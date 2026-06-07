# Tab EVM contracts

Foundry project. Six router contracts per chain (1 stable router each for TabRouter + TabBotRouter, plus a Business 1% and Personal 0% variant of TabEscrowRouter and TabSubscriptionRouter).

TabRouter and TabBotRouter share addresses across Base, BSC, Celo, and Ink (deterministic CREATE from the same fresh deployer wallet). TabEscrowRouter and TabSubscriptionRouter diverge: Base runs the original v2 deployment; BSC/Celo/Ink were redeployed to pin the stable to USDC.

## Deployed addresses

| Contract | Base | BSC / Celo / Ink |
|---|---|---|
| TabRouter | `0xB6e80fD7cd31429d4016FD644d877B799978428B` | (same) |
| TabBotRouter | `0xD9663b9a8C097D882bCbE69e811D500f7ad67Bcf` | (same) |
| TabEscrowRouter — Business 1% | `0xf25c8A76849D280A406c55EDF1ffb8d9d4cdF5d8` | `0x9e01dd09d3c4ddf8a7b6667edb9b71218b94ea6d` |
| TabEscrowRouter — Personal 0% | `0x0daf92a08c3952864869ab69cc6ec3d2e27d8966` | `0x49cab0d12A33FB2fd89Deb43569d38518becBA2C` |
| TabSubscriptionRouter — Business 1% | `0xFCB05c971A31127fEf2C470725B9952bB1fc55A6` | `0x650e324253cf75c068fb0a16e53a30c681463e7b` |
| TabSubscriptionRouter — Personal 0% | `0x8CE016282f11c699BA46b860fA3585bF00e5481d` | `0xd847314f382a41310bfcc2d1300a767129b3cd79` |

## Verify on explorers

- Base: [basescan.org](https://basescan.org/address/0xB6e80fD7cd31429d4016FD644d877B799978428B)
- BSC: [bscscan.com](https://bscscan.com/address/0xB6e80fD7cd31429d4016FD644d877B799978428B)
- Celo: [celoscan.io](https://celoscan.io/address/0xB6e80fD7cd31429d4016FD644d877B799978428B)
- Ink: [explorer.inkonchain.com](https://explorer.inkonchain.com/address/0xB6e80fD7cd31429d4016FD644d877B799978428B)

Source matches `src/`. Anyone can verify by running:

```bash
forge build
# compare the bytecode in out/<Contract>.sol/<Contract>.json against
# the deployed bytecode on the explorer
```

## What each contract does

- **TabRouter** — merchant flows (`/pay` checkouts, `/api/orders`). 1% platform fee.
- **TabBotRouter** — bot-relayed P2P tips. 0% fee. Used by the Telegram + Discord bots.
- **TabEscrowRouter** — share-link escrow (OpenTab) + handle-mode claims.
- **TabSubscriptionRouter** — recurring billing plans + per-subscriber charges.

## Build

```bash
forge install foundry-rs/forge-std openzeppelin/openzeppelin-contracts
forge build
forge test
```

## Deploy

See `script/` for deploy scripts. All scripts read keys from environment variables — never hardcode.

```bash
export DEPLOYER_PRIVATE_KEY=0x...    # use a FRESH wallet
export BASE_RPC=https://mainnet.base.org
./script/deploy-v2.sh base --broadcast
```

Verification keys (optional):

```bash
export BASESCAN_API_KEY=...
export BSCSCAN_API_KEY=...
export CELOSCAN_API_KEY=...
export INK_BLOCKSCOUT_API_KEY=...
```
