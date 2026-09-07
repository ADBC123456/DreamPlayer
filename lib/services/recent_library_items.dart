import '../library/models/library_models.dart';
import '../library/repository/library_repository.dart';
import '../models/video_item.dart';
import 'continue_watching.dart';
import 'tmdb_client.dart';

class RecentLibraryItem {
  const RecentLibraryItem({
    required this.key,
    required this.entry,
    this.title,
    this.episode,
    this.legacyMeta,
    this.file,
  });

  final String key;
  final ContinueWatchingEntry entry;
  final MediaTitle? title;
  final LibraryEpisode? episode;
  final TmdMeta? legacyMeta;
  final MediaFile? file;

  VideoMetadataContext? get metadata => entry.video.metadataContext;
  String get displayTitle =>
      title?.displayTitle ??
      metadata?.displayTitle ??
      legacyMeta?.movie.title ??
      entry.video.title;
  String? get artwork =>
      episode?.still ??
      title?.backdrop ??
      legacyMeta?.movie.backdropUrl() ??
      title?.poster ??
      legacyMeta?.movie.posterUrl();
}

/// A display projection only: full per-file history remains in the store.
/// Current library mappings take precedence over stale playback metadata.
List<RecentLibraryItem> recentLibraryItems(
  List<ContinueWatchingEntry> entries,
  LibrarySnapshot snapshot, {
  TmdMeta? Function(VideoItem)? legacyMetadata,
}) {
  final byResumeKey = <String, MediaFile>{};
  for (final file in snapshot.files.values) {
    if (file.legacyResumeKey.isNotEmpty) {
      byResumeKey[file.legacyResumeKey] = file;
    }
  }
  final sorted = entries.toList()
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  final seen = <String>{};
  final result = <RecentLibraryItem>[];
  for (final entry in sorted) {
    final video = entry.video;
    final resumeKey = ContinueWatchingStore.keyFor(video);
    final file = byResumeKey[resumeKey];
    final context = video.metadataContext;
    final meta = file == null ? legacyMetadata?.call(video) : null;
    final titleId = file != null ? file.titleId : context?.titleId;
    final title = snapshot.titles[titleId];
    final episode = file != null
        ? snapshot.episodes[file.episodeId]
        : snapshot.episodes.values
              .where(
                (episode) =>
                    episode.titleId == titleId &&
                    episode.seasonNumber == context?.seasonNumber &&
                    episode.episodeNumber == context?.episodeNumber,
              )
              .firstOrNull;
    // A library file with no title has explicitly lost its previous mapping.
    final key = titleId != null && titleId.isNotEmpty
        ? titleId
        : file == null && meta != null
        ? 'tmdb:${meta.movie.kind.name}:${meta.movie.id}'
        : 'file:${resumeKey.isEmpty ? video.id : resumeKey}';
    if (!seen.add(key)) continue;
    final currentMetadata = title == null
        ? (file == null ? context : null)
        : VideoMetadataContext(
            titleId: title.id,
            displayTitle: title.displayTitle,
            originalTitle: title.originalTitle,
            seasonNumber: file == null
                ? episode?.seasonNumber ?? context?.seasonNumber
                : episode?.seasonNumber,
            episodeNumber: file == null
                ? episode?.episodeNumber ?? context?.episodeNumber
                : episode?.episodeNumber,
            episodeTitle: file == null
                ? episode?.displayName ?? context?.episodeTitle
                : episode?.displayName,
            revision: title.revision,
          );
    result.add(
      RecentLibraryItem(
        key: key,
        title: title,
        episode: episode,
        file: file,
        legacyMeta: meta,
        entry: ContinueWatchingEntry(
          video: video.withMetadataContext(currentMetadata),
          position: entry.position,
          updatedAt: entry.updatedAt,
        ),
      ),
    );
  }
  return result;
}
