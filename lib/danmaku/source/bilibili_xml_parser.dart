/// Bilibili XML danmaku parser (`<d p="...">comment</d>` format)
/// (任务 .trellis/tasks/09-04-danmaku-source-series-scrape).
///
/// The bundled `danmaku_canvas` package ships its own `parseBilibiliXml`
/// operating on `PortableDanmakuItem`; this module produces the app's typed
/// [DanmakuItem]s instead, so the rest of the app never touches the portable
/// model. Contract (mirrors the canvas parser):
/// - `p` fields: time, mode, fontSize, color, [timestamp, pool, sender,
///   danmakuId] (the 8/9-field form); 4-field legacy uses
///   time,mode,color,source — index 3 is then the COLOR (requirement 4/5),
///   so the color index depends on the field count.
/// - mode 1/6/7 -> scroll, 4 -> bottom, 5 -> top (requirement 6).
/// - empty comments, <4-field `p`, unparseable time: skipped.
/// - CDATA and XML entities are decoded; malformed XML falls back to a
///   tolerant regex pass (requirement 8).
library;

import 'package:xml/xml.dart';

import '../model/danmaku_models.dart';
import '../model/parse_utils.dart';

/// Parses a Bilibili XML export into typed danmaku, sorted by time.
///
/// Never throws on broken XML: strict `xml` parsing first, then a tolerant
/// regex pass that still salvages well-formed `<d>` rows from a damaged
/// document. Returns an empty list when nothing usable remains.
List<DanmakuItem> parseBilibiliXml(String xml, {String source = 'bilibili'}) {
  if (xml.trim().isEmpty) return const [];

  try {
    final document = XmlDocument.parse(xml);
    final items = <DanmakuItem>[];
    for (final element in document.findAllElements('d')) {
      final item = _fromXml(
        element.getAttribute('p') ?? '',
        element.innerText,
        source,
      );
      if (item != null) items.add(item);
    }
    return items..sort((a, b) => a.timeSeconds.compareTo(b.timeSeconds));
  } on XmlException {
    return _parseBrokenXml(xml, source);
  }
}

/// Tolerant salvage for corrupted exports (requirement 8): extracts every
/// `<d ... p="...">text</d>` row the regex can still see, including CDATA
/// bodies. `XmlException` covers the malformed-document case; parse failures
/// inside salvage are swallowed row by row by [_fromXml] returning null.
List<DanmakuItem> _parseBrokenXml(String xml, String source) {
  final items = <DanmakuItem>[];
  final expression = RegExp(
    r'<d\b[^>]*\bp="([^"]+)"[^>]*>([\s\S]*?)</d>',
    caseSensitive: false,
  );
  for (final match in expression.allMatches(xml)) {
    final text = _textBody(match.group(2) ?? '');
    final item = _fromXml(match.group(1) ?? '', text, source);
    if (item != null) items.add(item);
  }
  return items..sort((a, b) => a.timeSeconds.compareTo(b.timeSeconds));
}

/// Strips a CDATA wrapper if present and decodes entities.
String _textBody(String raw) {
  final cdata = RegExp(
    r'<!\[CDATA\[([\s\S]*?)\]\]>',
    caseSensitive: false,
  ).firstMatch(raw);
  final body = cdata != null ? cdata.group(1)! : raw;
  return decodeXmlEntities(body).trim();
}

/// One `<d>` row -> [DanmakuItem]; null when the row must be dropped
/// (fewer than 4 `p` fields, empty text, invalid time).
DanmakuItem? _fromXml(String p, String text, String source) {
  final parts = p.split(',');
  if (parts.length < 4) return null;

  final time = parseDanmakuTime(parts[0]);
  final content = decodeXmlEntities(text).trim();
  if (time == null || content.isEmpty) return null;

  final modeCode = tryParseInt(parts[1]);
  // 4-field legacy `p` = time,mode,color,source: color at index 2.
  // 8/9-field `p` = time,mode,fontSize,color,...: color at index 3.
  final colorIndex = parts.length == 4 ? 2 : 3;
  final fontSize = parts.length > 4 ? tryParseDouble(parts[2]) : null;

  // 9-field rows also carry timestamp(4), pool(5), sender(6), id(7);
  final danmakuId = parts.length > 7 ? parts[7] : null;

  return DanmakuItem(
    timeSeconds: time,
    text: content,
    mode: DanmakuMode.fromCode(modeCode),
    colorRgb: parseDanmakuColor(parts[colorIndex]),
    fontSize: fontSize,
    danmakuId: (danmakuId == null || danmakuId.isEmpty) ? null : danmakuId,
    source: source,
  );
}
