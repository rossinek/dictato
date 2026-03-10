# Dictato

Local speech-to-text for macOS and iOS. Records speech and transcribes locally — no cloud transcription. Optionally post-processes transcriptions via OpenAI or Groq.

- **macOS**: Menu bar app using [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Whisper large-v3-turbo). Global shortcut to record, auto-pastes at cursor.
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
open Dictato.xcodeproj
```

Build and run from Xcode (Cmd+R).

### iOS

```bash
cd ios
xcodegen generate
open Dictato.xcodeproj
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

- `dictato://record` — open app and start recording
- `dictato://record?mode=email` — start recording with a specific mode

The app also provides a **Start Recording** shortcut in the Apple Shortcuts app with mode selection.

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

Output: `build/export/Dictato.zip`

## Notes

- First launch is slow while CoreML compiles the model for your hardware (~2-3 min on macOS, ~40s on iOS). Cached after that, but cache is invalidated by code signature changes (every Xcode rebuild).
- The `.xcodeproj` is gitignored — always regenerate with `xcodegen generate` after pulling changes.
