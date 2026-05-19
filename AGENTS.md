# Agent Instructions

## Project Context

- Product name: `Typeforme` for user-facing text; `typeforme` for URL schemes, logs, directories, and other machine identifiers.
- This repository contains a macOS Swift package app plus an iOS host app and keyboard extension.
- macOS source lives in `Sources/Typeforme/`; tests live in `Tests/TypeformeTests/`.
- iOS source lives in `iOS/TypeformeIOS/`, `iOS/TypeformeKeyboard/`, and `iOS/Shared/`.
- Large local outputs and dependencies belong in `dist/`, `.build/`, `vendor/`, and user Application Support directories; do not treat them as source.

## Working Rules

- Start by reading the relevant files and current local state before proposing edits.
- When a task depends on current external behavior, APIs, platform rules, or agent-tool conventions, verify with current official sources first.
- Keep edits scoped to the requested behavior and the surrounding ownership boundary.
- Prefer existing project patterns over new abstractions. Add a new abstraction only when it removes real duplication or clarifies a shared contract.
- Do not commit generated app bundles, local model files, signing material, or personal configuration.
- When changing deployable macOS or iOS app behavior, UI, assets, entitlements, bundle metadata, or embedded runtime packaging, bump the relevant app version/build in the same change. Pure docs, tests, scripts that are not packaged, and internal-only benchmark changes do not need an app version bump. macOS version lives in `Resources/Info.plist`; iOS host app and keyboard extension versions live in `iOS/TypeformeIOS.xcodeproj/project.pbxproj` and should stay in lockstep.
- For benchmark results, never treat app success, non-empty output, endpoint status, or simple automatic checks as semantic correctness. Correctness must be judged by an agent or human reviewer from the per-sample input, intent, output, and expected product behavior; report unreviewed correctness as pending.

## Gates

- Naming gate: user-facing product text must use `Typeforme`; URL schemes, logs, directories, and machine-readable identifiers must use lowercase `typeforme`.
- Compatibility gate: reject changes that add legacy aliases, fallback keys, old bundle identifiers, old URL schemes, old defaults domains, old pairing JSON keys, one-time migrations, or rename-era cleanup code unless the user explicitly asks for a migration.
- Current identifier gate: valid identifiers are `com.btcdtc.typeforme.mac`, `com.btcdtc.typeforme`, `com.btcdtc.typeforme.keyboard`, `typeforme://`, and `~/Library/Application Support/Typeforme/`.
- Pairing gate: pairing JSON may contain `token`, enabled `lan_bridge_url` / `lan_bridge_urls`, and enabled `public_bridge_url`; do not add Docker origin, local SSID, tunnel vendor metadata, or duplicated legacy fields.
- Migration exception gate: if a migration is explicitly requested, the same change must document exact input, output, code location, and removal date.

## Build And Test

- Use the Xcode-backed scripts for project verification.
- Do not rely on bare `xcodebuild` or `xcrun`; local `xcode-select` may point to Command Line Tools. Use `/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild` directly, or set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for direct `xcodebuild` / `xcrun` commands.
- macOS tests:

```sh
scripts/run-tests.sh
```

- macOS app build:

```sh
scripts/build-app.sh debug
```

- iOS device build/install:

```sh
scripts/deploy-ios.sh
```

- For iOS simulator build checks, use the full Xcode `xcodebuild` path against `iOS/TypeformeIOS.xcodeproj` and the `TypeformeIOS` scheme.
- If you cannot run a relevant verification command, report the reason and the residual risk.

## Codebase Notes

- The app has Server and Client modes. Server owns ASR, correction, and Bridge API; Client can record locally and send work to another Mac Bridge.
- ASR and correction are designed to fail explicitly when required local runtime files or models are missing.
- Normal logs should avoid raw user text. Debug capture may store raw audio and text locally for diagnosis.
- Keyboard and Bridge code touch system permissions, local networking, pasteboard, and App Group style coordination; validate those paths carefully after behavior changes.

## Documentation

- Keep human-facing documentation operational and current.
- Keep this file short and durable. Add instructions here only when they would prevent repeated mistakes across future agent sessions.
