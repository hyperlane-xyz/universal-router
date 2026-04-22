// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {HypNative} from '@hyperlane/core/contracts/token/HypNative.sol';
import {TypeCasts} from '@hyperlane/core/contracts/libs/TypeCasts.sol';
import {TestPostDispatchHook} from '@hyperlane/core/contracts/test/TestPostDispatchHook.sol';
import {LinearFee} from '@hyperlane/core/contracts/token/fees/LinearFee.sol';

import {BridgeRouter} from '../../../../contracts/modules/bridge/BridgeRouter.sol';
import {BridgeTypes} from '../../../../contracts/libraries/BridgeTypes.sol';
import {Commands} from '../../../../contracts/libraries/Commands.sol';
import {Constants} from '../../../../contracts/libraries/Constants.sol';
import {Dispatcher} from '../../../../contracts/base/Dispatcher.sol';
import {ActionConstants} from '@uniswap/v4-periphery/src/libraries/ActionConstants.sol';
import './BaseOverrideBridge.sol';

/// @notice Proof-of-concept: route a HypNative (ETH) transfer through the
/// UniversalRouter by overloading the HYP_ERC20_COLLATERAL branch with
/// token=address(0), payer=router. No BridgeRouter changes.
///
/// Intent contract for every test: "alice pays `totalIn`; the bridge credits
/// recipient exactly `BRIDGE_AMOUNT` on destination." The caller cannot pass
/// a tokenFee directly (`maxTokenFee` is only a cap — the router always
/// recomputes it from the quote), but CAN inflate `amount` off-chain to cover
/// expected fees and hit exact-output semantics.
contract BridgeTokenHypNativeOverloadTest is BaseOverrideBridge {
    HypNative public hypNative;
    bytes32 public remoteRouter = bytes32(uint256(uint160(0xDEAD)));

    uint256 constant BRIDGE_AMOUNT = 1 ether;

    bytes public commands;
    bytes[] public inputs;

    function setUp() public override {
        super.setUp();
        vm.selectFork(rootId);

        vm.startPrank(users.owner);
        hypNative = new HypNative(1, 1, address(rootMailbox));
        hypNative.initialize(address(0), address(0), users.owner);
        hypNative.enrollRemoteRouter(leafDomain, remoteRouter);
        vm.stopPrank();

        deal(users.alice, 10 ether);
        vm.startPrank(users.alice);

        commands = abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN)), bytes1(uint8(Commands.SWEEP)));
        inputs = new bytes[](2);
        inputs[1] = abi.encode(Constants.ETH, users.alice, 0);
    }

    function _encodeBridge(uint256 amount, uint256 maxTokenFee) internal view returns (bytes memory) {
        return abi.encode(
            uint8(BridgeTypes.HYP_ERC20_COLLATERAL),
            users.alice, // recipient
            address(0), // token: solmate safeApprove on EOA is a silent no-op
            address(hypNative), // bridge
            amount, // amount (may be inflated to absorb fees)
            amount, // msgFee — forward full native to transferRemote
            maxTokenFee,
            leafDomain,
            false // payerIsUser=false → payer = router, skips ERC20 pull
        );
    }

    function _assertExactOutput(uint256 totalIn, uint256 aliceBefore, uint256 bridgeBefore) internal view {
        // Recipient on destination is credited exactly BRIDGE_AMOUNT (= collateral here).
        assertEq(address(hypNative).balance - bridgeBefore, BRIDGE_AMOUNT, 'recipient credited BRIDGE_AMOUNT');
        // Alice paid exactly the inflated total she authorized.
        assertEq(aliceBefore - users.alice.balance, totalIn, 'alice paid exactly totalIn');
        assertEq(address(router).balance, 0, 'router holds no dust');
    }

    function test_NoFees_ExactOutput() external {
        inputs[0] = _encodeBridge(BRIDGE_AMOUNT, 0);

        uint256 aliceBefore = users.alice.balance;
        uint256 bridgeBefore = address(hypNative).balance;

        router.execute{value: BRIDGE_AMOUNT}(commands, inputs);

        _assertExactOutput(BRIDGE_AMOUNT, aliceBefore, bridgeBefore);
    }

    /// @notice Hook-fee case: caller inflates `amount = BRIDGE_AMOUNT + hookFee`.
    /// quoteExactInputBridgeAmount returns `amount - hookFee = BRIDGE_AMOUNT`, so
    /// exactly BRIDGE_AMOUNT is credited. maxTokenFee must be ≥ hookFee because
    /// the router sees the hook fee as a token fee.
    function test_HookFee_ExactOutput_WithInflatedAmount() external {
        uint256 fee = 0.01 ether;
        TestPostDispatchHook(address(rootMailbox.requiredHook())).setFee(fee);
        TestPostDispatchHook(address(rootMailbox.defaultHook())).setFee(fee);
        uint256 hookFee = 2 * fee;

        uint256 totalIn = BRIDGE_AMOUNT + hookFee;
        inputs[0] = _encodeBridge(totalIn, hookFee);

        uint256 aliceBefore = users.alice.balance;
        uint256 bridgeBefore = address(hypNative).balance;

        router.execute{value: totalIn}(commands, inputs);

        _assertExactOutput(totalIn, aliceBefore, bridgeBefore);
    }

    /// @notice Linear warp fee: caller inflates `amount = BRIDGE_AMOUNT * (1 + rate)`.
    /// With rate = 1%, amount = 1.01 ether → bridgeAmount = amount² / (amount + f(amount))
    /// = 1.01² / 1.0201 = 1 exactly (no rounding because 1.0201 = 1.01²).
    function test_LinearWarpFee_ExactOutput_WithInflatedAmount() external {
        uint256 maxFee = 0.02 ether; // LinearFee params: rate = maxFee / (2 * halfAmount) = 1%
        uint256 halfAmount = 1 ether;

        vm.stopPrank();
        LinearFee linearFee = new LinearFee(address(0), maxFee, halfAmount, users.owner);
        vm.prank(users.owner);
        hypNative.setFeeRecipient(address(linearFee));
        vm.startPrank(users.alice);

        uint256 totalIn = 1.01 ether; // BRIDGE_AMOUNT * (1 + rate)
        inputs[0] = _encodeBridge(totalIn, totalIn - BRIDGE_AMOUNT);

        uint256 aliceBefore = users.alice.balance;
        uint256 bridgeBefore = address(hypNative).balance;
        uint256 linearFeeBefore = address(linearFee).balance;

        router.execute{value: totalIn}(commands, inputs);

        _assertExactOutput(totalIn, aliceBefore, bridgeBefore);
        assertEq(address(linearFee).balance - linearFeeBefore, totalIn - BRIDGE_AMOUNT, 'LinearFee got the overage');
    }

    /// @notice An origin-chain swap produces native ETH at the router (e.g. after
    /// V2_SWAP_EXACT_OUT to WETH + UNWRAP_WETH). Normally a bridge step would
    /// pass `amount = CONTRACT_BALANCE` to consume whatever the swap produced.
    /// For the overload that path reverts: `ERC20(address(0)).balanceOf(router)`
    /// returns no data, so the Dispatcher can't decode the uint256.
    function test_SwapIntoNative_CannotUseContractBalanceSentinel() external {
        // Simulate swap output: router holds some native ETH.
        vm.deal(address(router), 2 ether);

        inputs[0] = _encodeBridge(ActionConstants.CONTRACT_BALANCE, 0);

        vm.expectRevert();
        router.execute(commands, inputs);
    }

    /// @notice Origin swap → bridge works, but only with caller-side exact-output
    /// math. The caller must know the swap's exact output (e.g. via V2_SWAP_EXACT_OUT)
    /// and the bridge's expected fees, and pass `amount = BRIDGE_AMOUNT + fees`.
    /// Any swap overage lands at the router and is swept back.
    function test_SwapIntoNative_ThenBridge_WithExactOutputInflation() external {
        uint256 fee = 0.005 ether;
        TestPostDispatchHook(address(rootMailbox.requiredHook())).setFee(fee);
        TestPostDispatchHook(address(rootMailbox.defaultHook())).setFee(fee);
        uint256 hookFee = 2 * fee;

        // Caller's off-chain plan:
        //   1. Swap USDC → WETH exact-out for (BRIDGE_AMOUNT + hookFee) WETH
        //   2. UNWRAP_WETH to give router native
        //   3. BRIDGE_TOKEN with amount = BRIDGE_AMOUNT + hookFee
        //
        // We stand in for steps 1–2 by dealing a slightly-overshot amount to the
        // router, modeling a swap that produced 0.01 ether extra due to routing.
        uint256 bridgeAmountIn = BRIDGE_AMOUNT + hookFee;
        uint256 swapOvershoot = 0.01 ether;
        vm.deal(address(router), bridgeAmountIn + swapOvershoot);

        inputs[0] = _encodeBridge(bridgeAmountIn, hookFee);

        uint256 aliceBefore = users.alice.balance;
        uint256 bridgeBefore = address(hypNative).balance;

        // User sends no msg.value — origin funds come from the (simulated) swap.
        router.execute(commands, inputs);

        assertEq(address(hypNative).balance - bridgeBefore, BRIDGE_AMOUNT, 'recipient credited BRIDGE_AMOUNT');
        // SWEEP returns everything the bridge didn't consume (the overshoot) to alice.
        assertEq(users.alice.balance - aliceBefore, swapOvershoot, 'alice recovers swap overshoot via SWEEP');
        assertEq(address(router).balance, 0, 'router fully drained');
    }

    /// @notice Combined hook + linear fee: caller inflates for both.
    /// Goal: solve `amount` such that `bridgeAmount = BRIDGE_AMOUNT`.
    /// With both fees: `amount = BRIDGE_AMOUNT * (1 + rate) + hookFee`.
    function test_CombinedFees_ExactOutput_WithInflatedAmount() external {
        uint256 fee = 0.005 ether;
        TestPostDispatchHook(address(rootMailbox.requiredHook())).setFee(fee);
        TestPostDispatchHook(address(rootMailbox.defaultHook())).setFee(fee);
        uint256 hookFee = 2 * fee;

        uint256 maxFee = 0.02 ether;
        uint256 halfAmount = 1 ether;

        vm.stopPrank();
        LinearFee linearFee = new LinearFee(address(0), maxFee, halfAmount, users.owner);
        vm.prank(users.owner);
        hypNative.setFeeRecipient(address(linearFee));
        vm.startPrank(users.alice);

        uint256 totalIn = 1.01 ether + hookFee; // BRIDGE_AMOUNT*(1+rate) + hookFee
        inputs[0] = _encodeBridge(totalIn, totalIn - BRIDGE_AMOUNT);

        uint256 aliceBefore = users.alice.balance;
        uint256 bridgeBefore = address(hypNative).balance;

        router.execute{value: totalIn}(commands, inputs);

        _assertExactOutput(totalIn, aliceBefore, bridgeBefore);
    }
}
