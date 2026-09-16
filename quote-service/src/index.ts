export type Venue = "0x" | "aerodrome";

export type QuoteRequest = {
  chainId: number;
  sellToken: string;
  buyToken: string;
  sellAmount: bigint;
  taker: string;
};

export type SwapPlan = {
  router: string;
  tokenIn: string;
  tokenOut: string;
  amountIn: bigint;
  minOut: bigint;
  value: bigint;
  data: `0x${string}`;
};

type ZeroExResponse = {
  buyAmount?: string;
  minBuyAmount?: string;
  allowanceTarget?: string;
  transaction?: {to?: string; data?: `0x${string}`; value?: string};
};

function address(value: string, field: string): string {
  if (!/^0x[0-9a-fA-F]{40}$/.test(value)) throw new Error(`invalid ${field}`);
  return value;
}

/**
 * Read-only 0x quote client. It does not sign, custody funds, or return secrets.
 * The caller must wrap the returned transaction data in the fixed-target adapter.
 */
export async function quoteZeroEx(
  endpoint: string,
  apiKey: string | undefined,
  request: QuoteRequest,
  slippageBps: bigint,
): Promise<{buyAmount: bigint; minBuyAmount: bigint; allowanceTarget: string; transaction: NonNullable<ZeroExResponse["transaction"]>}> {
  if (slippageBps > 10_000n) throw new Error("slippage exceeds 100%");
  const sellToken = address(request.sellToken, "sellToken");
  const buyToken = address(request.buyToken, "buyToken");
  const taker = address(request.taker, "taker");
  const url = new URL(endpoint);
  url.searchParams.set("chainId", request.chainId.toString());
  url.searchParams.set("sellToken", sellToken);
  url.searchParams.set("buyToken", buyToken);
  url.searchParams.set("sellAmount", request.sellAmount.toString());
  url.searchParams.set("taker", taker);
  url.searchParams.set("slippageBps", slippageBps.toString());

  const response = await fetch(url, {
    headers: apiKey ? { "0x-api-key": apiKey, "0x-version": "v2" } : {"0x-version": "v2"},
  });
  if (!response.ok) throw new Error(`0x quote failed: ${response.status}`);
  const body = (await response.json()) as ZeroExResponse;
  if (!body.buyAmount || !body.transaction?.to || !body.transaction.data) {
    throw new Error("0x response omitted executable route data");
  }
  if (body.transaction.value === undefined) throw new Error("0x response omitted transaction value");
  const buyAmount = BigInt(body.buyAmount);
  const minBuyAmount = body.minBuyAmount ? BigInt(body.minBuyAmount) : buyAmount * (10_000n - slippageBps) / 10_000n;
  return {
    buyAmount,
    minBuyAmount,
    allowanceTarget: address(body.allowanceTarget ?? body.transaction.to, "allowanceTarget"),
    transaction: {
      to: address(body.transaction.to, "transaction.to"),
      data: body.transaction.data,
      value: body.transaction.value,
    },
  };
}

export function buildPlan(
  venueAdapter: string,
  tokenIn: string,
  tokenOut: string,
  amountIn: bigint,
  minOut: bigint,
  value: bigint,
  adapterCalldata: `0x${string}`,
): SwapPlan {
  address(venueAdapter, "venueAdapter");
  address(tokenIn, "tokenIn");
  address(tokenOut, "tokenOut");
  if (amountIn <= 0n || minOut <= 0n) throw new Error("route amounts must be positive");
  return {router: venueAdapter, tokenIn, tokenOut, amountIn, minOut, value, data: adapterCalldata};
}
