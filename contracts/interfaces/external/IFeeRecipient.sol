// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IFeeRecipient {
    /// @notice Returns the linear fee contract address for a given destination domain
    /// @param domain The destination domain
    /// @return The address of the linear fee contract
    function feeContracts(uint32 domain) external view returns (address);
}
