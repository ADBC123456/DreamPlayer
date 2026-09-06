/// Typed danmaku models shared by the scraper, the pipeline and the overlay.
library;

enum DanmakuType { scroll, top, bottom, special }

/// Immutable danmaku entry the pipeline schedules.
class DanmakuItemModel {
  const DanmakuItemModel({
    required this.time,
    required this.text,
    this.type = DanmakuType.scroll,
    this.color = 0xFFFFFF,
    this.senderId,
    this.danmakuId,
  });

  /// Schedule position in media seconds (from the source `time` field).
  final double time;
  final String text;
  final DanmakuType type;

  /// 0xRRGGBB.
  final int color;
  final String? senderId;
  final String? danmakuId;

  DanmakuItemModel copyWith({String? text}) => DanmakuItemModel(
    time: time,
    text: text ?? this.text,
    type: type,
    color: color,
    senderId: senderId,
    danmakuId: danmakuId,
  );

  factory DanmakuItemModel.fromMap(Map<dynamic, dynamic> m) {
    final rawType = '${m['type'] ?? m['mode'] ?? ''}';
    final code = m['originalType'] is num
        ? (m['originalType'] as num).toInt()
        : null;
    final type = switch (rawType) {
      'top' => DanmakuType.top,
      'bottom' => DanmakuType.bottom,
      'special' => DanmakuType.special,
      _ => switch (code) {
        4 => DanmakuType.bottom,
        5 => DanmakuType.top,
        7 => DanmakuType.special,
        _ => DanmakuType.scroll,
      },
    };
    final colorRaw = m['color'];
    int color = 0xFFFFFF;
    if (colorRaw is num) {
      color = colorRaw.toInt() & 0xFFFFFF;
    } else if (colorRaw is String) {
      final s = colorRaw.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
      if (s.length == 6) color = int.tryParse(s, radix: 16) ?? 0xFFFFFF;
    }
    return DanmakuItemModel(
      time: (m['time'] as num?)?.toDouble() ?? 0,
      text: '${m['content'] ?? m['text'] ?? ''}',
      type: type,
      color: color,
      senderId: m['senderId'] as String?,
      danmakuId: m['danmakuId'] as String? ?? m['cid'] as String?,
    );
  }
}

/// Load-state surface for the overlay (requirement 7).
enum DanmakuLoadState { idle, loading, ready, empty, error }

/// Media-clock snapshot fed from the player events (requirement 1/2). The
/// pipeline treats `positionSeconds` as the ONLY source of truth; timers in
/// the widget layer merely extrapolate BETWEEN snapshots while playing.
class DanmakuClockSnapshot {
  const DanmakuClockSnapshot({
    required this.positionSeconds,
    this.durationSeconds = 0,
    this.rate = 1.0,
    this.isPlaying = false,
    this.buffering = false,
    this.seekRevision = 0,
  });

  final double positionSeconds;
  final double durationSeconds;

  /// Playback rate (0.5x/2x …). Rate changes only affect extrapolation speed;
  /// they never re-request data (requirement 5).
  final double rate;
  final bool isPlaying;
  final bool buffering;

  /// Incremented by the caller on every user seek; a change (or any position
  /// jump bigger than [largeJumpSeconds]) clears active danmaku and restores
  /// the look-back window.
  final int seekRevision;

  /// Threshold above which a position delta is treated as a seek even without
  /// a revision bump (covers native-side auto-seeks, e.g. resume).
  static const double largeJumpSeconds = 1.5;

  bool isLargeJumpFrom(double previousPositionSeconds) =>
      (positionSeconds - previousPositionSeconds).abs() > largeJumpSeconds;

  factory DanmakuClockSnapshot.fromPlayerEvent({
    required int positionMs,
    int durationMs = 0,
    double rate = 1.0,
    required bool playing,
    required bool buffering,
    int seekRevision = 0,
  }) => DanmakuClockSnapshot(
    positionSeconds: positionMs / 1000.0,
    durationSeconds: durationMs / 1000.0,
    rate: rate,
    isPlaying: playing,
    buffering: buffering,
    seekRevision: seekRevision,
  );
}
