import http from "node:http";

const port = Number(process.env.PORT ?? 8787);
const endpoint = process.env.ZERO_EX_QUOTE_URL ?? "https://api.0x.org/swap/allowance-holder/quote";
const apiKey = process.env.ZERO_EX_API_KEY;
const chainId = process.env.CHAIN_ID ?? "8453";

function json(res, status, body) {
  res.writeHead(status, {
    "content-type": "application/json",
    "access-control-allow-origin": "*",
  });
  res.end(JSON.stringify(body));
}

function address(value, field) {
  if (typeof value !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(value)) {
    throw new Error(`invalid ${field}`);
  }
  return value;
}

async function readBody(req) {
  let body = "";
  for await (const chunk of req) body += chunk;
  if (body.length > 32_768) throw new Error("request too large");
  return JSON.parse(body || "{}");
}

async function quote(input) {
  const sellToken = address(input.sellToken, "sellToken");
  const buyToken = address(input.buyToken, "buyToken");
  const taker = address(input.taker, "taker");
  const sellAmount = BigInt(input.sellAmount);
  const slippageBps = BigInt(input.slippageBps ?? 100);
  if (sellAmount <= 0n || slippageBps < 0n || slippageBps > 10_000n) {
    throw new Error("invalid amount or slippage");
  }

  const url = new URL(endpoint);
  url.searchParams.set("sellToken", sellToken);
  url.searchParams.set("buyToken", buyToken);
  url.searchParams.set("chainId", String(input.chainId ?? chainId));
  url.searchParams.set("sellAmount", sellAmount.toString());
  url.searchParams.set("taker", taker);
  url.searchParams.set("slippageBps", slippageBps.toString());
  const headers = { "0x-version": "v2" };
  if (apiKey) headers["0x-api-key"] = apiKey;

  const response = await fetch(url, { headers });
  const body = await response.json();
  if (!response.ok) throw new Error(`0x quote failed: ${response.status}`);
  if (!body.buyAmount || !body.transaction?.to || !body.transaction?.data) {
    throw new Error("quote omitted executable route data");
  }
  return {
    buyAmount: body.buyAmount,
    minBuyAmount: body.minBuyAmount ?? (
      BigInt(body.buyAmount) * (10_000n - slippageBps) / 10_000n
    ).toString(),
    allowanceTarget: body.allowanceTarget ?? body.transaction.to,
    transaction: {
      to: body.transaction.to,
      data: body.transaction.data,
      value: body.transaction.value ?? "0",
    },
  };
}

const server = http.createServer(async (req, res) => {
  if (req.method === "OPTIONS") return json(res, 204, {});
  if (req.method === "GET" && req.url === "/health") {
    return json(res, 200, { ok: true, service: "openBSKT-quote-service" });
  }
  if (req.method !== "POST" || req.url !== "/quote") {
    return json(res, 404, { error: "not found" });
  }
  try {
    return json(res, 200, await quote(await readBody(req)));
  } catch (error) {
    return json(res, 400, { error: error instanceof Error ? error.message : "request failed" });
  }
});

server.listen(port, "127.0.0.1", () => {
  console.log(`openBSKT quote service listening on http://127.0.0.1:${port}`);
});
