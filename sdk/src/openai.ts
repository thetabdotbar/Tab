// OpenAI function-calling tool schemas for Tab.
//
//   import { Tab } from "@tabdotbar/agent-sdk";
//   import { tabTools, runTool } from "@tabdotbar/agent-sdk/openai";
//
//   const tab = new Tab({ apiKey });
//   const completion = await openai.chat.completions.create({
//     model: "gpt-4o",
//     tools: tabTools,
//     messages: [...],
//   });
//   for (const call of completion.choices[0].message.tool_calls ?? []) {
//     const result = await runTool(tab, call.function.name, JSON.parse(call.function.arguments));
//     // result is { ok: true, value } or { ok: false, error } — feed the JSON-stringified
//     // version back as the tool result message. The model can see and react to errors.
//   }

import { Tab, TabApiError, createWallet, type PayableChain } from "./index.js";

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

export const tabTools = [
  {
    type: "function" as const,
    function: {
      name: "tab_resolve_handle",
      description:
        "Look up which wallet address a Tab handle (e.g. @alice) maps to. Use this before paying anyone you haven't paid before, so you can confirm with the user that the address looks right.",
      parameters: {
        type: "object",
        properties: {
          handle: { type: "string", description: "A Tab handle, with or without the @ prefix." },
        },
        required: ["handle"],
      },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "tab_create_payment",
      description:
        "Create a payment order. Returns a hosted checkout URL the user can pay at, and an order id you can poll. This does NOT move funds on its own — the recipient still has to be paid by someone signing a transaction.",
      parameters: {
        type: "object",
        properties: {
          recipient: { type: "string", description: "Tab handle of the recipient (e.g. @alice)." },
          amount: {
            type: "string",
            description: "Decimal amount in the stablecoin unit (e.g. '5.00' for 5 USDC).",
          },
          chain: {
            type: "string",
            enum: CHAIN_ENUM,
            description: "Which chain to settle on. Use 'base' for most cases.",
          },
          memo: {
            type: "string",
            description: "Optional human-readable description of what this payment is for.",
          },
        },
        required: ["recipient", "amount", "chain"],
      },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "tab_get_order",
      description: "Get the current status of a previously-created order.",
      parameters: {
        type: "object",
        properties: { order_id: { type: "string" } },
        required: ["order_id"],
      },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "tab_wait_for_settlement",
      description:
        "Wait for an order to settle (or expire / be cancelled). Polls every two seconds; gives up after timeout_ms. Returns the final order object.",
      parameters: {
        type: "object",
        properties: {
          order_id: { type: "string" },
          timeout_ms: { type: "number" },
        },
        required: ["order_id"],
      },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "tab_list_orders",
      description: "List the orders this API key has created. Useful for reconciliation.",
      parameters: { type: "object", properties: {} },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "tab_create_wallet",
      description:
        "Create a fresh Tab handle + wallet for this agent. Returns the handle, an EVM 0x-address, a Solana base58 address (both derived from the same private key), and the private key itself. STORE THE PRIVATE KEY SECURELY — anyone with it can spend the wallet's funds. You only need to do this once; reuse the same wallet for all subsequent payments by the same agent.",
      parameters: {
        type: "object",
        properties: {
          handle: {
            type: "string",
            description:
              "Desired handle (3-20 chars, a-z 0-9 _). If already taken, returns a conflict error and the agent should try a variant.",
          },
        },
        required: ["handle"],
      },
    },
  },
  // Smart Pay tools — the "one button, any asset" primitives.
  {
    type: "function" as const,
    function: {
      name: "tab_pay_smart",
      description:
        "Pay any supported asset (USDC/ETH/BNB/CELO) to a Tab handle or address. Tab picks the cheapest source from the payer's full balance and executes gaslessly via their 7702 delegation. Example: amount='5' (defaults to USDC) → alice gets 5 USDC on Base. amount='0.2' recipientAsset='BNB' → bob gets 0.2 BNB on BSC. Use this for all generic 'pay X to handle' flows. Requires gasless tipping enabled at thetab.bar/dashboard/tabbot.",
      parameters: {
        type: "object",
        properties: {
          amount: {
            type: "string",
            description:
              "Amount in recipient asset's natural units. '5' for 5 USDC, '0.2' for 0.2 BNB, '0.05' for 0.05 ETH.",
          },
          recipientAsset: {
            type: "string",
            enum: ["USDC", "ETH", "BNB", "CELO"],
            description: "Asset the recipient receives. Defaults to USDC.",
          },
          recipient: {
            type: "string",
            description: "EVM 0x address OR Tab @handle.",
          },
          recipientChain: {
            type: "string",
            enum: ["base", "bsc", "ink", "celo"],
            description:
              "Settle on this chain. Defaults sensibly per recipientAsset (base for USDC/ETH, bsc for BNB, celo for CELO).",
          },
          slippageCap: {
            type: "number",
            description:
              "Max acceptable slippage (0.01 = 1%). Default 0.01. Routes whose expected output falls below the cap are rejected.",
          },
          mode: {
            type: "string",
            enum: ["tip", "pos"],
            description:
              "'tip' (default): sender pays exact, recipient gets less on cross-chain. 'pos': recipient gets exact (preview UX deferred).",
          },
        },
        required: ["amount", "recipient"],
      },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "tab_balances_total",
      description:
        "Aggregated USD balance across every active EVM chain + Solana, with per-row breakdown. Use this before tab_pay_smart to confirm the wallet can cover the payment.",
      parameters: {
        type: "object",
        properties: {
          address: { type: "string", description: "EVM 0x address." },
          solanaAddress: { type: "string", description: "Solana base58 address (optional)." },
        },
        required: ["address"],
      },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "tab_prices_list",
      description:
        "USD spot prices for ETH, BNB, CELO, SOL, USDC. Multi-source fallback (CoinGecko → Binance → Coinbase). Public, no API key needed.",
      parameters: {
        type: "object",
        properties: {
          symbols: {
            type: "array",
            items: { type: "string", enum: ["ETH", "BNB", "CELO", "SOL", "USDC"] },
            description: "Subset of symbols. Defaults to all.",
          },
        },
      },
    },
  },
  // Unified bridge — any supported asset on any chain → any supported
  // asset on any chain. Reuses Smart Pay infrastructure with recipient
  // defaulting to self.
  {
    type: "function",
    function: {
      name: "tab_bridge_quote",
      description:
        "Preview a bridge route. Returns the expected destination amount, USD fee, ETA, and which underlying bridge relay.link picked. Use before tab_bridge_execute.",
      parameters: bridgeOpenAiSchema(),
    },
  },
  {
    type: "function",
    function: {
      name: "tab_bridge_execute",
      description:
        "Bridge any supported asset on any chain → any supported asset on any chain. Pulls source from the caller's 7702 delegation, swaps via relay.link, delivers to the caller's own wallet (or to `recipient` if specified). Gasless. ~20-30s end-to-end. Requires gasless tipping enabled at thetab.bar/dashboard/tabbot.",
      parameters: bridgeOpenAiSchema(),
    },
  },
  {
    type: "function",
    function: {
      name: "tab_bridge_status",
      description:
        "Poll the relay.link destination fill state. State transitions pending → filled (or failed/refunded). Public — requestId is the secret.",
      parameters: {
        type: "object",
        properties: {
          requestId: {
            type: "string",
            description: "relay.link request id returned by tab_bridge_execute.",
          },
        },
        required: ["requestId"],
      },
    },
  },
];

