// Tron mainnet deployment for UniversalRouter targeting SunSwap V3.
//
// Why this script exists: `forge script --broadcast` is not viable on Tron —
// JSON-RPC adapters (Chainstack, TronGrid) don't expose `eth_getTransactionCount`
// because Tron txs use ref_block_hash + ref_block_bytes for replay protection,
// not nonces. See script/deployParameters/DeployTron.s.sol NatSpec for the full
// list of blockers.
//
// What it does: reads bytecode + ABI from foundry's `out-tron/` artifacts
// (which were compiled under `[profile.tron]` with the 0x41-prefix Create2
// override) and deploys Permit2 → UnsupportedProtocol → UniversalRouter via
// @hyperlane-xyz/tron-sdk. `TronContractFactory` extracts the real on-chain
// address from the Tron tx response, since ethers' nonce-based CREATE
// derivation is wrong on TVM.
//
// Prerequisites:
//   1. `FOUNDRY_PROFILE=tron forge build` — produces out-tron artifacts.
//   2. `yarn install` — installs @hyperlane-xyz/tron-sdk.
//   3. Deployer EOA funded with TRX (energy + bandwidth).
//
// Env vars:
//   TRON_RPC_URL   JSON-RPC URL with /jsonrpc suffix (e.g. Chainstack endpoint).
//                  TronGrid public works too: https://api.trongrid.io/jsonrpc.
//                  Custom auth headers via ?custom_rpc_header=Header-Name:value.
//   PRIVATE_KEY    Deployer private key (hex, 0x-prefixed). Pipe via 1Password:
//                    PK=$(op read "op://abacusworks/<deployer>/private_key")
//
// Usage:
//   TRON_RPC_URL=... PRIVATE_KEY=... yarn deploy:tron
//
// Source-of-truth for params is script/deployParameters/DeployTron.s.sol.
// Keep this file in sync if the Solidity setUp() changes.

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ContractFactory } from 'ethers';
import { TronWallet, TronContractFactory } from '@hyperlane-xyz/tron-sdk';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(__dirname, '..');

const TRON_RPC_URL = process.env.TRON_RPC_URL;
const PRIVATE_KEY = process.env.PRIVATE_KEY;
if (!TRON_RPC_URL) throw new Error('TRON_RPC_URL is required (e.g. https://.../jsonrpc)');
if (!PRIVATE_KEY) throw new Error('PRIVATE_KEY is required');

// Mirrors script/deployParameters/DeployTron.s.sol::setUp(). Keep in sync.
const ZERO_BYTES32 = '0x' + '00'.repeat(32);
const STATIC_PARAMS = {
  // WTRX (TNUC9Qb1rRpS5CbWLmNMxXBjyFoydXjWFR)
  weth9: '0x891cdb91d149f23B1a45D9c5Ca78a88d0cB44C18',
  // SunSwap V3 factory (TThJt8zaJzJMhCEScH7zWKnp5buVZqys9x)
  v3Factory: '0xC2708485c99cd8cF058dE1a9a7e3C2d8261a995C',
  // Verified against on-chain pools at fee tiers 500/3000/10000 with 0x41 prefix.
  poolInitCodeHash: '0xba928a717d71946d75999ef1adef801a79cd34a20efecea8b2876b85f5f49580',
  pairInitCodeHash: ZERO_BYTES32,
  veloV2InitCodeHash: ZERO_BYTES32,
  veloCLInitCodeHash: ZERO_BYTES32,
  veloCLInitCodeHash2: ZERO_BYTES32,
  veloCLInitCodeHash3: ZERO_BYTES32,
};

const outDir = join(repoRoot, 'deployment-addresses');
const outPath = join(outDir, 'tron.json');

function loadArtifact(contractName) {
  const path = join(repoRoot, 'out-tron', `${contractName}.sol`, `${contractName}.json`);
  return JSON.parse(readFileSync(path, 'utf8'));
}

function loadAddresses() {
  if (!existsSync(outPath)) return {};
  return JSON.parse(readFileSync(outPath, 'utf8'));
}

function saveAddresses(addresses) {
  if (!existsSync(outDir)) mkdirSync(outDir, { recursive: true });
  writeFileSync(outPath, JSON.stringify(addresses, null, 2) + '\n');
}

// 10% buffer on the gas estimate. fee_limit on Tron is a ceiling (you only
// pay for energy actually consumed), so the buffer is free insurance against
// estimateGas drift between simulation and broadcast.
//
// Idempotent: if `name` already has an address recorded in tron.json, returns
// an attached contract instance instead of broadcasting again. Persists the
// new address immediately so a mid-sequence failure is recoverable.
async function deploy(name, wallet, contractName, args = []) {
  const artifact = loadArtifact(contractName);
  const ethersFactory = new ContractFactory(artifact.abi, artifact.bytecode.object, wallet);
  const factory = new TronContractFactory(ethersFactory, wallet);

  const addresses = loadAddresses();
  if (addresses[name]) {
    console.log(`${name}: ${addresses[name]} (already deployed, skipping)`);
    return ethersFactory.attach(addresses[name]);
  }

  const deployTx = factory.getDeployTransaction(...args);
  const estimatedGas = await wallet.estimateGas(deployTx);
  const gasLimit = estimatedGas.mul(110).div(100);

  console.log(`Deploying ${name}... (gas limit: ${gasLimit.toString()})`);
  const contract = await factory.deploy(...args, { gasLimit });
  console.log(`  ${name}: ${contract.address}`);

  addresses[name] = contract.address;
  saveAddresses(addresses);
  return contract;
}

async function main() {
  const wallet = new TronWallet(PRIVATE_KEY, TRON_RPC_URL);
  console.log('Deployer:', wallet.address);

  const balance = await wallet.getBalance();
  console.log('Balance: ', balance.toString(), 'sun');
  if (balance.isZero()) {
    throw new Error(`Deployer ${wallet.address} has 0 TRX — fund it before deploying.`);
  }

  const permit2 = await deploy('Permit2', wallet, 'Permit2');
  const unsupported = await deploy('UnsupportedProtocol', wallet, 'UnsupportedProtocol');

  const routerParams = {
    permit2: permit2.address,
    weth9: STATIC_PARAMS.weth9,
    v2Factory: unsupported.address,
    v3Factory: STATIC_PARAMS.v3Factory,
    pairInitCodeHash: STATIC_PARAMS.pairInitCodeHash,
    poolInitCodeHash: STATIC_PARAMS.poolInitCodeHash,
    v4PoolManager: unsupported.address,
    veloV2Factory: unsupported.address,
    veloCLFactory: unsupported.address,
    veloV2InitCodeHash: STATIC_PARAMS.veloV2InitCodeHash,
    veloCLInitCodeHash: STATIC_PARAMS.veloCLInitCodeHash,
    veloCLFactory2: unsupported.address,
    veloCLInitCodeHash2: STATIC_PARAMS.veloCLInitCodeHash2,
    veloCLFactory3: unsupported.address,
    veloCLInitCodeHash3: STATIC_PARAMS.veloCLInitCodeHash3,
  };
  const router = await deploy('UniversalRouter', wallet, 'UniversalRouter', [routerParams]);

  const outDir = join(repoRoot, 'deployment-addresses');
  if (!existsSync(outDir)) mkdirSync(outDir, { recursive: true });
  const outPath = join(outDir, 'tron.json');
  const output = {
    Permit2: permit2.address,
    UnsupportedProtocol: unsupported.address,
    UniversalRouter: router.address,
  };
  writeFileSync(outPath, JSON.stringify(output, null, 2) + '\n');
  console.log('Wrote', outPath);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
