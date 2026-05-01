// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import {InterchainAccountRouter} from '@hyperlane/core/contracts/middleware/InterchainAccountRouter.sol';
import {StandardHookMetadata} from '@hyperlane/core/contracts/hooks/libs/StandardHookMetadata.sol';
import {IPostDispatchHook} from '@hyperlane/core/contracts/interfaces/hooks/IPostDispatchHook.sol';
import {OwnableMulticall} from '@hyperlane/core/contracts/middleware/libs/OwnableMulticall.sol';
import {TypeCasts} from '@hyperlane/core/contracts/libs/TypeCasts.sol';

import {Quote, ITokenFee} from '@hyperlane/core/contracts/interfaces/ITokenBridge.sol';

import {IInterchainAccountRouter} from 'contracts/interfaces/external/IInterchainAccountRouter.sol';
import {IRouterClient} from 'contracts/interfaces/external/IRouterClient.sol';
import {IUniversalRouter} from 'contracts/interfaces/IUniversalRouter.sol';
import {BridgeTypes} from 'contracts/libraries/BridgeTypes.sol';
import {RouterDeployParameters} from 'contracts/types/RouterDeployParameters.sol';

import {MockERC20} from '../../mock/MockERC20.sol';

import '../../BaseForkFixture.t.sol';

