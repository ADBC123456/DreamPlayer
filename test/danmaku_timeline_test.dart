// Unit tests for the danmaku timeline pipeline
// (任务 .trellis/tasks/09-04-danmaku-source-series-scrape).
//
// Covers: play/pause consumption, 0.5x/2x rate behavior, seek clearing +
// window restore, empty data, blocked words/type switches, dedup and max
// text length (pure filter), track-full overflow, and dispose safety.
import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/danmaku/models/danmaku_models.dart';
import 'package:dream_player/danmaku/pipeline/danmaku_session.dart';
import 'package:dream_player/danmaku/pipeline/danmaku_timeline.dart';

DanmakuItemModel scroll(double t, String text, {String? sender}) =>
    DanmakuItemModel(
      time: t,
      text: text,
      type: DanmakuType.scroll,
      senderId: sender,
    );

DanmakuItemModel top(double t, String text) =>
    DanmakuItemModel(time: t, text: text, type: DanmakuType.top);

DanmakuItemModel bottom(double t, String text) =>
    DanmakuItemModel(time: t, text: text, type: DanmakuType.bottom);

DanmakuClockSnapshot playing(double pos, {double rate = 1.0, int rev = 0}) =>
    DanmakuClockSnapshot(
      positionSeconds: pos,
      durationSeconds: 600,
      rate: rate,
      isPlaying: true,
      seekRevision: rev,
    );

DanmakuClockSnapshot paused(double pos, {double rate = 1.0, int rev = 0}) =>
    DanmakuClockSnapshot(
      positionSeconds: pos,
      durationSeconds: 600,
      rate: rate,
      isPlaying: false,
      seekRevision: rev,
    );

/// Drives the session forward with realistic ~250 ms event cadence steps
/// (matching ExoPlayerController's event rate) up to [to] seconds.
void playUp(DanmakuSession s, double from, double to, {double rate = 1.0}) {
  var t = from;
  while (t < to - 0.001) {
    final step = (t + 0.25 > to) ? to - t : 0.25;
    t += step;
    s.updateClock(playing(t, rate: rate));
  }
}

