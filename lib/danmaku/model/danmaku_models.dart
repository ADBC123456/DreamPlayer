/// Typed models for the danmaku domain (任务
/// .trellis/tasks/09-04-danmaku-source-series-scrape, 模型层).
///
/// All protocol payloads (danmu_api JSON, Bilibili XML) are converted into
/// these models at the parser boundary — no raw maps cross into screens or
/// the pipeline (spec: .trellis/spec/frontend/type-safety.md).
///
/// Conventions:
/// - Numeric-typed protocol fields (`episodeId`, `animeId`, `cid`, `like`)
///   accept both JSON numbers and JSON strings (requirement 7) — string
///   identities are preserved verbatim, never coerced to int.
/// - Malformed values degrade to documented defaults; nothing throws at the
///   parser boundary.
library;

/// Identifies the video a danmaku set belongs to. Either a service-side
/// identity (danmu_api episodeId/animeId) or a local stable identity
/// (resume key). At least one of [episodeId] / [localKey] must be set.
class VideoIdentity {
  const VideoIdentity({this.animeId, this.episodeId, this.localKey, this.title})
    : assert(
        episodeId != null || localKey != null,
        'VideoIdentity needs a service episodeId or a localKey',
      );

  /// danmu_api anime id (number or string upstream; kept verbatim).
  final String? animeId;

  /// danmu_api episode id (number or string upstream; kept verbatim).
  final String? episodeId;

  /// App-side stable key (`TmdStore.identityKeyFor` shape) for local files.
  final String? localKey;

  /// Human-readable video title (best effort; display only).
  final String? title;

  VideoIdentity copyWith({String? title}) => VideoIdentity(
    animeId: animeId,
    episodeId: episodeId,
    localKey: localKey,
    title: title ?? this.title,
  );

  @override
  bool operator ==(Object other) =>
      other is VideoIdentity &&
      other.animeId == animeId &&
      other.episodeId == episodeId &&
      other.localKey == localKey;

  @override
  int get hashCode => Object.hash(animeId, episodeId, localKey);

  @override
  String toString() =>
      'VideoIdentity(anime: $animeId, episode: $episodeId, '
      'local: $localKey, title: $title)';
}

/// How a danmaku travels across the screen.
///
/// Protocol mapping (requirement 6):
/// - mode 1 / 6 / 7 -> [scroll] (6/7 degrade to plain scroll in v1)
/// - mode 4 -> [bottom]
/// - mode 5 -> [top]
enum DanmakuMode {
  scroll,
  bottom,
  top;

  /// Maps a protocol mode code; unknown/invalid codes degrade to [scroll].
  static DanmakuMode fromCode(int? code) => switch (code) {
    4 => DanmakuMode.bottom,
    5 => DanmakuMode.top,
    _ => DanmakuMode.scroll,
  };
}

/// One parsed danmaku comment, source-agnostic.
class DanmakuItem {
  const DanmakuItem({
    required this.timeSeconds,
    required this.text,
    this.mode = DanmakuMode.scroll,
    this.colorRgb = 0xFFFFFF,
    this.fontSize,
    this.danmakuId,
    this.likes,
    this.source,
  });

  /// Schedule position in media seconds. Non-finite or negative protocol
  /// times never reach a parser output (filtered at the parser boundary).
  final double timeSeconds;

  /// Comment text (already unescaped); never empty on parser outputs.
  final String text;

  /// Motion type (requirement 6 mapping).
  final DanmakuMode mode;

  /// 0xRRGGBB color; out-of-range protocol values clamp/mask to this.
  final int colorRgb;

  /// Font size for the 8/9-field `p` variants (index 2), if provided.
  final double? fontSize;

  /// Service comment id (`cid`), number or string kept verbatim.
  final String? danmakuId;

  /// Like count when the source provides one.
  final int? likes;

  /// Provenance label (e.g. `danmu_api`, `bilibili`), display/debug only.
  final String? source;

