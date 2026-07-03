// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from 'forge-std/Test.sol';
import {RouterDeployParameters} from 'contracts/types/RouterDeployParameters.sol';
import {UniversalRouter} from 'contracts/UniversalRouter.sol';
import {Commands} from 'contracts/libraries/Commands.sol';

import {MockTronUSDT} from './mock/MockTronUSDT.sol';
import {MockFalseReturningERC20} from './mock/MockFalseReturningERC20.sol';

/// @notice Reproduces the incident where a real, successful SWEEP/TRANSFER of Tron USDT reverted
/// with "TRANSFER_FAILED" because Tron's compiler pads `transfer()`'s missing return value with
/// 32 zero bytes instead of leaving it empty, and SafeTransferLib reads that as an explicit
/// `false`. Also proves the override doesn't mask genuine failures, for Tron USDT or any other
/// token.
///
/// Run under the tron profile only:
///   FOUNDRY_PROFILE=tron forge test --mp test/tron/TronUsdtSafeTransfer.t.sol
contract TronUsdtSafeTransferTest is Test {
    address constant RECIPIENT = address(1234);
    // The real Tron USDT address — the SafeTransferLib override only special-cases this
    // exact address, so the mock must be etched here rather than deployed normally.
    address constant TRON_USDT = 0xa614f803B6FD780986A42c78Ec9c7f77e6DeD13C;
    // Matches the amount actually stranded in the BSC->Tron incident (USDT has 6 decimals).
    uint256 constant AMOUNT = 56_186_409;

    UniversalRouter router;
    MockTronUSDT usdt;

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

        // Deploy the mock, then move its code onto the real Tron USDT address so the
        // override's address check actually matches (mirrors how the real token is deployed
        // at a fixed address on Tron, rather than a normal CREATE address in this test).
        vm.etch(TRON_USDT, address(new MockTronUSDT()).code);
        usdt = MockTronUSDT(TRON_USDT);
    }

    function test_sweepTronUsdt_succeedsDespiteZeroReturnData() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.SWEEP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(usdt), RECIPIENT, AMOUNT);

        usdt.mint(address(router), AMOUNT);
        assertEq(usdt.balanceOf(RECIPIENT), 0);

        router.execute(commands, inputs);

        assertEq(usdt.balanceOf(RECIPIENT), AMOUNT);
        assertEq(usdt.balanceOf(address(router)), 0);
    }

    /// @notice TRANSFER hits the same Payments.sol `.safeTransfer()` call site as SWEEP, but is
    /// a distinct dispatcher branch — this is also the closest analogue to the incident's actual
    /// rescue path, since BRIDGE_TOKEN's own transfer step goes through the same helper.
    function test_transferTronUsdt_succeedsDespiteZeroReturnData() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.TRANSFER)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(usdt), RECIPIENT, AMOUNT);

        usdt.mint(address(router), AMOUNT);
        assertEq(usdt.balanceOf(RECIPIENT), 0);

        router.execute(commands, inputs);

        assertEq(usdt.balanceOf(RECIPIENT), AMOUNT);
        assertEq(usdt.balanceOf(address(router)), 0);
    }

    /// @notice Proves the override didn't turn safeTransfer into a no-op success for Tron USDT —
    /// a genuine failure (insufficient balance) must still revert. Uses TRANSFER, since SWEEP is
    /// always bounded to the router's actual balance and can't be made to under-transfer.
    /// The override's raw `.call()` doesn't bubble up the token's own revert reason (matching
    /// how a low-level call normally behaves) — it surfaces as SafeTransferLib's own
    /// "TRANSFER_FAILED", which is what matters: the call reverts instead of silently succeeding.
    function test_transferTronUsdt_revertsOnGenuineFailure() public {
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.TRANSFER)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(usdt), RECIPIENT, AMOUNT);

        // Router holds less than AMOUNT, so the token's own balance check must fail.
        usdt.mint(address(router), AMOUNT - 1);

        vm.expectRevert(bytes('TRANSFER_FAILED'));
        router.execute(commands, inputs);
    }

    /// @notice Proves the override's hardcoded address check doesn't weaken the return-data
    /// check for any other token: a token that genuinely returns `false` (without reverting)
    /// must still cause SafeTransferLib to revert.
    function test_sweepNonTronToken_revertsWhenTransferReturnsFalse() public {
        MockFalseReturningERC20 falseToken = new MockFalseReturningERC20();

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.SWEEP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(falseToken), RECIPIENT, AMOUNT);

        falseToken.mint(address(router), AMOUNT);

        vm.expectRevert(bytes('TRANSFER_FAILED'));
        router.execute(commands, inputs);
    }
}
