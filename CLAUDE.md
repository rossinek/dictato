# Dictato

A minimal SuperWhisper clone. Records speech and transcribes it locally.

## Repository Structure

```
.
├── macos/          # macOS menu bar app (WhisperKit)
│   ├── Dictato/    # Source code
│   ├── project.yml # XcodeGen spec
│   └── ExportOptions.plist
├── ios/            # iOS app (FluidAudio/Parakeet TDT v3)
│   ├── Dictato/    # Source code
│   └── project.yml # XcodeGen spec
├── scripts/        # Build & notarize scripts
├── assets-raw/     # Source assets (icons, etc.)
├── IOS.md          # iOS app specification
└── CLAUDE.md       # This file
```

## macOS App

### Build & Run

```bash
cd macos

# Regenerate Xcode project after adding/removing files
xcodegen generate

# Build
xcodebuild -project Dictato.xcodeproj -scheme Dictato -destination 'platform=macOS' build

# The built app is at:
# ~/Library/Developer/Xcode/DerivedData/Dictato-*/Build/Products/Debug/Dictato.app
```

**Important:** Do not rebuild between accessibility permission grants — each rebuild changes the ad-hoc code signature, invalidating macOS accessibility trust. Relaunch without rebuilding when testing.

### Architecture

#### Entry Point
- `DictatoApp.swift` — SwiftUI `@main` app. `MenuBarExtra` for the tray icon/menu. `AppDelegate` handles shortcut registration and floating panel lifecycle.
- `AppState.swift` — `@MainActor` singleton (`AppState.shared`). Owns WhisperKit instance, recording state, transcription history. All state flows through here.

#### Recording & Transcription Flow
1. Global shortcut (default: **Option+Space**) toggles recording via `AppState.toggleRecording()`
2. Recording uses WhisperKit's built-in `audioProcessor.startRecordingLive()` — no custom AVAudioEngine
3. On stop, accumulated `[Float]` samples are passed to `whisperKit.transcribe(audioArray:)`
4. Result is pasted at cursor via `PasteService` (CGEvent Cmd+V simulation)
5. Transcription is saved to history

#### Key Files
```
macos/Dictato/
├── App/
│   ├── DictatoApp.swift          # App entry, MenuBarExtra, AppDelegate
│   └── AppState.swift            # Central state, WhisperKit lifecycle, recording
├── UI/
│   ├── FloatingPanel.swift       # NSPanel (non-activating, won't steal focus)
│   ├── RecordingOverlay.swift    # Pill-shaped recording/transcribing indicator
│   ├── HistoryView.swift         # Past transcriptions list (click to copy)
│   └── SettingsView.swift        # Shortcut recorder
├── Services/
│   ├── PasteService.swift        # Clipboard + CGEvent Cmd+V
│   └── PermissionsService.swift  # Mic & accessibility permission checks
├── Shortcuts/
│   └── GlobalShortcut.swift      # KeyboardShortcuts.Name definition
├── Models/
│   └── Transcription.swift       # Codable data model
└── Resources/
    ├── Info.plist                 # LSUIElement=YES, mic usage description
    └── Dictato.entitlements       # Empty (no sandbox for dev)
```

#### Dependencies (SPM via project.yml)
- **WhisperKit** (argmaxinc) — model download, audio processing, transcription
- **KeyboardShortcuts** (sindresorhus) — global hotkey with configurable UI

#### Data Storage
- **Model files:** `~/Library/Application Support/Dictato/Models/`
- **Transcription history:** `~/Library/Application Support/Dictato/history.json`

### Known Issues / Dev Notes

- **Slow first launch:** CoreML compiles the model for your hardware on first load (~2-3 min). Cached after that, but cache is invalidated by code signature changes (every Xcode rebuild).
- **Accessibility permissions:** Tied to code signature. After rebuilding, you may need to re-add the app in System Settings > Privacy & Security > Accessibility.
- **Sandbox disabled:** Entitlements file is empty for development. Needs proper sandbox + hardened runtime for distribution.
- **State observation:** The floating panel is managed via a polling Task (100ms) watching `AppState` properties. This works but could be replaced with Combine publishers if needed.

