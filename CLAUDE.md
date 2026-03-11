# Dictascade

A minimal SuperWhisper clone. Records speech and transcribes it locally.

## Repository Structure

```
.
├── macos/          # macOS menu bar app (WhisperKit + FluidAudio)
│   ├── Dictascade/ # Source code
│   ├── project.yml # XcodeGen spec
│   └── ExportOptions.plist
├── ios/            # iOS app (FluidAudio/Parakeet TDT v3)
│   ├── Dictascade/ # Source code
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
xcodebuild -project Dictascade.xcodeproj -scheme Dictascade -destination 'platform=macOS' build

# The built app is at:
# ~/Library/Developer/Xcode/DerivedData/Dictascade-*/Build/Products/Debug/Dictascade.app
```

**Important:** Do not rebuild between accessibility permission grants — each rebuild changes the ad-hoc code signature, invalidating macOS accessibility trust. Relaunch without rebuilding when testing.

### Architecture

#### Entry Point
- `DictascadeApp.swift` — SwiftUI `@main` app. `MenuBarExtra` for the tray icon/menu. `AppDelegate` handles shortcut registration and floating panel lifecycle.
- `AppState.swift` — `@MainActor` singleton (`AppState.shared`). Owns AVAudioEngine recording, delegates transcription to `ModelManager`. All state flows through here.

#### Recording & Transcription Flow
1. Global shortcut (default: **Option+Space**) toggles recording via `AppState.toggleRecording()`
2. Recording uses `AVAudioEngine` with `inputNode.installTap()`, converting to 16kHz mono — unified pipeline for both engines
3. Model preloading begins in the background when recording starts (via `ModelManager.preload()`)
4. If the user changes modes mid-recording, the previous model load is cancelled and the new one starts
5. On stop, `AppState` awaits model load completion, then passes accumulated `[Float]` samples to the loaded engine
6. Result is pasted at cursor via `PasteService` (CGEvent Cmd+V simulation)
7. Model is unloaded from RAM after transcription
8. Transcription is saved to history

#### Model Management
- Models are **not auto-downloaded** at launch. The user downloads models explicitly from Settings.
- If no models are downloaded on first launch, Settings opens automatically.
- Each mode specifies which transcription engine to use (per-mode selection).
- Models are loaded on demand and unloaded after each transcription — no persistent RAM usage.
- `ModelManager` (`Services/ModelManager.swift`) abstracts both engines behind a common preload/transcribe/unload lifecycle.

#### Key Files
```
macos/Dictascade/
├── App/
│   ├── DictascadeApp.swift       # App entry, MenuBarExtra, AppDelegate
│   ├── AppState.swift            # Central state, AVAudioEngine recording, mode management
│   └── AppIntents.swift          # Apple Shortcuts (Start Recording, Transcribe File)
├── UI/
│   ├── FloatingPanel.swift       # NSPanel (non-activating, won't steal focus)
│   ├── RecordingOverlay.swift    # Pill-shaped recording/transcribing indicator
│   ├── MainWindowView.swift      # Tab-based window (History + Settings)
│   ├── HistoryView.swift         # Past transcriptions list (click to copy)
│   └── SettingsView.swift        # Model downloads, shortcut, modes, API keys
├── Services/
│   ├── ModelManager.swift        # Multi-engine abstraction (WhisperKit + FluidAudio)
│   ├── LLMService.swift          # OpenAI/Groq post-processing
│   ├── PasteService.swift        # Clipboard + CGEvent Cmd+V
│   └── PermissionsService.swift  # Mic & accessibility permission checks
├── Shortcuts/
│   └── GlobalShortcut.swift      # KeyboardShortcuts.Name definition
├── Models/
│   ├── Transcription.swift       # Codable data model
│   └── TranscriptionMode.swift   # Mode with engine selection
└── Resources/
    ├── Info.plist                 # LSUIElement=YES, mic usage description
    └── Dictascade.entitlements    # Empty (no sandbox for dev)
```

#### Dependencies (SPM via project.yml)
- **WhisperKit** (argmaxinc) — Whisper Large V3 Turbo model download and transcription
- **FluidAudio** (FluidInference) — Parakeet TDT V3 model download and transcription
- **KeyboardShortcuts** (sindresorhus) — global hotkey with configurable UI

#### Data Storage
- **WhisperKit models:** `~/Library/Application Support/Dictascade/Models/`
- **FluidAudio models:** `~/Library/Application Support/Dictascade/FluidAudio/`
- **Transcription history:** `~/Library/Application Support/Dictascade/history.json`

