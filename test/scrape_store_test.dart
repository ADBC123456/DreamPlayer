import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/danmaku/scraper/scrape_state.dart';
import 'package:dream_player/danmaku/scraper/scrape_store.dart';

SeriesScope scopeA() => SeriesScope(
  sourceId: 'danmu_api',
  sourceBaseUrl: 'http://192.168.1.7:9321',
  seriesTitle: 'Show',
  seriesKey: 'tmdb:1234',
);

SeriesScope scopeB() => SeriesScope(
  sourceId: 'danmu_api',
  sourceBaseUrl: 'http://192.168.1.7:9321',
  seriesTitle: 'Show',
  seriesKey: 'tmdb:9999',
);

SeriesScope otherServer() => SeriesScope(
  sourceId: 'danmu_api',
  sourceBaseUrl: 'http://10.0.0.2:9321',
  seriesTitle: 'Show',
  seriesKey: 'tmdb:1234',
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ScrapeStore', () {
    test('save + load round-trips terminal states', () async {
      final scope = scopeA();
      final st = SeriesScrapeState(
        scope: scope,
        selectedAnimeId: '100',
        selectedAnimeTitle: 'Show from platform A',
        selectedEpisodeOffset: 52,
        episodes: [
          ScrapeEpisodeState(
            key: '/a.mkv',
            fileName: 'a.mkv',
            status: ScrapeStatus.success,
            ref: const DanmakuEpisodeRef(
              animeId: '100',
              episodeId: '9001',
              animeTitle: 'Show',
              episodeTitle: '第1集',
            ),
            commentCount: 42,
            fetchedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
          ),
          const ScrapeEpisodeState(
            key: '/b.mkv',
            fileName: 'b.mkv',
            status: ScrapeStatus.failed,
            error: 'boom',
          ),
          const ScrapeEpisodeState(
            key: '/c.mkv',
            fileName: 'c.mkv',
            status: ScrapeStatus.noMatch,
          ),
          const ScrapeEpisodeState(
            key: '/d.mkv',
            fileName: 'd.mkv',
            status: ScrapeStatus.cached,
          ),
          const ScrapeEpisodeState(
            key: '/e.mkv',
            fileName: 'e.mkv',
            status: ScrapeStatus.empty,
            commentCount: 0,
          ),
        ],
      );
      st.phase = ScrapePhase.partialFailure;

      await ScrapeStore.saveTask(st);
      final loaded = await ScrapeStore.loadTask(scope);

      expect(loaded, isNotNull);
      expect(loaded!.episodes, hasLength(5));
      expect(loaded.episodes[0].status, ScrapeStatus.success);
      expect(loaded.episodes[0].ref!.episodeId, '9001');
      expect(loaded.episodes[0].commentCount, 42);
      expect(loaded.episodes[1].status, ScrapeStatus.failed);
      expect(loaded.episodes[1].error, 'boom');
      expect(loaded.episodes[2].status, ScrapeStatus.noMatch);
      expect(loaded.episodes[3].status, ScrapeStatus.cached);
      expect(loaded.episodes[4].status, ScrapeStatus.empty);
      expect(loaded.phase, ScrapePhase.partialFailure);
      expect(loaded.selectedAnimeId, '100');
      expect(loaded.selectedAnimeTitle, 'Show from platform A');
      expect(loaded.selectedEpisodeOffset, 52);
    });

    test('transient states reset to pending on load', () async {
      final scope = scopeA();
      final st = SeriesScrapeState(
        scope: scope,
        episodes: const [
          ScrapeEpisodeState(
            key: '/a.mkv',
            fileName: 'a.mkv',
            status: ScrapeStatus.fetching,
          ),
          ScrapeEpisodeState(
            key: '/b.mkv',
            fileName: 'b.mkv',
            status: ScrapeStatus.matched,
          ),
        ],
      );
      await ScrapeStore.saveTask(st);

      final loaded = await ScrapeStore.loadTask(scope);
      expect(
        loaded!.episodes.every((e) => e.status == ScrapeStatus.pending),
        isTrue,
      );
    });

    test('tasks are isolated per source deployment and series', () async {
      await ScrapeStore.saveTask(
        SeriesScrapeState(
          scope: scopeA(),
          episodes: const [
            ScrapeEpisodeState(
              key: '/a.mkv',
              fileName: 'a.mkv',
              status: ScrapeStatus.success,
            ),
          ],
        ),
      );

      expect(await ScrapeStore.loadTask(scopeB()), isNull);
      expect(await ScrapeStore.loadTask(otherServer()), isNull);
      expect(
        (await ScrapeStore.loadTask(scopeA()))!.episodes.single.key,
        '/a.mkv',
      );
    });

    test('clearTask removes only the given scope', () async {
      await ScrapeStore.saveTask(
        SeriesScrapeState(scope: scopeA(), episodes: const []),
      );
      await ScrapeStore.saveTask(
        SeriesScrapeState(scope: scopeB(), episodes: const []),
      );

      await ScrapeStore.clearTask(scopeA());

      expect(await ScrapeStore.loadTask(scopeA()), isNull);
      expect(await ScrapeStore.loadTask(scopeB()), isNotNull);
    });

    test('loadTask on empty prefs returns null', () async {
      expect(await ScrapeStore.loadTask(scopeA()), isNull);
    });

    test('missing scope entry survives other entries (no crash)', () async {
      // Save A, then clear B (never saved) must not throw nor remove A.
      await ScrapeStore.saveTask(
        SeriesScrapeState(scope: scopeA(), episodes: const []),
      );
      await ScrapeStore.clearTask(scopeB());
      expect(await ScrapeStore.loadTask(scopeA()), isNotNull);
    });
  });
}
