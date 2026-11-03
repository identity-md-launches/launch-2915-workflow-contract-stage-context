// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal view of the Uniswap-style MerkleDistributor the launch uses for the native swarm
///         distribution. Leaf format: keccak256(abi.encodePacked(index, account, amount)).
interface IMerkleDistributor {
    function merkleRoot() external view returns (bytes32);

    function isClaimed(uint256 index) external view returns (bool);
}
