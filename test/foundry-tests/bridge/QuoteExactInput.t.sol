// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from 'forge-std/Test.sol';
import {Quote, ITokenFee} from '@hyperlane/core/contracts/interfaces/ITokenBridge.sol';
import {TypeCasts} from '@hyperlane/core/contracts/libs/TypeCasts.sol';

/// @dev Minimal harness for the exact-input bridge inversion formula.
contract QuoteExactInputHarness {
    function exposed_quoteExactInputBridgeAmount(
        address bridge,
        address token,
        address recipient,
        uint256 amount,
        uint32 domain
    ) external view returns (uint256 bridgeAmount) {
        bytes32 recipientBytes32 = TypeCasts.addressToBytes32(recipient);
        Quote[] memory quotes = ITokenFee(bridge).quoteTransferRemote(domain, recipientBytes32, amount);
        uint256 igpTokenFee = (quotes[0].token == token) ? quotes[0].amount : 0;
        uint256 linearQuotedTokens = quotes[1].amount + quotes[2].amount;
        bridgeAmount = ((amount - igpTokenFee) * amount) / linearQuotedTokens;
    }
}

/// @notice Unit tests for exact-input bridge inversion.
contract QuoteExactInputTest is Test {
    QuoteExactInputHarness harness;

    address constant BRIDGE = address(0xB1);
    address constant TOKEN = address(0xC1);
    address constant RECIPIENT = address(0xA1);
    uint32 constant DOMAIN = 8453;

    function setUp() public {
        harness = new QuoteExactInputHarness();
    }

    function _mockQuote(uint256 amount, Quote[3] memory quotes) internal {
        Quote[] memory quotesArr = new Quote[](3);
        quotesArr[0] = quotes[0];
        quotesArr[1] = quotes[1];
        quotesArr[2] = quotes[2];

        bytes32 recipientBytes32 = TypeCasts.addressToBytes32(RECIPIENT);
        vm.mockCall(
            BRIDGE,
            abi.encodeCall(ITokenFee.quoteTransferRemote, (DOMAIN, recipientBytes32, amount)),
            abi.encode(quotesArr)
        );
    }

    function test_noFees() public {
        uint256 amount = 1000e6;
        _mockQuote(amount, [
            Quote({token: address(0), amount: 0}),
            Quote({token: TOKEN, amount: amount}),
            Quote({token: TOKEN, amount: 0})
        ]);

        uint256 bridgeAmount = harness.exposed_quoteExactInputBridgeAmount(BRIDGE, TOKEN, RECIPIENT, amount, DOMAIN);
        assertEq(bridgeAmount, amount);
    }

    function test_nativeIgpOnly() public {
        uint256 amount = 1000e6;
        _mockQuote(amount, [
            Quote({token: address(0), amount: 69e9}),
            Quote({token: TOKEN, amount: amount}),
            Quote({token: TOKEN, amount: 0})
        ]);

        uint256 bridgeAmount = harness.exposed_quoteExactInputBridgeAmount(BRIDGE, TOKEN, RECIPIENT, amount, DOMAIN);
        assertEq(bridgeAmount, amount);
    }

    function test_internalFeeOnly() public {
        uint256 amount = 1000e6;
        uint256 internalFee = 500000;
        _mockQuote(amount, [
            Quote({token: address(0), amount: 69e9}),
            Quote({token: TOKEN, amount: amount + internalFee}),
            Quote({token: TOKEN, amount: 0})
        ]);

        uint256 bridgeAmount = harness.exposed_quoteExactInputBridgeAmount(BRIDGE, TOKEN, RECIPIENT, amount, DOMAIN);
        uint256 feeOnBridgeAmount = (internalFee * bridgeAmount) / amount;
        assertApproxEqAbs(bridgeAmount + feeOnBridgeAmount, amount, 1, 'bridgeAmount + fee should equal amount');
        assertLt(bridgeAmount, amount, 'bridgeAmount should be less than amount');
    }

    function test_externalFeeOnly() public {
        uint256 amount = 1000e6;
        uint256 externalFee = 130000;
        _mockQuote(amount, [
            Quote({token: address(0), amount: 69e9}),
            Quote({token: TOKEN, amount: amount}),
            Quote({token: TOKEN, amount: externalFee})
        ]);

        uint256 bridgeAmount = harness.exposed_quoteExactInputBridgeAmount(BRIDGE, TOKEN, RECIPIENT, amount, DOMAIN);
        uint256 feeOnBridgeAmount = (externalFee * bridgeAmount) / amount;
        assertApproxEqAbs(bridgeAmount + feeOnBridgeAmount, amount, 1, 'bridgeAmount + fee should equal amount');
        assertLt(bridgeAmount, amount);
    }

    function test_internalAndExternalFees() public {
        uint256 amount = 1000e6;
        uint256 internalFee = 500000;
        uint256 externalFee = 130000;
        _mockQuote(amount, [
            Quote({token: address(0), amount: 69e9}),
            Quote({token: TOKEN, amount: amount + internalFee}),
            Quote({token: TOKEN, amount: externalFee})
        ]);

        uint256 bridgeAmount = harness.exposed_quoteExactInputBridgeAmount(BRIDGE, TOKEN, RECIPIENT, amount, DOMAIN);
        uint256 totalFee = internalFee + externalFee;
        uint256 feeOnBridgeAmount = (totalFee * bridgeAmount) / amount;
        assertApproxEqAbs(bridgeAmount + feeOnBridgeAmount, amount, 1, 'bridgeAmount + fee should equal amount');
        assertLt(bridgeAmount, amount);
    }

    function test_tokenDenominatedIgp() public {
        uint256 amount = 1000e6;
        uint256 igpFee = 1e6;
        uint256 internalFee = 500000;
        _mockQuote(amount, [
            Quote({token: TOKEN, amount: igpFee}),
            Quote({token: TOKEN, amount: amount + internalFee}),
            Quote({token: TOKEN, amount: 0})
        ]);

        uint256 bridgeAmount = harness.exposed_quoteExactInputBridgeAmount(BRIDGE, TOKEN, RECIPIENT, amount, DOMAIN);
        uint256 availableForBridge = amount - igpFee;
        uint256 feeOnBridgeAmount = (internalFee * bridgeAmount) / amount;
        assertApproxEqAbs(
            bridgeAmount + feeOnBridgeAmount, availableForBridge, 1, 'bridgeAmount + fee should equal amount - igp'
        );
        assertLt(bridgeAmount, availableForBridge);
    }

    function test_largeAmount18Decimals() public {
        uint256 amount = 1_000_000_000 * 1e18;
        uint256 internalFee = amount * 5 / 10000;
        _mockQuote(amount, [
            Quote({token: address(0), amount: 69e9}),
            Quote({token: TOKEN, amount: amount + internalFee}),
            Quote({token: TOKEN, amount: 0})
        ]);

        uint256 bridgeAmount = harness.exposed_quoteExactInputBridgeAmount(BRIDGE, TOKEN, RECIPIENT, amount, DOMAIN);
        uint256 feeOnBridgeAmount = (internalFee * bridgeAmount) / amount;
        assertApproxEqAbs(bridgeAmount + feeOnBridgeAmount, amount, 1e6, 'bridgeAmount + fee should equal amount');
        assertLt(bridgeAmount, amount);
    }
}
