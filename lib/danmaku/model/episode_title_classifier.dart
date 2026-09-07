/// Returns whether [title] describes promotional or preview material rather
/// than a full episode.
///
/// danmu_api catalogs can contain entries such as `星海飞驰第1集预告`. The
/// embedded `第1集` must not make that entry compete with the actual episode.
/// These entries stay in manual search results; this classifier is only used
/// by automatic matching.
bool isDanmakuPromotionalEpisodeTitle(String title) {
  if (title.trim().isEmpty) return false;
  return _promotionalEpisodeMarker.hasMatch(title);
}

final RegExp _promotionalEpisodeMarker = RegExp(
  r'(?:预告|預告|先导|先導|宣传片|宣傳片|特报|特報|片花|抢先看|搶先看|花絮|幕后|幕後|制作特辑|製作特輯)'
  r'|(?:^|[^a-z0-9])(?:pv|trailer|teaser|preview)(?:[^a-z0-9]|$)',
  caseSensitive: false,
);
