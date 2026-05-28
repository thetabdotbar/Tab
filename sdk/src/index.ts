// Core Tab API client for agents.
//
//   import { Tab } from "@tabdotbar/agent-sdk";
//   const tab = new Tab({ apiKey: process.env.TAB_KEY!, baseUrl: "https://tab.example" });
//   await tab.orders.create({ amount: "5.00", chain: "base", recipient: "@alice" });

import {
  ERC8004_IDENTITY_REGISTRY,
  ERC8004_REPUTATION_REGISTRY,
  IDENTITY_REGISTRY_ABI,
  REPUTATION_REGISTRY_ABI,
  makeReadClient,
  feedbackValueToNumber,
  type OnChainReadOptions,
} from "./erc8004.js";

export {
  ERC8004_IDENTITY_REGISTRY,
  ERC8004_REPUTATION_REGISTRY,
  type OnChainReadOptions,
  type Erc8004Chain,
} from "./erc8004.js";

export type EvmChain =
  | "base"
  | "base-sepolia"
  | "bsc"
  | "bsc-testnet"
  | "ink"
  | "ink-sepolia"
  | "celo"
  | "celo-alfajores"
  | "anvil";

/** Every chain Tab can route a payment to. Solana sits alongside the EVM
 *  family — same handles, same SDK calls, different signature curve. */
export type PayableChain = EvmChain | "solana";

/** @deprecated use PayableChain for new code. Kept as alias for the EVM-only
 *  subset; agentic callers should use PayableChain. */
export type SupportedChain = PayableChain;

export type OrderStatus =
  | "awaiting_payment"
  | "processing"
  | "completed"
  | "expired"
  | "cancelled";

export type Order = {
  id: string;
  amount: string;
  amountWei: string;
  currency: string;
  chain: PayableChain;
  recipientHandle: string;
  /** 0x-EVM address on EVM chains, base58 pubkey on Solana. */
  recipientAddress: string;
  status: OrderStatus;
  /** Hex tx hash on EVM, base58 signature on Solana. */
  txHash?: string;
  /** Same encoding as `recipientAddress`. Populated after settlement. */
  payerAddress?: string;
  createdAt: number;
  expiresAt: number;
  metadata?: Record<string, unknown>;
};

export type CreateOrderParams = {
  amount: string;
  chain: PayableChain;
  recipient: string; // handle, with or without @
  currency?: string;
  expires_in?: number;
  metadata?: Record<string, unknown>;
  idempotencyKey?: string;
};

export type TabError = {
  code: string;
  message: string;
  request_id?: string;
};

export class TabApiError extends Error {
  public readonly status: number;
  public readonly code: string;
  public readonly requestId?: string;
  constructor(status: number, body: { error?: TabError }) {
    const err = body.error ?? { code: "unknown", message: "unknown error" };
    super(`[${err.code}] ${err.message}`);
    this.status = status;
    this.code = err.code;
    this.requestId = err.request_id;
  }
}

export type TabConfig = {
  apiKey: string;
  /** Absolute base URL for the Tab API. Required in production. The SDK
   *  doesn't pick a default so a misconfigured deploy fails loudly rather
   *  than silently hitting a placeholder domain. */
  baseUrl: string;
  fetchImpl?: typeof fetch;
};

export class Tab {
  private readonly apiKey: string;
  private readonly baseUrl: string;
  private readonly fetchImpl: typeof fetch;

  public readonly orders: OrdersResource;
  public readonly handles: HandlesResource;
  public readonly webhooks: WebhooksResource;
  public readonly escrow: EscrowResource;
  public readonly subscriptions: SubscriptionsResource;
  // Agent-economy resources — read ERC-8004 manifests + reputation,
  // mint x402 challenges, verify payments. These are the load-bearing
  // primitives for "agent pays agent" flows.
  public readonly agents: AgentsResource;
  public readonly x402: X402Resource;
  // Smart Pay primitives — pay $X to any handle from whatever asset
  // covers it cheapest, aggregate USD balance across all chains, and
  // public spot prices. The unlock for agents that just want to "pay
  // $5 to @alice" without picking a chain or asset.
  public readonly pay: PayResource;
  public readonly balances: BalancesResource;
  public readonly prices: PricesResource;

