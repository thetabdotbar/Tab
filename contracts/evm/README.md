# Tab EVM contracts

Foundry project. Four router contracts deployed at the **same address** on Base, BSC, Celo, and Ink via deterministic deployment.

## Deployed addresses

| Contract | Address (all chains) |
|---|---|
| TabRouter | `0xB6e80fD7cd31429d4016FD644d877B799978428B` |
| TabBotRouter | `0xD9663b9a8C097D882bCbE69e811D500f7ad67Bcf` |
| TabEscrowRouter | `0x75e698Eb803a8Cc6D6e2b78d7d269F5Fd117cCbd` |
| TabSubscriptionRouter | `0xd609c8CC0D3DEEcce68ccAb7F7e6eff0a830Db5E` |

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
