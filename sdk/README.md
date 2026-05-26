# @thetab/agent-sdk

A TypeScript SDK that turns Tab into a payment rail an autonomous agent can use safely. Ships with tool schemas for OpenAI, Anthropic, and MCP, plus a verifier for Tab's signed payment receipts.

```bash
npm install @thetab/agent-sdk viem
```

## Core client

```ts
import { Tab } from "@thetab/agent-sdk";

const tab = new Tab({
  apiKey: process.env.TAB_API_KEY!,    // sk_live_... or sk_test_...
  baseUrl: process.env.TAB_BASE_URL!,  // required, e.g. https://tab.yourdomain.com
});

const { order, checkout_url } = await tab.orders.create({
  amount: "12.50",
  chain: "base",
  recipient: "@alice",
  idempotencyKey: crypto.randomUUID(),
});
console.log(checkout_url);

const settled = await tab.orders.waitForSettlement(order.id, {
  signal: AbortSignal.timeout(5 * 60_000),
});
```

`waitForSettlement` is tolerant of transient network errors (a few retries with backoff before it gives up) and respects an external `AbortSignal` so you can cancel cleanly.

## OpenAI

```ts
import OpenAI from "openai";
import { Tab } from "@thetab/agent-sdk";
import { tabTools, runTool } from "@thetab/agent-sdk/openai";

const openai = new OpenAI();
const tab = new Tab({ apiKey: process.env.TAB_API_KEY!, baseUrl: process.env.TAB_BASE_URL! });

const completion = await openai.chat.completions.create({
  model: "gpt-4o",
  tools: tabTools,
  messages: [
    { role: "user", content: "Pay @alice 5 USDC on base for last night's pizza." },
  ],
});

for (const call of completion.choices[0].message.tool_calls ?? []) {
  const result = await runTool(tab, call.function.name, JSON.parse(call.function.arguments));
  // result is { ok: true, value } or { ok: false, error: { code, message, status? } }.
  // JSON.stringify it back into the next turn so the model can see + react to errors.
}
```

`runTool` never throws into the caller — every failure (network, 4xx, malformed arguments) comes back as `{ ok: false, error }`. The model can read the error and decide whether to retry, ask the user, or abort.

## Anthropic

```ts
import Anthropic from "@anthropic-ai/sdk";
import { Tab } from "@thetab/agent-sdk";
import { tabTools, runTool } from "@thetab/agent-sdk/anthropic";

const anthropic = new Anthropic();
const tab = new Tab({ apiKey: process.env.TAB_API_KEY!, baseUrl: process.env.TAB_BASE_URL! });

const msg = await anthropic.messages.create({
  model: "claude-opus-4-7",
  max_tokens: 1024,
  tools: tabTools,
  messages: [
    { role: "user", content: "Send 3 USDC to @bob on optimism, memo: 'lunch'." },
  ],
});

for (const block of msg.content) {
  if (block.type === "tool_use") {
    const result = await runTool(tab, block.name, block.input as Record<string, unknown>);
    // include JSON.stringify(result) in the next anthropic.messages.create() turn
  }
}
```

## MCP — Claude Desktop / Cursor / any MCP client

