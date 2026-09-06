# DreamPlayer Danmaku PRD

## 1. Objective

Add Bilibili-style timed comments to DreamPlayer without changing the playback
engine or blocking video startup. Users can configure one or more compatible
`danmu_api` deployments, automatically match the current video, and scrape all
episodes in the current series into an offline cache.

Android Media3, Android MPV, and iOS AetherEngine must share the same Flutter
danmaku pipeline. The media player's reported position is the only timeline
authority.

## 2. In Scope

- Scrolling, top, and bottom comments with color.
- Global and in-player show/hide controls.
- Font size, opacity, display area, traversal duration, type switches, and
  blocked words.
- Multiple user-managed `danmu_api` sources with URL, optional path token,
  enable state, priority, and connection testing.
- Cache-first automatic loading for the video being played.
- One-action scrape for every episode in the current series or season folder.
- Local files, Android SAF/library folders, SMB, WebDAV, FTP/SFTP, and
  Jellyfin enumeration where the host source supports directory listing.
- Per-episode progress, cancellation, retry-failed, and force-refresh.
- Bilibili XML and `danmu_api` JSON parsing as import/source adapters.

Sending new comments and account login are out of scope for the first release.

## 3. danmu_api Contract

A configured deployment exposes API v2 under either:

```text
{baseUrl}/api/v2/...
{baseUrl}/{token}/api/v2/...
```

Required operations:

```text
POST /match
GET  /search/episodes?anime={title}
GET  /bangumi/{animeId}
GET  /comment/{episodeId}?format=json&duration=true
POST /segmentcomment?format=json
```

`/match` receives `fileName`, optional first-16-MiB MD5 `fileHash`, optional
`fileSize`, and `matchMode`. Comment JSON is normalized to time, mode, RGB
color, text, id, and likes. Mode 1/6/7 scrolls, mode 4 is bottom, and mode 5 is
top. A match time shift must be retained and applied exactly once.

HTTP 429, 5xx, socket, and timeout failures are retryable with bounded
backoff. HTTP 401/403 and other invalid requests fail immediately. Tokens,
request bodies, and authenticated URLs must never be logged.

## 4. Playback Flow

1. Initialize source configuration independently of app startup rendering.
2. Derive a stable identity from `resumeKey`, local path, or a URL with query
   and fragment removed. Hash local readable files only.
3. Read valid cache first. On a miss, match and fetch from the selected source.
4. Open/play video immediately; all danmaku work runs beside playback.
5. Convert source comments to renderer models, filter, sort, and publish them
   to the overlay.
6. Drive the overlay from Media3 events or MPV position/state streams.
7. Increment a seek revision for every user seek, replay, chapter jump, and
   A-B loop. Pause/resume and playback rate changes update the same session.
8. Clear stale loads when the video changes or the screen is disposed.

Layer order is video, danmaku, subtitles, controls. The overlay is clipped,
wrapped in `RepaintBoundary` and `IgnorePointer`, hidden in PiP, and reserves a
subtitle-safe lower band. Native PlatformView subtitles must remain readable.

## 5. Source Settings

The Settings screen provides:

- A global danmaku switch.
- Source list with add, edit, delete, enable, and priority controls.
- Display name, base URL, and optional path token fields.
- URL validation and an explicit connection test.
- Display controls for font size, opacity, area, duration, comment types, and
  newline-separated blocked words.
- Cache clearing and a route to retry scraping where applicable.

Configuration and display settings persist across restarts. At least one
enabled source is required to turn danmaku on in the player.

## 6. Whole-Series Scrape

The details page exposes `Scrape episode danmaku` for episodic content. It
enumerates videos recursively to a bounded depth, derives season/episode data,
and fetches with concurrency 2 and a 300-500 ms per-source request gap.

Mapping priority:

1. File hash, filename, and size through `/match` when available.
2. Exact season and episode against the searched catalog.
3. Season-scoped numeric episode mapping.
4. Title similarity for OVA, OAD, and SP content.
5. Explicit no-match or user choice for ambiguous/duplicate candidates.

The implementation must never silently select the first duplicate episode or
the first unrelated anime search result.

Each row exposes one of: pending, matching, fetching, cached, success, empty,
no match, failed, or cancelled. One failed episode does not stop others.
Already cached episodes are skipped unless force-refresh is selected. Task
state survives navigation and app restart.

## 7. Cache

Entries are isolated by source id, normalized base URL, stable video identity,
and schema version. Writes use a temporary file and atomic rename. Corrupt or
incompatible entries are treated as misses. Empty matched episodes are cached
to prevent repeated requests.

Cache data includes source, base URL, video key, filename, anime/episode ids,
fetch time, optional duration, applied shift, comment count, and normalized
comments.

## 8. Acceptance Criteria

- A user can add and test a `danmu_api` source, restart the app, and retain it.
- Opening a matched episode displays synchronized comments on Media3 and MPV.
- Pause, seek, replay, rate changes, next episode, rotation, and PiP do not
  leak, duplicate, or desynchronize comments.
- The details page can scrape all episodes, cancel, retry failures, and force
  refresh while accurately reporting every terminal state.
- Duplicate/special episode ambiguity is visible and never silently resolved.
- Danmaku failures never interrupt video or subtitle playback.
- `flutter analyze` and the complete Flutter test suite pass.
- Android and iPad device checks cover PlatformView layering, HDR playback,
  subtitles, rotation, and a dense-comment performance sample.