### Known Issues / Dev Notes

- **Slow first model download:** WhisperKit prewarming compiles the CoreML model during download (~2-3 min). Cached after that, but cache is invalidated by code signature changes (every Xcode rebuild). FluidAudio has a similar first-load compilation cost.
- **Accessibility permissions:** Tied to code signature. After rebuilding, you may need to re-add the app in System Settings > Privacy & Security > Accessibility.
- **Sandbox disabled:** Entitlements file is empty for development. Needs proper sandbox + hardened runtime for distribution.
- **State observation:** The floating panel is managed via a polling Task (100ms) watching `AppState` properties. This works but could be replaced with Combine publishers if needed.

### Adding New Features

- **New UI:** Add SwiftUI views in `macos/Dictascade/UI/`, run `xcodegen generate` from `macos/` to update the project.
- **Settings:** Add controls to `SettingsView.swift`, store values with `@AppStorage` or `UserDefaults`.
- **New transcription engine:** Add a case to `TranscriptionEngine` enum in `ModelManager.swift`, implement download/load/transcribe/unload methods, and add UI in `SettingsView`.

## iOS App

### Build & Run

```bash
cd ios

# Regenerate Xcode project after adding/removing files
xcodegen generate

# Build
xcodebuild -project Dictascade.xcodeproj -scheme Dictascade -destination 'generic/platform=iOS' build
```

**Important:** CoreML recompiles models when the code signature changes (every Xcode rebuild). This makes each launch after a rebuild slow (~40s). Subsequent launches without rebuilding are fast (~1-2s). This only affects development.

### Architecture

#### Entry Point
- `DictascadeApp.swift` — SwiftUI `@main` app. `TabView` with Home, History, Settings tabs + file import action.
- `AppState.swift` — `@MainActor` singleton (`AppState.shared`). Owns FluidAudio `AsrManager`, AVAudioEngine recording, transcription history. All state flows through here.

#### Recording & Transcription Flow
1. User taps the central record button on HomeView
2. Recording uses `AVAudioEngine` with a tap on `inputNode`, converting to 16kHz mono via `AVAudioConverter`
3. On stop, accumulated `[Float]` samples are passed to `asrManager.transcribe(samples, source: .system)`
4. Result is shown in a sheet with Copy button
5. Transcription is saved to history

#### Key Files
```
ios/Dictascade/
├── App/
│   ├── DictascadeApp.swift       # App entry, TabView, file import
│   ├── AppState.swift            # Central state, FluidAudio lifecycle, AVAudioEngine recording
│   └── AppIntents.swift          # Apple Shortcuts (Start Recording, Transcribe File)
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
│   └── Info.plist                # Mic usage, URL scheme (dictascade://)
├── Assets.xcassets/              # Asset catalog
└── AppIcon.icon/                 # Layered app icon (Icon Composer format)
```

#### Dependencies (SPM via project.yml)
- **FluidAudio** — Parakeet TDT v3 CoreML model download, loading, and transcription

#### Deep Links
- `dictascade://record` — opens app and starts recording with current mode
- `dictascade://record?mode=email` — starts recording with specified mode (case-insensitive, `+`/`-`/`_` match spaces)

#### Shortcuts
- **Start Recording** — available in Apple Shortcuts app. Opens Dictascade and starts recording. Supports mode selection via parameter.
- **Transcribe Audio File** — accepts an audio file, transcribes it in the background, and returns the text. Model must be loaded first by opening the app.

Both shortcuts use the same intent names on macOS and iOS (`com.dictascade.app` bundle ID) so they sync across devices via iCloud.

#### Data Storage
- **Model files:** `<AppSupport>/FluidAudio/Models/` (managed by FluidAudio)
- **Transcription history:** `<AppSupport>/Dictascade/history.json`
- **Audio cache:** `<AppSupport>/Dictascade/Recordings/`

#### UI Design
- iOS 26 Liquid Glass effects throughout (`.glassEffect()`, `GlassEffectContainer`)
- State-driven central button with animated secondary actions
- Mode pills with `matchedGeometryEffect` sliding selection
- Glass cards in history with swipe-to-delete and context menu

## Logging

Uses `os.Logger` with subsystem `com.dictascade.app`. Categories: `AppState`, `ModelManager`, `Permissions`, `PasteService`. View in Xcode console or Console.app.
