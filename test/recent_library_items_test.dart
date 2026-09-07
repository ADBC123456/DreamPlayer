import 'package:dream_player/library/models/library_models.dart';
import 'package:dream_player/library/repository/library_repository.dart';
import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/services/continue_watching.dart';
import 'package:dream_player/services/recent_library_items.dart';
import 'package:dream_player/services/tmdb_client.dart';
import 'package:flutter_test/flutter_test.dart';

ContinueWatchingEntry entry(
  String id,
  int time, {
  String? titleId,
  int episode = 1,
  int season = 1,
  int minutes = 1,
}) => ContinueWatchingEntry(
  video: VideoItem(
    id: id,
    title: '000$episode.mkv',
    resumeKey: id,
    duration: const Duration(minutes: 30),
    metadataContext: titleId == null
        ? null
        : VideoMetadataContext(
            titleId: titleId,
            displayTitle: '凡人修仙传',
            seasonNumber: season,
            episodeNumber: episode,
            revision: 0,
          ),
  ),
  position: Duration(minutes: minutes),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(time),
);

void main() {
  test(
    'retains saved episode identity when only title metadata remains indexed',
    () {
      const title = MediaTitle(
        id: 'tmdb:tv:1',
        kind: MediaTitleKind.tv,
        tmdbId: 1,
        displayTitle: '凡人修仙传',
      );
      final recent = recentLibraryItems([
        entry('outside-root', 1, titleId: title.id, episode: 93),
      ], LibrarySnapshot(titles: {title.id: title}));
      expect(recent.single.metadata?.episodeNumber, 93);
      expect(recent.single.metadata?.seasonNumber, 1);
    },
  );
  test(
    'one latest playback per title across seasons and sources, without mutating history',
    () {
      final history = [
        entry(
          'webdav/e99',
          100,
          titleId: 'tmdb:tv:1',
          episode: 99,
          minutes: 20,
        ),
        entry('movie', 300, titleId: 'tmdb:movie:2'),
        entry('smb/e1', 400, titleId: 'tmdb:tv:1', season: 2, minutes: 2),
        entry('other', 200, titleId: 'tmdb:tv:3'),
      ];
      final recent = recentLibraryItems(history, const LibrarySnapshot());
      expect(recent.map((e) => e.entry.video.id), ['smb/e1', 'movie', 'other']);
      expect(recent.first.metadata?.seasonNumber, 2);
      expect(recent.first.entry.position, const Duration(minutes: 2));
      expect(history, hasLength(4));
      expect(history.first.video.id, 'webdav/e99');
    },
  );

  test(
    'legacy numeric filenames use indexed identity and corrected episode',
    () {
      const title = MediaTitle(
        id: 'tmdb:tv:8',
        kind: MediaTitleKind.tv,
        tmdbId: 8,
        displayTitle: '沧元图',
        backdrop: 'backdrop',
        revision: 3,
      );
      const episode = LibraryEpisode(
        id: 'ep',
        titleId: 'tmdb:tv:8',
        seasonNumber: 0,
        episodeNumber: 2,
        displayName: '特别篇',
        still: 'still',
      );
      MediaFile file(String key) => MediaFile(
        id: key,
        rootIds: const {'root'},
        sourceRef: const MediaSourceRef(
          sourceId: 'server',
          sourceType: 'webdav',
          path: '/',
        ),
        originalFileName: '0002.mkv',
        titleId: title.id,
        episodeId: episode.id,
        legacyResumeKey: key,
      );
      final recent = recentLibraryItems(
        [entry('old', 1), entry('new', 2, titleId: 'wrong')],
        LibrarySnapshot(
          titles: {title.id: title},
          episodes: {episode.id: episode},
          files: {'old': file('old'), 'new': file('new')},
        ),
      );
      expect(recent, hasLength(1));
      expect(recent.first.displayTitle, '沧元图');
      expect(recent.first.artwork, 'still');
      expect(recent.first.metadata?.seasonNumber, 0);
      expect(recent.first.metadata?.episodeNumber, 2);
      expect(recent.first.metadata?.revision, 3);
    },
  );

  test('unknown files with the same filename remain separate', () {
    final recent = recentLibraryItems([
      entry('serverA/file', 1),
      entry('serverB/file', 2),
    ], const LibrarySnapshot());
    expect(recent, hasLength(2));
  });

  test(
    'legacy metadata shares title identity but separates movie and tv ids',
    () {
      final recent = recentLibraryItems(
        [entry('tv1', 1), entry('tv2', 2), entry('movie', 3)],
        const LibrarySnapshot(),
        legacyMetadata: (video) => TmdMeta(
          movie: TmdMovie(
            id: 7,
            title: 'Title',
            kind: video.id == 'movie' ? TmdKind.movie : TmdKind.tv,
          ),
        ),
      );
      expect(recent.map((e) => e.entry.video.id), ['movie', 'tv2']);
    },
  );
}
