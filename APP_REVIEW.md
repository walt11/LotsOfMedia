# LotsOfMedia app review — October 5, 2026

**Fix status — October 5, 2026:** All 15 findings below have been addressed in the working tree. The findings retain their original descriptions as review history; the resolution notes below describe the current implementation.

**Final validation:** The app builds and all 60 tests pass on iPhone 17 Pro Simulator (iOS 26.5), including 22 new regression tests. The three download failures reproduced during review now pass. The final build emitted no compiler warnings, and `git diff --check` passes. Results: `/private/tmp/LotsOfMediaFixBuild/Logs/Test/Test-LotsOfMedia-2026.10.05_16-40-19--0500.xcresult`.

**Implemented changes**

| Findings | Resolution |
| --- | --- |
| 1 | Prepare the new user and discovered credentials before committing a session; replace rather than merge manual credentials across users; reject responses from old sessions and removed servers. Profile changes stop audio and pause transfers. |
| 2–4 | Keep the full-file fallback outside segment cleanup, check its adoption, recognize completed assembly before truncating, and reject malformed/missing ranges and incorrect body lengths. |
| 5–6 | Persist per-user progress with revision IDs, migrate legacy pending data, capture the playback owner, and acknowledge only the revision actually sent. Synced local data does not override fresher server resume positions. |
| 7, 15 | Serialize next-item transitions by playback request and bound final-report waits even when the report ignores cancellation. |
| 8 | Persist an explicit recovery conversion flag and disable direct stream copying for the replacement, so the server re-encodes the unplayable media. |
| 9 | Reset pagination generations when filters change and reject old page completions. |
| 10, 13 | Preserve each downloaded track’s server in queues, group by stable server/media identity, and clear the prior player item before selecting an unavailable track. |
| 11 | Fetch all playlist pages, including servers that cap page size, and fail visibly on premature empty pages. |
| 12, 14 | Preserve guide errors, scope recording and auto-download keys by server, migrate existing plans, and reconcile only the refreshed server’s recordings. |

Also fixed the ImageLoader concurrency warning, exposed download/mark-watched errors, and corrected the README’s stale feature limitations.

Runtime acceptance of authenticated Plex/Home switching, physical-device background transfers, tuner playback, AirPlay/PiP, CarPlay, VoiceOver, and large Dynamic Type remains outstanding. Simulator unit tests do not establish those behaviors. Simulator was not available through the native UI automation app inventory, so no visual acceptance pass is claimed.

---

Reviewed the current working tree across account/session handling, server discovery, browsing, downloads and persistence, audio/video and subtitles, Live TV/DVR, CarPlay, and Live Activities. This is a source review with simulator unit testing, not a complete authenticated device/UI acceptance test. No live Plex account, tuner, physical-device background transfer, AirPlay, or CarPlay session was exercised.

**Original review validation:** The existing suite passed all 38 tests on iPhone 17 Pro Simulator, iOS 26.5. Three additional checks in a temporary source copy each reproduced a download defect. At the original review stage, no production source or existing tests were edited. The subsequent fixes and regression tests are now in the working tree.

**Prioritized findings**

1. **[P1] A Home-user switch can retain the previous user’s server credentials.** [Source](/Users/walt/Desktop/LotsOfMedia/LotsOfMedia/App/AppState.swift:230)

   Switching commits the new account/user before discovery completes. If discovery fails, refreshServers keeps the old ServerDirectory, including its access tokens, and connect uses them under the new profile. Separately, ServerDirectory.setDiscovered (line 30) preserves manual servers absent from the new user’s discovery, including owner tokens. A restricted profile can therefore retain access under the previous account.

   Suggested fix: Treat user changes as an atomic session transition. Scope cached credentials to the user; do not reuse another user’s cache on discovery failure. Reauthorize manual servers explicitly.

2. **[P2] Whole-file download fallback deletes the file it needs.** [Source](/Users/walt/Desktop/LotsOfMedia/LotsOfMedia/Downloads/DownloadManager.swift:843)

   When a ranged transfer receives the full file, validation saves it as seg_whole. The completion handler calls removeSegmentFiles, which deletes every seg_ file, before moving seg_whole to seg_0. The move error is suppressed and assembly proceeds with missing data, causing verification failure and a fresh download.

   Suggested fix: Move the whole file outside the cleanup set first, check the move result, and then adopt it. Confirmed by isolated regression check.

