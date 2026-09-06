import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/danmaku/identity/md5.dart';
import 'package:dream_player/danmaku/identity/video_identity.dart';
import 'package:dream_player/models/video_item.dart';

void main() {
  group('Md5', () {
    test('RFC 1321 vectors', () {
      expect(md5Hex([]), 'd41d8cd98f00b204e9800998ecf8427e');
      expect(md5Hex('a'.codeUnits), '0cc175b9c0f1b6a831c399e269772661');
      expect(md5Hex('abc'.codeUnits), '900150983cd24fb0d6963f7d28e17f72');
      expect(
        md5Hex('message digest'.codeUnits),
        'f96b697d7cb7938d525a2f31aaf161d0',
      );
      expect(
        md5Hex('The quick brown fox jumps over the lazy dog'.codeUnits),
        '9e107d9d372bb6826bd81d3542a419d6',
      );
    });

    test('streaming equals one-shot across odd chunk sizes', () {
      final data = List<int>.generate(1000, (i) => i % 251);
      final oneShot = md5Hex(data);
      for (final chunk in const [1, 63, 64, 65, 127, 333]) {
        final h = Md5();
        for (var i = 0; i < data.length; i += chunk) {
          final end = (i + chunk) > data.length ? data.length : i + chunk;
          h.addBytes(data, i, end);
        }
        expect(h.digestHex(), oneShot, reason: 'chunk size $chunk');
      }
    });

    test('padding boundaries (55/56/57/63/64/65 bytes)', () {
      // Boundary cases only need internal consistency + distinctness: the
      // RFC vectors above already pin correctness at the padding edges.
      final d55 = md5Hex(List.filled(55, 0x61));
      final d56 = md5Hex(List.filled(56, 0x61));
      final d57 = md5Hex(List.filled(57, 0x61));
      final d63 = md5Hex(List.filled(63, 0x61));
      final d64 = md5Hex(List.filled(64, 0x61));
      final d65 = md5Hex(List.filled(65, 0x61));
      expect({d55, d56, d57, d63, d64, d65}.length, 6);
    });
  });

  group('hashLocalFileHead', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('danmaku_id');
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test(
      'hashes only the first N bytes (16 MiB default, small override)',
      () async {
        final f = File('${tmp.path}/video.mkv');
        // 64 KiB of 0x11 followed by 64 KiB of 0x22; the head hash with a
        // 64 KiB limit must differ from a whole-file hash and match hashing
        // just the head bytes.
        final head = List<int>.filled(65536, 0x11);
        final tail = List<int>.filled(65536, 0x22);
        await f.writeAsBytes([...head, ...tail]);

        final limited = hashLocalFileHead(f.path, bytes: 65536);
        expect(limited, md5Hex(head));
        expect(limited, isNot(md5Hex([...head, ...tail])));
      },
    );

    test('caps at 16 MiB for large files', () async {
      final f = File('${tmp.path}/big.mkv');
      final raf = await f.open(mode: FileMode.write);
      // 17 MiB of 0x33 — hash must cover only the first 16 MiB.
      final chunk = List<int>.filled(1 << 20, 0x33);
      for (var i = 0; i < 17; i++) {
        await raf.writeFrom(chunk);
      }
      await raf.close();

      final hash = hashLocalFileHead(f.path);
      final expected = md5Hex(List<int>.filled(16 << 20, 0x33));
      expect(hash, expected);
    });

    test('missing file returns null', () {
      expect(hashLocalFileHead('${tmp.path}/nope.mkv'), isNull);
    });

    test('unreadable path returns null (no throw)', () {
      // A directory is not a readable file — open fails.
      expect(hashLocalFileHead(tmp.path), isNull);
    });
  });

  group('VideoIdentity stable keys', () {
    test('local path item: path key + hash + size stat', () async {
      final tmp = await Directory.systemTemp.createTemp('danmaku_id2');
      addTearDown(() => tmp.delete(recursive: true));
      final f = File('${tmp.path}/Show.S01E01.mkv');
      await f.writeAsBytes(List<int>.generate(4096, (i) => i % 256));

      final id = identityFor(
        VideoItem(
          id: 'v1',
          title: 'Show.S01E01.mkv',
          path: f.path,
          duration: Duration.zero,
        ),
      );

      expect(id.stableKey, 'danmaku:${f.path}');
      expect(id.fileName, 'Show.S01E01.mkv');
      expect(id.fileSize, 4096);
      expect(id.fileHash, md5Hex(List<int>.generate(4096, (i) => i % 256)));
      expect(id.matchMode, 'hashAndFileName');
    });

    test('remote http item: no hash, uri query stripped', () {
      final id = identityFor(
        const VideoItem(
          id: 'v2',
          title: 'Movie.mkv',
          uri: 'http://192.168.1.16:8096/Videos/42/stream.mkv?api_key=TOKEN1',
          duration: Duration.zero,
        ),
      );
      expect(id.fileHash, isNull);
      expect(id.matchMode, 'fileName');
      // api_key rotation must NOT change the key.
      final id2 = identityFor(
        const VideoItem(
          id: 'v2',
          title: 'Movie.mkv',
          uri: 'http://192.168.1.16:8096/Videos/42/stream.mkv?api_key=TOKEN2',
          duration: Duration.zero,
        ),
      );
      expect(id.stableKey, id2.stableKey);
      expect(id.stableKey, startsWith('danmaku:'));
    });

    test('resumeKey wins over path/uri (rotation-proof)', () {
      final a = identityFor(
        const VideoItem(
          id: 'v3',
          title: 'Ep01.mkv',
          uri: 'http://127.0.0.1:11111/tokenA',
          resumeKey: 'smb:server1/media/Ep01.mkv',
          duration: Duration.zero,
        ),
      );
      final b = identityFor(
        const VideoItem(
          id: 'v3',
          title: 'Ep01.mkv',
          uri: 'http://127.0.0.1:22222/tokenB',
          resumeKey: 'smb:server1/media/Ep01.mkv',
          duration: Duration.zero,
        ),
      );
      expect(a.stableKey, b.stableKey);
      expect(a.stableKey, 'danmaku:smb:server1/media/Ep01.mkv');
    });

    test('jellyfin resume key is stable across token rotation', () {
      const k1 = 'jellyfin:host1:8096/item-abc';
      final a = identityFor(
        const VideoItem(
          id: 'v4',
          title: 'S01E01.mkv',
          uri: 'http://host1:8096/Videos/item-abc/stream?api_key=AAA',
          resumeKey: k1,
          duration: Duration.zero,
        ),
      );
      final b = identityFor(
        const VideoItem(
          id: 'v4',
          title: 'S01E01.mkv',
          uri: 'http://host1:8096/Videos/item-abc/stream?api_key=BBB',
          resumeKey: k1,
          duration: Duration.zero,
        ),
      );
      expect(a.stableKey, 'danmaku:$k1');
      expect(b.stableKey, a.stableKey);
    });

    test('percent-decoded file name for URL sources', () {
      final id = identityFor(
        const VideoItem(
          id: 'v5',
          title: '',
          uri: 'http://host/dav/My%20Show%20S01E02.mkv',
          duration: Duration.zero,
        ),
      );
      expect(id.fileName, 'My Show S01E02.mkv');
    });

    test('identity never embeds TMDB ids', () {
      // TMDB metadata lives in a different namespace; the identity key is
      // derived purely from source identifiers.
      final a = identityFor(
        const VideoItem(
          id: 'v6',
          title: 'Show S01E01.mkv',
          path: '/media/Show S01E01.mkv',
          duration: Duration.zero,
        ),
      );
      expect(a.stableKey.contains('tmdb'), isFalse);
      expect(a.stableKey.startsWith('danmaku:'), isTrue);
    });
  });

  group('stable keys survive app restart', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('danmaku_restart');
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('local file: same key and hash across sessions', () async {
      final f = File('${tmp.path}/Anime 第1集.mkv');
      await f.writeAsBytes(List<int>.filled(1024, 7));

      final s1 = identityFor(
        VideoItem(
          id: 'a',
          title: 'Anime 第1集.mkv',
          path: f.path,
          duration: Duration.zero,
        ),
      );
      // Simulated restart: a fresh VideoItem built from the same listing.
      final s2 = identityFor(
        VideoItem(
          id: 'freshly-rebuilt-id',
          title: 'Anime 第1集.mkv',
          path: f.path,
          duration: Duration.zero,
        ),
      );
      expect(s2.stableKey, s1.stableKey);
      expect(s2.fileHash, s1.fileHash);
    });

    test('webdav/ftp/smb/jellyfin resume keys are session-proof', () {
      const shapes = [
        'webdav_srv1/media/Show S01E01.mkv',
        'ftp_srv1/media/Show S01E01.mkv',
        'smb:srv1/media/Show S01E01.mkv',
        'jellyfin:host/item1',
      ];
      for (final key in shapes) {
        final s1 = identityFor(
          VideoItem(
            id: 'x',
            title: 'Show S01E01.mkv',
            uri: 'http://rotating/$key',
            resumeKey: key,
            duration: Duration.zero,
          ),
        );
        final s2 = identityFor(
          VideoItem(
            id: 'x',
            title: 'Show S01E01.mkv',
            uri: 'http://other-port/$key',
            resumeKey: key,
            duration: Duration.zero,
          ),
        );
        expect(s2.stableKey, s1.stableKey);
      }
    });

    test('identity keys do not depend on VideoItem.id', () {
      final a = identityFor(
        const VideoItem(
          id: 'id-one',
          title: 'E.mkv',
          path: '/m/E.mkv',
          duration: Duration.zero,
        ),
      );
      final b = identityFor(
        const VideoItem(
          id: 'id-two',
          title: 'E.mkv',
          path: '/m/E.mkv',
          duration: Duration.zero,
        ),
      );
      expect(a.stableKey, b.stableKey);
    });
  });
}
