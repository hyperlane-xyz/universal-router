// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC20} from 'solmate/src/tokens/ERC20.sol';

/// @notice Reproduces the real Tron USDT (TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t) `transfer()` bug:
/// the transfer succeeds and balances move, but its source discards `super.transfer()`'s return
/// value without its own `return true`, and the Tron compiler fills that missing return with 32
/// zero bytes instead of leaving the return data empty. SafeTransferLib reads that as an explicit
/// `false` and reverts, even though the transfer already succeeded.
/// See: https://gist.github.com/yorhodes/a6eccbeba27ff76355c3d761e84d6a35
contract MockTronUSDT is ERC20 {
    constructor() ERC20('Tether USD', 'USDT', 6) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(balanceOf[msg.sender] >= amount, 'insufficient balance');

        balanceOf[msg.sender] -= amount;

        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(msg.sender, to, amount);

        // Force 32 zero-bytes of return data, mimicking the Tron compiler's behavior for a
        // function whose body never hits its own explicit `return`.
        assembly {
            mstore(0, 0)
            return(0, 32)
        }
    }
}
