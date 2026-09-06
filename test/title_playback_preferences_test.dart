import 'package:dream_player/library/title_playback_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('concurrent source and playback updates merge', () async {
    SharedPreferences.setMockInitialValues({});

    await Future.wait([
      TitlePlaybackPreferences.save(
        titleId: 'tmdb:tv:1',
        preferredSourceId: 'webdav:home',
      ),
      TitlePlaybackPreferences.save(
        titleId: 'tmdb:tv:1',
        lastPlayedFileId: 'file:12',
        lastPlayedEpisodeId: 'tmdb:tv:1:s1:e12',
      ),
    ]);

    final value = await TitlePlaybackPreferences.load('tmdb:tv:1');
    expect(value?.preferredSourceId, 'webdav:home');
    expect(value?.lastPlayedFileId, 'file:12');
    expect(value?.lastPlayedEpisodeId, 'tmdb:tv:1:s1:e12');
  });
}
