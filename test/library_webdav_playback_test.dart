import 'package:dream_player/library/models/library_models.dart';
import 'package:dream_player/library/source/library_source_adapters.dart';
import 'package:dream_player/services/webdav_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dreamplayer/webdav');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => 'Basic test');
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  for (final name in ['沧元图.S01E01.mp4', '沧元图 100%.mkv', 'literal%20name.mkv']) {
    test(
      'resolves raw WebDAV filename $name without changing identity',
      () async {
        const server = WebDavServer(
          id: 'nas',
          name: 'NAS',
          url: 'https://example.test/dav',
          username: '',
          hasPassword: true,
        );
        final path = '/TV/沧元图/$name';
        final video = await WebDavLibrarySourceAdapter(server).resolvePlayable(
          MediaFile(
            id: 'file',
            rootIds: const {'root'},
            sourceRef: MediaSourceRef(
              sourceId: 'webdav:nas',
              sourceType: 'webdav',
              serverId: 'nas',
              path: path,
            ),
            originalFileName: name,
            legacyResumeKey: 'stable-resume',
          ),
        );
        expect(Uri.parse(video.uri!).pathSegments, ['dav', 'TV', '沧元图', name]);
        expect(video.resumeKey, 'stable-resume');
        expect(video.httpHeaders['Authorization'], 'Basic test');
      },
    );
  }
}
