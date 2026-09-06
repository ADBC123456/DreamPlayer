/// Enumerates every playable video of the current series/season for batch
/// danmaku scraping.
///
/// Sources supported (PRD "当前剧集一键刮削" + task constraints):
/// - local directory (direct `dart:io` listing; `content://` SAF trees are
///   reached through the native `dreamplayer/files` browser when needed),
/// - Jellyfin folders (server API children),
/// - WebDAV / FTP / SMB via their existing channel listings.
///
/// Recursion: at most TWO subdirectory levels below the start folder
/// (`Season 1/Extras/…` covers specials one level deep), non-video files
/// filtered. The output is a flat list of [EnumeratedVideo] whose
/// [VideoItem]s carry the same stable resumeKey shapes the browse screens
/// build — ready for `identityFor` and the batch scraper.
library;

import 'dart:io';

import '../../models/video_item.dart';
import '../../services/file_browser.dart';
import '../../services/ftp_client.dart';
import '../../services/jellyfin_client.dart';
import '../../services/library_folders.dart';
import '../../services/smb_client.dart';
import '../../services/webdav_client.dart';
import 'episode_mapper.dart';

/// Extensions treated as video files by every source (lowercase, no dot).
const Set<String> danmakuVideoExtensions = {
  'mp4',
  'mkv',
  'avi',
  'mov',
  'wmv',
  'flv',
  'webm',
  'm4v',
  'mpg',
  'mpeg',
  'ts',
  'm2ts',
  'mts',
  'vob',
  'ogv',
  '3gp',
  'rmvb',
  'rm',
  'asf',
  'f4v',
};

bool isVideoFileName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  final ext = name.substring(dot + 1).toLowerCase();
  return danmakuVideoExtensions.contains(ext);
}

/// How deep the enumeration recursed for a given video.
enum VideoDepth {
  /// The start folder itself.
  root,

  /// One subdirectory below the start folder.
  level1,

  /// Two subdirectories below the start folder (maximum per the PRD).
  level2,
}

class EnumeratedVideo {
  const EnumeratedVideo({
    required this.item,
    required this.episode,
    required this.depth,
    required this.parentFolderName,
  });

  final VideoItem item;

  /// Parsed from the file name (folder season applied).
  final EpisodeInfo episode;

  /// Directory depth the file was found at.
  final VideoDepth depth;

  /// The immediate parent folder's name (empty at the root).
  final String parentFolderName;
}

/// Discriminates which backend a folder belongs to. Built from the same
/// shapes the browse screens use: a [LibraryFolder], a Jellyfin item, or a
/// plain local path.
enum VideoSourceKind { local, jellyfin, webdav, ftp, smb }

class VideoSource {
  const VideoSource._({
    required this.kind,
    this.path,
    this.serverId = '',
    this.share = '',
    this.jellyfinServerUrl,
    this.jellyfinItemId,
  });

  /// A plain on-device folder.
  factory VideoSource.local(String path) =>
      VideoSource._(kind: VideoSourceKind.local, path: path);

  /// A Jellyfin folder/series item.
  factory VideoSource.jellyfin({
    required String serverUrl,
    required String itemId,
  }) => VideoSource._(
    kind: VideoSourceKind.jellyfin,
    jellyfinServerUrl: serverUrl,
    jellyfinItemId: itemId,
  );

  factory VideoSource.webdav({
    required String serverId,
    required String path,
  }) => VideoSource._(
    kind: VideoSourceKind.webdav,
    serverId: serverId,
    path: path,
  );

  factory VideoSource.ftp({required String serverId, required String path}) =>
      VideoSource._(kind: VideoSourceKind.ftp, serverId: serverId, path: path);

  factory VideoSource.smb({
    required String serverId,
    required String share,
    required String path,
  }) => VideoSource._(
    kind: VideoSourceKind.smb,
    serverId: serverId,
    share: share,
    path: path,
  );

  /// From a saved library folder (home-grid entry).
  factory VideoSource.fromLibraryFolder(LibraryFolder folder) {
    switch (folder.source) {
      case LibraryFolderSource.jellyfin:
        return VideoSource.jellyfin(
          serverUrl: folder.jellyfinServerUrl ?? '',
          itemId: folder.jellyfinItemId ?? '',
        );
      case LibraryFolderSource.webdav:
        return VideoSource.webdav(
          serverId: folder.networkServerId ?? '',
          path: folder.networkPath ?? '/',
        );
      case LibraryFolderSource.ftp:
        return VideoSource.ftp(
          serverId: folder.networkServerId ?? '',
          path: folder.networkPath ?? '/',
        );
      case LibraryFolderSource.smb:
        return VideoSource.smb(
          serverId: folder.networkServerId ?? '',
          share: folder.networkShare ?? '',
          path: folder.networkPath ?? '',
        );
      case LibraryFolderSource.files:
      case LibraryFolderSource.upnp:
        return VideoSource.local(folder.path);
    }
  }

  final VideoSourceKind kind;

