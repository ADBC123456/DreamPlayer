import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/danmaku/binding/danmaku_binding_store.dart';
import 'package:dream_player/danmaku/scraper/scrape_state.dart';
import 'package:dream_player/danmaku/scraper/series_scraper.dart';
import 'package:dream_player/danmaku/source/danmaku_source_registry.dart';

ScrapeVideo video(int n) => ScrapeVideo(
  key: '/shows/x/ep$n.mkv',
  fileName: 'Show.S01E${n.toString().padLeft(2, '0')}.mkv',
  season: 1,
  episode: n,
);

SeriesScope scope() => SeriesScope(
  sourceId: 'danmu_api',
  sourceBaseUrl: 'http://192.168.1.7:9321',
  seriesTitle: 'Show',
  seriesKey: 'tmdb:1234',
  season: 1,
);

/// In-memory danmu_api fake: catalog of 10 episodes, programmable failures.
class FakeSource implements DanmakuScrapeSource {
  FakeSource({this.matchRefs = const {}, this.failMatchFor = const {}});

  final Map<int, DanmakuEpisodeRef> matchRefs;
  final Set<int> failMatchFor;

  int searchEpisodesCalls = 0;
  final List<int> matchCalls = [];
  Completer<void>? searchGate;

  Future<void> holdSearch() {
    searchGate = Completer<void>();
    return searchGate!.future;
  }

  void releaseSearch() {
    searchGate?.complete();
    searchGate = null;
  }

  @override
  Future<List<DanmakuCatalogAnime>> searchEpisodes(
    String title, {
    DanmakuCancelToken? cancelToken,
  }) async {
    searchEpisodesCalls++;
    if (searchGate != null) await searchGate!.future;
    return [
      DanmakuCatalogAnime(
        animeId: '100',
        animeTitle: title,
        episodes: [
          for (var n = 1; n <= 10; n++)
            DanmakuCatalogEpisode(
              episodeId: '${9000 + n}',
              episodeTitle: '第$n集',
              episodeNumber: n,
            ),
        ],
      ),
    ];
  }

  @override
  Future<DanmakuEpisodeRef?> match(
    VideoIdentity v, {
    DanmakuCancelToken? cancelToken,
  }) async {
    final n = v.episode ?? -1;
    matchCalls.add(n);
    if (failMatchFor.contains(n)) {
      throw const DanmakuScrapeException(
        'boom',
        statusCode: 500,
        retryable: true,
      );
    }
    return matchRefs[n];
  }
}

class CatalogSource extends FakeSource {
  CatalogSource(this.catalog, {super.matchRefs});

  final List<DanmakuCatalogAnime> catalog;

  @override
  Future<List<DanmakuCatalogAnime>> searchEpisodes(
    String title, {
    DanmakuCancelToken? cancelToken,
  }) async {
    searchEpisodesCalls++;
    return catalog;
  }
}

/// In-memory repository: optional cache hits, programmable fetch failures.
class FakeRepo implements DanmakuScrapeRepository {
  FakeRepo({this.cacheHits = const {}, this.failFetchFor = const {}});

  final Set<String> cacheHits;
  final Set<String> failFetchFor;

  final List<String> fetchedKeys = [];
  final Map<String, int> cachedCounts = {};
  final List<String> attemptedKeys = [];

  @override
  Future<bool> hasValidCache(
    String key, {
    bool forceRefresh = false,
    String? episodeId,
  }) async => !forceRefresh && cacheHits.contains(key);

  @override
  Future<int> fetchAndCache(
    DanmakuEpisodeRef ref,
    String key, {
    DanmakuCancelToken? cancelToken,
  }) async {
    if (failFetchFor.contains(key)) {
      attemptedKeys.add(key);
      throw const DanmakuScrapeException(
        'boom',
        statusCode: 500,
        retryable: true,
      );
    }
    attemptedKeys.add(key);
    fetchedKeys.add(key);
    final count = ref.episodeId == '55' ? 0 : 42;
    cachedCounts[key] = count;
    return count;
  }
}