void main() {
  group('DanmakuTimeline (track scheduling)', () {
    test('lower-bound cursor consumes due items without full scans', () {
      final tl = DanmakuTimeline();
      tl.setItems([for (var i = 0; i < 1000; i++) scroll(i.toDouble(), 'd$i')]);

      // Fast-forward to 100s in one call: only item 100 becomes due in
      // (99.9, 100]; cursor must land past it.
      final due = tl.dueBetween(99.9, 100);
      expect(due, hasLength(1));
      expect(due.first.text, 'd100');
      expect(tl.cursor, 101);
    });

    test('dueBetween returns every item crossed in one big step', () {
      final tl = DanmakuTimeline();
      tl.setItems([scroll(1, 'a'), scroll(3, 'b'), scroll(5, 'c')]);
      final due = tl.dueBetween(0, 5);
      expect(due.map((d) => d.text), ['a', 'b', 'c']);
      expect(tl.cursor, 3);
    });

    test('restoreWindow returns only look-back slice and moves cursor', () {
      final tl = DanmakuTimeline();
      tl.setItems([
        scroll(1, 'early'),
        scroll(8, 'in-window'),
        scroll(11, 'edge'),
        scroll(12, 'just-after'),
        scroll(50, 'later'),
      ]);
      // Seek to 12: look-back 11 => window [1, 12] INCLUSIVE — a danmaku
      // exactly at the seek target is entering right now.
      final restored = tl.restoreWindow(12);
      expect(restored.map((d) => d.text), [
        'early',
        'in-window',
        'edge',
        'just-after',
      ]);
      expect(tl.cursor, 4);
      expect(tl.activeCount, 0); // restore only returns items; shown via mark
    });

    test('reapExpired drops only items past lifetime', () {
      final tl = DanmakuTimeline(lookBackSeconds: 11);
      tl.markShown(scroll(0, 'short'), 0, 5);
      tl.markShown(scroll(0, 'long'), 0, 30);
      expect(tl.reapExpired(4.9), isEmpty);
      final gone = tl.reapExpired(5);
      expect(gone, hasLength(1));
      expect(gone.first.item.text, 'short');
      expect(tl.activeCount, 1);
    });
  });

  group('DanmakuFilter (pure functions)', () {
    test('blocked words filter case-insensitively', () {
      final f = DanmakuFilter(blockedWords: {'spam'});
      final dedup = DanmakuDedupState();
      expect(f.apply(scroll(1, 'buy SPAM now'), dedup), isNull);
      expect(f.apply(scroll(1, 'hello'), dedup)?.text, 'hello');
    });

    test('type switches hide top/bottom/scroll independently', () {
      final f = DanmakuFilter(showTop: false, showBottom: false);
      final dedup = DanmakuDedupState();
      expect(f.apply(top(1, 't'), dedup), isNull);
      expect(f.apply(bottom(1, 'b'), dedup), isNull);
      expect(f.apply(scroll(1, 's'), dedup), isNotNull);
    });

    test('dedup drops same text within window, allows after', () {
      final f = DanmakuFilter();
      final dedup = DanmakuDedupState();
      expect(f.apply(scroll(10, '666'), dedup), isNotNull);
      expect(f.apply(scroll(12, '666'), dedup), isNull); // inside 6s window
      expect(f.apply(scroll(17, '666'), dedup), isNotNull); // outside
    });

    test('max text length clamps long text', () {
      final f = DanmakuFilter(maxTextLength: 5);
      final out = f.apply(scroll(1, 'a' * 20), DanmakuDedupState());
      expect(out!.text, 'aaaaa');
    });
  });

  group('DanmakuSession (playback-bound)', () {
    test('playing clock consumes scheduled danmaku', () {
      final s = DanmakuSession()..setItems([scroll(5, 'hit')]);
      playUp(s, 0, 5.25); // cadence steps cross 5.0
      final frame = s.updateClock(playing(5.5));
      expect(frame.shown, isEmpty); // already consumed at 5.0-5.25
      expect(s.activeCount, 1);
      expect(s.active.first.item.text, 'hit');
    });

    test('paused clock consumes nothing (top/bottom lifetimes freeze)', () {
      final s = DanmakuSession()
        ..setItems([top(5, 't'), bottom(5, 'b'), scroll(5, 's')]);
      s.updateClock(playing(4)); // baseline (before 5)
      // Position moved while paused: no consumption while paused.
      // Resuming consumes the paused gap in ONE seek-style step (4→6 is a
      // 2s jump over the large-jump threshold): the window is restored and
      // the 5s danmaku appear as restored, consumed exactly once.
      final f2 = s.updateClock(playing(6));
      expect(f2.restored.map((a) => a.item.text).toSet(), {'t', 'b', 's'});
      expect(s.activeCount, 3);
    });

    test('buffering pauses consumption like pause', () {
      final s = DanmakuSession()..setItems([scroll(5, 's')]);
      s.updateClock(playing(4));
      final buf = DanmakuClockSnapshot(
        positionSeconds: 6,
        isPlaying: true,
        buffering: true,
      );
      expect(s.updateClock(buf).shown, isEmpty);
      expect(s.activeCount, 0);
      // Resume after the stall restores the danmaku that came due across
      // it, exactly once.
      final f2 = s.updateClock(playing(6));
      expect(f2.restored.map((a) => a.item.text), ['s']);
      expect(s.activeCount, 1);
    });

    test('0.5x rate does not change which items are due', () {
      final s = DanmakuSession()..setItems([scroll(5, 'a'), scroll(9, 'b')]);
      s.updateClock(playing(0, rate: 0.5));
      // Media position advances at 0.5x wall speed, but consumption is by
      // media position — no re-request, no re-order (requirement 5).
      playUp(s, 0, 6, rate: 0.5);
      expect(s.active.map((a) => a.item.text), ['a']);
      playUp(s, 6, 10, rate: 0.5);
      expect(s.active.map((a) => a.item.text).toSet(), {'a', 'b'});
    });

    test('2x rate keeps media-clock scheduling identical', () {
      final s = DanmakuSession()..setItems([scroll(5, 'a')]);
      s.updateClock(playing(0, rate: 2.0));
      playUp(s, 0, 6, rate: 2.0);
    });

    test('seek clears active and restores ~11s window', () {
      final s = DanmakuSession()
        ..setItems([scroll(30, 'live'), scroll(22, 'still-visible')]);
      playUp(s, 0, 30.25); // 'live' shown; 'still-visible' still in lifetime
      expect(s.activeCount, 2);

      // Seek back to 24: 'live'(30) is future, 'still-visible'(22) is 2s
      // behind the clock => within look-back, restored mid-flight.
      final frame = s.updateClock(playing(24, rev: 1));
      expect(frame.seeked, isTrue);
      expect(s.activeCount, 1);
      expect(s.active.first.item.text, 'still-visible');
      expect(s.active.first.progressAt(24), closeTo(2 / 9, 0.01));
    });

    test('paused large jump re-baselines without consuming', () {
      final s = DanmakuSession()..setItems([scroll(100, 'x')]);
      s.updateClock(playing(1));
      // User seeks while paused (scrubber): big gap, paused state.
      final f1 = s.updateClock(paused(98));
      expect(f1.shown, isEmpty);
      expect(s.activeCount, 0);
      // Resume at the new position: 100 is 2s ahead — nothing consumed
      // yet; then crossing 100 shows it.
      s.updateClock(playing(98));
      expect(s.activeCount, 0);
      playUp(s, 98, 100.25);
      expect(s.activeCount, 1);
    });

    test('large jump without revision still counts as seek', () {
      final s = DanmakuSession()..setItems([scroll(100, 'far')]);
      playUp(s, 0, 1.25);
      final frame = s.updateClock(playing(100)); // +99s jump
      expect(frame.seeked, isTrue);
    });

    test('forward seek restores trailing window items', () {
      final s = DanmakuSession()..setItems([scroll(20, 'x')]);
      s.updateClock(playing(0));
      s.updateClock(playing(21)); // shown & active
      // Seek forward to 25: 20 is 5s behind => still within lifetime.
      final frame = s.updateClock(playing(25, rev: 1));
      expect(frame.seeked, isTrue);
      expect(frame.restored.map((a) => a.item.text), ['x']);
    });

    test('setItems re-drives the current window immediately', () {
      final s = DanmakuSession()..setItems(const []);
      s.updateClock(playing(50));
      expect(s.activeCount, 0);
      s.setItems([scroll(45, 'late-arrival')]);
      expect(s.activeCount, 1);
      expect(s.active.first.item.text, 'late-arrival');
    });

    test('onSeek from paused state restores window', () {
      final s = DanmakuSession()..setItems([scroll(30, 'x')]);
      s.updateClock(paused(10));
      s.onSeek(32);
      expect(s.clock.positionSeconds, 32);
      // 30 is 2s before the clock: restored.
      expect(s.active.first.item.text, 'x');
    });

    test('overflow retry: dropped item re-offered on next clock step', () {
      final s = DanmakuSession()..setItems([scroll(5, 'full-track')]);
      s.updateClock(playing(0));
      s.updateClock(playing(6)); // engine would drop; simulate report
      s.reportOverflow(scroll(5, 'full-track'));
      final drained = s.drainOverflow(6.4);
      expect(drained, hasLength(1));
      // After retry the queue is empty (one retry only).
      expect(s.drainOverflow(6.8), isEmpty);
    });

    test('empty list: no state, no crash', () {
      final s = DanmakuSession()..setItems(const []);
      s.updateClock(playing(10));
      s.updateClock(playing(20));
      s.updateClock(playing(100));
      expect(s.activeCount, 0);
      expect(s.hasItems, isFalse);
    });

    test('dispose is idempotent and freezes the timeline', () {
      final s = DanmakuSession()..setItems([scroll(5, 'x')]);
      s.updateClock(playing(0));
      s.dispose();
      s.dispose();
      final frame = s.updateClock(playing(6));
      expect(frame.shown, isEmpty);
      expect(s.isDisposed, isTrue);
      s.setItems([scroll(9, 'y')]); // ignored after dispose
      expect(s.hasItems, isFalse);
    });
  });
}
