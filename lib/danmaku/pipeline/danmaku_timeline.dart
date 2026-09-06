/// Danmaku timeline core: clock snapshot handling, scheduling track and the
/// pure filter object (任务 .trellis/tasks/09-04-danmaku-source-series-scrape).
///
/// The primary clock is ALWAYS the media position carried by
/// [DanmakuClockSnapshot] (fed from `ExoPlayerController.events`, which pushes
/// ~4 snapshots/s while playing). No Timer drives the timeline.
library;

import 'dart:collection';

import 'package:characters/characters.dart' show StringCharacters;

import '../models/danmaku_models.dart';

/// One live danmaku the renderer is currently showing.
class ActiveDanmaku {
  ActiveDanmaku({
    required this.item,
    required this.shownAtSeconds,
    required this.durationSeconds,
  });

  final DanmakuItemModel item;

  /// Media-clock seconds at which this danmaku was handed to the renderer.
  final double shownAtSeconds;

  /// Total on-screen lifetime in media seconds (scroll traversal or static
  /// hold duration).
  final double durationSeconds;

  /// Progress through its lifetime, 0.0..1.0.
  double progressAt(double clockSeconds) => durationSeconds <= 0
      ? 1.0
      : ((clockSeconds - shownAtSeconds) / durationSeconds).clamp(0.0, 1.0);

  bool expiredAt(double clockSeconds) =>
      clockSeconds - shownAtSeconds >= durationSeconds;
}

/// Pure scheduling model for the danmaku track.
///
/// The scheduler walks a time-ordered list with a binary-search cursor
/// (requirement 6) — it never scans the full list per clock step.
class DanmakuTimeline {
  DanmakuTimeline({this.lookBackSeconds = defaultLookBack});

  /// Window restored after a seek (requirement 3): danmaku scheduled up to
  /// this many media seconds BEFORE the new clock are re-shown at their
  /// correct progress.
  static const double defaultLookBack = 11.0;

  final double lookBackSeconds;

  final List<DanmakuItemModel> _items = <DanmakuItemModel>[];

  /// Index of the first item not yet consumed; advances as the clock moves
  /// forward past an item's schedule time.
  int _cursor = 0;

  /// Live danmaku handed to the renderer, ordered by show time.
  final Queue<ActiveDanmaku> _active = Queue<ActiveDanmaku>();

  int get cursor => _cursor;

  int get itemCount => _items.length;

  int get activeCount => _active.length;

  List<ActiveDanmaku> get active => List.unmodifiable(_active);

  /// Replaces the schedule. Resets cursor & active list; the caller re-drives
  /// the clock right after, which restores the window.
  void setItems(List<DanmakuItemModel> items) {
    _items
      ..clear()
      ..addAll(items);
    _items.sort((a, b) => a.time.compareTo(b.time));
    _cursor = 0;
    _active.clear();
  }

  /// Drops every live danmaku (seek). Schedule stays; [restoreWindow] brings
  /// back the look-back slice.
  void clearActive() {
    _active.clear();
  }

  /// Re-schedules the danmaku in `[position - lookBack, position]` so a seek
  /// keeps the ones still on screen. Binary search on the sorted list, not a
  /// full scan (requirement 6).
  List<DanmakuItemModel> restoreWindow(double positionSeconds) {
    clearActive();
    if (_items.isEmpty) return const [];
    final windowStart = positionSeconds - lookBackSeconds;
    var lo = _lowerBound(windowStart - 0.001);
    final out = <DanmakuItemModel>[];
    while (lo < _items.length && _items[lo].time <= positionSeconds) {
      out.add(_items[lo]);
      lo++;
    }
    _cursor = lo;
    return out;
  }

  /// Returns items whose schedule time falls in `(previous, current]` as the
  /// media clock advances; advances the internal cursor. Items restored by a
  /// window-restore are NOT re-emitted here (cursor already sits past them).
  List<DanmakuItemModel> dueBetween(
    double previousSeconds,
    double currentSeconds,
  ) {
    if (_items.isEmpty) return const [];
    if (currentSeconds < previousSeconds) {
      // Clock moved backwards without a declared seek (rare); treat as seek.
      return restoreWindow(currentSeconds);
    }
    final out = <DanmakuItemModel>[];
    var i = _cursor;
    if (i < _items.length && _items[i].time < previousSeconds - 0.001) {
      i = _lowerBound(previousSeconds - 0.001);
    }
    while (i < _items.length && _items[i].time <= currentSeconds) {
      out.add(_items[i]);
      i++;
    }
    _cursor = i;
    return out;
  }

