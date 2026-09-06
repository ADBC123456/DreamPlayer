/// Playback-bound danmaku session (任务 .trellis/tasks/09-04-danmaku-source-series-scrape).
///
/// Bridges player clock snapshots to the danmaku timeline:
///  - `updateClock` is the ONLY entry point driving time (requirement 1);
///  - large jumps / seek-revision changes clear active danmaku and restore
///    the ~10–12 s look-back window (requirement 3);
///  - while paused/buffering nothing is consumed — top/bottom lifetimes and
///    scroll progress freeze (requirement 4);
///  - rate changes only re-time the renderer; data is never re-requested
///    (requirement 5);
///  - no Timers/subscriptions are owned here; `dispose` is idempotent.
library;

import 'dart:collection';

import '../models/danmaku_models.dart';
import 'danmaku_timeline.dart';

/// Duration a scroll danmaku takes to cross the screen (media seconds).
const double kScrollDurationSeconds = 9.0;

/// Duration top/bottom danmaku stay on screen (media seconds).
const double kStaticDurationSeconds = 6.0;

/// What the engine/render layer receives for one clock step.
class DanmakuRenderFrame {
  const DanmakuRenderFrame({
    required this.clock,
    this.shown = const [],
    this.expired = const [],
    this.restored = const [],
    this.seeked = false,
  });

  final DanmakuClockSnapshot clock;

  /// Danmaku whose schedule time was crossed this step; engine places them
  /// on free tracks.
  final List<DanmakuItemModel> shown;

  /// Danmaku past their lifetime this step; engine removes them.
  final List<ActiveDanmaku> expired;

  /// Danmaku resurrected after a seek (already mid-flight); engine re-places
  /// them at [ActiveDanmaku.progressAt] progress.
  final List<ActiveDanmaku> restored;

  /// True when this frame follows a seek (engine may also clear its tracks).
  final bool seeked;
}

class DanmakuSession {
  DanmakuSession({
    this.lookBackSeconds = DanmakuTimeline.defaultLookBack,
    this.scrollDurationSeconds = kScrollDurationSeconds,
    this.staticDurationSeconds = kStaticDurationSeconds,
    DanmakuFilter? filter,
  }) : filter = filter ?? DanmakuFilter();

  final double lookBackSeconds;
  final double scrollDurationSeconds;
  final double staticDurationSeconds;
  DanmakuFilter filter;

  final DanmakuTimeline _timeline = DanmakuTimeline();
  final DanmakuDedupState _dedup = DanmakuDedupState();

  DanmakuClockSnapshot _clock = const DanmakuClockSnapshot(positionSeconds: 0);
  bool _hasClock = false;
  bool _disposed = false;

  /// Suppressed because every track was busy; freed when the clock moves.
  final Queue<DanmakuItemModel> _overflow = Queue<DanmakuItemModel>();

  DanmakuClockSnapshot get clock => _clock;
  bool get hasItems => _timeline.itemCount > 0;
  int get itemCount => _timeline.itemCount;
  int get activeCount => _timeline.activeCount;
  List<ActiveDanmaku> get active => _timeline.active;
  bool get isDisposed => _disposed;

  /// Duration callback for a scheduled item (lets tests/engine vary per type).
  double durationFor(DanmakuItemModel item) => switch (item.type) {
    DanmakuType.scroll => scrollDurationSeconds,
    DanmakuType.top || DanmakuType.bottom => staticDurationSeconds,
    DanmakuType.special => staticDurationSeconds,
  };

  /// Replaces the danmaku set (already sorted by the caller or sorted here).
  /// Pure data swap — no timers, no subscriptions.
  void setItems(List<DanmakuItemModel> items) {
    if (_disposed) return;
    _timeline.setItems(items);
    _dedup.clear();
    _overflow.clear();
    // Re-drive the current clock so the look-back window repopulates.
    if (_hasClock) {
      _restoreWindow(_clock.positionSeconds);
    }
  }

  /// Explicit seek from the player (scrubber, ±10 s, chapter jump).
  void onSeek(double positionSeconds, {int? seekRevision}) {
    if (_disposed) return;
    _clock = DanmakuClockSnapshot(
      positionSeconds: positionSeconds,
      durationSeconds: _clock.durationSeconds,
      rate: _clock.rate,
      isPlaying: _clock.isPlaying,
      buffering: _clock.buffering,
      seekRevision: seekRevision ?? _clock.seekRevision + 1,
    );
    _restoreWindow(positionSeconds);
  }

