# Dictato for iOS — Full Specification

## Overview

Dictato is a speech-to-text app that records audio, transcribes it locally using FluidAudio (Parakeet TDT v3 CoreML), optionally post-processes the result through an LLM, and presents the transcription for copying. This document specifies the iOS version, which replicates all macOS features adapted for a touch interface.

## Architecture

### Dependencies (SPM)
- **FluidAudio** (`https://github.com/FluidInference/FluidAudio.git`, from `0.12.2`) — model download, local transcription via Parakeet TDT v3 CoreML
- No KeyboardShortcuts (macOS-only)
- No WhisperKit (macOS version uses WhisperKit; iOS uses FluidAudio instead)

### Core Engine: AppState

A `@MainActor` singleton `ObservableObject` that owns all state. Two differences from macOS: (1) uses FluidAudio/Parakeet instead of WhisperKit for transcription, (2) instead of pasting via CGEvent after transcription, it sets a `lastTranscriptionResult` published property that the UI displays.

#### Published Properties

| Property | Type | Purpose |
|----------|------|---------|
| `isRecording` | `Bool` | Microphone is actively capturing |
| `isPaused` | `Bool` | Recording paused (mutually exclusive with `isRecording`) |
| `isTranscribing` | `Bool` | Parakeet transcription in progress |
| `isPostProcessing` | `Bool` | LLM post-processing in progress |
| `isModelLoaded` | `Bool` | Parakeet model ready |
| `modelLoadingProgress` | `String` | Status text during model download/compile |
| `isError` | `Bool` | Last transcription failed |
| `transcriptionHistory` | `[Transcription]` | All past transcriptions, newest first |
| `modes` | `[TranscriptionMode]` | User-configured transcription modes |
| `selectedModeIndex` | `Int` | Currently active mode |
| `reTranscribingID` | `UUID?` | Which history item is being re-transcribed (for loading indicator) |
| `isFileTranscribing` | `Bool` | File import transcription in progress |
| `lastTranscriptionResult` | `Transcription?` | **iOS only.** Set after successful transcription; drives the result sheet |

#### Private Properties
- `asrManager: AsrManager?` — FluidAudio ASR manager, initialized asynchronously on launch
- `audioSamples: [Float]` — accumulated 16kHz mono samples during recording
- `failedSamples: [Float]` — samples from a failed transcription (for export)
- `transcriptionTask: Task<Void, Never>?` — cancellable handle

### Data Models

#### Transcription
```swift
struct Transcription: Identifiable, Codable {
    let id: UUID           // Auto-generated
    var text: String       // Raw transcription output
    let date: Date         // Auto-set to creation time
    var modeName: String?  // Name of mode used
    var postProcessedText: String? // LLM-processed text (if mode has post-processing)
    var audioFileName: String?     // Cached audio filename (e.g. "UUID.wav")
}
```

Backward-compatible decoding: `modeName`, `postProcessedText`, `audioFileName` use `decodeIfPresent`.

#### TranscriptionMode
```swift
struct TranscriptionMode: Identifiable, Codable {
    let id: UUID
    var name: String        // Display name (e.g. "Default", "Email")
    var language: String?   // ISO code or nil for auto-detect
    var prompt: String      // System prompt for LLM post-processing
    var provider: LLMProvider // .none, .openai, .groq
    var model: String?      // LLM model ID (e.g. "gpt-4")
}
```

At least one mode always exists. If none found on disk, create `TranscriptionMode.default` (name: "Default", language: nil, prompt: "", provider: .none).

#### LLMProvider
```swift
enum LLMProvider: String, Codable, CaseIterable {
    case none    // No post-processing
    case openai  // baseURL: https://api.openai.com/v1
    case groq    // baseURL: https://api.groq.com/openai/v1
}
```

### Services

#### LLMService
Static methods, no state.

**`postProcess(provider:model:systemPrompt:userMessage:) async throws -> String`**
- Calls `POST /chat/completions` on the provider's base URL
- Auth: Bearer token from UserDefaults (`openai_api_key` or `groq_api_key`)
- System prompt is extended with: `"You will receive a transcription wrapped in <transcription> tags. Apply your instructions to this text. Output only the processed result, no tags or explanations."`
- User message wrapped in `<transcription>` XML tags
- Returns the assistant's response text

