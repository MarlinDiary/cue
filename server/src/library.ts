import { type Env, sha256Hex } from './env';

/** The entries' shape and prompts: an entry written for an older one is written again rather than given out. */
export const ENTRY_VERSION = 4;

/** What two inputs or headwords that are the same thing have in common. */
export function keyOf(text: string): string {
  return text.trim().replace(/\s+/g, ' ').toLowerCase();
}

/** The library's entry for what was typed, if someone has added it before: its key and its JSON. */
export async function lookup(env: Env, input: string): Promise<{ key: string; entry: string } | null> {
  return env.DB.prepare(`SELECT library.key AS key, library.entry AS entry FROM aliases
    JOIN library ON library.key = aliases.key WHERE aliases.input = ?1 AND library.version = ?2`)
    .bind(keyOf(input), ENTRY_VERSION)
    .first<{ key: string; entry: string }>();
}

/**
 * Keeps an entry just written for everyone who adds the word after: only one for what was typed as it is, correctly,
 * since an entry written for a question or a misspelling records it (`question`), and that is the user's own.
 */
export async function remember(env: Env, input: string, text: string): Promise<void> {
  let entry: any;
  try {
    entry = JSON.parse(text);
  } catch {
    return;
  }
  if (entry?.question != null || typeof entry?.headword !== 'string' || typeof entry?.pictureIdea !== 'string') return;
  const key = keyOf(entry.headword);
  if (!key) return;
  const ideaHash = await sha256Hex(entry.pictureIdea);
  await env.DB.batch([
    env.DB.prepare(`INSERT INTO library (key, headword, entry, version, idea_hash, picture, hits, created_at)
      VALUES (?1, ?2, ?3, ?4, ?5, NULL, 0, ?6)
      ON CONFLICT (key) DO UPDATE SET headword = excluded.headword, entry = excluded.entry, version = excluded.version,
        idea_hash = excluded.idea_hash, picture = NULL, created_at = excluded.created_at
      WHERE library.version < excluded.version`)
      .bind(key, entry.headword, text, ENTRY_VERSION, ideaHash, Date.now()),
    env.DB.prepare('INSERT OR REPLACE INTO aliases (input, key) VALUES (?1, ?2)').bind(keyOf(input), key),
    env.DB.prepare('INSERT OR IGNORE INTO aliases (input, key) VALUES (?1, ?1)').bind(key),
  ]);
}

export async function counted(env: Env, key: string): Promise<void> {
  await env.DB.prepare('UPDATE library SET hits = hits + 1 WHERE key = ?1').bind(key).run();
}

/** The library entry a picture brief belongs to, if any, with its picture's place in R2 once drawn. */
export async function forIdea(env: Env, idea: string): Promise<{ key: string; picture: string | null } | null> {
  return env.DB.prepare('SELECT key, picture FROM library WHERE idea_hash = ?1 AND version = ?2')
    .bind(await sha256Hex(idea), ENTRY_VERSION)
    .first<{ key: string; picture: string | null }>();
}

/** Keeps a library entry's picture, drawn for the first one who added the word. */
export async function keepPicture(env: Env, key: string, png: Uint8Array): Promise<void> {
  const name = `pictures/v${ENTRY_VERSION}/${await sha256Hex(key)}.png`;
  await env.LIBRARY.put(name, png, { httpMetadata: { contentType: 'image/png' } });
  await env.DB.prepare('UPDATE library SET picture = ?1 WHERE key = ?2').bind(name, key).run();
}