  /// Pseudocode implemented (requirement 12):
  /// ```
  /// void updateClock(snapshot) {
  ///   if (isLargeJump(snapshot.position, lastPosition)) {
  ///     seekRevision++;
  ///     clearActive();
  ///     restoreWindow(snapshot.position);
  ///   }
  ///   clock = snapshot;
  /// }
  /// ```
  DanmakuRenderFrame updateClock(DanmakuClockSnapshot snapshot) {
    if (_disposed) {
      return DanmakuRenderFrame(clock: snapshot);
    }
    final previous = _clock;
    final first = !_hasClock;
    _clock = snapshot;
    _hasClock = true;
    final playingSnapshot = snapshot.isPlaying && !snapshot.buffering;

    // Seek detection (requirement 12): revision bump or a large position
    // jump measured against the last PLAYING position (a jump that happened
    // while paused must not consume anything itself — the restore happens
    // when playback resumes). First snapshot: nothing to seek from.
    final seeked =
        !first &&
        (previous.seekRevision != snapshot.seekRevision ||
            (playingSnapshot &&
                snapshot.isLargeJumpFrom(_lastPlayingPosition)));

    if (!playingSnapshot) {
      // Paused/buffering: consume nothing (requirement 4). Lifetimes freeze
      // because they are all derived from the media clock, which is paused.
      return DanmakuRenderFrame(clock: snapshot);
    }

    if (seeked) {
      _lastPlayingPosition = snapshot.positionSeconds;
      return _onSeekFrame(snapshot);
    }

    // First playing snapshot: baseline the clock, consume nothing yet.
    if (first || _lastPlayingPosition < 0) {
      _lastPlayingPosition = snapshot.positionSeconds;
      return DanmakuRenderFrame(clock: snapshot);
    }

    _lastPlayingPosition = snapshot.positionSeconds;
    final shown = _timeline.dueBetween(
      previous.positionSeconds,
      snapshot.positionSeconds,
    );
    return _applyDue(shown, snapshot);
  }

  double _lastPlayingPosition = -1;

  DanmakuRenderFrame _onSeekFrame(DanmakuClockSnapshot snapshot) {
    final restored = _restoreWindow(snapshot.positionSeconds);
    return DanmakuRenderFrame(
      clock: snapshot,
      restored: restored,
      seeked: true,
    );
  }

  List<ActiveDanmaku> _restoreWindow(double positionSeconds) {
    final items = _timeline.restoreWindow(positionSeconds);
    final restored = <ActiveDanmaku>[];
    for (final item in items) {
      if (_filterPasses(item)) {
        final duration = durationFor(item);
        final active = ActiveDanmaku(
          item: item,
          shownAtSeconds: item.time,
          durationSeconds: duration,
        );
        _timeline.markShown(item, item.time, duration);
        restored.add(active);
      }
    }
    return restored;
  }

  bool _filterPasses(DanmakuItemModel item) {
    // Window restore: pass through dedup (these are re-shows) but keep the
    // blocked-word/type checks.
    final lower = item.text.toLowerCase();
    for (final w in filter.blockedWords) {
      if (lower.contains(w)) return false;
    }
    return switch (item.type) {
      DanmakuType.scroll => filter.showScroll,
      DanmakuType.top => filter.showTop,
      DanmakuType.bottom => filter.showBottom,
      DanmakuType.special => true,
    };
  }

  DanmakuRenderFrame _applyDue(
    List<DanmakuItemModel> due,
    DanmakuClockSnapshot snapshot,
  ) {
    final shown = <DanmakuItemModel>[];
    for (final raw in due) {
      final item = filter.apply(raw, _dedup);
      if (item == null) continue;
      shown.add(item);
      _timeline.markShown(item, item.time, durationFor(item));
    }
    final expired = _timeline.reapExpired(snapshot.positionSeconds);
    _dedup.compact(snapshot.positionSeconds, filter.dedupWindow);
    return DanmakuRenderFrame(clock: snapshot, shown: shown, expired: expired);
  }

  /// Engine reports a danmaku could not be placed (tracks full). The session
  /// keeps it for one replay when the clock next advances (trailing overflow
  /// retry). Returns false when the queue is full (drop to bound memory).
  bool reportOverflow(DanmakuItemModel item) {
    if (_disposed || _overflow.length >= 64) return false;
    _overflow.add(item);
    return true;
  }

  /// Items parked as overflow, in schedule order (engine polls after frames).
  List<DanmakuItemModel> drainOverflow(double positionSeconds) {
    if (_overflow.isEmpty) return const [];
    final out = <DanmakuItemModel>[];
    while (_overflow.isNotEmpty && _overflow.first.time <= positionSeconds) {
      out.add(_overflow.removeFirst());
    }
    return out;
  }

  /// Clears live danmaku without touching the schedule or the clock.
  void clearActive() {
    _timeline.clearActive();
    _overflow.clear();
  }

  /// Idempotent; nothing owned (no timers, no subscriptions — requirement
  /// 11), but every stored schedule/active item is released.
  void dispose() {
    _disposed = true;
    _timeline.setItems(const []);
    clearActive();
    _dedup.clear();
  }
}