### Adding New Features

- **New UI:** Add SwiftUI views in `macos/Dictato/UI/`, run `xcodegen generate` from `macos/` to update the project.
- **Settings:** Add controls to `SettingsView.swift`, store values with `@AppStorage` or `UserDefaults`.
- **Model selection:** Change the variant string in `AppState.initializeWhisperKit()`. Available variants are in the `argmaxinc/whisperkit-coreml` HuggingFace repo.

## iOS App

### Build & Run

```bash
cd ios

# Regenerate Xcode project after adding/removing files
xcodegen generate

# Build
xcodebuild -project Dictato.xcodeproj -scheme Dictato -destination 'generic/platform=iOS' build
```

**Important:** CoreML recompiles models when the code signature changes (every Xcode rebuild). This makes each launch after a rebuild slow (~40s). Subsequent launches without rebuilding are fast (~1-2s). This only affects development.

### Architecture

#### Entry Point
- `DictatoApp.swift` — SwiftUI `@main` app. `TabView` with Home, History, Settings tabs + file import action.
- `AppState.swift` — `@MainActor` singleton (`AppState.shared`). Owns FluidAudio `AsrManager`, AVAudioEngine recording, transcription history. All state flows through here.

#### Recording & Transcription Flow
1. User taps the central record button on HomeView
2. Recording uses `AVAudioEngine` with a tap on `inputNode`, converting to 16kHz mono via `AVAudioConverter`
3. On stop, accumulated `[Float]` samples are passed to `asrManager.transcribe(samples, source: .system)`
4. Result is shown in a sheet with Copy button
5. Transcription is saved to history

#### Key Files
```
ios/Dictato/
├── App/
│   ├── DictatoApp.swift          # App entry, TabView, file import
│   ├── AppState.swift            # Central state, FluidAudio lifecycle, AVAudioEngine recording
│   └── AppIntents.swift          # Shortcuts integration (Start Recording intent)
├── UI/
│   ├── HomeView.swift            # Main screen: record button, mode pills, result sheet
│   ├── HistoryView.swift         # Past transcriptions (swipe-to-delete, context menu, re-transcribe)
│   └── SettingsView.swift        # API keys, modes config, model picker
├── Models/
│   ├── Transcription.swift       # Codable data model (shared with macOS)
│   └── TranscriptionMode.swift   # Mode definition (shared with macOS)
├── Services/
│   ├── LLMService.swift          # OpenAI/Groq post-processing (shared with macOS)
│   └── PermissionsService.swift  # iOS microphone permission
├── Resources/
│   └── Info.plist                # Mic usage, URL scheme (dictato://)
├── Assets.xcassets/              # Asset catalog
└── AppIcon.icon/                 # Layered app icon (Icon Composer format)
```

#### Dependencies (SPM via project.yml)
- **FluidAudio** — Parakeet TDT v3 CoreML model download, loading, and transcription

#### Deep Links
- `dictato://record` — opens app and starts recording with current mode
- `dictato://record?mode=email` — starts recording with specified mode (case-insensitive, `+`/`-`/`_` match spaces)

#### Shortcuts
- **Start Recording** — available in Apple Shortcuts app. Opens Dictato and starts recording. Supports mode selection via parameter.

#### Data Storage
- **Model files:** `<AppSupport>/FluidAudio/Models/` (managed by FluidAudio)
- **Transcription history:** `<AppSupport>/Dictato/history.json`
- **Audio cache:** `<AppSupport>/Dictato/Recordings/`

#### UI Design
- iOS 26 Liquid Glass effects throughout (`.glassEffect()`, `GlassEffectContainer`)
- State-driven central button with animated secondary actions
- Mode pills with `matchedGeometryEffect` sliding selection
- Glass cards in history with swipe-to-delete and context menu

## Logging

Uses `os.Logger` with subsystem `com.dictato.app`. Categories: `AppState`, `Permissions`, `PasteService`. View in Xcode console or Console.app.