3. **[P2] A crash at assembly completion destroys the finished file on restart.** [Source](/Users/walt/Desktop/LotsOfMedia/LotsOfMedia/Downloads/DownloadSessionDelegate.swift:229)

   Assembler removes its checkpoint before DownloadManager persists the completed state. A termination in that window leaves the record assembling, the completed media file present, and no segments or checkpoint. Retrying assembly sees zero completed segments, truncates the final file to zero at line 207, and throws for missing segment 0. The engine must download the file again.

   Suggested fix: Retain the checkpoint until completion is durably persisted, or recognize and validate the completed output before truncating. Confirmed by rerunning assembly: output changed from 200 bytes to 0.

4. **[P2] Range validation accepts an unverifiable response.** [Source](/Users/walt/Desktop/LotsOfMedia/LotsOfMedia/Downloads/DownloadSessionDelegate.swift:132)

   A ranged HTTP 206 response with a missing or malformed Content-Range bypasses the range checks and is accepted if its body is long enough. Its bytes need not belong at the requested offset. The assembler only verifies size, so a corrupt file can be marked completed. The parsed range end is also not checked.

   Suggested fix: Require a valid Content-Range for ranged requests and validate offsets and body length consistently. Missing-header acceptance was confirmed by an isolated regression check.

5. **[P2] One user’s offline progress overwrites another user’s pending progress.** [Source](/Users/walt/Desktop/LotsOfMedia/LotsOfMedia/Downloads/DownloadManager.swift:611)

   Each download has only one pending offset, watched flag, and user ID. If user A watches offline and user B then watches the same shared download before A syncs, B overwrites A’s offset and user ID. If A finished the item, offlineWatched remains true when B only watches its beginning, so B can also receive A’s watched status. AppState.playRequest uses pending progress without checking its owner.

   Suggested fix: Store playback progress separately by user, server, and rating key. Attribute updates to the playback session’s captured user, and scope resume positions the same way.

6. **[P2] Sync acknowledges newer progress that it never sent.** [Source](/Users/walt/Desktop/LotsOfMedia/LotsOfMedia/Downloads/DownloadManager.swift:635)

   syncOfflineProgress snapshots a record and awaits a network request. Playback can update that record during the await. On success the sync unconditionally clears pendingSync and offlineWatched on the current record, losing the newer unsent update. This can also clear an update from a user switched in during the request.

   Suggested fix: Attach a revision to progress and clear only the exact user/revision successfully sent; leave newer updates pending.

7. **[P2] The next-episode countdown can skip multiple episodes.** [Source](/Users/walt/Desktop/LotsOfMedia/LotsOfMedia/Playback/VideoPlayback.swift:291)

   After the countdown reaches zero, every periodic tick schedules advance while the current credits continue. advance awaits the timeline request before consuming the queue and has no in-flight guard. With a slow request, several advances can accumulate and each remove another episode; an end notification can add another advance too.

   Suggested fix: Guard the entire transition before its first await, stop the countdown immediately, and validate the originating playback request before advancing.

8. **[P2] “Download Playable Version” can download the same unplayable file again.** [Source](/Users/walt/Desktop/LotsOfMedia/LotsOfMedia/Downloads/DownloadManager.swift:593)

   The recovery action deletes the download and queues Original quality. Preparation uses the same codec/container heuristic as before. When a file passed that heuristic but AVPlayer rejected its actual profile or contents, this action selects the same original again instead of forcing conversion.

   Suggested fix: Persist an explicit force-conversion request for this recovery path; preserve the old file until the replacement is viable where possible.

9. **[P2] Changing a library filter during paging can leave old or empty results.** [Source](/Users/walt/Desktop/LotsOfMedia/LotsOfMedia/UI/BrowseViews.swift:485)

   reload clears the list but loadMore immediately returns if an older page is still loading. The old request can later append results for the prior sort/filter/mode, or cancellation can leave the new list empty with no replacement request. The visible controls then do not match the data.

   Suggested fix: Give each query a generation or owned task; cancel/discard older generations and always start a fresh first page for the new query.

10. **[P2] Downloaded music from multiple servers loses its server identity.** [Source](/Users/walt/Desktop/LotsOfMedia/LotsOfMedia/CarPlay/CarPlaySceneDelegate.swift:96)

   CarPlay collects tracks from all servers but gives Shuffle All the first record’s server ID. Artist groups do the same. AudioPlayer then assigns that one server to every queue entry, so tracks from another server fail offline or resolve to a different item when rating keys collide. OfflineGroupView also groups by title alone and CompletedDownloadRow passes its siblings with one server ID.

   Suggested fix: Build queues from entries carrying individual server IDs and group downloads using server plus stable show/artist IDs rather than titles.

