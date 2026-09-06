import 'package:danmaku_canvas/danmaku_canvas.dart';
import 'package:danmaku_canvas/scroll_danmaku_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'scroll advances on repaint without rebuilding or laying out text again',
    (tester) async {
      final frames = ChangeNotifier();
      addTearDown(frames.dispose);
      var tick = 0;
      var builds = 0;
      // Exercise both the formerly direct and nested-picture drawing paths.
      final items = List.generate(
        12,
        (i) => DanmakuItem(
          content: DanmakuContentItem('弹幕 $i'),
          creationTime: 0,
          width: 80,
          height: 20,
          xPosition: 400,
          yPosition: i * 20,
        ),
      );
      final painter = ScrollDanmakuPainter(
        0,
        items,
        10,
        1,
        16,
        4,
        true,
        20,
        true,
        0,
        readTick: () => tick,
        repaint: frames,
      );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 400,
              height: 300,
              child: Builder(
                builder: (_) {
                  builds++;
                  return CustomPaint(painter: painter);
                },
              ),
            ),
          ),
        ),
      );
      final paragraph = items.first.paragraph;
      expect(paragraph, isNotNull);
      for (final nextTick in [100, 200, 300]) {
        tick = nextTick;
        frames.notifyListeners();
        await tester.pump();
        expect(items.first.xPosition, closeTo(400 - tick * .048, .0001));
      }
      expect(builds, 1);
      expect(identical(items.first.paragraph, paragraph), isTrue);
      // A paused clock can repaint (e.g. controls change) without moving text.
      final pausedX = items.first.xPosition;
      frames.notifyListeners();
      await tester.pump();
      expect(items.first.xPosition, pausedX);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
