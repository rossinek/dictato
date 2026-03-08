# Dictato

A minimal SuperWhisper clone for macOS. Menu bar app that records speech via a global shortcut and transcribes it locally using WhisperKit (Whisper large-v3-turbo).

## Build & Run

```bash
# Regenerate Xcode project after adding/removing files
xcodegen generate

# Build
xcodebuild -project Dictato.xcodeproj -scheme Dictato -destination 'platform=macOS' build

# The built app is at:
# ~/Library/Developer/Xcode/DerivedData/Dictato-*/Build/Products/Debug/Dictato.app
```

**Important:** Do not rebuild between accessibility permission grants — each rebuild changes the ad-hoc code signature, invalidating macOS accessibility trust. Relaunch without rebuilding when testing.

## Architecture

### Entry Point
- `DictatoApp.swift` — SwiftUI `@main` app. `MenuBarExtra` for the tray icon/menu. `AppDelegate` handles shortcut registration and floating panel lifecycle.
- `AppState.swift` — `@MainActor` singleton (`AppState.shared`). Owns WhisperKit instance, recording state, transcription history. All state flows through here.

### Recording & Transcription Flow
1. Global shortcut (default: **Option+Space**) toggles recording via `AppState.toggleRecording()`
2. Recording uses WhisperKit's built-in `audioProcessor.startRecordingLive()` — no custom AVAudioEngine
3. On stop, accumulated `[Float]` samples are passed to `whisperKit.transcribe(audioArray:)`
4. Result is pasted at cursor via `PasteService` (CGEvent Cmd+V simulation)
5. Transcription is saved to history

### Key Files
```
Dictato/
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

### Dependencies (SPM via project.yml)
- **WhisperKit** (argmaxinc) — model download, audio processing, transcription
- **KeyboardShortcuts** (sindresorhus) — global hotkey with configurable UI

### Data Storage
- **Model files:** `~/Library/Application Support/Dictato/Models/`
- **Transcription history:** `~/Library/Application Support/Dictato/history.json`

## Known Issues / Dev Notes

- **Slow first launch:** CoreML compiles the model for your hardware on first load (~2-3 min). Cached after that, but cache is invalidated by code signature changes (every Xcode rebuild).
- **Accessibility permissions:** Tied to code signature. After rebuilding, you may need to re-add the app in System Settings > Privacy & Security > Accessibility.
- **Sandbox disabled:** Entitlements file is empty for development. Needs proper sandbox + hardened runtime for distribution.
- **State observation:** The floating panel is managed via a polling Task (100ms) watching `AppState` properties. This works but could be replaced with Combine publishers if needed.

## Adding New Features

- **New UI:** Add SwiftUI views in `Dictato/UI/`, run `xcodegen generate` to update the project.
- **Settings:** Add controls to `SettingsView.swift`, store values with `@AppStorage` or `UserDefaults`.
- **Model selection:** Change the variant string in `AppState.initializeWhisperKit()`. Available variants are in the `argmaxinc/whisperkit-coreml` HuggingFace repo.

## Logging

Uses `os.Logger` with subsystem `com.dictato.app`. Categories: `AppState`, `Permissions`, `PasteService`. View in Xcode console or Console.app.
