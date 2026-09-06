import 'package:dream_player/danmaku/settings/danmaku_display_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('loads defaults', () async {
    final value = await DanmakuDisplaySettingsStore.load();
    expect(value.fontSize, 24);
    expect(value.opacity, 1);
    expect(value.displayArea, .5);
    expect(value.scrollSpeed, 1);
    expect(value.showScroll, isTrue);
  });

  test('round trips and normalizes blocked words', () async {
    await DanmakuDisplaySettingsStore.save(
      const DanmakuDisplaySettings(
        fontSize: 30,
        opacity: .7,
        displayArea: .75,
        scrollSpeed: 1.4,
        showTop: false,
        blockedWords: [' spoiler ', '', 'spoiler', 'ad'],
      ),
    );
    final value = await DanmakuDisplaySettingsStore.load();
    expect(value.fontSize, 30);
    expect(value.opacity, .7);
    expect(value.showTop, isFalse);
    expect(value.blockedWords, ['spoiler', 'ad']);
  });

  test('clamps corrupt numeric values', () async {
    SharedPreferences.setMockInitialValues({
      kDanmakuFontSizePref: 100.0,
      kDanmakuOpacityPref: -1.0,
    });
    final value = await DanmakuDisplaySettingsStore.load();
    expect(value.fontSize, 48);
    expect(value.opacity, .1);
  });
}