  /// Local absolute path, or the WebDAV/FTP/SMB directory path.
  final String? path;

  /// WebDAV / FTP / SMB saved-server id.
  final String serverId;

  /// SMB share name.
  final String share;

  /// Jellyfin normalized base URL + folder item id.
  final String? jellyfinServerUrl;
  final String? jellyfinItemId;
}

/// A folder listing: playable videos + subdirectories in one call, so the
/// enumerator can recurse without per-backend discovery code.
class FolderListing {
  const FolderListing({this.videos = const [], this.directories = const []});

  final List<VideoItem> videos;

  /// (name, path) pairs of the subdirectories.
  final List<(String, String)> directories;
}

/// Listing backend. Implementations list ONE folder (no recursion —
/// [DanmakuVideoEnumerator] handles that).
abstract class DanmakuListingGateway {
  Future<FolderListing> listFolder(VideoSource source, String path);
}

/// Production gateway wiring the existing channel clients.
class ChannelListingGateway implements DanmakuListingGateway {
  const ChannelListingGateway({JellyfinClient? jellyfinClient})
    : _jellyfin = jellyfinClient;

  final JellyfinClient? _jellyfin;

  @override
  Future<FolderListing> listFolder(VideoSource source, String path) {
    switch (source.kind) {
      case VideoSourceKind.local:
        return _listLocal(path);
      case VideoSourceKind.jellyfin:
        return _listJellyfin(source, path);
      case VideoSourceKind.webdav:
        return _listWebDav(source, path);
      case VideoSourceKind.ftp:
        return _listFtp(source, path);
      case VideoSourceKind.smb:
        return _listSmb(source, path);
    }
  }

  Future<FolderListing> _listLocal(String path) async {
    if (path.startsWith('tree:') || path.startsWith('content://')) {
      return _listNativeLocal(path);
    }
    final dir = Directory(path);
    if (!await dir.exists()) return _listNativeLocal(path);
    final items = <VideoItem>[];
    final dirs = <(String, String)>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File) {
        final name = entity.uri.pathSegments.isNotEmpty
            ? entity.uri.pathSegments.last
            : entity.path;
        if (!isVideoFileName(name)) continue;
        final stat = await entity.stat();
        items.add(
          VideoItem(
            id: 'danmaku_${entity.path.hashCode}',
            title: name,
            path: entity.path,
            duration: Duration.zero,
            sizeBytes: stat.size,
          ),
        );
      } else if (entity is Directory) {
        dirs.add((_dirNameOf(entity), entity.path));
      }
    }
    return FolderListing(videos: items, directories: dirs);
  }

  Future<FolderListing> _listNativeLocal(String path) async {
    final entries = await FileBrowserService.instance.listDirectory(path);
    return FolderListing(
      videos: [
        for (final entry in entries)
          if (!entry.isDirectory && isVideoFileName(entry.name))
            VideoItem(
              id: 'danmaku_native_${entry.path.hashCode}',
              title: entry.name,
              path: entry.path.startsWith('content://') ? null : entry.path,
              uri: entry.path.startsWith('content://') ? entry.path : null,
              resumeKey: entry.resumeKey,
              duration: Duration.zero,
              sizeBytes: entry.size,
            ),
      ],
      directories: [
        for (final entry in entries)
          if (entry.isDirectory) (entry.name, entry.path),
      ],
    );
  }

  static String _dirNameOf(Directory d) {
    final segments = d.uri.pathSegments;
    // Trailing slash gives an empty last segment on some platforms.
    for (var i = segments.length - 1; i >= 0; i--) {
      if (segments[i].isNotEmpty) return segments[i];
    }
    return d.path;
  }

  Future<FolderListing> _listJellyfin(VideoSource source, String path) async {
    final client = _jellyfin ?? JellyfinClient();
    final server = await client.serverForUrl(source.jellyfinServerUrl ?? '');
    if (server == null || !server.isAuthenticated) {
      return const FolderListing();
    }
    final itemId = path.isEmpty ? (source.jellyfinItemId ?? '') : path;
    final items = await client.getItems(server, itemId);
    return FolderListing(
      videos: [
        for (final item in items)
          if (item.isPlayable) client.videoItem(server, item),
      ],
      directories: [
        for (final item in items)
          if (item.isFolder) (item.name, item.id),
      ],
    );
  }

  Future<FolderListing> _listWebDav(VideoSource source, String path) async {
    final entries = await WebDavClient.instance.listDirectory(
      source.serverId,
      path,
    );
    final servers = await WebDavClient.instance.listServers();
    final base = servers
        .firstWhere(
          (s) => s.id == source.serverId,
          orElse: () => const WebDavServer(
            id: '',
            name: '',
            url: '',
            username: '',
            hasPassword: false,
          ),
        )
        .url
        .replaceAll(RegExp(r'/+$'), '');
    return FolderListing(
      videos: [
        for (final e in entries)
          if (!e.isDirectory && isVideoFileName(e.name))
            VideoItem(
              id: 'danmaku_webdav_${source.serverId}${e.path.hashCode}',
              title: e.name,
              uri: base.isEmpty ? '' : '$base${_encodeDavPath(e.path)}',
              resumeKey: 'webdav_${source.serverId}${e.path}',
              duration: Duration.zero,
              sizeBytes: e.size,
              webdavServerId: source.serverId,
            ),
      ],
      directories: [
        for (final e in entries)
          if (e.isDirectory) (e.name, e.path),
      ],
    );
  }

  Future<FolderListing> _listFtp(VideoSource source, String path) async {
    final entries = await FtpClient.instance.listDirectory(
      source.serverId,
      path,
    );
    return FolderListing(
      videos: [
        for (final e in entries)
          if (!e.isDirectory && isVideoFileName(e.name))
            VideoItem(
              id: 'danmaku_ftp_${source.serverId}${e.path.hashCode}',
              title: e.name,
              resumeKey: 'ftp_${source.serverId}${e.path}',
              duration: Duration.zero,
              sizeBytes: e.size,
              ftpServerId: source.serverId,
            ),
      ],
      directories: [
        for (final e in entries)
          if (e.isDirectory) (e.name, e.path),
      ],
    );
  }

  Future<FolderListing> _listSmb(VideoSource source, String path) async {
    final clean = path.replaceAll(RegExp(r'^/+|/+$'), '');
    final entries = await SmbClient.instance.listDirectory(
      source.serverId,
      source.share,
      clean,
    );
    return FolderListing(
      videos: [
        for (final e in entries)
          if (!e.isDirectory && isVideoFileName(e.name))
            VideoItem(
              id: 'danmaku_smb_${e.path.hashCode}',
              title: e.name,
              resumeKey: 'smb:${source.serverId}/${source.share}/${e.path}',
              duration: Duration.zero,
              sizeBytes: e.size,
            ),
      ],
      directories: [
        for (final e in entries)
          if (e.isDirectory) (e.name, e.path),
      ],
    );
  }

  String _encodeDavPath(String path) {
    final encoded = path
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    return encoded.isEmpty ? '/' : '/$encoded';
  }
}

