import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'scrape_state.dart';

/// Persists the batch-scrape task state so an app restart restores the
/// "已完成/失败" results (PRD 任务状态与错误处理 / 批量刮削默认跳过已有有效缓存).
///
/// One JSON blob per (source id, base URL, series key) — the same isolation
/// the danmaku cache uses — stored under a single prefs key. Terminal states
/// (cached/success/empty/noMatch/failed/cancelled) round-trip; transient
/// states (pending/matched/fetching) are reset to [ScrapeStatus.pending] on
/// load because their work did not survive the process death.
class ScrapeStore {
  ScrapeStore._();

  static const String _prefsKey = 'dreamplayer.seriesScrapeTasks';

  /// Loads the persisted task for [scope], or null when none was saved.
  /// Only terminal results are restored; everything else comes back as
  /// pending so a re-run can pick them up.
  static Future<SeriesScrapeState?> loadTask(SeriesScope scope) async {
    final key = scope.storeKey;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return null;
    Map<String, dynamic> root;
    try {
      root = json.decode(raw) as Map<String, dynamic>;
    } on FormatException {
      return null;
    }
    final entry = root[key];
    if (entry is! Map<String, dynamic>) return null;
    return _stateFromJson(entry, scope);
  }

  /// Saves the whole [state] (scope + per-episode rows) under its store key.
  static Future<void> saveTask(SeriesScrapeState state) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    Map<String, dynamic> root = <String, dynamic>{};
    if (raw != null && raw.isNotEmpty) {
      try {
        root = json.decode(raw) as Map<String, dynamic>;
      } on FormatException {
        root = <String, dynamic>{};
      }
    }
    root[state.scope.storeKey] = _stateToJson(state);
    await prefs.setString(_prefsKey, json.encode(root));
  }

  /// Drops the persisted task for [scope] (used by "clear" and tests).
  static Future<void> clearTask(SeriesScope scope) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final root = json.decode(raw) as Map<String, dynamic>;
      if (!root.containsKey(scope.storeKey)) return;
      root.remove(scope.storeKey);
      await prefs.setString(_prefsKey, json.encode(root));
    } on FormatException {
      // Corrupt blob: nothing left worth keeping for this scope.
    }
  }

  static Future<void> clearAllTasks() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }

  static Map<String, dynamic> _stateToJson(SeriesScrapeState s) => {
    'scope': {
      'sourceId': s.scope.sourceId,
      'sourceBaseUrl': s.scope.sourceBaseUrl,
      'seriesTitle': s.scope.seriesTitle,
      'seriesKey': s.scope.seriesKey,
      if (s.scope.season != null) 'season': s.scope.season,
    },
    'phase': s.phase.wire,
    'episodes': [for (final e in s.episodes) _episodeToJson(e)],
  };

  static Map<String, dynamic> _episodeToJson(ScrapeEpisodeState e) => {
    'key': e.key,
    'fileName': e.fileName,
    'status': e.status.wire,
    if (e.season != null) 'season': e.season,
    if (e.episode != null) 'episode': e.episode,
    if (e.ref != null) 'ref': e.ref!.toJson(),
    if (e.commentCount != null) 'commentCount': e.commentCount,
    if (e.error != null) 'error': e.error,
    if (e.fetchedAt != null) 'fetchedAt': e.fetchedAt!.millisecondsSinceEpoch,
  };

  static SeriesScrapeState? _stateFromJson(
    Map<String, dynamic> json,
    SeriesScope scope,
  ) {
    final rawEpisodes = json['episodes'];
    if (rawEpisodes is! List) return null;
    final episodes = <ScrapeEpisodeState>[];
    for (final raw in rawEpisodes) {
      if (raw is! Map<String, dynamic>) continue;
      final status = ScrapeStatus.fromWire(raw['status'] as String?);
      episodes.add(
        ScrapeEpisodeState(
          key: raw['key'] as String? ?? '',
          fileName: raw['fileName'] as String? ?? '',
          // Transient states never survived the restart — reset to pending.
          status: status.isTerminal || status == ScrapeStatus.cancelled
              ? status
              : ScrapeStatus.pending,
          season: (raw['season'] as num?)?.toInt(),
          episode: (raw['episode'] as num?)?.toInt(),
          ref: raw['ref'] is Map<String, dynamic>
              ? DanmakuEpisodeRef.fromJson(raw['ref'] as Map<String, dynamic>)
              : null,
          commentCount: (raw['commentCount'] as num?)?.toInt(),
          error: raw['error'] as String?,
          fetchedAt: raw['fetchedAt'] is num
              ? DateTime.fromMillisecondsSinceEpoch(
                  (raw['fetchedAt'] as num).toInt(),
                )
              : null,
        ),
      );
    }
    final phase = ScrapePhase.fromWire(json['phase'] as String?);
    return SeriesScrapeState(
      scope: scope,
      episodes: episodes,
      // A restored run is never "in progress"; failed-ish blob → partial.
      phase: phase == ScrapePhase.completed
          ? ScrapePhase.completed
          : ScrapePhase.partialFailure,
      generation: 0,
    );
  }
}
