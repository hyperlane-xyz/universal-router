// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {DeployUniversalRouter} from '../DeployUniversalRouter.s.sol';

contract DeployPolygon is DeployUniversalRouter {
    function setUp() public override {
        params = DeploymentParameters({
            weth9: 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270, // WMATIC
            v2Factory: address(0),
            v3Factory: 0x1F98431c8aD98523631AE4a59f267346ea31F984,
            pairInitCodeHash: bytes32(0),
            poolInitCodeHash: 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54,
            v4PoolManager: address(0),
            veloV2Factory: address(0),
            veloCLFactory: address(0),
            veloV2InitCodeHash: bytes32(0),
            veloCLInitCodeHash: bytes32(0)
        });

        outputFilename = 'polygon.json';
    }
}
