// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Quote} from '@hyperlane/core/contracts/interfaces/ITokenBridge.sol';

interface ICrossCollateralRouter {
    function transferRemoteTo(uint32 destination, bytes32 recipient, uint256 amount, bytes32 targetRouter)
        external
        payable
        returns (bytes32);

    function quoteTransferRemoteTo(uint32 destination, bytes32 recipient, uint256 amount, bytes32 targetRouter)
        external
        view
        returns (Quote[] memory);
}
