# Cue

A vocabulary notebook for Chinese speakers learning English, on iPhone (iOS 27).

Type an English word, Chinese, or a description of what you mean: AI writes a dictionary-style entry and draws a
picture for it. Words come back for review as cards, scheduled by FSRS-6.

- `Cue/`: the app (SwiftUI, SwiftData synced through CloudKit). AI goes through Cue's server, paid for with points
  bought in the app, or straight to OpenAI with the user's own API key.
- `server/`: the Cloudflare Worker behind points: accounts, purchases, and the shared library of entries and pictures.
- `site/`: the support and privacy pages, published to the `gh-pages` branch by `tools/publish_site.sh`.
- `tools/`: picture generation, model comparison, and the App Store export options.

## License

Apache License 2.0: see [LICENSE](LICENSE).
