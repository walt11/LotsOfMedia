# UI improvements

Implemented the eight requested areas:

1. **Home:** Continue Watching leads with visible progress and Resume buttons. Recently Added and Next Episodes follow. Profile and server appear together; promotional artwork follows the useful rows.
2. **Downloads:** Ready Offline and In Progress sections; only playlists with completed media appear under Ready Offline. Queue rows expose conversion/download/finishing/waiting stages, readable failure reasons, retry/resume controls, cellular/battery overrides, and a storage settings shortcut.
3. **Offline:** Persistent connection status and completed-item count across navigation, with reconnect and Downloads shortcuts. Search and download previews explain connection requirements.
4. **Details:** Direct Play/Resume, labeled Download, and More actions. Download previews fetch current metadata, expose quality choices, source/estimated size, and subtitle availability before enqueueing. Converted sizes are estimates, and grouped downloads disclose that size/subtitles vary by item.
5. **Queues:** Music and video Up Next sheets support reorder and removal without altering the current item. Play Next and Add to Queue are available on media context menus and song rows. Video deduplication preserves distinct server identities.
6. **Search:** Profile/server-specific recent searches, clear history, Movies/TV/Music filters, recent-title suggestions, cancellation-aware requests, and distinct error/no-results states with retry.
7. **iPad:** Regular-width sidebar navigation, adaptive poster grids that respond to text size, and enlarged artwork beside detail headers. Compact layouts retain tab navigation.
8. **Live TV:** Saved server-specific channel favorites, favorites/text guide filters, a last-watched shortcut, and previous-channel switching in the player. Recording screens show potential tuner conflicts before scheduling.

## Validation and limits

Regression coverage includes queue editing and server identity, search history/filtering, download estimate labels, and recording interval overlap. Live recording conflicts are estimates from the loaded server schedule: recording padding, live tuner usage, and future series episodes can introduce additional conflicts. Subtitle counts describe server-listed tracks; offline support depends on subtitle type and conversion.

Authenticated streaming/download/recording and visual checks on physical iPhone/iPad hardware remain manual integration checks.

## Music and icons

- Standard and dark app icons now use orange TV artwork; navigation shortcut and library icons use the shared orange accent. The tinted asset remains grayscale for iOS system tinting.
- Music libraries have Artists, Albums, Songs, and For You tabs. Songs displays track rows with playback, download, queue, and playlist actions. Full-library search and shuffle are described below.
- Create playlists from Library → Playlists → +, or the music library's playlist menu. Choose a name, music/video category, library, and items. Selections persist across pages and title filters. A success screen confirms the server save.
- Song row menus support Add to Playlist and creation with that song preselected. Smart playlists are excluded from manual additions.
- Playlist requests follow the [PlexAPI reference implementation](https://python-plexapi.readthedocs.io/en/latest/_modules/plexapi/playlist.html), using the server's machine identifier and active profile credentials. Validation prevents empty playlists, mixed audio/video, and invalid item identifiers.

## Music and Watch modes

- The Music / Watch switch is persistent on compact screens and at the top of the iPad sidebar. The last mode is restored at launch.
- Each mode retains its own selected tab and mounted navigation stacks when switching modes. Profiles, servers, storage settings, and playback queues remain shared.
- Music Home shows recently played tracks, new albums, music recommendations, and shortcuts to Artists, Albums, Songs, Playlists, and Offline Music.
- Watch Home retains Continue Watching, new video, Next Episodes, and Live TV. Music mode never exposes the Live TV tab.
- Libraries, search suggestions/results/history, playlists, playlist creation, playback history, downloads, counts, queue banners, and download bulk actions are scoped to the current mode. Photo libraries are outside both focused modes.
- The music mini-player is shown in Music mode. Switching modes does not pause playback or clear queues; explicitly playing another media source transfers playback focus and pauses the previous player.
- Regression tests cover media and playlist boundaries, mixed recommendation hubs, library filtering, tab restoration, preference persistence, queue preservation, and playback focus.

Live authenticated browsing and visual device checks remain integration checks; simulator unit tests do not establish those outcomes.

## Expanded media features

- **Playlist editor:** Open a manual playlist and choose Edit to rename it, delete or reorder individual entries, and choose artwork from Photos. Duplicate songs retain separate Plex playlist entry IDs. Saves check for changes on another device; failed partial saves report the error and refresh the playlist. Smart playlist rules remain managed by Plex.
- **Favorites:** Item menus have a heart action. Favorites appear on each Home screen and in Library, separated by Music/Watch, profile, and server. They persist locally on this device.
- **Music playback:** Now Playing has shuffle for remaining songs and repeat off/queue/song controls. Songs loads the complete selected music library for title/artist/album filtering and whole-library shuffle; other library views retain pagination.
- **Sleep timer:** Music and video menus offer 15/30/45/60/90 minutes or the end of the current item. Live TV offers timed pauses. End-of-video timers suppress the automatic credits countdown. Timers belong to the player where they were set and are cleared when that player closes.
- **Download planning:** Album, artist, show, season, and playlist previews show aggregate file size or a bitrate-based estimate, unknown sizes, and available device storage. Duplicate playlist entries count once toward storage. Estimates describe the full selection; existing downloads are reused. Context-menu group downloads also open the preview.
- **Live TV:** The in-player channel switcher has All/Favorites/Recent filters, search, current and next program listings, and swipe-to-favorite. The last eight channels persist separately for each server.
- **Playback preferences:** Settings → Playback → Music & Watch Preferences separates music bitrate and cellular streaming from video/Live TV quality and cellular streaming. AVURLAsset enforces the cellular policy; downloaded files remain playable.
- **Home customization:** Open the profile icon → Customize Home to reorder or hide sections and restore defaults. Layouts are saved separately for mode, profile, and server.
- **Device handoff:** Now Playing and the video player menu can send the current item and position to compatible Plex players discovered by the server. Commands go through the authenticated server; tokens are not sent to arbitrary client URLs. Local playback pauses only after command acceptance. The same sheet includes Apple's AirPlay route picker. Live TV supports AirPlay through its native player.

Playlist editing and artwork selection follow the [PlexAPI playlist implementation](https://python-plexapi.readthedocs.io/en/latest/_modules/plexapi/playlist.html) and [poster resource implementation](https://python-plexapi.readthedocs.io/en/latest/_modules/plexapi/media.html). Handoff follows the [Plex companion client implementation](https://python-plexapi.readthedocs.io/en/latest/_modules/plexapi/client.html). Device support, server permissions, and Plex transcoder availability determine which remote actions succeed; errors remain visible and local playback is retained when handoff is rejected.

Regression coverage includes favorites isolation and persistence, home-layout repair, independent playback settings, repeat boundaries, multi-field song search, duplicate download accounting, playlist occurrence IDs, audio bitrate requests, sleep-timer ownership, and handoff request/error handling. Authenticated artwork upload, DVR switching, and playback on a second physical device still require end-to-end verification with a Plex account and server.

Validation: the final iPhone 17 Pro simulator build passed all 92 tests with no compiler or runtime warnings. `git diff --check` passed.

Page titles now share a single compact navigation row with page actions. They use Home's large bold typography, align left, and explicitly retain their intrinsic size so iOS does not collapse them into an overflow menu. iOS 26 title backgrounds are hidden. A simulator rendering regression checks Library, Downloads, and Search title visibility with text recognition, left alignment, and single-row placement. The full suite passes 93 tests.
