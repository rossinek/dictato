# Dictato

A minimal macOS menu bar app for speech-to-text. Records speech via a global shortcut and transcribes locally using [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Whisper large-v3-turbo). Optionally post-processes transcriptions via OpenAI or Groq.

## Requirements

- macOS 26.0+
- Xcode 26.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Setup

```bash
# Install XcodeGen (if not already installed)
brew install xcodegen

# Generate Xcode project
xcodegen generate

# Open in Xcode
open Dictato.xcodeproj
```

Build and run from Xcode (Cmd+R).

## Permissions

On first launch, grant the following in **System Settings > Privacy & Security**:

- **Microphone** — for recording
- **Accessibility** — for global shortcut and paste simulation
- **Input Monitoring** — for keyboard event tap

## Scripts

### Sign, notarize & distribute

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

- First launch is slow (~2-3 min) while CoreML compiles the Whisper model for your hardware. Cached after that.
- The `.xcodeproj` is gitignored — always regenerate with `xcodegen generate` after pulling changes.
