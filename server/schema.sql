-- Accounts are the app's own: an id it makes up (also each purchase's appAccountToken) and a secret only it knows.
-- Balances are in micro-dollars of OpenAI cost paid for; a point is 27,000 of them (about one new word).
CREATE TABLE IF NOT EXISTS accounts (
  id TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL,
  balance INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);

-- Every change to a balance: purchases and refunds in, requests out, with what each request cost us at OpenAI.
CREATE TABLE IF NOT EXISTS ledger (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  account TEXT NOT NULL,
  change INTEGER NOT NULL,
  kind TEXT NOT NULL,
  cost INTEGER NOT NULL DEFAULT 0,
  detail TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS ledger_account ON ledger (account, created_at);
CREATE INDEX IF NOT EXISTS ledger_time ON ledger (created_at);

-- Purchases credited, once each, and whether Apple has since refunded them.
CREATE TABLE IF NOT EXISTS purchases (
  transaction_id TEXT PRIMARY KEY,
  account TEXT NOT NULL,
  product TEXT NOT NULL,
  points INTEGER NOT NULL,
  environment TEXT NOT NULL,
  revoked INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);

-- The shared library: one entry per headword, written once and given to everyone who adds the word after, with its
-- picture (in R2) once drawn. `entry` is the entry's JSON as the model wrote it; `idea_hash` finds it by its picture
-- brief.
CREATE TABLE IF NOT EXISTS library (
  key TEXT PRIMARY KEY,
  headword TEXT NOT NULL,
  entry TEXT NOT NULL,
  version INTEGER NOT NULL,
  idea_hash TEXT NOT NULL,
  picture TEXT,
  hits INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS library_idea ON library (idea_hash);

-- What people typed for a library entry ("Eavesdropped" for "eavesdrop"), so the next one who types it gets it.
CREATE TABLE IF NOT EXISTS aliases (
  input TEXT PRIMARY KEY,
  key TEXT NOT NULL
);
