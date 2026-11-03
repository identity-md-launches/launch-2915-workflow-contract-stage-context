// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IUnlockV2Hook} from "./interfaces/IUnlockV2Hook.sol";

/// @title UNLOCK V2 (UNLK2)
/// @notice Plain ERC-20: 1,000,000,000 UNLK2 minted once to the launch factory. Holder-authorized
///         burning reduces supply. No later mint, no transfer tax, no seizure, no blacklist, no
///         upgrade and no owner. The only extra behaviour is a one-time binding to the launch hook,
///         which is told about burns so it can debit sell rights and credit burn points.
contract UnlockV2Token is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    /// @notice The launch factory (msg.sender at deployment) that received the whole supply.
    address public immutable factory;

    /// @notice The launch hook, bound once during the launch transaction.
    address public hook;

    event HookRegistered(address indexed hook);
    event Burned(address indexed account, uint256 amount);

    error HookAlreadyRegistered();
    error NotLaunchFactory();
    error NotDuringLaunch();

    constructor() ERC20("UNLOCK V2", "UNLK2") {
        factory = msg.sender;
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @notice Binds the hook. Only callable while the launch transaction runs (the factory still
    ///         holds the entire supply) by a hook deployed for this token's factory, and only once.
    /// @param factory_ The factory the calling hook was deployed for; must equal this token's factory.
    function registerHook(address factory_) external {
        if (hook != address(0)) revert HookAlreadyRegistered();
        if (factory_ != factory) revert NotLaunchFactory();
        if (balanceOf(factory) != totalSupply()) revert NotDuringLaunch();
        hook = msg.sender;
        emit HookRegistered(msg.sender);
    }

    /// @notice Irreversibly burns `amount` of the caller's tokens and reports the burn to the hook.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
        emit Burned(msg.sender, amount);
        if (hook != address(0)) IUnlockV2Hook(hook).onBurn(msg.sender, amount);
    }
}
