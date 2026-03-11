# Dictascade

Local speech-to-text for macOS and iOS. Records speech and transcribes locally — no cloud transcription. Optionally post-processes transcriptions via OpenAI or Groq.

- **macOS**: Menu bar app with two transcription engines — [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Whisper large-v3-turbo) and [FluidAudio](https://github.com/FluidInference/FluidAudio) (Parakeet TDT v3). Global shortcut to record, auto-pastes at cursor. Models downloaded on demand, loaded per-transcription.
- **iOS**: Standalone app using [FluidAudio](https://github.com/FluidInference/FluidAudio) (Parakeet TDT v3). Liquid Glass UI, Apple Shortcuts integration, deep links.

## Requirements

- macOS 26.0+ / iOS 26.0+
- Xcode 26.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Setup

```bash
# Install XcodeGen (if not already installed)
brew install xcodegen
```

### macOS

```bash
cd macos
xcodegen generate
open Dictascade.xcodeproj
```

Build and run from Xcode (Cmd+R).

### iOS

```bash
cd ios
xcodegen generate
open Dictascade.xcodeproj
```

Build and run on a device from Xcode.

## Permissions

### macOS

On first launch, grant the following in **System Settings > Privacy & Security**:

- **Microphone** — for recording
- **Accessibility** — for global shortcut and paste simulation
- **Input Monitoring** — for keyboard event tap

### iOS

- **Microphone** — prompted on first recording

## iOS Deep Links

- `dictascade://record` — open app and start recording
- `dictascade://record?mode=email` — start recording with a specific mode

The app also provides **Start Recording** and **Transcribe Audio File** shortcuts in the Apple Shortcuts app, synced across macOS and iOS.

## Scripts

### Sign, notarize & distribute (macOS)

Builds, signs with Developer ID, notarizes with Apple, and produces a distributable zip:

```bash
APPLE_ID="your@email.com" APP_PASSWORD="your-app-specific-password" ./scripts/notarize.sh
```

To also install the notarized build to `/Applications`:

```bash
APPLE_ID="your@email.com" APP_PASSWORD="your-app-specific-password" ./scripts/notarize.sh --install
```

The app-specific password can be generated at [account.apple.com](https://account.apple.com) under Sign-In and Security → App-Specific Passwords.

Output: `build/export/Dictascade.zip`

## Notes

- On macOS, models are not auto-downloaded. Open Settings to download your preferred transcription engine. First download includes CoreML compilation (~2-3 min), cached after that but invalidated by code signature changes (every Xcode rebuild).
- On iOS, first launch is slow while CoreML compiles the model (~40s). Cached after that, but cache is invalidated by code signature changes (every Xcode rebuild).
- The `.xcodeproj` is gitignored — always regenerate with `xcodegen generate` after pulling changes.
