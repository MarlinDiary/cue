import { Buffer } from 'node:buffer';

export interface Env {
  DB: D1Database;
  LIBRARY: R2Bucket;
  OPENAI_API_KEY: string;
  BUNDLE_ID: string;
  MOCK_OPENAI: string;
  ALLOW_XCODE_TRANSACTIONS: string;
  DEV_GRANTS: string;
}

/** An answer to the app other than the one it asked for: `code` is what the app acts on, `message` what it may show. */
export class HttpError extends Error {
  constructor(readonly status: number, readonly code: string, message: string) {
    super(message);
  }

  response(): Response {
    return json({ error: { code: this.code, message: this.message } }, this.status);
  }
}

export function json(value: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json', ...headers } });
}

export async function sha256Hex(data: string | ArrayBuffer | Uint8Array): Promise<string> {
  const bytes = typeof data === 'string' ? new TextEncoder().encode(data) : data;
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

/** Base64 or base64url, decoded natively: a picture is a megabyte and a half of it, and a request on Workers' free
 * plan has 10 ms of CPU. */
export function base64ToBytes(base64: string): Uint8Array {
  return new Uint8Array(Buffer.from(base64, 'base64'));
}
