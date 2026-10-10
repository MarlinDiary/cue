# Cue's server

A Cloudflare Worker that the app talks to when the user pays with points instead of their own OpenAI key:

- **Points.** An account is an id and a secret the app makes up (kept in the user's iCloud Keychain); balances are in
  micro-dollars of OpenAI cost, a point being 27,000 of them (about one new word). Every request holds an estimate,
  then is charged what OpenAI actually billed (`ledger.ts`). Nothing the user typed is recorded in the ledger.
- **Purchases.** The app sends each App Store transaction; the server checks Apple's signature chain and credits it
  once (`apple.ts`, `routes.ts › purchase`). App Store Server Notifications take refunded points back.
- **The shared library.** A word typed as it is, correctly, is written once and given to everyone who adds it after,
  with its picture, for 0.2 points (`library.ts`). Voices are kept the same way, free after the first.
- **OpenAI.** Requests are made with the server's own key and the app's own prompts (`../Cue/Resources/Prompts`), and
  answered in OpenAI's shapes, so the app reads both alike.

## Local development

```sh
npm install
npx wrangler d1 execute cue --local --file=schema.sql
npm run dev -- --port 8787 --ip 127.0.0.1   # .dev.vars: mock OpenAI, Xcode purchases, free points
```

Run the app with `-serverURL http://127.0.0.1:8787 -grantPoints 10`. `test/purchase.test.ts` checks signatures,
double claims and refunds against the running server (see its first line).

## First deployment

1. `npx wrangler login` (opens Cloudflare in the browser).
2. `npx wrangler d1 create cue` and put the id it prints into `wrangler.toml` (`database_id`), then
   `npx wrangler d1 execute cue --remote --file=schema.sql`.
3. `npx wrangler r2 bucket create cue-library`.
4. Create an OpenAI project for the server with a monthly budget, and store its key:
   `npx wrangler secret put OPENAI_API_KEY` (paste it at the prompt; it never goes in a file).
5. `npm run deploy`, and put the URL it prints into `CueServer.production` in the app.
6. In App Store Connect, set the App Store Server Notifications URL (version 2) to `<url>/v1/apple/notifications`,
   and create the four consumable products in `routes.ts › PRODUCTS`.
