# Contributing

Thanks for helping. A few things keep OpenStream for Mac feeling like an app Apple might have made.

## Before you start

- Read `CLAUDE.md`: it maps the code and explains how each feature works and why.
- For anything bigger than a fix, open an issue first so we can agree on the approach.
- Sources (sites and add-ons) live in the shared catalog in the [Android repository](https://github.com/Ivorisnoob/OpenStream/tree/main/extensions). Add or fix them there.

## Building and testing

1. Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` and add a TMDB API key.
2. Build the `OpenStreamMac` scheme in Xcode 26 or with `xcodebuild` (see the README).
3. Run the core tests: `cd OpenStreamCore && swift test`. Add a test for each behaviour you add or fix there; real API answers make the best fixtures (`OpenStreamCore/Tests/OpenStreamCoreTests/Fixtures`).
4. Debug builds have a probe that checks sources and playback without the interface:
   `OPENSTREAM_PROBE=movie:27205 build/debug/Build/Products/Debug/OpenStream.app/Contents/MacOS/OpenStream`.

## Code

- SwiftUI, Swift 6 with strict concurrency, `@Observable`, no third-party packages.
- The system's own components first (`NavigationSplitView`, `.inspector`, `AVPlayerView`, `ContentUnavailableView`, glass button styles); draw something custom only when nothing in the system does the job.
- Everything below the interface goes in `OpenStreamCore`, which has tests.
- Comments explain *why*, in plain sentences.
- Saved data must survive upgrades: decode new fields optionally, with defaults.

## Pull requests

- One change per pull request, with a short description of what changed and why.
- Say what you tested, and how.
- No API keys, personal data or build products in commits.