  /// Canonical `time` field name used by the canvas renderer maps.
  Map<String, dynamic> toCanvasMap() => <String, dynamic>{
    'time': timeSeconds,
    'content': text,
    'type': switch (mode) {
      DanmakuMode.scroll => 'scroll',
      DanmakuMode.top => 'top',
      DanmakuMode.bottom => 'bottom',
    },
    'color': _colorCss(colorRgb),
    if (fontSize != null) 'fontSize': fontSize,
    if (danmakuId != null) 'cid': danmakuId,
    if (source != null) 'source': source,
  };

  static String _colorCss(int rgb) =>
      'rgb(${(rgb >> 16) & 0xff},${(rgb >> 8) & 0xff},${rgb & 0xff})';

  @override
  bool operator ==(Object other) =>
      other is DanmakuItem &&
      other.timeSeconds == timeSeconds &&
      other.text == text &&
      other.mode == mode &&
      other.colorRgb == colorRgb &&
      other.danmakuId == danmakuId;

  @override
  int get hashCode => Object.hash(timeSeconds, text, mode, colorRgb, danmakuId);

  @override
  String toString() =>
      'DanmakuItem(${timeSeconds}s, $mode, #$colorRgb, '
      '"$text")';
}

/// Reference to a remote episode's danmaku set (danmu_api match result).
class DanmakuRef {
  const DanmakuRef({
    required this.episodeId,
    this.animeId,
    this.animeTitle,
    this.episodeTitle,
    this.shiftSeconds = 0,
    this.url,
  });

  /// danmu_api episodeId — number or string upstream, kept verbatim
  /// (requirement 7: never coerce to int).
  final String episodeId;

  final String? animeId;
  final String? animeTitle;
  final String? episodeTitle;

  /// Comment time offset in seconds (danmu_api `shift`).
  final double shiftSeconds;

  /// Optional source URL hint from the match result.
  final String? url;

  /// Parses an id that may arrive as JSON number or string (requirement 7).
  static String idFromDynamic(dynamic value) => switch (value) {
    null => '',
    String s => s.trim(),
    num n => n.toInt().toString(),
    _ => '$value'.trim(),
  };

  @override
  bool operator ==(Object other) =>
      other is DanmakuRef &&
      other.episodeId == episodeId &&
      other.animeId == animeId;

  @override
  int get hashCode => Object.hash(episodeId, animeId);

  @override
  String toString() =>
      'DanmakuRef(episode: $episodeId, anime: $animeId, '
      '"$animeTitle / $episodeTitle")';
}

/// Result of matching one video against a danmaku source.
enum DanmakuMatchState { matched, noMatch, failed }

class DanmakuMatch {
  const DanmakuMatch({
    required this.state,
    this.ref,
    this.confidence = 1.0,
    this.errorMessage,
  }) : assert(
         state == DanmakuMatchState.matched ? ref != null : true,
         'matched requires a ref',
       );

  const DanmakuMatch.matched(DanmakuRef ref, {double confidence = 1.0})
    : this(state: DanmakuMatchState.matched, ref: ref, confidence: confidence);

  const DanmakuMatch.noMatch() : this(state: DanmakuMatchState.noMatch);

  const DanmakuMatch.failed(String message)
    : this(state: DanmakuMatchState.failed, errorMessage: message);

  final DanmakuMatchState state;
  final DanmakuRef? ref;

  /// 0..1; below the UI threshold the caller must not silently apply it.
  final double confidence;

  final String? errorMessage;

  bool get isUsable => state == DanmakuMatchState.matched && ref != null;

  @override
  String toString() =>
      'DanmakuMatch($state, ref: $ref, confidence: '
      '$confidence, error: $errorMessage)';
}

/// One episode of a series (scrape catalog entry).
class DanmakuEpisode {
  const DanmakuEpisode({
    required this.identity,
    required this.title,
    this.seasonNumber,
    this.episodeNumber,
    this.ref,
  });

