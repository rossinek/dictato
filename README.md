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

## Notes

- First launch is slow (~2-3 min) while CoreML compiles the Whisper model for your hardware. Cached after that.
- The `.xcodeproj` is gitignored — always regenerate with `xcodegen generate` after pulling changes.
