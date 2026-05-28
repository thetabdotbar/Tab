// MCP (Model Context Protocol) server for Tab. Plug into Claude Desktop,
// Cursor, or anything else that speaks MCP. Pass apiKey via env TAB_API_KEY,
// and baseUrl via TAB_BASE_URL (defaults to https://tab.example).

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { Tab, createWallet, type PayableChain } from "./index.js";

const CHAIN_ENUM: PayableChain[] = [
  "base",
  "base-sepolia",
  "bsc",
  "bsc-testnet",
  "ink",
  "ink-sepolia",
  "celo",
  "celo-alfajores",
  "solana",
];

const MCP_TOOLS = [
  {
    name: "tab_resolve_handle",
    description:
      "Look up which wallet address a Tab handle (e.g. @alice) maps to.",
    inputSchema: {
      type: "object",
      properties: { handle: { type: "string" } },
      required: ["handle"],
    },
  },
  {
    name: "tab_create_payment",
    description:
      "Create a payment order. Returns a hosted checkout URL and an order id you can poll.",
    inputSchema: {
      type: "object",
      properties: {
        recipient: { type: "string", description: "Tab handle (with or without @)." },
        amount: { type: "string", description: "Decimal stablecoin amount, e.g. '5.00'." },
        chain: { type: "string", enum: CHAIN_ENUM },
        memo: { type: "string" },
      },
      required: ["recipient", "amount", "chain"],
    },
  },
  {
    name: "tab_get_order",
    description: "Get the current status of an order.",
    inputSchema: {
      type: "object",
      properties: { order_id: { type: "string" } },
      required: ["order_id"],
    },
  },
  {
    name: "tab_wait_for_settlement",
    description: "Poll an order until it reaches a terminal state.",
    inputSchema: {
      type: "object",
      properties: {
        order_id: { type: "string" },
        timeout_ms: { type: "number" },
      },
      required: ["order_id"],
    },
  },
  {
    name: "tab_list_orders",
    description: "List orders created by this API key.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "tab_create_wallet",
    description:
      "Create a fresh Tab handle + wallet for this agent. Returns handle, EVM 0x-address, Solana base58 address, and the private key. STORE THE PRIVATE KEY — anyone with it can spend the wallet.",
    inputSchema: {
      type: "object",
      properties: { handle: { type: "string" } },
      required: ["handle"],
    },
  },
  {
    name: "tab_create_escrow_code",
    description:
      "Open a share-link escrow (OpenTab) for an arbitrary amount. The agent funds the escrow on-chain after this returns (the SDK does NOT submit the on-chain create tx — that's the agent's wallet's job). Anyone who later presents the secret can claim. Pass codeHash = keccak256(secret); generate `secret` yourself and never send it to Tab.",
    inputSchema: {
      type: "object",
      properties: {
        amount: { type: "string", description: "Decimal amount, e.g. '5.00'." },
        chain: { type: "string", enum: CHAIN_ENUM },
        codeHash: {
          type: "string",
          description: "0x-prefixed 32-byte keccak256(secret) — the on-chain commitment.",
        },
        dueInHours: { type: "number", description: "1–2160. Defaults 168 (7d)." },
        note: { type: "string" },
      },
      required: ["amount", "chain", "codeHash"],
    },
  },
  {
    name: "tab_claim_escrow_code",
    description:
      "Sponsored claim of a code-mode escrow. Tab pays the gas, funds go to `recipient`. Requires the raw secret (must hash to the codeHash committed on-chain).",
    inputSchema: {
      type: "object",
      properties: {
        escrow_id: { type: "string" },
        recipient: { type: "string", description: "0x-EVM address or Solana pubkey." },
        secret: { type: "string", description: "0x-hex preimage of the codeHash." },
      },
      required: ["escrow_id", "recipient", "secret"],
    },
  },
  {
    name: "tab_refund_escrow",
    description:
      "Refund an escrow after its deadline. Anyone can trigger this; funds return to the original sender.",
    inputSchema: {
      type: "object",
      properties: { escrow_id: { type: "string" } },
      required: ["escrow_id"],
    },
  },
  {
    name: "tab_list_escrows",
    description: "List OpenTab escrows created by this account.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "tab_create_subscription_plan",
    description:
      "Create a recurring billing plan. The plan owner can later collect charges from each subscriber once per period. Returns the plan record; the actual on-chain createPlan tx is submitted by the owner's wallet.",
    inputSchema: {
      type: "object",
      properties: {
        planId: { type: "string", description: "Creator-scoped string id." },
        amount: { type: "string", description: "Per-period charge, decimal." },
        chain: { type: "string", enum: CHAIN_ENUM },
        periodSeconds: {
          type: "number",
          description: "Seconds between charges. 3600..31536000 (1h..1y).",
        },
      },
      required: ["planId", "amount", "chain", "periodSeconds"],
    },
  },
  // ERC-8004 agent discovery — let an LLM agent look up another
  // agent before paying them. Manifest gives the service surface,
  // reputation gives the trust signal, list gives a directory crawl.
  {
    name: "tab_agent_manifest",
    description:
      "Fetch the ERC-8004 AgentManifest for a Tab handle. Use this before paying another agent to confirm their service surface (paymentEndpoint, x402Endpoint, services).",
    inputSchema: {
      type: "object",
      properties: { handle: { type: "string" } },
      required: ["handle"],
    },
  },
  {
    name: "tab_agent_reputation",
    description:
      "Get the on-chain ERC-8004 Reputation Registry summary + recent feedback for an agent. Use this as a trust signal before paying significant amounts.",
    inputSchema: {
      type: "object",
      properties: { handle: { type: "string" } },
      required: ["handle"],
    },
  },
  {
    name: "tab_agent_directory",
    description:
      "List every Tab handle published to the ERC-8004 Identity Registry. Cursor-paginated. Use this to discover agents you can pay.",
    inputSchema: {
      type: "object",
      properties: {
        limit: { type: "number", description: "1-100, defaults 50." },
        cursor: {
          type: "number",
          description: "registeredAt timestamp from a prior nextCursor.",
        },
      },
    },
  },
  // x402 — per-call payments. Use these when your agent EXPOSES an
  // HTTP surface that other agents pay to call.
  {
    name: "tab_x402_charge",
    description:
      "Mint a spec-compliant 402 Payment Required response for a protected resource. Your agent forwards the returned JSON verbatim to a non-paying caller; on retry the caller proves payment via X-PAYMENT header or the embedded Tab checkout URL.",
    inputSchema: {
      type: "object",
      properties: {
        amount: { type: "string", description: "Decimal stablecoin amount." },
        chain: { type: "string", enum: CHAIN_ENUM },
        resource: { type: "string", description: "The protected URL." },
        description: { type: "string", description: "Human-readable description, max 240 chars." },
      },
      required: ["amount", "chain", "resource", "description"],
    },
  },
  {
    name: "tab_x402_verify",
    description:
      "Confirm a previously-minted x402 order has been paid. Returns { paid, status, txHash, chain }. Use this in your protected handler to decide whether to release the resource.",
    inputSchema: {
      type: "object",
      properties: { order_id: { type: "string" } },
      required: ["order_id"],
    },
  },
  // Smart Pay — the "one button, any asset" primitive. Use this when
  // your agent just wants to pay $X to a Tab handle and doesn't care
  // which chain or which asset funds it. The server picks the cheapest
  // source from the caller's full balance, executes gaslessly via
  // their EIP-7702 delegation, and lands USDC at the recipient.
  {
    name: "tab_pay_smart",
    description:
      "Pay $X USD to a Tab handle. The server picks the cheapest source asset across all your chains and executes gaslessly via your 7702 delegation. Direct path (USDC on dest chain) takes ~3s; cross-asset (e.g. ETH → USDC bridge) ~20-30s. Requires gasless tipping enabled at thetab.bar/dashboard/tabbot.",
    inputSchema: {
      type: "object",
      properties: {
        amountUsd: { type: "string", description: "USD amount, decimal string like '4.20'." },
        recipient: { type: "string", description: "EVM 0x address OR Tab @handle." },
        recipientChain: {
          type: "string",
          enum: ["base", "bsc", "ink", "celo"],
          description: "Settle USDC on this EVM chain. Defaults to 'base'.",
        },
        slippageCap: {
          type: "number",
          description: "Max acceptable slippage (0.01 = 1%). Default 0.01.",
        },
      },
      required: ["amountUsd", "recipient"],
    },
  },
  {
    name: "tab_balances_total",
    description:
      "Aggregated USD balance across every active EVM chain + Solana, with per-row breakdown of each asset. Use before tab_pay_smart to confirm the caller can fund the payment without making the round-trip.",
    inputSchema: {
      type: "object",
      properties: {
        address: { type: "string", description: "EVM 0x address to query." },
        solanaAddress: { type: "string", description: "Solana base58 address (optional)." },
      },
      required: ["address"],
    },
  },
  {
    name: "tab_prices_list",
    description:
      "USD spot prices for ETH, BNB, CELO, SOL, USDC. Backed by CoinGecko → Binance → Coinbase with multi-source fallback. Public, no API key needed. Use this to display USD-denominated balances or denominate quotes.",
    inputSchema: {
      type: "object",
      properties: {
        symbols: {
          type: "array",
          items: { type: "string", enum: ["ETH", "BNB", "CELO", "SOL", "USDC"] },
          description: "Subset of symbols to fetch. Defaults to all.",
        },
      },
    },
  },
];

