# Dictascade

Dictascade is a native speech-to-text app for macOS and iOS. It records speech, transcribes it on-device, and can optionally clean up or reformat the result with Apple Intelligence, OpenAI, or Groq.

Raw audio is not sent to a transcription service. When cloud post-processing is enabled for a mode, only the resulting transcript is sent to the selected LLM provider.

## Highlights

### macOS

- Menu bar app with a floating recording and transcription overlay.
- Two local transcription engines, selectable per mode:
  - [FluidAudio](https://github.com/FluidInference/FluidAudio) with Parakeet TDT V3.
  - [WhisperKit](https://github.com/argmaxinc/WhisperKit) with Whisper Large V3 Turbo.
- Configurable global shortcuts for toggling recording and reusing the latest transcript.
- Automatic paste at the current cursor, with optional clipboard restoration and per-application shortcut overrides.
- Pause, resume, discard, cancel, and failed-recording recovery controls.
- Audio-file import from the menu bar.
- Models are downloaded explicitly from Settings. Loading starts in the background while recording.

### iOS

- On-device transcription with FluidAudio and Parakeet TDT V3.
- Automatic model download, compilation, and loading with first-run progress.
- Liquid Glass interface with recording, pause, discard, share, and copy actions.
- Audio-file import from the main tab bar.
- Live Activity and Dynamic Island status while recording or transcribing, including a stop action.
- Deep links and Apple Shortcuts integration.

### Both platforms

- Custom modes with a name, language, post-processing provider, model, and system prompt.
- Optional post-processing through Apple Intelligence, OpenAI, or Groq.
- Custom vocabulary boosting for names and domain-specific terms when using Parakeet.
- Local transcript history with original and post-processed text.
- Audio retained for the five most recent recorded transcripts, enabling re-transcription with another mode.
- Optional iCloud sync for modes and vocabulary, with conflict resolution when local and remote settings differ.
- Apple Shortcuts actions for starting recording, stopping and returning the transcript, and transcribing an audio file.

## How it works

1. Audio is captured with `AVAudioEngine` and converted to 16 kHz mono samples.
2. The selected local model transcribes those samples on-device.
3. If the active mode has post-processing configured, the transcript is passed to its selected LLM.
4. The original and processed text are saved to local history.
5. macOS copies or pastes the final text; iOS presents it for copying or sharing.

On macOS, model loading begins while recording. WhisperKit is unloaded after transcription to release memory; FluidAudio remains loaded for faster subsequent use.

## Requirements

- macOS 26.0+ or iOS 26.0+
- Xcode 26.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- A physical iPhone is recommended for microphone, Live Activity, and on-device model testing

## Getting started

Install XcodeGen if needed:

```bash
brew install xcodegen
```

The generated `.xcodeproj` directories are intentionally ignored by Git. Regenerate the relevant project after cloning, pulling project configuration changes, or adding source files.

### macOS

```bash
cd macos
xcodegen generate
open Dictascade.xcodeproj
```

Build and run the `Dictascade` scheme from Xcode. On the first launch, open Settings, download at least one transcription model, and assign a downloaded engine to each mode you want to use.

Command-line build:

```bash
cd macos
xcodegen generate
xcodebuild \
  -project Dictascade.xcodeproj \
  -scheme Dictascade \
  -destination 'platform=macOS' \
  build
```

### iOS

```bash
cd ios
xcodegen generate
open Dictascade.xcodeproj
```

Build and run the `Dictascade` scheme on an iOS 26 device. The app downloads and compiles the Parakeet model during its first initialization; subsequent launches use the cached model.

Command-line build:

```bash
cd ios
xcodegen generate
xcodebuild \
  -project Dictascade.xcodeproj \
  -scheme Dictascade \
  -destination 'generic/platform=iOS' \
  build
```

## Permissions

### macOS

Dictascade requests:

- **Microphone** for recording.
- **Accessibility** for automatic paste and global keyboard interaction.
- **Input Monitoring** when required by macOS for the global shortcut.

Without Accessibility permission, Dictascade can still place the result on the clipboard, but it cannot simulate paste into the active app.

### iOS

The app requests **Microphone** access before recording. Background audio mode is enabled so an active recording can continue while the app is backgrounded.

## Modes and post-processing

Each mode can define:

- a display name;
- a transcription language or automatic detection;
- a post-processing provider: None, Apple Intelligence, OpenAI, or Groq;
- an API model for OpenAI or Groq;
- a system prompt describing how to transform the transcript;
- a transcription engine on macOS.

OpenAI and Groq API keys are configured locally in Settings and are not included in iCloud sync. Available API models are fetched from the selected provider. Post-processing is skipped when the provider, model, or prompt is incomplete, and the local transcript remains available if post-processing fails.

Vocabulary entries use one line per term. Aliases can be provided after a colon:

```text
Dictascade: dict cascade, dicta scade
Acme Corporation: Acme Corp, ACME
```

Vocabulary boosting may download an additional FluidAudio CTC model the first time it is enabled.

## iCloud sync

Mode and vocabulary sync uses `NSUbiquitousKeyValueStore` and is enabled by default. It can be disabled independently on either device.

Synced mode fields include the name, language, prompt, provider, and LLM model. The macOS transcription engine remains device-local. The following data is not synced:

- API keys;
- transcript history;
- cached audio recordings;
- selected mode;
- downloaded model files.

## Apple Shortcuts and deep links

Both platforms expose these App Intents:

- **Start Recording** with an optional mode.
- **Stop Recording** and return the resulting text.
- **Transcribe Audio** with an optional mode.

iOS also supports:

```text
dictascade://record
dictascade://record?mode=email
dictascade://stop
```

Mode names in the `record` deep link are matched case-insensitively; spaces can be represented with `+`, `-`, or `_`.

## Project structure

```text
.
├── macos/
│   ├── Dictascade/
│   │   ├── App/          # App entry point, AppState, and App Intents
│   │   ├── Models/       # Transcription and mode models
│   │   ├── Services/     # Models, LLMs, permissions, paste, and iCloud sync
│   │   ├── Shortcuts/    # Global keyboard shortcut definitions
│   │   └── UI/           # Menu, overlay, history, and settings
│   └── project.yml       # macOS XcodeGen specification
├── ios/
│   ├── Dictascade/
│   │   ├── App/          # App entry point, AppState, and App Intents
│   │   ├── Models/       # Transcription and mode models
│   │   ├── Services/     # LLMs, permissions, and iCloud sync
│   │   └── UI/           # Home, history, and settings
│   ├── DictascadeWidget/ # Live Activity and Dynamic Island extension
│   ├── Shared/           # ActivityKit attributes shared with the extension
│   └── project.yml       # iOS XcodeGen specification
├── assets-raw/           # Source artwork
└── scripts/              # Distribution scripts
```

`AppState` is the central `@MainActor` observable state object on both platforms. macOS delegates engine lifecycle to `ModelManager`; iOS owns its FluidAudio manager directly.

## Local data

Application data is stored below the platform's Application Support directory:

```text
Dictascade/
├── history.json
├── modes.json
└── Recordings/           # WAV files for the five newest recorded transcripts
```

Transcription models are managed separately by WhisperKit and FluidAudio in their respective cache or Application Support locations.

## macOS distribution

The repository includes a script for Developer ID signing, notarization, and packaging for direct distribution:

```bash
APPLE_ID="your@email.com" \
APP_PASSWORD="your-app-specific-password" \
./scripts/notarize.sh
```

To install the notarized build in `/Applications` as well:

```bash
APPLE_ID="your@email.com" \
APP_PASSWORD="your-app-specific-password" \
./scripts/notarize.sh --install
```

Create the app-specific password at [account.apple.com](https://account.apple.com) under **Sign-In and Security → App-Specific Passwords**. The packaged app is written to `macos/build/export/Dictascade.zip`.

## Development notes

- Core ML compilation is cached, but a changed development code signature can invalidate that cache. A first run after rebuilding may therefore be much slower.
- macOS Accessibility trust is also tied to the app's code signature. Avoid rebuilding between granting permission and testing it; relaunch the existing build instead.
- Logs use subsystem `com.dictascade.app` with categories including `AppState`, `ModelManager`, `ModeSync`, `Permissions`, and `PasteService`. Inspect them in Xcode or Console.app.
- The macOS target currently uses Developer ID signing and hardened runtime for direct distribution.

## Main dependencies

- [FluidAudio](https://github.com/FluidInference/FluidAudio)
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) on macOS
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) on macOS
