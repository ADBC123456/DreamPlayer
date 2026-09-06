import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dream_player/screens/webdav_screen.dart';
import 'package:dream_player/services/library_folders.dart';
import 'package:dream_player/services/tmdb_client.dart';

void main() {
  testWidgets(
    'bookmark opens typed WebDAV entries and multi-select publishes matched folders',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      TmdStore.resetWriteQueueForTesting();
      const channel = MethodChannel('dreamplayer/webdav');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'listServers') {
          return [
            {'id': 's', 'name': 'NAS', 'url': 'http://localhost'},
          ];
        }
        if (call.method == 'listDirectory') {
          return [
            {'name': 'Show A', 'path': '/Show A', 'isDirectory': true},
            {'name': 'Show B', 'path': '/Show B', 'isDirectory': true},
            {'name': 'file.mkv', 'path': '/file.mkv', 'isDirectory': false},
          ];
        }
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      for (final name in ['Show A', 'Show B']) {
        final path = '/$name';
        await TmdService.instance.setManualFolder(
          'folder:webdav_s_${path.hashCode}',
          TmdMovie(id: name.length, title: name),
        );
      }
      await tester.pumpWidget(
        MaterialApp(
          home: WebDavScreen(
            initialFolder: LibraryFolder(
              id: 'root',
              name: 'Root',
              path: 'webdav:s/',
              addedAt: DateTime(2026),
              source: LibraryFolderSource.webdav,
              networkServerId: 's',
              networkPath: '/',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(Checkbox), findsNWidgets(2));
      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();
      await tester.tap(find.byType(Checkbox).last);
      await tester.pump();
      expect(find.text('自动识别 (2)'), findsOneWidget);
      await tester.tap(find.text('自动识别 (2)'));
      await tester.pumpAndSettle();
      expect(
        (await LibraryFoldersStore.load()).map((f) => f.name),
        containsAll(['Show A', 'Show B']),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