export async function makeTabMcpServer(opts: {
  apiKey: string;
  baseUrl: string;
}): Promise<Server> {
  const tab = new Tab(opts);
  const server = new Server(
    { name: "tab", version: "0.1.0" },
    { capabilities: { tools: {} } }
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: MCP_TOOLS,
  }));

  server.setRequestHandler(CallToolRequestSchema, async (req) => {
    const { name, arguments: args } = req.params;
    const a = (args ?? {}) as Record<string, unknown>;
    let result: unknown;
    try {
      switch (name) {
        case "tab_resolve_handle":
          result = await tab.handles.resolve(String(a.handle));
          break;
        case "tab_create_payment":
          result = await tab.orders.create({
            recipient: String(a.recipient),
            amount: String(a.amount),
            chain: String(a.chain) as PayableChain,
            metadata: a.memo ? { memo: String(a.memo) } : undefined,
          });
          break;
        case "tab_get_order":
          result = await tab.orders.retrieve(String(a.order_id));
          break;
        case "tab_wait_for_settlement":
          result = await tab.orders.waitForSettlement(String(a.order_id), {
            timeoutMs: typeof a.timeout_ms === "number" ? a.timeout_ms : undefined,
          });
          break;
        case "tab_list_orders":
          result = await tab.orders.list();
          break;
        case "tab_create_wallet":
          result = await createWallet(tab, { handle: String(a.handle) });
          break;
        case "tab_create_escrow_code":
          result = await tab.escrow.create({
            amount: String(a.amount),
            chain: String(a.chain) as PayableChain,
            claimType: "code",
            codeHash: String(a.codeHash) as `0x${string}`,
            dueInHours: typeof a.dueInHours === "number" ? a.dueInHours : undefined,
            note: a.note ? String(a.note) : undefined,
          });
          break;
        case "tab_claim_escrow_code":
          result = await tab.escrow.claimByCode(String(a.escrow_id), {
            recipient: String(a.recipient),
            secret: String(a.secret) as `0x${string}`,
          });
          break;
        case "tab_refund_escrow":
          result = await tab.escrow.refund(String(a.escrow_id));
          break;
        case "tab_list_escrows":
          result = await tab.escrow.list();
          break;
        case "tab_create_subscription_plan":
          result = await tab.subscriptions.createPlan({
            planId: String(a.planId),
            amount: String(a.amount),
            chain: String(a.chain) as PayableChain,
            periodSeconds: Number(a.periodSeconds),
          });
          break;
        case "tab_agent_manifest":
          result = await tab.agents.manifest(String(a.handle));
          break;
        case "tab_agent_reputation":
          result = await tab.agents.reputation(String(a.handle));
          break;
        case "tab_agent_directory":
          result = await tab.agents.list({
            limit: typeof a.limit === "number" ? a.limit : undefined,
            cursor: typeof a.cursor === "number" ? a.cursor : undefined,
          });
          break;
        case "tab_x402_charge":
          result = await tab.x402.charge({
            amount: String(a.amount),
            chain: String(a.chain) as PayableChain,
            resource: String(a.resource),
            description: String(a.description),
          });
          break;
        case "tab_x402_verify":
          result = await tab.x402.verify(String(a.order_id));
          break;
        case "tab_pay_smart":
          result = await tab.pay.smart({
            amountUsd: String(a.amountUsd),
            recipient: String(a.recipient),
            recipientChain:
              a.recipientChain
                ? (String(a.recipientChain) as "base" | "bsc" | "ink" | "celo")
                : undefined,
            slippageCap:
              typeof a.slippageCap === "number" ? a.slippageCap : undefined,
          });
          break;
        case "tab_balances_total":
          result = await tab.balances.total({
            address: String(a.address),
            solanaAddress: a.solanaAddress ? String(a.solanaAddress) : undefined,
          });
          break;
        case "tab_prices_list":
          result = await tab.prices.list(
            Array.isArray(a.symbols)
              ? (a.symbols as Array<"ETH" | "BNB" | "CELO" | "SOL" | "USDC">)
              : undefined
          );
          break;
        default:
          throw new Error(`Unknown tool: ${name}`);
      }
    } catch (e: unknown) {
      return {
        isError: true,
        content: [
          { type: "text", text: e instanceof Error ? e.message : "unknown error" },
        ],
      };
    }
    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    };
  });

  return server;
}

/** Boot a stdio MCP server when this module is run directly. */
export async function runStdioServer(): Promise<void> {
  const apiKey = process.env.TAB_API_KEY;
  const baseUrl = process.env.TAB_BASE_URL;
  if (!apiKey) {
    console.error("TAB_API_KEY env var required for the Tab MCP server");
    process.exit(1);
  }
  if (!baseUrl) {
    console.error(
      "TAB_BASE_URL env var required for the Tab MCP server (e.g. https://tab.yourdomain.com)"
    );
    process.exit(1);
  }
  const server = await makeTabMcpServer({ apiKey, baseUrl });
  const transport = new StdioServerTransport();
  await server.connect(transport);
  // Stay alive; transport handles process lifecycle.
}