  /// The video this episode maps to (file / Jellyfin item / URL).
  final VideoIdentity identity;

  /// Display title (episode name or file name).
  final String title;

  final int? seasonNumber;
  final int? episodeNumber;

  /// Matched remote episode, if resolution already succeeded.
  final DanmakuRef? ref;

  @override
  String toString() =>
      'DanmakuEpisode(S${seasonNumber ?? '?'}E'
      '${episodeNumber ?? '?'} "$title", ref: $ref)';
}

/// A whole series with its episodes (danmu_api bangumi catalog).
class DanmakuSeries {
  const DanmakuSeries({
    required this.animeId,
    required this.title,
    this.episodes = const [],
    this.type,
  });

  final String animeId;
  final String title;

  /// `tvseries` / `movie` / … (danmu_api `type` name).
  final String? type;

  final List<DanmakuEpisode> episodes;

  /// Finds the episode whose number matches (null-safe).
  DanmakuEpisode? episodeAt(int season, int episode) {
    for (final e in episodes) {
      if (e.seasonNumber == season && e.episodeNumber == episode) return e;
    }
    return null;
  }

  @override
  String toString() =>
      'DanmakuSeries($animeId "$title", '
      '${episodes.length} episodes)';
}

/// A danmaku track (ordered list) handed to the pipeline/renderer.
class DanmakuTrack {
  DanmakuTrack({
    required this.identity,
    required List<DanmakuItem> items,
    this.sourceId,
    this.sourceBaseUrl,
    this.fetchedAt,
    this.videoDurationSeconds = 0,
    this.schemaVersion = 1,
  }) : items = List.unmodifiable(items);

  /// Video the track belongs to.
  final VideoIdentity identity;

  /// Parsed comments, sorted by [DanmakuItem.timeSeconds].
  final List<DanmakuItem> items;

  /// Source id + base URL the track was fetched from (cache isolation
  /// requirement: cache is keyed per source address and video identity).
  final String? sourceId;
  final String? sourceBaseUrl;

  final DateTime? fetchedAt;

  /// Video duration as reported by the source (0 when unknown).
  final double videoDurationSeconds;

  /// Cache schema version.
  final int schemaVersion;

  int get count => items.length;

  bool get isEmpty => items.isEmpty;
}

/// User display options (renderer-independent, requirement 5 of the PRD:
/// rate changes only affect motion speed, not data).
class DanmakuOptions {
  const DanmakuOptions({
    this.enabled = true,
    this.fontSize = 16,
    this.opacity = 1.0,
    this.displayArea = 1.0,
    this.scrollDurationSeconds = 9.0,
    this.showScroll = true,
    this.showTop = true,
    this.showBottom = true,
    this.blockedWords = const <String>{},
  });

  final bool enabled;
  final double fontSize;

  /// 0.1..1.0
  final double opacity;

  /// 0.0 = single line, (0.0, 1.0] = proportional share of the screen.
  final double displayArea;

  /// Seconds a scroll danmaku takes to cross the screen.
  final double scrollDurationSeconds;

  final bool showScroll;
  final bool showTop;
  final bool showBottom;

  final Set<String> blockedWords;

  DanmakuOptions copyWith({
    bool? enabled,
    double? fontSize,
    double? opacity,
    double? displayArea,
    double? scrollDurationSeconds,
    bool? showScroll,
    bool? showTop,
    bool? showBottom,
    Set<String>? blockedWords,
  }) => DanmakuOptions(
    enabled: enabled ?? this.enabled,
    fontSize: fontSize ?? this.fontSize,
    opacity: opacity ?? this.opacity,
    displayArea: displayArea ?? this.displayArea,
    scrollDurationSeconds: scrollDurationSeconds ?? this.scrollDurationSeconds,
    showScroll: showScroll ?? this.showScroll,
    showTop: showTop ?? this.showTop,
    showBottom: showBottom ?? this.showBottom,
    blockedWords: blockedWords ?? this.blockedWords,
  );
}