  constructor(cfg: TabConfig) {
    if (!cfg.apiKey) throw new Error("Tab: apiKey is required");
    if (!cfg.baseUrl) {
      throw new Error("Tab: baseUrl is required (e.g. https://tab.example)");
    }
    this.apiKey = cfg.apiKey;
    this.baseUrl = cfg.baseUrl.replace(/\/$/, "");
    this.fetchImpl = cfg.fetchImpl ?? fetch;
    this.orders = new OrdersResource(this);
    this.handles = new HandlesResource(this);
    this.webhooks = new WebhooksResource(this);
    this.escrow = new EscrowResource(this);
    this.subscriptions = new SubscriptionsResource(this);
    this.agents = new AgentsResource(this);
    this.x402 = new X402Resource(this);
    this.pay = new PayResource(this);
    this.balances = new BalancesResource(this);
    this.prices = new PricesResource(this);
  }

  /** @internal */
  async request<T>(
    method: "GET" | "POST" | "DELETE",
    path: string,
    opts: {
      body?: unknown;
      idempotencyKey?: string;
      auth?: boolean;
      signal?: AbortSignal;
    } = {}
  ): Promise<T> {
    const headers: Record<string, string> = { accept: "application/json" };
    if (opts.auth !== false) headers.authorization = `Bearer ${this.apiKey}`;
    if (opts.body !== undefined) headers["content-type"] = "application/json";
    if (opts.idempotencyKey) headers["idempotency-key"] = opts.idempotencyKey;

    const res = await this.fetchImpl(this.baseUrl + path, {
      method,
      headers,
      body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
      signal: opts.signal,
    });
    const text = await res.text();
    let parsed: unknown = {};
    if (text) {
      try {
        parsed = JSON.parse(text);
      } catch {
        // Non-JSON body (HTML 5xx from a reverse proxy, network captive
        // portal, etc). Surface as a TabApiError so callers don't get a
        // raw SyntaxError out of an unrelated parse.
        throw new TabApiError(res.status, {
          error: {
            code: "non_json_response",
            message: text.slice(0, 200),
          },
        });
      }
    }
    if (!res.ok) {
      throw new TabApiError(res.status, parsed as { error?: TabError });
    }
    return parsed as T;
  }
}

export class OrdersResource {
  constructor(private readonly tab: Tab) {}

  async create(params: CreateOrderParams): Promise<{ order: Order; checkout_url: string }> {
    return this.tab.request("POST", "/api/orders", {
      body: {
        amount: params.amount,
        chain: params.chain,
        recipient: params.recipient.startsWith("@")
          ? params.recipient.slice(1)
          : params.recipient,
        currency: params.currency,
        expires_in: params.expires_in,
        metadata: params.metadata,
      },
      idempotencyKey: params.idempotencyKey,
    });
  }

  async retrieve(id: string, opts: { signal?: AbortSignal } = {}): Promise<{ order: Order }> {
    return this.tab.request("GET", `/api/orders/${id}`, { auth: false, signal: opts.signal });
  }

  async list(): Promise<{ orders: Order[] }> {
    return this.tab.request("GET", "/api/orders");
  }

  async cancel(id: string): Promise<{ order: Order }> {
    return this.tab.request("POST", `/api/orders/${id}`, {
      body: { action: "cancel" },
    });
  }

  /** Poll an order until it reaches a terminal state. Tolerant of transient
   *  network errors (logs them, retries the next tick). Cancellable via
   *  AbortSignal. Honours both the per-call deadline and an external signal. */
  async waitForSettlement(
    id: string,
    opts: { intervalMs?: number; timeoutMs?: number; signal?: AbortSignal } = {}
  ): Promise<Order> {
    const intervalMs = opts.intervalMs ?? 2_000;
    const timeoutMs = opts.timeoutMs ?? 5 * 60_000;
    const deadline = Date.now() + timeoutMs;

    let consecutiveErrors = 0;
    for (;;) {
      if (opts.signal?.aborted) throw new Error(`waitForSettlement aborted for ${id}`);
      if (Date.now() > deadline) {
        throw new Error(`Order ${id} did not settle within ${timeoutMs}ms`);
      }
      try {
        const { order } = await this.retrieve(id, { signal: opts.signal });
        consecutiveErrors = 0;
        if (
          order.status === "completed" ||
          order.status === "expired" ||
          order.status === "cancelled"
        ) {
          return order;
        }
      } catch (e: unknown) {
        // Permanent errors propagate immediately; transient errors (network,
        // 5xx, etc) get a few retries with backoff before giving up.
        if (e instanceof TabApiError && e.status >= 400 && e.status < 500) {
          throw e;
        }
        consecutiveErrors += 1;
        if (consecutiveErrors >= 5) throw e;
      }
      const wait = Math.min(intervalMs * Math.max(1, consecutiveErrors), 10_000);
      await new Promise((resolve, reject) => {
        const t = setTimeout(resolve, wait);
        if (opts.signal) {
          opts.signal.addEventListener(
            "abort",
            () => {
              clearTimeout(t);
              reject(new Error(`waitForSettlement aborted for ${id}`));
            },
            { once: true }
          );
        }
      });
    }
  }
}

