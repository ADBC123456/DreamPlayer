import 'package:dream_player/library/models/library_models.dart';
import 'package:dream_player/library/repository/library_repository.dart';
import 'package:dream_player/library/unified_library_service.dart';
import 'package:dream_player/screens/unified_title_details_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final size in [const Size(390, 844), const Size(1100, 700)]) {
    testWidgets('renders screenshot-style details without overflow at $size', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final library = UnifiedLibraryService.instance;
      final previous = library.snapshot;
      library.snapshot = _snapshot;
      addTearDown(() => library.snapshot = previous);

      await tester.pumpWidget(
        MaterialApp(
          themeMode: ThemeMode.dark,
          darkTheme: ThemeData.dark(),
          home: const UnifiedTitleDetailsScreen(titleId: 'tmdb:tv:229192'),
        ),
      );
      await tester.pump();

      expect(find.text('沧元图'), findsOneWidget);
      expect(find.text('第 1 季'), findsOneWidget);
      expect(find.text('1. 第一集'), findsOneWidget);
      if (find.textContaining('重复版本未展开显示').evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          find.textContaining('重复版本未展开显示'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
      }
      expect(find.textContaining('重复版本未展开显示'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

const _title = MediaTitle(
  id: 'tmdb:tv:229192',
  kind: MediaTitleKind.tv,
  tmdbId: 229192,
  displayTitle: '沧元图',
  releaseDate: '2023-06-22',
  genres: ['动画', '动作', '冒险'],
  overview: '沧元界妖邪作乱，主角孟川为母复仇并守护苍生。',
  rating: 8.5,
  totalEpisodeCount: 52,
);

const _episode = LibraryEpisode(
  id: 'tmdb:tv:229192:s1:e1',
  titleId: 'tmdb:tv:229192',
  seasonNumber: 1,
  episodeNumber: 1,
  displayName: '第一集',
  runtime: Duration(minutes: 24),
);

const _source = MediaSourceRef(
  sourceId: 'webdav:server',
  sourceType: 'webdav',
  path: '/TV/沧元图/沧元图.S01E01.mp4',
  serverId: 'server',
);

final _snapshot = LibrarySnapshot(
  titles: const {'tmdb:tv:229192': _title},
  episodes: const {'tmdb:tv:229192:s1:e1': _episode},
  files: {
    'version-a': MediaFile(
      id: 'version-a',
      rootIds: const {'root'},
      sourceRef: _source,
      originalFileName: '沧元图.S01E01.2160p.mp4',
      titleId: _title.id,
      episodeId: _episode.id,
      availability: MediaAvailability.available,
      legacyResumeKey: 'webdav:episode:1:a',
    ),
    'version-b': MediaFile(
      id: 'version-b',
      rootIds: const {'root'},
      sourceRef: _source,
      originalFileName: '沧元图.S01E01.1080p.mp4',
      titleId: _title.id,
      episodeId: _episode.id,
      availability: MediaAvailability.available,
      legacyResumeKey: 'webdav:episode:1:b',
    ),
  },
);
