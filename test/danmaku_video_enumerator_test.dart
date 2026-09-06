import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/danmaku/scraper/episode_mapper.dart';
import 'package:dream_player/danmaku/scraper/video_enumerator.dart';
import 'package:dream_player/models/video_item.dart';

/// Fake gateway: folder path → videos (and directories for recursion).
class FakeGateway implements DanmakuListingGateway {
  FakeGateway({this.jellyfinChildren = const {}});

  final Map<String, List<VideoItem>> _videos = {};
  final Map<String, List<(String, String)>> _dirs = {};

  /// Jellyfin parent item id → children.
  final Map<String, List<VideoItem>> jellyfinChildren;

  void addVideos(String path, List<VideoItem> items) =>
      _videos[path] = [...(_videos[path] ?? const []), ...items];

  void addDirs(String path, List<(String, String)> dirs) =>
      _dirs[path] = [...(_dirs[path] ?? const []), ...dirs];

  @override
  Future<FolderListing> listFolder(VideoSource source, String path) async {
    if (source.kind == VideoSourceKind.jellyfin) {
      return FolderListing(
        videos: jellyfinChildren[source.jellyfinItemId ?? ''] ?? const [],
      );
    }
    return FolderListing(
      videos: _videos[path] ?? const [],
      directories: _dirs[path] ?? const [],
    );
  }
}

/// Local-directory fake that walks the real filesystem (proves local path +
/// video filtering + recursion depth end-to-end).
class LocalFsGateway implements DanmakuListingGateway {
  @override
  Future<FolderListing> listFolder(VideoSource source, String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) return const FolderListing();
    final videos = <VideoItem>[];
    final dirs = <(String, String)>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is File) {
        final name = e.path.split(Platform.pathSeparator).last;
        if (!isVideoFileName(name)) continue;
        videos.add(
          VideoItem(
            id: 'fs_${e.path.hashCode}',
            title: name,
            path: e.path,
            duration: Duration.zero,
          ),
        );
      } else if (e is Directory) {
        final name = e.path.split(Platform.pathSeparator).last;
        dirs.add((name, e.path));
      }
    }
    return FolderListing(videos: videos, directories: dirs);
  }
}

class RecordingGateway implements DanmakuListingGateway {
  RecordingGateway(this.folders);

  final Map<String, List<VideoItem>> folders;
  final List<String> requested = [];

  @override
  Future<FolderListing> listFolder(VideoSource source, String path) async {
    requested.add(path);
    return FolderListing(videos: folders[path] ?? const []);
  }
}

VideoItem v(String title, {String? resumeKey, int? size}) => VideoItem(
  id: 'id_$title',
  title: title,
  resumeKey: resumeKey,
  duration: Duration.zero,
  sizeBytes: size,
);

