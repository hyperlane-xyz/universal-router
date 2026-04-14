// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Quote} from '@hyperlane/core/contracts/interfaces/ITokenBridge.sol';

interface ICrossCollateralRouter {
    function transferRemoteTo(
        uint32 _destination,
        bytes32 _recipient,
        uint256 _amount,
        bytes32 _targetRouter
    ) external payable returns (bytes32);

    function quoteTransferRemoteTo(
        uint32 _destination,
        bytes32 _recipient,
        uint256 _amount,
        bytes32 _targetRouter
    ) external view returns (Quote[] memory);
}
