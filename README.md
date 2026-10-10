<p align="center">
  <img src=".github/images/icon.png" width="128" height="128" alt="Cue">
</p>

<h1 align="center">Cue</h1>

<p align="center">
  Vocabulary cards for Chinese speakers learning English.<br>
  Type a word, or just say what you mean: AI writes the entry and draws the picture.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-27-000000?logo=apple&logoColor=white" alt="iOS 27">
  <img src="https://img.shields.io/badge/SwiftUI-Liquid%20Glass-F05138?logo=swift&logoColor=white" alt="SwiftUI">
  <img src="https://img.shields.io/badge/review-FSRS--6-34C759" alt="FSRS-6">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-blue" alt="Apache 2.0"></a>
</p>

<p align="center"><b>English</b> · <a href="README.zh-CN.md">简体中文</a></p>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/images/screens-dark.png">
  <img src=".github/images/screens-light.png" alt="The wall of words, a word's page, a review card, and Ask AI">
</picture>

## Features

- **Add anything.** An English word, a Chinese word, or a description of what you mean. Cue finds the English and
  writes a dictionary-style entry: IPA, Chinese meanings, examples, phrases, usage, and where the word comes from.
- **A picture for every word.** Each word gets its own illustration, drawn from its entry.
- **Hear it.** Tap the headword, an example, or a phrase to hear it in a natural American voice.
- **Review at the right time.** Cards come back as you are about to forget them (FSRS-6). Tap to see the answer,
  swipe right if you knew it. The ring in the corner fills as today's review gets done.
- **Ask AI.** Ask about one word, or about everything on your wall.
- **In your iCloud.** Words and conversations sync to your other devices and come back after a reinstall.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/images/pictures-dark.png">
  <img src=".github/images/pictures-light.png" alt="Pictures drawn for twelve words">
</picture>

## AI

AI runs on OpenAI's models, in one of two ways:

- **Points**, bought in the app. Cue's server charges each request what it actually costs at OpenAI. A word someone
  has already added comes from the shared library for 0.2 points.
- **Your own OpenAI API key.** The app talks to OpenAI directly, and Cue's server is never involved.

## Inside

| | |
| --- | --- |
| [`Cue/`](Cue) | The app: SwiftUI, SwiftData with CloudKit sync, StoreKit 2 |
| [`server/`](server) | A Cloudflare Worker with D1 and R2: accounts, points, purchases, and the shared library |
| [`site/`](site) | Support and privacy pages, at [chenyeni.com/cue](https://chenyeni.com/cue/) |
| [`tools/`](tools) | Picture generation, model comparison, site publishing, App Store export |

## Build

Open `Cue.xcodeproj` in Xcode 27, choose your own team, and run on iOS 27. On a device, also use your own bundle
identifier and iCloud container. For AI, add an OpenAI API key in Settings → AI → My OpenAI Key. The server's setup
is in [`server/README.md`](server/README.md).

## License

[Apache 2.0](LICENSE)