contract ExecuteCrossChainTest is BaseForkFixture {
    InterchainAccountRouter public rootIcaRouter;
    InterchainAccountRouter public leafIcaRouter;

    IPoolFactory public constant v2Factory = IPoolFactory(0x420DD381b31aEf6683db6B902084cB0FFECe40Da);
    address public constant baseUSDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @dev Fixed fee used for x-chain message quotes
    uint256 public constant MESSAGE_FEE = 1 ether / 10_000; // 0.0001 ETH

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

        // Encode destination swap
        bytes memory swapSubplan = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_IN)));
        bytes memory path = abi.encodePacked(OPEN_USDT_ADDRESS, int24(1), baseUSDC);
        bytes[] memory swapInputs = new bytes[](1);
        swapInputs[0] = abi.encode(users.alice, amountIn, amountOutMin, path, true, false);

        // Encode fallback transfer
        bytes memory transferSubplan = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)));
        bytes[] memory transferInputs = new bytes[](1);
        transferInputs[0] = abi.encode(OPEN_USDT_ADDRESS, users.alice, Constants.TOTAL_BALANCE);

        // Encode Sub Plan
        bytes memory leafCommands = abi.encodePacked(
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT,
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT
        );
        bytes[] memory leafInputs = new bytes[](2);
        leafInputs[0] = abi.encode(swapSubplan, swapInputs);
        leafInputs[1] = abi.encode(transferSubplan, transferInputs);

        // Encode ICA calls
        CallLib.Call[] memory calls = new CallLib.Call[](2);
        calls[0] = CallLib.build({
            to: OPEN_USDT_ADDRESS, value: 0, data: abi.encodeCall(ERC20.approve, (address(leafRouter), amountIn))
        });
        calls[1] = CallLib.build({
            to: address(leafRouter), value: 0, data: abi.encodeCall(Dispatcher.execute, (leafCommands, leafInputs))
        });

        // Calculate commitment hash
        bytes32 commitment = hashCommitment({_calls: calls, _salt: TypeCasts.addressToBytes32(users.alice)});

        // Predict User's ICA address
        address payable userICA = payable(rootIcaRouter.getRemoteInterchainAccount({
                _destination: leafDomain, _owner: address(router), _userSalt: TypeCasts.addressToBytes32(users.alice)
            }));

        // Encode origin chain commands
        bytes memory commands =
            abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN)), bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN)));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            userICA,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            amountIn,
            MESSAGE_FEE,
            0, // tokenFee
            leafDomain,
            true
        );
        inputs[1] = abi.encode(
            leafDomain, // destination domain
            address(rootIcaRouter), // origin ica router
            rootIcaRouter.routers(leafDomain), // destination ica router
            bytes32(0), // destination ism
            commitment, // commitment of the calls to be made
            MESSAGE_FEE, // fee to dispatch x-chain message
            address(0), // token
            0, // tokenFee
            rootIcaRouter.hook(), // post dispatch hook
            new bytes(0) // hook metadata
        );

        // Broadcast x-chain messages
        deal(OPEN_USDT_ADDRESS, users.alice, amountIn);
        ERC20(OPEN_USDT_ADDRESS).approve(address(router), amountIn);
        vm.expectCall({
            callee: address(rootIcaRouter),
            data: abi.encodeCall(
                IInterchainAccountRouter.callRemoteCommitReveal,
                (
                    leafDomain,
                    rootIcaRouter.routers(leafDomain),
                    bytes32(0),
                    new bytes(0),
                    IPostDispatchHook(address(rootIcaRouter.hook())),
                    TypeCasts.addressToBytes32(users.alice),
                    commitment
                )
            )
        });

        vm.expectEmit(address(router));
        emit Dispatcher.CrossChainSwap({
            caller: users.alice,
            localRouter: address(rootIcaRouter),
            destinationDomain: leafDomain,
            commitment: commitment
        });

        router.execute{value: MESSAGE_FEE * 2}(commands, inputs);

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);

        // Process Token Bridging message & check tokens arrived
        vm.selectFork(leafId);
        vm.expectEmit(address(leafMailbox));
        emit IMailbox.Process({
            origin: rootDomain,
            sender: TypeCasts.addressToBytes32(OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS),
            recipient: address(leafOpenUsdtTokenBridge)
        });
        leafMailbox.processNextInboundMessage();
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), amountIn);

        // Process Commitment message & check commitment was stored
        vm.expectEmit(address(leafMailbox));
        emit IMailbox.Process({
            origin: rootDomain,
            sender: TypeCasts.addressToBytes32(address(rootIcaRouter)),
            recipient: address(leafIcaRouter)
        });
        leafMailbox.processNextInboundMessage();
        assertTrue(OwnableMulticall(userICA).commitments(commitment));

        assertEq(ERC20(baseUSDC).balanceOf(users.alice), 0);

        // Self Relay the message & check swap was successful
        vm.expectEmit(address(leafRouter));
        emit Dispatcher.UniversalRouterSwap(userICA, users.alice);
        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(userICA).revealAndExecute({calls: calls, salt: TypeCasts.addressToBytes32(users.alice)});

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), 0); // no leftover input from swap in exactIn
        assertGt(ERC20(baseUSDC).balanceOf(users.alice), amountOutMin);
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(userICA, address(leafRouter)), 0);
    }

    function test_executeCrosschainFlowV3SwapExactOut() public {
        uint256 amountOut = 9e5;
        uint256 amountInMax = USDC_1;

        // Encode destination swap
        bytes memory swapSubplan = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_OUT)));
        bytes memory path = abi.encodePacked(baseUSDC, int24(1), OPEN_USDT_ADDRESS);
        bytes[] memory swapInputs = new bytes[](1);
        swapInputs[0] = abi.encode(users.alice, amountOut, amountInMax, path, true, false);

        // Encode fallback transfer
        bytes memory transferSubplan = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)));
        bytes[] memory transferInputs = new bytes[](1);
        transferInputs[0] = abi.encode(OPEN_USDT_ADDRESS, users.alice, Constants.TOTAL_BALANCE);

        // Encode Sub Plan
        bytes memory leafCommands = abi.encodePacked(
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT,
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT
        );
        bytes[] memory leafInputs = new bytes[](2);
        leafInputs[0] = abi.encode(swapSubplan, swapInputs);
        leafInputs[1] = abi.encode(transferSubplan, transferInputs);

        // Encode ICA calls
        CallLib.Call[] memory calls = new CallLib.Call[](2);
        calls[0] = CallLib.build({
            to: OPEN_USDT_ADDRESS, value: 0, data: abi.encodeCall(ERC20.approve, (address(leafRouter), amountInMax))
        });
        calls[1] = CallLib.build({
            to: address(leafRouter), value: 0, data: abi.encodeCall(Dispatcher.execute, (leafCommands, leafInputs))
        });

        // Calculate commitment hash
        bytes32 commitment = hashCommitment({_calls: calls, _salt: TypeCasts.addressToBytes32(users.alice)});

        // Predict User's ICA address
        address payable userICA = payable(rootIcaRouter.getRemoteInterchainAccount({
                _destination: leafDomain, _owner: address(router), _userSalt: TypeCasts.addressToBytes32(users.alice)
            }));

        // Encode origin chain commands
        bytes memory commands =
            abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN)), bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN)));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            userICA,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            amountInMax,
            MESSAGE_FEE,
            0, // tokenFee
            leafDomain,
            true
        );
        inputs[1] = abi.encode(
            leafDomain, // destination domain
            address(rootIcaRouter), // origin ica router
            rootIcaRouter.routers(leafDomain), // destination ica router
            bytes32(0), // destination ism
            commitment, // commitment of the calls to be made
            MESSAGE_FEE, // fee to dispatch x-chain message
            address(0), // token
            0, // tokenFee
            rootIcaRouter.hook(), // post dispatch hook
            new bytes(0) // hook metadata
        );

        // Broadcast x-chain messages
        deal(OPEN_USDT_ADDRESS, users.alice, USDC_1);
        ERC20(OPEN_USDT_ADDRESS).approve(address(router), amountInMax);
        vm.expectCall({
            callee: address(rootIcaRouter),
            data: abi.encodeCall(
                IInterchainAccountRouter.callRemoteCommitReveal,
                (
                    leafDomain,
                    rootIcaRouter.routers(leafDomain),
                    bytes32(0),
                    new bytes(0),
                    IPostDispatchHook(address(rootIcaRouter.hook())),
                    TypeCasts.addressToBytes32(users.alice),
                    commitment
                )
            )
        });

        vm.expectEmit(address(router));
        emit Dispatcher.CrossChainSwap({
            caller: users.alice,
            localRouter: address(rootIcaRouter),
            destinationDomain: leafDomain,
            commitment: commitment
        });

        router.execute{value: MESSAGE_FEE * 2}(commands, inputs);

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);

        // Process Token Bridging message & check tokens arrived
        vm.selectFork(leafId);
        vm.expectEmit(address(leafMailbox));
        emit IMailbox.Process({
            origin: rootDomain,
            sender: TypeCasts.addressToBytes32(OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS),
            recipient: address(leafOpenUsdtTokenBridge)
        });
        leafMailbox.processNextInboundMessage();
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), amountInMax);

        // Process Commitment message & check commitment was stored
        vm.expectEmit(address(leafMailbox));
        emit IMailbox.Process({
            origin: rootDomain,
            sender: TypeCasts.addressToBytes32(address(rootIcaRouter)),
            recipient: address(leafIcaRouter)
        });
        leafMailbox.processNextInboundMessage();
        assertTrue(OwnableMulticall(userICA).commitments(commitment));

        assertEq(ERC20(baseUSDC).balanceOf(users.alice), 0);

        // Self Relay the message & check swap was successful
        vm.expectEmit(address(leafRouter));
        emit Dispatcher.UniversalRouterSwap(userICA, users.alice);
        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(userICA).revealAndExecute({calls: calls, salt: TypeCasts.addressToBytes32(users.alice)});

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), 100100); //leftover from swap is sent to user
        assertEq(ERC20(baseUSDC).balanceOf(users.alice), amountOut);
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(userICA, address(leafRouter)), 0);
    }

    function test_executeCrosschainFlowMultichainV3SwapExactIn() public {
        uint256 destinationAmountOutMin = 5800000;

        // Encode destination swap
        bytes memory swapSubplan =
            abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)), bytes1(uint8(Commands.V3_SWAP_EXACT_IN)));
        bytes memory path = abi.encodePacked(OPEN_USDT_ADDRESS, int24(1), baseUSDC);
        bytes[] memory swapInputs = new bytes[](2);
        swapInputs[0] = abi.encode(OPEN_USDT_ADDRESS, address(leafRouter), Constants.TOTAL_BALANCE);
        swapInputs[1] =
            abi.encode(users.alice, ActionConstants.CONTRACT_BALANCE, destinationAmountOutMin, path, false, false);

        // Encode fallback transfer
        bytes memory transferSubplan = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)));
        bytes[] memory transferInputs = new bytes[](1);
        transferInputs[0] = abi.encode(OPEN_USDT_ADDRESS, users.alice, Constants.TOTAL_BALANCE);

        // Encode Sub Plan
        bytes memory leafCommands = abi.encodePacked(
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT,
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT
        );
        bytes[] memory leafInputs = new bytes[](2);
        leafInputs[0] = abi.encode(swapSubplan, swapInputs);
        leafInputs[1] = abi.encode(transferSubplan, transferInputs);

        // Encode ICA calls
        CallLib.Call[] memory calls = new CallLib.Call[](3);
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

        // Calculate commitment hash
        bytes32 commitment = hashCommitment({_calls: calls, _salt: TypeCasts.addressToBytes32(users.alice)});

        // Predict User's ICA address
        address payable userICA = payable(rootIcaRouter.getRemoteInterchainAccount({
                _destination: leafDomain, _owner: address(router), _userSalt: TypeCasts.addressToBytes32(users.alice)
            }));

        // Encode origin chain commands
        uint256 amountIn = 10 ether;
        uint256 originAmountOutMin = 5800000;
        bytes memory commands = abi.encodePacked(
            bytes1(uint8(Commands.V3_SWAP_EXACT_IN)),
            bytes1(uint8(Commands.BRIDGE_TOKEN)),
            bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN))
        );
        bytes[] memory inputs = new bytes[](3);
        path = abi.encodePacked(address(OP), int24(100), OPEN_USDT_ADDRESS);
        inputs[0] = abi.encode(ActionConstants.ADDRESS_THIS, amountIn, originAmountOutMin, path, true, false);
        inputs[1] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            userICA,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            Constants.TOTAL_BALANCE,
            MESSAGE_FEE,
            0, // tokenFee
            leafDomain,
            false
        );
        inputs[2] = abi.encode(
            leafDomain, // destination domain
            address(rootIcaRouter), // origin ica router
            rootIcaRouter.routers(leafDomain), // destination ica router
            bytes32(0), // destination ism
            commitment, // commitment of the calls to be made
            MESSAGE_FEE, // fee to dispatch x-chain message
            address(0), // token
            0, // tokenFee
            rootIcaRouter.hook(), // post dispatch hook
            new bytes(0) // hook metadata
        );

        // Broadcast x-chain messages
        deal(address(OP), users.alice, amountIn);
        OP.approve(address(router), amountIn);
        vm.expectCall({
            callee: address(rootIcaRouter),
            data: abi.encodeCall(
                IInterchainAccountRouter.callRemoteCommitReveal,
                (
                    leafDomain,
                    rootIcaRouter.routers(leafDomain),
                    bytes32(0),
                    new bytes(0),
                    IPostDispatchHook(address(rootIcaRouter.hook())),
                    TypeCasts.addressToBytes32(users.alice),
                    commitment
                )
            )
        });

        vm.expectEmit(address(router));
        emit Dispatcher.UniversalRouterSwap({sender: users.alice, recipient: address(router)});
        vm.expectEmit(address(router));
        emit Dispatcher.CrossChainSwap({
            caller: users.alice,
            localRouter: address(rootIcaRouter),
            destinationDomain: leafDomain,
            commitment: commitment
        });
        router.execute{value: MESSAGE_FEE * 2}(commands, inputs);

        // No leftover from ExactIn swap
        assertEq(OP.balanceOf(userICA), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);

        // Process Token Bridging message & check tokens arrived
        vm.selectFork(leafId);
        vm.expectEmit(address(leafMailbox));
        emit IMailbox.Process({
            origin: rootDomain,
            sender: TypeCasts.addressToBytes32(OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS),
            recipient: address(leafOpenUsdtTokenBridge)
        });
        leafMailbox.processNextInboundMessage();
        // Check output of first swap was bridged to ICA on destination
        assertGe(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), originAmountOutMin);

        // Process Commitment message & check commitment was stored
        vm.expectEmit(address(leafMailbox));
        emit IMailbox.Process({
            origin: rootDomain,
            sender: TypeCasts.addressToBytes32(address(rootIcaRouter)),
            recipient: address(leafIcaRouter)
        });
        leafMailbox.processNextInboundMessage();
        assertTrue(OwnableMulticall(userICA).commitments(commitment));

        assertEq(ERC20(baseUSDC).balanceOf(users.alice), 0);

        // Self Relay the message & check swap was successful
        vm.expectEmit(address(leafRouter));
        emit Dispatcher.UniversalRouterSwap(userICA, users.alice);
        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(userICA).revealAndExecute({calls: calls, salt: TypeCasts.addressToBytes32(users.alice)});

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), 0); // no leftover input from swap in exactIn
        assertGt(ERC20(baseUSDC).balanceOf(users.alice), destinationAmountOutMin);
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(userICA, address(leafRouter)), 0);
    }

    function test_executeCrosschainFlowV2SwapExactIn() public {
        uint256 amountIn = USDC_1;
        uint256 amountOutMin = 9e5;

        // Encode destination swap
        bytes memory swapSubplan = abi.encodePacked(bytes1(uint8(Commands.V2_SWAP_EXACT_IN)));
        bytes memory path = abi.encodePacked(OPEN_USDT_ADDRESS, false, baseUSDC);
        bytes[] memory swapInputs = new bytes[](1);
        swapInputs[0] = abi.encode(users.alice, amountIn, amountOutMin, path, true, false);

        // Encode fallback transfer
        bytes memory transferSubplan = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)));
        bytes[] memory transferInputs = new bytes[](1);
        transferInputs[0] = abi.encode(OPEN_USDT_ADDRESS, users.alice, Constants.TOTAL_BALANCE);

        // Encode Sub Plan
        bytes memory leafCommands = abi.encodePacked(
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT,
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT
        );
        bytes[] memory leafInputs = new bytes[](2);
        leafInputs[0] = abi.encode(swapSubplan, swapInputs);
        leafInputs[1] = abi.encode(transferSubplan, transferInputs);

        // Encode ICA calls
        CallLib.Call[] memory calls = new CallLib.Call[](2);
        calls[0] = CallLib.build({
            to: OPEN_USDT_ADDRESS, value: 0, data: abi.encodeCall(ERC20.approve, (address(leafRouter), amountIn))
        });
        calls[1] = CallLib.build({
            to: address(leafRouter), value: 0, data: abi.encodeCall(Dispatcher.execute, (leafCommands, leafInputs))
        });

        // Calculate commitment hash
        bytes32 commitment = hashCommitment({_calls: calls, _salt: TypeCasts.addressToBytes32(users.alice)});

        // Predict User's ICA address
        address payable userICA = payable(rootIcaRouter.getRemoteInterchainAccount({
                _destination: leafDomain, _owner: address(router), _userSalt: TypeCasts.addressToBytes32(users.alice)
            }));

        // Encode origin chain commands
        bytes memory commands =
            abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN)), bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN)));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            userICA,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            amountIn,
            MESSAGE_FEE,
            0, // tokenFee
            leafDomain,
            true
        );
        inputs[1] = abi.encode(
            leafDomain, // destination domain
            address(rootIcaRouter), // origin ica router
            rootIcaRouter.routers(leafDomain), // destination ica router
            bytes32(0), // destination ism
            commitment, // commitment of the calls to be made
            MESSAGE_FEE, // fee to dispatch x-chain message
            address(0), // token
            0, // tokenFee
            rootIcaRouter.hook(), // post dispatch hook
            new bytes(0) // hook metadata
        );

        // Broadcast x-chain messages
        deal(OPEN_USDT_ADDRESS, users.alice, amountIn);
        ERC20(OPEN_USDT_ADDRESS).approve(address(router), amountIn);
        vm.expectCall({
            callee: address(rootIcaRouter),
            data: abi.encodeCall(
                IInterchainAccountRouter.callRemoteCommitReveal,
                (
                    leafDomain,
                    rootIcaRouter.routers(leafDomain),
                    bytes32(0),
                    new bytes(0),
                    IPostDispatchHook(address(rootIcaRouter.hook())),
                    TypeCasts.addressToBytes32(users.alice),
                    commitment
                )
            )
        });

        vm.expectEmit(address(router));
        emit Dispatcher.CrossChainSwap({
            caller: users.alice,
            localRouter: address(rootIcaRouter),
            destinationDomain: leafDomain,
            commitment: commitment
        });

        router.execute{value: MESSAGE_FEE * 2}(commands, inputs);

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);

        // Process Token Bridging message & check tokens arrived
        vm.selectFork(leafId);
        vm.expectEmit(address(leafMailbox));
        emit IMailbox.Process({
            origin: rootDomain,
            sender: TypeCasts.addressToBytes32(OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS),
            recipient: address(leafOpenUsdtTokenBridge)
        });
        leafMailbox.processNextInboundMessage();
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), amountIn);

        // Process Commitment message & check commitment was stored
        vm.expectEmit(address(leafMailbox));
        emit IMailbox.Process({
            origin: rootDomain,
            sender: TypeCasts.addressToBytes32(address(rootIcaRouter)),
            recipient: address(leafIcaRouter)
        });
        leafMailbox.processNextInboundMessage();
        assertTrue(OwnableMulticall(userICA).commitments(commitment));

        assertEq(ERC20(baseUSDC).balanceOf(users.alice), 0);

        // Self Relay the message & check swap was successful
        vm.expectEmit(address(leafRouter));
        emit Dispatcher.UniversalRouterSwap(userICA, users.alice);
        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(userICA).revealAndExecute({calls: calls, salt: TypeCasts.addressToBytes32(users.alice)});

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), 0); // no leftover from exactIn swap
        assertGt(ERC20(baseUSDC).balanceOf(users.alice), amountOutMin);
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(userICA, address(leafRouter)), 0);
    }

    function test_executeCrosschainFlowV2SwapExactOut() public {
        uint256 amountOut = 9e5;
        uint256 amountInMax = USDC_1;

        // Encode destination swap
        bytes memory swapSubplan = abi.encodePacked(bytes1(uint8(Commands.V2_SWAP_EXACT_OUT)));
        bytes memory path = abi.encodePacked(OPEN_USDT_ADDRESS, false, baseUSDC);
        bytes[] memory swapInputs = new bytes[](1);
        swapInputs[0] = abi.encode(users.alice, amountOut, amountInMax, path, true, false);

        // Encode fallback transfer
        bytes memory transferSubplan = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)));
        bytes[] memory transferInputs = new bytes[](1);
        transferInputs[0] = abi.encode(OPEN_USDT_ADDRESS, users.alice, Constants.TOTAL_BALANCE);

        // Encode Sub Plan
        bytes memory leafCommands = abi.encodePacked(
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT,
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT
        );
        bytes[] memory leafInputs = new bytes[](2);
        leafInputs[0] = abi.encode(swapSubplan, swapInputs);
        leafInputs[1] = abi.encode(transferSubplan, transferInputs);

        // Encode ICA calls
        CallLib.Call[] memory calls = new CallLib.Call[](2);
        calls[0] = CallLib.build({
            to: OPEN_USDT_ADDRESS, value: 0, data: abi.encodeCall(ERC20.approve, (address(leafRouter), amountInMax))
        });
        calls[1] = CallLib.build({
            to: address(leafRouter), value: 0, data: abi.encodeCall(Dispatcher.execute, (leafCommands, leafInputs))
        });

        // Calculate commitment hash
        bytes32 commitment = hashCommitment({_calls: calls, _salt: TypeCasts.addressToBytes32(users.alice)});

        // Predict User's ICA address
        address payable userICA = payable(rootIcaRouter.getRemoteInterchainAccount({
                _destination: leafDomain, _owner: address(router), _userSalt: TypeCasts.addressToBytes32(users.alice)
            }));

        // Encode origin chain commands
        bytes memory commands =
            abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN)), bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN)));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            userICA,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            amountInMax,
            MESSAGE_FEE,
            0, // tokenFee
            leafDomain,
            true
        );
        inputs[1] = abi.encode(
            leafDomain, // destination domain
            address(rootIcaRouter), // origin ica router
            rootIcaRouter.routers(leafDomain), // destination ica router
            bytes32(0), // destination ism
            commitment, // commitment of the calls to be made
            MESSAGE_FEE, // fee to dispatch x-chain message
            address(0), // token
            0, // tokenFee
            rootIcaRouter.hook(), // post dispatch hook
            new bytes(0) // hook metadata
        );

        // Broadcast x-chain messages
        deal(OPEN_USDT_ADDRESS, users.alice, amountInMax);
        ERC20(OPEN_USDT_ADDRESS).approve(address(router), amountInMax);
        vm.expectCall({
            callee: address(rootIcaRouter),
            data: abi.encodeCall(
                IInterchainAccountRouter.callRemoteCommitReveal,
                (
                    leafDomain,
                    rootIcaRouter.routers(leafDomain),
                    bytes32(0),
                    new bytes(0),
                    IPostDispatchHook(address(rootIcaRouter.hook())),
                    TypeCasts.addressToBytes32(users.alice),
                    commitment
                )
            )
        });

        vm.expectEmit(address(router));
        emit Dispatcher.CrossChainSwap({
            caller: users.alice,
            localRouter: address(rootIcaRouter),
            destinationDomain: leafDomain,
            commitment: commitment
        });

        router.execute{value: MESSAGE_FEE * 2}(commands, inputs);

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);

        // Process Token Bridging message & check tokens arrived
        vm.selectFork(leafId);
        vm.expectEmit(address(leafMailbox));
        emit IMailbox.Process({
            origin: rootDomain,
            sender: TypeCasts.addressToBytes32(OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS),
            recipient: address(leafOpenUsdtTokenBridge)
        });
        leafMailbox.processNextInboundMessage();
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), amountInMax);

        // Process Commitment message & check commitment was stored
        vm.expectEmit(address(leafMailbox));
        emit IMailbox.Process({
            origin: rootDomain,
            sender: TypeCasts.addressToBytes32(address(rootIcaRouter)),
            recipient: address(leafIcaRouter)
        });
        leafMailbox.processNextInboundMessage();
        assertTrue(OwnableMulticall(userICA).commitments(commitment));

        assertEq(ERC20(baseUSDC).balanceOf(users.alice), 0);

        // Self Relay the message & check swap was successful
        vm.expectEmit(address(leafRouter));
        emit Dispatcher.UniversalRouterSwap(userICA, users.alice);
        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(userICA).revealAndExecute({calls: calls, salt: TypeCasts.addressToBytes32(users.alice)});

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), 89098); //leftover from swap is sent to user
        assertGe(ERC20(baseUSDC).balanceOf(users.alice), amountOut);
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(userICA, address(leafRouter)), 0);
    }

    function test_executeCrosschainFlowMultichainV2SwapExactIn() public {
        uint256 destinationAmountOutMin = 100000;

        // Encode destination swap
        bytes memory swapSubplan =
            abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)), bytes1(uint8(Commands.V2_SWAP_EXACT_IN)));
        bytes memory path = abi.encodePacked(OPEN_USDT_ADDRESS, false, baseUSDC);
        bytes[] memory swapInputs = new bytes[](2);
        swapInputs[0] = abi.encode(OPEN_USDT_ADDRESS, address(leafRouter), Constants.TOTAL_BALANCE);
        swapInputs[1] =
            abi.encode(users.alice, ActionConstants.CONTRACT_BALANCE, destinationAmountOutMin, path, false, false);

        // Encode fallback transfer
        bytes memory transferSubplan = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)));
        bytes[] memory transferInputs = new bytes[](1);
        transferInputs[0] = abi.encode(OPEN_USDT_ADDRESS, users.alice, Constants.TOTAL_BALANCE);

        // Encode Sub Plan
        bytes memory leafCommands = abi.encodePacked(
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT,
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT
        );
        bytes[] memory leafInputs = new bytes[](2);
        leafInputs[0] = abi.encode(swapSubplan, swapInputs);
        leafInputs[1] = abi.encode(transferSubplan, transferInputs);

        // Encode ICA calls
        CallLib.Call[] memory calls = new CallLib.Call[](3);
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

        // Calculate commitment hash
        bytes32 commitment = hashCommitment({_calls: calls, _salt: TypeCasts.addressToBytes32(users.alice)});

        // Predict User's ICA address
        address payable userICA = payable(rootIcaRouter.getRemoteInterchainAccount({
                _destination: leafDomain, _owner: address(router), _userSalt: TypeCasts.addressToBytes32(users.alice)
            }));

        // Encode origin chain commands
        uint256 amountIn = 10 * USDC_1;
        uint256 originAmountOutMin = 100000;
        bytes memory commands = abi.encodePacked(
            bytes1(uint8(Commands.V2_SWAP_EXACT_IN)),
            bytes1(uint8(Commands.BRIDGE_TOKEN)),
            bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN))
        );
        bytes[] memory inputs = new bytes[](3);
        path = abi.encodePacked(address(USDT), true, OPEN_USDT_ADDRESS);
        inputs[0] = abi.encode(ActionConstants.ADDRESS_THIS, amountIn, destinationAmountOutMin, path, true, false);
        inputs[1] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            userICA,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            Constants.TOTAL_BALANCE,
            MESSAGE_FEE,
            0, // tokenFee
            leafDomain,
            false
        );
        inputs[2] = abi.encode(
            leafDomain, // destination domain
            address(rootIcaRouter), // origin ica router
            rootIcaRouter.routers(leafDomain), // destination ica router
            bytes32(0), // destination ism
            commitment, // commitment of the calls to be made
            MESSAGE_FEE, // fee to dispatch x-chain message
            address(0), // token
            0, // tokenFee
            rootIcaRouter.hook(), // post dispatch hook
            new bytes(0) // hook metadata
        );

        // Broadcast x-chain messages
        deal(address(USDT), users.alice, amountIn);
        USDT.approve(address(router), amountIn);
        vm.expectCall({
            callee: address(rootIcaRouter),
            data: abi.encodeCall(
                IInterchainAccountRouter.callRemoteCommitReveal,
                (
                    leafDomain,
                    rootIcaRouter.routers(leafDomain),
                    bytes32(0),
                    new bytes(0),
                    IPostDispatchHook(address(rootIcaRouter.hook())),
                    TypeCasts.addressToBytes32(users.alice),
                    commitment
                )
            )
        });

        vm.expectEmit(address(router));
        emit Dispatcher.UniversalRouterSwap({sender: users.alice, recipient: address(router)});
        vm.expectEmit(address(router));
        emit Dispatcher.CrossChainSwap({
            caller: users.alice,
            localRouter: address(rootIcaRouter),
            destinationDomain: leafDomain,
            commitment: commitment
        });

        router.execute{value: MESSAGE_FEE * 2}(commands, inputs);

        // No leftover from ExactIn swap
        assertEq(USDT.balanceOf(userICA), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);

        // Process Token Bridging message & check tokens arrived
        vm.selectFork(leafId);
        vm.expectEmit(address(leafMailbox));
        emit IMailbox.Process({
            origin: rootDomain,
            sender: TypeCasts.addressToBytes32(OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS),
            recipient: address(leafOpenUsdtTokenBridge)
        });
        leafMailbox.processNextInboundMessage();
        // Check output of first swap was bridged to ICA on destination
        assertGe(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), originAmountOutMin);

        // Process Commitment message & check commitment was stored
        vm.expectEmit(address(leafMailbox));
        emit IMailbox.Process({
            origin: rootDomain,
            sender: TypeCasts.addressToBytes32(address(rootIcaRouter)),
            recipient: address(leafIcaRouter)
        });
        leafMailbox.processNextInboundMessage();
        assertTrue(OwnableMulticall(userICA).commitments(commitment));

        assertEq(ERC20(baseUSDC).balanceOf(users.alice), 0);

        // Self Relay the message & check swap was successful
        vm.expectEmit(address(leafRouter));
        emit Dispatcher.UniversalRouterSwap(userICA, users.alice);
        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(userICA).revealAndExecute({calls: calls, salt: TypeCasts.addressToBytes32(users.alice)});

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), 0); // no leftover from exactIn swap
        assertGt(ERC20(baseUSDC).balanceOf(users.alice), destinationAmountOutMin);
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(userICA, address(leafRouter)), 0);
    }

    function test_executeCrosschainFallback() public {
        uint256 amountIn = USDC_1;
        /// @dev Setting `amountOutMin` too large to simulate swap failure
        uint256 amountOutMin = amountIn * 10;

        // Encode destination swap
        bytes memory swapSubplan = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_IN)));
        bytes memory path = abi.encodePacked(OPEN_USDT_ADDRESS, int24(1), baseUSDC);
        bytes[] memory swapInputs = new bytes[](1);
        swapInputs[0] = abi.encode(users.alice, amountIn, amountOutMin, path, true, false);

        // Encode fallback transfer
        bytes memory transferSubplan = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)));
        bytes[] memory transferInputs = new bytes[](1);
        transferInputs[0] = abi.encode(OPEN_USDT_ADDRESS, users.alice, Constants.TOTAL_BALANCE);

        // Encode Sub Plan
        bytes memory leafCommands = abi.encodePacked(
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT,
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT
        );
        bytes[] memory leafInputs = new bytes[](2);
        leafInputs[0] = abi.encode(swapSubplan, swapInputs);
        leafInputs[1] = abi.encode(transferSubplan, transferInputs);

        // Encode ICA calls
        CallLib.Call[] memory calls = new CallLib.Call[](2);
        calls[0] = CallLib.build({
            to: OPEN_USDT_ADDRESS, value: 0, data: abi.encodeCall(ERC20.approve, (address(leafRouter), amountIn))
        });
        calls[1] = CallLib.build({
            to: address(leafRouter), value: 0, data: abi.encodeCall(Dispatcher.execute, (leafCommands, leafInputs))
        });

        // Calculate commitment hash
        bytes32 commitment = hashCommitment({_calls: calls, _salt: TypeCasts.addressToBytes32(users.alice)});

        // Predict User's ICA address
        address payable userICA = payable(rootIcaRouter.getRemoteInterchainAccount({
                _destination: leafDomain, _owner: address(router), _userSalt: TypeCasts.addressToBytes32(users.alice)
            }));

        // Encode origin chain commands
        bytes memory commands =
            abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN)), bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN)));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            userICA,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            amountIn,
            MESSAGE_FEE,
            0, // tokenFee
            leafDomain,
            true
        );
        inputs[1] = abi.encode(
            leafDomain, // destination domain
            address(rootIcaRouter), // origin ica router
            rootIcaRouter.routers(leafDomain), // destination ica router
            bytes32(0), // destination ism
            commitment, // commitment of the calls to be made
            MESSAGE_FEE, // fee to dispatch x-chain message
            address(0), // token
            0, // tokenFee
            rootIcaRouter.hook(), // post dispatch hook
            new bytes(0) // hook metadata
        );

        // Broadcast x-chain messages
        deal(OPEN_USDT_ADDRESS, users.alice, amountIn);
        ERC20(OPEN_USDT_ADDRESS).approve(address(router), amountIn);
        vm.expectCall({
            callee: address(rootIcaRouter),
            data: abi.encodeCall(
                IInterchainAccountRouter.callRemoteCommitReveal,
                (
                    leafDomain,
                    rootIcaRouter.routers(leafDomain),
                    bytes32(0),
                    new bytes(0),
                    IPostDispatchHook(address(rootIcaRouter.hook())),
                    TypeCasts.addressToBytes32(users.alice),
                    commitment
                )
            )
        });

        vm.expectEmit(address(router));
        emit Dispatcher.CrossChainSwap({
            caller: users.alice,
            localRouter: address(rootIcaRouter),
            destinationDomain: leafDomain,
            commitment: commitment
        });

        router.execute{value: MESSAGE_FEE * 2}(commands, inputs);

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);

        // Process Token Bridging message & check tokens arrived
        vm.selectFork(leafId);
        vm.expectEmit(address(leafMailbox));
        emit IMailbox.Process({
            origin: rootDomain,
            sender: TypeCasts.addressToBytes32(OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS),
            recipient: address(leafOpenUsdtTokenBridge)
        });
        leafMailbox.processNextInboundMessage();
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), amountIn);

        // Process Commitment message & check commitment was stored
        vm.expectEmit(address(leafMailbox));
        emit IMailbox.Process({
            origin: rootDomain,
            sender: TypeCasts.addressToBytes32(address(rootIcaRouter)),
            recipient: address(leafIcaRouter)
        });
        leafMailbox.processNextInboundMessage();
        assertTrue(OwnableMulticall(userICA).commitments(commitment));

        // Self Relay the message. Swap should fail & fallback transfer should succeed
        vm.expectEmit(OPEN_USDT_ADDRESS);
        emit ERC20.Transfer({from: userICA, to: users.alice, amount: amountIn});
        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(userICA).revealAndExecute({calls: calls, salt: TypeCasts.addressToBytes32(users.alice)});

        // Swap input is returned to user on destination
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), amountIn);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);
        assertEq(ERC20(baseUSDC).balanceOf(users.alice), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(userICA, address(leafRouter)), 0);
    }

    function test_executeCrosschainFlowMixedV3ExactInV2ExactIn() public {
        uint256 v3AmountIn = USDC_1;
        uint256 v3AmountOutMin = 999000;

        // Encode destination swaps & sweep
        bytes memory swapSubplan = abi.encodePacked(
            bytes1(uint8(Commands.V3_SWAP_EXACT_IN)),
            bytes1(uint8(Commands.V2_SWAP_EXACT_IN)),
            bytes1(uint8(Commands.SWEEP))
        );
        bytes[] memory swapInputs = new bytes[](3);

        // V3 Swap Inputs
        bytes memory v3Path = abi.encodePacked(OPEN_USDT_ADDRESS, int24(1), baseUSDC);
        swapInputs[0] = abi.encode(ActionConstants.ADDRESS_THIS, v3AmountIn, v3AmountOutMin, v3Path, true, false);

        // V2 Swap Inputs
        uint256 v2AmountIn = ActionConstants.CONTRACT_BALANCE; // Use all available baseUSDC from V3 swap
        uint256 v2AmountOutMin = 3e13; // More realistic minimum output for available liquidity
        bytes memory v2Path = abi.encodePacked(baseUSDC, false, WETH9_ADDRESS);
        swapInputs[1] = abi.encode(users.alice, v2AmountIn, v2AmountOutMin, v2Path, false, false);

        // Sweep leftover intermediary tokens to recipient
        swapInputs[2] = abi.encode(baseUSDC, users.alice, 0);

        // Encode fallback transfer
        bytes memory transferSubplan = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)));
        bytes[] memory transferInputs = new bytes[](1);
        transferInputs[0] = abi.encode(OPEN_USDT_ADDRESS, users.alice, Constants.TOTAL_BALANCE);

        // Encode Sub Plan
        bytes memory leafCommands = abi.encodePacked(
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT,
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT
        );
        bytes[] memory leafInputs = new bytes[](2);
        leafInputs[0] = abi.encode(swapSubplan, swapInputs);
        leafInputs[1] = abi.encode(transferSubplan, transferInputs);

        // Encode ICA calls
        CallLib.Call[] memory calls = new CallLib.Call[](2);
        calls[0] = CallLib.build({
            to: OPEN_USDT_ADDRESS, value: 0, data: abi.encodeCall(ERC20.approve, (address(leafRouter), v3AmountIn))
        });
        calls[1] = CallLib.build({
            to: address(leafRouter), value: 0, data: abi.encodeCall(Dispatcher.execute, (leafCommands, leafInputs))
        });

        // Calculate commitment hash
        bytes32 commitment = hashCommitment({_calls: calls, _salt: TypeCasts.addressToBytes32(users.alice)});

        // Predict User's ICA address
        address payable userICA = payable(rootIcaRouter.getRemoteInterchainAccount({
                _destination: leafDomain, _owner: address(router), _userSalt: TypeCasts.addressToBytes32(users.alice)
            }));

        // Encode origin chain commands
        bytes memory commands =
            abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN)), bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN)));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            userICA,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            v3AmountIn,
            MESSAGE_FEE,
            0, // tokenFee
            leafDomain,
            true
        );
        inputs[1] = abi.encode(
            leafDomain, // destination domain
            address(rootIcaRouter), // origin ica router
            rootIcaRouter.routers(leafDomain), // destination ica router
            bytes32(0), // destination ism
            commitment, // commitment of the calls to be made
            MESSAGE_FEE, // fee to dispatch x-chain message
            address(0), // token
            0, // tokenFee
            rootIcaRouter.hook(), // post dispatch hook
            new bytes(0) // hook metadata
        );

        // Broadcast x-chain messages
        deal(OPEN_USDT_ADDRESS, users.alice, v3AmountIn);
        ERC20(OPEN_USDT_ADDRESS).approve(address(router), v3AmountIn);
        vm.expectCall({
            callee: address(rootIcaRouter),
            data: abi.encodeCall(
                IInterchainAccountRouter.callRemoteCommitReveal,
                (
                    leafDomain,
                    rootIcaRouter.routers(leafDomain),
                    bytes32(0),
                    new bytes(0),
                    IPostDispatchHook(address(rootIcaRouter.hook())),
                    TypeCasts.addressToBytes32(users.alice),
                    commitment
                )
            )
        });

        vm.expectEmit(address(router));
        emit Dispatcher.CrossChainSwap({
            caller: users.alice,
            localRouter: address(rootIcaRouter),
            destinationDomain: leafDomain,
            commitment: commitment
        });

        router.execute{value: MESSAGE_FEE * 2}(commands, inputs);

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);

        // Select Leaf & avoid underflow
        vm.selectFork(leafId);
        IPool pool = IPool(v2Factory.getPool(baseUSDC, WETH9_ADDRESS, false));
        uint256 last = pool.blockTimestampLast();

        // Set timestamp greater than last timestamp in Pool to avoid underflow
        vm.warp(last + 1);

        // Process Token Bridging message & check tokens arrived
        vm.expectEmit(address(leafMailbox));
        emit IMailbox.Process({
            origin: rootDomain,
            sender: TypeCasts.addressToBytes32(OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS),
            recipient: address(leafOpenUsdtTokenBridge)
        });
        leafMailbox.processNextInboundMessage();
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), v3AmountIn);

        // Process Commitment message & check commitment was stored
        vm.expectEmit(address(leafMailbox));
        emit IMailbox.Process({
            origin: rootDomain,
            sender: TypeCasts.addressToBytes32(address(rootIcaRouter)),
            recipient: address(leafIcaRouter)
        });
        leafMailbox.processNextInboundMessage();
        assertTrue(OwnableMulticall(userICA).commitments(commitment));

        assertEq(ERC20(baseUSDC).balanceOf(users.alice), 0);
        assertEq(ERC20(WETH9_ADDRESS).balanceOf(users.alice), 0);

        // Self Relay the message & check both swaps were successful
        vm.expectEmit(address(leafRouter));
        emit Dispatcher.UniversalRouterSwap({sender: userICA, recipient: address(leafRouter)});
        vm.expectEmit(address(leafRouter));
        emit Dispatcher.UniversalRouterSwap({sender: userICA, recipient: users.alice});
        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(userICA).revealAndExecute({calls: calls, salt: TypeCasts.addressToBytes32(users.alice)});

        // No leftover in the Router
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(address(leafRouter)), 0);
        assertEq(ERC20(baseUSDC).balanceOf(address(leafRouter)), 0);
        assertEq(ERC20(WETH9_ADDRESS).balanceOf(address(leafRouter)), 0);

        // No leftover in the ICA
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);
        assertEq(ERC20(baseUSDC).balanceOf(userICA), 0); // leftover intermediary tokens swept from ICA
        assertEq(ERC20(WETH9_ADDRESS).balanceOf(userICA), 0);

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), 0); // no leftover input from v3 exactIn swap
        assertApproxEqAbs(ERC20(baseUSDC).balanceOf(users.alice), 0, 1e3); // most output from first swap has been used by second swap
        assertGe(ERC20(WETH9_ADDRESS).balanceOf(users.alice), v2AmountOutMin);
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(userICA, address(leafRouter)), 0);
    }

    function test_executeCrosschainFlowMixedV3ExactInV2ExactInFirstSwapRevert() public {
        uint256 v3AmountIn = USDC_1;
        /// @dev Large v3AmountOutMin to simulate failure
        uint256 v3AmountOutMin = 999000 * 2;

        // Encode destination swaps & sweep
        bytes memory swapSubplan = abi.encodePacked(
            bytes1(uint8(Commands.V3_SWAP_EXACT_IN)),
            bytes1(uint8(Commands.V2_SWAP_EXACT_IN)),
            bytes1(uint8(Commands.SWEEP))
        );
        bytes[] memory swapInputs = new bytes[](3);

        // V3 Swap Inputs
        bytes memory v3Path = abi.encodePacked(OPEN_USDT_ADDRESS, int24(1), baseUSDC);
        swapInputs[0] = abi.encode(ActionConstants.ADDRESS_THIS, v3AmountIn, v3AmountOutMin, v3Path, true, false);

        // V2 Swap Inputs
        uint256 v2AmountIn = v3AmountOutMin;
        uint256 v2AmountOutMin = 606500898800000;
        bytes memory v2Path = abi.encodePacked(baseUSDC, false, WETH9_ADDRESS);
        swapInputs[1] = abi.encode(users.alice, v2AmountIn, v2AmountOutMin, v2Path, false, false);

        // Sweep leftover intermediary tokens to recipient
        swapInputs[2] = abi.encode(baseUSDC, users.alice, 0);

        // Encode fallback transfer
        bytes memory transferSubplan = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)));
        bytes[] memory transferInputs = new bytes[](1);
        transferInputs[0] = abi.encode(OPEN_USDT_ADDRESS, users.alice, Constants.TOTAL_BALANCE);

        // Encode Sub Plan
        bytes memory leafCommands = abi.encodePacked(
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT,
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT
        );
        bytes[] memory leafInputs = new bytes[](2);
        leafInputs[0] = abi.encode(swapSubplan, swapInputs);
        leafInputs[1] = abi.encode(transferSubplan, transferInputs);

        // Encode ICA calls
        CallLib.Call[] memory calls = new CallLib.Call[](2);
        calls[0] = CallLib.build({
            to: OPEN_USDT_ADDRESS, value: 0, data: abi.encodeCall(ERC20.approve, (address(leafRouter), v3AmountIn))
        });
        calls[1] = CallLib.build({
            to: address(leafRouter), value: 0, data: abi.encodeCall(Dispatcher.execute, (leafCommands, leafInputs))
        });

        // Calculate commitment hash
        bytes32 commitment = hashCommitment({_calls: calls, _salt: TypeCasts.addressToBytes32(users.alice)});

        // Predict User's ICA address
        address payable userICA = payable(rootIcaRouter.getRemoteInterchainAccount({
                _destination: leafDomain, _owner: address(router), _userSalt: TypeCasts.addressToBytes32(users.alice)
            }));

        // Encode origin chain commands
        bytes memory commands =
            abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN)), bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN)));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            userICA,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            v3AmountIn,
            MESSAGE_FEE,
            0, // tokenFee
            leafDomain,
            true
        );
        inputs[1] = abi.encode(
            leafDomain, // destination domain
            address(rootIcaRouter), // origin ica router
            rootIcaRouter.routers(leafDomain), // destination ica router
            bytes32(0), // destination ism
            commitment, // commitment of the calls to be made
            MESSAGE_FEE, // fee to dispatch x-chain message
            address(0), // token
            0, // tokenFee
            rootIcaRouter.hook(), // post dispatch hook
            new bytes(0) // hook metadata
        );

        // Broadcast x-chain messages
        deal(OPEN_USDT_ADDRESS, users.alice, v3AmountIn);
        ERC20(OPEN_USDT_ADDRESS).approve(address(router), v3AmountIn);
        vm.expectCall({
            callee: address(rootIcaRouter),
            data: abi.encodeCall(
                IInterchainAccountRouter.callRemoteCommitReveal,
                (
                    leafDomain,
                    rootIcaRouter.routers(leafDomain),
                    bytes32(0),
                    new bytes(0),
                    IPostDispatchHook(address(rootIcaRouter.hook())),
                    TypeCasts.addressToBytes32(users.alice),
                    commitment
                )
            )
        });

        vm.expectEmit(address(router));
        emit Dispatcher.CrossChainSwap({
            caller: users.alice,
            localRouter: address(rootIcaRouter),
            destinationDomain: leafDomain,
            commitment: commitment
        });

        router.execute{value: MESSAGE_FEE * 2}(commands, inputs);

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);

        // Select Leaf & avoid underflow
        vm.selectFork(leafId);
        IPool pool = IPool(v2Factory.getPool(baseUSDC, WETH9_ADDRESS, false));
        uint256 last = pool.blockTimestampLast();

        // Set timestamp greater than last timestamp in Pool to avoid underflow
        vm.warp(last + 1);

        // Process Token Bridging message & check tokens arrived
        vm.expectEmit(address(leafMailbox));
        emit IMailbox.Process({
            origin: rootDomain,
            sender: TypeCasts.addressToBytes32(OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS),
            recipient: address(leafOpenUsdtTokenBridge)
        });
        leafMailbox.processNextInboundMessage();
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), v3AmountIn);

        // Process Commitment message & check commitment was stored
        vm.expectEmit(address(leafMailbox));
        emit IMailbox.Process({
            origin: rootDomain,
            sender: TypeCasts.addressToBytes32(address(rootIcaRouter)),
            recipient: address(leafIcaRouter)
        });
        leafMailbox.processNextInboundMessage();
        assertTrue(OwnableMulticall(userICA).commitments(commitment));

        assertEq(ERC20(baseUSDC).balanceOf(users.alice), 0);
        assertEq(ERC20(WETH9_ADDRESS).balanceOf(users.alice), 0);

        // Self Relay the message. Swaps should fail & fallback transfer should succeed
        vm.expectEmit(OPEN_USDT_ADDRESS);
        emit ERC20.Transfer({from: userICA, to: users.alice, amount: v3AmountIn});
        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(userICA).revealAndExecute({calls: calls, salt: TypeCasts.addressToBytes32(users.alice)});

        // No leftover in the Router
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(address(leafRouter)), 0);
        assertEq(ERC20(baseUSDC).balanceOf(address(leafRouter)), 0);
        assertEq(ERC20(WETH9_ADDRESS).balanceOf(address(leafRouter)), 0);

        // No leftover in the ICA
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);
        assertEq(ERC20(baseUSDC).balanceOf(userICA), 0);
        assertEq(ERC20(WETH9_ADDRESS).balanceOf(userICA), 0);

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), v3AmountIn);
        assertEq(ERC20(baseUSDC).balanceOf(users.alice), 0);
        assertEq(ERC20(WETH9_ADDRESS).balanceOf(users.alice), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(userICA, address(leafRouter)), 0);
    }

    function test_executeCrosschainFlowMixedV3ExactInV2ExactInSecondSwapRevert() public {
        uint256 v3AmountIn = USDC_1;
        uint256 v3AmountOutMin = 999000;

        // Encode destination swaps & sweep
        bytes memory swapSubplan = abi.encodePacked(
            bytes1(uint8(Commands.V3_SWAP_EXACT_IN)),
            bytes1(uint8(Commands.V2_SWAP_EXACT_IN)),
            bytes1(uint8(Commands.SWEEP))
        );
        bytes[] memory swapInputs = new bytes[](3);

        // V3 Swap Inputs
        bytes memory v3Path = abi.encodePacked(OPEN_USDT_ADDRESS, int24(1), baseUSDC);
        swapInputs[0] = abi.encode(ActionConstants.ADDRESS_THIS, v3AmountIn, v3AmountOutMin, v3Path, true, false);

        // V2 Swap Inputs
        uint256 v2AmountIn = v3AmountOutMin;
        /// @dev Large v2AmountOutMin to simulate failure
        uint256 v2AmountOutMin = 606500898800000 * 2;
        bytes memory v2Path = abi.encodePacked(baseUSDC, false, WETH9_ADDRESS);
        swapInputs[1] = abi.encode(users.alice, v2AmountIn, v2AmountOutMin, v2Path, false, false);

        // Sweep leftover intermediary tokens to recipient
        swapInputs[2] = abi.encode(baseUSDC, users.alice, 0);

        // Encode fallback transfer
        bytes memory transferSubplan = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)));
        bytes[] memory transferInputs = new bytes[](1);
        transferInputs[0] = abi.encode(OPEN_USDT_ADDRESS, users.alice, Constants.TOTAL_BALANCE);

        // Encode Sub Plan
        bytes memory leafCommands = abi.encodePacked(
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT,
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT
        );
        bytes[] memory leafInputs = new bytes[](2);
        leafInputs[0] = abi.encode(swapSubplan, swapInputs);
        leafInputs[1] = abi.encode(transferSubplan, transferInputs);

        // Encode ICA calls
        CallLib.Call[] memory calls = new CallLib.Call[](2);
        calls[0] = CallLib.build({
            to: OPEN_USDT_ADDRESS, value: 0, data: abi.encodeCall(ERC20.approve, (address(leafRouter), v3AmountIn))
        });
        calls[1] = CallLib.build({
            to: address(leafRouter), value: 0, data: abi.encodeCall(Dispatcher.execute, (leafCommands, leafInputs))
        });

        // Calculate commitment hash
        bytes32 commitment = hashCommitment({_calls: calls, _salt: TypeCasts.addressToBytes32(users.alice)});

        // Predict User's ICA address
        address payable userICA = payable(rootIcaRouter.getRemoteInterchainAccount({
                _destination: leafDomain, _owner: address(router), _userSalt: TypeCasts.addressToBytes32(users.alice)
            }));

        // Encode origin chain commands
        bytes memory commands =
            abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN)), bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN)));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            userICA,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            v3AmountIn,
            MESSAGE_FEE,
            0, // tokenFee
            leafDomain,
            true
        );
        inputs[1] = abi.encode(
            leafDomain, // destination domain
            address(rootIcaRouter), // origin ica router
            rootIcaRouter.routers(leafDomain), // destination ica router
            bytes32(0), // destination ism
            commitment, // commitment of the calls to be made
            MESSAGE_FEE, // fee to dispatch x-chain message
            address(0), // token
            0, // tokenFee
            rootIcaRouter.hook(), // post dispatch hook
            new bytes(0) // hook metadata
        );

        // Broadcast x-chain messages
        deal(OPEN_USDT_ADDRESS, users.alice, v3AmountIn);
        ERC20(OPEN_USDT_ADDRESS).approve(address(router), v3AmountIn);
        vm.expectCall({
            callee: address(rootIcaRouter),
            data: abi.encodeCall(
                IInterchainAccountRouter.callRemoteCommitReveal,
                (
                    leafDomain,
                    rootIcaRouter.routers(leafDomain),
                    bytes32(0),
                    new bytes(0),
                    IPostDispatchHook(address(rootIcaRouter.hook())),
                    TypeCasts.addressToBytes32(users.alice),
                    commitment
                )
            )
        });

        vm.expectEmit(address(router));
        emit Dispatcher.CrossChainSwap({
            caller: users.alice,
            localRouter: address(rootIcaRouter),
            destinationDomain: leafDomain,
            commitment: commitment
        });

        router.execute{value: MESSAGE_FEE * 2}(commands, inputs);

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);

        // Select Leaf & avoid underflow
        vm.selectFork(leafId);
        IPool pool = IPool(v2Factory.getPool(baseUSDC, WETH9_ADDRESS, false));
        uint256 last = pool.blockTimestampLast();

        // Set timestamp greater than last timestamp in Pool to avoid underflow
        vm.warp(last + 1);

        // Process Token Bridging message & check tokens arrived
        vm.expectEmit(address(leafMailbox));
        emit IMailbox.Process({
            origin: rootDomain,
            sender: TypeCasts.addressToBytes32(OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS),
            recipient: address(leafOpenUsdtTokenBridge)
        });
        leafMailbox.processNextInboundMessage();
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), v3AmountIn);

        // Process Commitment message & check commitment was stored
        vm.expectEmit(address(leafMailbox));
        emit IMailbox.Process({
            origin: rootDomain,
            sender: TypeCasts.addressToBytes32(address(rootIcaRouter)),
            recipient: address(leafIcaRouter)
        });
        leafMailbox.processNextInboundMessage();
        assertTrue(OwnableMulticall(userICA).commitments(commitment));

        assertEq(ERC20(baseUSDC).balanceOf(users.alice), 0);
        assertEq(ERC20(WETH9_ADDRESS).balanceOf(users.alice), 0);

        // Self Relay the message. Swaps should fail & fallback transfer should succeed
        vm.expectEmit(OPEN_USDT_ADDRESS);
        emit ERC20.Transfer({from: userICA, to: users.alice, amount: v3AmountIn});
        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(userICA).revealAndExecute({calls: calls, salt: TypeCasts.addressToBytes32(users.alice)});

        // No leftover in the Router
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(address(leafRouter)), 0);
        assertEq(ERC20(baseUSDC).balanceOf(address(leafRouter)), 0);
        assertEq(ERC20(WETH9_ADDRESS).balanceOf(address(leafRouter)), 0);

        // No leftover in the ICA
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);
        assertEq(ERC20(baseUSDC).balanceOf(userICA), 0);
        assertEq(ERC20(WETH9_ADDRESS).balanceOf(userICA), 0);

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), v3AmountIn);
        assertEq(ERC20(baseUSDC).balanceOf(users.alice), 0);
        assertEq(ERC20(WETH9_ADDRESS).balanceOf(users.alice), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(userICA, address(leafRouter)), 0);
    }

    function test_executeCrosschainFlowV3SwapExactInETHRefund() public {
        uint256 amountIn = USDC_1;
        uint256 amountOutMin = 9e5;
        uint256 leftoverETH = MESSAGE_FEE / 2;

        // Encode destination swap
        bytes memory swapSubplan = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_IN)));
        bytes memory path = abi.encodePacked(OPEN_USDT_ADDRESS, int24(1), baseUSDC);
        bytes[] memory swapInputs = new bytes[](1);
        swapInputs[0] = abi.encode(users.alice, amountIn, amountOutMin, path, true, false);

        // Encode fallback transfer
        bytes memory transferSubplan = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)));
        bytes[] memory transferInputs = new bytes[](1);
        transferInputs[0] = abi.encode(OPEN_USDT_ADDRESS, users.alice, Constants.TOTAL_BALANCE);

        // Encode Sub Plan
        bytes memory leafCommands = abi.encodePacked(
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT,
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT
        );
        bytes[] memory leafInputs = new bytes[](2);
        leafInputs[0] = abi.encode(swapSubplan, swapInputs);
        leafInputs[1] = abi.encode(transferSubplan, transferInputs);

        // Encode ICA calls
        CallLib.Call[] memory calls = new CallLib.Call[](2);
        calls[0] = CallLib.build({
            to: OPEN_USDT_ADDRESS, value: 0, data: abi.encodeCall(ERC20.approve, (address(leafRouter), amountIn))
        });
        calls[1] = CallLib.build({
            to: address(leafRouter), value: 0, data: abi.encodeCall(Dispatcher.execute, (leafCommands, leafInputs))
        });

        // Calculate commitment hash
        bytes32 commitment = hashCommitment({_calls: calls, _salt: TypeCasts.addressToBytes32(users.alice)});

        // Predict User's ICA address
        address payable userICA = payable(rootIcaRouter.getRemoteInterchainAccount({
                _destination: leafDomain, _owner: address(router), _userSalt: TypeCasts.addressToBytes32(users.alice)
            }));

        // Encode origin chain commands
        bytes memory commands =
            abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN)), bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN)));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            userICA,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            amountIn,
            MESSAGE_FEE,
            0, // tokenFee
            leafDomain,
            true
        );
        bytes memory hookMetadata = StandardHookMetadata.formatMetadata({
            _msgValue: uint256(0),
            _gasLimit: HypXERC20(OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS).destinationGas(rootDomain),
            _refundAddress: users.alice,
            _customMetadata: ''
        });
        inputs[1] = abi.encode(
            leafDomain, // destination domain
            address(rootIcaRouter), // origin ica router
            rootIcaRouter.routers(leafDomain), // destination ica router
            bytes32(0), // destination ism
            commitment, // commitment of the calls to be made
            MESSAGE_FEE + leftoverETH, // fee to dispatch x-chain message
            address(0), // token
            0, // tokenFee
            IPostDispatchHook(address(rootIcaRouter.hook())), // post dispatch hook
            hookMetadata // hook metadata
        );

        uint256 oldETHBal = users.alice.balance;

        // Broadcast x-chain messages
        deal(OPEN_USDT_ADDRESS, users.alice, amountIn);
        ERC20(OPEN_USDT_ADDRESS).approve(address(router), amountIn);
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
                    TypeCasts.addressToBytes32(users.alice),
                    commitment
                )
            )
        });

        vm.expectEmit(address(router));
        emit Dispatcher.CrossChainSwap({
            caller: users.alice,
            localRouter: address(rootIcaRouter),
            destinationDomain: leafDomain,
            commitment: commitment
        });

        router.execute{value: MESSAGE_FEE * 2 + leftoverETH}(commands, inputs);

        assertEq(address(router).balance, 0);
        assertEq(address(rootIcaRouter).balance, 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);
        // Assert excess fee was refunded (allow delta for hook fee variance across blocks)
        assertApproxEqAbs(users.alice.balance, oldETHBal - (MESSAGE_FEE + leftoverETH), 1e14);

        // Process Token Bridging message & check tokens arrived
        vm.selectFork(leafId);
        vm.expectEmit(address(leafMailbox));
        emit IMailbox.Process({
            origin: rootDomain,
            sender: TypeCasts.addressToBytes32(OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS),
            recipient: address(leafOpenUsdtTokenBridge)
        });
        leafMailbox.processNextInboundMessage();
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), amountIn);

        // Process Commitment message & check commitment was stored
        vm.expectEmit(address(leafMailbox));
        emit IMailbox.Process({
            origin: rootDomain,
            sender: TypeCasts.addressToBytes32(address(rootIcaRouter)),
            recipient: address(leafIcaRouter)
        });
        leafMailbox.processNextInboundMessage();
        assertTrue(OwnableMulticall(userICA).commitments(commitment));

        assertEq(ERC20(baseUSDC).balanceOf(users.alice), 0);

        // Self Relay the message & check swap was successful
        vm.expectEmit(address(leafRouter));
        emit Dispatcher.UniversalRouterSwap(userICA, users.alice);
        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(userICA).revealAndExecute({calls: calls, salt: TypeCasts.addressToBytes32(users.alice)});

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), 0); // no leftover input from swap in exactIn
        assertGt(ERC20(baseUSDC).balanceOf(users.alice), amountOutMin);
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(userICA, address(leafRouter)), 0);
    }

    function test_executeCrosschainICARefund() public {
        uint256 amount = USDC_1;

        // Predict User's ICA address
        address payable userICA = payable(rootIcaRouter.getRemoteInterchainAccount({
                _destination: leafDomain, _owner: address(router), _userSalt: TypeCasts.addressToBytes32(users.alice)
            }));

        // Bridge tokens to User's ICA to simulate stuck funds
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            userICA,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            amount,
            MESSAGE_FEE,
            0, // tokenFee
            leafDomain,
            true
        );

        // Broadcast bridge message
        deal(OPEN_USDT_ADDRESS, users.alice, amount);
        ERC20(OPEN_USDT_ADDRESS).approve(address(router), amount);
        router.execute{value: MESSAGE_FEE}(commands, inputs);

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);

        // Process Token Bridging message & check tokens arrived
        vm.selectFork(leafId);
        leafMailbox.processNextInboundMessage();
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), amount);

        vm.selectFork(rootId);

        // Encode refund ICA call
        CallLib.Call[] memory calls = new CallLib.Call[](1);
        calls[0] = CallLib.build({
            to: OPEN_USDT_ADDRESS, value: 0, data: abi.encodeCall(ERC20.transfer, (users.alice, amount))
        });

        // Calculate commitment hash
        bytes32 commitment = hashCommitment({_calls: calls, _salt: TypeCasts.addressToBytes32(users.alice)});

        // Encode origin chain command
        commands = abi.encodePacked(bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN)));
        inputs[0] = abi.encode(
            leafDomain, // destination domain
            address(rootIcaRouter), // origin ica router
            rootIcaRouter.routers(leafDomain), // destination ica router
            bytes32(0), // destination ism
            commitment, // commitment of the calls to be made
            MESSAGE_FEE, // fee to dispatch x-chain message
            address(0), // token
            0, // tokenFee
            rootIcaRouter.hook(), // post dispatch hook
            new bytes(0) // hook metadata
        );
        router.execute{value: MESSAGE_FEE}(commands, inputs);

        // Process Commitment message & check commitment was stored
        vm.selectFork(leafId);
        leafMailbox.processNextInboundMessage();
        assertTrue(OwnableMulticall(userICA).commitments(commitment));

        // Self Relay the message. Refund transfer should be executed
        vm.expectEmit(OPEN_USDT_ADDRESS);
        emit ERC20.Transfer({from: userICA, to: users.alice, amount: amount});
        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(userICA).revealAndExecute({calls: calls, salt: TypeCasts.addressToBytes32(users.alice)});

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), amount);
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(userICA), 0);
    }

    function test_RevertWhen_executeCrosschainInsufficientFee() public {
        uint256 amountIn = 10 ether;
        uint256 originAmountOutMin = 8e5;
        uint256 destinationAmountOutMin = 9e5;
        /// @dev Insufficient message fee
        uint256 msgFee = MESSAGE_FEE - 1;

        (,, bytes memory commands, bytes[] memory inputs) = _executeCrosschainParams({
            _amountIn: amountIn,
            _originAmountOutMin: originAmountOutMin,
            _destinationAmountOutMin: destinationAmountOutMin,
            _msgFee: MESSAGE_FEE,
            _leftoverETH: 0
        });

        deal(address(OP), users.alice, amountIn);
        OP.approve(address(router), amountIn);
        vm.expectRevert(); // OutOfFunds
        router.execute{value: MESSAGE_FEE}(commands, inputs);
    }

    function test_RevertWhen_executeCrosschainFeeGreaterThanContractBalance() public {
        uint256 amountIn = 10 ether;
        uint256 originAmountOutMin = 8e5;
        uint256 destinationAmountOutMin = 9e5;

        (,, bytes memory commands, bytes[] memory inputs) = _executeCrosschainParams({
            _amountIn: amountIn,
            _originAmountOutMin: originAmountOutMin,
            _destinationAmountOutMin: destinationAmountOutMin,
            _msgFee: MESSAGE_FEE,
            _leftoverETH: 0
        });

        deal(address(OP), users.alice, amountIn);
        OP.approve(address(router), amountIn);
        vm.expectRevert(); // OutOfFunds
        router.execute{value: MESSAGE_FEE}(commands, inputs); // @dev Fee only covers x-chain bridge command
    }

    function testGas_executeCrosschainOriginSuccess() public {
        uint256 amountIn = 10 ether;
        uint256 originAmountOutMin = 8e5;
        uint256 destinationAmountOutMin = 9e5;
        uint256 leftoverETH = MESSAGE_FEE / 2;

        (,, bytes memory commands, bytes[] memory inputs) = _executeCrosschainParams({
            _amountIn: amountIn,
            _originAmountOutMin: originAmountOutMin,
            _destinationAmountOutMin: destinationAmountOutMin,
            _msgFee: MESSAGE_FEE,
            _leftoverETH: leftoverETH
        });

        deal(address(OP), users.alice, amountIn);
        OP.approve(address(router), amountIn);
        router.execute{value: MESSAGE_FEE * 2 + leftoverETH}(commands, inputs);
        vm.snapshotGasLastCall('UniversalRouter_ExecuteCrossChain_Origin_Success');
    }

    function testGas_executeCrosschainOriginFallback() public {
        uint256 amountIn = 10 ether;
        uint256 originAmountOutMin = 8e5;
        /// @dev Setting `destinationAmountOutMin` too large to simulate destination swap failure
        uint256 destinationAmountOutMin = amountIn * 10;
        uint256 leftoverETH = MESSAGE_FEE / 2;

        (,, bytes memory commands, bytes[] memory inputs) = _executeCrosschainParams({
            _amountIn: amountIn,
            _originAmountOutMin: originAmountOutMin,
            _destinationAmountOutMin: destinationAmountOutMin,
            _msgFee: MESSAGE_FEE,
            _leftoverETH: leftoverETH
        });

        deal(address(OP), users.alice, amountIn);
        OP.approve(address(router), amountIn);
        router.execute{value: MESSAGE_FEE * 2 + leftoverETH}(commands, inputs);
        vm.snapshotGasLastCall('UniversalRouter_ExecuteCrossChain_Origin_Fallback');
    }

    function testGas_executeCrosschainDestinationSuccess() public {
        uint256 amountIn = 10 ether;
        uint256 originAmountOutMin = 8e5;
        uint256 destinationAmountOutMin = 9e5;
        uint256 leftoverETH = MESSAGE_FEE / 2;

        (address payable userICA, CallLib.Call[] memory calls, bytes memory commands, bytes[] memory inputs) = _executeCrosschainParams({
            _amountIn: amountIn,
            _originAmountOutMin: originAmountOutMin,
            _destinationAmountOutMin: destinationAmountOutMin,
            _msgFee: MESSAGE_FEE,
            _leftoverETH: leftoverETH
        });

        deal(address(OP), users.alice, amountIn);
        OP.approve(address(router), amountIn);
        router.execute{value: MESSAGE_FEE * 2 + leftoverETH}(commands, inputs);

        // Process Token Bridging & Commitment messages
        vm.selectFork(leafId);
        leafMailbox.processNextInboundMessage();
        leafMailbox.processNextInboundMessage();

        // Self Relay the message
        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(userICA).revealAndExecute({calls: calls, salt: TypeCasts.addressToBytes32(users.alice)});
        vm.snapshotGasLastCall('UniversalRouter_ExecuteCrossChain_Destination_Success');
    }

    function testGas_executeCrosschainDestinationFallback() public {
        uint256 amountIn = 10 ether;
        uint256 originAmountOutMin = 8e5;
        /// @dev Setting `destinationAmountOutMin` too large to simulate swap failure
        uint256 destinationAmountOutMin = amountIn * 10;
        uint256 leftoverETH = MESSAGE_FEE / 2;

        (address payable userICA, CallLib.Call[] memory calls, bytes memory commands, bytes[] memory inputs) = _executeCrosschainParams({
            _amountIn: amountIn,
            _originAmountOutMin: originAmountOutMin,
            _destinationAmountOutMin: destinationAmountOutMin,
            _msgFee: MESSAGE_FEE,
            _leftoverETH: leftoverETH
        });

        deal(address(OP), users.alice, amountIn);
        OP.approve(address(router), amountIn);
        router.execute{value: MESSAGE_FEE * 2 + leftoverETH}(commands, inputs);

        // Process Token Bridging & Commitment messages
        vm.selectFork(leafId);
        leafMailbox.processNextInboundMessage();
        leafMailbox.processNextInboundMessage();

        // Self Relay the message
        vm.startPrank({msgSender: users.alice});
        OwnableMulticall(userICA).revealAndExecute({calls: calls, salt: TypeCasts.addressToBytes32(users.alice)});
        vm.snapshotGasLastCall('UniversalRouter_ExecuteCrossChain_Destination_Fallback');
    }

    /// @dev Helper to generate the parameters for valid execute x-chain calls
    function _executeCrosschainParams(
        uint256 _amountIn,
        uint256 _originAmountOutMin,
        uint256 _destinationAmountOutMin,
        uint256 _msgFee,
        uint256 _leftoverETH
    )
        internal
        view
        returns (address payable userICA, CallLib.Call[] memory calls, bytes memory commands, bytes[] memory inputs)
    {
        // Encode destination swap
        bytes memory swapSubplan =
            abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)), bytes1(uint8(Commands.V3_SWAP_EXACT_IN)));
        bytes memory path = abi.encodePacked(OPEN_USDT_ADDRESS, int24(1), baseUSDC);
        bytes[] memory swapInputs = new bytes[](2);
        swapInputs[0] = abi.encode(OPEN_USDT_ADDRESS, address(leafRouter), Constants.TOTAL_BALANCE);
        swapInputs[1] =
            abi.encode(users.alice, ActionConstants.CONTRACT_BALANCE, _destinationAmountOutMin, path, false, false);

        // Encode fallback transfer
        bytes memory transferSubplan = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)));
        bytes[] memory transferInputs = new bytes[](1);
        transferInputs[0] = abi.encode(OPEN_USDT_ADDRESS, users.alice, Constants.TOTAL_BALANCE);

        // Encode Sub Plan
        bytes memory leafCommands = abi.encodePacked(
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT,
            bytes1(uint8(Commands.EXECUTE_SUB_PLAN)) | Commands.FLAG_ALLOW_REVERT
        );
        bytes[] memory leafInputs = new bytes[](2);
        leafInputs[0] = abi.encode(swapSubplan, swapInputs);
        leafInputs[1] = abi.encode(transferSubplan, transferInputs);

        // Encode ICA calls
        calls = new CallLib.Call[](3);
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

        // Calculate commitment hash
        bytes32 commitment = hashCommitment({_calls: calls, _salt: TypeCasts.addressToBytes32(users.alice)});

        // Predict User's ICA address
        userICA = payable(rootIcaRouter.getRemoteInterchainAccount({
                _destination: leafDomain, _owner: address(router), _userSalt: TypeCasts.addressToBytes32(users.alice)
            }));

        // Encode origin chain commands
        commands = abi.encodePacked(
            bytes1(uint8(Commands.V3_SWAP_EXACT_IN)),
            bytes1(uint8(Commands.BRIDGE_TOKEN)),
            bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN))
        );
        inputs = new bytes[](3);
        path = abi.encodePacked(address(OP), int24(100), OPEN_USDT_ADDRESS);
        inputs[0] = abi.encode(ActionConstants.ADDRESS_THIS, _amountIn, _originAmountOutMin, path, true, false);
        inputs[1] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            userICA,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            Constants.TOTAL_BALANCE,
            MESSAGE_FEE,
            0, // tokenFee
            leafDomain,
            false
        );
        bytes memory hookMetadata = StandardHookMetadata.formatMetadata({
            _msgValue: uint256(0),
            _gasLimit: HypXERC20(OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS).destinationGas(rootDomain),
            _refundAddress: users.alice,
            _customMetadata: ''
        });
        inputs[2] = abi.encode(
            leafDomain, // destination domain
            address(rootIcaRouter), // origin ica router
            rootIcaRouter.routers(leafDomain), // destination ica router
            bytes32(0), // destination ism
            commitment, // commitment of the calls to be made
            _msgFee + _leftoverETH, // fee to dispatch x-chain message
            address(0), // token
            0, // tokenFee
            rootIcaRouter.hook(), // post dispatch hook
            hookMetadata // hook metadata
        );
    }

    function createAndSeedPair(address tokenA, address tokenB, bool _stable) internal returns (address newPair) {
        address factory = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
        newPair = IPoolFactory(factory).getPool(tokenA, tokenB, _stable);
        if (newPair == address(0)) {
            newPair = IPoolFactory(factory).createPool(tokenA, tokenB, _stable);
        }

        deal(tokenA, address(this), 100 * 10 ** ERC20(tokenA).decimals());
        deal(tokenB, address(this), 100 * 10 ** ERC20(tokenB).decimals());

        ERC20(tokenA).transfer(address(newPair), 100 * 10 ** ERC20(tokenA).decimals());
        ERC20(tokenB).transfer(address(newPair), 100 * 10 ** ERC20(tokenB).decimals());
        IPool(newPair).mint(address(this));
    }
}