function bridgeOpenAiSchema() {
  return {
    type: "object",
    properties: {
      fromChain: { type: "string", enum: ["base", "bsc", "ink", "celo"] },
      fromAsset: { type: "string", enum: ["USDC", "ETH", "BNB", "CELO"] },
      toChain: { type: "string", enum: ["base", "bsc", "ink", "celo", "solana"] },
      toAsset: { type: "string", enum: ["USDC", "ETH", "BNB", "CELO", "SOL"] },
      amount: {
        type: "string",
        description:
          "Amount in SOURCE asset units. '10' for 10 USDC, '0.05' for 0.05 ETH.",
      },
      slippageCap: { type: "number" },
      recipient: {
        type: "string",
        description:
          "Where to land the destination asset. Defaults to caller's own wallet.",
      },
    },
    required: ["fromChain", "fromAsset", "toChain", "toAsset", "amount"],
  };
}

export type ToolResult =
  | { ok: true; value: unknown }
  | { ok: false; error: { code: string; message: string; status?: number } };

function fail(code: string, message: string, status?: number): ToolResult {
  return { ok: false, error: { code, message, ...(status ? { status } : {}) } };
}

type RequireOk = { ok: true; value: string };
type RequireErr = { ok: false; error: { code: string; message: string; status?: number } };
function requireString(
  args: Record<string, unknown>,
  key: string
): RequireOk | RequireErr {
  const v = args[key];
  if (typeof v !== "string" || !v) {
    return { ok: false, error: { code: "invalid_argument", message: `Missing or non-string field '${key}'` } };
  }
  return { ok: true, value: v };
}

