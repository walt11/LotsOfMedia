# LotsOfMedia

A native SwiftUI Plex and Jellyfin client for iPhone, iPad (iOS 17+) and Apple TV (tvOS 17+). The only third-party code is VLCKit, for the optional built-in player (see below).

The Roku version, built to look and work like the Apple TV app, lives in its own repository: [LotsOfMedia-Roku](https://github.com/walt11/LotsOfMedia-Roku).

## Features

- **Sign in**: Plex account through the browser (`app.plex.tv/auth`) or a 4-character code at plex.tv/link. You can also add a server manually by URL, with an optional token.
- **Plex Home users**: switch profiles from the avatar on Home or from Settings, including PIN-protected users. Server access, On Deck, watch state and history all follow the active user.
- **Local and remote**: discovers every server on your account, including shared ones. It races all of a server's advertised addresses and picks the best that answers: local direct, then remote direct, then relay. It re-resolves when the network changes, for example when you leave home Wi-Fi.
- **Browse**:
  - Home hubs and Continue Watching
  - Libraries in a paged grid with sort and an unwatched filter
  - Recommended and Collections views
  - Playlists and search
  - Detail pages for movies, shows, seasons, episodes, artists, albums, tracks, photo albums, and collections, including cast and related items
- **Video playback**: `AVPlayerViewController` with Picture in Picture and AirPlay.
  - Direct play when iOS supports the file. Otherwise it uses Plex HLS transcoding, and it falls back to transcoding automatically if direct play fails.
  - Audio and subtitle track selection.
  - Resume points, with progress reported to the server via `/:/timeline`.
  - Mark watched or unwatched.
  - Watch history (from any device), with screens refreshing when you return to the app so progress made elsewhere shows up.
- **Music**: background audio with a queue and shuffle, lock-screen and Control Center controls, and a mini player plus a full Now Playing screen.
- **Lyrics**: from your server when it has them; timed lyrics follow along and scroll, and tapping a line jumps there.
- **Sound Check**: songs play at a consistent volume using the server's loudness analysis (Playback Preferences).
- **Skip Intro / Skip Credits**: uses Plex's intro and credits markers. At the final credits a "Next Episode in 10" countdown rolls into the next episode, with a "Watch Credits" option.
- **Subtitles**: text subtitles (SRT/ASS/VTT) are drawn by the app, so they don't force a transcode. In the player you can switch tracks, adjust timing and size, and search online providers through your server. Subtitles are saved with downloads for offline use.
- **Smart Downloads**: per show, keep the next 1/3/5/10 unwatched episodes downloaded and delete episodes after watching. Specials (season 0) are skipped unless Include Specials is on. Refreshes on connect, after playback, on app open and in the background.
- **Download rules**: Wi-Fi only, charging only (downloads resume automatically when plugged in, even with the app closed), and a storage limit that can remove watched downloads to make room.
- **Live TV & DVR** (Plex Pass with a tuner such as an HDHomeRun; the tab appears only when the server has a DVR):
  - **On Now**: every channel's current program with artwork, progress and what's next. Tap to watch.
  - **Guide**: a channel × time grid with the channel column and time ruler pinned, a "now" line, new-episode markers and red record dots. It loads more as you scroll, up to 24 hours ahead.
  - **Watching live**: the server tunes the channel and converts the broadcast (MPEG-2) for iPhone. You can pause and rewind within the buffer, then Jump to Live; change channels without leaving the player; and use AirPlay and Picture in Picture.
  - **Recording**: record an episode, or a series with new-only, how many to keep and channel options. The Recordings tab shows what's recording now, upcoming recordings and series rules, which you can edit or stop.
  - **After recording**: a notification when a recording finishes, and an optional "Download to This iPhone" that hands the show to Smart Downloads once its first recording reaches the library.
- **Listening session**: the music queue, current song, position, shuffle and repeat are saved and restored after the app closes, paused, so nothing plays until you press play.
- **Song transitions**: the next song is buffered and queued behind the current one, so songs change without a gap. Optional crossfade (4/8/12 seconds): the next song starts on a helper player and the volumes cross, then the main player takes over at the same point. It applies when the next song is a file (direct play or downloaded); converted streams keep the gapless change. With crossfade off, optional 2/4/6-second fades.
- **Search includes downloads**: matching downloads appear under On This Device, an On This Device filter limits results to them, and offline search shows downloads.
- **Offline readiness**: Downloads shows what's ready to play offline, what's still converting or downloading, what failed, and whether offline watch progress has synced.
- **Offline library**: library, show, album, playlist and Home responses are cached per profile (80 MB cap, plus artwork), so browsing works without a connection. Items that aren't downloaded are dimmed with a "not downloaded" mark while offline.
- **Downloaded playlists stay current**: per playlist, optionally download songs added on the server, and (as a separate choice) remove ones taken off it. Checked when the app connects and in the background.
- **Bulk selection**: Select in songs, albums, mixes, playlists and library grids, then add to a playlist, favorite, Watch Later, download, or remove.
- **Undo**: removing playlist entries shows "Removed — Undo" for five seconds before anything changes on the server.
- **Mixes**: Favorites to Revisit, Recently Added, Downloaded Songs, Most Played and Rediscover.
- **Watch Later**: its own list, separate from Favorites and Continue Watching; watched items are removed automatically (can be turned off).
- **Video controls**: playback speed (0.25–4×), chapters when the file has them, and remembered audio/subtitle languages per profile. The built-in player adds audio sync (±50 ms steps), zoom from 50% to 200% (menu or pinch) and preview thumbnails while scrubbing.
- **Versions**: a title with more than one file (4K and 1080p, an extended cut) has a Version menu on its page; the choice is used for playback and downloads, and remembered.
- **Ratings**: your own 1–5 star rating on each title's page, and IMDb, Rotten Tomatoes and TMDB scores where the server has them.
- **Scrub previews and chapter pictures**: Plex's preview thumbnails and Jellyfin's trickplay images show above the built-in player's scrubber; on Apple TV, chapters appear in the player's info panel with a picture each.
- **Settings backup**: Settings → Backup shares a file with preferences, Favorites, Watch Later and Home layouts, and restores it on another device. Sign-ins and servers aren't included.
- **Free Up Space**: suggests watched movies, finished shows, the largest downloads and rarely played music, and previews the space saved before deleting.
- **Playback Info**: Direct Play vs conversion and why, which player is in use, suggestions to improve playback, source and stream quality, connection route, server conversion details and recent errors, with a shareable report that removes account tokens.
- **Play on another device**: send what's playing to a Plex player on your network (from Now Playing or the video player).
- **CarPlay**: browse music libraries, artists, albums, playlists and downloaded music, with Now Playing controls.
- **Download management**: up to 3 items download at a time. Group downloads (playlists, seasons, shows) appear as one row while downloading and are announced once when they finish. The Downloads tab lists downloaded playlists, and you can swipe to remove a whole playlist, show or artist, or remove a season from its header.
- **Playlists**: video, music and photo playlists with Play/Shuffle; video playlists auto-advance, and episodes roll into the next episode.
- **Navigation**: episodes link to their show and season, with season chips and the season's episode list under every episode.
- **Offline**:
  - Download a movie, an episode, a whole season, a whole show (all or unwatched only), an album, or an artist.
  - Downloads play from disk. Downloaded shows and music can be browsed with no connection.
  - Progress made while offline is synced to the server when you're back online.

## Jellyfin

Jellyfin servers sit alongside Plex ones: sign in from the first screen or Servers → Add Jellyfin Server with a username and password, or with Quick Connect (a code approved in another Jellyfin app, handy on Apple TV). The app keeps working with Plex-shaped requests; [`JellyfinBridge`](LotsOfMedia/Plex/JellyfinBridge.swift) answers them from Jellyfin's API (10.9 and later preferred, with the older per-user routes as a fallback) and returns the JSON a Plex server would. Stream and artwork keys in those answers are Jellyfin paths, signed with `ApiKey` (the spelling every Jellyfin version accepts; 12 refuses `api_key`).

What works the same: browsing, Home rows (Continue Watching, Next Up, Recently Added), search, collections, playlists (create, add, remove, reorder), detail pages with cast and similar titles, extras, direct play and HLS conversion (with the chosen version, audio track and burned-in subtitles), text subtitles drawn by the app, online subtitle search, intro and credits skipping (Jellyfin 10.10 media segments), chapters, trickplay scrub previews, progress and watched state, likes as ratings, lyrics, Sound Check (normalization gain), downloads of the original file and the offline cache.

Not on Jellyfin: Live TV and DVR, Plex Home profiles and the Watchlist (these are Plex account features), playing on other devices, and converted downloads (a file Apple's player can't play downloads as the original for the built-in player).

## Download engine

The code is in [`LotsOfMedia/Downloads/`](LotsOfMedia/Downloads). The design goal is that a network interruption never makes a download start over.

1. **Background `URLSession`.** Transfers keep running while the app is suspended or terminated, and iOS relaunches the app to deliver results (`handleEventsForBackgroundURLSession`).
2. **Byte-range segments.** The file is split into chunks of at least 32 MB, and each chunk is its own HTTP `Range` request.
   - A finished chunk is validated before it is moved to disk: status code, `Content-Range` start offset, total size, and exact length.
   - A dropped connection, app kill, or reboot can only lose the part of a chunk that was in flight.
   - Servers that ignore `Range` fall back to a single stream that resumes using URLSession resume data.
3. **Persisted state.** State is written to disk after every transition. On launch it is reconciled with the tasks the system kept running. Chunk files already on disk are adopted, even if the app died before recording them.
4. **Retries.**
   - Network errors are retried indefinitely with backoff, and retries fire immediately when connectivity returns.
   - Host errors trigger re-resolution of the server address. Only chunks bound to the old address restart.
   - A foreground stall watchdog restarts transfers that iOS's download daemon has silently put on hold. The daemon was observed waiting about 60 seconds or more before retrying on its own.
5. **Crash-safe assembly.** Chunks are stitched into the final file. A checkpoint after each chunk lets assembly resume after a crash, and the final file is verified against the expected size.
6. **Always playable.** "Original Quality" downloads the untouched file when iOS can play it. Otherwise the server converts it to MP4 automatically *before* download using the Plex download queue (`/downloadQueue`, PMS 1.41.9+). The video is copied into the new container without re-encoding whenever its codec allows, so quality is kept. 1080p/720p/480p always convert to a smaller file. The converted file is fetched with the same segmented engine. A server too old to convert gets a clear error instead of an unplayable download.
7. **Background-friendly.** When the app leaves the foreground, every remaining chunk is handed to iOS while it can still be created as a normal (non-discretionary) transfer. The system can then finish large downloads without waking the app between batches.
8. **Live Activity.** Progress appears on the Lock Screen and in the Dynamic Island. While the app is suspended, the bar animates from an estimated finish time and refreshes whenever iOS wakes the app.

Other details:
- A free-space check runs before each download starts.
- Downloads can be restricted to Wi-Fi.
- Files are excluded from iCloud backup.

## CarPlay

The app has Apple's CarPlay audio entitlement (`LotsOfMedia/Resources/LotsOfMedia.entitlements`, with Siri). In the Simulator, open I/O → External Displays → CarPlay.

## Built-in player (VLCKit)

Apple's player plays everything iOS supports (with AirPlay, picture-in-picture and HDR). Files it can't play — MKV/AVI, DTS/TrueHD, MPEG-2/VC-1, image subtitles — play in a built-in player based on [VLCKit](https://code.videolan.org/videolan/VLCKit) straight from the original file, and download as the original. AirPlay and smaller streaming qualities still use your server's conversion. It can be turned off in Playback Preferences.

VLCKit is licensed under the LGPL 2.1. It's embedded unmodified as its own dynamic framework (`MobileVLCKit.framework`), and Settings → Acknowledgements shows its license and source link. Keep it dynamic and unmodified.

## Build

```bash
brew install xcodegen
```

Download VLCKit (about 250 MB, checked against its published SHA-256; it's too large for git, so `Vendor/` isn't committed):

```bash
./scripts/fetch-vlckit.sh
```

```bash
xcodegen generate
```

```bash
open LotsOfMedia.xcodeproj
```

Set your signing team in Xcode to run on a device. Unit tests cover segment planning, `Content-Range` parsing, error classification, chunk validation, and crash-resumable assembly:

```bash
xcodebuild test -project LotsOfMedia.xcodeproj -scheme LotsOfMedia -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Known limitations

- Force-quitting the app (swiping it away in the app switcher) makes iOS cancel its background transfers. Finished chunks are kept, and the download resumes the next time you open the app.
- Server conversion progress is polled while the app is open, plus opportunistic background refreshes. The server keeps converting regardless, and the download starts when you next open the app.
- Sidecar text subtitles are rendered by the app and saved alongside downloads when available. Image-based subtitles play in the built-in player; with it turned off, they require server burn-in.
- Files played by the built-in player can't use AirPlay or picture-in-picture, and pause when the app goes to the background.
- Downloads are shared by all Home users on the device. Offline progress is stored separately for each user and synced when that user is active. Switching profiles pauses active downloads; resume them under the new profile as needed. Manually entered server credentials must be re-added for each session after a profile switch.
- Not yet implemented: Watch Together, and an equalizer (Apple's player has no built-in EQ, and one wouldn't apply to AirPlay or the built-in player).
- The Apple TV app has no unit test target yet; its session and playback logic is covered by building and manual testing.

## Apple TV

The `LotsOfMediaTV` target is the same app on Apple TV (one purchase covers both with Universal Purchase): Home with Continue Watching and a Top Shelf, Library with sort, filters, collections, playlists and photos, detail pages with trailers, extras and cast pages, Live TV with a guide and a playing window, music with a saved, editable queue, Up Next, a sleep timer, Plex Home profiles, and the built-in player (TVVLCKit). Top Shelf links carry their server, so they never open another server's item.

## Platform and provider capabilities

| Capability | iPhone / iPad | Apple TV | Roku |
| --- | --- | --- | --- |
| Plex and Jellyfin library streaming | Yes | Yes | Yes |
| Plex Live TV / DVR | Requires server tuner/DVR | Requires server tuner/DVR | Requires server tuner/DVR |
| Jellyfin Live TV | Not currently supported | Not currently supported | Not currently supported |
| Offline downloads | Yes | No | No |
| Smaller converted downloads | Plex; Jellyfin keeps originals | — | — |
| Plex Home profiles | Yes | Yes | Yes |

Codecs, subtitles, extras and skip markers depend on device and server capabilities.

### Reproducible Apple TV live playback test

Run `python3 tools/live_seek_fixture.py` (requires ffmpeg). In another terminal, run the
`LivePlayPauseUITests/testPlayPausePresses` test in the `LotsOfMediaTVUITests` scheme with
`TEST_RUNNER_LIVE_URL=http://127.0.0.1:18765/window/live.m3u8` in the environment, and repeat
with `/event/live.m3u8`. It presses Play/Pause and Select full screen; with `-tvLiveDiagnostics`
the app logs each press and pause to `Caches/live-state.log` in its simulator container.
Without a fixture URL, this integration test skips. Restart the fixture before repeating a long
run; its generated stream contains three minutes.

Physical Apple TV testing is still needed for Siri Remote touch-ring scrubbing and real Plex tuners.
Live-state diagnostics are opt-in with the `-tvLiveDiagnostics` debug launch argument; logs rotate
at 1 MB. They are not included in release builds.
