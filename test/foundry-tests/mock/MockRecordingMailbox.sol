// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @notice Minimal IMailbox mock that records the most recent dispatch() call.
/// Used by EVM→Sealevel tests to capture the Hyperlane message body without
/// needing a full Mailbox deployment or a connected remote mailbox.
contract MockRecordingMailbox {
    uint32 public lastDomain;
    bytes32 public lastRecipient;
    bytes public lastBody;
    uint256 public dispatchCount;

    function dispatch(uint32 _dest, bytes32 _recipient, bytes calldata _body)
        external
        payable
        returns (bytes32)
    {
        lastDomain = _dest;
        lastRecipient = _recipient;
        lastBody = _body;
        dispatchCount++;
        return bytes32(0);
    }
}