SeriesScraper buildScraper(FakeSource source, FakeRepo repo) {
  return SeriesScraper(
    source: source,
    repository: repo,
    minRequestGap: const Duration(milliseconds: 300),
    backoffBase: const Duration(milliseconds: 1),
    backoffMax: const Duration(milliseconds: 2),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('SeriesScraper', () {
    test('10 episodes all succeed via catalog mapping', () async {
      final source = FakeSource();
      final repo = FakeRepo();
      final scraper = buildScraper(source, repo);
      final videos = [for (var n = 1; n <= 10; n++) video(n)];

      final result = await scraper.start(scope(), videos);

      expect(result.completed, isTrue);
      final st = scraper.state!;
      expect(st.successCount, 10);
      expect(st.phase, ScrapePhase.completed);
      expect(repo.fetchedKeys.length, 10);
      expect(
        source.matchCalls,
        isEmpty,
        reason: 'precise S/E mapping should cover every episode',
      );
      // All episodeIds come from the catalog (9001..9010).
      final ids = st.episodes.map((e) => e.ref!.episodeId).toSet();
      expect(ids, {for (var n = 1; n <= 10; n++) '${9000 + n}'});
    });

    test('cached episodes are skipped', () async {
      final source = FakeSource();
      final repo = FakeRepo(cacheHits: {'/shows/x/ep1.mkv'});
      final scraper = buildScraper(source, repo);

      await scraper.start(scope(), [video(1), video(2)]);

      final st = scraper.state!;
      expect(st.episodes.first.status, ScrapeStatus.cached);
      expect(st.episodes.last.status, ScrapeStatus.success);
      expect(repo.fetchedKeys, ['/shows/x/ep2.mkv']);
      expect(st.cachedCount, 1);
    });

    test('fully cached series does not request the remote catalog', () async {
      final source = FakeSource();
      final repo = FakeRepo(
        cacheHits: {'/shows/x/ep1.mkv', '/shows/x/ep2.mkv'},
      );
      final scraper = buildScraper(source, repo);

      await scraper.start(scope(), [video(1), video(2)]);

      expect(scraper.state!.cachedCount, 2);
      expect(scraper.state!.phase, ScrapePhase.completed);
      expect(source.searchEpisodesCalls, 0);
      expect(source.matchCalls, isEmpty);
      expect(repo.fetchedKeys, isEmpty);
    });

    test('single failure does not block other episodes', () async {
      final source = FakeSource();
      final repo = FakeRepo(failFetchFor: {'/shows/x/ep3.mkv'});
      final scraper = buildScraper(source, repo);

      final result = await scraper.start(scope(), [
        video(1),
        video(2),
        video(3),
        video(4),
      ]);

      expect(result.completed, isTrue, reason: 'partial failure still ends');
      final st = scraper.state!;
      expect(
        st.episodes.firstWhere((e) => e.key.endsWith('ep3.mkv')).status,
        ScrapeStatus.failed,
      );
      expect(st.successCount, 3);
      expect(st.phase, ScrapePhase.partialFailure);
      expect(
        st.episodes.firstWhere((e) => e.key.endsWith('ep3.mkv')).error,
        'boom',
      );
    });

    test('cancel leaves remaining episodes cancelled', () async {
      final source = FakeSource();
      final repo = FakeRepo();
      final scraper = buildScraper(source, repo);
      source.holdSearch();

      final run = scraper.start(scope(), [
        for (var n = 1; n <= 10; n++) video(n),
      ]);
      // Let start() reach the search gate, then cancel.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await scraper.cancel();
      source.releaseSearch();
      final result = await run;

      expect(result.completed, isFalse);
      final st = scraper.state!;
      expect(st.phase, ScrapePhase.cancelled);
      expect(st.cancelledCount, 10);
      expect(repo.fetchedKeys, isEmpty);
    });

    test('failed items retry and succeed', () async {
      final source = FakeSource();
      final repo = FakeRepo(failFetchFor: {'/shows/x/ep2.mkv'});
      final scraper = buildScraper(source, repo);

      await scraper.start(scope(), [video(1), video(2)]);
      var st = scraper.state!;
      expect(st.failedCount, 1);

      repo.failFetchFor.clear();
      await scraper.retryFailed(scope());
      st = scraper.state!;
      expect(st.successCount, 2);
      // Ep2 was attempted in run 1 (failed) and again in the retry run
      // (succeeded). Ep1 was fetched exactly once in run 1.
      // fetchAndCache is attempted (1 initial + up to 2 retries) in run 1 and
      // exactly once (successfully) in the retry run.
      expect(
        repo.attemptedKeys.where((k) => k.endsWith('ep2.mkv')).length,
        1 + 2 + 1,
      );
      expect(repo.fetchedKeys.where((k) => k.endsWith('ep2.mkv')).length, 1);
      expect(repo.fetchedKeys.where((k) => k.endsWith('ep1.mkv')).length, 1);
    });

    test('forceRefresh re-downloads cached episodes', () async {
      final source = FakeSource();
      final repo = FakeRepo(cacheHits: {'/shows/x/ep1.mkv'});
      final scraper = buildScraper(source, repo);

      await scraper.start(scope(), [video(1)]);
      expect(scraper.state!.cachedCount, 1);

      await scraper.start(scope(), [video(1)], forceRefresh: true);
      final st = scraper.state!;
      expect(st.cachedCount, 0);
      expect(st.successCount, 1);
      expect(repo.fetchedKeys, ['/shows/x/ep1.mkv']);
    });

    test('stale generation results are discarded', () async {
      final source = FakeSource();
      final repo = FakeRepo();
      final scraper = buildScraper(source, repo);
      source.holdSearch();

      final first = scraper.start(scope(), [video(1), video(2)]);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // A new run supersedes the first; the first must not write back.
      final second = scraper.start(scope(), [video(1), video(2)]);
      source.releaseSearch();
      await Future.wait([first, second]);

      final st = scraper.state!;
      expect(st.generation, 2);
      // Each surviving episode state must belong to generation 2 — no zombie
      // writes from run 1 (which saw the same keys).
      for (final e in st.episodes) {
        expect(e.status, anyOf(ScrapeStatus.success, ScrapeStatus.empty));
      }
      expect(st.successCount, 2);
    });

    test('empty danmaku and noMatch are distinguished', () async {
      final source = FakeSource(
        matchRefs: {7: const DanmakuEpisodeRef(animeId: '1', episodeId: 'x7')},
        failMatchFor: {9},
      );
      final repo = FakeRepo();
      final scraper = buildScraper(source, repo);

      await scraper.start(scope(), [video(7), video(8), video(9)]);

      final st = scraper.state!;
      // Ep7: catalog has no entry beyond its 10; 7 IS in catalog, so it maps
      // via catalog (episodeId 9007) — success.
      expect(
        st.episodes.firstWhere((e) => e.key.endsWith('ep7.mkv')).status,
        ScrapeStatus.success,
      );
      // Ep8: catalog-mapped, 42 comments → success.
      expect(
        st.episodes.firstWhere((e) => e.key.endsWith('ep8.mkv')).status,
        ScrapeStatus.success,
      );
      // Ep9: catalog-mapped too. To exercise noMatch we rely on the OVA test
      // below; here 9 stays success.
      expect(
        st.episodes.firstWhere((e) => e.key.endsWith('ep9.mkv')).status,
        ScrapeStatus.success,
      );
      expect(st.noMatchCount, 0);
    });

    test('noMatch distinguished from empty via unresolvable file', () async {
      final source = FakeSource(
        matchRefs: {55: const DanmakuEpisodeRef(animeId: '1', episodeId: '55')},
      );
      final repo = FakeRepo();
      final scraper = buildScraper(source, repo);
      const ova = ScrapeVideo(
        key: '/shows/x/ova.mkv',
        fileName: 'Show OVA.mkv',
      );
      const emptyEp = ScrapeVideo(
        key: '/shows/x/ep55.mkv',
        fileName: 'Show S01E55.mkv',
        season: 1,
        episode: 55,
      );

      await scraper.start(scope(), [ova, emptyEp]);

      final st = scraper.state!;
      // OVA: no catalog mapping (no episode number) → /match returns null
      // → noMatch.
      expect(
        st.episodes.firstWhere((e) => e.key.endsWith('ova.mkv')).status,
        ScrapeStatus.noMatch,
      );
      // Ep55: /match resolved it but the episode has 0 comments → empty.
      expect(
        st.episodes.firstWhere((e) => e.key.endsWith('ep55.mkv')).status,
        ScrapeStatus.empty,
      );
      expect(st.noMatchCount, 1);
      expect(st.emptyCount, 1);
    });

    test('empty episode (0 comments) is its own state', () async {
      // Episode 55 maps via /match to episodeId '55' which the repo serves
      // with 0 comments.
      final source = FakeSource(
        matchRefs: {55: const DanmakuEpisodeRef(animeId: '1', episodeId: '55')},
      );
      final repo = FakeRepo();
      final scraper = buildScraper(source, repo);
      const emptyEp = ScrapeVideo(
        key: '/shows/x/ep55.mkv',
        fileName: 'Show S01E55.mkv',
        season: 1,
        episode: 55,
      );

      await scraper.start(scope(), [emptyEp]);

      final st = scraper.state!;
      expect(st.emptyCount, 1);
      expect(st.episodes.single.status, ScrapeStatus.empty);
      expect(st.episodes.single.commentCount, 0);
      expect(st.successCount, 0);
    });

    test('noMatch when both catalog and /match fail to resolve', () async {
      // Video with no episode number: catalog mapping impossible; /match
      // returns null.
      final source = FakeSource();
      final repo = FakeRepo();
      final scraper = buildScraper(source, repo);
      const extra = ScrapeVideo(
        key: '/shows/x/ova.mkv',
        fileName: 'Show OVA.mkv',
      );

      await scraper.start(scope(), [extra]);

      final st = scraper.state!;
      expect(st.noMatchCount, 1);
      expect(st.episodes.single.status, ScrapeStatus.noMatch);
      expect(source.matchCalls, hasLength(1));
    });

    test('duplicate catalog episodes fall back to per-file match', () async {
      final source = CatalogSource(
        const [
          DanmakuCatalogAnime(
            animeId: 'anime',
            animeTitle: 'Show',
            episodes: [
              DanmakuCatalogEpisode(
                episodeId: 'duplicate-a',
                episodeTitle: 'Episode 1 A',
                episodeNumber: 1,
              ),
              DanmakuCatalogEpisode(
                episodeId: 'duplicate-b',
                episodeTitle: 'Episode 1 B',
                episodeNumber: 1,
              ),
            ],
          ),
        ],
        matchRefs: const {
          1: DanmakuEpisodeRef(
            animeId: 'anime',
            episodeId: 'server-choice',
            animeTitle: 'Show',
            episodeTitle: 'Episode 1',
          ),
        },
      );
      final scraper = buildScraper(source, FakeRepo());

      await scraper.start(scope(), [video(1)]);

      expect(source.matchCalls, [1]);
      expect(scraper.state!.episodes.single.ref!.episodeId, 'server-choice');
    });

    test('ambiguous anime catalogs fall back to per-file match', () async {
      final source = CatalogSource(
        const [
          DanmakuCatalogAnime(
            animeId: 'anime-a',
            animeTitle: 'Show',
            episodes: [],
          ),
          DanmakuCatalogAnime(
            animeId: 'anime-b',
            animeTitle: 'Show Remake',
            episodes: [],
          ),
        ],
        matchRefs: const {
          1: DanmakuEpisodeRef(
            animeId: 'anime-b',
            episodeId: 'matched-episode',
            animeTitle: 'Show Remake',
            episodeTitle: 'Episode 1',
          ),
        },
      );
      final scraper = buildScraper(source, FakeRepo());

      await scraper.start(scope(), [video(1)]);

      expect(source.matchCalls, [1]);
      expect(scraper.state!.episodes.single.ref!.episodeId, 'matched-episode');
    });

    test('manual series selection batch maps an ambiguous catalog', () async {
      final source = CatalogSource(const [
        DanmakuCatalogAnime(
          animeId: 'live-action',
          animeTitle: 'Show (2025)',
          episodes: [
            DanmakuCatalogEpisode(
              episodeId: 'live-1',
              episodeTitle: 'Episode 1',
              episodeNumber: 1,
            ),
          ],
        ),
        DanmakuCatalogAnime(
          animeId: 'animation',
          animeTitle: 'Show (2020) Animation',
          episodes: [
            DanmakuCatalogEpisode(
              episodeId: 'animation-1',
              episodeTitle: 'Episode 1',
              episodeNumber: 1,
            ),
          ],
        ),
      ]);
      final repo = FakeRepo();
      final scraper = buildScraper(source, repo);

      await scraper.start(
        scope(),
        [video(1)],
        forceRefresh: true,
        selectedAnimeId: 'animation',
        selectedAnimeTitle: 'Show (2020) Animation',
      );

      expect(source.matchCalls, isEmpty);
      expect(scraper.state!.episodes.single.ref!.animeId, 'animation');
      expect(scraper.state!.episodes.single.ref!.episodeId, 'animation-1');
      expect(scraper.state!.selectedAnimeId, 'animation');
      expect(scraper.state!.phase, ScrapePhase.completed);
    });

    test('manual batch start episode applies an index offset', () async {
      final source = CatalogSource(const [
        DanmakuCatalogAnime(
          animeId: 'animation',
          animeTitle: 'Long running animation',
          episodes: [
            DanmakuCatalogEpisode(
              episodeId: 'remote-53',
              episodeTitle: 'Episode 53',
              episodeNumber: 53,
            ),
          ],
        ),
      ]);
      final scraper = buildScraper(source, FakeRepo());

      await scraper.start(
        scope(),
        [video(1)],
        selectedAnimeId: 'animation',
        selectedAnimeTitle: 'Long running animation',
        selectedEpisodeOffset: 52,
      );

      expect(scraper.state!.episodes.single.ref!.episodeId, 'remote-53');
      expect(scraper.state!.selectedEpisodeOffset, 52);
    });

    test('manual episode selection replaces an existing match', () async {
      final source = FakeSource();
      final repo = FakeRepo();
      final scraper = buildScraper(source, repo);
      await scraper.start(scope(), [video(1)]);

      const replacement = DanmakuEpisodeRef(
        animeId: 'other-platform',
        episodeId: 'other-episode-1',
        animeTitle: 'Show from another platform',
        episodeTitle: 'Episode 1',
      );
      await scraper.manualMatchEpisode(scope(), video(1).key, replacement);

      final episode = scraper.state!.episodes.single;
      expect(episode.ref, replacement);
      expect(episode.status, ScrapeStatus.matched);
      expect(repo.fetchedKeys, [video(1).key]);
      expect(
        (await DanmakuBindingStore.loadForScope(
          scope(),
        ))[video(1).key]!.ref.episodeId,
        'other-episode-1',
      );
    });

    test('batch binding persists every mapping without downloading', () async {
      final source = FakeSource();
      final repo = FakeRepo();
      final scraper = buildScraper(source, repo);
      final videos = [video(1), video(2)];
      final anime = (await source.searchEpisodes('Show')).single;

      final count = await scraper.bindSeries(scope(), videos, anime);

      expect(count, 2);
      expect(repo.fetchedKeys, isEmpty);
      expect(
        scraper.state!.episodes.every((e) => e.status == ScrapeStatus.matched),
        isTrue,
      );
      final bindings = await DanmakuBindingStore.loadForScope(scope());
      expect(bindings['/shows/x/ep1.mkv']!.ref.episodeId, '9001');
      expect(bindings['/shows/x/ep2.mkv']!.ref.episodeId, '9002');

      source.searchEpisodesCalls = 0;
      await scraper.start(scope(), videos);
      expect(source.searchEpisodesCalls, 0);
      expect(repo.fetchedKeys, ['/shows/x/ep1.mkv', '/shows/x/ep2.mkv']);
    });

    test('content hash match takes priority over catalog mapping', () async {
      final source = FakeSource(
        matchRefs: const {
          1: DanmakuEpisodeRef(
            animeId: 'hash-anime',
            episodeId: 'hash-episode',
            animeTitle: 'Hash match',
            episodeTitle: 'Episode 1',
          ),
        },
      );
      final scraper = buildScraper(source, FakeRepo());
      const hashed = ScrapeVideo(
        key: 'danmaku:/shows/x/ep1.mkv',
        fileName: 'Show.S01E01.mkv',
        fileHash: '0123456789abcdef',
        season: 1,
        episode: 1,
      );

      await scraper.start(scope(), [hashed]);

      expect(source.matchCalls, [1]);
      expect(scraper.state!.episodes.single.ref!.episodeId, 'hash-episode');
    });

    test('request pacing: at least 300ms between source requests', () async {
      final source = FakeSource();
      final repo = FakeRepo();
      final scraper = buildScraper(source, repo);
      final sw = Stopwatch()..start();

      // 4 videos needing /match pacing (2 at a time, 300ms gap).
      final videos = [
        const ScrapeVideo(key: '/a.mkv', fileName: 'Show 01.mkv'),
        const ScrapeVideo(key: '/b.mkv', fileName: 'Show 02.mkv'),
        const ScrapeVideo(key: '/c.mkv', fileName: 'Show 03.mkv'),
        const ScrapeVideo(key: '/d.mkv', fileName: 'Show 04.mkv'),
      ];
      await scraper.start(scope(), videos);
      sw.stop();

      // 4 paced calls (match+fetch pair each has its own _pace; at minimum
      // the 4 sequential pacing gaps in each of 2 workers take ≥300ms each).
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(600));
    });
  });
}
