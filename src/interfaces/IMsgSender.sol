// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Standard router interface (Uniswap Universal Router / v4 periphery BaseActionsRouter)
///         that exposes the account that initiated the current call.
interface IMsgSender {
    function msgSender() external view returns (address);
}
