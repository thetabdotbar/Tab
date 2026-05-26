// Direct on-chain reads against the canonical ERC-8004 registries.
//
// The Tab API offers REST wrappers that resolve @handles, cache reads,
// and aggregate reputation feedback — convenient, but they require
// trusting Tab's backend. These helpers bypass Tab entirely and read
// the same data the registry stores on-chain via a public RPC.
//
// Same registry address on every supported EVM chain. See
// https://8004scan.io/networks for the canonical deployments.

import { createPublicClient, http, type Address } from "viem";
import { base, bsc, celo } from "viem/chains";

/** ERC-8004 Identity Registry — ERC-1967 proxy, identical address on
 *  every EVM chain that has 8004 deployed. */
export const ERC8004_IDENTITY_REGISTRY: Address =
  "0x8004A169FB4a3325136EB29fA0ceB6D2e539a432";

/** ERC-8004 Reputation Registry — ERC-1967 proxy, identical address on
 *  every EVM chain that has 8004 deployed. */
export const ERC8004_REPUTATION_REGISTRY: Address =
  "0x8004BAa17C55a88189AE136b182e5fdA19dE9b63";

export type Erc8004Chain = "base" | "bsc" | "celo";

const DEFAULT_RPC: Record<Erc8004Chain, string> = {
  base: "https://mainnet.base.org",
  bsc: "https://bsc-dataseed.binance.org",
  celo: "https://forno.celo.org",
};

const CHAIN_CONFIG = { base, bsc, celo } as const;

/** Identity Registry ABI subset — the read-only surface this SDK uses. */
export const IDENTITY_REGISTRY_ABI = [
  {
    type: "function",
    name: "tokenURI",
    stateMutability: "view",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [{ type: "string" }],
  },
  {
    type: "function",
    name: "ownerOf",
    stateMutability: "view",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "getAgentWallet",
    stateMutability: "view",
    inputs: [{ name: "agentId", type: "uint256" }],
    outputs: [{ type: "address" }],
  },
] as const;

/** Reputation Registry ABI subset — read-only surface this SDK uses. */
export const REPUTATION_REGISTRY_ABI = [
  {
    type: "function",
    name: "getSummary",
    stateMutability: "view",
    inputs: [
      { name: "agentId", type: "uint256" },
      { name: "clientAddresses", type: "address[]" },
      { name: "tag1", type: "string" },
      { name: "tag2", type: "string" },
    ],
    outputs: [
      { name: "count", type: "uint64" },
      { name: "summaryValue", type: "int128" },
      { name: "summaryValueDecimals", type: "uint8" },
    ],
  },
  {
    type: "function",
    name: "getClients",
    stateMutability: "view",
    inputs: [{ name: "agentId", type: "uint256" }],
    outputs: [{ type: "address[]" }],
  },
  {
    type: "function",
    name: "readAllFeedback",
    stateMutability: "view",
    inputs: [
      { name: "agentId", type: "uint256" },
      { name: "clientAddresses", type: "address[]" },
      { name: "tag1", type: "string" },
      { name: "tag2", type: "string" },
      { name: "includeRevoked", type: "bool" },
    ],
    outputs: [
      { name: "clients", type: "address[]" },
      { name: "feedbackIndexes", type: "uint64[]" },
      { name: "values", type: "int128[]" },
      { name: "valueDecimals", type: "uint8[]" },
      { name: "tag1s", type: "string[]" },
      { name: "tag2s", type: "string[]" },
      { name: "revokedStatuses", type: "bool[]" },
    ],
  },
] as const;

export type OnChainReadOptions = {
  /** Which EVM chain to read from. Defaults to "base". Registry address
   *  is the same on every chain, so the data lives on whichever chain
   *  the agent registered on. */
  chain?: Erc8004Chain;
  /** Override the default public RPC. Use a paid RPC (Alchemy/QuickNode)
   *  for production traffic — public endpoints are rate-limited. */
  rpcUrl?: string;
};

/** Minimal viem PublicClient surface this SDK uses. Typed narrowly so
 *  the export's inferred type doesn't drag in all 70+ viem actions. */
export type Erc8004ReadClient = {
  readContract: (params: {
    address: Address;
    abi: readonly unknown[];
    functionName: string;
    args?: readonly unknown[];
  }) => Promise<unknown>;
};

export function makeReadClient(
  opts: OnChainReadOptions = {}
): Erc8004ReadClient {
  const chain = opts.chain ?? "base";
  const rpcUrl = opts.rpcUrl ?? DEFAULT_RPC[chain];
  return createPublicClient({
    chain: CHAIN_CONFIG[chain],
    transport: http(rpcUrl),
  }) as unknown as Erc8004ReadClient;
}

/** Convert int128 + decimals to a JS number safely. Reputation scores
 *  can range from booleans (1/-1) to fixed-point values, so the
 *  registry stores them as (value, decimals) pairs. */
export function feedbackValueToNumber(
  value: bigint,
  decimals: number
): number {
  const sign = value < 0n ? -1 : 1;
  const abs = value < 0n ? -value : value;
  const divisor = 10n ** BigInt(decimals);
  const whole = Number(abs / divisor);
  const frac = Number(abs % divisor) / Number(divisor);
  return sign * (whole + frac);
}