void main() {
  group('isVideoFileName', () {
    test('accepts common containers, rejects others', () {
      expect(isVideoFileName('a.mkv'), isTrue);
      expect(isVideoFileName('b.MP4'), isTrue);
      expect(isVideoFileName('c.ts'), isTrue);
      expect(isVideoFileName('e.srt'), isFalse);
      expect(isVideoFileName('f.nfo'), isFalse);
      expect(isVideoFileName('g.jpg'), isFalse);
      expect(isVideoFileName('noext'), isFalse);
    });
  });

  group('DanmakuVideoEnumerator — local filesystem', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('danmaku_enum');
      // Layout:
      // root/Show S01E01.mkv, note.txt, poster.jpg
      // root/Season 2/Show S02E01.mkv, Show S02E02.mkv
      // root/Season 2/Extras/OVA.mkv, extras/depth3.mkv  (depth 3 → skipped)
      // root/Season 2/Extras/SP01.mp4
      await File('${tmp.path}/Show S01E01.mkv').writeAsBytes([1]);
      await File('${tmp.path}/note.txt').writeAsString('x');
      await File('${tmp.path}/poster.jpg').writeAsBytes([2]);
      final s2 = Directory('${tmp.path}/Season 2')..createSync();
      await File('${s2.path}/Show S02E01.mkv').writeAsBytes([3]);
      await File('${s2.path}/Show S02E02.mkv').writeAsBytes([4]);
      final extras = Directory('${s2.path}/Extras')..createSync();
      await File('${extras.path}/OVA.mkv').writeAsBytes([5]);
      await File('${extras.path}/SP01.mp4').writeAsBytes([6]);
      final deep = Directory('${extras.path}/extras')..createSync();
      await File('${deep.path}/depth3.mkv').writeAsBytes([7]);
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('lists root videos and filters non-video files', () async {
      final enumr = DanmakuVideoEnumerator(gateway: LocalFsGateway());
      final out = await enumr.enumerate(
        VideoSource.local(tmp.path),
        folderName: 'Show',
      );
      final names = out.map((e) => e.item.title).toSet();
      expect(names, contains('Show S01E01.mkv'));
      expect(names, isNot(contains('note.txt')));
      expect(names, isNot(contains('poster.jpg')));
    });

    test('recurses exactly two levels, not three', () async {
      final enumr = DanmakuVideoEnumerator(gateway: LocalFsGateway());
      final out = await enumr.enumerate(
        VideoSource.local(tmp.path),
        folderName: 'Show',
      );
      final names = out.map((e) => e.item.title).toSet();
      // Level 1.
      expect(names, containsAll(['Show S02E01.mkv', 'Show S02E02.mkv']));
      // Level 2.
      expect(names, containsAll(['OVA.mkv', 'SP01.mp4']));
      // Level 3 must be excluded.
      expect(names, isNot(contains('depth3.mkv')));
      // Depth labels.
      final ova = out.firstWhere((e) => e.item.title == 'OVA.mkv');
      expect(ova.depth, VideoDepth.level2);
      final rootEp = out.firstWhere((e) => e.item.title == 'Show S01E01.mkv');
      expect(rootEp.depth, VideoDepth.root);
    });

    test('parses season from subfolder for season-less files', () async {
      final enumr = DanmakuVideoEnumerator(gateway: LocalFsGateway());
      final out = await enumr.enumerate(
        VideoSource.local(tmp.path),
        folderName: 'Show',
      );
      final ep = out.firstWhere((e) => e.item.title == 'Show S02E01.mkv');
      expect(ep.episode.season, 2);
      expect(ep.episode.episode, 1);
      final ova = out.firstWhere((e) => e.item.title == 'OVA.mkv');
      expect(ova.episode.isEpisode, isTrue);
      expect(ova.episode.source, EpisodeSource.special);
    });

    test('missing folder never throws', () async {
      final enumr = DanmakuVideoEnumerator(gateway: LocalFsGateway());
      final out = await enumr.enumerate(VideoSource.local('${tmp.path}/nope'));
      expect(out, isEmpty);
    });
  });

  group('DanmakuVideoEnumerator — fake multi-source', () {
    test('local source via gateway with injected subfolders', () async {
      final gw = FakeGateway()
        ..addVideos('/root', [v('第1集.mkv', size: 10)])
        ..addDirs('/root', [('第2季', '/root/S2')])
        ..addVideos('/root/S2', [v('第1集.mkv'), v('第2集.mkv')]);
      final enumr = DanmakuVideoEnumerator(gateway: gw);
      final out = await enumr.enumerate(VideoSource.local('/root'));

      expect(out, hasLength(3));
      // The subfolder's episodes carry the immediate parent folder name.
      final s2 = out.where((e) => e.parentFolderName == '第2季').toList();
      expect(s2, hasLength(2));
      // Parent name is the immediate folder, so season comes from folder.
      expect(s2.first.parentFolderName, '第2季');
    });

    test('WebDAV source keeps the webdav_ resumeKey shape', () async {
      final gw = FakeGateway()
        ..addVideos('/dav/Show', [
          v('Show S01E01.mkv', resumeKey: 'webdav_srv1/Show S01E01.mkv'),
          v('Show S01E02.mkv', resumeKey: 'webdav_srv1/Show S01E02.mkv'),
        ]);
      final enumr = DanmakuVideoEnumerator(gateway: gw);
      final out = await enumr.enumerate(
        VideoSource.webdav(serverId: 'srv1', path: '/dav/Show'),
        folderName: 'Show',
      );
      expect(out, hasLength(2));
      expect(
        out.every((e) => e.item.resumeKey!.startsWith('webdav_srv1/')),
        isTrue,
      );
      expect(out.map((e) => e.episode.episode), [1, 2]);
    });

    test('FTP source keeps the ftp_ resumeKey shape', () async {
      final gw = FakeGateway()
        ..addVideos('/media', [
          v('Show S01E01.mkv', resumeKey: 'ftp_srv9/media/Show S01E01.mkv'),
        ]);
      final enumr = DanmakuVideoEnumerator(gateway: gw);
      final out = await enumr.enumerate(
        VideoSource.ftp(serverId: 'srv9', path: '/media'),
      );
      expect(out.single.item.resumeKey, 'ftp_srv9/media/Show S01E01.mkv');
    });

    test('SMB source keeps the smb: resumeKey shape', () async {
      final gw = FakeGateway()
        ..addVideos('', [
          v('Show S01E01.mkv', resumeKey: 'smb:srv1/media/Show S01E01.mkv'),
        ]);
      final enumr = DanmakuVideoEnumerator(gateway: gw);
      final out = await enumr.enumerate(
        VideoSource.smb(serverId: 'srv1', share: 'media', path: ''),
      );
      expect(out.single.item.resumeKey, 'smb:srv1/media/Show S01E01.mkv');
    });

    test('Jellyfin children map to stable resume keys and episodes', () async {
      final gw = FakeGateway(
        jellyfinChildren: {
          'series-1': [
            v('Episode 101', resumeKey: 'jellyfin:host/ep-101'),
            v('Episode 102', resumeKey: 'jellyfin:host/ep-102'),
            v('Behind the Scenes', resumeKey: 'jellyfin:host/ep-bts'),
          ],
        },
      );
      final enumr = DanmakuVideoEnumerator(gateway: gw);
      final out = await enumr.enumerate(
        VideoSource.jellyfin(serverUrl: 'http://host:8096', itemId: 'series-1'),
        folderName: 'Show',
      );
      expect(out, hasLength(3));
      final keys = out.map((e) => e.item.resumeKey).toSet();
      expect(
        keys,
        containsAll(['jellyfin:host/ep-101', 'jellyfin:host/ep-102']),
      );
      // Jellyfin episode names usually carry no numbers → unmatched here;
      // the Jellyfin indexer supplies numbers upstream (indexNumber).
      expect(
        out.every((e) => e.item.resumeKey!.startsWith('jellyfin:')),
        isTrue,
      );
    });

    test('dead subfolder does not abort the whole enumeration', () async {
      final gw = FakeGateway()
        ..addVideos('/root', [v('Show S01E01.mkv')])
        ..addDirs('/root', [('dead', '/root/dead'), ('alive', '/root/alive')]);
      // alive has content; dead would throw — emulate by omitting it from
      // the map and making the gateway throw for that path.
      gw.addVideos('/root/alive', [v('Show S01E02.mkv')]);

      final throwing = ThrowingOnPathsGateway(
        delegate: gw,
        throwFor: {'/root/dead'},
      );
      final enumr = DanmakuVideoEnumerator(gateway: throwing);
      final out = await enumr.enumerate(VideoSource.local('/root'));
      expect(
        out.map((e) => e.item.title),
        containsAll(['Show S01E01.mkv', 'Show S01E02.mkv']),
      );
    });

    test('max two levels of recursion (gateway calls bounded)', () async {
      final gw = RecordingGateway({
        '/root': [v('Show S01E01.mkv')],
        '/root/L1': [v('Show S01E02.mkv')],
        '/root/L1/L2': [v('Show S01E03.mkv')],
        '/root/L1/L2/L3': [v('Show S01E04.mkv')],
      });
      // The enumerator discovers subfolders through the same gateway;
      // RecordingGateway returns videos only, so also wire a DirectorySpy.
      final dirSpy = DirSpyGateway(
        videos: {
          '/root': [v('Show S01E01.mkv')],
          '/root/L1': [v('Show S01E02.mkv')],
          '/root/L1/L2': [v('Show S01E03.mkv')],
          '/root/L1/L2/L3': [v('Show S01E04.mkv')],
        },
        dirs: {
          '/root': [('L1', '/root/L1')],
          '/root/L1': [('L2', '/root/L1/L2')],
          '/root/L1/L2': [('L3', '/root/L1/L2/L3')],
        },
      );
      final enumr = DanmakuVideoEnumerator(gateway: dirSpy);
      final out = await enumr.enumerate(VideoSource.local('/root'));
      expect(
        out.map((e) => e.item.title),
        containsAll(['Show S01E01.mkv', 'Show S01E02.mkv', 'Show S01E03.mkv']),
      );
      expect(out.map((e) => e.item.title), isNot(contains('Show S01E04.mkv')));
      expect(gw.requested, isEmpty); // sanity: RecordingGateway unused
    });
  });
}

class ThrowingOnPathsGateway implements DanmakuListingGateway {
  ThrowingOnPathsGateway({required this.delegate, required this.throwFor});

  final DanmakuListingGateway delegate;
  final Set<String> throwFor;

  @override
  Future<FolderListing> listFolder(VideoSource source, String path) async {
    if (throwFor.contains(path)) {
      throw FileSystemException('dead folder', path);
    }
    return delegate.listFolder(source, path);
  }
}

/// Gateway with directory discovery so recursion is testable.
class DirSpyGateway implements DanmakuListingGateway {
  DirSpyGateway({required this.videos, required this.dirs});

  final Map<String, List<VideoItem>> videos;
  final Map<String, List<(String, String)>> dirs;

  int calls = 0;

  @override
  Future<FolderListing> listFolder(VideoSource source, String path) async {
    calls++;
    return FolderListing(
      videos: videos[path] ?? const [],
      directories: dirs[path] ?? const [],
    );
  }
}
