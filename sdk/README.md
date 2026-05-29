# @tabdotbar/agent-sdk

A TypeScript SDK that turns Tab into a payment rail an autonomous agent can use safely. Ships with tool schemas for OpenAI, Anthropic, and MCP, plus a verifier for Tab's signed payment receipts.

```bash
npm install @tabdotbar/agent-sdk viem
```

## Core client

```ts
import { Tab } from "@tabdotbar/agent-sdk";

const tab = new Tab({
  apiKey: process.env.TAB_API_KEY!,    // sk_live_... or sk_test_...
  baseUrl: process.env.TAB_BASE_URL!,  // required, e.g. https://tab.yourdomain.com
});
```

## Smart Pay (recommended)

One call, any asset, any chain. The server picks the cheapest source across every chain you hold balance on, then executes gaslessly via your EIP-7702 delegation. Direct path (you hold the target asset on the target chain) lands in ~3s with zero fee; cross-asset/cross-chain via relay.link is ~20-30s with a small bridge fee.

```ts
// Pay 20 USDC to @alice — Tab picks whatever source covers it cheapest
const result = await tab.pay.smart({
  amount: "20",
  recipient: "@alice",            // handle or 0x address
  // recipientAsset defaults to "USDC"
  // recipientChain defaults to "base"
});

// Tip a friend 0.2 BNB — recipient gets BNB on BSC, source could be
// your USDC on Base or any other asset
await tab.pay.smart({
  amount: "0.2",
  recipientAsset: "BNB",
  recipient: "@bob",
});

// Pay 0.05 ETH to a vendor on Ink
await tab.pay.smart({
  amount: "0.05",
  recipientAsset: "ETH",
  recipientChain: "ink",
  recipient: "@vendor",
});

if (result.kind === "direct") {
  console.log("Tx:", result.txHash);
} else {
  console.log("Pull tx:", result.pullTxHash);
  console.log("Source swap:", result.sourceTxHash);
}

// Every response includes fee transparency. Direct (same-chain) is
// always zero fee. Cross-chain incurs ~$0.05-0.40 depending on amount.
console.log(`Sent $${result.senderPaysUsd} → recipient got $${result.recipientAmountUsd} (fee $${result.feeUsd})`);
```