11. **[P2] Large playlists are silently truncated.** [Source](/Users/walt/Desktop/LotsOfMedia/LotsOfMedia/UI/BrowseViews.swift:807)

   PlaylistDetailView fetches only the first 1,000 items and does not paginate. Play and download actions operate on this truncated array. CarPlay similarly fetches only 500 playlist items. Larger playlists therefore cannot be played or downloaded in full through these paths.

   Suggested fix: Follow totalSize and fetch all pages for whole-playlist actions; progressively paginate the visible list.

12. **[P2] Live guide errors are erased immediately.** [Source](/Users/walt/Desktop/LotsOfMedia/LotsOfMedia/LiveTV/LiveTVStore.swift:76)

   reloadGuide catches a failed grid request and sets a useful error. Its caller then unconditionally sets error to nil. DVR discovery can succeed while the guide fails, leaving an empty guide without the reason or clear recovery feedback.

   Suggested fix: Propagate the guide result/error to refresh, or clear the old error before starting work rather than after a caught failure.

13. **[P2] Selecting unavailable music can keep the previous track playing.** [Source](/Users/walt/Desktop/LotsOfMedia/LotsOfMedia/Playback/AudioPlayer.swift:150)

   skip updates queue index and timing before load resolves a URL. If the selected track has no local file and no server API, load returns without pausing or clearing the old AVPlayerItem. The UI now identifies the new track while audio and subsequent timeline positions come from the old one.

   Suggested fix: Stop/clear the previous item when committing the queue transition, and explicitly skip or present the unavailable entry state.

14. **[P2] DVR completion tracking mixes different servers.** [Source](/Users/walt/Desktop/LotsOfMedia/LotsOfMedia/LiveTV/LiveTVStore.swift:199)

   tracked is one persisted dictionary keyed only by grab ID. Refreshing a second server compares its schedule against the first server’s entries, removes missing entries, and can announce them as finished once their scheduled end is near. Server-local ID collisions can overwrite entries. Auto-download plans are likewise keyed only by show GUID.

   Suggested fix: Partition tracking and auto-download plans by server, and only reconcile entries belonging to the refreshed server.

15. **[P2] The four-second playback shutdown timeout does not bound the wait.** [Source](/Users/walt/Desktop/LotsOfMedia/LotsOfMedia/Playback/VideoPlayback.swift:520)

   After the timer wins, group.cancelAll cancels the child waiting on final.value, but does not cancel the separate detached final task. That child still awaits its completion, and the task-group scope waits for its children. Consequently playbackEnded and refresh can remain delayed until the timeline request completes rather than the advertised four seconds.

   Suggested fix: Make the network reporting work itself cancellation-aware and owned by the timeout operation, or detach the UI refresh from its completion.

**Additional improvements**

- Add integration tests for session changes, async pagination, progress synchronization, queue transitions, and the download completion handler. Existing tests cover helpers and response models but missed the three reproduced lifecycle failures.
- Surface failed group-download and mark-watched actions. DownloadActions.download and AppState.markWatched currently swallow errors, so a tap can appear to do nothing.
- Address the compiler warning in ImageLoader.cached (line 23): its nonisolated method references actor-isolated memory. The compiler identifies this as an error under Swift 6 language mode.
- Reconcile README limitations with the implementation: it says Live TV/DVR is unimplemented and external subtitles are not downloaded, despite implementation and feature descriptions for both.
- Add a focused UI acceptance pass for VoiceOver, large Dynamic Type, landscape/iPad layout, long titles, and error/retry states. These need runtime visual verification before calling them defects.

**Reproduction artifacts**

- Temporary source/tests: `/private/tmp/LotsOfMediaReviewSource/LotsOfMediaTests/DownloadEngineTests.swift` (ReviewRegressionTests).
- Baseline results: `/private/tmp/LotsOfMediaReviewBuild/Logs/Test/`.
- Regression results: `/private/tmp/LotsOfMediaReviewRegression/Logs/Test/`.

P1 = address first because it affects user access boundaries. P2 = a concrete functional/data-integrity defect triggered by the described scenario. Source-traced findings other than the three download regressions still need integration reproduction against appropriate app/server fixtures.
