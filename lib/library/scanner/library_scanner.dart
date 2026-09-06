import 'dart:async';
import 'dart:collection';

import '../models/library_models.dart';
import '../repository/library_repository.dart';

enum ScanState { queued, scanning, complete, failed, cancelled }

class ScanProgress {
  const ScanProgress({
    required this.rootId,
    required this.state,
    required this.discoveredFiles,
    this.error,
  });

  final String rootId;
  final ScanState state;
  final int discoveredFiles;
  final Object? error;
}

abstract interface class LibraryScanner {
  Stream<ScanProgress> get progress;

  Future<void> refreshRoots(List<LibraryRoot> roots);

  void cancel(String scanId);
}

class CoordinatedLibraryScanner implements LibraryScanner {
  CoordinatedLibraryScanner({
    required this.repository,
    required Iterable<LibrarySourceAdapter> adapters,
    required this.metadataResolver,
    DateTime Function()? clock,
  }) : _adapters = {for (final adapter in adapters) adapter.sourceId: adapter},
       _clock = clock ?? DateTime.now;

  static const int batchSize = 100;
  static const Duration batchInterval = Duration(seconds: 1);

  final LibraryRepository repository;
  final Map<String, LibrarySourceAdapter> _adapters;
  final MetadataResolver metadataResolver;
  final DateTime Function() _clock;
  final StreamController<ScanProgress> _progress =
      StreamController<ScanProgress>.broadcast();
  final Set<String> _cancelled = {};
  int _generationCounter = 0;

  @override
  Stream<ScanProgress> get progress => _progress.stream;

  @override
  Future<void> refreshRoots(List<LibraryRoot> roots) async {
    final grouped = <String, List<LibraryRoot>>{};
    for (final root in roots) {
      (grouped[root.sourceId] ??= []).add(root);
      _progress.add(
        ScanProgress(
          rootId: root.id,
          state: ScanState.queued,
          discoveredFiles: 0,
        ),
      );
    }
    final groups = Queue<List<LibraryRoot>>.of(grouped.values);
    final workers = <Future<void>>[];
    final workerCount = groups.length < 2 ? groups.length : 2;
    for (var i = 0; i < workerCount; i++) {
      workers.add(_runSourceGroups(groups));
    }
    await Future.wait(workers);
  }

  Future<void> _runSourceGroups(Queue<List<LibraryRoot>> groups) async {
    while (groups.isNotEmpty) {
      final roots = groups.removeFirst();
      // Roots for one source stay sequential so native clients do not receive
      // overlapping directory requests for the same authenticated server.
      for (final root in roots) {
        await _refreshRoot(root);
      }
    }
  }

