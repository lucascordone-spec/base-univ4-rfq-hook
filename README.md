# Base Uniswap v4 Zero-Slippage RFQ Hook + AI Agent MCP Server

**Live on Base Mainnet (`Chain ID: 8453`)** — Zero-TVL Institutional RFQ Hook (`0xd72CD1d46bA05479583fbB561B558f133BA98088`) on Uniswap v4 `PoolManager` (`0x498581fF718922c3f8e6A244956aF099B2652b2b`).

- **Zero Price Impact (0% AMM Curve Slippage):** Flat Chainlink On-Chain Oracle pricing (`-0.30%` fixed spread) backed by **$3.25B+ Morpho Blue 0% fee flash liquidity** and **KyberSwap PMMs**.
- **21 Initialized Uniswap v4 Pools on Base Mainnet:** All combinations of `USDC`, `WETH`, `cbBTC`, `cbETH`, `wstETH`, `AERO`, and `EURC` (`fee: 0`, `tickSpacing: 60`).
- **Sourcify Full Match Verified:** [0xd72CD1d46bA05479583fbB561B558f133BA98088](https://repo.sourcify.dev/contracts/full_match/8453/0xd72CD1d46bA05479583fbB561B558f133BA98088/)

## Live Endpoints for Autonomous AI Agents (MCP / A2A / x402) & Aggregators

- **MCP Server (JSON-RPC 2.0):** `https://courage-matches-omaha-commissions.trycloudflare.com/mcp`
- **One-Step Swap Builder (`/swap`):** `https://courage-matches-omaha-commissions.trycloudflare.com/swap?tokenIn=USDC&tokenOut=WETH&amountIn=10000`
- **LLMs Discovery (`/llms.txt`):** `https://courage-matches-omaha-commissions.trycloudflare.com/llms.txt`
- **A2A Agent Card (`/.well-known/agent.json`):** `https://courage-matches-omaha-commissions.trycloudflare.com/.well-known/agent.json`
- **x402 Manifest (`/.well-known/x402`):** `https://courage-matches-omaha-commissions.trycloudflare.com/.well-known/x402`
- **OpenAPI 3.1 Spec (`/openapi.json`):** `https://courage-matches-omaha-commissions.trycloudflare.com/openapi.json`
