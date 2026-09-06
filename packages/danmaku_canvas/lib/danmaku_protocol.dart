import 'dart:convert';

import 'package:xml/xml.dart';

/// Protocol mode codes used by Bilibili XML and DanDanPlay's `p` field.
enum DanmakuMode {
  scroll(1, 'scroll'),
  bottom(4, 'bottom'),
  top(5, 'top'),
  reverseScroll(6, 'scroll'),
  advanced(7, 'scroll');

  const DanmakuMode(this.code, this.typeName);

  final int code;
  final String typeName;

  static DanmakuMode fromCode(int? code) => switch (code) {
        4 => DanmakuMode.bottom,
        5 => DanmakuMode.top,
        6 => DanmakuMode.reverseScroll,
        7 => DanmakuMode.advanced,
        _ => DanmakuMode.scroll,
      };
}

class PortableDanmakuItem {
  const PortableDanmakuItem({
    required this.time,
    required this.content,
    required this.mode,
    required this.colorRgb,
    this.senderId,
    this.danmakuId,
    this.sentAt,
    this.source,
    this.fontSize,
    this.extra = const <String, dynamic>{},
  });

  final double time;
  final String content;
  final DanmakuMode mode;
  final int colorRgb;
  final String? senderId;
  final String? danmakuId;
  final DateTime? sentAt;
  final String? source;
  final double? fontSize;
  final Map<String, dynamic> extra;

  String get colorCss {
    final r = (colorRgb >> 16) & 0xff;
    final g = (colorRgb >> 8) & 0xff;
    final b = colorRgb & 0xff;
    return 'rgb($r,$g,$b)';
  }

  /// Shape accepted by the copied Canvas renderer.
  Map<String, dynamic> toCanvasMap() => <String, dynamic>{
        ...extra,
        'time': time,
        'content': content,
        'type': mode.typeName,
        'originalType': mode.code,
        'color': colorCss,
        if (senderId != null) 'senderId': senderId,
        if (danmakuId != null) 'cid': danmakuId,
        if (sentAt != null) 'timestamp': sentAt!.millisecondsSinceEpoch ~/ 1000,
        if (source != null) 'source': source,
        if (fontSize != null) 'fontSize': fontSize,
      };

  factory PortableDanmakuItem.fromMap(Map<dynamic, dynamic> input) {
    final map = Map<String, dynamic>.from(input);
    final rawColor = map['color'] ?? map['r'];
    return PortableDanmakuItem(
      time: _double(map['time'] ?? map['t']),
      content: '${map['content'] ?? map['c'] ?? map['m'] ?? ''}',
      mode: _mode(map),
      colorRgb: parseColor(rawColor),
      senderId: _string(map['senderId'] ?? map['uid'] ?? map['hash']),
      danmakuId: _string(map['danmakuId'] ?? map['cid'] ?? map['id']),
      sentAt: _date(map['sentAt'] ?? map['timestamp']),
      source: _string(map['source']),
      fontSize: _doubleOrNull(map['fontSize'] ?? map['size']),
      extra: map,
    );
  }
}

/// Parse Bilibili XML. XML parsing is strict first; malformed exports get a
/// small tolerant fallback that still follows the same `p` field contract.
List<PortableDanmakuItem> parseBilibiliXml(String xml) {
  try {
    final document = XmlDocument.parse(xml);
    return document
        .findAllElements('d')
        .map((element) {
          return _fromXml(element.getAttribute('p') ?? '', element.innerText);
        })
        .where((item) => item.content.isNotEmpty)
        .toList()
      ..sort((a, b) => a.time.compareTo(b.time));
  } on XmlParserException {
    final result = <PortableDanmakuItem>[];
    final expression = RegExp(
      r'<d\b[^>]*\bp="([^"]+)"[^>]*>([\s\S]*?)</d>',
      caseSensitive: false,
    );
    for (final match in expression.allMatches(xml)) {
      final item =
          _fromXml(match.group(1) ?? '', _decode(match.group(2) ?? ''));
      if (item.content.isNotEmpty) result.add(item);
    }
    return result..sort((a, b) => a.time.compareTo(b.time));
  }
}

PortableDanmakuItem _fromXml(String p, String text) {
  final parts = p.split(',');
  if (parts.length < 4) {
    return const PortableDanmakuItem(
      time: 0,
      content: '',
      mode: DanmakuMode.scroll,
      colorRgb: 0xffffff,
    );
  }
  final timestamp = parts.length > 4 ? int.tryParse(parts[4]) : null;
  return PortableDanmakuItem(
    time: _double(parts[0]),
    content: _decode(text),
    mode: DanmakuMode.fromCode(int.tryParse(parts[1])),
    colorRgb: parseColor(int.tryParse(parts[3])),
    sentAt: timestamp == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(timestamp * 1000, isUtc: true),
    senderId: parts.length > 6 ? _string(parts[6]) : null,
    danmakuId: parts.length > 7 ? _string(parts[7]) : null,
    source: 'bilibili',
    fontSize: _doubleOrNull(parts[2]),
  );
}

int parseColor(dynamic value) {
  if (value is num) return value.toInt() & 0xffffff;
  final text = '$value'.trim();
  final rgb = RegExp(r'rgb\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)',
          caseSensitive: false)
      .firstMatch(text);
  if (rgb != null) {
    final r = int.parse(rgb.group(1)!).clamp(0, 255);
    final g = int.parse(rgb.group(2)!).clamp(0, 255);
    final b = int.parse(rgb.group(3)!).clamp(0, 255);
    return (r << 16) | (g << 8) | b;
  }
  final decimal = int.tryParse(text);
  if (decimal != null) return decimal & 0xffffff;
  final hex = text.replaceFirst(RegExp(r'^#|^0x', caseSensitive: false), '');
  return (int.tryParse(hex, radix: 16) ?? 0xffffff) & 0xffffff;
}

DanmakuMode _mode(Map<String, dynamic> map) {
  final value = map['originalType'] ?? map['mode'] ?? map['type'] ?? map['y'];
  final code = value is num ? value.toInt() : int.tryParse('$value');
  if (code != null) return DanmakuMode.fromCode(code);
  return switch ('$value'.toLowerCase()) {
    'top' => DanmakuMode.top,
    'bottom' => DanmakuMode.bottom,
    _ => DanmakuMode.scroll,
  };
}

double _double(dynamic value) =>
    value is num ? value.toDouble() : double.tryParse('$value') ?? 0;
double? _doubleOrNull(dynamic value) =>
    value is num ? value.toDouble() : double.tryParse('$value');
String? _string(dynamic value) =>
    value == null || '$value'.trim().isEmpty || '$value' == '0'
        ? null
        : '$value'.trim();
DateTime? _date(dynamic value) {
  final number = value is num ? value.toInt() : int.tryParse('$value');
  if (number != null) {
    return DateTime.fromMillisecondsSinceEpoch(
      number.abs() < 100000000000 ? number * 1000 : number,
      isUtc: true,
    );
  }
  return DateTime.tryParse('$value');
}

String _decode(String value) => const HtmlUnescape().convert(value);

/// Minimal HTML entity decoder without requiring a second package.
class HtmlUnescape {
  const HtmlUnescape();
  String convert(String value) => value
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}

String encodePortableJson(Iterable<PortableDanmakuItem> items) => jsonEncode(
      items.map((item) => item.toCanvasMap()).toList(growable: false),
    );
