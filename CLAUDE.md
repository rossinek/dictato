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
- `AppState.swift` — `@MainActor` singleton (`AppState.shared`). Drives recording through `AudioRecorder`, delegates transcription to `ModelManager`. All state flows through here.

#### Recording & Transcription Flow
1. Global shortcut (default: **Option+Space**) toggles recording via `AppState.toggleRecording()`
2. `AudioRecorder` (`Services/AudioRecorder.swift`) captures with `AVCaptureSession` + `AVCaptureAudioDataOutput`, which delivers 16kHz mono Float32 directly — unified pipeline for both engines. The input device comes from the microphone priority list (Settings → Microphone; first connected entry wins, "Auto" = system default, always last); a device that disconnects mid-recording is replaced in the running session by the next entry, a newly connected higher-priority device is used from the next recording
3. Model preloading begins in the background when recording starts (via `ModelManager.preload()`)
4. If the user changes modes mid-recording, the previous model load is cancelled and the new one starts
5. On stop, `AppState` awaits model load completion, then passes accumulated `[Float]` samples to the loaded engine
6. Result is inserted at the cursor via `PasteService`: clipboard + CGEvent Cmd+V, or Unicode typing (`KeyboardTyper`) for Chromium 155–156 browsers and apps set to "Type" (see docs/automatic-paste.md)
7. Model is unloaded from RAM after transcription (Whisper is held for 60 s first, see below)
8. Transcription is saved to history

#### Model Management
- Models are **not auto-downloaded** at launch. The user downloads models explicitly from Settings.
- If no models are downloaded on first launch, Settings opens automatically.
- Each mode specifies which transcription engine to use (per-mode selection).
- Models are loaded on demand. Parakeet stays loaded; Whisper is held for 60 s after a transcription, a discarded recording or a mode switch (dictation sessions reuse the warm model), then released, or earlier under memory pressure.
- `ModelManager` (`Services/ModelManager.swift`) abstracts both engines behind a common preload/transcribe/unload lifecycle.

