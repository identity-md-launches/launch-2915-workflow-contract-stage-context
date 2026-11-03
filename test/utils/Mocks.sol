// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {UnlockV2Hook} from "../../src/UnlockV2Hook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockFeed {
    uint8 public decimals = 8;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;
    bool public shouldRevert;

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setRounds(uint80 roundId_, uint80 answeredInRound_) external {
        roundId = roundId_;
        answeredInRound = answeredInRound_;
    }

    function setDecimals(uint8 d) external {
        decimals = d;
    }

    function setRevert(bool r) external {
        shouldRevert = r;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!shouldRevert, "feed down");
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}

/// @notice Uniswap-style MerkleDistributor stub: only the two views the hook reads.
contract MockDistributor {
    bytes32 public merkleRoot;
    mapping(uint256 => bool) public isClaimed;

    constructor(bytes32 root) {
        merkleRoot = root;
    }

    function setClaimed(uint256 index, bool v) external {
        isClaimed[index] = v;
    }
}

/// @notice Minimal "standard router": exposes msgSender() like the Universal Router / v4 periphery.
contract AuthRouter is IUnlockCallback {
    IPoolManager public immutable manager;
    address public msgSender;

    constructor(IPoolManager m) {
        manager = m;
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta delta) {
        msgSender = msg.sender;
        delta = abi.decode(manager.unlock(abi.encode(key, params)), (BalanceDelta));
        msgSender = address(0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, SwapParams memory params) = abi.decode(data, (PoolKey, SwapParams));
        BalanceDelta delta = manager.swap(key, params, "");
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency c, int128 amount) internal {
        if (amount < 0) {
            manager.sync(c);
            IERC20(Currency.unwrap(c)).transferFrom(msgSender, address(manager), uint256(uint128(-amount)));
            manager.settle();
        } else if (amount > 0) {
            manager.take(c, msgSender, uint256(uint128(amount)));
        }
    }
}

/// @notice Exposes gate internals for unit tests of the threshold logic.
contract HookHarness is UnlockV2Hook {
    constructor(
        IPoolManager pm,
        address token_,
        address imd_,
        address factory_,
        address owner_,
        address v1_,
        address feed_,
        uint256 chainId_
    ) UnlockV2Hook(pm, token_, imd_, factory_, owner_, v1_, feed_, chainId_) {}

    function addVolume(uint256 usd) external {
        cumulativeVolumeUsd += usd;
    }

    function advance(uint256 fdv, bool valid) external {
        _advanceGates(fdv, valid);
    }

    function addBurn(uint256 amount) external {
        gateBurned += amount;
    }
}