export type HandleRecord = {
  handle: string;
  /** 0x-EVM address (always present). */
  address: `0x${string}`;
  /** base58 Solana pubkey (present for accounts created with v1+ wallet). */
  solanaAddress?: string;
};

export type AgentWallet = {
  handle: string;
  address: `0x${string}`;
  solanaAddress: string;
  /** 32-byte hex EVM private key. Same bytes serve as the Ed25519 seed for
   *  the Solana keypair — one wallet, both chains, one secret to protect. */
  privateKey: `0x${string}`;
};

export class HandlesResource {
  constructor(private readonly tab: Tab) {}

  /** Look up an existing handle. Public, no auth. */
  async resolve(handle: string): Promise<{ record: HandleRecord }> {
    const clean = handle.replace(/^@/, "");
    return this.tab.request("GET", `/api/handles/${encodeURIComponent(clean)}`, { auth: false });
  }

  /** Claim a handle for a wallet you already own. The caller is responsible
   *  for signing the canonical claim message — see `createWallet` for the
   *  one-shot helper that generates a fresh wallet, signs, and claims.
   *
   *  Use this when:
   *   - You already have a keypair you want to associate with a handle
   *   - You're integrating with a Wallet-as-a-Service provider that signs
   *     on your behalf */
  async claim(params: {
    handle: string;
    address: `0x${string}`;
    /** Optional base58 Solana address derived from the same private key as
     *  `address`. Tab stores both so a single handle can receive on either
     *  chain. */
    solanaAddress?: string;
    /** Hex-encoded EIP-191 personal_sign over the canonical claim message. */
    signature: `0x${string}`;
    /** Unix-millis timestamp matching the message body. Must be within
     *  ±10 minutes of the server clock. */
    ts: number;
  }): Promise<{ record: HandleRecord }> {
    return this.tab.request("POST", "/api/handles", {
      auth: false, // claim is sig-authenticated, not API-key
      body: params,
    });
  }

  /** Canonical message format the server validates the claim signature
   *  against. Exposed so agents that bring their own signer can reproduce
   *  it byte-for-byte. The exact string MUST match `app/api/handles/route.ts`
   *  in tab-web. */
  static claimMessage(
    handle: string,
    address: string,
    solanaAddress: string | null,
    ts: number
  ): string {
    return [
      `Tab — Claim handle`,
      ``,
      `handle: @${handle.toLowerCase()}`,
      `address: ${address.toLowerCase()}`,
      `solana: ${solanaAddress ?? "none"}`,
      `ts: ${ts}`,
    ].join("\n");
  }
}

/** Create a fresh Tab wallet (EVM + Solana from one seed) and claim a
 *  handle for it. The wallet's private key is returned to the caller —
 *  the SDK does NOT persist it anywhere. Stash it in your secrets manager
 *  (KMS, Vault, env file with restricted perms, etc.) before relying on
 *  this handle for payments.
 *
 *  Optional deps: imports `viem` and `@solana/web3.js` dynamically so this
 *  function only fails at call time if you haven't installed them.
 *
 *  Returns the wallet alongside the server's HandleRecord. Throws on:
 *    - handle taken / reserved / profane (TabApiError)
 *    - signature timestamp drift > 10 min
 *    - network failure
 */