  int _lowerBound(double target) {
    var low = 0;
    var high = _items.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (_items[mid].time < target) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  void markShown(
    DanmakuItemModel item,
    double clockSeconds,
    double durationSeconds,
  ) {
    _active.add(
      ActiveDanmaku(
        item: item,
        shownAtSeconds: clockSeconds,
        durationSeconds: durationSeconds,
      ),
    );
  }

  /// Removes expired active danmaku (clock-driven, not timer) and returns
  /// them so the engine can release renderer slots.
  List<ActiveDanmaku> reapExpired(double clockSeconds) {
    if (_active.isEmpty) return const [];
    final expired = <ActiveDanmaku>[];
    while (_active.isNotEmpty && _active.first.expiredAt(clockSeconds)) {
      expired.add(_active.removeFirst());
    }
    // Active list is ordered by show time; a longer-lived danmaku may sit
    // behind shorter ones — sweep the rest by predicate too.
    if (_active.isNotEmpty) {
      final survivors = <ActiveDanmaku>[];
      for (final a in _active) {
        if (a.expiredAt(clockSeconds)) {
          expired.add(a);
        } else {
          survivors.add(a);
        }
      }
      _active
        ..clear()
        ..addAll(survivors);
    }
    return expired;
  }
}

/// Pure, testable decision object for masking danmaku before they hit the
/// timeline (requirement 8): blocked words, per-type switches, dedup and max
/// text length. [apply] is a pure function of (item, dedup-state).
class DanmakuFilter {
  DanmakuFilter({
    Set<String>? blockedWords,
    this.showScroll = true,
    this.showTop = true,
    this.showBottom = true,
    this.maxTextLength = 100,
    this.dedupWindow = const Duration(seconds: 6),
  }) : blockedWords = Set.unmodifiable(
         (blockedWords ?? const <String>{})
             .map((w) => w.trim().toLowerCase())
             .where((w) => w.isNotEmpty),
       );

  final Set<String> blockedWords;
  final bool showScroll;
  final bool showTop;
  final bool showBottom;
  final int maxTextLength;
  final Duration dedupWindow;

  /// Returns the passed item (clamped), or null when filtered out. Pure.
  DanmakuItemModel? apply(DanmakuItemModel item, DanmakuDedupState dedup) {
    final text = item.text;
    if (text.isEmpty) return null;
    final lower = text.toLowerCase();
    for (final w in blockedWords) {
      if (lower.contains(w)) return null;
    }
    switch (item.type) {
      case DanmakuType.scroll:
        if (!showScroll) return null;
      case DanmakuType.top:
        if (!showTop) return null;
      case DanmakuType.bottom:
        if (!showBottom) return null;
      case DanmakuType.special:
        break;
    }
    if (dedup.seen(dedupKey(item), item.time, dedupWindow)) return null;
    if (text.characters.length > maxTextLength) {
      return item.copyWith(
        text: text.characters.take(maxTextLength).toString(),
      );
    }
    return item;
  }

  /// Dedup key: same sender + same text inside the window.
  String dedupKey(DanmakuItemModel item) =>
      '${item.senderId ?? '*'}\u0000${item.text.toLowerCase()}';
}

/// Mutable dedup bookkeeping owned by the session; the filter itself stays
/// pure (it only queries [DanmakuDedupState.seen]). Testable in isolation.
class DanmakuDedupState {
  final Map<String, double> _lastSeen = {};

  bool seen(String key, double timeSeconds, Duration window) {
    final last = _lastSeen[key];
    final win = window.inMilliseconds / 1000.0;
    if (last != null && (timeSeconds - last).abs() <= win) {
      return true;
    }
    _lastSeen[key] = timeSeconds;
    return false;
  }

  /// Drops entries older than twice the window to keep memory bounded.
  void compact(double timeSeconds, Duration window) {
    final win = window.inMilliseconds / 1000.0;
    final stale = _lastSeen.keys
        .where((k) => (timeSeconds - _lastSeen[k]!).abs() > win * 2)
        .toList(growable: false);
    for (final k in stale) {
      _lastSeen.remove(k);
    }
  }

  void clear() => _lastSeen.clear();
}