Add this to `claude_desktop_config.json` (or your client's equivalent):

```json
{
  "mcpServers": {
    "tab": {
      "command": "npx",
      "args": ["-y", "@thetab/agent-sdk"],
      "env": {
        "TAB_API_KEY": "sk_live_...",
        "TAB_BASE_URL": "https://tab.yourdomain.com"
      }
    }
  }
}
```

The MCP server exposes the same tools as the OpenAI/Anthropic variants. Your client picks them up automatically.

## Signed payment receipts

When a merchant settles a payment in Tab, they can sign a receipt with their own wallet. The signed JSON is verifiable by anyone who independently knows the merchant's wallet address — usually obtained by resolving the merchant's handle.

```ts
import { Tab } from "@thetab/agent-sdk";
import { verifyReceipt, type SignedReceipt } from "@thetab/agent-sdk/receipts";

const tab = new Tab({ apiKey: process.env.TAB_API_KEY!, baseUrl: process.env.TAB_BASE_URL! });

const receipt: SignedReceipt = JSON.parse(/* JSON the merchant downloaded */);

// Look up the merchant's wallet address independently — this is what makes
// verification meaningful. Without an expected signer, the receipt would
// only prove that *someone* signed it, not that the handle owner did.
const { record } = await tab.handles.resolve(receipt.message.recipientHandle);

const valid = await verifyReceipt(receipt, record.address);
if (!valid) throw new Error("Receipt signature invalid — possible tampering or wrong handle");

console.log(
  `${receipt.message.amount} ${receipt.message.currency} paid to @${receipt.message.recipientHandle} on ${receipt.message.chain}`
);
console.log("On-chain tx:", receipt.message.txHash);
console.log("Payer:       ", receipt.message.payerAddress);
```

The EIP-712 domain pins the chain id, so a receipt for `base` cannot be replayed as a receipt for `optimism` with the same order id. The verifier also rejects receipts with zero-address payers.

## Why this matters for agents

Three properties of Tab make it the right rail for autonomous spenders:

1. **Structured handles.** An LLM can pay `@coffee-shop` the same way a human can. No need to teach it about wallet addresses or chain IDs.
2. **Per-key spend caps.** Issue a scoped `sk_live_` API key with a daily limit (set on the dashboard). The agent literally cannot exceed it.
3. **Verifiable receipts.** After every payment, the agent can stash a signed receipt in its memory. Future agents (or the same one next session) can verify "yes, this was paid" without trusting any intermediary.

## All exposed tools

**Core payments**

| Tool name | What it does |
|---|---|
| `tab_resolve_handle` | Look up a `@handle` → wallet address. Use before paying anyone new. |
| `tab_create_payment` | Create an order. Returns a checkout URL and id. Doesn't move funds itself. |
| `tab_get_order` | Get current status of an order. |
| `tab_wait_for_settlement` | Poll until the order settles or expires. |
| `tab_list_orders` | List orders created by this API key. |
| `tab_create_wallet` | Generate a fresh Tab handle + wallet in one call. |

**OpenTab (share-link escrow)**

| Tool name | What it does |
|---|---|
| `tab_create_escrow_code` | Open a share-link escrow (caller funds it on-chain). |
| `tab_claim_escrow_code` | Sponsored claim — Tab pays the gas. |
| `tab_refund_escrow` | Refund a past-deadline escrow back to the sender. |
| `tab_list_escrows` | List escrows owned by this account. |

**Subscriptions**

| Tool name | What it does |
|---|---|
| `tab_create_subscription_plan` | Create a recurring billing plan. |

**Agent discovery (ERC-8004)**

| Tool name | What it does |
|---|---|
| `tab_agent_manifest` | Read another agent's ERC-8004 manifest (paymentEndpoint, x402Endpoint, services). |
| `tab_agent_reputation` | On-chain feedback summary for an agent. Use as a trust signal before paying. |
| `tab_agent_directory` | Crawl every Tab handle published to the ERC-8004 registry. Cursor-paginated. |

**x402 (pay-per-call)**

| Tool name | What it does |
|---|---|
| `tab_x402_charge` | Mint a 402 Payment Required response for a protected resource. |
| `tab_x402_verify` | Confirm a caller paid before releasing the resource. |

## Errors

Direct SDK calls throw `TabApiError` on non-2xx responses (or on non-JSON 5xx bodies — those get a synthetic `non_json_response` error code so you don't get a raw `SyntaxError`):

```ts
import { Tab, TabApiError } from "@thetab/agent-sdk";

try {
  await tab.orders.create({ ... });
} catch (e) {
  if (e instanceof TabApiError && e.code === "rate_limited") {
    // honour Retry-After and try again
  }
  throw e;
}
```

The `runTool` helpers (`@thetab/agent-sdk/openai`, `@thetab/agent-sdk/anthropic`) never throw — they return `{ ok: false, error }` instead. That's the right shape for feeding back to a model.

## License

MIT.
