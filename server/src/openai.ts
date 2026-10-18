import type { Env } from './env';
import { mock } from './mock';

/** The models the app uses, as it uses them with the user's own key. */
export const MODELS = {
  entry: 'gpt-6.1-sol',
  brief: 'gpt-6.1-sol',
  chat: 'gpt-6.1-sol',
  decide: 'gpt-6-luna',
  offer: 'gpt-6-luna',
  note: 'gpt-6-luna',
  split: 'gpt-6-luna',
  picture: 'gpt-image-2.5-sunburst',
  speech: 'gpt-4o-mini-tts',
} as const;
export const VOICE = 'marin';

/**
 * Dollars per million tokens, which is micro-dollars per token (October 2026 list prices). Input written to OpenAI's
 * prompt cache costs a quarter more than plain input, and read from it a tenth: the entry's instructions (2,150
 * tokens) are written there whenever no request in the last few minutes read them.
 */
const TEXT_PRICES: Record<string, { input: number; cacheWrite: number; cached: number; output: number }> = {
  'gpt-6.1-sol': { input: 2, cacheWrite: 2.5, cached: 0.2, output: 10 },
  'gpt-6-luna': { input: 0.1, cacheWrite: 0.125, cached: 0.01, output: 0.5 },
};
const IMAGE_PRICES = { text: 5, output: 30 };

export interface Usage {
  input_tokens?: number;
  output_tokens?: number;
  input_tokens_details?: { cached_tokens?: number; cache_write_tokens?: number; text_tokens?: number };
}

/** What a text response cost us, in micro-dollars. */
export function textCost(model: string, usage: Usage | undefined): number {
  const price = TEXT_PRICES[model];
  const input = usage?.input_tokens ?? 0;
  const cached = usage?.input_tokens_details?.cached_tokens ?? 0;
  const written = usage?.input_tokens_details?.cache_write_tokens ?? 0;
  return Math.ceil((input - cached - written) * price.input + written * price.cacheWrite + cached * price.cached
    + (usage?.output_tokens ?? 0) * price.output);
}

/** What a picture cost us, in micro-dollars. */
export function imageCost(usage: Usage | undefined): number {
  const text = usage?.input_tokens_details?.text_tokens ?? usage?.input_tokens ?? 0;
  return Math.ceil(text * IMAGE_PRICES.text + (usage?.output_tokens ?? 0) * IMAGE_PRICES.output);
}

/** A medium picture, for one the safety system turned down after drawing it (its usage isn't given then). */
export const REFUSED_PICTURE_COST = 15_200;

/**
 * What reading `text` aloud cost us, in micro-dollars: the speech endpoint answers with the audio alone, so it is
 * worked out from the text, at about 15 characters a second of audio ($0.015 a minute) and its own tokens.
 */
export function speechCost(text: string): number {
  return Math.ceil((text.length / 15) * 250 + (text.length / 4) * 0.6);
}

/** Asks OpenAI (or, in local development, `mock`) at `path` under /v1. */
export function openai(env: Env, path: string, body: unknown): Promise<Response> {
  if (env.MOCK_OPENAI === '1') return mock(path, body);
  return fetch(`https://api.openai.com/v1/${path}`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${env.OPENAI_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}
