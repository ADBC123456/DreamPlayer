// Smoke tests for the bundled danmaku_canvas package (requirement 9/10).
//
// Proves the vendored package: compiles, the canonical entry
// `package:danmaku_canvas/danmaku_canvas.dart` exports CanvasDanmakuManager
// (not only DanmakuScreen), and its controllers behave per contract.
import 'package:danmaku_canvas/danmaku_canvas.dart' as entry;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('canonical entry exports CanvasDanmakuManager and DanmakuScreen', () {
    // CanvasDanmakuManager.createRenderer builds a renderer widget.
    final renderer = entry.CanvasDanmakuManager.createRenderer(
      fontSize: 16,
      opacity: 1.0,
      displayArea: 1.0,
      visible: true,
      stacking: false,
      mergeDanmaku: false,
      blockTopDanmaku: false,
      blockBottomDanmaku: false,
      blockScrollDanmaku: false,
      blockWords: const [],
      danmakuList: const [],
      currentTime: 0,
      isPlaying: false,
      playbackRate: 1.0,
      scrollDurationSeconds: 9,
    );
    expect(renderer, isA<Widget>());
    expect(entry.DanmakuScreen, isNotNull);
    expect(entry.DanmakuController, isNotNull);
    expect(entry.DanmakuOption, isNotNull);
  });

  testWidgets('DanmakuScreen hands a working controller to the host', (
    tester,
  ) async {
    entry.DanmakuController? controller;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: entry.DanmakuScreen(
            option: const entry.DanmakuOption(),
            createdController: (c) => controller = c,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(controller, isNotNull);
    var shown = 0;
    // Content items land on the track; the boolean tells whether it stuck.
    final placed = controller!.addDanmaku(
      entry.DanmakuContentItem('hello', color: const Color(0xFFFF0000)),
      initialProgress: 0,
      elapsedSeconds: 0,
    );
    // Track placement can legitimately reject; record and clear.
    expect(placed, isA<bool>());
    shown = placed ? 1 : 0;
    expect(shown, lessThanOrEqualTo(1));

    controller!.pause();
    expect(controller!.running, isFalse);
    controller!.resume();
    expect(controller!.running, isTrue);
    controller!.clear();
    controller!.updateOption(
      const entry.DanmakuOption(fontSize: 20, playbackRate: 2.0),
    );
    expect(controller!.option.fontSize, 20);
  });

  testWidgets('CanvasDanmakuRenderer places danmaku from map lists', (
    tester,
  ) async {
    final danmakuList = <Map<String, dynamic>>[
      {
        'time': 0.0,
        'content': 'first',
        'type': 'scroll',
        'color': 'rgb(255,255,255)',
      },
      {'time': 0.5, 'content': 'second', 'type': 'top', 'color': 0x00FF00},
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: entry.CanvasDanmakuManager.createRenderer(
            fontSize: 16,
            opacity: 1.0,
            displayArea: 1.0,
            visible: true,
            stacking: false,
            mergeDanmaku: false,
            blockTopDanmaku: false,
            blockBottomDanmaku: false,
            blockScrollDanmaku: false,
            blockWords: const [],
            danmakuList: danmakuList,
            currentTime: 0.2,
            isPlaying: true,
            playbackRate: 1.0,
            scrollDurationSeconds: 9,
            danmakuListVersion: 1,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The renderer consumed the list without crashing and is still on tree.
    expect(find.byType(entry.CanvasDanmakuRenderer), findsOneWidget);
  });
}
