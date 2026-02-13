// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ILinearFee {
    /// @notice The maximum fee (in token units) that can be charged for a transfer
    /// @dev Used as the cap in fee calculations; fee = min(maxFee, (amount * maxFee) / (2 * halfAmount))
    /// @return The maximum fee in token units
    function maxFee() external view returns (uint256);

    /// @notice The reference amount at which the fee equals half of maxFee
    /// @dev Used as a scaling parameter in the linear fee formula
    /// @return The half amount in token units
    function halfAmount() external view returns (uint256);
}
