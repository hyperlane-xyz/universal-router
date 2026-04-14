// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ActionConstants} from '@uniswap/v4-periphery/src/libraries/ActionConstants.sol';
import {QuotedCalls} from '@hyperlane/core/contracts/token/QuotedCalls.sol';
import {Commands} from '../../../../contracts/libraries/Commands.sol';
import {Constants} from '../../../../contracts/libraries/Constants.sol';
import {TypeCasts} from '@hyperlane/core/contracts/libs/TypeCasts.sol';
import './BaseOverrideBridge.sol';

library QuotedCallsCommands {
    uint256 internal constant PERMIT2_TRANSFER_FROM = 0x02;
    uint256 internal constant TRANSFER_FROM = 0x03;
    uint256 internal constant TRANSFER_REMOTE = 0x04;
    uint256 internal constant SWEEP = 0x08;
}

contract BridgeTokenTest is BaseOverrideBridge {
    uint256 internal constant QUOTED_CALLS_CONTRACT_BALANCE =
        0x8000000000000000000000000000000000000000000000000000000000000000;
    uint256 internal constant QUOTED_CALLS_BRIDGE_EXACT_IN =
        0x8000000000000000000000000000000000000000000000000000000000000001;

    uint256 public openUsdtBridgeAmount = USDC_1 * 1000;
    uint256 public openUsdtInitialBal = openUsdtBridgeAmount * 2;
    uint256 public usdcBridgeAmount = 1000 * USDC_1;
    uint256 public usdcInitialBal = usdcBridgeAmount * 2;

    uint256 public constant MESSAGE_FEE = 1 ether / 10_000;

    uint32 internal constant MOCK_DOMAIN = 111;

    function setUp() public override {
        super.setUp();

        deal(address(users.alice), 1 ether);
        deal(OPEN_USDT_ADDRESS, users.alice, openUsdtInitialBal);
        deal(OPTIMISM_USDC_ADDRESS, users.alice, usdcInitialBal);

        vm.selectFork(leafId);
        deal(BASE_USDC_ADDRESS, USDC_BASE_BRIDGE, usdcInitialBal);
        vm.selectFork(rootId);

        vm.startPrank({msgSender: users.alice});
    }

    function test_WhenRecipientIsZeroAddress() external {
        (bytes memory commands, bytes[] memory inputs) = _encodeHypXERC20Bridge({
            usePermit2: false,
            pullAmount: openUsdtBridgeAmount,
            bridgeAmount: openUsdtBridgeAmount,
            bridgeValue: MESSAGE_FEE,
            domain: leafDomain,
            recipient: bytes32(0),
            token: OPEN_USDT_ADDRESS,
            sweepETH: false
        });

        ERC20(OPEN_USDT_ADDRESS).approve(address(router), type(uint256).max);
        vm.expectRevert();
        router.execute{value: MESSAGE_FEE}(commands, inputs);
    }

    function test_WhenMessageFeeIsSmallerThanContractBalance() external {
        (bytes memory commands, bytes[] memory inputs) = _encodeHypXERC20Bridge({
            usePermit2: false,
            pullAmount: openUsdtBridgeAmount,
            bridgeAmount: openUsdtBridgeAmount,
            bridgeValue: MESSAGE_FEE,
            domain: leafDomain,
            recipient: TypeCasts.addressToBytes32(users.alice),
            token: OPEN_USDT_ADDRESS,
            sweepETH: false
        });

        ERC20(OPEN_USDT_ADDRESS).approve(address(router), type(uint256).max);
        vm.expectRevert();
        router.execute{value: MESSAGE_FEE - 1}(commands, inputs);
    }

    function test_WhenTokenIsNotTheBridgeToken() external {
        (bytes memory commands, bytes[] memory inputs) = _encodeHypXERC20Bridge({
            usePermit2: false,
            pullAmount: openUsdtBridgeAmount,
            bridgeAmount: openUsdtBridgeAmount,
            bridgeValue: MESSAGE_FEE,
            domain: leafDomain,
            recipient: TypeCasts.addressToBytes32(users.alice),
            token: OPTIMISM_USDC_ADDRESS,
            sweepETH: false
        });

        ERC20(OPTIMISM_USDC_ADDRESS).approve(address(router), type(uint256).max);
        vm.expectRevert();
        router.execute{value: MESSAGE_FEE}(commands, inputs);
    }

    function test_WhenNoTokenApprovalWasGiven() external {
        (bytes memory commands, bytes[] memory inputs) = _encodeHypXERC20Bridge({
            usePermit2: false,
            pullAmount: openUsdtBridgeAmount,
            bridgeAmount: openUsdtBridgeAmount,
            bridgeValue: MESSAGE_FEE,
            domain: leafDomain,
            recipient: TypeCasts.addressToBytes32(users.alice),
            token: OPEN_USDT_ADDRESS,
            sweepETH: false
        });

        vm.expectRevert();
        router.execute{value: MESSAGE_FEE}(commands, inputs);
    }

    function test_WhenNoPermit2ApprovalWasGiven() external {
        (bytes memory commands, bytes[] memory inputs) = _encodeHypXERC20Bridge({
            usePermit2: true,
            pullAmount: openUsdtBridgeAmount,
            bridgeAmount: openUsdtBridgeAmount,
            bridgeValue: MESSAGE_FEE,
            domain: leafDomain,
            recipient: TypeCasts.addressToBytes32(users.alice),
            token: OPEN_USDT_ADDRESS,
            sweepETH: false
        });

        vm.expectRevert(abi.encodeWithSelector(IAllowanceTransfer.AllowanceExpired.selector, 0));
        router.execute{value: MESSAGE_FEE}(commands, inputs);
    }

    function test_WhenDomainIsZero() external {
        _approveOpenUsdtWithPermit2();
        (bytes memory commands, bytes[] memory inputs) = _encodeHypXERC20Bridge({
            usePermit2: true,
            pullAmount: openUsdtBridgeAmount,
            bridgeAmount: openUsdtBridgeAmount,
            bridgeValue: MESSAGE_FEE,
            domain: 0,
            recipient: TypeCasts.addressToBytes32(users.alice),
            token: OPEN_USDT_ADDRESS,
            sweepETH: false
        });

        vm.expectRevert(bytes('No router enrolled for domain: 0'));
        router.execute{value: MESSAGE_FEE}(commands, inputs);
    }

    function test_WhenDomainIsNotRegistered() external {
        _approveOpenUsdtWithPermit2();
        (bytes memory commands, bytes[] memory inputs) = _encodeHypXERC20Bridge({
            usePermit2: true,
            pullAmount: openUsdtBridgeAmount,
            bridgeAmount: openUsdtBridgeAmount,
            bridgeValue: MESSAGE_FEE,
            domain: MOCK_DOMAIN,
            recipient: TypeCasts.addressToBytes32(users.alice),
            token: OPEN_USDT_ADDRESS,
            sweepETH: false
        });

        vm.expectRevert(bytes('No router enrolled for domain: 111'));
        router.execute{value: MESSAGE_FEE}(commands, inputs);
    }

    function test_WhenDomainIsTheSameAsSourceDomain() external {
        _approveOpenUsdtWithPermit2();
        (bytes memory commands, bytes[] memory inputs) = _encodeHypXERC20Bridge({
            usePermit2: true,
            pullAmount: openUsdtBridgeAmount,
            bridgeAmount: openUsdtBridgeAmount,
            bridgeValue: MESSAGE_FEE,
            domain: rootDomain,
            recipient: TypeCasts.addressToBytes32(users.alice),
            token: OPEN_USDT_ADDRESS,
            sweepETH: false
        });

        vm.expectRevert(bytes('No router enrolled for domain: 10'));
        router.execute{value: MESSAGE_FEE}(commands, inputs);
    }

    function test_RevertWhen_FeeIsInsufficient() external {
        _approveOpenUsdtWithPermit2();
        (bytes memory commands, bytes[] memory inputs) = _encodeHypXERC20Bridge({
            usePermit2: true,
            pullAmount: openUsdtBridgeAmount,
            bridgeAmount: openUsdtBridgeAmount,
            bridgeValue: MESSAGE_FEE,
            domain: leafDomain,
            recipient: TypeCasts.addressToBytes32(users.alice),
            token: OPEN_USDT_ADDRESS,
            sweepETH: false
        });

        vm.expectRevert();
        router.execute(commands, inputs);
    }

    function test_WhenAmountIsEqualToContractBalanceConstant_Permit2() external {
        _approveOpenUsdtWithPermit2();
        (bytes memory commands, bytes[] memory inputs) = _encodeHypXERC20Bridge({
            usePermit2: true,
            pullAmount: openUsdtInitialBal,
            bridgeAmount: QUOTED_CALLS_CONTRACT_BALANCE,
            bridgeValue: MESSAGE_FEE,
            domain: leafDomain,
            recipient: TypeCasts.addressToBytes32(users.alice),
            token: OPEN_USDT_ADDRESS,
            sweepETH: true
        });

        uint256 balanceBefore = users.alice.balance;
        router.execute{value: MESSAGE_FEE + MESSAGE_FEE / 2}(commands, inputs);
        assertApproxEqAbs(users.alice.balance, balanceBefore - MESSAGE_FEE, 1e14);
        _assertOpenUsdtBridged(openUsdtInitialBal);
    }

    function test_WhenAmountIsNotEqualToContractBalanceConstant_Permit2() external {
        _approveOpenUsdtWithPermit2();
        (bytes memory commands, bytes[] memory inputs) = _encodeHypXERC20Bridge({
            usePermit2: true,
            pullAmount: openUsdtBridgeAmount,
            bridgeAmount: openUsdtBridgeAmount,
            bridgeValue: MESSAGE_FEE,
            domain: leafDomain,
            recipient: TypeCasts.addressToBytes32(users.alice),
            token: OPEN_USDT_ADDRESS,
            sweepETH: true
        });

        uint256 balanceBefore = users.alice.balance;
        router.execute{value: MESSAGE_FEE + MESSAGE_FEE / 2}(commands, inputs);
        assertApproxEqAbs(users.alice.balance, balanceBefore - MESSAGE_FEE, 1e14);
        _assertOpenUsdtBridged(openUsdtBridgeAmount);
    }

    function test_WhenAmountIsEqualToContractBalanceConstant_DirectApproval() external {
        ERC20(OPEN_USDT_ADDRESS).approve(address(router), type(uint256).max);
        (bytes memory commands, bytes[] memory inputs) = _encodeHypXERC20Bridge({
            usePermit2: false,
            pullAmount: openUsdtInitialBal,
            bridgeAmount: QUOTED_CALLS_CONTRACT_BALANCE,
            bridgeValue: MESSAGE_FEE,
            domain: leafDomain,
            recipient: TypeCasts.addressToBytes32(users.alice),
            token: OPEN_USDT_ADDRESS,
            sweepETH: true
        });

        uint256 balanceBefore = users.alice.balance;
        router.execute{value: MESSAGE_FEE + MESSAGE_FEE / 2}(commands, inputs);
        assertApproxEqAbs(users.alice.balance, balanceBefore - MESSAGE_FEE, 1e14);
        _assertOpenUsdtBridged(openUsdtInitialBal);
    }

    function test_WhenAmountIsNotEqualToContractBalanceConstant_DirectApproval() external {
        ERC20(OPEN_USDT_ADDRESS).approve(address(router), type(uint256).max);
        (bytes memory commands, bytes[] memory inputs) = _encodeHypXERC20Bridge({
            usePermit2: false,
            pullAmount: openUsdtBridgeAmount,
            bridgeAmount: openUsdtBridgeAmount,
            bridgeValue: MESSAGE_FEE,
            domain: leafDomain,
            recipient: TypeCasts.addressToBytes32(users.alice),
            token: OPEN_USDT_ADDRESS,
            sweepETH: true
        });

        uint256 balanceBefore = users.alice.balance;
        router.execute{value: MESSAGE_FEE + MESSAGE_FEE / 2}(commands, inputs);
        assertApproxEqAbs(users.alice.balance, balanceBefore - MESSAGE_FEE, 1e14);
        _assertOpenUsdtBridged(openUsdtBridgeAmount);
    }

    function test_HypERC20Collateral_WhenTokenIsNotTheBridgeToken() external {
        (bytes memory commands, bytes[] memory inputs) = _encodeHypErc20CollateralBridge({
            usePermit2: false,
            token: VELO_ADDRESS,
            sweepETH: true
        });

        vm.expectRevert();
        router.execute{value: MESSAGE_FEE}(commands, inputs);
    }

    function test_HypERC20Collateral_WhenNoTokenApprovalWasGiven() external {
        (bytes memory commands, bytes[] memory inputs) = _encodeHypErc20CollateralBridge({
            usePermit2: true,
            token: OPTIMISM_USDC_ADDRESS,
            sweepETH: true
        });

        vm.expectRevert(abi.encodeWithSelector(IAllowanceTransfer.AllowanceExpired.selector, 0));
        router.execute{value: MESSAGE_FEE}(commands, inputs);
    }

    function test_HypERC20Collateral_WhenUsingPermit2() external {
        _approveUsdcWithPermit2();
        (bytes memory commands, bytes[] memory inputs) = _encodeHypErc20CollateralBridge({
            usePermit2: true,
            token: OPTIMISM_USDC_ADDRESS,
            sweepETH: true
        });

        uint256 balanceBefore = users.alice.balance;
        router.execute{value: MESSAGE_FEE}(commands, inputs);
        assertEq(users.alice.balance, balanceBefore - MESSAGE_FEE);
        assertEq(ERC20(OPTIMISM_USDC_ADDRESS).balanceOf(users.alice), usdcInitialBal - usdcBridgeAmount);

        vm.selectFork(leafId);
        leafMailbox.processNextInboundMessage();

        uint256 leafBalance = ERC20(BASE_USDC_ADDRESS).balanceOf(users.alice);
        assertGt(leafBalance, 0);
        assertLt(leafBalance, usdcBridgeAmount);
        assertApproxEqAbs(leafBalance, usdcBridgeAmount, USDC_1);
    }

    function test_HypERC20Collateral_WhenUsingDirectApproval() external {
        ERC20(OPTIMISM_USDC_ADDRESS).approve(address(router), type(uint256).max);
        (bytes memory commands, bytes[] memory inputs) = _encodeHypErc20CollateralBridge({
            usePermit2: false,
            token: OPTIMISM_USDC_ADDRESS,
            sweepETH: true
        });

        uint256 balanceBefore = users.alice.balance;
        router.execute{value: MESSAGE_FEE}(commands, inputs);
        assertEq(users.alice.balance, balanceBefore - MESSAGE_FEE);
        assertEq(ERC20(OPTIMISM_USDC_ADDRESS).balanceOf(users.alice), usdcInitialBal - usdcBridgeAmount);

        vm.selectFork(leafId);
        leafMailbox.processNextInboundMessage();

        uint256 leafBalance = ERC20(BASE_USDC_ADDRESS).balanceOf(users.alice);
        assertGt(leafBalance, 0);
        assertLt(leafBalance, usdcBridgeAmount);
        assertApproxEqAbs(leafBalance, usdcBridgeAmount, USDC_1);
    }

    function test_HypERC20Collateral_WhenUsingBridgeExactInSentinelAfterSwap() external {
        uint256 amountIn = 10 ether;
        uint256 amountOutMin = 3e6;

        bytes memory commands =
            abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_IN)), bytes1(uint8(Commands.QUOTED_CALLS)));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(
            ActionConstants.ADDRESS_THIS,
            amountIn,
            amountOutMin,
            abi.encodePacked(address(OP), FEE, address(WETH), FEE, address(USDC)),
            true,
            true
        );

        bytes memory quotedCommands = abi.encodePacked(bytes1(uint8(QuotedCallsCommands.TRANSFER_REMOTE)));
        bytes[] memory quotedInputs = new bytes[](1);
        quotedInputs[0] = abi.encode(
            USDC_OPTIMISM_BRIDGE,
            leafDomain,
            TypeCasts.addressToBytes32(users.alice),
            QUOTED_CALLS_BRIDGE_EXACT_IN,
            MESSAGE_FEE,
            OPTIMISM_USDC_ADDRESS,
            QUOTED_CALLS_CONTRACT_BALANCE
        );
        inputs[1] = abi.encodeCall(QuotedCalls.execute, (quotedCommands, quotedInputs));

        deal(address(OP), users.alice, amountIn);
        OP.approve(address(router), amountIn);

        router.execute{value: MESSAGE_FEE}(commands, inputs);

        assertEq(OP.balanceOf(users.alice), 0);
        assertEq(ERC20(OPTIMISM_USDC_ADDRESS).balanceOf(users.alice), usdcInitialBal);
        assertEq(ERC20(OPTIMISM_USDC_ADDRESS).balanceOf(address(router)), 0);

        vm.selectFork(leafId);
        leafMailbox.processNextInboundMessage();

        uint256 leafBalance = ERC20(BASE_USDC_ADDRESS).balanceOf(users.alice);
        assertGt(leafBalance, 0);
        assertGe(leafBalance, amountOutMin);
    }

    function testGas_HypERC20CollateralBridgePermit2() public {
        _approveUsdcWithPermit2();
        (bytes memory commands, bytes[] memory inputs) = _encodeHypErc20CollateralBridge({
            usePermit2: true,
            token: OPTIMISM_USDC_ADDRESS,
            sweepETH: true
        });

        router.execute{value: MESSAGE_FEE}(commands, inputs);
        vm.snapshotGasLastCall('BridgeRouter_HypERC20Collateral_Permit2');
    }

    function testGas_HypERC20CollateralBridgeDirectApproval() public {
        ERC20(OPTIMISM_USDC_ADDRESS).approve(address(router), type(uint256).max);
        (bytes memory commands, bytes[] memory inputs) = _encodeHypErc20CollateralBridge({
            usePermit2: false,
            token: OPTIMISM_USDC_ADDRESS,
            sweepETH: true
        });

        router.execute{value: MESSAGE_FEE}(commands, inputs);
        vm.snapshotGasLastCall('BridgeRouter_HypERC20Collateral_DirectApproval');
    }

    function _encodeHypXERC20Bridge(
        bool usePermit2,
        uint256 pullAmount,
        uint256 bridgeAmount,
        uint256 bridgeValue,
        uint32 domain,
        bytes32 recipient,
        address token,
        bool sweepETH
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        uint256 innerCount = sweepETH ? 3 : 2;
        bytes memory quotedCommands;
        if (usePermit2) {
            quotedCommands = sweepETH
                ? abi.encodePacked(
                    bytes1(uint8(QuotedCallsCommands.PERMIT2_TRANSFER_FROM)),
                    bytes1(uint8(QuotedCallsCommands.TRANSFER_REMOTE)),
                    bytes1(uint8(QuotedCallsCommands.SWEEP))
                )
                : abi.encodePacked(
                    bytes1(uint8(QuotedCallsCommands.PERMIT2_TRANSFER_FROM)),
                    bytes1(uint8(QuotedCallsCommands.TRANSFER_REMOTE))
                );
        } else {
            quotedCommands = sweepETH
                ? abi.encodePacked(
                    bytes1(uint8(QuotedCallsCommands.TRANSFER_FROM)),
                    bytes1(uint8(QuotedCallsCommands.TRANSFER_REMOTE)),
                    bytes1(uint8(QuotedCallsCommands.SWEEP))
                )
                : abi.encodePacked(
                    bytes1(uint8(QuotedCallsCommands.TRANSFER_FROM)),
                    bytes1(uint8(QuotedCallsCommands.TRANSFER_REMOTE))
                );
        }

        bytes[] memory quotedInputs = new bytes[](innerCount);
        quotedInputs[0] = usePermit2
            ? abi.encode(token, uint160(pullAmount))
            : abi.encode(token, pullAmount);
        quotedInputs[1] =
            abi.encode(OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS, domain, recipient, bridgeAmount, bridgeValue, token, bridgeAmount);
        if (sweepETH) quotedInputs[2] = abi.encode(Constants.ETH);

        commands = abi.encodePacked(bytes1(uint8(Commands.QUOTED_CALLS)));
        inputs = new bytes[](1);
        inputs[0] = abi.encodeCall(QuotedCalls.execute, (quotedCommands, quotedInputs));
    }

    function _encodeHypErc20CollateralBridge(bool usePermit2, address token, bool sweepETH)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
        bytes memory quotedCommands = sweepETH
            ? abi.encodePacked(
                bytes1(uint8(usePermit2 ? QuotedCallsCommands.PERMIT2_TRANSFER_FROM : QuotedCallsCommands.TRANSFER_FROM)),
                bytes1(uint8(QuotedCallsCommands.TRANSFER_REMOTE)),
                bytes1(uint8(QuotedCallsCommands.SWEEP))
            )
            : abi.encodePacked(
                bytes1(uint8(usePermit2 ? QuotedCallsCommands.PERMIT2_TRANSFER_FROM : QuotedCallsCommands.TRANSFER_FROM)),
                bytes1(uint8(QuotedCallsCommands.TRANSFER_REMOTE))
            );

        bytes[] memory quotedInputs = new bytes[](sweepETH ? 3 : 2);
        quotedInputs[0] = usePermit2 ? abi.encode(token, uint160(usdcBridgeAmount)) : abi.encode(token, usdcBridgeAmount);
        quotedInputs[1] =
            abi.encode(USDC_OPTIMISM_BRIDGE, leafDomain, TypeCasts.addressToBytes32(users.alice), usdcBridgeAmount, MESSAGE_FEE, token, usdcBridgeAmount);
        if (sweepETH) quotedInputs[2] = abi.encode(Constants.ETH);

        commands = abi.encodePacked(bytes1(uint8(Commands.QUOTED_CALLS)));
        inputs = new bytes[](1);
        inputs[0] = abi.encodeCall(QuotedCalls.execute, (quotedCommands, quotedInputs));
    }

    function _approveOpenUsdtWithPermit2() internal {
        ERC20(OPEN_USDT_ADDRESS).approve(address(rootPermit2), type(uint256).max);
        rootPermit2.approve(OPEN_USDT_ADDRESS, address(router), type(uint160).max, type(uint48).max);
    }

    function _approveUsdcWithPermit2() internal {
        ERC20(OPTIMISM_USDC_ADDRESS).approve(address(rootPermit2), type(uint256).max);
        rootPermit2.approve(OPTIMISM_USDC_ADDRESS, address(router), type(uint160).max, type(uint48).max);
    }

    function _assertOpenUsdtBridged(uint256 bridgeAmount) internal {
        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), openUsdtInitialBal - bridgeAmount);

        vm.selectFork(leafId);
        leafMailbox.processNextInboundMessage();

        assertEq(ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice), bridgeAmount);
    }
}