#### Key Files
```
macos/Dictascade/
├── App/
│   ├── DictascadeApp.swift       # App entry, MenuBarExtra, AppDelegate
│   ├── AppState.swift            # Central state, recording lifecycle, mode management
│   └── AppIntents.swift          # Apple Shortcuts (Start Recording, Transcribe File)
├── UI/
│   ├── FloatingPanel.swift       # NSPanel (non-activating, won't steal focus)
│   ├── PanelPlacement.swift      # Overlay position: proportional top-center anchor, saved only after a drag
│   ├── RecordingOverlay.swift    # Pill-shaped recording/transcribing indicator
│   ├── MainWindowView.swift      # Tab-based window (History + Settings)
│   ├── HistoryView.swift         # Past transcriptions list (click to copy)
│   ├── SettingsView.swift        # Model downloads, shortcut, modes, API keys
│   └── MicrophoneSettingsSection.swift # Microphone priority list
├── Services/
│   ├── ModelManager.swift        # Multi-engine abstraction (WhisperKit + FluidAudio)
│   ├── LLMService.swift          # OpenAI/Groq post-processing
│   ├── PasteService.swift        # Clipboard + CGEvent Cmd+V
│   ├── KeyboardTyper.swift       # Unicode typing fallback (no clipboard)
│   ├── ChromiumEngineDetector.swift # Detects Chromium 155–156 (drops synthetic pastes)
│   ├── PermissionsService.swift  # Mic & accessibility permission checks
│   ├── InputDevicePreference.swift # Microphone priority list + resolver (pure, unit-tested)
│   ├── AudioInputDevices.swift   # CoreAudio device list, clamshell check, monitor
│   └── AudioRecorder.swift       # Microphone capture (AVCaptureSession, device priority, fail-over)
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

- **Automatic paste regression:** Before changing synthetic keyboard events or clipboard restoration, read [docs/automatic-paste.md](docs/automatic-paste.md) and run `PasteboardTests`. Never leave synthetic shortcut modifiers on the final key-up. Test paste changes across apps with `scripts/paste-harness`.

- **Slow first model download:** WhisperKit prewarming compiles the CoreML model during download (~2-3 min). Cached after that, but cache is invalidated by code signature changes (every Xcode rebuild). FluidAudio has a similar first-load compilation cost.
- **Whisper variant:** Use `openai_whisper-large-v3-v20240930_turbo` (real Turbo, 4 decoder layers; ~2 s for 17 s of audio on M3 Pro). `openai_whisper-large-v3_turbo` is full Large V3 with 32 decoder layers (~12 s) and is removed at launch, then the new variant is downloaded. The `_632MB` build is ~1.2 s, but its first Core ML compilation takes ~2.5 min and repeats when the ANE cache is lost (e.g. the app runs from a new path). With `language: nil`, `detectLanguage` must be set explicitly or WhisperKit forces English. Whisper loads on the ANE (~0.6–0.9 s, usable immediately); a second encoder copy is then loaded on the GPU and swapped in once its first encode is done. The GPU first encode after every load takes ~5 s (MPS graph specialization, not cached across loads), warm it is ~0.7 s vs ~1.2 s on the ANE, so warming in the background while recording and holding the model gives ~1 s transcriptions without short recordings ever waiting for the GPU. A GPU decoder brings nothing. Settings → Whisper Acceleration (`WhisperAcceleration`, `UserDefaults` key `whisperAcceleration`) offers Hybrid (default), Neural Engine only and GPU only; GPU only warms the encoder inside the load, so short recordings wait for it. After a new build/install the first ANE encode takes ~4 s, the first GPU load ~2 s and the first GPU decode ~1.5 s once, so `warmUpWhisperAtLaunch` (called when a mode uses Whisper) loads Whisper 3 s after launch and transcribes 2 s of noise, then holds it like after a transcription. Digital silence at the edges (Bluetooth profile switch) is trimmed (`SilenceTrimmer`) and temperature fallback is capped at 1 — leading silence made Whisper re-decode up to 5 times (4–6 s instead of 2 s). Per-transcription timings are logged at `.notice` (`Whisper: … encoder … (GPU|ANE), decoder … fallbacks`), as are load, GPU-ready, hold and release events (`.info` is not persisted by `log show`).
- **Accessibility permissions:** Tied to code signature. After rebuilding, you may need to re-add the app in System Settings > Privacy & Security > Accessibility.
- **Sandbox disabled:** Entitlements file is empty for development. Needs proper sandbox + hardened runtime for distribution.
- **Microphone capture:** Do not go back to `AVAudioEngine` for recording. Creating its input node opens the system default input first: with AirPods connected that cost ~1 s even when recording from the built-in microphone, a device bound afterwards kept the previous device's format (`-10868`) and Bluetooth profile switches raised NSExceptions from `installTap`. `AVCaptureSession` opens only the chosen device (built-in: first audio after ~80 ms with AirPods connected). Bluetooth headsets still deliver ~1.5–2.2 s of digital silence while switching to the headset profile (firmware; `First audio after N ms` can fire early on a short blip before it). If the switch fails — recording started while the headset was still leaving the profile after the previous recording, e.g. during the completion sound — bluetoothd gives up (`eSCO connect failed`, `audio connection failure`) and the session delivers silence with no error. `AudioRecorder` therefore switches a Bluetooth input that stays below -120 dBFS for 4 s to the next device (built-in microphone preferred), keeping the captured samples.
- **Overlay panel drag & position:** On macOS 27 `isMovableByWindowBackground` no longer moves a window over SwiftUI content; `FloatingPanel.sendEvent` starts `performDrag(with:)` after 3 pt of movement (clicks still reach SwiftUI). The position is stored as a top-center anchor in fractions of the screen's visible frame (`PanelPlacement`), saved only when a drag ends — never on hide — and resizes keep the top edge fixed; this prevents drift and places the pill proportionally on any screen.
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
