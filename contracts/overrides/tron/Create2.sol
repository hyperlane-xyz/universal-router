// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Tron (TVM) variant of OZ Create2 — identical to the upstream library except
// the CREATE2 prefix byte is 0x41 instead of 0xff.  TVM uses 0x41 as its
// address-space tag; using the EVM 0xff prefix produces wrong pool addresses
// on SunSwap V3 (and any other TVM CREATE2-derived address).
//
// Drop-in replacement via the [profile.tron] foundry remapping:
//   contracts/modules/uniswap/v3/V3SwapRouter.sol:@openzeppelin/contracts/utils/Create2.sol
//     = contracts/overrides/tron/Create2.sol
//
// Only computeAddress is overridden (deploy() is unchanged — we never
// broadcast through forge on Tron).
library Create2 {
    error Create2EmptyBytecode();
    error Create2InsufficientBalance(uint256 balance, uint256 needed);
    error Create2FailedDeployment();

    function deploy(uint256 amount, bytes32 salt, bytes memory bytecode) internal returns (address addr) {
        if (address(this).balance < amount) {
            revert Create2InsufficientBalance(address(this).balance, amount);
        }
        if (bytecode.length == 0) {
            revert Create2EmptyBytecode();
        }
        assembly ("memory-safe") {
            addr := create2(amount, add(bytecode, 0x20), mload(bytecode), salt)
        }
        if (addr == address(0)) {
            revert Create2FailedDeployment();
        }
    }

    function computeAddress(bytes32 salt, bytes32 bytecodeHash) internal view returns (address) {
        return computeAddress(salt, bytecodeHash, address(this));
    }

    // Tron uses 0x41 as the CREATE2 prefix instead of EVM's 0xff.
    function computeAddress(bytes32 salt, bytes32 bytecodeHash, address deployer) internal pure returns (address addr) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)

            mstore(add(ptr, 0x40), bytecodeHash)
            mstore(add(ptr, 0x20), salt)
            mstore(ptr, deployer)
            let start := add(ptr, 0x0b)
            mstore8(start, 0x41) // TVM prefix — 0xff on EVM, 0x41 on Tron
            addr := and(keccak256(start, 85), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }
}
