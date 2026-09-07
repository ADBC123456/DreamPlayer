import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/danmaku/scraper/scrape_state.dart';
import 'package:dream_player/danmaku/scraper/series_scraper.dart';
import 'package:dream_player/danmaku/scraper/video_enumerator.dart';
import 'package:dream_player/danmaku/service/danmaku_service.dart';
import 'package:dream_player/danmaku/source/danmaku_source_store.dart';
import 'package:dream_player/danmaku/source/danmaku_source_registry.dart';
import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/screens/danmaku_scrape_screen.dart';
import 'package:dream_player/services/library_folders.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
    for (var attempt = 0; attempt < 80; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (finder.evaluate().isNotEmpty) return;
    }
    fail('Timed out waiting for $finder');
  }

  final folder = LibraryFolder(
    id: 'show',
    name: 'Example Show',
    path: '/shows/example',
    addedAt: DateTime(2026),
  );

  testWidgets('runs the series scraper and exposes progress actions', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      kDanmakuSourcesPref: jsonEncode([
        const DanmakuSourceConfig(
          id: 'test',
          name: 'Test source',
          baseUrl: 'https://example.invalid',
        ).toJson(),
      ]),
    });
    final enumerator = DanmakuVideoEnumerator(gateway: _ListingGateway());
    final repository = _Repository();

    final service = DanmakuService.forTesting(
      configs: const [
        DanmakuSourceConfig(
          id: 'test',
          name: 'Test source',
          baseUrl: 'https://example.invalid',
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: DanmakuScrapeScreen(
          folder: folder,
          seriesTitle: folder.name,
          service: service,
          enumerator: enumerator,
          scraperFactory: (_, _, changed) => SeriesScraper(
            source: _Source(),
            repository: repository,
            minRequestGap: Duration.zero,
            backoffBase: Duration.zero,
            onChanged: changed,
          ),
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('0 / 1 · Ready'));

    expect(find.text('0 / 1 · Ready'), findsOneWidget);
    expect(repository.videoKeys, isEmpty);
    expect(find.byKey(const Key('precache-season')), findsOneWidget);

    await tester.tap(find.byKey(const Key('precache-season')));
    await pumpUntilFound(tester, find.text('1 / 1 · Completed'));
    expect(find.text('success · 3'), findsOneWidget);
    expect(repository.videoKeys, [
      'danmaku:/shows/example/Example.Show.S01E01.mkv',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows an actionable empty-source state', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: DanmakuScrapeScreen(
          folder: folder,
          seriesTitle: folder.name,
          service: DanmakuService.forTesting(),
        ),
      ),
    );
    await pumpUntilFound(
      tester,
      find.textContaining('No danmaku source is enabled'),
    );

    expect(find.textContaining('No danmaku source is enabled'), findsOneWidget);
    expect(find.byKey(const Key('configure-source')), findsOneWidget);
  });
}

class _ListingGateway implements DanmakuListingGateway {
  @override
  Future<FolderListing> listFolder(VideoSource source, String path) async =>
      const FolderListing(
        videos: [
          VideoItem(
            id: 'ep1',
            title: 'Example.Show.S01E01.mkv',
            path: '/shows/example/Example.Show.S01E01.mkv',
            duration: Duration.zero,
          ),
        ],
      );
}

class _Source implements DanmakuScrapeSource {
  @override
  Future<List<DanmakuCatalogAnime>> searchEpisodes(
    String title, {
    DanmakuCancelToken? cancelToken,
  }) async => const [
    DanmakuCatalogAnime(
      animeId: 'anime',
      animeTitle: 'Example Show',
      episodes: [
        DanmakuCatalogEpisode(
          episodeId: 'episode-1',
          episodeTitle: 'Episode 1',
          episodeNumber: 1,
        ),
      ],
    ),
  ];

  @override
  Future<DanmakuEpisodeRef?> match(
    VideoIdentity video, {
    DanmakuCancelToken? cancelToken,
  }) async => null;
}

class _Repository implements DanmakuScrapeRepository {
  final List<String> videoKeys = [];

  @override
  Future<int> fetchAndCache(
    DanmakuEpisodeRef ref,
    String videoKey, {
    DanmakuCancelToken? cancelToken,
  }) async {
    videoKeys.add(videoKey);
    return 3;
  }

  @override
  Future<bool> hasValidCache(
    String videoKey, {
    bool forceRefresh = false,
    String? episodeId,
  }) async => false;
}
