/*
 * Request signing: HMAC-SHA256 over `${timestamp}.${body}` with a key that also ships inside the
 * Furl app.
 *
 * THIS IS NOT REAL SECURITY. Anyone can pull the key out of the app binary and sign whatever they
 * like. It is a speed bump against drive-by junk (curl, scanners, copy-pasted requests), nothing
 * more. What actually keeps the totals honest is the schema validation, per-event ceilings, the
 * per-install daily caps in SQL, rate limiting, and idempotent event ids.
 */

const encoder = new TextEncoder();

function hexToBytes(hex: string): Uint8Array | null {
  if (!/^[0-9a-f]{64}$/.test(hex)) return null;
  const out = new Uint8Array(32);
  for (let i = 0; i < 32; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

async function importKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
    "verify",
  ]);
}

/** Constant-time verification (crypto.subtle.verify does the comparison). */
export async function verifySignature(secret: string, timestamp: string, body: string, signatureHex: string): Promise<boolean> {
  const signature = hexToBytes(signatureHex);
  if (!signature) return false;
  const key = await importKey(secret);
  return crypto.subtle.verify("HMAC", key, signature, encoder.encode(`${timestamp}.${body}`));
}

/** Used by tests (and documents exactly what the app computes). */
export async function sign(secret: string, timestamp: string, body: string): Promise<string> {
  const key = await importKey(secret);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(`${timestamp}.${body}`)));
  return Array.from(mac, (b) => b.toString(16).padStart(2, "0")).join("");
}
