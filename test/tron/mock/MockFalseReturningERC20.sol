// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC20} from 'solmate/src/tokens/ERC20.sol';

/// @notice A token that genuinely fails and correctly reports it by returning `false` (without
/// reverting), used to prove the Tron SafeTransferLib override's address check doesn't
/// accidentally weaken the return-data check for tokens other than Tron USDT.
contract MockFalseReturningERC20 is ERC20 {
    constructor() ERC20('FALSE', 'FALSE', 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }
}
