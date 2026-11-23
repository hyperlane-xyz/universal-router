// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from 'forge-std/Test.sol';
import {MockMailbox} from '@hyperlane/core/contracts/mock/MockMailbox.sol';
import {CrossCollateralRouter} from '@hyperlane/core/contracts/token/CrossCollateralRouter.sol';
import {ICrossCollateralFee} from '@hyperlane/core/contracts/token/interfaces/ICrossCollateralFee.sol';
import {Quote} from '@hyperlane/core/contracts/interfaces/ITokenBridge.sol';
import {TestPostDispatchHook} from '@hyperlane/core/contracts/test/TestPostDispatchHook.sol';
import {TypeCasts} from '@hyperlane/core/contracts/libs/TypeCasts.sol';
import {UniversalRouter, RouterDeployParameters} from '../../../contracts/UniversalRouter.sol';
import {BridgeRouter} from '../../../contracts/modules/bridge/BridgeRouter.sol';
import {BridgeTypes} from '../../../contracts/libraries/BridgeTypes.sol';
import {Commands} from '../../../contracts/libraries/Commands.sol';
import {MockERC20} from '../mock/MockERC20.sol';

contract CrossCollateralTest is Test, ICrossCollateralFee {
    uint32 constant ORIGIN = 1;
    uint32 constant DESTINATION = 2;
    uint256 constant INPUT = 1100;
    uint256 constant GAS_FEE = 2 gwei;

    UniversalRouter router;
    MockERC20 collateral;
    MockERC20 payoutToken;
    CrossCollateralRouter source;
    CrossCollateralRouter target;
    MockMailbox destinationMailbox;

    function setUp() public {
        RouterDeployParameters memory params;
        router = new UniversalRouter(params);
        collateral = new MockERC20();
        payoutToken = new MockERC20();

        MockMailbox originMailbox = new MockMailbox(ORIGIN);
        destinationMailbox = new MockMailbox(DESTINATION);
        originMailbox.addRemoteMailbox(DESTINATION, destinationMailbox);
        // The mock mailbox charges its hook once as the required hook and once as the default hook.
        TestPostDispatchHook(address(originMailbox.defaultHook())).setFee(GAS_FEE / 2);

        source = new CrossCollateralRouter(address(collateral), 1, 1, address(originMailbox));
        target = new CrossCollateralRouter(address(payoutToken), 1, 1, address(destinationMailbox));
        source.initialize(address(0), address(0), address(this));
        target.initialize(address(0), address(0), address(this));
        uint32[] memory domains = new uint32[](1);
        domains[0] = DESTINATION;
        bytes32[] memory targets = new bytes32[](1);
        targets[0] = TypeCasts.addressToBytes32(address(target));
        source.enrollCrossCollateralRouters(domains, targets);
        target.enrollRemoteRouter(ORIGIN, TypeCasts.addressToBytes32(address(source)));
        source.setFeeRecipient(address(this));

        collateral.mint(address(this), INPUT);
        collateral.approve(address(router), INPUT);
        payoutToken.mint(address(target), INPUT);
    }

    // A 10% fee for this specific target. Both quoting and charging must use that route.
    function quoteTransferRemoteTo(uint32 domain, bytes32, uint256 amount, bytes32 targetRouter)
        external
        view
        override
        returns (Quote[] memory quotes)
    {
        require(domain == DESTINATION && targetRouter == TypeCasts.addressToBytes32(address(target)));
        quotes = new Quote[](1);
        quotes[0] = Quote(address(collateral), amount / 10);
    }

    function executeBridge(uint8 bridgeType, address token, uint256 maxFee, bytes memory targetWord) private {
        bytes32 recipient = TypeCasts.addressToBytes32(address(this));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = bytes.concat(
            abi.encode(bridgeType, recipient, token, source, INPUT, GAS_FEE, maxFee, DESTINATION, true), targetWord
        );
        router.execute{value: GAS_FEE}(abi.encodePacked(uint8(Commands.BRIDGE_TOKEN)), inputs);
    }

    function test_explicitTargetPaysRecipient() public {
        executeBridge(BridgeTypes.HYP_CROSS_COLLATERAL, address(collateral), 100, abi.encode(target));
        destinationMailbox.processNextInboundMessage();

        assertEq(payoutToken.balanceOf(address(this)), 1000);
        assertEq(collateral.balanceOf(address(source)), 1000);
        assertEq(collateral.balanceOf(address(this)), 100);
        assertEq(collateral.balanceOf(address(router)), 0);
        assertEq(collateral.allowance(address(router), address(source)), 0);
    }

    function test_standardCollateralUsesDefaultRouterWithNineWords() public {
        source.enrollRemoteRouter(DESTINATION, TypeCasts.addressToBytes32(address(target)));
        executeBridge(BridgeTypes.HYP_ERC20_COLLATERAL, address(collateral), 100, '');
        destinationMailbox.processNextInboundMessage();

        assertEq(payoutToken.balanceOf(address(this)), 1000);
    }

    function test_feeAboveMaxReverts() public {
        vm.expectRevert(abi.encodeWithSelector(BridgeRouter.TokenFeeExceedsMax.selector, 100, 99));
        executeBridge(BridgeTypes.HYP_CROSS_COLLATERAL, address(collateral), 99, abi.encode(target));
    }

    function test_targetIsRequired() public {
        vm.expectRevert(BridgeRouter.InvalidTargetRouter.selector);
        executeBridge(BridgeTypes.HYP_CROSS_COLLATERAL, address(collateral), 100, '');
        vm.expectRevert(BridgeRouter.InvalidTargetRouter.selector);
        executeBridge(BridgeTypes.HYP_CROSS_COLLATERAL, address(collateral), 100, abi.encode(bytes32(0)));
    }

    function test_nativeInputReverts() public {
        vm.expectRevert(BridgeRouter.InvalidTokenAddress.selector);
        executeBridge(BridgeTypes.HYP_CROSS_COLLATERAL, address(0), 100, abi.encode(target));
    }
}
