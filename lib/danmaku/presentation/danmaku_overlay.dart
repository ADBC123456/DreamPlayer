/// Danmaku overlay widget (任务 .trellis/tasks/09-04-danmaku-source-series-scrape).
///
/// Layer contract (requirement 10): 视频 -> 弹幕 -> 字幕/控制层 — this widget
/// renders ONLY the danmaku band; the player screen stacks it above the video
/// platform view and below the subtitle/controls layers.
///
/// Rendering contract (requirement 9): the canvas is wrapped in
/// `RepaintBoundary` + `IgnorePointer`, so it neither repaints the video
/// layer nor steals touches.
///
/// Clock contract (requirement 1): the media position carried by the player
/// event stream is the ONLY clock. No Timer/Ticker is created here — the
/// canvas package runs its own frame-driven animation between snapshots and
/// is paused/resumed by the engine from the snapshots (requirement 11: no
/// timers/subscriptions leak from this widget).
library;

import 'dart:async';

import 'package:danmaku_canvas/danmaku_canvas.dart' as canvas;
import 'package:flutter/material.dart';

import '../engine/canvas_engine.dart';
import '../models/danmaku_models.dart';
import '../pipeline/danmaku_session.dart';

/// Media-clock snapshot derived from an [ExoPlayerEvent] (helper kept here so
/// the player screen does not import the pipeline models directly).
DanmakuClockSnapshot snapshotFromPlayerEvent(
  dynamic event, {
  required double rate,
  required int seekRevision,
}) {
  // Duck-typed to avoid importing exo_player.dart here (agent boundary).
  final positionMs = (event.positionMs as num?)?.toInt() ?? 0;
  final durationMs = (event.durationMs as num?)?.toInt() ?? 0;
  return DanmakuClockSnapshot(
    positionSeconds: positionMs / 1000.0,
    durationSeconds: durationMs / 1000.0,
    rate: rate,
    isPlaying: event.playing == true,
    buffering: event.buffering == true,
    seekRevision: seekRevision,
  );
}

/// Widget wrapping the canvas renderer with the player clock.
class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    required this.events,
    required this.initial,
    this.option,
    this.onControllerReady,
    super.key,
  });

  /// Player event stream mapped to [DanmakuClockSnapshot] by the host
  /// (player screen). Drives the whole timeline.
  final Stream<DanmakuClockSnapshot> events;

  /// The latest known snapshot (avoids a blank window before the first event).
  final DanmakuClockSnapshot initial;

  /// Initial display options.
  final canvas.DanmakuOption? option;

  /// Exposes the canvas controller for user options (font size, area, hide
  /// switches, rate…).
  final void Function(canvas.DanmakuController controller)? onControllerReady;

  @override
  State<DanmakuOverlay> createState() => DanmakuOverlayState();
}

class DanmakuOverlayState extends State<DanmakuOverlay> {
  StreamSubscription<DanmakuClockSnapshot>? _sub;
  late DanmakuClockSnapshot _clock;

  DanmakuSession? _session;
  CanvasDanmakuEngine? _engine;

  @override
  void initState() {
    super.initState();
    _clock = widget.initial;
    _sub = widget.events.listen(_onClockEvent);
  }

  void _onClockEvent(DanmakuClockSnapshot snapshot) {
    if (!mounted) return;
    // The engine updates the canvas directly. Clock events do not change this
    // widget's layout; rebuilding here repeats track/text layout every 250 ms.
    _clock = snapshot;
    _engine?.updateClock(snapshot);
  }

  @override
  void didUpdateWidget(covariant DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.events != oldWidget.events) {
      _sub?.cancel();
      _sub = widget.events.listen(_onClockEvent);
    }
    if (widget.initial != oldWidget.initial) {
      _clock = widget.initial;
    }
    if (widget.option != oldWidget.option && widget.option != null) {
      _engine?.updateOption(widget.option!);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    _engine?.dispose();
    _engine = null;
    _session = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: IgnorePointer(
        child: RepaintBoundary(
          child: canvas.DanmakuScreen(
            option: _effectiveOption,
            createdController: _onCanvasControllerCreated,
          ),
        ),
      ),
    );
  }

  canvas.DanmakuOption get _effectiveOption =>
      widget.option ?? canvas.DanmakuOption();

  void _onCanvasControllerCreated(canvas.DanmakuController controller) {
    if (_engine != null) return; // DanmakuScreen may re-create on rebuild.
    final session = DanmakuSession();
    final engine = CanvasDanmakuEngine(
      session: session,
      controller: controller,
    );
    if (widget.option != null) {
      engine.updateOption(widget.option!);
    }
    // DanmakuScreen fires createdController from its own initState (during
    // build) — never setState() here; plain assignment is safe because the
    // engine does not affect this widget's build output.
    _session = session;
    _engine = engine;
    widget.onControllerReady?.call(controller);
    // Prime the current window so a mid-video mount shows the live danmaku.
    engine.updateClock(_clock);
  }

  /// Forwards a user seek to the pipeline (used by the host when the seek
  /// happens outside the normal event flow, e.g. scrubber release while
  /// paused).
  void seekTo(double positionSeconds) {
    _engine?.onSeek(positionSeconds);
  }

  /// Replaces the danmaku set (e.g. after an async scrape finished).
  void setItems(List<DanmakuItemModel> items) {
    _engine?.setItems(items);
  }

  /// Visible for tests.
  @visibleForTesting
  bool get isEngineReady => _engine != null;

  @visibleForTesting
  DanmakuSession? get debugSession => _session;

  @visibleForTesting
  DanmakuClockSnapshot get debugClock => _clock;
}
