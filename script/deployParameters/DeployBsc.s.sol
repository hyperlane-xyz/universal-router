// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {DeployUniversalRouter} from '../DeployUniversalRouter.s.sol';

contract DeployBsc is DeployUniversalRouter {
    function setUp() public override {
        // PancakeSwap V3 uses a separate PoolDeployer as the CREATE2 origin,
        // so v3Factory must be the deployer address, not the PCS V3 Factory.
        params = DeploymentParameters({
            weth9: 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c, // WBNB
            v2Factory: 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73, // PancakeSwap V2
            v3Factory: 0x41ff9AA7e16B8B1a8a8dc4f0eFacd93D02d071c9, // PancakeSwap V3 PoolDeployer
            pairInitCodeHash: 0x00fb7f630766e6a796048ea87d01acd3068e8ff67d078148a3fa3f4a84f69bd5,
            poolInitCodeHash: 0x6ce8eb472fa82df5469c6ab6d485f17c3ad13c8cd7af59b3d4a8026c5ce0f7e2,
            v4PoolManager: address(0),
            veloV2Factory: address(0),
            veloCLFactory: address(0),
            veloV2InitCodeHash: bytes32(0),
            veloCLInitCodeHash: bytes32(0)
        });

        outputFilename = 'bsc.json';
    }
}
