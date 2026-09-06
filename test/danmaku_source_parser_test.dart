// Typed-model + parser tests for the danmaku source layer
// (任务 .trellis/tasks/09-04-danmaku-source-series-scrape).
//
// Covers every explicitly requested case:
//  - 4/8/9-field `p` parsing (time/mode/color indices)
//  - mode 6/7 mapping to scroll (requirement 6)
//  - numeric AND string episodeId/animeId/cid (requirement 7)
//  - RGB-string / decimal / hex colors (requirement 8)
//  - XML entities, CDATA, broken XML (requirement 8)
//  - empty comments / invalid times dropped (requirement 8)
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/danmaku/model/danmaku_models.dart';
import 'package:dream_player/danmaku/model/parse_utils.dart';
import 'package:dream_player/danmaku/source/bilibili_xml_parser.dart';
import 'package:dream_player/danmaku/source/danmu_api_comment_parser.dart';

void main() {
  group('DanmakuMode.fromCode (requirement 6)', () {
    test('1/6/7 map to scroll, 4 bottom, 5 top', () {
      expect(DanmakuMode.fromCode(1), DanmakuMode.scroll);
      expect(DanmakuMode.fromCode(6), DanmakuMode.scroll);
      expect(DanmakuMode.fromCode(7), DanmakuMode.scroll);
      expect(DanmakuMode.fromCode(4), DanmakuMode.bottom);
      expect(DanmakuMode.fromCode(5), DanmakuMode.top);
    });

    test('unknown / null / garbage degrade to scroll', () {
      expect(DanmakuMode.fromCode(null), DanmakuMode.scroll);
      expect(DanmakuMode.fromCode(99), DanmakuMode.scroll);
      expect(DanmakuMode.fromCode(-1), DanmakuMode.scroll);
    });
  });

  group('danmu_api comments (requirements 2-5)', () {
    test('parses the documented 4-field payload end to end', () {
      final body = jsonEncode(<String, dynamic>{
        'success': true,
        'errorCode': 0,
        'errorMessage': '',
        'count': 1,
        'videoDuration': 2700,
        'comments': [
          {
            'p': '12.50,1,16777215,[bilibili]',
            'm': '弹幕内容',
            'cid': 123456,
            'like': 8,
          },
        ],
      });

      final result = parseDanmuApiComments(body);

      expect(result.count, 1);
      expect(result.videoDurationSeconds, 2700);
      expect(result.errorCode, 0);
      final item = result.items.single;
      expect(item.timeSeconds, 12.5);
      expect(item.mode, DanmakuMode.scroll);
      // 16777215 = 0xFFFFFF.
      expect(item.colorRgb, 0xFFFFFF);
      expect(item.text, '弹幕内容');
      expect(item.danmakuId, '123456');
      expect(item.likes, 8);
    });

    test('4-field p uses index 2 as color (source is NOT the color)', () {
      // "10,5,255,[source]" -> time 10, mode 5 (top), color 255 (blue).
      final result = parseDanmuApiComments(
        jsonEncode({
          'comments': [
            {'p': '10,5,255,[acfun]', 'm': 'top row'},
          ],
        }),
      );
      final item = result.items.single;
      expect(item.mode, DanmakuMode.top);
      expect(item.colorRgb, 0x0000FF);
      expect(item.fontSize, isNull);
    });

    test('8-field p uses time/mode/fontSize/color at 0/1/2/3', () {
      // "30,4,25,16711680,1700000000,0,alice,9001" (8 fields).
      final result = parseDanmuApiComments(
        jsonEncode({
          'comments': [
            {
              'p': '30,4,25,16711680,1700000000,0,alice,9001',
              'm': 'bottom red',
              'cid': 'cid-string',
            },
          ],
        }),
      );
      final item = result.items.single;
      expect(item.timeSeconds, 30);
      expect(item.mode, DanmakuMode.bottom);
      expect(item.fontSize, 25);
      expect(item.colorRgb, 0xFF0000);
      expect(item.danmakuId, 'cid-string');
    });

    test('9-field p parses like 8-field (extra trailing fields ignored)', () {
      final result = parseDanmuApiComments(
        jsonEncode({
          'comments': [
            {'p': '5.2,6,20,65280,1700000000,1,bob,42,extra', 'm': 'x'},
          ],
        }),
      );
      final item = result.items.single;
      expect(item.timeSeconds, 5.2);
      expect(item.mode, DanmakuMode.scroll); // 6 -> scroll (requirement 6)
      expect(item.fontSize, 20);
      expect(item.colorRgb, 0x00FF00);
    });

    test('mode 7 degrades to scroll (requirement 6, v1 downgrade)', () {
      final result = parseDanmuApiComments(
        jsonEncode({
          'comments': [
            {'p': '1,7,16777215,[bilibili]', 'm': 'advanced'},
          ],
        }),
      );
      expect(result.items.single.mode, DanmakuMode.scroll);
    });

    test('cid and like accept both numbers and strings (requirement 7)', () {
      final result = parseDanmuApiComments(
        jsonEncode({
          'comments': [
            {'p': '1,1,255,[x]', 'm': 'a', 'cid': 123, 'like': 4},
            {
              'p': '2,1,255,[x]',
              'm': 'b',
              'cid': '99999999999999999999',
              'like': '12',
            },
            {'p': '3,1,255,[x]', 'm': 'c', 'like': null},
          ],
        }),
      );
      expect(result.items[0].danmakuId, '123');
      expect(result.items[0].likes, 4);
      // Huge id survives verbatim (no int coercion).
      expect(result.items[1].danmakuId, '99999999999999999999');
      expect(result.items[1].likes, 12);
      expect(result.items[2].danmakuId, isNull);
      expect(result.items[2].likes, isNull);
    });

    test('empty m and invalid times are dropped (requirement 8)', () {
      final result = parseDanmuApiComments(
        jsonEncode({
          'comments': [
            {'p': '1,1,255,[x]', 'm': ''},
            {'p': '1,1,255,[x]', 'm': '   '},
            {'p': '1,1,255,[x]', 'm': null},
            {'p': 'abc,1,255,[x]', 'm': 'bad time'},
            {'p': '-5,1,255,[x]', 'm': 'negative time'},
            {'p': '1,1,255,[x]', 'm': 'ok'},
          ],
        }),
      );
      expect(result.items, hasLength(1));
      expect(result.items.single.text, 'ok');
    });

    test('fewer than 4 p fields is dropped; entities decoded in m', () {
      final result = parseDanmuApiComments(
        jsonEncode({
          'comments': [
            {'p': '1,1', 'm': 'too few'},
            {'p': '1,1,255,[x]', 'm': 'a &lt;b&gt; &amp;&quot;c&quot;'},
          ],
        }),
      );
      expect(result.items, hasLength(1));
      expect(result.items.single.text, 'a <b> &"c"');
    });

    test('numeric-array p variant is tolerated', () {
      final result = parseDanmuApiComments(
        jsonEncode({
          'comments': [
            {
              'p': [9, 5, 255, 1],
              'm': 'list p',
            },
          ],
        }),
      );
      final item = result.items.single;
      expect(item.timeSeconds, 9);
      expect(item.mode, DanmakuMode.top);
      // 4 numeric entries = 4-field contract: color at index 2.
      expect(item.colorRgb, 255);
    });

    test('errorCode/errorMessage/videoDuration surface without throwing', () {
      final result = parseDanmuApiComments(
        jsonEncode({
          'success': false,
          'errorCode': 404,
          'errorMessage': 'episode not found',
          'comments': [],
        }),
      );
      expect(result.errorCode, 404);
      expect(result.errorMessage, 'episode not found');
      expect(result.count, 0);
      expect(result.videoDurationSeconds, isNull);
    });

    test('broken JSON / non-object payloads degrade gracefully', () {
      expect(parseDanmuApiComments('not json').items, isEmpty);
      expect(parseDanmuApiComments('').items, isEmpty);
      expect(parseDanmuApiComments('[1,2]').items, isEmpty);
      expect(parseDanmuApiComments('42').errorMessage, isNotNull);
    });
  });

  group('color parsing (requirement 8)', () {
    test('decimal number, negative, and >24-bit mask', () {
      expect(parseDanmakuColor(16711680), 0xFF0000);
      expect(parseDanmakuColor(-1), 0xFFFFFF); // & 0xFFFFFF
      expect(parseDanmakuColor(0x1FF0000), 0xFF0000); // alpha byte dropped
    });

    test('decimal string, hex string, #hex, 0xhex', () {
      expect(parseDanmakuColor('65280'), 0x00FF00);
      expect(parseDanmakuColor('#FF0000'), 0xFF0000);
      expect(parseDanmakuColor('0x00FF00'), 0x00FF00);
      expect(parseDanmakuColor('ff0000'), 0xFF0000);
    });

    test('rgb() string clamps out-of-range channels', () {
      expect(parseDanmakuColor('rgb(255,0,0)'), 0xFF0000);
      expect(parseDanmakuColor('RGB(300, -5, 12)'), 0xFF000C);
    });

    test('garbage / null / empty degrade to white', () {
      expect(parseDanmakuColor(null), 0xFFFFFF);
      expect(parseDanmakuColor(''), 0xFFFFFF);
      expect(parseDanmakuColor('not-a-color'), 0xFFFFFF);
      expect(parseDanmakuColor(double.nan), 0xFFFFFF);
    });
  });

  group('Bilibili XML (requirement 8)', () {
    const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<i>
  <chatserver>chat.bilibili.com</chatserver>
  <d p="12.50,1,25,16777215,1700000000,0,alice,9001">hello &amp; bye</d>
  <d p="13.00,4,25,16711680,1700000000,0,bob,9002"><![CDATA[bottom <row>]]></d>
  <d p="14.25,5,25,65280,1700000000,0,carol,9003">top</d>
  <d p="15,6,25,255,1700000000,0,dave,9004">reverse</d>
  <d p="16,7,25,255,1700000000,0,erin,9005">advanced</d>
</i>
''';

    test('parses rows with entity decoding, CDATA and time sort', () {
      final items = parseBilibiliXml(xml);
      expect(items, hasLength(5));
      expect(items[0].text, 'hello & bye');
      expect(items[0].mode, DanmakuMode.scroll);
      expect(items[0].colorRgb, 0xFFFFFF);
      expect(items[0].fontSize, 25);
      expect(items[0].danmakuId, '9001');

      expect(items[1].text, 'bottom <row>');
      expect(items[1].mode, DanmakuMode.bottom);
      expect(items[1].colorRgb, 0xFF0000);

      expect(items[2].mode, DanmakuMode.top);
      expect(items[2].colorRgb, 0x00FF00);
      // Mode 6 and 7 both degrade to scroll:
      expect(items[3].mode, DanmakuMode.scroll);
      expect(items[4].mode, DanmakuMode.scroll);
    });

    test('broken XML is salvaged row by row', () {
      // Shapes a corrupted export actually takes: truncated `<d` tail with
      // junk after it. The regex swallows the tail into the NEXT row's body,
      // so salvaged texts are dirty but non-empty; the parser never throws.
      const broken =
          '<i><d p="1,1,255,[x]">ok</d>'
          '<d p="2,1,255,[x]">still works</d'
          ' garbage-tail <d p="3,5,255,[y]">trailing</d></i>';
      final items = parseBilibiliXml(broken);
      expect(items.map((e) => e.text), contains('ok'));
      expect(items.map((e) => e.text), anyElement(contains('still works')));
      expect(items.map((e) => e.text), anyElement(contains('trailing')));
    });

    test('empty / useless xml yields empty list, never throws', () {
      expect(parseBilibiliXml(''), isEmpty);
      expect(parseBilibiliXml('   '), isEmpty);
      expect(parseBilibiliXml('<i><maxlimit>100</maxlimit></i>'), isEmpty);
    });

    test('4-field rows read color at index 2; <4 fields dropped', () {
      const xml =
          '<i>'
          '<d p="1,5,255,[acfun]">top</d>'
          '<d p="1,1">too few</d>'
          '</i>';
      final items = parseBilibiliXml(xml);
      expect(items, hasLength(1));
      expect(items.single.mode, DanmakuMode.top);
      expect(items.single.colorRgb, 255);
    });
  });

  group('identity models (requirement 7)', () {
    test('DanmakuRef.idFromDynamic keeps strings verbatim', () {
      expect(DanmakuRef.idFromDynamic(10001), '10001');
      expect(DanmakuRef.idFromDynamic(10001.0), '10001');
      expect(DanmakuRef.idFromDynamic('  eps_42 '), 'eps_42');
      expect(
        DanmakuRef.idFromDynamic('99999999999999999999'),
        '99999999999999999999',
      );
      expect(DanmakuRef.idFromDynamic(null), '');
    });

    test('VideoIdentity accepts service or local identity', () {
      final service = VideoIdentity(animeId: '100', episodeId: '10001');
      final local = VideoIdentity(localKey: 'file:///a.mkv');
      expect(service, VideoIdentity(animeId: '100', episodeId: '10001'));
      expect(
        service.hashCode,
        VideoIdentity(animeId: '100', episodeId: '10001').hashCode,
      );
      expect(service == local, isFalse);
      expect(() => VideoIdentity(), throwsA(isA<AssertionError>()));
    });
  });

  group('DanmakuTrack / options', () {
    test('track snapshots its list and exposes counts', () {
      final track = DanmakuTrack(
        identity: const VideoIdentity(episodeId: '1'),
        items: [const DanmakuItem(timeSeconds: 2, text: 'b')],
      );
      expect(track.count, 1);
      expect(track.isEmpty, isFalse);
    });

    test('DanmakuOptions defaults match the PRD display contract', () {
      const options = DanmakuOptions();
      expect(options.enabled, isTrue);
      expect(options.opacity, 1.0);
      expect(options.displayArea, 1.0);
      expect(options.showScroll, isTrue);
      expect(options.showTop, isTrue);
      expect(options.showBottom, isTrue);
      final tuned = options.copyWith(enabled: false, fontSize: 20);
      expect(tuned.enabled, isFalse);
      expect(tuned.fontSize, 20);
      expect(tuned.opacity, 1.0);
    });
  });
}
