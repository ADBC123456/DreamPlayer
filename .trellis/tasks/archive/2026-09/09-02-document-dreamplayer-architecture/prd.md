# Document DreamPlayer architecture and file responsibilities

## Goal

Map Flutter, Android, iOS, tests, tooling, file responsibilities, architecture boundaries, interface contracts, and core data flows.

## Requirements

- Document the real repository tree and the responsibility of each application layer.
- Describe Flutter, Android, iOS, tests, assets, build configuration, and Trellis/tooling boundaries.
- Record Dart-to-native MethodChannel/EventChannel contracts and the Media3/AetherEngine/MPV playback paths.
- Record the primary data flows: app startup, library discovery, open-with intent, playback, subtitles, resume, and remote sources.
- Keep claims source-backed with concrete paths and symbols; do not invent a server backend or database.

## Acceptance Criteria

- [x] `docs/architecture.md` contains the current structure, ownership map, flow diagrams, and extension rules.
- [x] `.trellis/spec/backend/architecture.md` and `.trellis/spec/backend/interface-contracts.md` cover native and cross-layer contracts.
- [x] `.trellis/spec/frontend/` indexes link the relevant Flutter structure/state/type guidance.
- [x] No template placeholders remain in the updated Trellis specs.
- [x] `trellis platforms`, context loading, and spec placeholder checks pass.

## Notes

- Keep `prd.md` focused on requirements, constraints, and acceptance criteria.
- Lightweight tasks can remain PRD-only.
- For complex tasks, add `design.md` for technical design and `implement.md` for execution planning before `task.py start`.
