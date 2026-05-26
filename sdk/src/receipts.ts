// Signed payment receipts.
//
// The merchant's wallet signs an EIP-712 typed-data Receipt after a payment
// settles. Verification proves the JSON wasn't tampered with AND that it was
// signed by the address you expected.
//
// IMPORTANT: verifyReceipt requires an `expectedSigner` (the merchant's
// known wallet address — resolve via tab.handles.resolve() if you only have
// the handle). A self-attesting receipt where signer == message.recipientAddress
// is *trivially* satisfiable by anyone with any keypair and proves nothing
// about who actually controls the handle.
//
// The domain pins chain (chainId derived from message.chain) so a receipt
// for `base` cannot be replayed as a receipt for `optimism` with the same
// orderId.

import { verifyTypedData, type Address, type Hex } from "viem";

// Mirror of the server's RECEIPT_TYPES at
// tab-web/app/api/orders/[id]/receipt/route.ts. Keep in sync.
export const RECEIPT_TYPES = {
  Receipt: [
    { name: "orderId", type: "string" },
    { name: "amount", type: "string" },
    { name: "currency", type: "string" },
    { name: "chain", type: "string" },
    { name: "recipientHandle", type: "string" },
    { name: "recipientAddress", type: "address" },
    { name: "payerAddress", type: "address" },
    { name: "txHash", type: "string" },
    { name: "issuedAt", type: "uint256" },
  ],
} as const;

const CHAIN_IDS: Record<string, number> = {
  base: 8453,
  "base-sepolia": 84532,
  bsc: 56,
  "bsc-testnet": 97,
  ink: 57073,
  "ink-sepolia": 763373,
  celo: 42220,
  "celo-alfajores": 44787,
  anvil: 31337,
};

export type ReceiptMessage = {
  orderId: string;
  amount: string;
  currency: string;
  chain: string;
  recipientHandle: string;
  recipientAddress: Address;
  payerAddress: Address;
  txHash: string;
  issuedAt: bigint;
};

export type ReceiptDomain = {
  name: "Tab Receipt";
  version: "1";
  chainId: number;
};

export function receiptDomain(chain: string): ReceiptDomain {
  const chainId = CHAIN_IDS[chain];
  if (!chainId) throw new Error(`Unknown chain for receipt domain: ${chain}`);
  return { name: "Tab Receipt", version: "1", chainId };
}

export type SignedReceipt = {
  version: "1";
  message: {
    orderId: string;
    amount: string;
    currency: string;
    chain: string;
    recipientHandle: string;
    recipientAddress: Address;
    payerAddress: Address;
    txHash: string;
    issuedAt: string; // bigint serialised as decimal string for JSON safety
  };
  domain: ReceiptDomain;
  signature: Hex;
  /** The merchant address that signed. Verified against `expectedSigner`. */
  signer: Address;
};

const ZERO_ADDRESS: Address = "0x0000000000000000000000000000000000000000";

/** Verify a downloaded receipt JSON.
 *
 *  `expectedSigner` is mandatory and is the wallet address you independently
 *  know belongs to the merchant — usually obtained from
 *  `tab.handles.resolve(handle).record.address`.
 *
 *  Returns false on any of: bad signature, signer mismatch, domain mismatch,
 *  zero-address payer, malformed message.
 */
export async function verifyReceipt(
  receipt: SignedReceipt,
  expectedSigner: Address
): Promise<boolean> {
  if (!expectedSigner || expectedSigner === ZERO_ADDRESS) return false;
  if (receipt.message.payerAddress === ZERO_ADDRESS) return false;
  if (receipt.message.recipientAddress === ZERO_ADDRESS) return false;
  // Domain must be the canonical one for the receipt's claimed chain.
  let expectedDomain: ReceiptDomain;
  try {
    expectedDomain = receiptDomain(receipt.message.chain);
  } catch {
    return false;
  }
  if (
    receipt.domain.name !== expectedDomain.name ||
    receipt.domain.version !== expectedDomain.version ||
    receipt.domain.chainId !== expectedDomain.chainId
  ) {
    return false;
  }
  if (receipt.signer.toLowerCase() !== expectedSigner.toLowerCase()) {
    return false;
  }

  const message: ReceiptMessage = {
    ...receipt.message,
    issuedAt: BigInt(receipt.message.issuedAt),
  };
  try {
    return await verifyTypedData({
      address: expectedSigner,
      domain: receipt.domain,
      types: RECEIPT_TYPES,
      primaryType: "Receipt",
      message,
      signature: receipt.signature,
    });
  } catch {
    return false;
  }
}

/** Build the EIP-712 envelope for signing. The caller signs this with their
 *  wallet (e.g. viem's `signTypedData` or a browser wallet). */
export function buildReceiptEnvelope(message: ReceiptMessage) {
  return {
    domain: receiptDomain(message.chain),
    types: RECEIPT_TYPES,
    primaryType: "Receipt" as const,
    message,
  };
}
