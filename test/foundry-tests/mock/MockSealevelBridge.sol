// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IMailbox} from '@hyperlane/core/contracts/interfaces/IMailbox.sol';
import {MockRecordingMailbox} from './MockRecordingMailbox.sol';

/// @notice Mock Hyperlane warp route bridge for Sealevel destinations.
/// Implements IMailboxClient.mailbox() (for the Dispatcher's Sealevel branch)
/// and ITokenBridge.transferRemote() as a no-op (for BRIDGE_TOKEN).
contract MockSealevelBridge {
    MockRecordingMailbox private immutable _mailbox;

    constructor(MockRecordingMailbox mailbox_) {
        _mailbox = mailbox_;
    }

    /// IMailboxClient — Dispatcher calls this to get the mailbox for direct dispatch
    function mailbox() external view returns (IMailbox) {
        return IMailbox(address(_mailbox));
    }

    /// ITokenBridge.transferRemote — called by BridgeRouter.executeHypBridge (no-op in tests)
    function transferRemote(uint32, bytes32, uint256) external payable returns (bytes32) {
        return bytes32(0);
    }
}