class DanmakuVideoEnumerator {
  DanmakuVideoEnumerator({DanmakuListingGateway? gateway})
    : _gateway = gateway ?? const ChannelListingGateway();

  final DanmakuListingGateway _gateway;

  /// Maximum subdirectory recursion (PRD: 递归最多两层子目录).
  static const int maxDepthLevels = 2;

  /// Enumerates all playable videos under [source], recursing at most
  /// [maxDepthLevels] subdirectories. [folderName] is the display name of
  /// the start folder (used to extract the season for season-less files).
  ///
  /// Per-source failures (a dead subdirectory) are swallowed: the rest of
  /// the tree still enumerates. Never throws for empty results.
  Future<List<EnumeratedVideo>> enumerate(
    VideoSource source, {
    String folderName = '',
    int? season,
  }) async {
    final out = <EnumeratedVideo>[];
    await _walk(
      source,
      path: source.path ?? '',
      depth: 0,
      parentName: '',
      season: season,
      folderName: folderName,
      out: out,
    );
    return out;
  }

  Future<void> _walk(
    VideoSource source, {
    required String path,
    required int depth,
    required String parentName,
    required int? season,
    required String folderName,
    required List<EnumeratedVideo> out,
  }) async {
    if (depth > maxDepthLevels) return;
    FolderListing listing;
    try {
      listing = await _gateway.listFolder(source, path);
    } catch (_) {
      return; // Dead folder — best effort.
    }
    final effectiveSeason = season ?? _parseSeasonFromFolder(folderName);
    for (final v in listing.videos) {
      final info = DanmakuEpisodeParser.parse(
        v.title,
        folderName: parentName.isEmpty ? folderName : parentName,
      );
      out.add(
        EnumeratedVideo(
          item: v,
          episode: info.season == 0 && effectiveSeason > 0
              ? _withSeason(info, effectiveSeason)
              : info,
          depth: _depthOf(depth),
          parentFolderName: parentName,
        ),
      );
    }
    if (depth >= maxDepthLevels) return;
    for (final (name, subPath) in listing.directories) {
      await _walk(
        source,
        path: subPath,
        depth: depth + 1,
        parentName: name,
        season: season,
        folderName: folderName,
        out: out,
      );
    }
  }

  VideoDepth _depthOf(int depth) => switch (depth) {
    0 => VideoDepth.root,
    1 => VideoDepth.level1,
    _ => VideoDepth.level2,
  };

  static EpisodeInfo _withSeason(EpisodeInfo info, int season) => EpisodeInfo(
    source: info.source,
    season: season,
    episode: info.episode,
    special: info.special,
    specialIndex: info.specialIndex,
    seriesName: info.seriesName,
  );
}

/// Season number carried by a folder name (`Season 2`, `S02`, `第二季`).
int _parseSeasonFromFolder(String? folderName) =>
    folderName == null || folderName.isEmpty
    ? 0
    : DanmakuEpisodeParser.parse('x', folderName: folderName).season;
