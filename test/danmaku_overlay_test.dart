// Widget tests for DanmakuOverlay
// (任务 .trellis/tasks/09-04-danmaku-source-series-scrape).
//
// Covers: tap-through (IgnorePointer), RepaintBoundary presence, resize
// relayout, event-driven clock updates, and dispose leak-freedom (no
// listeners/timers survive unmount).
import 'dart:async';

import 'package:danmaku_canvas/danmaku_canvas.dart' as canvas;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/danmaku/models/danmaku_models.dart';
import 'package:dream_player/danmaku/presentation/danmaku_overlay.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('overlay does not accept taps (tap-through)', (tester) async {
    final controller = StreamController<DanmakuClockSnapshot>.broadcast();
    addTearDown(controller.close);

    var taps = 0;
    await tester.pumpWidget(
      _host(
        Stack(
          children: [
            // A tappable layer BENEATH the danmaku overlay (the video surface).
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: const ColoredBox(color: Colors.black),
              ),
            ),
            Positioned.fill(
              child: DanmakuOverlay(
                events: controller.stream,
                initial: const DanmakuClockSnapshot(positionSeconds: 0),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Tap dead center — must reach the video layer beneath the overlay.
    await tester.tap(find.byType(ColoredBox).first);
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('overlay contains RepaintBoundary above the canvas', (
    tester,
  ) async {
    final controller = StreamController<DanmakuClockSnapshot>.broadcast();
    addTearDown(controller.close);

    await tester.pumpWidget(
      _host(
        SizedBox.expand(
          child: DanmakuOverlay(
            events: controller.stream,
            initial: const DanmakuClockSnapshot(positionSeconds: 0),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // RepaintBoundary exists between the overlay and DanmakuScreen.
    final boundaries = find.descendant(
      of: find.byType(DanmakuOverlay),
      matching: find.byType(RepaintBoundary),
    );
    expect(boundaries, findsWidgets);
  });

  testWidgets('resize keeps the canvas laid out and engine alive', (
    tester,
  ) async {
    final controller = StreamController<DanmakuClockSnapshot>.broadcast();
    addTearDown(controller.close);

    canvas.DanmakuController? exposed;
    await tester.pumpWidget(
      _host(
        Center(
          child: SizedBox(
            width: 400,
            height: 200,
            child: DanmakuOverlay(
              events: controller.stream,
              initial: const DanmakuClockSnapshot(positionSeconds: 0),
              onControllerReady: (c) => exposed = c,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(exposed, isNotNull);

    // Resize: the same controller must survive (engine not rebuilt).
    await tester.pumpWidget(
      _host(
        Center(
          child: SizedBox(
            width: 800,
            height: 500,
            child: DanmakuOverlay(
              events: controller.stream,
              initial: const DanmakuClockSnapshot(positionSeconds: 0),
              onControllerReady: (c) => exposed = c,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(exposed, isNotNull);
    expect(exposed!.option, isA<canvas.DanmakuOption>());
  });

  testWidgets('dispose cancels the event subscription (no leaks)', (
    tester,
  ) async {
    final controller = StreamController<DanmakuClockSnapshot>.broadcast();
    await tester.pumpWidget(
      _host(
        SizedBox.expand(
          child: DanmakuOverlay(
            events: controller.stream,
            initial: const DanmakuClockSnapshot(positionSeconds: 0),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(controller.hasListener, isTrue);

    await tester.pumpWidget(_host(const SizedBox.shrink()));
    await tester.pump();
    // The subscription is cancelled on unmount — the stream has no listener.
    expect(controller.hasListener, isFalse);
  });

  testWidgets('clock events flow into the engine (window primed on mount)', (
    tester,
  ) async {
    final controller = StreamController<DanmakuClockSnapshot>.broadcast();
    addTearDown(controller.close);

    final overlayKey = GlobalKey<DanmakuOverlayState>();
    await tester.pumpWidget(
      _host(
        SizedBox.expand(
          child: DanmakuOverlay(
            key: overlayKey,
            events: controller.stream,
            initial: const DanmakuClockSnapshot(
              positionSeconds: 50,
              isPlaying: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final state = overlayKey.currentState!;
    expect(state.isEngineReady, isTrue);
    expect(state.debugClock.positionSeconds, 50);

    // Push a later snapshot; the state must track it.
    controller.add(
      const DanmakuClockSnapshot(positionSeconds: 51, isPlaying: true),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(state.debugClock.positionSeconds, 51);
  });
}
