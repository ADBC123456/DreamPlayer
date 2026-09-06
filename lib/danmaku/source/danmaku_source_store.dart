// User-managed danmaku source configuration + persistence.
//
// A config is everything needed to rebuild a [DanmuApiSource]: display name,
// base URL, optional path token, enabled flag and priority. Only these fields
// are persisted (shared_preferences JSON list, key `dreamplayer.danmakuSources`
// + `dreamplayer.danmakuEnabled` for the global show/hide switch); tokens are
// path prefixes for danmu_api deployments, not secrets — they still never
// reach any log line (see danmu_api_source.dart logging contract).
//
// On startup `DanmakuService.init` loads the stored configs and registers one
// [DanmuApiSource] per config into the global [DanmakuSourceRegistry].

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Prefs key: JSON list of [DanmakuSourceConfig.toJson] maps.
const String kDanmakuSourcesPref = 'dreamplayer.danmakuSources';

/// Prefs key: bool, the global danmaku show/hide switch (default ON).
const String kDanmakuEnabledPref = 'dreamplayer.danmakuEnabled';

/// One user-configured danmaku source deployment.
@immutable
class DanmakuSourceConfig {
  const DanmakuSourceConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.token = '',
    this.enabled = true,
    this.priority = 0,
  });

  /// Stable id (uuid-ish) persisted across restarts; also the registry key.
  final String id;

  /// User-facing display name.
  final String name;

  /// The deployed API address — never a GitHub repo URL.
  final String baseUrl;

  /// Optional path token (`{baseUrl}/{token}/api/v2/...`); empty = none.
  final String token;

  final bool enabled;

  /// Higher = tried first.
  final int priority;

  DanmakuSourceConfig copyWith({
    String? name,
    String? baseUrl,
    String? token,
    bool? enabled,
    int? priority,
  }) => DanmakuSourceConfig(
    id: id,
    name: name ?? this.name,
    baseUrl: baseUrl ?? this.baseUrl,
    token: token ?? this.token,
    enabled: enabled ?? this.enabled,
    priority: priority ?? this.priority,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'token': token,
    'enabled': enabled,
    'priority': priority,
  };

  static DanmakuSourceConfig fromJson(Map<String, dynamic> json) =>
      DanmakuSourceConfig(
        id: '${json['id'] ?? ''}',
        name: '${json['name'] ?? ''}',
        baseUrl: '${json['baseUrl'] ?? ''}',
        token: '${json['token'] ?? ''}',
        enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
        priority: (json['priority'] as num?)?.toInt() ?? 0,
      );

  /// Fresh id for new configs; readable + collision-safe for this scope.
  static String newId() =>
      'danmu_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
      '${(_counter++).toRadixString(36)}';

  static int _counter = 0;
}

/// Load / save the config list.
class DanmakuSourceStore {
  DanmakuSourceStore._();

  static Future<List<DanmakuSourceConfig>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(kDanmakuSourcesPref);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((m) => DanmakuSourceConfig.fromJson(m.cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> save(List<DanmakuSourceConfig> configs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      kDanmakuSourcesPref,
      jsonEncode(configs.map((c) => c.toJson()).toList()),
    );
  }
}

/// Global danmaku show/hide switch persistence.
class DanmakuEnabledStore {
  static Future<bool> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(kDanmakuEnabledPref) ?? true;
  }

  static Future<void> save(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kDanmakuEnabledPref, value);
  }
}