**`fetchModels(provider:) async throws -> [String]`**
- Calls `GET /models` on the provider's base URL
- OpenAI: filters out non-text models (image, audio, realtime, embedding, dall-e, etc.)
- Sorts by creation date descending
- Returns array of model ID strings

#### PasteService
**Not used on iOS.** On macOS this simulates Cmd+V via CGEvent. On iOS, copying to clipboard is done via `UIPasteboard.general.string = text` and the user pastes manually.

#### PermissionsService
iOS version only needs microphone permission. No accessibility permission needed.
- Check: `AVAudioSession.sharedInstance().recordPermission`
- Request: `AVAudioSession.sharedInstance().requestRecordPermission()`

### Storage

All paths relative to app's `Application Support` directory (iOS: inside app sandbox).

| Item | Path | Format |
|------|------|--------|
| Parakeet models | `Dictato/Models/` | CoreML (downloaded by FluidAudio) |
| Transcription history | `Dictato/history.json` | JSON array of `Transcription` |
| Mode configuration | `Dictato/modes.json` | JSON array of `TranscriptionMode` |
| Cached recordings | `Dictato/Recordings/*.wav` | PCM WAV, 16kHz, mono, float32 |
| API keys | `UserDefaults` | Keys: `openai_api_key`, `groq_api_key` |

### Audio Caching

- After each successful live transcription, save the raw `[Float]` samples as `<UUID>.wav` (16kHz mono) in the Recordings directory.
- Store the filename in `Transcription.audioFileName`.
- Keep only the **5 most recent** cached audio files. On cleanup, delete older WAV files from disk and set their `audioFileName` to nil.
- Cleanup runs on app launch and after each new transcription.
- File transcriptions (imported files) do **not** cache audio.

### Audio File Import

**`loadAudioFromFile(url:) -> [Float]?`**
- Opens any audio file via `AVAudioFile`
- If already 16kHz mono: returns samples directly
- Otherwise: converts via `AVAudioConverter` to 16kHz mono float
- Supports WAV, MP3, M4A, AIFF, CAF, and any format AVAudioFile can read

**`transcribeFile(url:mode:completion:)`**
- Guards: not recording, not transcribing, model loaded
- Loads samples, transcribes, post-processes (if mode configured), saves to history
- Does **not** paste, does **not** play sounds
- Calls completion when done (UI navigates to history)

---

## Screens

### 1. Main Screen (Home)

The primary screen. Shows the record button and current state.

#### Layout (top to bottom, centered)

**Model Loading State** (shown while `!isModelLoaded`):
- Progress text (`modelLoadingProgress`) centered on screen
- Examples: "Downloading model (42%)...", "Compiling model (first launch is slow)..."
- No record button visible until model is ready

**Ready State** (default, `isModelLoaded && !isRecording && !isPaused && !isTranscribing && !isPostProcessing && !isError`):
- **Mode selector**: Horizontal scrollable pill bar showing all modes. Selected mode is visually highlighted (filled background). Tap to select.
- **Record button**: Large circular button (80pt diameter), red fill, microphone icon. Tap to start recording.
- Bottom toolbar with "History" and "Settings" navigation buttons, and "Import File" button.

**Recording State** (`isRecording`):
- **Status indicator**: Red pulsing dot (animation: scale 1.0 to 1.3, 0.8s ease-in-out, repeating) + "Recording..." text
- **Mode selector**: Same horizontal pills, still tappable to switch mode before stopping
- **Action buttons** (horizontally centered):
  - "Pause" button (pause icon) — pauses recording
  - "Stop" button (stop square icon, red) — stops and begins transcription

**Paused State** (`isPaused`):
- **Status indicator**: Yellow static dot + "Paused" text
- **Action buttons**:
  - "Resume" button (play icon) — resumes recording
  - "Discard" button (trash icon) — discards recording, returns to ready state

**Transcribing State** (`isTranscribing`):
- **Status indicator**: Orange static dot + "Transcribing..." text
- **Spinner**: `ProgressView()` below status
- **Action button**: "Cancel" button — cancels transcription, returns to ready state

**Post-Processing State** (`isPostProcessing`):
- **Status indicator**: Blue static dot + "Post-processing..." text
- **Spinner**: `ProgressView()` below status
- **Action button**: "Cancel" button — cancels post-processing

