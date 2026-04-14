// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

// Command implementations
import {Quote} from '@hyperlane/core/contracts/interfaces/ITokenBridge.sol';
import {IAllowanceTransfer} from 'permit2/src/interfaces/IAllowanceTransfer.sol';
import {QuotedCalls} from '@hyperlane/core/contracts/token/QuotedCalls.sol';
import {Dispatcher} from './base/Dispatcher.sol';
import {RouterDeployParameters} from './types/RouterDeployParameters.sol';
import {PaymentsImmutables, PaymentsParameters} from './modules/PaymentsImmutables.sol';
import {RouterImmutables, RouterParameters} from './modules/uniswap/RouterImmutables.sol';
import {V4SwapRouter} from './modules/uniswap/v4/V4SwapRouter.sol';
import {Commands} from './libraries/Commands.sol';
import {Locker} from './libraries/Locker.sol';
import {IUniversalRouter} from './interfaces/IUniversalRouter.sol';

contract UniversalRouter is IUniversalRouter, Dispatcher {
    address internal immutable _quotedCallsModule;

    constructor(RouterDeployParameters memory params)
        RouterImmutables(RouterParameters(
                params.v2Factory,
                params.v3Factory,
                params.pairInitCodeHash,
                params.poolInitCodeHash,
                params.veloV2Factory,
                params.veloCLFactory,
                params.veloV2InitCodeHash,
                params.veloCLInitCodeHash,
                params.veloCLFactory2,
                params.veloCLInitCodeHash2,
                params.veloCLFactory3,
                params.veloCLInitCodeHash3
            ))
        V4SwapRouter(params.v4PoolManager)
        PaymentsImmutables(PaymentsParameters(params.permit2, params.weth9))
    {
        _quotedCallsModule = address(new QuotedCalls(IAllowanceTransfer(params.permit2)));
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert TransactionDeadlinePassed();
        _;
    }

    /// @notice To receive ETH from WETH, poolManager, or refunds from bridges/hooks during execution
    receive() external payable {
        if (!Locker.isLocked() && msg.sender != address(WETH9) && msg.sender != address(poolManager)) {
            revert InvalidEthSender();
        }
    }

    /// @inheritdoc IUniversalRouter
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
    {
        execute(commands, inputs);
    }

    /// @inheritdoc Dispatcher
    function execute(bytes calldata commands, bytes[] calldata inputs) public payable override isNotLocked {
        bool success;
        bytes memory output;
        uint256 numCommands = commands.length;
        if (inputs.length != numCommands) revert LengthMismatch();

        // loop through all given commands, execute them and pass along outputs as defined
        for (uint256 commandIndex = 0; commandIndex < numCommands; commandIndex++) {
            bytes1 command = commands[commandIndex];

            bytes calldata input = inputs[commandIndex];

            (success, output) = dispatch(command, input);

            if (!success && successRequired(command)) {
                revert ExecutionFailed({commandIndex: commandIndex, message: output});
            }
        }
    }

    /// @inheritdoc IUniversalRouter
    function quoteExecute(bytes calldata commands, bytes[] calldata inputs)
        external
        override
        returns (Quote[][] memory results)
    {
        bool success;
        bytes memory output;
        address module = _quotedCallsModule;
        bytes4 selector = QuotedCalls.quoteExecute.selector;
        assembly ("memory-safe") {
            let argsSize := sub(calldatasize(), 0x04)
            let payloadSize := add(0x04, argsSize)
            let payload := mload(0x40)
            mstore(payload, payloadSize)
            mstore(add(payload, 0x20), shl(224, selector))
            calldatacopy(add(payload, 0x24), 0x04, argsSize)

            success := delegatecall(gas(), module, add(payload, 0x20), payloadSize, 0, 0)

            let returnSize := returndatasize()
            output := mload(0x40)
            mstore(output, returnSize)
            returndatacopy(add(output, 0x20), 0, returnSize)
            mstore(0x40, and(add(add(output, 0x20), add(returnSize, 0x1f)), not(0x1f)))
        }
        if (!success) assembly ("memory-safe") {
            revert(add(output, 0x20), mload(output))
        }
        results = abi.decode(output, (Quote[][]));
    }

    function successRequired(bytes1 command) internal pure returns (bool) {
        return command & Commands.FLAG_ALLOW_REVERT == 0;
    }

    /// @inheritdoc Dispatcher
    function quotedCallsModule() internal view override returns (address) {
        return _quotedCallsModule;
    }
}
