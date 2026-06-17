// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console} from 'forge-std/Test.sol';
import {TypeCasts} from '@hyperlane/core/contracts/libs/TypeCasts.sol';

import {UniversalRouter} from 'contracts/UniversalRouter.sol';
import {Dispatcher} from 'contracts/base/Dispatcher.sol';
import {Commands} from 'contracts/libraries/Commands.sol';
import {BridgeTypes} from 'contracts/libraries/BridgeTypes.sol';
import {RouterDeployParameters} from 'contracts/types/RouterDeployParameters.sol';

import {MockERC20} from '../../mock/MockERC20.sol';
import {MockRecordingMailbox} from '../../mock/MockRecordingMailbox.sol';
import {MockSealevelBridge} from '../../mock/MockSealevelBridge.sol';

// ---------------------------------------------------------------------------
// EVM → Sealevel cross-chain commitment message test (standalone — no fork)
//
// Tests the full Dispatcher path for icaRouter == address(0):
//   router.execute() → Dispatcher reads mailbox() from bridge →
//   mailbox.dispatch(solanaDomain, remoteRouter, commitment||userSalt||recipient)
//
// The reveal payload (REVEAL_PAYLOAD) and shared constants are mirrored in
// tests/universal_router.ts so both sides can independently compute the same
// commitment and verify round-trip correctness.
//
// Shared constants (copy into Anchor test):
//   REVEAL_PAYLOAD = hex"010000000b010000000800000040420f0000000000" (21 bytes)
//   USER_EVM       = 0x1234567890AbcdEF1234567890aBcdef12345678
//   ALICE_SOLANA   = bytes32(0xa1ce...0000)
//   SOLANA_DOMAIN  = 1399811149
// ---------------------------------------------------------------------------
contract ExecuteCrossChainSealevelTest is Test {
    // Hyperlane domain ID for Solana mainnet
    uint32 constant SOLANA_DOMAIN = 1399811149;

    // Placeholder Solana UR program ID — replace after `solana-keygen new` deploy
    bytes32 constant SOLANA_UR_PROGRAM_ID =
        bytes32(hex'0000000000000000000000000000000000000000000000000000000000000001');

    // Fixed test user EVM address — deterministic across EVM and Solana tests
    address constant USER = 0x1234567890AbcdEF1234567890aBcdef12345678;

    // Alice's Solana wallet pubkey (32 bytes) — used in Anchor tests as recipientBytes
    bytes32 constant ALICE_SOLANA_PUBKEY =
        bytes32(hex'a1ce000000000000000000000000000000000000000000000000000000000000');

    // Borsh encoding of the Solana reveal payload:
    //   (Vec<u8>, Vec<Vec<u8>>) = ([CMD_TRANSFER=0x0b], [TransferInput{amount:1_000_000}])
    //
    //   01 00 00 00   → len(commands) = 1
    //   0b            → CMD_TRANSFER byte
    //   01 00 00 00   → len(inputs) = 1
    //   08 00 00 00   → len(inputs[0]) = 8
    //   40 42 0f 00 00 00 00 00 → u64-LE(1_000_000)
    //
    // RouterInstruction::Reveal on Solana deserializes this exact byte string and re-computes
    // keccak256(REVEAL_PAYLOAD || salt) to verify the stored commitment.
    bytes constant REVEAL_PAYLOAD = hex'010000000b010000000800000040420f0000000000';

    UniversalRouter public router;
    MockRecordingMailbox recordingMailbox;
    MockSealevelBridge mockBridge;
    MockERC20 mockToken;

    function setUp() public {
        recordingMailbox = new MockRecordingMailbox();
        mockBridge = new MockSealevelBridge(recordingMailbox);
        mockToken = new MockERC20();

        // Deploy the router directly — TestDeployRouter.run() requires CreateX which is not
        // available in a non-fork local environment. All DEX factory addresses are unused by
        // BRIDGE_TOKEN + EXECUTE_CROSS_CHAIN, so address(0) is safe.
        RouterDeployParameters memory routerParams = RouterDeployParameters({
            permit2: address(1), // not called (payerIsUser=false → no Permit2 path)
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
        router = new UniversalRouter(routerParams);

        vm.deal(USER, 1 ether);
    }

    // -----------------------------------------------------------------------
    // test_sealevel_commitmentMessageBody
    //
    // Verifies the 96-byte message body dispatched to the Solana mailbox:
    //   [0..32]  commitment = keccak256(REVEAL_PAYLOAD || revealSalt)
    //   [32..64] userSalt   = TypeCasts.addressToBytes32(msgSender()) — mirrors ICA userSalt
    //   [64..96] recipient  = ALICE_SOLANA_PUBKEY
    //
    // On success, logs all values so they can be pasted into the Anchor test
    // and used to drive RouterInstruction::Reveal with matching inputs.
    // -----------------------------------------------------------------------
    function test_sealevel_commitmentMessageBody() public {
        // userSalt — on-chain Dispatcher computes TypeCasts.addressToBytes32(msgSender()),
        // used as PDA seed on Solana (mirrors ICA userSalt derivation).
        bytes32 userSalt = TypeCasts.addressToBytes32(USER);

        // revealSalt — random bytes32 used for the commitment hash (computed off-chain).
        // In production the engine generates this with crypto.getRandomValues().
        bytes32 revealSalt = bytes32(hex'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef');

        // commitment = keccak256(REVEAL_PAYLOAD || revealSalt)
        // Mirrors RouterInstruction::Reveal's verification:
        //   keccak256(borsh_serialize(swap_commands, swap_inputs) || pending.salt)
        bytes32 commitment = keccak256(bytes.concat(REVEAL_PAYLOAD, abi.encodePacked(revealSalt)));

        // Solana PDA that receives bridged tokens (derived off-chain by engine)
        bytes32 pdaBytes32 =
            bytes32(hex'beef000000000000000000000000000000000000000000000000000000000000');

        bytes[] memory inputs = new bytes[](2);

        // BRIDGE_TOKEN: payerIsUser=false (router holds mock tokens — no Permit2 call)
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            pdaBytes32,
            address(mockToken),
            address(mockBridge),
            uint256(1_000_000),
            uint256(0), // msgFee
            uint256(0), // maxTokenFee
            SOLANA_DOMAIN,
            false // payerIsUser
        );

        // EXECUTE_CROSS_CHAIN — Sealevel path (icaRouter = address(0))
        inputs[1] = abi.encode(
            SOLANA_DOMAIN,
            address(0), // icaRouter = 0 → direct mailbox dispatch
            SOLANA_UR_PROGRAM_ID, // remoteRouter
            bytes32(0), // ism (zero — Solana UR default ISM applies)
            commitment,
            ALICE_SOLANA_PUBKEY, // recipient (Solana wallet pubkey)
            uint256(0), // msgFee
            address(mockBridge), // token — Dispatcher calls IMailboxClient(token).mailbox()
            uint256(0), // tokenFee
            address(0), // hook
            bytes('') // hookMetadata
        );

        bytes memory commands = abi.encodePacked(
            bytes1(uint8(Commands.BRIDGE_TOKEN)),
            bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN))
        );

        // USER is the lock holder → msgSender() = USER → salt = padded USER address
        vm.prank(USER);
        router.execute(commands, inputs);

        // ── Verify recording mailbox received correct call ──────────────────
        assertEq(recordingMailbox.dispatchCount(), 1, 'dispatch should be called once');
        assertEq(recordingMailbox.lastDomain(), SOLANA_DOMAIN, 'wrong destination domain');
        assertEq(recordingMailbox.lastRecipient(), SOLANA_UR_PROGRAM_ID, 'wrong remote router');

        bytes memory body = recordingMailbox.lastBody();
        assertEq(body.length, 96, 'body must be exactly 96 bytes');

        // body layout: [0..32] = commitment, [32..64] = userSalt, [64..96] = recipient
        bytes32 gotCommitment;
        bytes32 gotUserSalt;
        bytes32 gotRecipient;
        assembly {
            gotCommitment := mload(add(body, 0x20)) // bytes[0..31]
            gotUserSalt   := mload(add(body, 0x40)) // bytes[32..63]
            gotRecipient  := mload(add(body, 0x60)) // bytes[64..95]
        }
        assertEq(gotCommitment, commitment, 'commitment field mismatch');
        assertEq(gotUserSalt, TypeCasts.addressToBytes32(USER), 'userSalt must be TypeCasts.addressToBytes32(USER)');
        assertEq(gotRecipient, ALICE_SOLANA_PUBKEY, 'recipient field mismatch');

        // ── Cross-chain reference values (mirror in Anchor test) ────────────
        console.log('=== EVM->Solana message values (use in Anchor test) ===');
        console.log('REVEAL_PAYLOAD (hex):');
        console.logBytes(REVEAL_PAYLOAD);
        console.log('revealSalt (random, for commitment hash):');
        console.logBytes32(revealSalt);
        console.log('commitment (keccak256(REVEAL_PAYLOAD || revealSalt)):');
        console.logBytes32(commitment);
        console.log('ALICE_SOLANA_PUBKEY:');
        console.logBytes32(ALICE_SOLANA_PUBKEY);
        console.log('userSalt (TypeCasts.addressToBytes32(USER)) at bytes[32..64]:');
        console.logBytes32(userSalt);
        console.log('full message body (96 bytes) — commitment || userSalt || recipient:');
        console.logBytes(body);
    }

    // -----------------------------------------------------------------------
    // test_sealevel_commitmentChangesWithPayload
    //
    // Sanity check: different reveal payloads produce different commitments.
    // Catches accidental preimage truncation or salt omission.
    // -----------------------------------------------------------------------
    function test_sealevel_commitmentChangesWithPayload() public {
        bytes32 salt = TypeCasts.addressToBytes32(USER);

        bytes32 c1 = keccak256(bytes.concat(REVEAL_PAYLOAD, abi.encodePacked(salt)));

        // Tamper: different amount (2_000_000 instead of 1_000_000)
        bytes memory altered = hex'010000000b010000000800000080841e0000000000';
        bytes32 c2 = keccak256(bytes.concat(altered, abi.encodePacked(salt)));

        assertTrue(c1 != c2, 'commitments must differ for different reveal payloads');

        // Salt change also shifts commitment
        bytes32 c3 =
            keccak256(bytes.concat(REVEAL_PAYLOAD, abi.encodePacked(TypeCasts.addressToBytes32(address(1)))));
        assertTrue(c1 != c3, 'commitments must differ for different salts');
    }
}
