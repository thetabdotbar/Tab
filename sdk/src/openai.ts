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
];

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
