// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMailbox} from '@hyperlane/core/contracts/interfaces/IMailbox.sol';

/// @notice Minimal interface for reading the Hyperlane mailbox from a MailboxClient contract.
/// All Hyperlane warp routes inherit MailboxClient, which declares `IMailbox public immutable mailbox`
/// — this interface exposes the generated getter so callers can retrieve the mailbox without importing
/// the abstract MailboxClient contract.
interface IMailboxClient {
    function mailbox() external view returns (IMailbox);
}
