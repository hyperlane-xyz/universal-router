// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {IRouterImmutables} from '../../interfaces/IRouterImmutables.sol';

struct RouterParameters {
    address v2Factory;
    address v3Factory;
    bytes32 pairInitCodeHash;
    bytes32 poolInitCodeHash;
    address veloV2Factory;
    address veloCLFactory;
    bytes32 veloV2InitCodeHash;
    bytes32 veloCLInitCodeHash;
    address veloCLFactory2;
    bytes32 veloCLInitCodeHash2;
    address veloCLFactory3;
    bytes32 veloCLInitCodeHash3;
}

contract RouterImmutables is IRouterImmutables {
    ///@inheritdoc IRouterImmutables
    address public immutable UNISWAP_V2_FACTORY;

    ///@inheritdoc IRouterImmutables
    bytes32 public immutable UNISWAP_V2_PAIR_INIT_CODE_HASH;

    ///@inheritdoc IRouterImmutables
    address public immutable UNISWAP_V3_FACTORY;

    ///@inheritdoc IRouterImmutables
    bytes32 public immutable UNISWAP_V3_POOL_INIT_CODE_HASH;

    ///@inheritdoc IRouterImmutables
    address public immutable VELODROME_V2_FACTORY;

    ///@inheritdoc IRouterImmutables
    bytes32 public immutable VELODROME_V2_INIT_CODE_HASH;

    ///@inheritdoc IRouterImmutables
    address public immutable VELODROME_CL_FACTORY;

    ///@inheritdoc IRouterImmutables
    bytes32 public immutable VELODROME_CL_POOL_INIT_CODE_HASH;

    ///@inheritdoc IRouterImmutables
    address public immutable VELODROME_CL_FACTORY_2;

    ///@inheritdoc IRouterImmutables
    bytes32 public immutable VELODROME_CL_POOL_INIT_CODE_HASH_2;

    ///@inheritdoc IRouterImmutables
    address public immutable VELODROME_CL_FACTORY_3;

    ///@inheritdoc IRouterImmutables
    bytes32 public immutable VELODROME_CL_POOL_INIT_CODE_HASH_3;

    constructor(RouterParameters memory params) {
        UNISWAP_V2_FACTORY = params.v2Factory;
        UNISWAP_V2_PAIR_INIT_CODE_HASH = params.pairInitCodeHash;
        UNISWAP_V3_FACTORY = params.v3Factory;
        UNISWAP_V3_POOL_INIT_CODE_HASH = params.poolInitCodeHash;
        VELODROME_V2_FACTORY = params.veloV2Factory;
        VELODROME_V2_INIT_CODE_HASH = params.veloV2InitCodeHash;
        VELODROME_CL_FACTORY = params.veloCLFactory;
        VELODROME_CL_POOL_INIT_CODE_HASH = params.veloCLInitCodeHash;
        VELODROME_CL_FACTORY_2 = params.veloCLFactory2;
        VELODROME_CL_POOL_INIT_CODE_HASH_2 = params.veloCLInitCodeHash2;
        VELODROME_CL_FACTORY_3 = params.veloCLFactory3;
        VELODROME_CL_POOL_INIT_CODE_HASH_3 = params.veloCLInitCodeHash3;
    }
}
