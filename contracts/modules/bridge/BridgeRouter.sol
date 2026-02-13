// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {ERC20} from 'solmate/src/tokens/ERC20.sol';
import {SafeTransferLib} from 'solmate/src/utils/SafeTransferLib.sol';
import {HypXERC20} from '@hyperlane/core/contracts/token/extensions/HypXERC20.sol';
import {HypERC20Collateral} from '@hyperlane/core/contracts/token/HypERC20Collateral.sol';
import {StandardHookMetadata} from '@hyperlane/core/contracts/hooks/libs/StandardHookMetadata.sol';
import {TypeCasts} from '@hyperlane/core/contracts/libs/TypeCasts.sol';

import {ITokenBridge} from '../../interfaces/external/ITokenBridge.sol';
import {IHypCollateralBridge} from '../../interfaces/external/IHypCollateralBridge.sol';
import {IFeeRecipient} from '../../interfaces/external/IFeeRecipient.sol';
import {ILinearFee} from '../../interfaces/external/ILinearFee.sol';
import {BridgeTypes} from '../../libraries/BridgeTypes.sol';
import {Permit2Payments} from './../Permit2Payments.sol';

/// @title BridgeRouter
/// @notice Handles cross-chain bridging operations
abstract contract BridgeRouter is Permit2Payments {
    using SafeTransferLib for ERC20;

    error InvalidTokenAddress();
    error InvalidRecipient();
    error InvalidBridgeType(uint8 bridgeType);
    error TokenFeeExceedsMax(uint256 tokenFee, uint256 maxTokenFee);

    uint256 public constant OPTIMISM_CHAIN_ID = 10;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Send tokens x-chain using the selected bridge
    /// @param bridgeType The type of bridge to use
    /// @param sender The address initiating the bridge
    /// @param recipient The recipient address on the destination chain
    /// @param token The token to be bridged
    /// @param bridge The bridge used for the token
    /// @param amount The amount to bridge
    /// @param msgFee The fee to pay for message bridging
    /// @param maxTokenFee The maximum acceptable fee for token bridging
    /// @param domain The destination domain
    /// @param payer The address to pay for the transfer
    function bridgeToken(
        uint8 bridgeType,
        address sender,
        address recipient,
        address token,
        address bridge,
        uint256 amount,
        uint256 msgFee,
        uint256 maxTokenFee,
        uint32 domain,
        address payer
    ) internal {
        if (recipient == address(0)) revert InvalidRecipient();

        if (bridgeType == BridgeTypes.HYP_XERC20) {
            if (address(HypXERC20(bridge).wrappedToken()) != token) revert InvalidTokenAddress();

            prepareTokensForBridge({_token: token, _bridge: bridge, _payer: payer, _amount: amount});

            executeHypXERC20Bridge({
                bridge: bridge,
                sender: sender,
                recipient: recipient,
                amount: amount,
                msgFee: msgFee,
                domain: domain
            });
            ERC20(token).safeApprove({to: bridge, amount: 0});
        } else if (bridgeType == BridgeTypes.XVELO) {
            address _bridgeToken =
                block.chainid == OPTIMISM_CHAIN_ID ? ITokenBridge(bridge).erc20() : ITokenBridge(bridge).xerc20();
            if (_bridgeToken != token) revert InvalidTokenAddress();

            prepareTokensForBridge({_token: token, _bridge: bridge, _payer: payer, _amount: amount});

            executeXVELOBridge({
                bridge: bridge,
                sender: sender,
                recipient: recipient,
                amount: amount,
                msgFee: msgFee,
                domain: domain
            });
            ERC20(token).safeApprove({to: bridge, amount: 0});
        } else if (bridgeType == BridgeTypes.HYP_ERC20_COLLATERAL) {
            if (address(HypERC20Collateral(bridge).wrappedToken()) != token) revert InvalidTokenAddress();

            uint256 tokenFee = _getTokenFee(bridge, amount, domain);
            if (tokenFee > maxTokenFee) revert TokenFeeExceedsMax(tokenFee, maxTokenFee);

            prepareTokensForBridge({_token: token, _bridge: bridge, _payer: payer, _amount: amount});

            executeHypERC20CollateralBridge({
                bridge: bridge,
                recipient: recipient,
                amount: amount - tokenFee,
                msgFee: msgFee,
                domain: domain
            });
            ERC20(token).safeApprove({to: bridge, amount: 0});
        } else {
            revert InvalidBridgeType({bridgeType: bridgeType});
        }
    }

    /// @dev Executes bridge transfer via HypXERC20
    function executeHypXERC20Bridge(
        address bridge,
        address sender,
        address recipient,
        uint256 amount,
        uint256 msgFee,
        uint32 domain
    ) private {
        bytes memory metadata = StandardHookMetadata.formatMetadata({
            _msgValue: uint256(0),
            _gasLimit: HypXERC20(bridge).destinationGas(domain),
            _refundAddress: sender,
            _customMetadata: ''
        });

        HypXERC20(bridge).transferRemote{value: msgFee}({
            _destination: domain,
            _recipient: TypeCasts.addressToBytes32(recipient),
            _amountOrId: amount,
            _hookMetadata: metadata,
            _hook: address(HypXERC20(bridge).hook())
        });
    }

    /// @dev Executes bridge transfer via XVELO TokenBridge
    function executeXVELOBridge(
        address bridge,
        address sender,
        address recipient,
        uint256 amount,
        uint256 msgFee,
        uint32 domain
    ) private {
        ITokenBridge(bridge).sendToken{value: msgFee}({
            _recipient: recipient,
            _amount: amount,
            _domain: domain,
            _refundAddress: sender
        });
    }

    /// @dev Executes bridge transfer via HypERC20Collateral
    function executeHypERC20CollateralBridge(
        address bridge,
        address recipient,
        uint256 amount,
        uint256 msgFee,
        uint32 domain
    ) private {
        HypERC20Collateral(bridge).transferRemote{value: msgFee}({
            _destination: domain,
            _recipient: TypeCasts.addressToBytes32(recipient),
            _amountOrId: amount
        });
    }

    /// @dev Calculates the token fee for a HypERC20Collateral bridge transfer
    /// @param bridge The bridge contract address
    /// @param amount The amount being bridged
    /// @param domain The destination domain
    /// @return fee The calculated token fee
    function _getTokenFee(address bridge, uint256 amount, uint32 domain) private view returns (uint256 fee) {
        address feeRecipient = IHypCollateralBridge(bridge).feeRecipient();
        address linearFeeAddr = IFeeRecipient(feeRecipient).feeContracts(domain);
        uint256 maxFee = ILinearFee(linearFeeAddr).maxFee();
        uint256 halfAmount = ILinearFee(linearFeeAddr).halfAmount();
        uint256 maxFeeBps = (maxFee * BPS_DENOMINATOR) / (2 * halfAmount);
        fee = amount - (amount * (BPS_DENOMINATOR - maxFeeBps)) / BPS_DENOMINATOR;
    }

    /// @dev Moves the tokens from sender to this contract then approves the bridge
    function prepareTokensForBridge(address _token, address _bridge, address _payer, uint256 _amount) private {
        if (_payer != address(this)) {
            payOrPermit2Transfer({token: _token, payer: _payer, recipient: address(this), amount: _amount});
        }
        ERC20(_token).safeApprove({to: _bridge, amount: _amount});
    }
}
