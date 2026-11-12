# OpenStream for Mac — map for Claude

Movies, series and anime in a native Mac app: SwiftUI on the macOS SDK itself (not Catalyst), macOS 26, Liquid Glass, Swift 6, `@Observable`, no third-party packages. The Apple sibling of OpenStream for Android (`~/Developement/openstream`), built the way Koda for Mac was (`~/Developement/swift koda/Koda`, its `KodaMac` target). Android's ideas are copied where they serve viewers here; its layouts, Material design and habits stay on Android. An iPhone target will share the same folders later (`#if os(iOS)` branches, as Koda does).

## Rules

- **Keep this file current.** Every feature, file, setting, saved key or non-obvious decision gets a short line here: where it lives and how it works. History goes in commits.
- **Build it the way Apple would.** Before designing a screen, ask how Apple's own Mac apps do it (TV, Music, QuickTime, System Settings) and do that, without copying any one app's look. Everything lives in the sidebar, side panels are `.inspector`, playback has its own window, every place has a menu command and shortcut.
- **The most default SwiftUI that does the job.** System controls, materials and APIs (`NavigationSplitView`, `List(.sidebar)`, `.inspector`, `.searchable`, `ContentUnavailableView`, `.glassEffect`, `.buttonStyle(.glass)`, `backgroundExtensionEffect`, AVKit's `AVPlayerView`) before anything drawn by hand.
- **Caching the platform's way**, not Android's: HTTP caching through `URLCache` where the server sends cache headers, `NSCache` for decoded images, memory only for anything that expires (stream links).
- New `.swift` files are picked up automatically (synchronized folders); no pbxproj edits.
- The app target defaults to **MainActor isolation**; value types used off the main actor need `nonisolated`. Callbacks AVFoundation calls on its own threads are built in `nonisolated static` helpers (see `PlaybackModel`'s Callbacks).
- No `await` on the right of `??` (an autoclosure).
- Comments say *why*, in plain sentences. No emojis anywhere.

## Layout

```
OpenStreamCore/            Swift package: everything below the UI (has tests: `swift test`)
  TMDB/                    TMDB (client + HTTP cache), TMDBResponses (DTOs → models), TitleList (every list TMDB can give)
  Models/                  Title (MediaKind, TitleRef, TitleSummary, TitleDetails, Season, Episode, Person, SearchResults, TMDBDate), Artwork (TMDBImage sizes)
  Streams/                 StreamModels (MediaIdentity, StreamSource, StreamQuality, StreamAudio, StreamProvider, ProviderError),
                           Catalog (the shared extensions/index.json; bundled copy in Resources/catalog.json), StreamFinder (search + ranking + 10-min memory cache),
                           SourceHTTP (Safari user agent, ephemeral session, "looks playable" probe), StremioProvider, VidkingProvider (+ VidkingCipher),
                           WebPlayerProvider (URL templates; the sniffing itself is the app's)
  Library/                 Library (@MainActor @Observable: Watchlist, positions, Continue Watching, watched marks, History → library.json)
OpenStream/                the app target (OpenStreamMac)
  App/                     OpenStreamApp (scenes, menus), AppModel, AppSettings, SourcesStore, Route (+ SidebarItem), SettingsView, Probe (debug only)
  Mac/                     RootView (split view, sidebar, search), BrowseModel/BrowseView (Home, Movies, TV Shows, Anime + hero carousel), TitleView,
                           GridPages (PosterGrid, TitleListView, PersonView), SearchView, LibraryViews, SourcesView
  Player/                  PlaybackModel (the one AVPlayer), PlayerView (window content, inspector), WebPlayerSniffer (hidden WKWebView)
  Components/              Cards (PosterCard, WideCard, RankedCard, ContinueCard, CardBand, PersonCard, TitleLink, TitleMenuItems), Shelf (+ ShelfScroller, TitleShelf), Loading
  Images/                  ImagePipeline (+ Artwork view)
Config/Base.xcconfig       includes Secrets.xcconfig (git-ignored: TMDB_API_KEY) → Info.plist TMDBAPIKey → `Secrets.tmdbKey`
OpenStream-Info.plist      TMDBAPIKey, ATS arbitrary loads (some sources are plain http)
```

## How things work

- **Window and navigation:** one `Window("OpenStream", id: "main")`. Sidebar: Home, Movies, TV Shows, Anime; Library: Continue Watching, Watchlist, History; Sources. Each place keeps its own stack (`AppModel.paths[SidebarItem]`); clicking the current place pops to its root (`select`). Push with `NavigationLink(value: Route…)` or `app.open(route)`. Go menu: ⌘1–⌘7 in sidebar order, Sources ⌘0. ⌘R refreshes the current browse page.
- **Search:** the field is in the sidebar (`.searchable(placement: .sidebar)`, as Music's), not the toolbar: with no title in the toolbar a toolbar field drifted left over the hero. Typing switches to `SidebarItem.search` (not shown as a row); clearing the field returns to where you were. `SearchModel` debounces 250 ms; results have All / Movies / TV Shows / People. Empty field shows genre tiles.
- **Browse pages:** `BrowseModel` (owned by `AppModel`, so switching places never reloads): hero from `heroList` (titles with a backdrop and an overview, ≤ 7), shelves from `ShelfSpec`s, each loaded on its own; reloaded after an hour. Home adds Continue Watching after the hero; Movies/TV add a genre strip. Hero: crossfades every 9 s unless hovered or Reduce Motion, logo from TMDB images (`TitleLogo`), page dots, chevrons in the margin. The hero runs under the toolbar: `.ignoresSafeArea(.top)`, `.scrollEdgeEffectHidden(true, for: .top)`, `.toolbarBackgroundVisibility(.hidden)`, `.toolbar(removing: .title)`, and `heroShape()` (no `backgroundExtensionEffect`; see Hero shape).
- **Hero shape:** featured pictures (Home/browse carousel, title header) sit beside the sidebar, never under it: `heroShape()` (BrowseView.swift) rounds their foot. With `backgroundExtensionEffect` the picture's bottom edge showed through the floating sidebar's glass as a hard line, and the shade met the sidebar at a seam.
- **Cards:** posters in shelves have no caption (the art carries the title; `.help` and the accessibility label give the name); grids pass `showsCaption: true`. `CardButtonStyle` scales to 0.97 on press and lifts the artwork on hover (`cardHovered` environment). Continue Watching and episode cards put their text in a `CardBand` (material + dark gradient, masked) over the image's foot. Top 10 sets the rank into the poster's corner.
- **Title page:** `TitleModel` loads details (credits, videos, recommendations + similar, external ids, images, ratings in one request) and the selected season. Play's label says what it will do ("Resume S2, E3", "Play S1, E1"). Crew: one entry per person with all their jobs, director first; people already in the cast aren't repeated.
- **Caching:** TMDB answers live in a 200 MB disk `URLCache` (Caches/com.ivor.openstream/TMDB) with the protocol policy: TMDB sends `max-age` (≈4 h titles, 2 min trending) and ETags, so stale answers revalidate with 304s. Offline errors retry with `.returnCacheDataDontLoad`. `fresh: true` (refresh) uses `.reloadIgnoringLocalCacheData`. Images: `ImagePipeline` = 600 MB disk `URLCache` (`returnCacheDataElseLoad`; TMDB images carry a one-year max-age) + `NSCache` of ImageIO-downsampled `CGImage`s keyed by URL and pixel size (300 MB cost). Streams: `ResolvedStreamCache`, memory only, 10 min, complete searches that found something; a failed stream drops the entry. Settings → Storage shows sizes and clears.
- **Sources:** `SourcesStore` = bundled `Catalog` merged (by `versionCode`) with the copy fetched from GitHub at most daily (kept in Application Support/OpenStream/catalog.json). Enabled set and order in UserDefaults (`openstream.sources.*`). New entries follow `installedByDefault`, except Stremio add-ons, which start on here (see Known constraints). Anime site engines (anikoto, reanime, animepahe, fouranimo, animegg) aren't supported yet and show under "Coming to the Mac".
- **Finding streams:** `StreamFinder.search` asks direct sources at once (25 s each); fallback sources (web players) start when the direct ones found nothing, or nothing after 8 s (60 s limit each, which covers waiting for a page slot). `rank`: `playabilityRank` (HLS and MP4 first, unknown links next, MKV/AVI/DASH/WebM/TS last), then quality (Auto counts as 720p), then the viewer's order. Stremio: manifest read once per run, IMDb or `tmdb:` ids as the add-on says, releases grouped and the first mirror per release that answers a 16-byte range request like video (8 s budget); the filename hint (`behaviorHints.filename`) gives links without an extension their container.
- **Web players:** `WebPlayerSniffer` loads the page in a `WKWebView` (non-persistent store, Safari UA) inside a transparent window far off screen (players only start in a window), five pages at a time (`SniffLimiter`), 13 s each. A document-start script in every frame reports XHR/fetch URLs and JSON bodies, media element sources, mutes and nudges play buttons; `isStream` keeps .m3u8/.mp4 and drops ads and placeholder clips (demo, sample, preroll). Headers sent with a found stream: Referer/Origin of the frame that asked. Main-frame navigation to another site is allowed only until the first page loads (redirects), then blocked (ads).
- **Playback:** `PlaybackModel` owns one `AVPlayer`. `play`/`resume` → `Window("Player")` opens (`windowRequests`) → details (for the IMDb id) and the season's episodes → search; the best stream starts 2.5 s after the first is found (or when the search ends). Headers go through `AVURLAsset` options (`AVURLAssetHTTPHeaderFieldsKey`, `AVURLAssetHTTPUserAgentKey`). A stream that fails, stops mid-way or isn't ready in 20 s is marked failed and the next untried one starts at the same position. `AppSettings.startsAutomatically` off = the viewer picks from the inspector.
- **Waiting and failing over:** `PlaybackModel` watches `timeControlStatus`; waiting longer than 0.4 s while playing shows `BufferingIndicator` (spinner in glass; after 10 s "This stream is slow to load" + Try Another Stream → `tryAnotherStream`). `AVPlayerItem.newErrorLogEntryNotification`: two hard HTTP refusals (401/403/404/410 in the error comment) move to the next stream at the same spot; AVFoundation alone retries a missing segment every 5 s for 20+ s. When every stream found has failed and fallback sources were skipped (`SourceStatus.skipped`), `lookFurther` asks them (`StreamFinder.search(_:only:)`) before showing the failure. hdhub's "HLS" (its own server, segments disguised as .jpg/.png on nebula.* hosts) is missing many segments outright; that is the server, not the app.
- **Subtitles:** `OpenStreamCore/Subtitles`: `OpenSubtitles.search` (keyless legacy REST, IMDb id, episode/season path segments in alphabetical order, English and the viewer's language first, ≤ 4 per language) and `Subtitles.load` (download, gunzip via Compression's raw DEFLATE after reading the gzip header, UTF-8/16 else CP1252, SRT/VTT parse, tags and subtitle-site ads dropped). Options: the playing stream's own files first, other sources', then OpenSubtitles. Toolbar `SubtitleMenu` (Off, then per language); the choice's language is remembered (`AppSettings.subtitleLanguage`, `openstream.subtitles.language`, nil = off) and picked again automatically. `SubtitleText` draws the cue over the picture (4.2 % of its height, white on 55 % black), updated by a 0.1 s time observer with a binary search.
- **Logging:** `Log.playback` (subsystem com.ivor.openstream, category Playback): starts, each source's result, streams chosen, stream errors, failovers, subtitles. Read with `log show --last 30m --info --predicate 'subsystem == "com.ivor.openstream"'`.
- **Player window:** AVKit's `AVPlayerView` (floating controls, subtitles/audio menus, speed, PiP, AirPlay, full screen, Now Playing, media keys). Inspector (toolbar button): Streams (sources with streams, still looking, then a folded "No Streams (n)" group with reasons; Search Again in a `safeAreaBar`) and Episodes. Before the picture: `StatusOverlay` (blurred still, logo, progress / failure). Near the credits: `UpNextCard`; at the end a 5 s countdown when `autoplaysNextEpisode`. Closing the window stops playback and saves the position. Playback menu: Next Episode ⇧⌘→, Search for Streams Again.
- **Progress:** saved every 5 s and on stop (`Library.record`): resume from ≥ 30 s; ≥ 94 % counts as finished (`finish` → watched mark, History, and Continue Watching moves to the next episode as "Next Episode", or the film leaves it). Next episode: next in the season, else the first aired episode of the next season.
- **Library file:** Application Support/OpenStream/library.json, written off the main thread (progress batched 2 s), every field decoded optionally so older files open; `flush()` on quit.

## Known constraints (November 2026)

- **Vidking's API is gone:** `api.speedracelight.com/seed` answers 404, so all nine `vidking-direct` routes fail at once ("Isn't answering right now"). Android has the same problem; its catalog still lists them.
- **AVFoundation plays HLS and MP4 only** (no DASH, MKV, AVI, WebM). vidlink (Jett) hands out DASH (`.mpd`, HEVC, CloudFront cookies in `playlistHeaders`); several Stremio releases are MKV. A local gateway that rewrites DASH (SegmentTemplate/fMP4) as an HLS playlist and adds headers/cookies is the planned fix; the same proxy would handle hosts that need cookies and the fake-PNG segment prefix some anime CDNs use.
- **Web players tested on Inception:** vidrock (Phoenix) and vidfast (Sova) give HLS/MP4 that plays; vidlink gives DASH; videasy, vidzee, vidplus, 2embed, vidsrc.wtf, vidjoy, spencerdevs and the Vidking embed reported nothing to the hidden page. Each needs its own look (Cloudflare checks, click-to-play, players in frames that block scripts).
- **Stremio add-ons start on** on the Mac (the catalog has them off): with Vidking down they are what most often has a stream AVFoundation plays (hdhub 1080p HLS, yastream 720p HLS tested). zeus and fenixflix didn't connect.
- Subtitles inside an HLS stream also show through AVKit's own menu; files that web players load (vidlink's captions) aren't collected yet.

## Machines

This Mac is Intel (x86_64), macOS 26.7, Xcode 26.5. Builds are slow-ish; incremental Debug builds take under a minute.

- Build: `xcodebuild -project OpenStream.xcodeproj -scheme OpenStreamMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build/debug build` → `build/debug/Build/Products/Debug/OpenStream.app`.
- Core tests: `cd OpenStreamCore && swift test` (fixtures are real TMDB and Stremio answers).
- **Probe (debug builds):** `OPENSTREAM_PROBE=movie:27205` or `tv:1396:1:1` runs every supported source for the title, prints what each found, opens the best streams in AVPlayer and reports whether they play, then quits. `OPENSTREAM_PROBE_SOURCES=hdhub,phoenix` limits the sources; `OPENSTREAM_PROBE="sniff <url>"` runs one web player; `OPENSTREAM_PROBE_TRACE=1` prints what pages report. macOS has no `timeout`: wrap with `perl -e 'alarm 120; exec @ARGV'`.
- Screenshots: `screencapture -x file.png` works from the shell; clicks can be posted with a small CGEvent tool kept in the scratchpad.
- Scratch work goes in `.scratchpad/` (git-ignored).

## Git

Local repository, branch `main`; not pushed anywhere yet. Commit as the person's GitHub identity once the remote exists (Koda uses `Ivorisnoob <179814302+Ivorisnoob@users.noreply.github.com>`). Commit messages: a short subject, then what changed and why.

## Working with the person

- They test on their Mac and report with screenshots; fixes should be done properly for viewers, not patched.
- Say plainly what was verified (tests, build, probe, screenshots) and what wasn't.
