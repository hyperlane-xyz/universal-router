// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import './BaseSlipstreamV2Fixture.t.sol';

contract SlipstreamV2Test is BaseSlipstreamV2Fixture {
    function setUp() public override {
        super.setUp();
        tokenA.approve(address(leafPermit2), type(uint256).max);
        WETH.approve(address(leafPermit2), type(uint256).max);
        leafPermit2.approve(address(tokenA), address(leafRouter), type(uint160).max, type(uint48).max);
        leafPermit2.approve(address(WETH), address(leafRouter), type(uint160).max, type(uint48).max);
    }

    function testInitCodeHash() public pure {
        /// @dev SlipstreamV2 initCodeHash for new implementation (on Base)
        address clPoolImplementation = 0x942e97a4c6FdC38B4CD1c0298D37d81fDD8E5A16;
        bytes32 initCodeHash = _getInitCodeHash({_implementation: clPoolImplementation});
        assertEq(initCodeHash, CL_POOL_INIT_CODE_HASH_2);
    }

    function testExactInputERC20ToWETH() public {
        uint256 amountOutMin = 1e12;
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_IN)));
        bytes memory path = abi.encodePacked(address(tokenA), TICK_SPACING_WITH_FLAG, address(WETH));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, amountOutMin, path, true, false);

        vm.expectEmit(address(leafRouter));
        emit Dispatcher.UniversalRouterSwap({sender: FROM, recipient: FROM});
        leafRouter.execute(commands, inputs);
        assertEq(tokenA.balanceOf(FROM), BALANCE - AMOUNT);
        assertGt(WETH.balanceOf(FROM), BALANCE);
    }

    function testExactInputWETHToERC20() public {
        uint256 amountOutMin = 1e12;
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_IN)));
        bytes memory path = abi.encodePacked(address(WETH), TICK_SPACING_WITH_FLAG, address(tokenA));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, amountOutMin, path, true, false);

        vm.expectEmit(address(leafRouter));
        emit Dispatcher.UniversalRouterSwap({sender: FROM, recipient: FROM});
        leafRouter.execute(commands, inputs);
        assertEq(WETH.balanceOf(FROM), BALANCE - AMOUNT);
        assertGt(tokenA.balanceOf(FROM), BALANCE);
    }

    function testExactInputERC20ToETH() public {
        uint256 amountOutMin = 1e12;
        bytes memory commands =
            abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_IN)), bytes1(uint8(Commands.UNWRAP_WETH)));
        bytes memory path = abi.encodePacked(address(tokenA), TICK_SPACING_WITH_FLAG, address(WETH));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(address(leafRouter), AMOUNT, amountOutMin, path, true, false);
        inputs[1] = abi.encode(FROM, 0);
        uint256 ethBalanceBefore = FROM.balance;

        vm.expectEmit(address(leafRouter));
        emit Dispatcher.UniversalRouterSwap({sender: FROM, recipient: address(leafRouter)});
        leafRouter.execute(commands, inputs);

        uint256 ethBalanceAfter = FROM.balance;
        assertEq(tokenA.balanceOf(FROM), BALANCE - AMOUNT);
        assertGt(ethBalanceAfter - ethBalanceBefore, amountOutMin);
    }

    function testExactInputERC20ToWETHToERC20() public {
        uint256 amountOutMin = 1e12;
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_IN)));
        bytes memory path = abi.encodePacked(
            address(tokenA), TICK_SPACING_WITH_FLAG, address(WETH), TICK_SPACING_WITH_FLAG, address(tokenB)
        );
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, amountOutMin, path, true, false);

        vm.expectEmit(address(leafRouter));
        emit Dispatcher.UniversalRouterSwap({sender: FROM, recipient: FROM});
        leafRouter.execute(commands, inputs);
        assertEq(tokenA.balanceOf(FROM), BALANCE - AMOUNT);
        assertEq(WETH.balanceOf(FROM), BALANCE);
        assertGt(tokenB.balanceOf(FROM), 0);
    }

    function testExactOutputERC20ToWETH() public {
        uint256 amountInMax = BALANCE;
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_OUT)));
        // see L46 of SwapRouter, exact output are executed in reverse order
        bytes memory path = abi.encodePacked(address(WETH), TICK_SPACING_WITH_FLAG, address(tokenA));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, amountInMax, path, true, false);

        vm.expectEmit(address(leafRouter));
        emit Dispatcher.UniversalRouterSwap({sender: FROM, recipient: FROM});
        leafRouter.execute(commands, inputs);
        assertLt(ERC20(address(tokenA)).balanceOf(FROM), BALANCE);
        assertEq(ERC20(address(WETH)).balanceOf(FROM), BALANCE + AMOUNT);
    }

    function testExactOutputWETHToERC20() public {
        uint256 amountInMax = BALANCE;
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_OUT)));
        bytes memory path = abi.encodePacked(address(tokenA), TICK_SPACING_WITH_FLAG, address(WETH));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(ActionConstants.MSG_SENDER, AMOUNT, amountInMax, path, true, false);

        vm.expectEmit(address(leafRouter));
        emit Dispatcher.UniversalRouterSwap({sender: FROM, recipient: FROM});
        leafRouter.execute(commands, inputs);
        assertLt(ERC20(address(WETH)).balanceOf(FROM), BALANCE);
        assertEq(ERC20(address(tokenA)).balanceOf(FROM), BALANCE + AMOUNT);
    }

    function testExactOutputERC20ToETH() public {
        uint256 amountInMax = BALANCE;
        bytes memory commands =
            abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_OUT)), bytes1(uint8(Commands.UNWRAP_WETH)));
        bytes memory path = abi.encodePacked(address(WETH), TICK_SPACING_WITH_FLAG, address(tokenA));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(address(leafRouter), AMOUNT, amountInMax, path, true, false);
        inputs[1] = abi.encode(FROM, 0);
        uint256 ethBalanceBefore = FROM.balance;

        vm.expectEmit(address(leafRouter));
        emit Dispatcher.UniversalRouterSwap({sender: FROM, recipient: address(leafRouter)});
        leafRouter.execute(commands, inputs);

        uint256 ethBalanceAfter = FROM.balance;
        assertLt(tokenA.balanceOf(FROM), BALANCE - AMOUNT);
        assertEq(ethBalanceAfter - ethBalanceBefore, AMOUNT);
    }
}