export async function createWallet(
  tab: Tab,
  params: {
    handle: string;
    /** Skip Solana key derivation (saves ~30ms + the @solana/web3.js import).
     *  Default: false — both EVM and Solana addresses are claimed. */
    evmOnly?: boolean;
  }
): Promise<{ wallet: AgentWallet; record: HandleRecord }> {
  const { generatePrivateKey, privateKeyToAccount } = await import("viem/accounts");

  // @solana/web3.js is an optional peer dep so the SDK works EVM-only.
  // Load via the runtime function-call form so TypeScript doesn't try to
  // resolve types at build time. Callers who want Solana addresses must
  // `npm install @solana/web3.js` themselves.
  type SolanaModule = {
    Keypair: { fromSeed(seed: Uint8Array): { publicKey: { toBase58(): string } } };
  };
  const solana: SolanaModule | null = params.evmOnly
    ? null
    : await (Function("return import('@solana/web3.js').catch(() => null)") as () => Promise<SolanaModule | null>)();

  const privateKey = generatePrivateKey();
  const account = privateKeyToAccount(privateKey);

  // Derive Solana from the same 32-byte secret if @solana/web3.js loads.
  let solanaAddress = "";
  if (solana) {
    const seed = hexToBytes(privateKey);
    solanaAddress = solana.Keypair.fromSeed(seed).publicKey.toBase58();
  }

  const ts = Date.now();
  const message = HandlesResource.claimMessage(
    params.handle,
    account.address,
    solanaAddress || null,
    ts
  );
  const signature = await account.signMessage({ message });

  const { record } = await tab.handles.claim({
    handle: params.handle,
    address: account.address,
    solanaAddress: solanaAddress || undefined,
    signature,
    ts,
  });

  return {
    wallet: {
      handle: record.handle,
      address: account.address,
      solanaAddress,
      privateKey,
    },
    record,
  };
}

