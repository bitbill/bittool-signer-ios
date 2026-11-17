// Node module hook used only by review-text-corpus.mjs: wraps the engine's review
// entry points so that every review the test suite produces, and every refusal it
// provokes, is handed to globalThis.__reviewText. No engine file is changed on disk.
const WRAP = {
  '/src/evm.js': ['parseEVM'], '/src/solana.js': ['parseSolana'], '/src/bitcoin.js': ['parseBitcoin'], '/src/tron.js': ['parseTron'],
  '/src/resolver.js': ['resolveSigningPlan', 'signPlanTask'], '/src/index.js': ['dispatch'],
  '/protocols.js': ['decodeQR', 'decodePayload', 'createWalletPairing', 'createPublicPairing'],
};
export async function load(url, context, next) {
  const out = await next(url, context);
  const hit = Object.entries(WRAP).find(([suffix]) => url.endsWith('/engine' + suffix));
  if (!hit || out.format !== 'module') return out;
  let source = typeof out.source === 'string' ? out.source : new TextDecoder().decode(out.source);
  for (const name of hit[1]) source += `\n;{const __o=${name};${name}=function(...a){let r;` +
    `try{r=__o.apply(this,a);}catch(e){try{globalThis.__reviewText?.('error',e);}catch{}throw e;}` +
    `try{globalThis.__reviewText?.('result',r);}catch{}return r;};}\n`;
  return { ...out, source, shortCircuit: true };
}
