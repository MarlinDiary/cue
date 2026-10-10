import type { Env } from './env';

/** Micro-dollars of OpenAI cost one point pays for: about one new word (entry and picture, measured 2026-10-10). */
export const POINT = 27_000;
/** A word someone has already added, from the shared library: 0.2 points, for the server and storage. */
export const LIBRARY_HIT = 5_400;

/** The points a balance comes to, to one decimal place, as the app shows them. */
export function points(micros: number): number {
  return Math.round((micros / POINT) * 10) / 10;
}

/**
 * Takes `hold` from the account for a request about to be made, if it has at least `needs`, so two requests at once
 * can't both spend the same points. Whether it could.
 */
export async function reserve(env: Env, account: string, hold: number, needs = hold): Promise<boolean> {
  const row = await env.DB.prepare('UPDATE accounts SET balance = balance - ?1 WHERE id = ?2 AND balance >= ?3 RETURNING balance')
    .bind(hold, account, needs)
    .first();
  return row !== null;
}

/**
 * Settles a request: gives back what was held, takes `charge`, and records it with what OpenAI charged us, `cost`.
 * Nothing the user typed or asked is recorded: only what kind of request it was and what it cost.
 * The balance can go a little below zero when a request cost more than was held; the next purchase covers it.
 */
export async function settle(env: Env, account: string, hold: number, charge: number, kind: string, cost: number,
  detail?: string): Promise<number> {
  const [update] = await env.DB.batch<{ balance: number }>([
    env.DB.prepare('UPDATE accounts SET balance = balance + ?1 WHERE id = ?2 RETURNING balance').bind(hold - charge, account),
    env.DB.prepare('INSERT INTO ledger (account, change, kind, cost, detail, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)')
      .bind(account, -charge, kind, cost, detail?.slice(0, 200) ?? null, Date.now()),
  ]);
  return update.results[0]?.balance ?? 0;
}

/** Adds to (or, for a refund, takes from) a balance, and records it. */
export async function credit(env: Env, account: string, amount: number, kind: string, detail: string): Promise<number> {
  const [update] = await env.DB.batch<{ balance: number }>([
    env.DB.prepare('UPDATE accounts SET balance = balance + ?1 WHERE id = ?2 RETURNING balance').bind(amount, account),
    env.DB.prepare('INSERT INTO ledger (account, change, kind, cost, detail, created_at) VALUES (?1, ?2, ?3, 0, ?4, ?5)')
      .bind(account, amount, kind, detail, Date.now()),
  ]);
  return update.results[0]?.balance ?? 0;
}
