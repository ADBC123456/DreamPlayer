// Engine tests: CanvasDanmakuEngine bridging session frames to the canvas
// renderer with a fake DanmakuController
// (任务 .trellis/tasks/09-04-danmaku-source-series-scrape).
import 'package:danmaku_canvas/danmaku_canvas.dart' as canvas;
import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/danmaku/engine/canvas_engine.dart';
import 'package:dream_player/danmaku/models/danmaku_models.dart';
import 'package:dream_player/danmaku/pipeline/danmaku_session.dart';

/// Records every controller call without any real rendering. Extends the
/// real [canvas.DanmakuController] with no-op callbacks so the engine runs
/// against the production type.
class FakeCanvasController extends canvas.DanmakuController {
  FakeCanvasController()
    : super(
        onAddDanmaku:
            (_, {required initialProgress, required elapsedSeconds}) => true,
        onUpdateOption: (_) {},
        onPause: () {},
        onResume: () {},
        onClear: () {},
      );

  final List<String> log = [];
  final List<(String, double, double)> added = [];
  int cleared = 0;
  int pauses = 0;
  int resumes = 0;

  // When true, addDanmaku reports "tracks full".
  bool tracksFull = false;

  @override
  bool addDanmaku(
    content, {
    double initialProgress = 0,
    double elapsedSeconds = 0,
  }) {
    if (tracksFull) return false;
    added.add((content.text, initialProgress, elapsedSeconds));
    log.add('add:${content.text}');
    return true;
  }

  @override
  void clear() {
    cleared++;
    log.add('clear');
  }

  @override
  void pause() {
    pauses++;
    log.add('pause');
  }

  @override
  void resume() {
    resumes++;
    log.add('resume');
  }

  @override
  void updateOption(option) {
    log.add('option:${option.playbackRate}');
  }
}

DanmakuClockSnapshot snap(
  double pos, {
  bool playing = true,
  bool buffering = false,
  double rate = 1.0,
  int rev = 0,
}) => DanmakuClockSnapshot(
  positionSeconds: pos,
  durationSeconds: 600,
  rate: rate,
  isPlaying: playing,
  buffering: buffering,
  seekRevision: rev,
);

void main() {
  test('engine pauses canvas when media pauses and resumes with it', () {
    final controller = FakeCanvasController();
    final engine = CanvasDanmakuEngine(
      session: DanmakuSession(),
      controller: controller,
    );
    engine.updateClock(snap(1));
    expect(controller.pauses, 0);
    expect(controller.resumes, 1);

    engine.updateClock(snap(1.25, playing: false));
    expect(controller.pauses, 1);
    expect(controller.resumes, 1);

    engine.updateClock(snap(1.5, playing: false));
    expect(controller.pauses, 1); // no repeated pause calls
    engine.updateClock(snap(1.75));
    expect(controller.resumes, 2);
  });

  test('engine clears canvas and re-places window on seek', () {
    final controller = FakeCanvasController();
    final session = DanmakuSession()
      ..setItems([
        const DanmakuItemModel(time: 30, text: 'live'),
        const DanmakuItemModel(time: 25, text: 'restored'),
      ]);
    final engine = CanvasDanmakuEngine(
      session: session,
      controller: controller,
    );

    // Baseline + play across 30.
    var t = 0.0;
    while (t < 30.25) {
      t = (t + 0.25).clamp(0.0, 30.25);
      engine.updateClock(snap(t));
    }
    final clearsBefore = controller.cleared;
    expect(controller.added.map((a) => a.$1), contains('live'));

    // Seek back to 26: 'restored'(25) is 1s behind → re-placed at progress.
    final clears = controller.cleared;
    engine.updateClock(snap(26, rev: 1));
    expect(controller.cleared, clears + 1);
    expect(clears, greaterThanOrEqualTo(clearsBefore));
    // 'restored' re-added at mid-flight progress (1s into a 9s traversal).
    final restoredAdd = controller.added.lastWhere((a) => a.$1 == 'restored');
    expect(restoredAdd.$2, closeTo(1 / 9, 0.02));
  });

  test('engine reports rate changes to canvas as option updates only', () {
    final controller = FakeCanvasController();
    final engine = CanvasDanmakuEngine(
      session: DanmakuSession(),
      controller: controller,
    );
    engine.updateClock(snap(1, rate: 1.0));
    engine.updateClock(snap(1.25, rate: 2.0));
    expect(controller.log.where((l) => l.startsWith('option:2.0')), isNotEmpty);
    // No re-request / re-clear on rate change (requirement 5).
    expect(controller.cleared, 0);
  });

  test('track-full: engine retries overflow once on the next clock step', () {
    final controller = FakeCanvasController();
    final session = DanmakuSession()
      ..setItems([const DanmakuItemModel(time: 2, text: 'busy')]);
    final engine = CanvasDanmakuEngine(
      session: session,
      controller: controller,
    );

    controller.tracksFull = true;
    engine.updateClock(snap(1));
    engine.updateClock(snap(2.25));
    expect(controller.added.where((a) => a.$1 == 'busy'), isEmpty);

    // Tracks free again: the very next step retries and places it.
    controller.tracksFull = false;
    engine.updateClock(snap(2.5));
    expect(controller.added.map((a) => a.$1), contains('busy'));
  });

  test('engine dispose clears canvas and freezes the session', () {
    final controller = FakeCanvasController();
    final session = DanmakuSession()
      ..setItems([const DanmakuItemModel(time: 2, text: 'x')]);
    final engine = CanvasDanmakuEngine(
      session: session,
      controller: controller,
    );
    engine.updateClock(snap(1));
    engine.dispose();
    expect(controller.cleared, greaterThanOrEqualTo(1));
    expect(session.isDisposed, isTrue);
    final mutated = engine.updateClock(snap(5));
    expect(mutated, isFalse);
  });
}
