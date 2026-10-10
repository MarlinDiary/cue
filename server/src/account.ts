import { type Env, HttpError, sha256Hex } from './env';

export interface Account {
  id: string;
  balance: number;
}

const AUTHORIZATION = /^Bearer ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.([A-Za-z0-9_-]{32,128})$/;

/**
 * The account a request is for. The app makes up its account, an id and a secret kept in the user's iCloud Keychain,
 * and the first request it makes opens it: there is nothing to sign up for.
 */
export async function authenticate(request: Request, env: Env): Promise<Account> {
  const match = AUTHORIZATION.exec(request.headers.get('Authorization') ?? '');
  if (!match) throw new HttpError(401, 'unauthorized', 'The request had no account.');
  const [, id, token] = match;
  const hash = await sha256Hex(token);
  const find = () => env.DB.prepare('SELECT token_hash, balance FROM accounts WHERE id = ?1').bind(id)
    .first<{ token_hash: string; balance: number }>();
  let row = await find();
  if (!row) {
    await env.DB.prepare('INSERT OR IGNORE INTO accounts (id, token_hash, balance, created_at) VALUES (?1, ?2, 0, ?3)')
      .bind(id, hash, Date.now()).run();
    row = await find();
  }
  if (!row || row.token_hash !== hash) throw new HttpError(401, 'unauthorized', 'The account’s secret didn’t match.');
  return { id, balance: row.balance };
}