function hexToBytes(hex: `0x${string}`): Uint8Array {
  const clean = hex.startsWith("0x") ? hex.slice(2) : hex;
  const out = new Uint8Array(clean.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(clean.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

export class WebhooksResource {
  constructor(private readonly tab: Tab) {}

  async list(): Promise<{
    webhooks: Array<{
      id: string;
      url: string;
      events: string[];
      active: boolean;
      createdAt: number;
    }>;
  }> {
    return this.tab.request("GET", "/api/webhooks");
  }

  async create(params: { url: string; events: string[] }): Promise<{
    webhook: {
      id: string;
      url: string;
      events: string[];
      signingSecret: string;
      active: boolean;
      createdAt: number;
    };
  }> {
    return this.tab.request("POST", "/api/webhooks", { body: params });
  }

  async delete(id: string): Promise<{ deleted: boolean }> {
    return this.tab.request("DELETE", `/api/webhooks/${id}`);
  }
}

/* =====================================================================
 *                          Escrow (OpenTab)
 * =====================================================================
 *
 * Agentic use case: an agent receiving asynchronous payments from any
 * source. The agent creates a code-mode OpenTab, hands the resulting
 * share URL to the payer (via Slack/Discord/email/etc), and polls or
 * subscribes to webhooks for settlement.
 *
 * Server side, code-mode escrows are auth-free to claim — the secret in
 * the URL IS the authorization — so the recipient doesn't need a Tab
 * account. This makes them the right primitive for tipping flows, gift
 * cards, and "send to anyone who clicks this link" use cases.
 *
 * The create path requires the agent to own a Tab handle and have an
 * API key bound to it (or hold the session cookie of a Tab user). The
 * SDK assumes API key auth — pass `sessionCookie` to constructor if you
 * really need cookie-based auth (uncommon for agents).
 */

export type EscrowClaimType = "handle" | "code";
export type EscrowStatus =
  | "pending_create"
  | "pending"
  | "claimed"
  | "refunded"
  | "expired";

export type EscrowRecord = {
  id: string;
  onChainId: string;
  senderHandle: string;
  /** EVM address or Solana pubkey of the funder. */
  senderAddress: string;
  /** Empty string for code escrows. */
  handleSlug: string;
  amount: string;
  amountWei: string;
  currency: string;
  chain: PayableChain;
  deadline: number;
  status: EscrowStatus;
  claimType: EscrowClaimType;
  /** keccak256(secret) committed on-chain for code escrows. */
  codeHash?: string;
  createTxHash?: string;
  claimTxHash?: string;
  refundTxHash?: string;
  recipientAddress?: string;
  recipientHandle?: string;
  createdAt: number;
  note?: string;
};

export type CreateEscrowParams = {
  amount: string;
  chain: PayableChain;
  /** When "code", `recipient` is ignored and a share-link is returned.
   *  When "handle", `recipient` must be a Tab handle (with or without @). */
  claimType: EscrowClaimType;
  recipient?: string;
  /** Required for code-mode. keccak256(bytes(secret)) committed on-chain.
   *  Generate the secret client-side; never send it to Tab. */
  codeHash?: `0x${string}`;
  /** Hours until the sender can refund. 1h..2160h (90 days). Default 168 (7d). */
  dueInHours?: number;
  /** Per-recipient comment, visible on the claim page. */
  note?: string;
};

export class EscrowResource {
  constructor(private readonly tab: Tab) {}

  /** Create a new OpenTab. For code-mode, the caller must supply
   *  `codeHash = keccak256(secret)` — the SDK never sees the secret.
   *  After this returns, the caller funds the escrow on-chain (their
   *  wallet signs createEscrow/createEscrowByCode against the returned
   *  router address) and then calls `confirm()` with the tx hash. */
  async create(
    params: CreateEscrowParams
  ): Promise<{
    escrow: EscrowRecord;
    onChainArgs: {
      router: string;
      stable: string;
      handleSlug: string;
      codeHash: string;
      claimType: EscrowClaimType;
      amount: string;
      deadline: number;
      senderNonce: string;
      /** Solana-only. */
      feeRecipient?: string;
      stableDecimals?: number;
    };
  }> {
    return this.tab.request("POST", "/api/escrow", {
      body: {
        claimType: params.claimType,
        handleSlug: params.recipient?.replace(/^@/, "") ?? "",
        codeHash: params.codeHash,
        amount: params.amount,
        chain: params.chain,
        dueInHours: params.dueInHours,
        note: params.note,
      },
    });
  }

  /** Tell Tab that the on-chain create-escrow tx has mined. The server
   *  verifies the EscrowCreated event matches the on-chain id + sender
   *  before flipping the row to "pending". */
  async confirm(
    id: string,
    params: { txHash: string; onChainId: string }
  ): Promise<{ escrow: EscrowRecord }> {
    return this.tab.request("POST", `/api/escrow/${id}`, {
      body: { action: "confirm_create", ...params },
    });
  }

  /** Sponsored claim-by-code: Tab pays the gas, funds go to `recipient`.
   *  Only valid for code-mode escrows. The secret must hash to the
   *  committed codeHash or the contract reverts (server pre-checks). */
  async claimByCode(
    id: string,
    params: { recipient: string; secret: `0x${string}` }
  ): Promise<{ escrow: EscrowRecord; txHash: string }> {
    return this.tab.request("POST", `/api/escrow/${id}`, {
      body: { action: "claim_by_code", ...params },
    });
  }

  /** Handle-mode claim. Only callable as the handle owner. */
  async claim(id: string): Promise<{ escrow: EscrowRecord; txHash: string }> {
    return this.tab.request("POST", `/api/escrow/${id}`, {
      body: { action: "claim" },
    });
  }

  /** Refund after the deadline. Anyone can trigger; funds return to the
   *  original sender. */
  async refund(id: string): Promise<{ escrow: EscrowRecord; txHash: string }> {
    return this.tab.request("POST", `/api/escrow/${id}`, {
      body: { action: "refund" },
    });
  }

  async retrieve(id: string): Promise<{ escrow: EscrowRecord }> {
    return this.tab.request("GET", `/api/escrow/${id}`, { auth: false });
  }

  async list(): Promise<{ escrows: EscrowRecord[] }> {
    return this.tab.request("GET", "/api/escrow");
  }
}

/* =====================================================================
 *                       Subscriptions (recurring)
 * =====================================================================
 *
 * Agentic use case: a SaaS or API service charging an autonomous agent
 * on a recurring schedule. The agent owns a Tab wallet, approves the
 * subscription router as a spender for ~1 year of charges, and lets the
 * cron pull funds without further signatures. Cancel any time.
 */

export type SubscriptionPlan = {
  id: string;
  planId: string;
  creatorHandle: string;
  creatorAddress: string;
  amount: string;
  amountWei: string;
  currency: string;
  chain: PayableChain;
  periodSeconds: number;
  active: boolean;
  createdAt: number;
};

export type Subscription = {
  id: string;
  planId: string;
  subscriberHandle: string;
  subscriberAddress: string;
  active: boolean;
  startedAt: number;
  lastChargedAt?: number;
  chargesPaid: number;
  cancelledAt?: number;
};

export class SubscriptionsResource {
  constructor(private readonly tab: Tab) {}

  async createPlan(params: {
    planId: string;
    amount: string;
    chain: PayableChain;
    periodSeconds: number;
  }): Promise<{ plan: SubscriptionPlan }> {
    return this.tab.request("POST", "/api/subscriptions/plans", {
      body: params,
    });
  }

  async listPlans(): Promise<{ plans: SubscriptionPlan[] }> {
    return this.tab.request("GET", "/api/subscriptions/plans");
  }

  async deactivatePlan(id: string): Promise<{ plan: SubscriptionPlan }> {
    return this.tab.request("POST", `/api/subscriptions/plans/${id}`, {
      body: { action: "deactivate" },
    });
  }

  async subscribe(planId: string): Promise<{ subscription: Subscription }> {
    return this.tab.request("POST", `/api/subscriptions/subs`, {
      body: { planId },
    });
  }

  async cancel(subscriptionId: string): Promise<{ subscription: Subscription }> {
    return this.tab.request("POST", `/api/subscriptions/subs/${subscriptionId}`, {
      body: { action: "cancel" },
    });
  }

  async listSubscriptions(): Promise<{ subscriptions: Subscription[] }> {
    return this.tab.request("GET", `/api/subscriptions/subs`);
  }
}

// Convenience helper: pay a handle directly (creates order; settlement is
// up to the buyer or a separately-configured relayer).
export async function payHandle(
  tab: Tab,
  params: { recipient: string; amount: string; chain: SupportedChain; metadata?: Record<string, unknown> }
): Promise<{ order: Order; checkout_url: string }> {
  return tab.orders.create({
    amount: params.amount,
    chain: params.chain,
    recipient: params.recipient,
    metadata: params.metadata,
  });
}

/* ============================================================
 *  ERC-8004 agents resource
 * ============================================================
 *  Read-only surface that wraps the canonical agent registry
 *  endpoints. Use this when an LLM agent needs to "look up another
 *  agent before paying them" — the Tab handle resolution gives
 *  the wallet; the manifest gives the published service surface;
 *  the reputation gives the on-chain feedback summary. */

export type AgentManifest = {
  schemaVersion: string;
  name: string;
  description: string;
  homepage: string;
  paymentEndpoint: string;
  x402Endpoint: string;
  image: string;
  services: string[];
  reputationEndpoint: string;
};

export type AgentRegistration = {
  handle: string;
  chain: string;
  agentId: string;
  agentUri: string;
  owner: string;
  txHash: string;
  registeredAt: number;
  manifestUrl: string;
};

export class AgentsResource {
  constructor(private readonly tab: Tab) {}

  /** Fetch the AgentManifest JSON for a Tab handle. Public; same data
   *  every ERC-8004 indexer pulls from the on-chain agentURI. */
  async manifest(handle: string): Promise<AgentManifest> {
    const clean = handle.replace(/^@/, "");
    return this.tab.request("GET", `/api/agent-registry/manifest/${encodeURIComponent(clean)}`, { auth: false });
  }

  /** Reputation summary + recent feedback. Aggregates on-chain
   *  Reputation Registry reads server-side so the caller doesn't
   *  need a viem client. */
  async reputation(handle: string): Promise<{
    handle: string;
    registered: boolean;
    summary: unknown;
    feedback: unknown[];
  }> {
    const clean = handle.replace(/^@/, "");
    return this.tab.request("GET", `/api/agent-registry/reputation/${encodeURIComponent(clean)}`, { auth: false });
  }

  /** Crawl the public directory of every Tab agent published to
   *  ERC-8004. Cursor-paginated. */
  async list(opts: { cursor?: number; limit?: number } = {}): Promise<{
    registrations: AgentRegistration[];
    nextCursor: number | null;
  }> {
    const params: string[] = [];
    if (opts.limit) params.push(`limit=${opts.limit}`);
    if (opts.cursor != null) params.push(`cursor=${opts.cursor}`);
    const qs = params.length ? `?${params.join("&")}` : "";
    return this.tab.request("GET", `/api/agent-registry/public${qs}`, { auth: false });
  }

  /** Resolve a Tab @handle to its ERC-8004 agentId. Handles aren't
   *  on-chain (only agentIds are), so this hop hits Tab's registry
   *  index. Pair with the *OnChain helpers below to verify everything
   *  else directly against the contract. */
  async resolveAgentId(
    handle: string,
    opts: { chain?: "base" | "bsc" | "celo" } = {}
  ): Promise<{ agentId: string; chain: string; owner: string }> {
    const clean = handle.replace(/^@/, "");
    const qs = opts.chain ? `?chain=${encodeURIComponent(opts.chain)}` : "";
    return this.tab.request(
      "GET",
      `/api/agent-registry/resolve/${encodeURIComponent(clean)}${qs}`,
      { auth: false }
    );
  }

  /** Read an agent's manifest directly from the ERC-8004 Identity
   *  Registry — no Tab backend involved. Fetches the tokenURI from the
   *  registry on `chain` (default "base"), then GETs the JSON it points
   *  to. Use this when you need to verify what an agent actually
   *  published on-chain, not what Tab's cache returned. */
  async manifestOnChain(
    agentId: bigint | string,
    opts: OnChainReadOptions = {}
  ): Promise<AgentManifest> {
    const client = makeReadClient(opts);
    const id = typeof agentId === "string" ? BigInt(agentId) : agentId;
    const uri = (await client.readContract({
      address: ERC8004_IDENTITY_REGISTRY,
      abi: IDENTITY_REGISTRY_ABI,
      functionName: "tokenURI",
      args: [id],
    })) as string;
    const res = await fetch(uri);
    if (!res.ok) {
      throw new Error(
        `manifestOnChain: tokenURI fetch failed (${res.status}) for ${uri}`
      );
    }
    return (await res.json()) as AgentManifest;
  }

  /** Read the owning wallet of an agent directly from the registry.
   *  This is the address allowed to update the agent's tokenURI — the
   *  signer of any "this agent says X" claim should be this address. */
  async ownerOnChain(
    agentId: bigint | string,
    opts: OnChainReadOptions = {}
  ): Promise<`0x${string}`> {
    const client = makeReadClient(opts);
    const id = typeof agentId === "string" ? BigInt(agentId) : agentId;
    return (await client.readContract({
      address: ERC8004_IDENTITY_REGISTRY,
      abi: IDENTITY_REGISTRY_ABI,
      functionName: "ownerOf",
      args: [id],
    })) as `0x${string}`;
  }

  /** Read the agent's wallet (the address that receives payments) from
   *  the registry. May or may not equal `ownerOnChain` depending on the
   *  agent's setup. */
  async walletOnChain(
    agentId: bigint | string,
    opts: OnChainReadOptions = {}
  ): Promise<`0x${string}`> {
    const client = makeReadClient(opts);
    const id = typeof agentId === "string" ? BigInt(agentId) : agentId;
    return (await client.readContract({
      address: ERC8004_IDENTITY_REGISTRY,
      abi: IDENTITY_REGISTRY_ABI,
      functionName: "getAgentWallet",
      args: [id],
    })) as `0x${string}`;
  }

  /** Read the on-chain reputation summary for an agent directly from
   *  the ERC-8004 Reputation Registry. Returns the feedback count and
   *  the aggregated summary value (normalised via the registry's
   *  (value, decimals) pair encoding). */
  async reputationOnChain(
    agentId: bigint | string,
    opts: OnChainReadOptions & {
      /** Filter by a specific tag1 (e.g. "payment", "validation"). */
      tag1?: string;
      /** Filter by a specific tag2. */
      tag2?: string;
    } = {}
  ): Promise<{
    count: number;
    summaryValue: number;
    rawValue: bigint;
    decimals: number;
    clients: `0x${string}`[];
  }> {
    const client = makeReadClient(opts);
    const id = typeof agentId === "string" ? BigInt(agentId) : agentId;
    const tag1 = opts.tag1 ?? "";
    const tag2 = opts.tag2 ?? "";
    const [clients, summary] = await Promise.all([
      client.readContract({
        address: ERC8004_REPUTATION_REGISTRY,
        abi: REPUTATION_REGISTRY_ABI,
        functionName: "getClients",
        args: [id],
      }) as Promise<readonly `0x${string}`[]>,
      client.readContract({
        address: ERC8004_REPUTATION_REGISTRY,
        abi: REPUTATION_REGISTRY_ABI,
        functionName: "getSummary",
        args: [id, [], tag1, tag2],
      }) as Promise<readonly [bigint, bigint, number]>,
    ]);
    const [count, summaryValue, decimals] = summary;
    return {
      count: Number(count),
      summaryValue: feedbackValueToNumber(summaryValue, decimals),
      rawValue: summaryValue,
      decimals,
      clients: [...clients],
    };
  }
}

/* ============================================================
 *  x402 — pay-per-call for AI agents
 * ============================================================
 *  Use this from an agent that wants to GATE its own HTTP surface
 *  behind a payment. `charge` mints a spec-compliant 402 response
 *  the caller forwards verbatim. `verify` confirms the caller
 *  actually paid before releasing the protected resource. */

export type X402ChargeParams = {
  amount: string;
  chain: SupportedChain;
  resource: string;
  description: string;
};

export type X402Challenge = {
  x402Version: number;
  error: string;
  accepts: Array<Record<string, unknown>>;
  extra?: { tab?: { orderId?: string; checkoutUrl?: string } };
};

export type X402VerifyResult = {
  paid: boolean;
  status?: string;
  txHash?: string;
  chain?: string;
};

export class X402Resource {
  constructor(private readonly tab: Tab) {}

  /** Mint a 402 challenge for a protected resource. Requires the
   *  Tab API key configured on the Tab client (write scope). */
  async charge(params: X402ChargeParams): Promise<X402Challenge> {
    return this.tab.request("POST", "/api/x402/charge", { body: params });
  }

  /** Check whether the caller has paid a previously-minted order.
   *  Public — orderId is the secret (unguessable nanoid). */
  async verify(orderId: string): Promise<X402VerifyResult> {
    return this.tab.request(
      "GET",
      `/api/x402/verify?orderId=${encodeURIComponent(orderId)}`,
      { auth: false }
    );
  }
}

/* ---------- Smart Pay ---------- */

export type SmartPayParams = {
  /** USD amount as a decimal string ("4.20"). */
  amountUsd: string;
  /** EVM 0x address OR @handle the caller has already resolved. The
   *  endpoint also accepts a handle — pass `recipientHandle` instead
   *  if you don't have the address yet. */
  recipient: string;
  /** Settle USDC on this chain. Defaults to "base". */
  recipientChain?: "base" | "bsc" | "ink" | "celo";
  /** Max acceptable slippage as a fraction (0.01 = 1%). Default 0.01. */
  slippageCap?: number;
};

export type SmartPayResult =
  | {
      ok: true;
      kind: "direct";
      txHash: string;
      route: {
        kind: "direct";
        chain: string;
        expectedOutUsd: number;
      };
    }
  | {
      ok: true;
      kind: "relay";
      pullTxHash: string;
      sourceTxHash: string;
      sourceChain: string;
      destinationChain: string;
      expectedOutUsd: number;
    };

export class PayResource {
  constructor(private readonly tab: Tab) {}

  /** Pay an arbitrary USD amount to a Tab handle. The server picks
   *  the cheapest source asset across all your chains, executes
   *  gaslessly via your 7702 delegation, and lands USDC at the
   *  recipient.
   *
   *  Direct path (USDC already on dest chain): single tx, ~3s.
   *  Cross-asset path (e.g. ETH → USDC via relay.link): pull-then-
   *  swap, ~20-30s. Server-side simulation rejects the route if
   *  expected output is below `amountUsd × (1 - slippageCap)`. */
  async smart(params: SmartPayParams): Promise<SmartPayResult> {
    return this.tab.request("POST", "/api/pay/smart", { body: params });
  }
}

/* ---------- Balance aggregation ---------- */

export type BalanceRow = {
  chain: string;
  symbol: string;
  balance: string;
  usd: number;
  isStable: boolean;
};

export type TotalBalanceResult = {
  totalUsd: number;
  breakdown: BalanceRow[];
  fetchedAt: number;
};

export class BalancesResource {
  constructor(private readonly tab: Tab) {}

  /** Aggregated USD balance across every active EVM chain + Solana,
   *  with per-row breakdown (stable + native). Used by agents to
   *  decide whether they can fund a payment before calling pay.smart. */
  async total(opts: {
    address: string;
    solanaAddress?: string;
  }): Promise<TotalBalanceResult> {
    const params = new URLSearchParams({ address: opts.address });
    if (opts.solanaAddress) params.set("solanaAddress", opts.solanaAddress);
    return this.tab.request("GET", `/api/balance/total?${params}`);
  }
}

/* ---------- Spot prices ---------- */

export type PricesResult = {
  prices: Record<string, number>;
  fetchedAt: number;
};

export class PricesResource {
  constructor(private readonly tab: Tab) {}

  /** USD spot prices for the assets Tab supports (ETH, BNB, CELO,
   *  SOL, USDC). Backed by a multi-source feed (CoinGecko → Binance
   *  → Coinbase) with 60s cache + CDN edge cache. Public — no API
   *  key needed, safe to call freely. */
  async list(symbols?: Array<"ETH" | "BNB" | "CELO" | "SOL" | "USDC">): Promise<PricesResult> {
    const path = symbols && symbols.length > 0
      ? `/api/prices?symbols=${symbols.join(",")}`
      : "/api/prices";
    return this.tab.request("GET", path, { auth: false });
  }
}
