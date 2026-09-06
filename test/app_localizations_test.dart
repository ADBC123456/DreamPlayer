import 'package:dream_player/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Chinese is the default UI translation', () {
    const strings = AppLocalizations(Locale('zh'));
    expect(strings.tr('Settings'), '设置');
    expect(strings.tr('Scrape series danmaku'), '刮削整季弹幕');
  });

  test('English and unknown media titles stay unchanged', () {
    const english = AppLocalizations(Locale('en'));
    const chinese = AppLocalizations(Locale('zh'));
    expect(english.tr('Settings'), 'Settings');
    expect(chinese.tr('The Demon Hunter'), 'The Demon Hunter');
  });
}
