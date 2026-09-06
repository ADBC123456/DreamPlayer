/// Shared parsing helpers for the danmaku source parsers (requirement 8:
/// tolerate empty content, invalid numbers, out-of-range colors, HTML/XML
/// escapes, CDATA and broken XML without ever throwing at the boundary).
library;

/// 0xRRGGBB white — the protocol default color.
const int kDefaultDanmakuColor = 0xFFFFFF;

/// Normalizes any protocol color into 0xRRGGBB (requirement 8).
///
/// Accepts:
/// - JSON numbers (decimal 16777215 / 0xFFFFFF, also negative / >24-bit)
/// - decimal strings ("16711680")
/// - hex strings ("#FF0000", "0xFF0000", "ff0000")
/// - css "rgb(255,0,0)" (channel values clamp to 0..255)
///
/// Unknown/invalid input degrades to [kDefaultDanmakuColor].
int parseDanmakuColor(dynamic value) {
  if (value == null) return kDefaultDanmakuColor;
  if (value is num) {
    if (!value.isFinite) return kDefaultDanmakuColor;
    return value.toInt() & 0xFFFFFF;
  }
  final text = '$value'.trim();
  if (text.isEmpty) return kDefaultDanmakuColor;

  final rgb = RegExp(
    r'rgb\s*\(\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*\)',
    caseSensitive: false,
  ).firstMatch(text);
  if (rgb != null) {
    final r = (int.tryParse(rgb.group(1)!) ?? 0).clamp(0, 255);
    final g = (int.tryParse(rgb.group(2)!) ?? 0).clamp(0, 255);
    final b = (int.tryParse(rgb.group(3)!) ?? 0).clamp(0, 255);
    return (r << 16) | (g << 8) | b;
  }

  final decimal = int.tryParse(text);
  if (decimal != null) return decimal & 0xFFFFFF;

  final hex = text.replaceFirst(RegExp(r'^#|^0x', caseSensitive: false), '');
  final parsed = int.tryParse(hex, radix: 16);
  if (parsed == null) return kDefaultDanmakuColor;
  // #RRGGBB -> mask; #AARRGGBB -> drop the alpha byte.
  return parsed & 0xFFFFFF;
}

/// Tolerant double parse: null/blank/garbage -> null (caller decides the
/// fallback). "1.5", " 12 ", "12.50," style inputs all parse.
double? tryParseDouble(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.isFinite ? value.toDouble() : null;
  final text = '$value'.trim();
  if (text.isEmpty) return null;
  return double.tryParse(text);
}

/// Tolerant int parse: null/blank/garbage -> null.
int? tryParseInt(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.isFinite ? value.toInt() : null;
  final text = '$value'.trim();
  if (text.isEmpty) return null;
  return int.tryParse(text);
}

/// A `p`-field time is only usable when finite and not negative; returns
/// null for anything the renderer must not schedule (requirement 8).
double? parseDanmakuTime(dynamic value) {
  final seconds = tryParseDouble(value);
  if (seconds == null || seconds < 0 || seconds.isNaN || seconds.isInfinite) {
    return null;
  }
  return seconds;
}

/// Decodes XML/HTML character references the way the Bilibili XML export and
/// danmu_api HTML-ish payloads need: named entities (&amp; &lt; &gt; &quot;
/// &apos; &nbsp;) first, then numeric (&#83; / &#x53;). A lone `&` survives.
String decodeXmlEntities(String input) {
  if (!input.contains('&')) return input;
  var out = input.replaceAllMapped(RegExp(r'&(#x?)?([0-9A-Za-z]+);?'), (m) {
    final isHex = m.group(1) == '#x';
    final isDec = m.group(1) == '#';
    final body = m.group(2)!;
    if (isHex || isDec) {
      final code = int.tryParse(body, radix: isHex ? 16 : 10);
      return code != null ? String.fromCharCode(code) : m.group(0)!;
    }
    return switch (body) {
      'amp' => '&',
      'lt' => '<',
      'gt' => '>',
      'quot' => '"',
      'apos' => "'",
      'nbsp' => ' ',
      _ => m.group(0)!,
    };
  });
  // The `&amp;` -> `&` pass can leave a semicolon-terminated reference when
  // upstream double-escaped (`&amp;lt;`); re-run once so `&lt;` becomes `<`.
  out = out.replaceAllMapped(RegExp(r'&(amp|lt|gt|quot|apos);'), (m) {
    return switch (m.group(1)!) {
      'amp' => '&',
      'lt' => '<',
      'gt' => '>',
      'quot' => '"',
      _ => "'",
    };
  });
  return out;
}