Requires the payer wallet to have [gasless tipping enabled](https://thetab.bar/dashboard/tabbot) (one EIP-7702 signature). After that, every Smart Pay call is fully gasless.

### Fee model

- **Same-chain payment** (recipient's chain matches what you hold): **zero fee**. Sender and recipient see the same amount.
- **Cross-chain payment**: the bridge / swap fee comes from relay.link (~$0.05-0.10 flat on USDC↔USDC bridges, 0.5-2% on asset swaps).
  - **`mode: "tip"`** (default): sender pays exactly `amountUsd`. Recipient receives `amountUsd - feeUsd`. Same model Cashapp/Venmo use for international transfers. The receipt shows the breakdown.
  - **`mode: "pos"`** (for bills / merchant POS where recipient must receive an exact amount): sender pays `amountUsd + feeUsd`. Pre-confirm preview UX is on the roadmap — for now agents should sum `senderPaysUsd` and verify before calling.

```ts
// "Tip mode" — default. Sender pays $10. Alice gets ~$9.94 cross-chain.
await tab.pay.smart({ amountUsd: "10.00", recipient: "@alice" });

// "POS mode" — alice must receive exactly $10. Sender pays $10.06.
await tab.pay.smart({ amountUsd: "10.00", recipient: "@alice", mode: "pos" });
```

## Bridge (any asset → any asset)

Bridge any supported asset on any chain to any supported asset on any chain. Internally the same Smart Pay infrastructure as `tab.pay.smart` — the bridge is just a self-pay with explicit source. Gasless via the caller's 7702 delegation. Same `~20-30s` end-to-end timing.

```ts
// Preview before executing
const quote = await tab.bridge.quote({
  fromChain: "base",
  fromAsset: "ETH",
  toChain: "bsc",
  toAsset: "USDC",
  amount: "0.05",
});
console.log(`You'll get ~${quote.recipientAmount} USDC on BSC (fee $${quote.feeUsd})`);

// Execute when ready
const result = await tab.bridge.execute({
  fromChain: "base",
  fromAsset: "ETH",
  toChain: "bsc",
  toAsset: "USDC",
  amount: "0.05",
});

// Poll relay.link for destination fill
if (result.kind === "relay" && result.requestId) {
  while (true) {
    const s = await tab.bridge.status(result.requestId);
    if (s.state === "filled") break;
    if (s.state === "failed" || s.state === "refunded") throw new Error(s.state);
    await new Promise((r) => setTimeout(r, 5000));
  }
}
```

Same-chain swaps (e.g. ETH → USDC on Base), cross-chain bridges (USDC on Base → USDC on BSC), and cross-asset cross-chain (ETH on Base → BNB on BSC) all go through the same call. Source and destination can be EVM (Base/BSC/Ink/Celo) **or Solana** — Solana sources use the user's Subscriptions Delegation Program approval for USDC + wSOL.

For users who land on Tab with only EVM USDC and need SOL for the Solana Smart Pay onboarding tx, `tab.solana.topUp({ amountSol: "0.07" })` pulls USDC via the user's 7702 delegation and bridges native SOL to their Solana wallet through relay.link.

### Aggregate balance + spot prices

```ts
// Total USD balance across all chains, with breakdown
const balance = await tab.balances.total({
  address: "0x...",
  solanaAddress: "...",
});
console.log("Total:", balance.totalUsd);

// Multi-source spot prices (no API key needed)
const prices = await tab.prices.list();
console.log("ETH:", prices.prices.ETH);
```

## Legacy orders (external customers)

When the payer isn't on Tab (e.g. a customer paying via MetaMask), use the hosted checkout flow — the customer signs an EIP-2612 permit on the checkout page, no Tab account required.

```ts
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

`waitForSettlement` is tolerant of transient network errors and respects an external `AbortSignal`.

## OpenAI

```ts
import OpenAI from "openai";
import { Tab } from "@tabdotbar/agent-sdk";
import { tabTools, runTool } from "@tabdotbar/agent-sdk/openai";

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
import { Tab } from "@tabdotbar/agent-sdk";
import { tabTools, runTool } from "@tabdotbar/agent-sdk/anthropic";

const anthropic = new Anthropic();
const tab = new Tab({ apiKey: process.env.TAB_API_KEY!, baseUrl: process.env.TAB_BASE_URL! });

const msg = await anthropic.messages.create({
  model: "claude-opus-4-7",
  max_tokens: 1024,
  tools: tabTools,
  messages: [
    { role: "user", content: "Send 3 USDC to @bob on base, memo: 'lunch'." },
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
      "args": ["-y", "@tabdotbar/agent-sdk"],
      "env": {
        "TAB_API_KEY": "sk_live_...",
        "TAB_BASE_URL": "https://tab.yourdomain.com"
      }
    }
  }
}
```

The MCP server exposes the same tools as the OpenAI/Anthropic variants. Your client picks them up automatically.

## ERC-8004 — direct on-chain reads

The agent-discovery tools (`agents.manifest`, `agents.reputation`,
`agents.list`) hit Tab's REST cache by default — fast, handle-aware,
no RPC bandwidth. When you need to *verify* what an agent really
published, skip Tab and read the canonical ERC-8004 registries
directly:

```ts
import { Tab } from "@tabdotbar/agent-sdk";

const tab = new Tab({ apiKey: process.env.TAB_API_KEY!, baseUrl: process.env.TAB_BASE_URL! });

// Step 1 — handle → agentId (Tab's index; handles aren't on-chain).
const { agentId } = await tab.agents.resolveAgentId("@alice");

// Step 2 — everything below talks to the ERC-8004 contract directly.
const manifest = await tab.agents.manifestOnChain(agentId, { chain: "base" });
const owner    = await tab.agents.ownerOnChain(agentId,    { chain: "base" });
const wallet   = await tab.agents.walletOnChain(agentId,   { chain: "base" });
const rep      = await tab.agents.reputationOnChain(agentId, { chain: "base" });

console.log(`@alice published`, manifest);
console.log(`owner ${owner}, wallet ${wallet}, ${rep.count} feedback entries, summary ${rep.summaryValue}`);
```

The same registry address (`0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`)
is deployed on Base, BSC, and Celo — pick whichever chain the agent
registered on. By default the SDK hits the chain's public RPC; pass
`rpcUrl` to use a paid endpoint for production traffic.

## Signed payment receipts

When a merchant settles a payment in Tab, they can sign a receipt with their own wallet. The signed JSON is verifiable by anyone who independently knows the merchant's wallet address — usually obtained by resolving the merchant's handle.

```ts
import { Tab } from "@tabdotbar/agent-sdk";
import { verifyReceipt, type SignedReceipt } from "@tabdotbar/agent-sdk/receipts";

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
import { Tab, TabApiError } from "@tabdotbar/agent-sdk";

try {
  await tab.orders.create({ ... });
} catch (e) {
  if (e instanceof TabApiError && e.code === "rate_limited") {
    // honour Retry-After and try again
  }
  throw e;
}
```

The `runTool` helpers (`@tabdotbar/agent-sdk/openai`, `@tabdotbar/agent-sdk/anthropic`) never throw — they return `{ ok: false, error }` instead. That's the right shape for feeding back to a model.

## License

MIT.
