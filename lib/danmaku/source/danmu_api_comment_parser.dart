/// danmu_api comment payload parser (任务
/// .trellis/tasks/09-04-danmaku-source-series-scrape).
///
/// Parses the single-episode endpoint response:
/// ```json
/// {
///   "success": true, "errorCode": 0, "errorMessage": "",
///   "count": 1, "videoDuration": 2700,
///   "comments": [{"p": "12.50,1,16777215,[bilibili]", "m": "...",
///                 "cid": 123456, "like": 8}]
/// }
/// ```
/// `p` field contracts (requirements 4/5):
/// - 4 fields `time,mode,color,source`: color at index 2
/// - 8/9 fields `time,mode,fontSize,color,...`: color at index 3
/// Mode mapping (requirement 6): 1/6/7 scroll, 4 bottom, 5 top.
/// `cid`/`like` (requirement 3) and string/number ids (requirement 7) are
/// both handled; broken rows are skipped, never thrown (requirement 8).
library;

import 'dart:convert';

import '../model/danmaku_models.dart';
import '../model/parse_utils.dart';

/// The parsed comment-list response for one episode.
class DanmuApiComments {
  const DanmuApiComments({
    required this.items,
    this.videoDurationSeconds,
    this.errorCode,
    this.errorMessage,
  });

  /// Usable comments sorted by time; malformed rows excluded.
  final List<DanmakuItem> items;

  /// Server-reported `videoDuration` (seconds) when `duration=true`.
  final double? videoDurationSeconds;

  /// Non-zero `errorCode` values are surfaced for the source layer to map
  /// onto typed exceptions; the parser itself never throws.
  final int? errorCode;
  final String? errorMessage;

  int get count => items.length;
}

/// Parses a danmu_api `/api/v2/comment/{episodeId}` JSON body.
///
/// [bodyBytes]/[bodyText] accept the raw transport payload; when the JSON is
/// completely unusable the result carries the parse failure via an empty
/// list plus an [DanmuApiComments.errorMessage] — no exception escapes.
DanmuApiComments parseDanmuApiComments(
  String bodyText, {
  String source = 'danmu_api',
}) {
  final trimmed = bodyText.trim();
  if (trimmed.isEmpty) {
    return const DanmuApiComments(items: []);
  }

  Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on FormatException {
    return const DanmuApiComments(
      items: [],
      errorMessage: 'Response is not valid JSON',
    );
  }
  if (decoded is! Map<String, dynamic>) {
    return const DanmuApiComments(
      items: [],
      errorMessage: 'Response is not a JSON object',
    );
  }
  return parseDanmuApiCommentsMap(decoded, source: source);
}

/// Parses an already decoded response. HTTP clients use this entry point so
/// protocol normalization has one implementation shared with import tests.
DanmuApiComments parseDanmuApiCommentsMap(
  Map<String, dynamic> decoded, {
  String source = 'danmu_api',
}) {
  return DanmuApiComments(
    items: _parseComments(decoded['comments'], source),
    videoDurationSeconds: _parseDuration(decoded['videoDuration']),
    errorCode: tryParseInt(decoded['errorCode']),
    errorMessage: _stringOrNull(decoded['errorMessage']),
  );
}

/// Parses the `comments` array; every broken row is skipped (requirement 8).
List<DanmakuItem> _parseComments(Object? comments, String source) {
  if (comments is! List) return const [];
  final items = <DanmakuItem>[];
  for (final raw in comments) {
    if (raw is! Map) continue;
    final item = _parseComment(raw, source);
    if (item != null) items.add(item);
  }
  return items..sort((a, b) => a.timeSeconds.compareTo(b.timeSeconds));
}

/// One comment row -> [DanmakuItem]; null when unusable.
DanmakuItem? _parseComment(Map<Object?, Object?> raw, String source) {
  final text = _commentText(raw['m']);
  if (text == null || text.isEmpty) return null;

  final fields = _pFields(raw['p']);
  if (fields.length < 4) return null;

  final time = parseDanmakuTime(fields[0]);
  if (time == null) return null;

  final modeCode = tryParseInt(fields[1]);
  final colorIndex = fields.length == 4 ? 2 : 3;
  final fontSize = fields.length > 4 ? tryParseDouble(fields[2]) : null;

  return DanmakuItem(
    timeSeconds: time,
    text: text,
    mode: DanmakuMode.fromCode(modeCode),
    colorRgb: parseDanmakuColor(fields[colorIndex]),
    fontSize: fontSize,
    danmakuId: DanmakuRef.idFromDynamic(raw['cid']).isEmpty
        ? null
        : DanmakuRef.idFromDynamic(raw['cid']),
    likes: tryParseInt(raw['like']),
    source: source,
  );
}

/// Splits the `p` string; numeric lists (defensive) also supported.
List<String> _pFields(Object? p) {
  if (p == null) return const [];
  if (p is List) return p.map((e) => '$e'.trim()).toList();
  return '$p'.split(',').map((e) => e.trim()).toList();
}

/// Comment text: strings only, HTML/XML entities decoded (requirement 8).
String? _commentText(Object? m) {
  if (m is! String) return null;
  final decoded = decodeXmlEntities(m).trim();
  return decoded.isEmpty ? null : decoded;
}

double? _parseDuration(Object? value) {
  final seconds = tryParseDouble(value);
  if (seconds == null || seconds < 0) return null;
  return seconds;
}

String? _stringOrNull(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
