// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

import {UnlockV2Token} from "../src/UnlockV2Token.sol";
import {UnlockV2Hook} from "../src/UnlockV2Hook.sol";
import {MigrationVault} from "../src/MigrationVault.sol";
import {RewardPot} from "../src/RewardPot.sol";
import {MockERC20, MockFeed, AuthRouter} from "./utils/Mocks.sol";

/// @dev The test contract plays the launch factory: it deploys the token (receiving the supply),
///      deploys the hook at a flag-bearing address, initializes the official pool and seeds liquidity.
abstract contract BaseTest is Test {
    using PoolIdLibrary for PoolKey;

    address internal constant OWNER = 0x48E4E74fE1d0c14404cEB57B9fec5b21329C6ec9;
    uint160 internal constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    // official pool opens at ~1e-4 IMD per UNLK2 (tick +-92100), reference pool at ~2980 IMD per ETH
    int24 internal constant OFFICIAL_TICK_ABS = 92100;
    int24 internal constant REF_TICK = 80000;
    int256 internal constant ETH_USD = 3000e8;

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    AuthRouter internal authRouter;
    MockERC20 internal imd;
    MockERC20 internal v1;
    MockFeed internal feed;
    UnlockV2Token internal token;
    UnlockV2Hook internal hook;
    MigrationVault internal vault;
    RewardPot internal pot;
    PoolKey internal key;
    PoolKey internal refKey;
    bool internal tokenIs0;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    receive() external payable {}

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        vm.roll(20_000_000);
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        authRouter = new AuthRouter(manager);
        imd = new MockERC20("IMD", "IMD");
        v1 = new MockERC20("UNLOCK", "UNLK");
        feed = new MockFeed();
        feed.set(ETH_USD, vm.getBlockTimestamp());

        token = new UnlockV2Token();
        address hookAddr = address(uint160(uint160(0x1234) << 20) | FLAGS);
        bytes memory args = abi.encode(
            IPoolManager(address(manager)),
            address(token),
            address(imd),
            address(this),
            OWNER,
            address(v1),
            address(feed),
            block.chainid
        );
        deployCodeTo("UnlockV2Hook.sol:UnlockV2Hook", args, hookAddr);
        hook = UnlockV2Hook(hookAddr);
        vault = hook.migrationVault();
        pot = hook.rewardPot();

        tokenIs0 = address(token) < address(imd);
        key = PoolKey({
            currency0: Currency.wrap(tokenIs0 ? address(token) : address(imd)),
            currency1: Currency.wrap(tokenIs0 ? address(imd) : address(token)),
            fee: 12500,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        refKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(imd)),
            fee: 10000,
            tickSpacing: 200,
            hooks: IHooks(address(0))
        });

        imd.mint(address(this), 1e30);
        imd.approve(address(lpRouter), type(uint256).max);
        token.approve(address(lpRouter), type(uint256).max);
        vm.deal(address(this), 1000 ether);
    }

    // ------------------------------------------------------------------ helpers

    function officialTick() internal view returns (int24) {
        return tokenIs0 ? -OFFICIAL_TICK_ABS : OFFICIAL_TICK_ABS;
    }

    function initOfficialPool() internal {
        manager.initialize(key, TickMath.getSqrtPriceAtTick(officialTick()));
    }

    function seedOfficialLiquidity() internal {
        int24 t = officialTick();
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: t - 6000, tickUpper: t + 6000, liquidityDelta: 1e24, salt: 0}), ""
        );
    }

    function initReferencePool() internal {
        manager.initialize(refKey, TickMath.getSqrtPriceAtTick(REF_TICK));
    }

    function seedReferenceLiquidity() internal {
        lpRouter.modifyLiquidity{value: 10 ether}(
            refKey,
            ModifyLiquidityParams({
                tickLower: REF_TICK - 1000, tickUpper: REF_TICK + 1000, liquidityDelta: 1e21, salt: 0
            }),
            ""
        );
    }

    /// @dev Mirrors the launch factory distribution and the owner's setup, then activates.
    function fullLaunch() internal {
        if (!hook.poolInitialized()) {
            initOfficialPool();
            seedOfficialLiquidity();
        }
        initReferencePool();
        seedReferenceLiquidity();
        // factory pays out: 100m swarm (kept here as stand-in distributor), 750m to owner
        token.transfer(OWNER, 750_000_000e18);
        // owner funds the migration vault with 700m and activates
        vm.startPrank(OWNER);
        token.transfer(address(vault), 700_000_000e18);
        hook.setRouter(address(authRouter), true);
        hook.activate();
        vm.stopPrank();
    }

    function giveImd(address who, uint256 amount) internal {
        imd.mint(who, amount);
        vm.startPrank(who);
        imd.approve(address(swapRouter), type(uint256).max);
        imd.approve(address(authRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(authRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Buy UNLK2 with IMD through the unregistered test router (shared account). Negative = exact input IMD.
    function buyShared(address who, int256 amountSpecified) internal returns (BalanceDelta d) {
        bool zeroForOne = !tokenIs0; // IMD -> token
        vm.prank(who);
        d = swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function sellShared(address who, int256 amountSpecified) internal returns (BalanceDelta d) {
        bool zeroForOne = tokenIs0; // token -> IMD
        vm.prank(who);
        d = swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    /// @notice Buy through the registered router that authenticates the trader via msgSender().
    function buy(address who, int256 amountSpecified) internal returns (BalanceDelta d) {
        bool zeroForOne = !tokenIs0;
        vm.prank(who);
        d = authRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    function sell(address who, int256 amountSpecified) internal returns (BalanceDelta d) {
        bool zeroForOne = tokenIs0;
        vm.prank(who);
        d = authRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );
    }

    function imdAmt(BalanceDelta d) internal view returns (int128) {
        return tokenIs0 ? d.amount1() : d.amount0();
    }

    function tokAmt(BalanceDelta d) internal view returns (int128) {
        return tokenIs0 ? d.amount0() : d.amount1();
    }

    function abs(int128 x) internal pure returns (uint256) {
        return x < 0 ? uint256(uint128(-x)) : uint256(uint128(x));
    }
}
