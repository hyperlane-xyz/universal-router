// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {DeployUniversalRouter} from '../DeployUniversalRouter.s.sol';

contract DeployArbitrum is DeployUniversalRouter {
    function setUp() public override {
        params = DeploymentParameters({
            weth9: 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1,
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

        outputFilename = 'arbitrum.json';
    }
}
