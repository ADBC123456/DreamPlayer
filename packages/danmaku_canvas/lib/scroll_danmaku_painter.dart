import 'package:flutter/material.dart';
import 'models/danmaku_item.dart';
import 'utils/utils.dart';
import 'danmaku_timeline.dart';

class ScrollDanmakuPainter extends CustomPainter {
  final double progress;
  final List<DanmakuItem> scrollDanmakuItems;
  final double danmakuDurationInSeconds;
  final double playbackRate;
  final double fontSize;
  final int fontWeight;
  final bool showStroke;
  final double danmakuHeight;
  final bool running;
  final int tick;
  final int batchThreshold;
  final int Function()? readTick;

  final Paint selfSendPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5
    ..color = Colors.green;

  ScrollDanmakuPainter(
    this.progress,
    this.scrollDanmakuItems,
    this.danmakuDurationInSeconds,
    this.playbackRate,
    this.fontSize,
    this.fontWeight,
    this.showStroke,
    this.danmakuHeight,
    this.running,
    this.tick, {
    this.batchThreshold = 10,
    this.readTick,
    Listenable? repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final startPosition = size.width;

    final frameTick = readTick?.call() ?? tick;
    // CustomPaint already records a display list. A nested PictureRecorder on
    // every dense frame adds allocation/recording work without batching glyphs.
    for (var item in scrollDanmakuItems) {
      item.lastDrawTick ??= item.creationTime;
      item.xPosition = CanvasDanmakuTimeline.advanceScrollX(
        currentX: item.xPosition,
        previousTick: item.lastDrawTick!,
        currentTick: frameTick,
        viewWidth: startPosition,
        danmakuWidth: item.width,
        durationSeconds: danmakuDurationInSeconds,
        playbackRate: playbackRate,
      );

      item.lastDrawTick = frameTick;
      if (item.xPosition < -item.width || item.xPosition > size.width) {
        continue;
      }

      item.paragraph ??= Utils.generateParagraph(
          item.content, size.width, fontSize, fontWeight);

      if (showStroke) {
        item.strokeParagraph ??= Utils.generateStrokeParagraph(
            item.content, size.width, fontSize, fontWeight);
        canvas.drawParagraph(
            item.strokeParagraph!, Offset(item.xPosition, item.yPosition));
      }

      if (item.content.selfSend) {
        canvas.drawRect(
            Offset(item.xPosition, item.yPosition).translate(-2, 2) &
                (Size(item.width, item.height) + const Offset(4, 0)),
            selfSendPaint);
      }

      canvas.drawParagraph(
          item.paragraph!, Offset(item.xPosition, item.yPosition));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }
}
