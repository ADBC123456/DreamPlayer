import 'package:dream_player/screens/danmaku_settings_screen.dart';
import 'package:dream_player/danmaku/service/danmaku_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
    for (var attempt = 0; attempt < 40; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (finder.evaluate().isNotEmpty) return;
    }
    fail('Timed out waiting for $finder');
  }

  testWidgets('shows source and appearance controls', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        home: DanmakuSettingsScreen(service: DanmakuService.forTesting()),
      ),
    );
    await pumpUntilFound(tester, find.text('Show danmaku'));
    expect(find.text('Show danmaku'), findsOneWidget);
    expect(find.text('No danmaku sources'), findsOneWidget);
    expect(find.text('Font size'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Blocked words'), 300);
    expect(find.text('Blocked words'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Clear danmaku cache'), 200);
    expect(find.text('Clear danmaku cache'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('validates source URL', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        home: DanmakuSettingsScreen(service: DanmakuService.forTesting()),
      ),
    );
    await pumpUntilFound(tester, find.text('Show danmaku'));
    await tester.tap(find.text('Add source'));
    await pumpUntilFound(tester, find.text('Add danmaku source'));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Base URL'),
      'github.com/example',
    );
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Enter a valid http(s) service URL'), findsOneWidget);
  });

  testWidgets('rejects the danmu_api GitHub repository URL', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        home: DanmakuSettingsScreen(service: DanmakuService.forTesting()),
      ),
    );
    await pumpUntilFound(tester, find.text('Show danmaku'));
    await tester.tap(find.text('Add source'));
    await pumpUntilFound(tester, find.text('Add danmaku source'));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Base URL'),
      'https://github.com/huangxd-/danmu_api',
    );
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(
      find.text('Enter the deployed danmu_api service URL, not its repository'),
      findsOneWidget,
    );
  });
}