export async function runTool(
  tab: Tab,
  name: string,
  args: Record<string, unknown>
): Promise<ToolResult> {
  try {
    switch (name) {
      case "tab_resolve_handle": {
        const h = requireString(args, "handle");
        if (!h.ok) return h;
        const value = await tab.handles.resolve(h.value);
        return { ok: true, value };
      }
      case "tab_create_payment": {
        const r = requireString(args, "recipient");
        if (!r.ok) return r;
        const a = requireString(args, "amount");
        if (!a.ok) return a;
        const c = requireString(args, "chain");
        if (!c.ok) return c;
        if (!CHAIN_ENUM.includes(c.value as PayableChain)) {
          return fail("invalid_chain", `Unsupported chain '${c.value}'`);
        }
        const value = await tab.orders.create({
          recipient: r.value,
          amount: a.value,
          chain: c.value as PayableChain,
          metadata: typeof args.memo === "string" ? { memo: args.memo } : undefined,
        });
        return { ok: true, value };
      }
      case "tab_get_order": {
        const id = requireString(args, "order_id");
        if (!id.ok) return id;
        const value = await tab.orders.retrieve(id.value);
        return { ok: true, value };
      }
      case "tab_wait_for_settlement": {
        const id = requireString(args, "order_id");
        if (!id.ok) return id;
        const timeoutMs = typeof args.timeout_ms === "number" ? args.timeout_ms : undefined;
        const value = await tab.orders.waitForSettlement(id.value, { timeoutMs });
        return { ok: true, value };
      }
      case "tab_list_orders": {
        const value = await tab.orders.list();
        return { ok: true, value };
      }
      case "tab_create_wallet": {
        const h = requireString(args, "handle");
        if (!h.ok) return h;
        const value = await createWallet(tab, { handle: h.value });
        return { ok: true, value };
      }
      case "tab_pay_smart": {
        // Accept either `amount` (new) or `amountUsd` (legacy alias).
        const amount =
          typeof args.amount === "string"
            ? args.amount
            : typeof args.amountUsd === "string"
              ? args.amountUsd
              : null;
        if (!amount) return fail("invalid_argument", "Missing field 'amount'");
        const r = requireString(args, "recipient");
        if (!r.ok) return r;
        const value = await tab.pay.smart({
          amount,
          recipient: r.value,
          recipientAsset:
            typeof args.recipientAsset === "string"
              ? (args.recipientAsset as "USDC" | "ETH" | "BNB" | "CELO")
              : undefined,
          recipientChain:
            typeof args.recipientChain === "string"
              ? (args.recipientChain as "base" | "bsc" | "ink" | "celo")
              : undefined,
          slippageCap:
            typeof args.slippageCap === "number" ? args.slippageCap : undefined,
          mode:
            typeof args.mode === "string"
              ? (args.mode as "tip" | "pos")
              : undefined,
        });
        return { ok: true, value };
      }
      case "tab_balances_total": {
        const addr = requireString(args, "address");
        if (!addr.ok) return addr;
        const value = await tab.balances.total({
          address: addr.value,
          solanaAddress:
            typeof args.solanaAddress === "string" ? args.solanaAddress : undefined,
        });
        return { ok: true, value };
      }
      case "tab_prices_list": {
        const value = await tab.prices.list(
          Array.isArray(args.symbols)
            ? (args.symbols as Array<"ETH" | "BNB" | "CELO" | "SOL" | "USDC">)
            : undefined
        );
        return { ok: true, value };
      }
      case "tab_bridge_quote":
      case "tab_bridge_execute": {
        const fc = requireString(args, "fromChain");
        if (!fc.ok) return fc;
        const fa = requireString(args, "fromAsset");
        if (!fa.ok) return fa;
        const tc = requireString(args, "toChain");
        if (!tc.ok) return tc;
        const ta = requireString(args, "toAsset");
        if (!ta.ok) return ta;
        const amt = requireString(args, "amount");
        if (!amt.ok) return amt;
        const params = {
          fromChain: fc.value as "base" | "bsc" | "ink" | "celo",
          fromAsset: fa.value as "USDC" | "ETH" | "BNB" | "CELO",
          toChain: tc.value as "base" | "bsc" | "ink" | "celo" | "solana",
          toAsset: ta.value as "USDC" | "ETH" | "BNB" | "CELO" | "SOL",
          amount: amt.value,
          slippageCap:
            typeof args.slippageCap === "number" ? args.slippageCap : undefined,
          recipient:
            typeof args.recipient === "string" ? args.recipient : undefined,
        };
        const value =
          name === "tab_bridge_quote"
            ? await tab.bridge.quote(params)
            : await tab.bridge.execute(params);
        return { ok: true, value };
      }
      case "tab_bridge_status": {
        const id = requireString(args, "requestId");
        if (!id.ok) return id;
        const value = await tab.bridge.status(id.value);
        return { ok: true, value };
      }
      default:
        return fail("unknown_tool", `Unknown Tab tool: ${name}`);
    }
  } catch (e: unknown) {
    if (e instanceof TabApiError) {
      return fail(e.code, e.message, e.status);
    }
    return fail("runtime_error", e instanceof Error ? e.message : "unknown error");
  }
}
