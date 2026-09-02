# Architecture Documentation Design

## Scope

Documentation only. Product source, generated Flutter files, dependencies, and native behavior are unchanged.

## Document Set

- `docs/architecture.md`: human-readable repository map and runtime flows.
- `.trellis/spec/backend/architecture.md`: implementation-facing platform and lifecycle rules.
- `.trellis/spec/backend/interface-contracts.md`: channel names, commands, event fields, errors, and ownership.
- `.trellis/spec/frontend/index.md`: links the Flutter-facing rules to the architecture document.
- `.trellis/workspace/BraveLiu/index.md`: compact session memory and root/worktree distinction.

## Evidence Sources

- `pubspec.yaml`, `android/app/build.gradle.kts`, `ios/Runner.xcodeproj/project.pbxproj` for runtime/toolchain boundaries.
- `lib/app.dart`, `lib/screens/*`, `lib/services/*`, `lib/models/*`, `lib/utils/*`, and `lib/widgets/*` for Flutter ownership.
- `MainActivity.kt`, `ExoPlayerView.kt`, native adapters, `AppDelegate.swift`, and `AvPlayerView.swift` for platform ownership.
- `test/*` and `ios/RunnerTests/*` for verification boundaries.

## Invariants

- `megamouth/` is an existing Git worktree, not a configured package.
- Shared channel changes must be mirrored in Dart, Kotlin, and Swift where both platforms implement the capability.
- Android hybrid composition is required for Media3 HDR/DV; MPV remains a user-selected SDR secondary engine.
