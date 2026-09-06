/// Entry point of the bundled Canvas danmaku renderer package
/// (任务 .trellis/tasks/09-04-danmaku-source-series-scrape).
///
/// `canvas_danmaku.dart` remains the historical barrel; this file is the
/// canonical `package:danmaku_canvas/danmaku_canvas.dart` import target the
/// engine/overlay use. `CanvasDanmakuManager` is re-exported here so the
/// main entry exports the manager, not only `DanmakuScreen`.
library;

export 'canvas_danmaku.dart';
export 'canvas_danmaku_renderer.dart'
    show CanvasDanmakuManager, CanvasDanmakuRenderer;
