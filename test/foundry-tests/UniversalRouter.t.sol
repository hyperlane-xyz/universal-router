// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import 'forge-std/Test.sol';

import {Payments} from 'contracts/modules/Payments.sol';
import {Permit2Payments} from 'contracts/modules/Permit2Payments.sol';
import {RouterDeployParameters} from 'contracts/types/RouterDeployParameters.sol';
import {ExampleModule} from 'contracts/test/ExampleModule.sol';
import {UniversalRouter} from 'contracts/UniversalRouter.sol';
import {Dispatcher} from 'contracts/base/Dispatcher.sol';
import {IUniversalRouter} from 'contracts/interfaces/IUniversalRouter.sol';
import {Constants} from 'contracts/libraries/Constants.sol';
import {Commands} from 'contracts/libraries/Commands.sol';
import {Quote, ITokenFee} from '@hyperlane/core/contracts/interfaces/ITokenBridge.sol';
import {TypeCasts} from '@hyperlane/core/contracts/libs/TypeCasts.sol';

import {MockERC20} from './mock/MockERC20.sol';

contract UniversalRouterTest is Test {
    address constant RECIPIENT = address(1234);
    uint256 constant AMOUNT = 10 ** 18;

    UniversalRouter router;
    ExampleModule testModule;
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
        testModule = new ExampleModule();
        erc20 = new MockERC20();
    }

    event ExampleModuleEvent(string message);

    function testCallModule() public {
        uint256 bytecodeSize;
        address theRouter = address(router);
        assembly {
            bytecodeSize := extcodesize(theRouter)
        }
        emit log_uint(bytecodeSize);
    }

    function testSweepToken() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.SWEEP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(erc20), RECIPIENT, AMOUNT);

        erc20.mint(address(router), AMOUNT);
        assertEq(erc20.balanceOf(RECIPIENT), 0);

        router.execute(commands, inputs);

        assertEq(erc20.balanceOf(RECIPIENT), AMOUNT);
    }

    function testSweepTokenInsufficientOutput() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.SWEEP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(erc20), RECIPIENT, AMOUNT + 1);

        erc20.mint(address(router), AMOUNT);
        assertEq(erc20.balanceOf(RECIPIENT), 0);

        vm.expectRevert(Payments.InsufficientToken.selector);
        router.execute(commands, inputs);
    }

    function testSweepETH() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.SWEEP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(Constants.ETH, RECIPIENT, AMOUNT);

        assertEq(RECIPIENT.balance, 0);

        router.execute{value: AMOUNT}(commands, inputs);

        assertEq(RECIPIENT.balance, AMOUNT);
    }

    function testSweepETHInsufficientOutput() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.SWEEP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(Constants.ETH, RECIPIENT, AMOUNT + 1);

        erc20.mint(address(router), AMOUNT);

        vm.expectRevert(Payments.InsufficientETH.selector);
        router.execute(commands, inputs);
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