  Future<void> _refreshRoot(LibraryRoot root) async {
    final adapter = _adapters[root.sourceId];
    final generation =
        '${_clock().microsecondsSinceEpoch}:${_generationCounter++}';
    if (adapter == null) {
      _progress.add(
        ScanProgress(
          rootId: root.id,
          state: ScanState.failed,
          discoveredFiles: 0,
          error: StateError('No adapter for source ${root.sourceId}'),
        ),
      );
      return;
    }
    _cancelled.remove(root.id);
    await repository.applyScanBatch(
      ScanBatch(rootId: root.id, generation: generation, isStart: true),
    );
    _progress.add(
      ScanProgress(
        rootId: root.id,
        state: ScanState.scanning,
        discoveredFiles: 0,
      ),
    );

    final queue = Queue<_QueuedDirectory>()
      ..add(_QueuedDirectory(root.directory, const []));
    final visited = <String>{};
    final seen = <String>{};
    final staged = <MatchResult>[];
    final identifying = <Future<void>>[];
    var lastFlush = _clock();

    Future<void> flush() async {
      if (staged.isEmpty) return;
      final ready = List<MatchResult>.of(staged);
      staged.clear();
      await repository.applyScanBatch(
        ScanBatch(
          rootId: root.id,
          generation: generation,
          files: [for (final result in ready) result.file],
          titles: [
            for (final result in ready)
              if (result.title != null) result.title!,
          ],
          episodes: [
            for (final result in ready)
              if (result.episode != null) result.episode!,
          ],
        ),
      );
      lastFlush = _clock();
    }

    try {
      while (queue.isNotEmpty) {
        _checkCancelled(root.id);
        final queued = queue.removeFirst();
        final canonical = _canonicalDirectory(queued.directory);
        if (!visited.add(canonical)) continue;
        String? cursor;
        do {
          _checkCancelled(root.id);
          final page = await adapter.list(queued.directory, cursor: cursor);
          for (final entry in page.entries) {
            _checkCancelled(root.id);
            if (entry.isDirectory) {
              if (entry.directory != null) {
                queue.add(
                  _QueuedDirectory(entry.directory!, [
                    ...queued.ancestors,
                    if ((queued.directory.contextName ?? '').isNotEmpty)
                      queued.directory.contextName!,
                  ]),
                );
              }
              continue;
            }
            final sourceRef = entry.sourceRef;
            if (sourceRef == null || !_isSupportedVideo(entry.name)) continue;
            final file = MediaFile(
              id: entry.stableId,
              rootIds: {root.id},
              sourceRef: sourceRef,
              originalFileName: entry.name,
              sizeBytes: entry.sizeBytes,
              modifiedAt: entry.modifiedAt,
              discoveredAt: _clock(),
              titleId: entry.serverTitleId,
              episodeId:
                  entry.serverTitleId != null && entry.episodeNumber != null
                  ? '${entry.serverTitleId}:s${entry.seasonNumber ?? 'unknown'}'
                        ':e${entry.episodeNumber}'
                  : null,
              matchOrigin: entry.serverTitleId == null
                  ? null
                  : MatchOrigin.server,
              availability: MediaAvailability.available,
              legacyResumeKey: entry.legacyResumeKey ?? entry.stableId,
            );
            seen.add(file.id);
            // Persist discovery independently of metadata lookup. A slow or
            // unavailable TMDB endpoint must never make an enumerated file
            // disappear from the index.
            staged.add(MatchResult(file: file));
            final context = DiscoveryContext(
              rootId: root.id,
              directoryNames: List.unmodifiable([
                ...queued.ancestors,
                if ((queued.directory.contextName ?? '').isNotEmpty)
                  queued.directory.contextName!,
              ]),
            );
            final task = metadataResolver.resolve(file, context).then((
              result,
            ) async {
              staged.add(result);
              if (staged.length >= batchSize ||
                  _clock().difference(lastFlush) >= batchInterval) {
                await flush();
              }
            });
            identifying.add(task);
            _progress.add(
              ScanProgress(
                rootId: root.id,
                state: ScanState.scanning,
                discoveredFiles: seen.length,
              ),
            );
          }
          cursor = page.nextCursor;
        } while (cursor != null && cursor.isNotEmpty);
      }
      await flush();
      await Future.wait(identifying);
      await flush();
      _checkCancelled(root.id);
      await repository.applyScanBatch(
        ScanBatch(
          rootId: root.id,
          generation: generation,
          isRootComplete: true,
          seenFileIds: seen,
        ),
      );
      _progress.add(
        ScanProgress(
          rootId: root.id,
          state: ScanState.complete,
          discoveredFiles: seen.length,
        ),
      );
    } on _ScanCancelled {
      _progress.add(
        ScanProgress(
          rootId: root.id,
          state: ScanState.cancelled,
          discoveredFiles: seen.length,
        ),
      );
    } catch (error) {
      // No completion batch means old records are retained for this root.
      _progress.add(
        ScanProgress(
          rootId: root.id,
          state: ScanState.failed,
          discoveredFiles: seen.length,
          error: error,
        ),
      );
    }
  }

  @override
  void cancel(String scanId) => _cancelled.add(scanId);

  void _checkCancelled(String rootId) {
    if (_cancelled.contains(rootId)) throw const _ScanCancelled();
  }

  static String _canonicalDirectory(SourceDirectory directory) =>
      '${directory.sourceId}:${directory.identity.replaceAll('\\', '/').toLowerCase()}';

  static bool _isSupportedVideo(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return const {
      'mkv',
      'mp4',
      'm4v',
      'mov',
      'avi',
      'webm',
      'wmv',
      'flv',
      'ogv',
      'rmvb',
      'mpg',
      'mpeg',
      'vob',
      'ts',
      'm2ts',
      'mts',
    }.contains(name.substring(dot + 1).toLowerCase());
  }
}

class _QueuedDirectory {
  const _QueuedDirectory(this.directory, this.ancestors);

  final SourceDirectory directory;
  final List<String> ancestors;
}

class _ScanCancelled implements Exception {
  const _ScanCancelled();
}