**Error State** (`isError`):
- **Status indicator**: Red static dot + "Transcription failed" text
- **Action buttons**:
  - "Dismiss" button — clears error, returns to ready
  - "Save Recording" button — presents share sheet to export the failed audio as WAV

**Result State** (`lastTranscriptionResult != nil`):
Present as a **sheet** over the main screen:
- Shows the transcription text (full, scrollable, selectable)
- If post-processed text exists: tab toggle between "Original" and "Post-processed" (same style as history rows)
- **"Copy" button**: Copies displayed text to `UIPasteboard.general`, shows brief confirmation (e.g. checkmark or "Copied!" toast)
- **"Done" button**: Dismisses the sheet, clears `lastTranscriptionResult`
- Mode name shown as a caption label

### 2. History Screen

Navigated to from the main screen's toolbar. Shows all past transcriptions.

#### Layout

**Navigation title**: "History"

**Empty state**: "No transcriptions yet" centered, secondary color.

**List of transcription rows** (newest first), each row contains:

1. **Text preview**: Up to 3 lines of the displayed text (original or post-processed based on tab). Text selection enabled.

2. **Relative timestamp** (caption, secondary color):
   - "Just now" (< 60s)
   - "1 minute ago" / "X minutes ago" (< 60m)
   - "1 hour ago" / "X hours ago" (< 24h)
   - "1 day ago" / "X days ago"

3. **Controls row** (horizontal):
   - **Mode indicator / Re-transcribe**:
     - If `reTranscribingID == item.id`: Show small `ProgressView` spinner
     - If audio file exists (`audioFileName` and file on disk): Show mode name as a tappable pill/menu with a `>` indicator. Tapping opens a menu listing all modes. Selecting a mode calls `reTranscribe(transcriptionID:withMode:)`.
     - If no audio: Static pill showing mode name (no interaction)
   - **Tab toggle**: "Original" / "Post-processed" buttons in a segmented style. "Post-processed" disabled (dimmed) if `postProcessedText` is nil.
   - **Save Audio button** (only if audio file exists): Download icon button. Presents a share sheet (`UIActivityViewController`) with the WAV file URL.
   - **Copy button**: doc.on.doc icon. Copies the currently displayed text (original or post-processed based on tab) to clipboard.

#### Re-transcription Flow
1. User taps mode pill on a history row that has cached audio
2. Menu appears with all available modes
3. User picks a mode
4. `reTranscribingID` is set to this item's ID (row shows spinner instead of pill)
5. Audio is loaded from cache, re-transcribed with new mode's language setting
6. If new mode has LLM post-processing configured, that runs too
7. History item is updated in-place: `text`, `postProcessedText`, `modeName` all change
8. `reTranscribingID` cleared, row updates to show new content

### 3. Settings Screen

Navigated to from the main screen's toolbar.

#### Layout

**Navigation title**: "Settings"

Scrollable form with sections:

#### Section: API Keys
Two `SecureField` inputs with rounded borders:
- "OpenAI API Key" — stored in `@AppStorage("openai_api_key")`
- "Groq API Key" — stored in `@AppStorage("groq_api_key")`

#### Section: Modes
List of all `TranscriptionMode`s, separated by dividers.

**Each mode row:**

1. **Top row**: Name text field + Language picker + Delete button (trash icon, only shown if more than 1 mode exists)

2. **Language picker options**:
   - Auto-detect (nil)
   - English ("en"), Spanish ("es"), French ("fr"), German ("de"), Italian ("it"), Portuguese ("pt"), Dutch ("nl"), Japanese ("ja"), Korean ("ko"), Chinese ("zh"), Arabic ("ar"), Russian ("ru"), Hindi ("hi"), Polish ("pl"), Swedish ("sv"), Ukrainian ("uk"), Turkish ("tr")

3. **Post-processing picker**: "None", "OpenAI", "Groq"

4. **If provider != .none**, show additional fields:
   - **Model selection**: Search field + refresh button + loading spinner while fetching. Dropdown/list of models filtered by search text. Selected model displayed below. Models fetched via `LLMService.fetchModels(provider:)`.
   - **System prompt**: Multi-line text editor. Placeholder: "System prompt for post-processing". Min height ~60pt.

**"Add Mode" button** at the bottom:
- Creates a new mode named "Mode X" (auto-incremented)
- Default: no language (auto-detect), no post-processing
- Saves immediately