/// @dev Unit tests for BALANCE_CHECK_ERC20 used as a bridge-delivery gate on
///      the destination-side committed commands string. These run against a
///      freshly-deployed UniversalRouter without forks — they assert the
///      encoding contract the origin-side encoder must honour so the
///      reference superswap flow (ExecuteCrossChainTest above) is safe
///      against the reveal-before-bridge race.
contract BalanceCheckGateTest is Test {
    address constant RECIPIENT = address(1234);
    uint256 constant AMOUNT = 10 ** 18;

    UniversalRouter router;
    MockERC20 erc20;

    function setUp() public {
        RouterDeployParameters memory params = RouterDeployParameters({
            permit2: address(0),
            weth9: address(0),
            v2Factory: address(0),
            v3Factory: address(0),
            pairInitCodeHash: bytes32(0),
            poolInitCodeHash: bytes32(0),
            v4PoolManager: address(0),
            veloV2Factory: address(0),
            veloCLFactory: address(0),
            veloV2InitCodeHash: bytes32(0),
            veloCLInitCodeHash: bytes32(0),
            veloCLFactory2: address(0),
            veloCLInitCodeHash2: bytes32(0),
            veloCLFactory3: address(0),
            veloCLInitCodeHash3: bytes32(0)
        });
        router = new UniversalRouter(params);
        erc20 = new MockERC20();
    }

    // ---------------------------------------------------------------------
    // BALANCE_CHECK_ERC20 as a bridge-delivery gate
    //
    // The `minBalance` of the destination-side BALANCE_CHECK_ERC20 is the
    // same value encoded as `amount` in the origin-side BRIDGE_TOKEN input.
    // Prepending an un-flagged BALANCE_CHECK_ERC20 to the committed commands
    // string makes execute() revert until the ICA's balance reaches that
    // amount — i.e. until the bridge lands. The outer revealAndExecute then
    // reverts, the Mailbox does not mark the message processed, and the
    // relayer retries until funds arrive. No new contracts needed.
    // ---------------------------------------------------------------------

    /// @dev Encodes an origin-side BRIDGE_TOKEN input with the given
    ///      `transferRemoteAmount` in the `amount` slot. The other fields
    ///      are filler for the purposes of this unit test — only the amount
    ///      matters for the destination-side balance-check coupling.
    function _encodeBridgeTokenInput(uint256 transferRemoteAmount)
        internal
        view
        returns (bytes memory bridgeTokenInput)
    {
        // BRIDGE_TOKEN layout: (uint8, address, address, address, uint256, uint256, uint256, uint32, bool)
        // fields:              (type,  recipient, token, bridge, amount, msgFee, maxTokenFee, domain, payerIsUser)
        return abi.encode(
            uint8(0), RECIPIENT, address(erc20), address(0), transferRemoteAmount, uint256(0), uint256(0), uint32(0), false
        );
    }

    /// @dev Mirrors what the origin encoder should do: decode `amount` out of
    ///      the BRIDGE_TOKEN input it just built and re-use it verbatim as
    ///      `minBalance` in the destination-side BALANCE_CHECK_ERC20 input.
    function _encodeBalanceCheckFromBridgeInput(address ica, bytes memory bridgeTokenInput)
        internal
        view
        returns (bytes memory balanceCheckInput)
    {
        (,,,, uint256 transferRemoteAmount,,,,) =
            abi.decode(bridgeTokenInput, (uint8, address, address, address, uint256, uint256, uint256, uint32, bool));
        return abi.encode(ica, address(erc20), transferRemoteAmount);
    }

    function testBalanceCheckGate_RevertsWhenBridgeNotLanded() public {
        address ica = address(router); // unit-test stand-in for the ICA multicall caller
        bytes memory bridgeInput = _encodeBridgeTokenInput(AMOUNT);

        // commands = [BALANCE_CHECK_ERC20, SWEEP]
        // byte 0x0e has FLAG_ALLOW_REVERT clear, so a failed balance check
        // bubbles as ExecutionFailed instead of being silently skipped.
        bytes memory commands =
            abi.encodePacked(bytes1(uint8(Commands.BALANCE_CHECK_ERC20)), bytes1(uint8(Commands.SWEEP)));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = _encodeBalanceCheckFromBridgeInput(ica, bridgeInput);
        inputs[1] = abi.encode(address(erc20), RECIPIENT, 0);

        // Bridge has NOT landed: router holds 0 of the transfer token.
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniversalRouter.ExecutionFailed.selector,
                uint256(0),
                abi.encodePacked(Dispatcher.BalanceTooLow.selector)
            )
        );
        router.execute(commands, inputs);
    }

    function testBalanceCheckGate_SucceedsAfterBridgeLands() public {
        address ica = address(router);
        bytes memory bridgeInput = _encodeBridgeTokenInput(AMOUNT);
        (,,,, uint256 transferRemoteAmount,,,,) =
            abi.decode(bridgeInput, (uint8, address, address, address, uint256, uint256, uint256, uint32, bool));

        bytes memory commands =
            abi.encodePacked(bytes1(uint8(Commands.BALANCE_CHECK_ERC20)), bytes1(uint8(Commands.SWEEP)));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = _encodeBalanceCheckFromBridgeInput(ica, bridgeInput);
        inputs[1] = abi.encode(address(erc20), RECIPIENT, transferRemoteAmount);

        // Simulate the bridge landing by crediting the ICA exactly the
        // `transferRemote` amount.
        erc20.mint(ica, transferRemoteAmount);

        assertEq(erc20.balanceOf(RECIPIENT), 0);
        router.execute(commands, inputs);
        assertEq(erc20.balanceOf(RECIPIENT), transferRemoteAmount);
    }

    function testBalanceCheckGate_RetrySemantics() public {
        // Same commands/inputs replayed across two attempts, mirroring what
        // the relayer does: first attempt reverts (bridge not landed),
        // second attempt succeeds once funds arrive.
        address ica = address(router);
        bytes memory bridgeInput = _encodeBridgeTokenInput(AMOUNT);
        (,,,, uint256 transferRemoteAmount,,,,) =
            abi.decode(bridgeInput, (uint8, address, address, address, uint256, uint256, uint256, uint32, bool));

        bytes memory commands =
            abi.encodePacked(bytes1(uint8(Commands.BALANCE_CHECK_ERC20)), bytes1(uint8(Commands.SWEEP)));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = _encodeBalanceCheckFromBridgeInput(ica, bridgeInput);
        inputs[1] = abi.encode(address(erc20), RECIPIENT, transferRemoteAmount);

        // Attempt 1: pre-bridge.
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniversalRouter.ExecutionFailed.selector,
                uint256(0),
                abi.encodePacked(Dispatcher.BalanceTooLow.selector)
            )
        );
        router.execute(commands, inputs);

        // Bridge lands between retries with the exact transferRemote amount.
        erc20.mint(ica, transferRemoteAmount);

        // Attempt 2: same payload, now succeeds.
        router.execute(commands, inputs);
        assertEq(erc20.balanceOf(RECIPIENT), transferRemoteAmount);
    }

    function testBalanceCheckGate_RevertsWhenPartiallyDelivered() public {
        // If only a fraction of the transferRemote amount has arrived (e.g.
        // a stale dust balance in the ICA from a prior flow), the gate must
        // still revert — it keys off the exact amount encoded at origin.
        address ica = address(router);
        bytes memory bridgeInput = _encodeBridgeTokenInput(AMOUNT);
        (,,,, uint256 transferRemoteAmount,,,,) =
            abi.decode(bridgeInput, (uint8, address, address, address, uint256, uint256, uint256, uint32, bool));

        bytes memory commands =
            abi.encodePacked(bytes1(uint8(Commands.BALANCE_CHECK_ERC20)), bytes1(uint8(Commands.SWEEP)));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = _encodeBalanceCheckFromBridgeInput(ica, bridgeInput);
        inputs[1] = abi.encode(address(erc20), RECIPIENT, 0);

        // ICA has strictly less than the transferRemote amount.
        erc20.mint(ica, transferRemoteAmount - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IUniversalRouter.ExecutionFailed.selector,
                uint256(0),
                abi.encodePacked(Dispatcher.BalanceTooLow.selector)
            )
        );
        router.execute(commands, inputs);
    }

    // ---------------------------------------------------------------------
    // HYP_ERC20_COLLATERAL compatibility
    //
    // For collateral routes, BRIDGE_TOKEN.input.amount is the user-supplied
    // total, but transferRemote is called with `bridgeAmount` derived via
    // BridgeRouter.quoteExactInputBridgeAmount such that
    //   bridgeAmount + fee(bridgeAmount) ≈ amount
    // so bridgeAmount < amount whenever there are non-zero internal/external
    // fees. The origin encoder must therefore pre-call the quote off-chain
    // and embed `minBalance = bridgeAmount` (NOT `input.amount`) in the
    // destination-side BALANCE_CHECK_ERC20 input — otherwise the gate
    // over-gates and the reveal is stuck forever.
    // ---------------------------------------------------------------------

    address constant MOCK_BRIDGE = address(0xB1D6E);
    uint32 constant DEST_DOMAIN = 8453;

    /// @dev Mocks ITokenFee.quoteTransferRemote with the given 3-quote shape.
    function _mockBridgeQuote(uint256 amount, Quote[3] memory quotes) internal {
        Quote[] memory arr = new Quote[](3);
        arr[0] = quotes[0];
        arr[1] = quotes[1];
        arr[2] = quotes[2];
        vm.mockCall(
            MOCK_BRIDGE,
            abi.encodeCall(ITokenFee.quoteTransferRemote, (DEST_DOMAIN, TypeCasts.addressToBytes32(RECIPIENT), amount)),
            abi.encode(arr)
        );
    }

    /// @dev Mirror of BridgeRouter.quoteExactInputBridgeAmount — stands in for
    ///      the client UI's off-chain computation. The UI calls
    ///      ITokenFee.quoteTransferRemote (already external view) and applies
    ///      this formula in TS; no contract change required.
    function _clientSideBridgeAmount(address token, uint256 amount) internal view returns (uint256) {
        Quote[] memory quotes =
            ITokenFee(MOCK_BRIDGE).quoteTransferRemote(DEST_DOMAIN, TypeCasts.addressToBytes32(RECIPIENT), amount);
        uint256 igpTokenFee = (quotes[0].token == token) ? quotes[0].amount : 0;
        return ((amount - igpTokenFee) * amount) / (quotes[1].amount + quotes[2].amount);
    }

    function testBalanceCheckGate_CollateralBridge_EncodesTransferRemoteAmount() public {
        // Setup: user provides 1000 USDC, bridge has a 5 bps internal fee.
        address ica = address(router);
        uint256 userAmount = 1000e6;
        uint256 internalFee = 500000; // 5 bps of 1000 USDC
        _mockBridgeQuote(
            userAmount,
            [
                Quote({token: address(0), amount: 69e9}), // native IGP
                Quote({token: address(erc20), amount: userAmount + internalFee}),
                Quote({token: address(erc20), amount: 0})
            ]
        );

        // Client UI derives bridgeAmount off-chain via quoteTransferRemote
        // + the one-line formula (no BridgeRouter changes, no harness).
        uint256 bridgeAmount = _clientSideBridgeAmount(address(erc20), userAmount);
        assertLt(bridgeAmount, userAmount, 'collateral fees: bridgeAmount < userAmount');

        // Commitment encodes minBalance = bridgeAmount (transferRemote amount),
        // NOT userAmount.
        bytes memory commands =
            abi.encodePacked(bytes1(uint8(Commands.BALANCE_CHECK_ERC20)), bytes1(uint8(Commands.SWEEP)));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(ica, address(erc20), bridgeAmount);
        inputs[1] = abi.encode(address(erc20), RECIPIENT, bridgeAmount);

        // Pre-bridge: router holds nothing → gate reverts, relayer retries.
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniversalRouter.ExecutionFailed.selector,
                uint256(0),
                abi.encodePacked(Dispatcher.BalanceTooLow.selector)
            )
        );
        router.execute(commands, inputs);

        // Bridge lands: destination mints `bridgeAmount` to the ICA (this is
        // exactly transferRemote._amount for HypERC20Collateral — no dest skim).
        erc20.mint(ica, bridgeAmount);

        // Gate unblocks even though userAmount never arrived.
        router.execute(commands, inputs);
        assertEq(erc20.balanceOf(RECIPIENT), bridgeAmount);
    }

    function testBalanceCheckGate_CollateralBridge_OriginSwapFloorAsMinBalance() public {
        // Real Superswap flow: the amount entering BRIDGE_TOKEN is the
        // *output* of an origin-side swap, unknown at commitment-build time.
        // The UI therefore can't pre-compute an exact bridgeAmount. Instead
        // it uses the origin swap's slippage-protected floor (minAmountOut)
        // to derive a worst-case bridgeAmount, and encodes that as minBalance.
        // Because actualOriginOut >= minAmountOut is enforced on origin, and
        // bridgeAmount is monotonic in amount, the realised ICA balance will
        // always be >= the encoded minBalance.
        address ica = address(router);
        uint256 minAmountOut = 1000e6; // origin swap slippage floor
        uint256 actualOriginOut = 1020e6; // realized swap output — 2% above floor
        uint256 feeBps = 5; // 5 bps internal fee, constant across amounts

        // UI pre-quotes the bridge with minAmountOut (not expected output).
        _mockBridgeQuote(
            minAmountOut,
            [
                Quote({token: address(0), amount: 69e9}),
                Quote({token: address(erc20), amount: minAmountOut + (minAmountOut * feeBps / 10_000)}),
                Quote({token: address(erc20), amount: 0})
            ]
        );
        uint256 minBridgeAmount = _clientSideBridgeAmount(address(erc20), minAmountOut);

        // Destination commitment uses minBridgeAmount as minBalance.
        bytes memory commands =
            abi.encodePacked(bytes1(uint8(Commands.BALANCE_CHECK_ERC20)), bytes1(uint8(Commands.SWEEP)));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(ica, address(erc20), minBridgeAmount);
        inputs[1] = abi.encode(address(erc20), RECIPIENT, minBridgeAmount);

        // Simulate the full origin-side flow: at execution time the bridge is
        // quoted with actualOriginOut, and transferRemote delivers
        // actualBridgeAmount to the destination ICA.
        _mockBridgeQuote(
            actualOriginOut,
            [
                Quote({token: address(0), amount: 69e9}),
                Quote({token: address(erc20), amount: actualOriginOut + (actualOriginOut * feeBps / 10_000)}),
                Quote({token: address(erc20), amount: 0})
            ]
        );
        uint256 actualBridgeAmount = _clientSideBridgeAmount(address(erc20), actualOriginOut);

        // Monotonicity invariant — the property the gate relies on.
        assertGe(actualBridgeAmount, minBridgeAmount, 'bridgeAmount must be monotonic in origin output');

        // Bridge lands with the actual (not floor) amount.
        erc20.mint(ica, actualBridgeAmount);

        // Gate passes — actualBridgeAmount >= minBridgeAmount, even though
        // the UI had no exact value at commitment time.
        router.execute(commands, inputs);
        assertEq(erc20.balanceOf(RECIPIENT), actualBridgeAmount);
    }

    function testBalanceCheckGate_CollateralBridge_NaiveEncodingStuckForever() public {
        // Footgun: if the encoder naively uses BRIDGE_TOKEN.input.amount as
        // minBalance, the ICA can only ever receive bridgeAmount < userAmount
        // so the gate NEVER passes and the reveal is stuck forever.
        address ica = address(router);
        uint256 userAmount = 1000e6;
        uint256 internalFee = 500000;
        _mockBridgeQuote(
            userAmount,
            [
                Quote({token: address(0), amount: 69e9}),
                Quote({token: address(erc20), amount: userAmount + internalFee}),
                Quote({token: address(erc20), amount: 0})
            ]
        );
        uint256 bridgeAmount = _clientSideBridgeAmount(address(erc20), userAmount);

        // Naive (WRONG) encoding: minBalance = userAmount.
        bytes memory commands =
            abi.encodePacked(bytes1(uint8(Commands.BALANCE_CHECK_ERC20)), bytes1(uint8(Commands.SWEEP)));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(ica, address(erc20), userAmount);
        inputs[1] = abi.encode(address(erc20), RECIPIENT, 0);

        // Simulate the bridge landing: ICA receives the full bridgeAmount,
        // which is the MOST it can ever receive from this route.
        erc20.mint(ica, bridgeAmount);

        // Gate still reverts: bridgeAmount < userAmount. Stuck forever.
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniversalRouter.ExecutionFailed.selector,
                uint256(0),
                abi.encodePacked(Dispatcher.BalanceTooLow.selector)
            )
        );
        router.execute(commands, inputs);
    }

    function testBalanceCheckAllowRevert_DoesNotGate() public {
        // Sanity check: with FLAG_ALLOW_REVERT (0x80) set on the balance
        // check, a failing balance check is silently skipped. This is the
        // footgun we are *avoiding* by using the un-flagged form above.
        address ica = address(router);
        bytes memory bridgeInput = _encodeBridgeTokenInput(AMOUNT);

        bytes memory commands = abi.encodePacked(
            bytes1(uint8(Commands.BALANCE_CHECK_ERC20) | 0x80), // allow-revert set
            bytes1(uint8(Commands.SWEEP))
        );
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = _encodeBalanceCheckFromBridgeInput(ica, bridgeInput);
        inputs[1] = abi.encode(address(erc20), RECIPIENT, 0);

        // Router holds nothing, but allow-revert swallows the failure and
        // the sweep (amountMin=0) happily transfers nothing.
        router.execute(commands, inputs);
        assertEq(erc20.balanceOf(RECIPIENT), 0);
    }
}
