/**
 * ParaSwap / Velora DEX Adapter (`VeloraDEX/paraswap-dex-lib`) & 0x Custom Hook Adapter
 * -------------------------------------------------------------------------------------
 * Protocol: BaseSwapper UniswapV4RFQHook (Base Mainnet - Chain ID 8453)
 * Hook Address: 0xd72CD1d46bA05479583fbB561B558f133BA98088
 * PoolManager:  0x498581fF718922c3f8e6A244956aF099B2652b2b
 * Sourcify Verified: https://repo.sourcify.dev/contracts/full_match/8453/0xd72CD1d46bA05479583fbB561B558f133BA98088/
 *
 * How it works:
 * 1. Off-chain pricing: Queries `/quote` (or computes deterministic Chainlink price - 30 bps)
 *    with 0% size-dependent price impact up to Morpho Blue's $3.25B+ Base flash liquidity.
 * 2. Swap calldata build: Queries `/hookdata` (or `/swap`) to obtain the ABI-encoded
 *    `RFQQuote` + ECDSA signature (`hookData`) and passes it into Uniswap v4 `PoolManager.swap(key, params, hookData)`.
 */

export interface Address {
  toString(): string;
}

export interface Univ4RFQPoolKey {
  currency0: string;
  currency1: string;
  fee: number;
  tickSpacing: number;
  hooks: string;
}

export interface Univ4RFQSwapParams {
  zeroForOne: boolean;
  amountSpecified: string; // Negative for exactInput in Uniswap v4
  sqrtPriceLimitX96: string;
}

export interface Univ4RFQSwapPayload {
  poolManager: string;
  poolKey: Univ4RFQPoolKey;
  swapParams: Univ4RFQSwapParams;
  hookData: string;
  expectedAmountOut: string;
  minAmountOut: string;
  deadline: number;
}

export const BASE_UNIV4_RFQ_CONFIG = {
  chainId: 8453,
  hookAddress: '0xd72CD1d46bA05479583fbB561B558f133BA98088',
  poolManager: '0x498581fF718922c3f8e6A244956aF099B2652b2b',
  morphoBlue: '0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb',
  fee: 0,
  tickSpacing: 60,
  endpoint:
    process.env.UNIV4_RFQ_API_URL ||
    'https://courage-matches-omaha-commissions.trycloudflare.com',
  supportedTokens: {
    USDC: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
    WETH: '0x4200000000000000000000000000000000000006',
    cbBTC: '0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf',
    cbETH: '0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22',
    wstETH: '0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452',
    AERO: '0x940181a94A35A4569E4529A3CDfB74e38FD98631',
    EURC: '0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42',
  },
} as const;

export class BaseUniv4RFQAdapter {
  private readonly apiBaseUrl: string;

  constructor(apiBaseUrl: string = BASE_UNIV4_RFQ_CONFIG.endpoint) {
    this.apiBaseUrl = apiBaseUrl.replace(/\/$/, '');
  }

  /**
   * Returns deterministic PoolKey for any pair of supported tokens on Base Mainnet (8453).
   */
  public getPoolKey(tokenA: string, tokenB: string): Univ4RFQPoolKey {
    const [currency0, currency1] =
      tokenA.toLowerCase() < tokenB.toLowerCase()
        ? [tokenA, tokenB]
        : [tokenB, tokenA];

    return {
      currency0,
      currency1,
      fee: BASE_UNIV4_RFQ_CONFIG.fee,
      tickSpacing: BASE_UNIV4_RFQ_CONFIG.tickSpacing,
      hooks: BASE_UNIV4_RFQ_CONFIG.hookAddress,
    };
  }

  /**
   * Fetches a firm zero-slippage quote from the Filler API (Chainlink Oracle - 30 bps).
   */
  public async getFirmQuote(params: {
    tokenIn: string;
    tokenOut: string;
    amountIn: string;
    isWei?: boolean;
  }): Promise<{
    quoteId: string;
    amountInWei: string;
    promisedOutWei: string;
    promisedOutHuman: number;
    feeBps: number;
    deadline: number;
  }> {
    const query = new URLSearchParams({
      tokenIn: params.tokenIn,
      tokenOut: params.tokenOut,
      amountIn: params.amountIn,
      isWei: String(params.isWei ?? true),
    });

    const response = await fetch(`${this.apiBaseUrl}/quote?${query.toString()}`);
    if (!response.ok) {
      throw new Error(`Univ4RFQ /quote failed with HTTP ${response.status}`);
    }
    const data = await response.json();
    if (data.error) {
      throw new Error(`Univ4RFQ /quote error: ${data.error}`);
    }

    return {
      quoteId: data.quoteId,
      amountInWei: data.amountInWei,
      promisedOutWei: data.promisedOutWei,
      promisedOutHuman: data.promisedOutHuman,
      feeBps: data.feeBps,
      deadline: data.deadline,
    };
  }

  /**
   * One-step builder for Aggregators & Solvers: returns `PoolKey`, `SwapParams`, and signed `hookData`
   * ready to pass into Uniswap v4 `PoolManager.swap(poolKey, swapParams, hookData)`.
   */
  public async buildSwapTransactionParams(params: {
    tokenIn: string;
    tokenOut: string;
    amountIn: string;
    isWei?: boolean;
  }): Promise<Univ4RFQSwapPayload> {
    const query = new URLSearchParams({
      tokenIn: params.tokenIn,
      tokenOut: params.tokenOut,
      amountIn: params.amountIn,
      isWei: String(params.isWei ?? true),
    });

    const response = await fetch(`${this.apiBaseUrl}/swap?${query.toString()}`);
    if (!response.ok) {
      throw new Error(`Univ4RFQ /swap failed with HTTP ${response.status}`);
    }
    const data = await response.json();
    if (data.error) {
      throw new Error(`Univ4RFQ /swap error: ${data.error}`);
    }

    return {
      poolManager: data.uniswapV4Execution.poolManager,
      poolKey: data.uniswapV4Execution.poolKey,
      swapParams: data.uniswapV4Execution.swapParams,
      hookData: data.uniswapV4Execution.hookData,
      expectedAmountOut: data.promisedOutWei,
      minAmountOut: data.promisedOutWei,
      deadline: data.deadline,
    };
  }
}