#### Section: About (optional)
App version, link to project.

### 4. File Import Flow

Triggered from the main screen toolbar "Import File" button.

1. Present document picker (`UIDocumentPickerViewController` or `.fileImporter`) for audio types: WAV, MP3, M4A, AIFF, and generic audio.
2. After file selection, show an action sheet or menu listing all available modes: "Transcribe with [mode name]".
3. On mode selection:
   - `isFileTranscribing = true`
   - Transcribe the file (FluidAudio can transcribe directly from URL via `asrManager.transcribe(audioURL, source: .system)`, or load/convert manually; post-process if mode configured)
   - Create `Transcription` entry in history (no audio caching for file imports)
   - On completion: navigate to History screen
   - `isFileTranscribing = false`

---

## Recording & Transcription Flow (Complete)

### Audio Capture (AVAudioEngine)

Since FluidAudio does not provide a built-in live audio capture API (unlike WhisperKit's `audioProcessor` on macOS), iOS uses `AVAudioEngine` directly to record:

```swift
private var audioEngine: AVAudioEngine?

func startRecording() {
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let recordingFormat = inputNode.outputFormat(forBus: 0)

    // Install tap — accumulate samples, convert to 16kHz mono if needed
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
        // Convert buffer to 16kHz mono [Float] and append to audioSamples
    }

    try engine.start()
    audioEngine = engine
    isRecording = true
}
```

- **Pause**: `audioEngine.pause()` — stops the tap without tearing down. State: `isRecording=false, isPaused=true`.
- **Resume**: `try audioEngine.start()` — resumes the tap. State: `isPaused=false, isRecording=true`.
- **Stop**: `inputNode.removeTap(onBus: 0)`, `audioEngine.stop()`, `audioEngine = nil`.
- **Discard**: Same as stop, but also clears `audioSamples` and returns to ready state.

The tap callback should convert incoming audio to 16kHz mono float (using `AVAudioConverter` if the device's native format differs) and append to `audioSamples: [Float]`.

### Live Recording Flow

1. User taps Record button (ready state, model loaded)
2. `startRecording()`: `AVAudioEngine` begins capturing. Samples (16kHz mono float) accumulate in `audioSamples`.
3. **During recording**, user can:
   - **Pause** (tap Pause): Engine paused. State: `isRecording=false, isPaused=true`.
   - **Switch mode** (tap mode pill): Changes `selectedModeIndex`. Affects which language/post-processing is used when transcription starts.
4. **While paused**, user can:
   - **Resume** (tap Resume): Engine restarted. State: `isPaused=false, isRecording=true`.
   - **Discard** (tap Discard): Engine stopped, samples cleared, return to ready state.
5. User taps **Stop**:
   - Engine stopped and torn down
   - `isRecording=false, isTranscribing=true`
   - Capture current samples and selected mode
6. **Transcription** (async):
   - `let result = try await asrManager.transcribe(samples, source: .system)`
   - Result text: `result.text` (single string, no segment joining needed)
7. **If text is empty**: set `isError=true`, store samples in `failedSamples`
8. **If text is non-empty**:
   - `isTranscribing=false`
   - **Post-processing** (if `mode.provider != .none && mode.model != nil && !mode.prompt.trimmed.isEmpty`):
     - `isPostProcessing=true`
     - Call `LLMService.postProcess(provider, model, systemPrompt, userMessage: text)`
     - On success: store result in `processedText`
     - On error: log, continue with nil `processedText`
     - `isPostProcessing=false`
   - **Cache audio**: Save samples as WAV in Recordings dir, store filename
   - **Create Transcription**: `Transcription(text:, postProcessedText:, modeName:, audioFileName:)`
   - **Insert** at `transcriptionHistory[0]`
   - **Cleanup**: Remove oldest cached audio if more than 5
   - **Save** history to disk
   - **Show result**: Set `lastTranscriptionResult` to show result sheet with Copy button

### Cancellation
- During transcribing or post-processing: user taps "Cancel"
- `transcriptionTask?.cancel()`, clear `isTranscribing` and `isPostProcessing`
- Return to ready state

---

## FluidAudio / Parakeet Configuration

### Initialization

```swift
import FluidAudio

func initializeASR() async {
    modelLoadingProgress = "Downloading model..."

    do {
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        modelLoadingProgress = "Loading model..."

        let asrManager = AsrManager(config: .default)
        try await asrManager.initialize(models: models)

        self.asrManager = asrManager
        isModelLoaded = true
        modelLoadingProgress = "Ready"
    } catch {
        modelLoadingProgress = "Model failed: \(error.localizedDescription)"
    }
}
```

### Transcription

```swift
// From [Float] samples:
let result = try await asrManager.transcribe(samples, source: .system)
let text = result.text

// From file URL (handles format conversion internally):
let result = try await asrManager.transcribe(audioURL, source: .system)
let text = result.text
```

**Model**: Parakeet TDT v3 (0.6B parameters), CoreML-optimized for Apple Neural Engine.

**Language support**: 25 European languages with auto-detection. The `TranscriptionMode.language` field may not be directly usable with FluidAudio's API — check if `AsrManager` accepts a language parameter. If not, language selection in modes only affects the LLM post-processing context, and Parakeet auto-detects the spoken language.

**First launch**: Model download + CoreML compilation may take 1-2 minutes. Cached after that.

**Platform requirement**: iOS 17.0+ on Apple Silicon devices.

---

## Logging

Use `os.Logger` with subsystem `com.dictato.app`. Categories:
- `AppState` — state machine, recording, transcription
- `Permissions` — permission checks
- `LLMService` — API calls

---

## Key Differences from macOS

| Aspect | macOS | iOS |
|--------|-------|-----|
| Transcription engine | WhisperKit (Whisper large-v3-turbo) | FluidAudio (Parakeet TDT v3 CoreML) |
| Audio capture | WhisperKit's `audioProcessor` | `AVAudioEngine` with tap (16kHz mono conversion) |
| Entry point | Menu bar app (LSUIElement) | Standard app with main screen |
| Recording trigger | Global keyboard shortcut (Option+Space) | Tap record button |
| During recording | Floating panel overlay (non-activating) | Main screen changes state |
| Actions during recording | Keyboard shortcuts (Esc=pause, Enter=discard, 1-9=mode) | On-screen buttons |
| After transcription | Auto-paste via Cmd+V CGEvent + play "Funk" sound | Show result sheet with Copy button |
| Error: save recording | NSSavePanel (file save dialog) | UIActivityViewController (share sheet) |
| File import | NSOpenPanel from menu bar | UIDocumentPicker / .fileImporter from toolbar |
| History | Separate window (`openWindow`) | Navigation push |
| Settings | SwiftUI Settings scene | Navigation push |
| Audio export from history | NSSavePanel | UIActivityViewController |
| Accessibility permission | Required (for Cmd+V paste) | Not needed |
| Dock icon | Hidden (LSUIElement=YES) | Standard app icon |
| Panel position/snap | Draggable floating panel with snap-to-center | N/A |

---

## Navigation Structure

```
TabView or NavigationStack:

Main Screen (Home)
├── [Model loading state]
├── [Ready state] → Record button, mode selector
├── [Recording state] → Pause / Stop buttons
├── [Paused state] → Resume / Discard buttons
├── [Transcribing state] → Cancel button
├── [Post-processing state] → Cancel button
├── [Error state] → Dismiss / Save Recording buttons
├── [Result sheet] → Copy / Done buttons
│
├── → History Screen (navigation push)
│     └── Each row: text preview, timestamp, mode pill/re-transcribe, tabs, save audio, copy
│
├── → Settings Screen (navigation push)
│     ├── API Keys section
│     └── Modes section (name, language, provider, model, prompt per mode)
│
└── → File Import (document picker → mode selection → transcribe → navigate to history)
```

---

## Visual Style Guidelines

- **Status dot colors**: Red (recording), Yellow (paused), Orange (transcribing), Blue (post-processing), Red (error)
- **Recording dot animation**: Pulsing scale 1.0 to 1.3, 0.8s ease-in-out, repeating with autoreversal
- **Mode pills**: Capsule shape, caption font, selected = filled/highlighted, unselected = secondary
- **History rows**: Card style with subtle background, 12pt corner radius, 16pt padding
- **Tab toggles**: Capsule-grouped buttons, caption font, selected has filled background
- **Fonts**: Title = `.title2.bold()`, body = system default, captions = `.caption`, status text = 16pt semibold
- **Spacing**: 20pt between sections, 12pt between rows, 8pt within components
- Use standard iOS system colors and dynamic type support
