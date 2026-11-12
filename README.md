# OpenStream for Mac

Movies, series and anime in a native Mac app, written in SwiftUI with Liquid Glass. The Apple sibling of [OpenStream for Android](https://github.com/Ivorisnoob/OpenStream), built for the Mac rather than ported to it.

- Browse what's trending, popular and new: Home, Movies, TV Shows and Anime, each with featured titles and shelves
- Title pages with seasons and episodes, cast, trailers and similar titles
- Streams from the same source catalog as Android: Stremio add-ons and web players, searched together, the best one first
- AVKit's player in its own window: Picture in Picture, AirPlay, subtitles and audio tracks, speed, full screen, media keys
- Continue Watching, Watchlist and History, with the next episode lined up and played for you

Needs macOS 26.

## Building

1. Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` and put a TMDB API key in it.
2. Open `OpenStream.xcodeproj` and run the `OpenStreamMac` scheme, or:

```sh
xcodebuild -project OpenStream.xcodeproj -scheme OpenStreamMac -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/debug build
```

Core tests: `cd OpenStreamCore && swift test`.
