/// Canvas engine: adapts the [DanmakuSession] pipeline to the bundled
/// `danmaku_canvas` package renderer
/// (任务 .trellis/tasks/09-04-danmaku-source-series-scrape).
///
/// Owns the `DanmakuController` calls only — no Timers, no streams. The
/// overlay widget drives `updateClock` from player events; the engine maps
/// render frames to `addDanmaku`/`clear`/`pause`/`resume`.
///
/// Pause/seek/rate semantics live in the session; the canvas package's own
/// wall-clock lifetime tracking for top/bottom items is kept frozen by
/// `controller.pause()` while the media is paused (requirement 4) — both
/// clocks stop together, so nothing expires invisibly.
library;

import 'package:danmaku_canvas/danmaku_canvas.dart' as canvas;
import 'package:flutter/material.dart' show Color;

import '../models/danmaku_models.dart';
import '../pipeline/danmaku_session.dart';
import '../pipeline/danmaku_timeline.dart' show ActiveDanmaku;

/// Bridges pipeline frames to the canvas renderer.
class CanvasDanmakuEngine {
  CanvasDanmakuEngine({
    required this.session,
    required this.controller,
    this.maxTextLength = 100,
  }) {
    controller.updateOption(_option);
  }

  final DanmakuSession session;
  final canvas.DanmakuController controller;
  final int maxTextLength;

  /// Canvas display options owned by the engine; the overlay/user settings
  /// replace fields via [updateOption].
  canvas.DanmakuOption _option = canvas.DanmakuOption(
    // Playback rate is re-applied on every clock snapshot (requirement 5:
    // rate changes re-time motion, never re-request data).
    playbackRate: 1.0,
  );

  bool _disposed = false;

  /// Last pause/resume state pushed into the canvas; starts null so the
  /// first snapshot always syncs the real state (no false resume).
  bool? _lastCanvasRunning;

  /// Current display options (test/debug visibility).
  canvas.DanmakuOption get debugOption => _option;

  /// Feed a new clock snapshot (from the player event stream). Returns true
  /// when the frame produced renderer mutations.
  bool updateClock(DanmakuClockSnapshot snapshot) {
    if (_disposed) return false;

    // Pause/resume the canvas in lockstep with the media (requirement 4) and
    // re-time motion with the current rate (requirement 5).
    _syncRunning(snapshot);
    _syncRate(snapshot);

    final frame = session.updateClock(snapshot);

    var mutated = false;
    if (frame.seeked) {
      // Seek: clear the canvas, then re-place the restored window at their
      // mid-flight progress (requirement 3).
      controller.clear();
      mutated = true;
    }
    for (final active in frame.restored) {
      mutated = _place(active, frame.clock) || mutated;
    }
    for (final item in frame.shown) {
      mutated = _placeItem(item, frame.clock) || mutated;
    }
    // Retry overflow only while actually playing (never while paused).
    if (snapshot.isPlaying && !snapshot.buffering) {
      for (final item in session.drainOverflow(snapshot.positionSeconds)) {
        mutated = _placeItem(item, frame.clock) || mutated;
      }
    }
    return mutated;
  }

  bool _placeItem(DanmakuItemModel item, DanmakuClockSnapshot clock) {
    if (_disposed) return false;
    // Progress at placement: restored items are mid-flight, fresh ones are 0.
    final elapsed = (clock.positionSeconds - item.time)
        .clamp(0.0, session.durationFor(item))
        .toDouble();
    return _placeAt(item, elapsed);
  }

  bool _place(ActiveDanmaku active, DanmakuClockSnapshot clock) {
    if (_disposed) return false;
    final elapsed =
        active.progressAt(clock.positionSeconds) * active.durationSeconds;
    return _placeAt(active.item, elapsed);
  }

  bool _placeAt(DanmakuItemModel item, double elapsedSeconds) {
    final placed = controller.addDanmaku(
      _toContent(item),
      initialProgress: elapsedSeconds / session.durationFor(item),
      elapsedSeconds: elapsedSeconds,
    );
    if (!placed) {
      // Tracks full: ask the session to retry once when the clock moves on.
      session.reportOverflow(item);
    }
    return placed;
  }

  void _syncRunning(DanmakuClockSnapshot snapshot) {
    final running = snapshot.isPlaying && !snapshot.buffering;
    if (running == _lastCanvasRunning) return;
    _lastCanvasRunning = running;
    if (running) {
      controller.resume();
    } else {
      controller.pause();
    }
  }

  void _syncRate(DanmakuClockSnapshot snapshot) {
    final rate = snapshot.rate > 0 ? snapshot.rate : 1.0;
    if (rate == _option.playbackRate) return;
    _option = _option.copyWith(playbackRate: rate);
    controller.updateOption(_option);
  }

  canvas.DanmakuContentItem _toContent(DanmakuItemModel item) {
    final text = item.text.length <= maxTextLength
        ? item.text
        : item.text.substring(0, maxTextLength);
    final color = Color(item.color | 0xFF000000);
    return canvas.DanmakuContentItem(
      text,
      color: color,
      type: switch (item.type) {
        DanmakuType.top => canvas.DanmakuItemType.top,
        DanmakuType.bottom => canvas.DanmakuItemType.bottom,
        _ => canvas.DanmakuItemType.scroll,
      },
    );
  }

  /// Explicit seek from the player (scrubber, ±10 s, chapter jump).
  void onSeek(double positionSeconds, {int? seekRevision}) {
    if (_disposed) return;
    session.onSeek(positionSeconds, seekRevision: seekRevision);
    // Re-place the restored window immediately (the next event snapshot will
    // confirm), so a paused seek still shows the live window.
    final frame = session.updateClock(session.clock);
    for (final active in frame.restored) {
      _place(active, frame.clock);
    }
  }

  /// Replaces the item set and re-drives the current clock window.
  void setItems(List<DanmakuItemModel> items) {
    if (_disposed) return;
    session.setItems(items);
    controller.clear();
    if (session.clock.positionSeconds > 0) {
      final frame = session.updateClock(session.clock);
      for (final active in frame.restored) {
        _place(active, frame.clock);
      }
    }
  }

  /// Applies user display options (font/area/hide switches…). Rate is
  /// managed by [updateClock]; a caller-provided rate is accepted too (UI
  /// knows the rate before the first event lands).
  void updateOption(canvas.DanmakuOption option) {
    if (_disposed) return;
    _option = option;
    controller.updateOption(option);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    controller.clear();
    session.dispose();
  }
}
