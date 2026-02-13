// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IHypCollateralBridge {
    /// @notice Returns the address of the fee recipient contract
    /// @return The fee recipient contract address
    function feeRecipient() external view returns (address);
}
