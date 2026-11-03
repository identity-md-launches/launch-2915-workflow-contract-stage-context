// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import {UnlockV2Token} from "./UnlockV2Token.sol";
import {MigrationVault} from "./MigrationVault.sol";
import {RewardPot} from "./RewardPot.sol";
import {IUnlockV2Hook} from "./interfaces/IUnlockV2Hook.sol";
import {IMsgSender} from "./interfaces/IMsgSender.sol";
import {IMerkleDistributor} from "./interfaces/IMerkleDistributor.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/// @title UNLOCK V2 official-pool hook
/// @notice Gatekeeper of the official UNLK2/IMD Uniswap v4 pool:
///   * lets only the launch factory initialize exactly the intended PoolKey, once;
///   * keeps swaps closed until the owner has funded the migration vault and activated (sealed);
///   * enforces origin-bucketed sell rights that ten permanent gates unlock (FDV, gross IMD volume or burns);
///   * takes an extra 1% fee on the IMD leg of every swap, kept as IMD for the burn-points reward pot;
///   * prices FDV and volume on chain from the official pool, the ETH/IMD v4 reference pool and the
///     Chainlink ETH/USD feed; invalid prices skip price/volume progress but never block trading.
/// It creates the MigrationVault and RewardPot in its constructor.
contract UnlockV2Hook is IHooks, IUnlockCallback, IUnlockV2Hook {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;
    using SafeCast for int256;

    // ------------------------------------------------------------------ constants

    uint24 public constant POOL_FEE = 12500;
    int24 public constant POOL_TICK_SPACING = 60;
    uint24 public constant REFERENCE_FEE = 10000;
    int24 public constant REFERENCE_TICK_SPACING = 200;
    /// @notice Extra hook fee on the IMD leg of every official swap, in basis points (1%).
    uint256 public constant HOOK_FEE_BPS = 100;
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_FEED_AGE = 90 minutes;
    uint8 public constant FEED_DECIMALS = 8;
    /// @notice Sell allowance of official-pool buys before gate 1 (percent).
    uint256 public constant PRE_GATE_BUY_PCT = 20;
    uint8 public constant GATE_COUNT = 10;

    uint256 public constant POOL_ALLOCATION = 150_000_000e18;
    uint256 public constant SWARM_ALLOCATION = 100_000_000e18;
    uint256 public constant MIGRATION_ALLOCATION = 700_000_000e18;
    uint256 public constant FOUNDER_ALLOCATION = 50_000_000e18;

    // ------------------------------------------------------------------ immutables

    IPoolManager public immutable poolManager;
    UnlockV2Token public immutable token;
    address public immutable imd;
    address public immutable factory;
    address public immutable owner;
    AggregatorV3Interface public immutable ethUsdFeed;
    uint256 public immutable expectedChainId;
    MigrationVault public immutable migrationVault;
    RewardPot public immutable rewardPot;
    PoolId public immutable referencePoolId;

    // ------------------------------------------------------------------ state

    PoolKey public poolKey;
    PoolId public officialPoolId;
    bool public poolInitialized;
    bool public tokenIsCurrency0;
    bool public activated;
    uint64 public activatedAt;

    uint8 public gatesOpen;
    /// @notice Gross official volume (executed IMD legs at execution USD), 18 decimals, never reset.
    uint256 public cumulativeVolumeUsd;
    uint256 public totalBurned;
    uint256 public burnBaseline;
    uint256 public lastFdvUsd;
    uint256 public lastValidObservation;

    mapping(address => bool) public isRouter;
    address public swarmDistributor;
    mapping(uint256 => bool) public swarmIndexCredited;

    struct Rights {
        uint128 buyCredited;
        uint128 buySold;
        uint128 otherCredited;
        uint128 otherSold;
        uint128 pendingBuy;
        uint64 pendingBlock;
    }

    mapping(address => Rights) internal _rights;

    // swap context (set in beforeSwap, consumed in afterSwap, within one PoolManager lock)
    address private _ctxTrader;
    bool private _ctxIsSell;
    bool private _redeeming;

    // ------------------------------------------------------------------ events

    event PoolInitialized(PoolId indexed poolId, bool tokenIsCurrency0);
    event RouterSet(address indexed router, bool supported);
    event SwarmDistributorSet(address indexed distributor);
    event Activated(uint256 timestamp, uint256 imdUsdPrice);
    event GateOpened(uint8 indexed gate, uint8 reason, uint256 fdvUsd, uint256 volumeUsd, uint256 burned);
    event BuyCredited(address indexed account, uint256 amount, uint256 maturesAfterBlock);
    event SellDebited(address indexed account, uint256 amount, uint256 fromBuy, uint256 fromOther);
    event MigrationCredited(address indexed account, uint256 amount);
    event SwarmClaimCredited(address indexed account, uint256 index, uint256 amount);
    event FounderCredited(address indexed account, uint256 amount);
    event BurnDebited(address indexed account, uint256 amount, uint256 fromPending, uint256 fromBuy, uint256 fromOther);
    event HookFeeCollected(uint256 amount, bool isSell);
    event FeesRedeemed(uint256 amount);
    event Observation(bool valid, uint256 imdUsd, uint256 fdvUsd, uint256 volumeUsdAdded);

    // ------------------------------------------------------------------ errors

    error NotPoolManager();
    error NotOwner();
    error NotToken();
    error NotVault();
    error NotFactory();
    error HookNotImplemented();
    error AlreadyInitialized();
    error WrongPoolKey();
    error WrongPool();
    error TradingClosed();
    error Sealed();
    error PoolNotInitialized();
    error WrongChain(uint256 actual);
    error MigrationNotFunded(uint256 backing, uint256 required);
    error ReferenceUnavailable();
    error FeedDecimalsMismatch(uint8 actual);
    error SellExceedsAllowance(address trader, uint256 requested, uint256 allowed);
    error NothingToRedeem();
    error DistributorNotSet();
    error SwarmClaimNotFound();
    error SwarmIndexAlreadyCredited(uint256 index);
    error InvalidProof();
    error ZeroAddress();
    error NotRedeeming();

    // ------------------------------------------------------------------ modifiers

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier notSealed() {
        if (activated) revert Sealed();
        _;
    }

    // ------------------------------------------------------------------ constructor

    /// @param poolManager_ Uniswap v4 PoolManager of the launch chain ("$poolManager").
    /// @param token_ The UNLK2 token deployed just before this hook ("$token").
    /// @param imd_ The IMD pair token.
    /// @param factory_ The launch factory ("$factory").
    /// @param owner_ The launch owner / founder ("$owner").
    /// @param v1Token_ UNLOCK V1 token accepted by the migration vault.
    /// @param ethUsdFeed_ Chainlink ETH/USD aggregator (8 decimals).
    /// @param expectedChainId_ Chain id the pricing references are valid for.
    constructor(
        IPoolManager poolManager_,
        address token_,
        address imd_,
        address factory_,
        address owner_,
        address v1Token_,
        address ethUsdFeed_,
        uint256 expectedChainId_
    ) {
        if (
            address(poolManager_) == address(0) || token_ == address(0) || imd_ == address(0) || factory_ == address(0)
                || owner_ == address(0) || v1Token_ == address(0) || ethUsdFeed_ == address(0)
        ) revert ZeroAddress();
        poolManager = poolManager_;
        token = UnlockV2Token(token_);
        imd = imd_;
        factory = factory_;
        owner = owner_;
        ethUsdFeed = AggregatorV3Interface(ethUsdFeed_);
        expectedChainId = expectedChainId_;

        migrationVault = new MigrationVault(v1Token_, token_);
        rewardPot = new RewardPot(imd_);

        referencePoolId = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(imd_),
            fee: REFERENCE_FEE,
            tickSpacing: REFERENCE_TICK_SPACING,
            hooks: IHooks(address(0))
        }).toId();

        // Bind this hook to the token. Low-level so that the constructor also runs on a chain where
        // the token is not deployed (launch pre-checks); the binding is verified by `isBound()`.
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok,) = token_.call(abi.encodeCall(UnlockV2Token.registerHook, (factory_)));
        ok;
    }

    // ------------------------------------------------------------------ hook permissions

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice The address flag bits this hook must be deployed at.
    function requiredAddressFlags() external pure returns (uint160) {
        return Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    }

    // ------------------------------------------------------------------ owner setup (before seal)

    /// @notice Mark a standard router (one exposing msgSender()) as supported for trader authentication.
    function setRouter(address router, bool supported) external onlyOwner notSealed {
        if (router == address(0)) revert ZeroAddress();
        isRouter[router] = supported;
        emit RouterSet(router, supported);
    }

    /// @notice Set the launch's native swarm MerkleDistributor used to verify swarm claim evidence.
    function setSwarmDistributor(address distributor) external onlyOwner notSealed {
        if (distributor == address(0)) revert ZeroAddress();
        swarmDistributor = distributor;
        emit SwarmDistributorSet(distributor);
    }

    /// @notice Opens trading and seals configuration forever. Requires: official pool initialized,
    ///         correct chain, migration vault fully funded, pricing references available.
    function activate() external onlyOwner notSealed {
        if (!poolInitialized) revert PoolNotInitialized();
        if (block.chainid != expectedChainId) revert WrongChain(block.chainid);
        uint256 backing = migrationVault.remainingBacking();
        uint256 required = migrationVault.remainingCapacity();
        if (backing < required) revert MigrationNotFunded(backing, required);
        uint8 dec = ethUsdFeed.decimals();
        if (dec != FEED_DECIMALS) revert FeedDecimalsMismatch(dec);
        (uint256 price, bool valid) = imdUsdPrice();
        if (!valid) revert ReferenceUnavailable();
        (, bool tokenPriceValid) = tokenPriceInImd();
        if (!tokenPriceValid) revert ReferenceUnavailable();

        activated = true;
        activatedAt = uint64(block.timestamp);
        _rights[owner].otherCredited += uint128(FOUNDER_ALLOCATION);
        emit FounderCredited(owner, FOUNDER_ALLOCATION);
        emit Activated(block.timestamp, price);
    }

    // ------------------------------------------------------------------ IHooks

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (sender != factory) revert NotFactory();
        if (poolInitialized) revert AlreadyInitialized();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        bool tokenFirst = c0 == address(token) && c1 == imd;
        bool imdFirst = c0 == imd && c1 == address(token);
        if (!(tokenFirst || imdFirst)) revert WrongPoolKey();
        if (key.fee != POOL_FEE || key.tickSpacing != POOL_TICK_SPACING || address(key.hooks) != address(this)) {
            revert WrongPoolKey();
        }
        poolInitialized = true;
        tokenIsCurrency0 = tokenFirst;
        poolKey = key;
        officialPoolId = key.toId();
        emit PoolInitialized(officialPoolId, tokenFirst);
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!activated) revert TradingClosed();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(officialPoolId)) revert WrongPool();

        bool isSell = tokenIsCurrency0 ? params.zeroForOne : !params.zeroForOne;
        bool exactInput = params.amountSpecified < 0;
        _ctxTrader = _resolveTrader(sender);
        _ctxIsSell = isSell;

        // IMD is the specified currency on exact-input buys and exact-output sells: take the fee here.
        int128 feeSpecified = 0;
        if ((!isSell && exactInput) || (isSell && !exactInput)) {
            uint256 amount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            uint256 fee = amount * HOOK_FEE_BPS / BPS;
            if (fee != 0) {
                poolManager.mint(address(this), Currency.wrap(imd).toId(), fee);
                feeSpecified = fee.toInt128();
                emit HookFeeCollected(fee, isSell);
            }
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(feeSpecified, 0), 0);
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        address trader = _ctxTrader;
        bool isSell = _ctxIsSell;
        bool exactInput = params.amountSpecified < 0;
        delete _ctxTrader;
        delete _ctxIsSell;

        int128 imdDelta = tokenIsCurrency0 ? delta.amount1() : delta.amount0();
        int128 tokenDelta = tokenIsCurrency0 ? delta.amount0() : delta.amount1();
        uint256 imdLeg = _abs(imdDelta);
        uint256 tokenLeg = _abs(tokenDelta);

        // IMD is the unspecified currency on exact-input sells and exact-output buys: take the fee here.
        int128 feeUnspecified = 0;
        if ((isSell && exactInput) || (!isSell && !exactInput)) {
            uint256 fee = imdLeg * HOOK_FEE_BPS / BPS;
            if (fee != 0) {
                poolManager.mint(address(this), Currency.wrap(imd).toId(), fee);
                feeUnspecified = fee.toInt128();
                emit HookFeeCollected(fee, isSell);
            }
        }

        if (isSell) {
            _debitSell(trader, tokenLeg);
        } else {
            _creditBuy(trader, tokenLeg);
        }

        _observe(imdLeg);
        return (IHooks.afterSwap.selector, feeUnspecified);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    // ------------------------------------------------------------------ companions

    /// @inheritdoc IUnlockV2Hook
    function onBurn(address account, uint256 amount) external {
        if (msg.sender != address(token)) revert NotToken();
        totalBurned += amount;
        _debitBurn(account, amount);
        rewardPot.addPoints(account, amount);
        _advanceGates(lastFdvUsd, false);
    }

    /// @inheritdoc IUnlockV2Hook
    function creditMigration(address account, uint256 amount) external {
        if (msg.sender != address(migrationVault)) revert NotVault();
        _rights[account].otherCredited += amount.toUint128();
        emit MigrationCredited(account, amount);
    }

    /// @notice Credit a native swarm claim once, verified against the launch MerkleDistributor
    ///         (claimed flag plus Merkle proof of the leaf). Anyone may submit the evidence.
    function creditSwarmClaim(uint256 index, address account, uint256 amount, bytes32[] calldata proof) external {
        address distributor = swarmDistributor;
        if (distributor == address(0)) revert DistributorNotSet();
        if (swarmIndexCredited[index]) revert SwarmIndexAlreadyCredited(index);
        if (!IMerkleDistributor(distributor).isClaimed(index)) revert SwarmClaimNotFound();
        bytes32 leaf = keccak256(abi.encodePacked(index, account, amount));
        if (!MerkleProof.verify(proof, IMerkleDistributor(distributor).merkleRoot(), leaf)) revert InvalidProof();
        swarmIndexCredited[index] = true;
        _rights[account].otherCredited += amount.toUint128();
        emit SwarmClaimCredited(account, index, amount);
    }

    /// @notice Pending hook fees held as ERC-6909 IMD claims in the PoolManager.
    function pendingFees() public view returns (uint256) {
        return poolManager.balanceOf(address(this), Currency.wrap(imd).toId());
    }

    /// @notice Moves collected IMD fees from the PoolManager into the reward pot. Anyone may call.
    function redeemFees() external returns (uint256 amount) {
        amount = pendingFees();
        if (amount == 0) revert NothingToRedeem();
        _redeeming = true;
        poolManager.unlock(abi.encode(amount));
        _redeeming = false;
        rewardPot.notifyDeposit(amount);
        emit FeesRedeemed(amount);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!_redeeming) revert NotRedeeming();
        uint256 amount = abi.decode(data, (uint256));
        Currency c = Currency.wrap(imd);
        poolManager.burn(address(this), c.toId(), amount);
        poolManager.take(c, address(rewardPot), amount);
        return "";
    }

    // ------------------------------------------------------------------ views

    /// @notice True when the token reports this hook as its bound hook.
    function isBound() external view returns (bool) {
        return token.hook() == address(this);
    }

    /// @notice Gate table row (1-based). Percent unlocked, USD FDV, cumulative USD volume, burn target (18 dec).
    function gate(uint8 g)
        public
        pure
        returns (uint8 pct, uint256 fdvThreshold, uint256 volumeThreshold, uint256 burnTarget)
    {
        if (g == 1) return (25, 250_000e18, 125_000e18, 25_000_000e18);
        if (g == 2) return (30, 500_000e18, 375_000e18, 22_000_000e18);
        if (g == 3) return (35, 1_000_000e18, 750_000e18, 19_000_000e18);
        if (g == 4) return (40, 2_000_000e18, 1_500_000e18, 16_000_000e18);
        if (g == 5) return (50, 3_500_000e18, 2_500_000e18, 13_000_000e18);
        if (g == 6) return (60, 5_000_000e18, 4_000_000e18, 10_000_000e18);
        if (g == 7) return (70, 8_000_000e18, 6_000_000e18, 8_000_000e18);
        if (g == 8) return (80, 12_000_000e18, 9_000_000e18, 6_000_000e18);
        if (g == 9) return (90, 18_000_000e18, 12_500_000e18, 4_000_000e18);
        if (g == 10) return (100, 25_000_000e18, 20_000_000e18, 2_000_000e18);
        revert("bad gate");
    }

    /// @notice Burns counted toward the next gate.
    function burnProgress() external view returns (uint256) {
        return totalBurned - burnBaseline;
    }

    /// @notice Current unlocked percentages for (official buys, other credited origins).
    function unlockedPercents() public view returns (uint256 buyPct, uint256 otherPct) {
        if (gatesOpen == 0) return (PRE_GATE_BUY_PCT, 0);
        (uint8 pct,,,) = gate(gatesOpen);
        return (pct, pct);
    }

    function rightsOf(address account) external view returns (Rights memory r) {
        r = _rights[account];
        _matureInMemory(r);
    }

    /// @notice Tokens `account` may currently sell into the official pool (type(uint256).max after gate 10).
    function sellAllowance(address account) public view returns (uint256) {
        if (gatesOpen >= GATE_COUNT) return type(uint256).max;
        Rights memory r = _rights[account];
        _matureInMemory(r);
        (uint256 buyAllow, uint256 otherAllow) = _allowances(r);
        return buyAllow + otherAllow;
    }

    /// @notice Preview how a burn of `amount` would debit `account`'s credits, and the allowance after.
    function previewBurn(address account, uint256 amount)
        external
        view
        returns (uint256 fromPending, uint256 fromBuy, uint256 fromOther, uint256 uncredited, uint256 allowanceAfter)
    {
        Rights memory r = _rights[account];
        _matureInMemory(r);
        (fromPending, fromBuy, fromOther) = _burnDebits(r, amount);
        uncredited = amount - fromPending - fromBuy - fromOther;
        r.pendingBuy -= uint128(fromPending);
        r.buyCredited -= uint128(fromBuy);
        r.otherCredited -= uint128(fromOther);
        if (gatesOpen >= GATE_COUNT) {
            allowanceAfter = type(uint256).max;
        } else {
            (uint256 b, uint256 o) = _allowances(r);
            allowanceAfter = b + o;
        }
    }

    /// @notice USD per IMD (18 decimals) from the ETH/IMD v4 reference pool and the Chainlink ETH/USD feed.
    function imdUsdPrice() public view returns (uint256 price, bool valid) {
        if (block.chainid != expectedChainId) return (0, false);
        (uint256 ethUsd, bool feedOk) = _ethUsd();
        if (!feedOk) return (0, false);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(referencePoolId);
        if (sqrtPriceX96 == 0) return (0, false);
        if (poolManager.getLiquidity(referencePoolId) == 0) return (0, false);
        // reference pool: currency0 = native ETH, currency1 = IMD; price = IMD per ETH (both 18 decimals)
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
        uint256 imdPerEth = FullMath.mulDiv(priceX96, 1e18, FixedPoint96.Q96);
        if (imdPerEth == 0) return (0, false);
        // ethUsd has 8 decimals -> scale to 18, then USD/IMD = USD/ETH / (IMD/ETH)
        price = FullMath.mulDiv(ethUsd * 1e10, 1e18, imdPerEth);
        valid = price != 0;
    }

    /// @notice IMD per UNLK2 (18 decimals) from the official pool's current sqrt price.
    function tokenPriceInImd() public view returns (uint256 price, bool valid) {
        if (!poolInitialized) return (0, false);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(officialPoolId);
        if (sqrtPriceX96 == 0) return (0, false);
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96); // currency1 per currency0
        if (tokenIsCurrency0) {
            price = FullMath.mulDiv(priceX96, 1e18, FixedPoint96.Q96);
        } else {
            if (priceX96 == 0) return (0, false);
            price = FullMath.mulDiv(1e18, FixedPoint96.Q96, priceX96);
        }
        valid = price != 0;
    }

    /// @notice Fully diluted value in USD (18 decimals): token price x current totalSupply (burned excluded).
    function fdvUsd() public view returns (uint256 fdv, bool valid) {
        (uint256 imdUsd, bool v1) = imdUsdPrice();
        (uint256 tokenImd, bool v2) = tokenPriceInImd();
        if (!v1 || !v2) return (0, false);
        uint256 usdPerToken = FullMath.mulDiv(tokenImd, imdUsd, 1e18);
        fdv = FullMath.mulDiv(usdPerToken, token.totalSupply(), 1e18);
        valid = true;
    }

    /// @notice True when both pricing references currently produce a valid price.
    function isReferenceAvailable() external view returns (bool) {
        (, bool v) = fdvUsd();
        return v;
    }

    /// @notice Allocation table; the sum must equal the token supply.
    function allocation() external pure returns (uint256 pool, uint256 swarm, uint256 migration, uint256 founder) {
        return (POOL_ALLOCATION, SWARM_ALLOCATION, MIGRATION_ALLOCATION, FOUNDER_ALLOCATION);
    }

    // ------------------------------------------------------------------ internals

    function _resolveTrader(address sender) internal view returns (address) {
        if (isRouter[sender]) return IMsgSender(sender).msgSender();
        return sender;
    }

    function _ethUsd() internal view returns (uint256, bool) {
        try ethUsdFeed.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80 answeredInRound
        ) {
            if (answer <= 0) return (0, false);
            if (updatedAt == 0 || updatedAt > block.timestamp) return (0, false);
            if (block.timestamp - updatedAt > MAX_FEED_AGE) return (0, false);
            if (answeredInRound < roundId) return (0, false);
            return (uint256(answer), true);
        } catch {
            return (0, false);
        }
    }

    function _observe(uint256 imdLeg) internal {
        (uint256 imdUsd, bool v1) = imdUsdPrice();
        (uint256 tokenImd, bool v2) = tokenPriceInImd();
        if (!v1 || !v2) {
            emit Observation(false, 0, 0, 0);
            _advanceGates(0, false);
            return;
        }
        uint256 volumeAdded = FullMath.mulDiv(imdLeg, imdUsd, 1e18);
        cumulativeVolumeUsd += volumeAdded;
        uint256 usdPerToken = FullMath.mulDiv(tokenImd, imdUsd, 1e18);
        uint256 fdv = FullMath.mulDiv(usdPerToken, token.totalSupply(), 1e18);
        lastFdvUsd = fdv;
        lastValidObservation = block.timestamp;
        emit Observation(true, imdUsd, fdv, volumeAdded);
        _advanceGates(fdv, true);
    }

    /// @dev Opens every sequential gate whose FDV, volume or burn threshold is met. reason: 1 burn, 2 fdv, 3 volume.
    function _advanceGates(uint256 fdv, bool priceValid) internal {
        while (gatesOpen < GATE_COUNT) {
            uint8 next = gatesOpen + 1;
            (, uint256 fdvT, uint256 volT, uint256 burnT) = gate(next);
            uint8 reason = 0;
            if (totalBurned - burnBaseline >= burnT) reason = 1;
            else if (priceValid && fdv >= fdvT) reason = 2;
            else if (cumulativeVolumeUsd >= volT) reason = 3;
            if (reason == 0) break;
            if (reason == 1) burnBaseline += burnT;
            else burnBaseline = totalBurned;
            gatesOpen = next;
            emit GateOpened(next, reason, fdv, cumulativeVolumeUsd, totalBurned);
        }
    }

    function _matureInMemory(Rights memory r) internal view {
        if (r.pendingBuy != 0 && r.pendingBlock < block.number) {
            r.buyCredited += r.pendingBuy;
            r.pendingBuy = 0;
        }
    }

    function _mature(address account) internal {
        Rights storage r = _rights[account];
        if (r.pendingBuy != 0 && r.pendingBlock < block.number) {
            r.buyCredited += r.pendingBuy;
            r.pendingBuy = 0;
        }
    }

    function _allowances(Rights memory r) internal view returns (uint256 buyAllow, uint256 otherAllow) {
        (uint256 buyPct, uint256 otherPct) = unlockedPercents();
        uint256 buyCap = uint256(r.buyCredited) * buyPct / 100;
        buyAllow = buyCap > r.buySold ? buyCap - r.buySold : 0;
        uint256 otherCap = uint256(r.otherCredited) * otherPct / 100;
        otherAllow = otherCap > r.otherSold ? otherCap - r.otherSold : 0;
    }

    function _creditBuy(address account, uint256 amount) internal {
        if (amount == 0) return;
        _mature(account);
        Rights storage r = _rights[account];
        r.pendingBuy += amount.toUint128();
        r.pendingBlock = uint64(block.number);
        emit BuyCredited(account, amount, block.number);
    }

    function _debitSell(address account, uint256 amount) internal {
        if (amount == 0) return;
        _mature(account);
        Rights storage r = _rights[account];
        if (gatesOpen >= GATE_COUNT) {
            emit SellDebited(account, amount, 0, 0);
            return;
        }
        (uint256 buyAllow, uint256 otherAllow) = _allowances(r);
        if (amount > buyAllow + otherAllow) revert SellExceedsAllowance(account, amount, buyAllow + otherAllow);
        uint256 fromBuy = amount < buyAllow ? amount : buyAllow;
        uint256 fromOther = amount - fromBuy;
        r.buySold += uint128(fromBuy);
        r.otherSold += uint128(fromOther);
        emit SellDebited(account, amount, fromBuy, fromOther);
    }

    /// @dev Conservative burn debit: credits are consumed before uncredited balance, in the order
    ///      pending buys, matured buys, other origins. Sold counters never change.
    function _burnDebits(Rights memory r, uint256 amount)
        internal
        pure
        returns (uint256 fromPending, uint256 fromBuy, uint256 fromOther)
    {
        uint256 rem = amount;
        fromPending = rem < r.pendingBuy ? rem : r.pendingBuy;
        rem -= fromPending;
        uint256 heldBuy = r.buyCredited > r.buySold ? r.buyCredited - r.buySold : 0;
        fromBuy = rem < heldBuy ? rem : heldBuy;
        rem -= fromBuy;
        uint256 heldOther = r.otherCredited > r.otherSold ? r.otherCredited - r.otherSold : 0;
        fromOther = rem < heldOther ? rem : heldOther;
    }

    function _debitBurn(address account, uint256 amount) internal {
        _mature(account);
        Rights storage r = _rights[account];
        (uint256 fromPending, uint256 fromBuy, uint256 fromOther) = _burnDebits(r, amount);
        r.pendingBuy -= uint128(fromPending);
        r.buyCredited -= uint128(fromBuy);
        r.otherCredited -= uint128(fromOther);
        emit BurnDebited(account, amount, fromPending, fromBuy, fromOther);
    }

    function _abs(int128 x) internal pure returns (uint256) {
        return x < 0 ? uint256(uint128(-x)) : uint256(uint128(x));
    }
}
