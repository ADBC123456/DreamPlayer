import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kDanmakuFontSizePref = 'dreamplayer.danmaku.fontSize';
const String kDanmakuOpacityPref = 'dreamplayer.danmaku.opacity';
const String kDanmakuDisplayAreaPref = 'dreamplayer.danmaku.displayArea';
const String kDanmakuScrollSpeedPref = 'dreamplayer.danmaku.scrollSpeed';
const String kDanmakuShowScrollPref = 'dreamplayer.danmaku.showScroll';
const String kDanmakuShowTopPref = 'dreamplayer.danmaku.showTop';
const String kDanmakuShowBottomPref = 'dreamplayer.danmaku.showBottom';
const String kDanmakuBlockedWordsPref = 'dreamplayer.danmaku.blockedWords';

@immutable
class DanmakuDisplaySettings {
  const DanmakuDisplaySettings({
    this.fontSize = 24,
    this.opacity = 1,
    this.displayArea = 0.5,
    this.scrollSpeed = 1,
    this.showScroll = true,
    this.showTop = true,
    this.showBottom = true,
    this.blockedWords = const [],
  });

  final double fontSize;
  final double opacity;
  final double displayArea;
  final double scrollSpeed;
  final bool showScroll;
  final bool showTop;
  final bool showBottom;
  final List<String> blockedWords;

  DanmakuDisplaySettings copyWith({
    double? fontSize,
    double? opacity,
    double? displayArea,
    double? scrollSpeed,
    bool? showScroll,
    bool? showTop,
    bool? showBottom,
    List<String>? blockedWords,
  }) => DanmakuDisplaySettings(
    fontSize: fontSize ?? this.fontSize,
    opacity: opacity ?? this.opacity,
    displayArea: displayArea ?? this.displayArea,
    scrollSpeed: scrollSpeed ?? this.scrollSpeed,
    showScroll: showScroll ?? this.showScroll,
    showTop: showTop ?? this.showTop,
    showBottom: showBottom ?? this.showBottom,
    blockedWords: blockedWords ?? this.blockedWords,
  );
}

class DanmakuDisplaySettingsStore {
  DanmakuDisplaySettingsStore._();

  static Future<DanmakuDisplaySettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    double number(String key, double fallback, double min, double max) {
      final value = prefs.getDouble(key) ?? fallback;
      return value.isFinite ? value.clamp(min, max) : fallback;
    }

    return DanmakuDisplaySettings(
      fontSize: number(kDanmakuFontSizePref, 24, 12, 48),
      opacity: number(kDanmakuOpacityPref, 1, 0.1, 1),
      displayArea: number(kDanmakuDisplayAreaPref, 0.5, 0.25, 1),
      scrollSpeed: number(kDanmakuScrollSpeedPref, 1, 0.5, 2),
      showScroll: prefs.getBool(kDanmakuShowScrollPref) ?? true,
      showTop: prefs.getBool(kDanmakuShowTopPref) ?? true,
      showBottom: prefs.getBool(kDanmakuShowBottomPref) ?? true,
      blockedWords: (prefs.getStringList(kDanmakuBlockedWordsPref) ?? const [])
          .map((word) => word.trim())
          .where((word) => word.isNotEmpty)
          .toSet()
          .toList(),
    );
  }

  static Future<void> save(DanmakuDisplaySettings value) async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setDouble(kDanmakuFontSizePref, value.fontSize.clamp(12, 48)),
      prefs.setDouble(kDanmakuOpacityPref, value.opacity.clamp(0.1, 1)),
      prefs.setDouble(
        kDanmakuDisplayAreaPref,
        value.displayArea.clamp(0.25, 1),
      ),
      prefs.setDouble(kDanmakuScrollSpeedPref, value.scrollSpeed.clamp(0.5, 2)),
      prefs.setBool(kDanmakuShowScrollPref, value.showScroll),
      prefs.setBool(kDanmakuShowTopPref, value.showTop),
      prefs.setBool(kDanmakuShowBottomPref, value.showBottom),
      prefs.setStringList(
        kDanmakuBlockedWordsPref,
        value.blockedWords
            .map((word) => word.trim())
            .where((word) => word.isNotEmpty)
            .toSet()
            .toList(),
      ),
    ]);
  }
}
