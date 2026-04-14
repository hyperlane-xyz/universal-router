// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {InterchainAccountRouter} from '@hyperlane/core/contracts/middleware/InterchainAccountRouter.sol';
import {StandardHookMetadata} from '@hyperlane/core/contracts/hooks/libs/StandardHookMetadata.sol';
import {IPostDispatchHook} from '@hyperlane/core/contracts/interfaces/hooks/IPostDispatchHook.sol';
import {OwnableMulticall} from '@hyperlane/core/contracts/middleware/libs/OwnableMulticall.sol';
import {TypeCasts} from '@hyperlane/core/contracts/libs/TypeCasts.sol';
import {HypXERC20} from '@hyperlane/core/contracts/token/extensions/HypXERC20.sol';
import {QuotedCalls} from '@hyperlane/core/contracts/token/QuotedCalls.sol';

import {IInterchainAccountRouter} from 'contracts/interfaces/external/IInterchainAccountRouter.sol';

import '../../BaseForkFixture.t.sol';

library QuotedCallsCommands {
    uint256 internal constant TRANSFER_REMOTE = 0x04;
    uint256 internal constant CALL_REMOTE_COMMIT_REVEAL = 0x07;
}

contract ExecuteCrossChainTest is BaseForkFixture {
    uint256 internal constant QUOTED_CALLS_CONTRACT_BALANCE =
        0x8000000000000000000000000000000000000000000000000000000000000000;

    InterchainAccountRouter public rootIcaRouter;
    InterchainAccountRouter public leafIcaRouter;

    IPoolFactory public constant v2Factory = IPoolFactory(0x420DD381b31aEf6683db6B902084cB0FFECe40Da);
    address public constant baseUSDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    uint256 public constant MESSAGE_FEE = 1 ether / 10_000;

    struct CrosschainContext {
        address payable userICA;
        bytes32 commitment;
        bytes commands;
        bytes[] inputs;
        CallLib.Call[] calls;
        bytes hookMetadata;
    }

    function setUp() public override {
        super.setUp();

        deal(address(users.alice), 1 ether);
        rootIcaRouter = InterchainAccountRouter(OPTIMISM_ROUTER_ICA_ADDRESS);

        vm.selectFork({forkId: leafId});
        leafIcaRouter = InterchainAccountRouter(BASE_ROUTER_ICA_ADDRESS);
        createAndSeedPair(baseUSDC, OPEN_USDT_ADDRESS, false);

        vm.selectFork({forkId: rootId});
        vm.deal(users.alice, MESSAGE_FEE * 10);
        vm.startPrank({msgSender: users.alice});
    }

    function test_executeCrosschainFlowV3SwapExactIn() public {
        uint256 amountIn = USDC_1;
        uint256 amountOutMin = 9e5;

        bytes memory swapSubplan = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_IN)));
        bytes memory path = abi.encodePacked(OPEN_USDT_ADDRESS, int24(1), baseUSDC);
        bytes[] memory swapInputs = new bytes[](1);
        swapInputs[0] = abi.encode(users.alice, amountIn, amountOutMin, path, true, false);

        bytes memory transferSubplan = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)));
        bytes[] memory transferInputs = new bytes[](1);
        transferInputs[0] = abi.encode(OPEN_USDT_ADDRESS, users.alice, Constants.TOTAL_BALANCE);

        bytes memory leafCommands = abi.encodePacked(
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT,
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT
        );
        bytes[] memory leafInputs = new bytes[](2);
        leafInputs[0] = abi.encode(swapSubplan, swapInputs);
        leafInputs[1] = abi.encode(transferSubplan, transferInputs);

        CallLib.Call[] memory calls = new CallLib.Call[](2);
        calls[0] = CallLib.build({
            to: OPEN_USDT_ADDRESS, value: 0, data: abi.encodeCall(ERC20.approve, (address(leafRouter), amountIn))
        });
        calls[1] = CallLib.build({
            to: address(leafRouter), value: 0, data: abi.encodeCall(Dispatcher.execute, (leafCommands, leafInputs))
        });

        bytes32 salt = TypeCasts.addressToBytes32(users.alice);
        bytes32 commitment = hashCommitment({_calls: calls, _salt: salt});
        address payable userICA = _predictUserICA(salt);

        (bytes memory commands, bytes[] memory inputs) = _encodeOriginQuotedPlan(userICA, amountIn, amountIn, commitment, salt);

        deal(OPEN_USDT_ADDRESS, users.alice, amountIn);
        ERC20(OPEN_USDT_ADDRESS).approve(address(router), amountIn);

        _expectCommitRevealCall(salt, commitment, new bytes(0));
        router.execute{value: MESSAGE_FEE * 2}(commands, inputs);

        vm.selectFork(leafId);
        leafMailbox.processNextInboundMessage();
        leafMailbox.processNextInboundMessage();

        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(userICA).revealAndExecute({calls: calls, salt: salt});

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), 0);
        assertGt(ERC20(baseUSDC).balanceOf(users.alice), amountOutMin);
    }

    function test_executeCrosschainFlowV3SwapExactOut() public {
        uint256 amountOut = 9e5;
        uint256 amountInMax = USDC_1;

        bytes memory swapSubplan = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_OUT)));
        bytes memory path = abi.encodePacked(baseUSDC, int24(1), OPEN_USDT_ADDRESS);
        bytes[] memory swapInputs = new bytes[](1);
        swapInputs[0] = abi.encode(users.alice, amountOut, amountInMax, path, true, false);

        bytes memory transferSubplan = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)));
        bytes[] memory transferInputs = new bytes[](1);
        transferInputs[0] = abi.encode(OPEN_USDT_ADDRESS, users.alice, Constants.TOTAL_BALANCE);

        bytes memory leafCommands = abi.encodePacked(
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT,
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT
        );
        bytes[] memory leafInputs = new bytes[](2);
        leafInputs[0] = abi.encode(swapSubplan, swapInputs);
        leafInputs[1] = abi.encode(transferSubplan, transferInputs);

        CallLib.Call[] memory calls = new CallLib.Call[](2);
        calls[0] = CallLib.build({
            to: OPEN_USDT_ADDRESS, value: 0, data: abi.encodeCall(ERC20.approve, (address(leafRouter), amountInMax))
        });
        calls[1] = CallLib.build({
            to: address(leafRouter), value: 0, data: abi.encodeCall(Dispatcher.execute, (leafCommands, leafInputs))
        });

        bytes32 salt = TypeCasts.addressToBytes32(users.alice);
        bytes32 commitment = hashCommitment({_calls: calls, _salt: salt});
        address payable userICA = _predictUserICA(salt);

        (bytes memory commands, bytes[] memory inputs) =
            _encodeOriginQuotedPlan(userICA, amountInMax, amountInMax, commitment, salt);

        deal(OPEN_USDT_ADDRESS, users.alice, amountInMax);
        ERC20(OPEN_USDT_ADDRESS).approve(address(router), amountInMax);

        _expectCommitRevealCall(salt, commitment, new bytes(0));
        router.execute{value: MESSAGE_FEE * 2}(commands, inputs);

        vm.selectFork(leafId);
        leafMailbox.processNextInboundMessage();
        leafMailbox.processNextInboundMessage();

        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(userICA).revealAndExecute({calls: calls, salt: salt});

        assertEq(ERC20(baseUSDC).balanceOf(users.alice), amountOut);
        assertGt(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), 0);
    }

    function test_executeCrosschainFlowMultichainV3SwapExactIn_scoped() public {
        uint256 destinationAmountOutMin = 5800000;
        uint256 amountIn = 10 ether;
        uint256 originAmountOutMin = 5800000;
        bytes32 salt = TypeCasts.addressToBytes32(users.alice);

        bytes memory leafCommands;
        bytes[] memory leafInputs;
        {
            bytes memory swapSubplan =
                abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)), bytes1(uint8(Commands.V3_SWAP_EXACT_IN)));
            bytes[] memory swapInputs = new bytes[](2);
            swapInputs[0] = abi.encode(OPEN_USDT_ADDRESS, address(leafRouter), Constants.TOTAL_BALANCE);
            swapInputs[1] = abi.encode(
                users.alice, ActionConstants.CONTRACT_BALANCE, destinationAmountOutMin, _v3BasePath(), false, false
            );

            bytes memory transferSubplan = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)));
            bytes[] memory transferInputs = new bytes[](1);
            transferInputs[0] = abi.encode(OPEN_USDT_ADDRESS, users.alice, Constants.TOTAL_BALANCE);

            leafCommands = abi.encodePacked(
                bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT,
                bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT
            );
            leafInputs = new bytes[](2);
            leafInputs[0] = abi.encode(swapSubplan, swapInputs);
            leafInputs[1] = abi.encode(transferSubplan, transferInputs);
        }

        CallLib.Call[] memory calls = new CallLib.Call[](3);
        {
            calls[0] = CallLib.build({
                to: OPEN_USDT_ADDRESS,
                value: 0,
                data: abi.encodeCall(ERC20.approve, (address(leafRouter), type(uint256).max))
            });
            calls[1] = CallLib.build({
                to: address(leafRouter), value: 0, data: abi.encodeCall(Dispatcher.execute, (leafCommands, leafInputs))
            });
            calls[2] = CallLib.build({
                to: OPEN_USDT_ADDRESS, value: 0, data: abi.encodeCall(ERC20.approve, (address(leafRouter), 0))
            });
        }

        bytes32 commitment = hashCommitment({_calls: calls, _salt: salt});
        address payable userICA = _predictUserICA(salt);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_IN)), bytes1(uint8(Commands.QUOTED_CALLS)));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(ActionConstants.ADDRESS_THIS, amountIn, originAmountOutMin, _v3OpToBridgePath(), true, false);
        inputs[1] = _encodeOriginQuotedPlanFromRouterBalance(userICA, commitment, salt, MESSAGE_FEE, new bytes(0));

        deal(address(OP), users.alice, amountIn);
        OP.approve(address(router), amountIn);
        _expectCommitRevealCall(salt, commitment, new bytes(0));

        router.execute{value: MESSAGE_FEE * 2}(commands, inputs);

        assertEq(OP.balanceOf(userICA), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);

        vm.selectFork(leafId);
        leafMailbox.processNextInboundMessage();
        assertGe(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), originAmountOutMin);
        leafMailbox.processNextInboundMessage();
        assertTrue(OwnableMulticall(userICA).commitments(commitment));

        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(userICA).revealAndExecute({calls: calls, salt: salt});

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), 0);
        assertGt(ERC20(baseUSDC).balanceOf(users.alice), destinationAmountOutMin);
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(userICA, address(leafRouter)), 0);
    }

    function test_executeCrosschainFlowV2SwapExactIn_scoped() public {
        uint256 amountIn = USDC_1;
        uint256 amountOutMin = 9e5;
        bytes32 salt = TypeCasts.addressToBytes32(users.alice);

        bytes memory leafCommands;
        bytes[] memory leafInputs;
        {
            bytes memory swapSubplan = abi.encodePacked(bytes1(uint8(Commands.V2_SWAP_EXACT_IN)));
            bytes[] memory swapInputs = new bytes[](1);
            swapInputs[0] = abi.encode(users.alice, amountIn, amountOutMin, _v2BasePath(), true, false);

            bytes memory transferSubplan = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)));
            bytes[] memory transferInputs = new bytes[](1);
            transferInputs[0] = abi.encode(OPEN_USDT_ADDRESS, users.alice, Constants.TOTAL_BALANCE);

            leafCommands = abi.encodePacked(
                bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT,
                bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT
            );
            leafInputs = new bytes[](2);
            leafInputs[0] = abi.encode(swapSubplan, swapInputs);
            leafInputs[1] = abi.encode(transferSubplan, transferInputs);
        }

        CallLib.Call[] memory calls = new CallLib.Call[](2);
        calls[0] = CallLib.build({
            to: OPEN_USDT_ADDRESS, value: 0, data: abi.encodeCall(ERC20.approve, (address(leafRouter), amountIn))
        });
        calls[1] = CallLib.build({
            to: address(leafRouter), value: 0, data: abi.encodeCall(Dispatcher.execute, (leafCommands, leafInputs))
        });

        bytes32 commitment = hashCommitment({_calls: calls, _salt: salt});
        address payable userICA = _predictUserICA(salt);
        (bytes memory commands, bytes[] memory inputs) = _encodeOriginQuotedPlan(userICA, amountIn, amountIn, commitment, salt);

        deal(OPEN_USDT_ADDRESS, users.alice, amountIn);
        ERC20(OPEN_USDT_ADDRESS).approve(address(router), amountIn);
        _expectCommitRevealCall(salt, commitment, new bytes(0));

        router.execute{value: MESSAGE_FEE * 2}(commands, inputs);

        vm.selectFork(leafId);
        leafMailbox.processNextInboundMessage();
        leafMailbox.processNextInboundMessage();

        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(userICA).revealAndExecute({calls: calls, salt: salt});

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), 0);
        assertGt(ERC20(baseUSDC).balanceOf(users.alice), amountOutMin);
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(userICA, address(leafRouter)), 0);
    }

    function test_executeCrosschainFlowV2SwapExactOut_scoped() public {
        uint256 amountOut = 9e5;
        uint256 amountInMax = USDC_1;
        bytes32 salt = TypeCasts.addressToBytes32(users.alice);

        bytes memory leafCommands;
        bytes[] memory leafInputs;
        {
            bytes memory swapSubplan = abi.encodePacked(bytes1(uint8(Commands.V2_SWAP_EXACT_OUT)));
            bytes[] memory swapInputs = new bytes[](1);
            swapInputs[0] = abi.encode(users.alice, amountOut, amountInMax, _v2BasePath(), true, false);

            bytes memory transferSubplan = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)));
            bytes[] memory transferInputs = new bytes[](1);
            transferInputs[0] = abi.encode(OPEN_USDT_ADDRESS, users.alice, Constants.TOTAL_BALANCE);

            leafCommands = abi.encodePacked(
                bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT,
                bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT
            );
            leafInputs = new bytes[](2);
            leafInputs[0] = abi.encode(swapSubplan, swapInputs);
            leafInputs[1] = abi.encode(transferSubplan, transferInputs);
        }

        CallLib.Call[] memory calls = new CallLib.Call[](2);
        calls[0] = CallLib.build({
            to: OPEN_USDT_ADDRESS, value: 0, data: abi.encodeCall(ERC20.approve, (address(leafRouter), amountInMax))
        });
        calls[1] = CallLib.build({
            to: address(leafRouter), value: 0, data: abi.encodeCall(Dispatcher.execute, (leafCommands, leafInputs))
        });

        bytes32 commitment = hashCommitment({_calls: calls, _salt: salt});
        address payable userICA = _predictUserICA(salt);
        (bytes memory commands, bytes[] memory inputs) =
            _encodeOriginQuotedPlan(userICA, amountInMax, amountInMax, commitment, salt);

        deal(OPEN_USDT_ADDRESS, users.alice, amountInMax);
        ERC20(OPEN_USDT_ADDRESS).approve(address(router), amountInMax);
        _expectCommitRevealCall(salt, commitment, new bytes(0));

        router.execute{value: MESSAGE_FEE * 2}(commands, inputs);

        vm.selectFork(leafId);
        leafMailbox.processNextInboundMessage();
        leafMailbox.processNextInboundMessage();

        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(userICA).revealAndExecute({calls: calls, salt: salt});

        assertEq(ERC20(baseUSDC).balanceOf(users.alice), amountOut);
        assertGt(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(userICA, address(leafRouter)), 0);
    }

    function test_executeCrosschainFallback_scoped() public {
        uint256 amountIn = USDC_1;
        uint256 amountOutMin = amountIn * 10;
        bytes32 salt = TypeCasts.addressToBytes32(users.alice);

        bytes memory leafCommands;
        bytes[] memory leafInputs;
        {
            bytes memory swapSubplan = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_IN)));
            bytes[] memory swapInputs = new bytes[](1);
            swapInputs[0] = abi.encode(users.alice, amountIn, amountOutMin, _v3BasePath(), true, false);

            bytes memory transferSubplan = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)));
            bytes[] memory transferInputs = new bytes[](1);
            transferInputs[0] = abi.encode(OPEN_USDT_ADDRESS, users.alice, Constants.TOTAL_BALANCE);

            leafCommands = abi.encodePacked(
                bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT,
                bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT
            );
            leafInputs = new bytes[](2);
            leafInputs[0] = abi.encode(swapSubplan, swapInputs);
            leafInputs[1] = abi.encode(transferSubplan, transferInputs);
        }

        CallLib.Call[] memory calls = new CallLib.Call[](2);
        calls[0] = CallLib.build({
            to: OPEN_USDT_ADDRESS, value: 0, data: abi.encodeCall(ERC20.approve, (address(leafRouter), amountIn))
        });
        calls[1] = CallLib.build({
            to: address(leafRouter), value: 0, data: abi.encodeCall(Dispatcher.execute, (leafCommands, leafInputs))
        });

        bytes32 commitment = hashCommitment({_calls: calls, _salt: salt});
        address payable userICA = _predictUserICA(salt);
        (bytes memory commands, bytes[] memory inputs) = _encodeOriginQuotedPlan(userICA, amountIn, amountIn, commitment, salt);

        deal(OPEN_USDT_ADDRESS, users.alice, amountIn);
        ERC20(OPEN_USDT_ADDRESS).approve(address(router), amountIn);
        _expectCommitRevealCall(salt, commitment, new bytes(0));

        router.execute{value: MESSAGE_FEE * 2}(commands, inputs);

        vm.selectFork(leafId);
        leafMailbox.processNextInboundMessage();
        leafMailbox.processNextInboundMessage();

        vm.expectEmit(OPEN_USDT_ADDRESS);
        emit ERC20.Transfer({from: userICA, to: users.alice, amount: amountIn});
        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(userICA).revealAndExecute({calls: calls, salt: salt});

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), amountIn);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);
        assertEq(ERC20(baseUSDC).balanceOf(users.alice), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(userICA, address(leafRouter)), 0);
    }

    function test_executeCrosschainFlowMultichainV2SwapExactIn_scoped() public {
        uint256 destinationAmountOutMin = 100000;
        uint256 amountIn = 10 * USDC_1;
        uint256 originAmountOutMin = 100000;
        bytes32 salt = TypeCasts.addressToBytes32(users.alice);
        CrosschainContext memory ctx =
            _buildMultichainV2ExactInContext(amountIn, originAmountOutMin, destinationAmountOutMin, MESSAGE_FEE, 0);

        deal(address(USDT), users.alice, amountIn);
        USDT.approve(address(router), amountIn);
        _expectCommitRevealCall(salt, ctx.commitment, new bytes(0));

        router.execute{value: MESSAGE_FEE * 2}(ctx.commands, ctx.inputs);

        assertEq(USDT.balanceOf(ctx.userICA), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(ctx.userICA), 0);

        vm.selectFork(leafId);
        leafMailbox.processNextInboundMessage();
        assertGe(ERC20(OPEN_USDT_ADDRESS).balanceOf(ctx.userICA), originAmountOutMin);
        leafMailbox.processNextInboundMessage();
        assertTrue(OwnableMulticall(ctx.userICA).commitments(ctx.commitment));

        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(ctx.userICA).revealAndExecute({calls: ctx.calls, salt: salt});

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(ctx.userICA), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), 0);
        assertGt(ERC20(baseUSDC).balanceOf(users.alice), destinationAmountOutMin);
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(ctx.userICA, address(leafRouter)), 0);
    }

    function test_executeCrosschainFlowMixedV3ExactInV2ExactIn_scoped() public {
        uint256 v3AmountIn = USDC_1;
        uint256 v3AmountOutMin = 999000;
        uint256 v2AmountOutMin = 3e13;
        bytes32 salt = TypeCasts.addressToBytes32(users.alice);
        CrosschainContext memory ctx =
            _buildMixedV3ExactInV2ExactInContext(v3AmountIn, v3AmountOutMin, v2AmountOutMin, salt);

        deal(OPEN_USDT_ADDRESS, users.alice, v3AmountIn);
        ERC20(OPEN_USDT_ADDRESS).approve(address(router), v3AmountIn);
        _expectCommitRevealCall(salt, ctx.commitment, new bytes(0));

        router.execute{value: MESSAGE_FEE * 2}(ctx.commands, ctx.inputs);

        vm.selectFork(leafId);
        _warpBaseUsdcWethPool();
        leafMailbox.processNextInboundMessage();
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(ctx.userICA), v3AmountIn);
        leafMailbox.processNextInboundMessage();
        assertTrue(OwnableMulticall(ctx.userICA).commitments(ctx.commitment));

        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(ctx.userICA).revealAndExecute({calls: ctx.calls, salt: salt});

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(address(leafRouter)), 0);
        assertEq(ERC20(baseUSDC).balanceOf(address(leafRouter)), 0);
        assertEq(ERC20(WETH9_ADDRESS).balanceOf(address(leafRouter)), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(ctx.userICA), 0);
        assertEq(ERC20(baseUSDC).balanceOf(ctx.userICA), 0);
        assertEq(ERC20(WETH9_ADDRESS).balanceOf(ctx.userICA), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), 0);
        assertApproxEqAbs(ERC20(baseUSDC).balanceOf(users.alice), 0, 1e3);
        assertGe(ERC20(WETH9_ADDRESS).balanceOf(users.alice), v2AmountOutMin);
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(ctx.userICA, address(leafRouter)), 0);
    }

    function test_executeCrosschainFlowMixedV3ExactInV2ExactInFirstSwapRevert_scoped() public {
        uint256 v3AmountIn = USDC_1;
        uint256 v3AmountOutMin = 999000 * 2;
        uint256 v2AmountOutMin = 606500898800000;
        bytes32 salt = TypeCasts.addressToBytes32(users.alice);
        CrosschainContext memory ctx =
            _buildMixedV3ExactInV2ExactInContext(v3AmountIn, v3AmountOutMin, v2AmountOutMin, salt);

        deal(OPEN_USDT_ADDRESS, users.alice, v3AmountIn);
        ERC20(OPEN_USDT_ADDRESS).approve(address(router), v3AmountIn);
        _expectCommitRevealCall(salt, ctx.commitment, new bytes(0));

        router.execute{value: MESSAGE_FEE * 2}(ctx.commands, ctx.inputs);

        vm.selectFork(leafId);
        _warpBaseUsdcWethPool();
        leafMailbox.processNextInboundMessage();
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(ctx.userICA), v3AmountIn);
        leafMailbox.processNextInboundMessage();
        assertTrue(OwnableMulticall(ctx.userICA).commitments(ctx.commitment));

        vm.expectEmit(OPEN_USDT_ADDRESS);
        emit ERC20.Transfer({from: ctx.userICA, to: users.alice, amount: v3AmountIn});
        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(ctx.userICA).revealAndExecute({calls: ctx.calls, salt: salt});

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(address(leafRouter)), 0);
        assertEq(ERC20(baseUSDC).balanceOf(address(leafRouter)), 0);
        assertEq(ERC20(WETH9_ADDRESS).balanceOf(address(leafRouter)), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(ctx.userICA), 0);
        assertEq(ERC20(baseUSDC).balanceOf(ctx.userICA), 0);
        assertEq(ERC20(WETH9_ADDRESS).balanceOf(ctx.userICA), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), v3AmountIn);
        assertEq(ERC20(baseUSDC).balanceOf(users.alice), 0);
        assertEq(ERC20(WETH9_ADDRESS).balanceOf(users.alice), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(ctx.userICA, address(leafRouter)), 0);
    }

    function test_executeCrosschainFlowMixedV3ExactInV2ExactInSecondSwapRevert_scoped() public {
        uint256 v3AmountIn = USDC_1;
        uint256 v3AmountOutMin = 999000;
        uint256 v2AmountOutMin = 606500898800000 * 2;
        bytes32 salt = TypeCasts.addressToBytes32(users.alice);
        CrosschainContext memory ctx =
            _buildMixedV3ExactInV2ExactInContext(v3AmountIn, v3AmountOutMin, v2AmountOutMin, salt);

        deal(OPEN_USDT_ADDRESS, users.alice, v3AmountIn);
        ERC20(OPEN_USDT_ADDRESS).approve(address(router), v3AmountIn);
        _expectCommitRevealCall(salt, ctx.commitment, new bytes(0));

        router.execute{value: MESSAGE_FEE * 2}(ctx.commands, ctx.inputs);

        vm.selectFork(leafId);
        _warpBaseUsdcWethPool();
        leafMailbox.processNextInboundMessage();
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(ctx.userICA), v3AmountIn);
        leafMailbox.processNextInboundMessage();
        assertTrue(OwnableMulticall(ctx.userICA).commitments(ctx.commitment));

        vm.expectEmit(OPEN_USDT_ADDRESS);
        emit ERC20.Transfer({from: ctx.userICA, to: users.alice, amount: v3AmountIn});
        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(ctx.userICA).revealAndExecute({calls: ctx.calls, salt: salt});

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(address(leafRouter)), 0);
        assertEq(ERC20(baseUSDC).balanceOf(address(leafRouter)), 0);
        assertEq(ERC20(WETH9_ADDRESS).balanceOf(address(leafRouter)), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(ctx.userICA), 0);
        assertEq(ERC20(baseUSDC).balanceOf(ctx.userICA), 0);
        assertEq(ERC20(WETH9_ADDRESS).balanceOf(ctx.userICA), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), v3AmountIn);
        assertEq(ERC20(baseUSDC).balanceOf(users.alice), 0);
        assertEq(ERC20(WETH9_ADDRESS).balanceOf(users.alice), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(ctx.userICA, address(leafRouter)), 0);
    }

    function test_executeCrosschainFlowV3SwapExactInETHRefund_scoped() public {
        uint256 amountIn = USDC_1;
        uint256 amountOutMin = 9e5;
        uint256 leftoverETH = MESSAGE_FEE / 2;
        bytes32 salt = TypeCasts.addressToBytes32(users.alice);
        CrosschainContext memory ctx = _buildExactInEthRefundContext(amountIn, amountOutMin, leftoverETH, salt);

        uint256 oldETHBal = users.alice.balance;

        deal(OPEN_USDT_ADDRESS, users.alice, amountIn);
        ERC20(OPEN_USDT_ADDRESS).approve(address(router), amountIn);
        _expectCommitRevealCall(salt, ctx.commitment, ctx.hookMetadata);

        router.execute{value: MESSAGE_FEE * 2 + leftoverETH}(ctx.commands, ctx.inputs);

        assertEq(address(router).balance, 0);
        assertEq(address(rootIcaRouter).balance, 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(ctx.userICA), 0);
        assertApproxEqAbs(users.alice.balance, oldETHBal - (MESSAGE_FEE + leftoverETH), 1e14);

        vm.selectFork(leafId);
        leafMailbox.processNextInboundMessage();
        leafMailbox.processNextInboundMessage();

        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(ctx.userICA).revealAndExecute({calls: ctx.calls, salt: salt});

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(ctx.userICA), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), 0);
        assertGt(ERC20(baseUSDC).balanceOf(users.alice), amountOutMin);
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(ctx.userICA, address(leafRouter)), 0);
    }

    function test_executeCrosschainICARefund_scoped() public {
        uint256 amount = USDC_1;
        bytes32 salt = TypeCasts.addressToBytes32(users.alice);
        address payable userICA = _predictUserICA(salt);

        {
            bytes memory bridgeCommands = abi.encodePacked(bytes1(uint8(Commands.QUOTED_CALLS)));
            bytes[] memory bridgeInputs = new bytes[](1);
            bytes memory quotedCommands = abi.encodePacked(bytes1(uint8(QuotedCallsCommands.TRANSFER_REMOTE)));
            bytes[] memory quotedInputs = new bytes[](1);
            quotedInputs[0] = abi.encode(
                OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
                leafDomain,
                TypeCasts.addressToBytes32(userICA),
                amount,
                MESSAGE_FEE,
                OPEN_USDT_ADDRESS,
                amount
            );
            bridgeInputs[0] = abi.encodeCall(QuotedCalls.execute, (quotedCommands, quotedInputs));

            deal(OPEN_USDT_ADDRESS, users.alice, amount);
            ERC20(OPEN_USDT_ADDRESS).approve(address(router), amount);
            router.execute{value: MESSAGE_FEE}(bridgeCommands, bridgeInputs);
        }

        vm.selectFork(leafId);
        leafMailbox.processNextInboundMessage();
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), amount);

        vm.selectFork(rootId);

        CallLib.Call[] memory calls = new CallLib.Call[](1);
        calls[0] = CallLib.build({
            to: OPEN_USDT_ADDRESS, value: 0, data: abi.encodeCall(ERC20.transfer, (users.alice, amount))
        });

        bytes32 commitment = hashCommitment({_calls: calls, _salt: salt});
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.QUOTED_CALLS)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeCommitRevealOnlyPlan(commitment, salt, MESSAGE_FEE, new bytes(0));

        _expectCommitRevealCall(salt, commitment, new bytes(0));
        router.execute{value: MESSAGE_FEE}(commands, inputs);

        vm.selectFork(leafId);
        leafMailbox.processNextInboundMessage();
        assertTrue(OwnableMulticall(userICA).commitments(commitment));

        vm.expectEmit(OPEN_USDT_ADDRESS);
        emit ERC20.Transfer({from: userICA, to: users.alice, amount: amount});
        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(userICA).revealAndExecute({calls: calls, salt: salt});

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), amount);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);
    }

    function test_RevertWhen_executeCrosschainInsufficientFee_scoped() public {
        CrosschainContext memory ctx = _buildMultichainExactInContext(10 ether, 8e5, 9e5, MESSAGE_FEE, 0);

        deal(address(OP), users.alice, 10 ether);
        OP.approve(address(router), 10 ether);
        vm.expectRevert();
        router.execute{value: MESSAGE_FEE}(ctx.commands, ctx.inputs);
    }

    function test_RevertWhen_executeCrosschainFeeGreaterThanContractBalance_scoped() public {
        CrosschainContext memory ctx = _buildMultichainExactInContext(10 ether, 8e5, 9e5, MESSAGE_FEE, 0);

        deal(address(OP), users.alice, 10 ether);
        OP.approve(address(router), 10 ether);
        vm.expectRevert();
        router.execute{value: MESSAGE_FEE}(ctx.commands, ctx.inputs);
    }

    function testGas_executeCrosschainOriginSuccess_scoped() public {
        uint256 leftoverEth = MESSAGE_FEE / 2;
        CrosschainContext memory ctx = _buildMultichainExactInContext(10 ether, 8e5, 9e5, MESSAGE_FEE, leftoverEth);

        deal(address(OP), users.alice, 10 ether);
        OP.approve(address(router), 10 ether);
        router.execute{value: MESSAGE_FEE * 2 + leftoverEth}(ctx.commands, ctx.inputs);
        vm.snapshotGasLastCall('UniversalRouter_ExecuteCrossChain_Origin_Success');
    }

    function testGas_executeCrosschainOriginFallback_scoped() public {
        uint256 leftoverEth = MESSAGE_FEE / 2;
        CrosschainContext memory ctx =
            _buildMultichainExactInContext(10 ether, 8e5, 100 ether, MESSAGE_FEE, leftoverEth);

        deal(address(OP), users.alice, 10 ether);
        OP.approve(address(router), 10 ether);
        router.execute{value: MESSAGE_FEE * 2 + leftoverEth}(ctx.commands, ctx.inputs);
        vm.snapshotGasLastCall('UniversalRouter_ExecuteCrossChain_Origin_Fallback');
    }

    function testGas_executeCrosschainDestinationSuccess_scoped() public {
        uint256 leftoverEth = MESSAGE_FEE / 2;
        bytes32 salt = TypeCasts.addressToBytes32(users.alice);
        CrosschainContext memory ctx = _buildMultichainExactInContext(10 ether, 8e5, 9e5, MESSAGE_FEE, leftoverEth);

        deal(address(OP), users.alice, 10 ether);
        OP.approve(address(router), 10 ether);
        router.execute{value: MESSAGE_FEE * 2 + leftoverEth}(ctx.commands, ctx.inputs);

        vm.selectFork(leafId);
        leafMailbox.processNextInboundMessage();
        leafMailbox.processNextInboundMessage();

        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(ctx.userICA).revealAndExecute({calls: ctx.calls, salt: salt});
        vm.snapshotGasLastCall('UniversalRouter_ExecuteCrossChain_Destination_Success');
    }

    function testGas_executeCrosschainDestinationFallback_scoped() public {
        uint256 leftoverEth = MESSAGE_FEE / 2;
        bytes32 salt = TypeCasts.addressToBytes32(users.alice);
        CrosschainContext memory ctx =
            _buildMultichainExactInContext(10 ether, 8e5, 100 ether, MESSAGE_FEE, leftoverEth);

        deal(address(OP), users.alice, 10 ether);
        OP.approve(address(router), 10 ether);
        router.execute{value: MESSAGE_FEE * 2 + leftoverEth}(ctx.commands, ctx.inputs);

        vm.selectFork(leafId);
        leafMailbox.processNextInboundMessage();
        leafMailbox.processNextInboundMessage();

        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(ctx.userICA).revealAndExecute({calls: ctx.calls, salt: salt});
        vm.snapshotGasLastCall('UniversalRouter_ExecuteCrossChain_Destination_Fallback');
    }

    function _buildLeafSingleSwapFallbackPlan(uint256 swapCommand, bytes memory swapInput)
        internal
        view
        returns (bytes memory leafCommands, bytes[] memory leafInputs)
    {
        bytes memory swapSubplan = abi.encodePacked(bytes1(uint8(swapCommand)));
        bytes[] memory swapInputs = new bytes[](1);
        swapInputs[0] = swapInput;

        bytes memory transferSubplan = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)));
        bytes[] memory transferInputs = new bytes[](1);
        transferInputs[0] = abi.encode(OPEN_USDT_ADDRESS, users.alice, Constants.TOTAL_BALANCE);

        leafCommands = abi.encodePacked(
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT,
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT
        );
        leafInputs = new bytes[](2);
        leafInputs[0] = abi.encode(swapSubplan, swapInputs);
        leafInputs[1] = abi.encode(transferSubplan, transferInputs);
    }

    function _buildApproveAndExecuteCalls(uint256 amountIn, bytes memory leafCommands, bytes[] memory leafInputs)
        internal
        view
        returns (CallLib.Call[] memory calls)
    {
        calls = new CallLib.Call[](2);
        calls[0] = CallLib.build({
            to: OPEN_USDT_ADDRESS, value: 0, data: abi.encodeCall(ERC20.approve, (address(leafRouter), amountIn))
        });
        calls[1] = CallLib.build({
            to: address(leafRouter), value: 0, data: abi.encodeCall(Dispatcher.execute, (leafCommands, leafInputs))
        });
    }

    function _buildExactInEthRefundContext(uint256 amountIn, uint256 amountOutMin, uint256 leftoverETH, bytes32 salt)
        internal
        view
        returns (CrosschainContext memory ctx)
    {
        (bytes memory leafCommands, bytes[] memory leafInputs) = _buildLeafSingleSwapFallbackPlan({
            swapCommand: Commands.V3_SWAP_EXACT_IN,
            swapInput: abi.encode(users.alice, amountIn, amountOutMin, _v3BasePath(), true, false)
        });
        ctx.calls = _buildApproveAndExecuteCalls(amountIn, leafCommands, leafInputs);
        ctx.commitment = hashCommitment({_calls: ctx.calls, _salt: salt});
        ctx.userICA = _predictUserICA(salt);
        ctx.hookMetadata = StandardHookMetadata.formatMetadata({
            _msgValue: uint256(0),
            _gasLimit: HypXERC20(OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS).destinationGas(rootDomain),
            _refundAddress: users.alice,
            _customMetadata: ''
        });
        ctx.commands = abi.encodePacked(bytes1(uint8(Commands.QUOTED_CALLS)));
        ctx.inputs = new bytes[](1);
        ctx.inputs[0] = _encodeOriginQuotedPlanWithHookMetadata(
            ctx.userICA, amountIn, amountIn, ctx.commitment, salt, MESSAGE_FEE + leftoverETH, ctx.hookMetadata
        );
    }

    function _buildMultichainExactInContext(
        uint256 amountIn,
        uint256 originAmountOutMin,
        uint256 destinationAmountOutMin,
        uint256 msgFee,
        uint256 leftoverEth
    ) internal view returns (CrosschainContext memory ctx) {
        bytes32 salt = TypeCasts.addressToBytes32(users.alice);
        (bytes memory leafCommands, bytes[] memory leafInputs) =
            _buildLeafMultichainV3ExactInPlan(destinationAmountOutMin);

        ctx.calls = new CallLib.Call[](3);
        ctx.calls[0] = CallLib.build({
            to: OPEN_USDT_ADDRESS,
            value: 0,
            data: abi.encodeCall(ERC20.approve, (address(leafRouter), type(uint256).max))
        });
        ctx.calls[1] = CallLib.build({
            to: address(leafRouter), value: 0, data: abi.encodeCall(Dispatcher.execute, (leafCommands, leafInputs))
        });
        ctx.calls[2] = CallLib.build({
            to: OPEN_USDT_ADDRESS, value: 0, data: abi.encodeCall(ERC20.approve, (address(leafRouter), 0))
        });

        ctx.commitment = hashCommitment({_calls: ctx.calls, _salt: salt});
        ctx.userICA = _predictUserICA(salt);
        ctx.commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_IN)), bytes1(uint8(Commands.QUOTED_CALLS)));
        ctx.inputs = new bytes[](2);
        ctx.inputs[0] = abi.encode(ActionConstants.ADDRESS_THIS, amountIn, originAmountOutMin, _v3OpToBridgePath(), true, false);
        ctx.inputs[1] =
            _encodeOriginQuotedPlanFromRouterBalance(ctx.userICA, ctx.commitment, salt, msgFee + leftoverEth, new bytes(0));
    }

    function _buildMultichainV2ExactInContext(
        uint256 amountIn,
        uint256 originAmountOutMin,
        uint256 destinationAmountOutMin,
        uint256 msgFee,
        uint256 leftoverEth
    ) internal view returns (CrosschainContext memory ctx) {
        bytes32 salt = TypeCasts.addressToBytes32(users.alice);
        (bytes memory leafCommands, bytes[] memory leafInputs) =
            _buildLeafMultichainV2ExactInPlan(destinationAmountOutMin);

        ctx.calls = new CallLib.Call[](3);
        ctx.calls[0] = CallLib.build({
            to: OPEN_USDT_ADDRESS,
            value: 0,
            data: abi.encodeCall(ERC20.approve, (address(leafRouter), type(uint256).max))
        });
        ctx.calls[1] = CallLib.build({
            to: address(leafRouter), value: 0, data: abi.encodeCall(Dispatcher.execute, (leafCommands, leafInputs))
        });
        ctx.calls[2] = CallLib.build({
            to: OPEN_USDT_ADDRESS, value: 0, data: abi.encodeCall(ERC20.approve, (address(leafRouter), 0))
        });

        ctx.commitment = hashCommitment({_calls: ctx.calls, _salt: salt});
        ctx.userICA = _predictUserICA(salt);
        ctx.commands = abi.encodePacked(bytes1(uint8(Commands.V2_SWAP_EXACT_IN)), bytes1(uint8(Commands.QUOTED_CALLS)));
        ctx.inputs = new bytes[](2);
        ctx.inputs[0] =
            abi.encode(ActionConstants.ADDRESS_THIS, amountIn, originAmountOutMin, _v2UsdtToBridgePath(), true, false);
        ctx.inputs[1] =
            _encodeOriginQuotedPlanFromRouterBalance(ctx.userICA, ctx.commitment, salt, msgFee + leftoverEth, new bytes(0));
    }

    function _buildLeafMultichainV3ExactInPlan(uint256 destinationAmountOutMin)
        internal
        view
        returns (bytes memory leafCommands, bytes[] memory leafInputs)
    {
        bytes memory swapSubplan =
            abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)), bytes1(uint8(Commands.V3_SWAP_EXACT_IN)));
        bytes[] memory swapInputs = new bytes[](2);
        swapInputs[0] = abi.encode(OPEN_USDT_ADDRESS, address(leafRouter), Constants.TOTAL_BALANCE);
        swapInputs[1] =
            abi.encode(users.alice, ActionConstants.CONTRACT_BALANCE, destinationAmountOutMin, _v3BasePath(), false, false);

        bytes memory transferSubplan = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)));
        bytes[] memory transferInputs = new bytes[](1);
        transferInputs[0] = abi.encode(OPEN_USDT_ADDRESS, users.alice, Constants.TOTAL_BALANCE);

        leafCommands = abi.encodePacked(
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT,
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT
        );
        leafInputs = new bytes[](2);
        leafInputs[0] = abi.encode(swapSubplan, swapInputs);
        leafInputs[1] = abi.encode(transferSubplan, transferInputs);
    }

    function _buildLeafMultichainV2ExactInPlan(uint256 destinationAmountOutMin)
        internal
        view
        returns (bytes memory leafCommands, bytes[] memory leafInputs)
    {
        bytes memory swapSubplan =
            abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)), bytes1(uint8(Commands.V2_SWAP_EXACT_IN)));
        bytes[] memory swapInputs = new bytes[](2);
        swapInputs[0] = abi.encode(OPEN_USDT_ADDRESS, address(leafRouter), Constants.TOTAL_BALANCE);
        swapInputs[1] =
            abi.encode(users.alice, ActionConstants.CONTRACT_BALANCE, destinationAmountOutMin, _v2BasePath(), false, false);

        bytes memory transferSubplan = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)));
        bytes[] memory transferInputs = new bytes[](1);
        transferInputs[0] = abi.encode(OPEN_USDT_ADDRESS, users.alice, Constants.TOTAL_BALANCE);

        leafCommands = abi.encodePacked(
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT,
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT
        );
        leafInputs = new bytes[](2);
        leafInputs[0] = abi.encode(swapSubplan, swapInputs);
        leafInputs[1] = abi.encode(transferSubplan, transferInputs);
    }

    function _buildMixedV3ExactInV2ExactInContext(
        uint256 v3AmountIn,
        uint256 v3AmountOutMin,
        uint256 v2AmountOutMin,
        bytes32 salt
    ) internal view returns (CrosschainContext memory ctx) {
        bytes memory leafCommands;
        bytes[] memory leafInputs;
        {
            bytes memory swapSubplan = abi.encodePacked(
                bytes1(uint8(Commands.V3_SWAP_EXACT_IN)),
                bytes1(uint8(Commands.V2_SWAP_EXACT_IN)),
                bytes1(uint8(Commands.SWEEP))
            );
            bytes[] memory swapInputs = new bytes[](3);
            swapInputs[0] =
                abi.encode(ActionConstants.ADDRESS_THIS, v3AmountIn, v3AmountOutMin, _v3BasePath(), true, false);
            swapInputs[1] = abi.encode(
                users.alice, ActionConstants.CONTRACT_BALANCE, v2AmountOutMin, _v2BaseUsdcWethPath(), false, false
            );
            swapInputs[2] = abi.encode(baseUSDC, users.alice, 0);

            bytes memory transferSubplan = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)));
            bytes[] memory transferInputs = new bytes[](1);
            transferInputs[0] = abi.encode(OPEN_USDT_ADDRESS, users.alice, Constants.TOTAL_BALANCE);

            leafCommands = abi.encodePacked(
                bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT,
                bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT
            );
            leafInputs = new bytes[](2);
            leafInputs[0] = abi.encode(swapSubplan, swapInputs);
            leafInputs[1] = abi.encode(transferSubplan, transferInputs);
        }

        ctx.calls = _buildApproveAndExecuteCalls(v3AmountIn, leafCommands, leafInputs);
        ctx.commitment = hashCommitment({_calls: ctx.calls, _salt: salt});
        ctx.userICA = _predictUserICA(salt);
        (ctx.commands, ctx.inputs) = _encodeOriginQuotedPlan(ctx.userICA, v3AmountIn, v3AmountIn, ctx.commitment, salt);
    }

    function test_revertWhen_quotedCallsNestedInSubplan() public {
        bytes memory quotedCommands = abi.encodePacked(bytes1(uint8(QuotedCallsCommands.CALL_REMOTE_COMMIT_REVEAL)));
        bytes[] memory quotedInputs = new bytes[](1);
        quotedInputs[0] = abi.encode(
            address(rootIcaRouter),
            leafDomain,
            rootIcaRouter.routers(leafDomain),
            bytes32(0),
            new bytes(0),
            address(rootIcaRouter.hook()),
            bytes32(0),
            bytes32(0),
            MESSAGE_FEE,
            address(0),
            uint256(0)
        );

        bytes memory nestedCommands = abi.encodePacked(bytes1(uint8(Commands.QUOTED_CALLS)));
        bytes[] memory nestedInputs = new bytes[](1);
        nestedInputs[0] = abi.encodeCall(QuotedCalls.execute, (quotedCommands, quotedInputs));

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.EXECUTE_SUB_PLAN)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(nestedCommands, nestedInputs);

        vm.expectRevert();
        router.execute{value: MESSAGE_FEE}(commands, inputs);
    }

    function _encodeOriginQuotedPlan(
        address userICA,
        uint256 bridgeAmount,
        uint256 bridgeApproval,
        bytes32 commitment,
        bytes32 salt
    ) internal view returns (bytes memory commands, bytes[] memory inputs) {
        bytes memory quotedCommands = abi.encodePacked(
            bytes1(uint8(QuotedCallsCommands.TRANSFER_REMOTE)),
            bytes1(uint8(QuotedCallsCommands.CALL_REMOTE_COMMIT_REVEAL))
        );
        bytes[] memory quotedInputs = new bytes[](2);
        quotedInputs[0] = abi.encode(
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            leafDomain,
            TypeCasts.addressToBytes32(userICA),
            bridgeAmount,
            MESSAGE_FEE,
            OPEN_USDT_ADDRESS,
            bridgeApproval
        );
        quotedInputs[1] = abi.encode(
            address(rootIcaRouter),
            leafDomain,
            rootIcaRouter.routers(leafDomain),
            bytes32(0),
            new bytes(0),
            address(rootIcaRouter.hook()),
            salt,
            commitment,
            MESSAGE_FEE,
            address(0),
            uint256(0)
        );

        commands = abi.encodePacked(bytes1(uint8(Commands.QUOTED_CALLS)));
        inputs = new bytes[](1);
        inputs[0] = abi.encodeCall(QuotedCalls.execute, (quotedCommands, quotedInputs));
    }

    function _encodeOriginQuotedPlanFromRouterBalance(
        address userICA,
        bytes32 commitment,
        bytes32 salt,
        uint256 commitValue,
        bytes memory hookMetadata
    ) internal view returns (bytes memory) {
        bytes memory quotedCommands = abi.encodePacked(
            bytes1(uint8(QuotedCallsCommands.TRANSFER_REMOTE)),
            bytes1(uint8(QuotedCallsCommands.CALL_REMOTE_COMMIT_REVEAL))
        );
        bytes[] memory quotedInputs = new bytes[](2);
        quotedInputs[0] = abi.encode(
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            leafDomain,
            TypeCasts.addressToBytes32(userICA),
            QUOTED_CALLS_CONTRACT_BALANCE,
            MESSAGE_FEE,
            OPEN_USDT_ADDRESS,
            QUOTED_CALLS_CONTRACT_BALANCE
        );
        quotedInputs[1] = abi.encode(
            address(rootIcaRouter),
            leafDomain,
            rootIcaRouter.routers(leafDomain),
            bytes32(0),
            hookMetadata,
            address(rootIcaRouter.hook()),
            salt,
            commitment,
            commitValue,
            address(0),
            uint256(0)
        );
        return abi.encodeCall(QuotedCalls.execute, (quotedCommands, quotedInputs));
    }

    function _encodeOriginQuotedPlanWithHookMetadata(
        address userICA,
        uint256 bridgeAmount,
        uint256 bridgeApproval,
        bytes32 commitment,
        bytes32 salt,
        uint256 commitValue,
        bytes memory hookMetadata
    ) internal view returns (bytes memory) {
        bytes memory quotedCommands = abi.encodePacked(
            bytes1(uint8(QuotedCallsCommands.TRANSFER_REMOTE)),
            bytes1(uint8(QuotedCallsCommands.CALL_REMOTE_COMMIT_REVEAL))
        );
        bytes[] memory quotedInputs = new bytes[](2);
        quotedInputs[0] = abi.encode(
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            leafDomain,
            TypeCasts.addressToBytes32(userICA),
            bridgeAmount,
            MESSAGE_FEE,
            OPEN_USDT_ADDRESS,
            bridgeApproval
        );
        quotedInputs[1] = abi.encode(
            address(rootIcaRouter),
            leafDomain,
            rootIcaRouter.routers(leafDomain),
            bytes32(0),
            hookMetadata,
            address(rootIcaRouter.hook()),
            salt,
            commitment,
            commitValue,
            address(0),
            uint256(0)
        );
        return abi.encodeCall(QuotedCalls.execute, (quotedCommands, quotedInputs));
    }

    function _encodeCommitRevealOnlyPlan(
        bytes32 commitment,
        bytes32 salt,
        uint256 commitValue,
        bytes memory hookMetadata
    ) internal view returns (bytes memory) {
        bytes memory quotedCommands = abi.encodePacked(bytes1(uint8(QuotedCallsCommands.CALL_REMOTE_COMMIT_REVEAL)));
        bytes[] memory quotedInputs = new bytes[](1);
        quotedInputs[0] = abi.encode(
            address(rootIcaRouter),
            leafDomain,
            rootIcaRouter.routers(leafDomain),
            bytes32(0),
            hookMetadata,
            address(rootIcaRouter.hook()),
            salt,
            commitment,
            commitValue,
            address(0),
            uint256(0)
        );
        return abi.encodeCall(QuotedCalls.execute, (quotedCommands, quotedInputs));
    }

    function _expectCommitRevealCall(bytes32 salt, bytes32 commitment, bytes memory hookMetadata) internal {
        vm.expectCall({
            callee: address(rootIcaRouter),
            data: abi.encodeCall(
                IInterchainAccountRouter.callRemoteCommitReveal,
                (
                    leafDomain,
                    rootIcaRouter.routers(leafDomain),
                    bytes32(0),
                    hookMetadata,
                    IPostDispatchHook(address(rootIcaRouter.hook())),
                    _scopedSalt(salt),
                    commitment
                )
            )
        });
    }

    function _predictUserICA(bytes32 salt) internal view returns (address payable) {
        return payable(
            rootIcaRouter.getRemoteInterchainAccount({
                _destination: leafDomain,
                _owner: address(router),
                _userSalt: _scopedSalt(salt)
            })
        );
    }

    function _scopedSalt(bytes32 salt) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(users.alice, salt));
    }

    function _v3BasePath() internal pure returns (bytes memory) {
        return abi.encodePacked(OPEN_USDT_ADDRESS, int24(1), baseUSDC);
    }

    function _v2BasePath() internal pure returns (bytes memory) {
        return abi.encodePacked(OPEN_USDT_ADDRESS, false, baseUSDC);
    }

    function _v3OpToBridgePath() internal pure returns (bytes memory) {
        return abi.encodePacked(address(OP), int24(100), OPEN_USDT_ADDRESS);
    }

    function _v2UsdtToBridgePath() internal pure returns (bytes memory) {
        return abi.encodePacked(address(USDT), true, OPEN_USDT_ADDRESS);
    }

    function _v2BaseUsdcWethPath() internal pure returns (bytes memory) {
        return abi.encodePacked(baseUSDC, false, WETH9_ADDRESS);
    }

    function _warpBaseUsdcWethPool() internal {
        IPool pool = IPool(v2Factory.getPool(baseUSDC, WETH9_ADDRESS, false));
        vm.warp(pool.blockTimestampLast() + 1);
    }

    function createAndSeedPair(address tokenA, address tokenB, bool stable) internal returns (address newPair) {
        newPair = IPoolFactory(address(v2Factory)).getPool(tokenA, tokenB, stable);
        if (newPair == address(0)) {
            newPair = IPoolFactory(address(v2Factory)).createPool(tokenA, tokenB, stable);
        }

        deal(tokenA, address(this), 100 * 10 ** ERC20(tokenA).decimals());
        deal(tokenB, address(this), 100 * 10 ** ERC20(tokenB).decimals());

        ERC20(tokenA).transfer(address(newPair), 100 * 10 ** ERC20(tokenA).decimals());
        ERC20(tokenB).transfer(address(newPair), 100 * 10 ** ERC20(tokenB).decimals());
        IPool(newPair).mint(address(this));
    }
}
