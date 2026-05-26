# Tab

Stablecoin payments by `@handle`. Non-custodial, gasless, multi-chain.

[thetab.bar](https://thetab.bar) · [Docs](https://thetab.bar/docs) · [Agents](https://thetab.bar/docs/agents/base-mcp)

This repository is the public surface of Tab: smart contracts, SDK, and MCP server. The product (dashboard, API, bots) is private.

## What's in here

| Path | What |
|---|---|
| [`sdk/`](./sdk) | `@thetab/agent-sdk` — TypeScript SDK with OpenAI/Anthropic tool schemas + MCP server for Claude Desktop / Cursor |
| [`contracts/evm/`](./contracts/evm) | Solidity routers deployed on Base, BSC, Celo, Ink. Same address every chain. |
| [`contracts/solana/`](./contracts/solana) | Anchor programs deployed on Solana mainnet-beta. |

## Quick links

- **Pay by handle:** [`thetab.bar/pay/handle/<handle>`](https://thetab.bar)
- **Dashboard:** [`thetab.bar/dashboard`](https://thetab.bar/dashboard)
- **REST API:** [`thetab.bar/docs/api`](https://thetab.bar/docs/api)
- **MCP install:** see [`sdk/README.md`](./sdk/README.md)

## License

MIT. See [LICENSE](./LICENSE).
