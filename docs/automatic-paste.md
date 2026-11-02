# Automatic paste: modifier-state regression

## Incident and cause (2026-11-01)

In v1.5.0, the first dictation pasted, but the next could be copied without being
pasted unless the user pressed an ordinary key (for example Space) between them.
PasteService logged `Paste deferred: shortcut modifiers remained pressed; copying text only`.

The synthetic Cmd+V sequence attached Command to both the V key-down and V key-up.
After posting at the HID event tap, Quartz retained Command in both HID and combined
session flags. Even `CGEventSource.keyState` reported Command down. The next paste
therefore waited two seconds for a modifier that the user was not physically holding
and fell back to copying only. A plain key event cleared the synthetic modifier state.

## Required invariants

- Build shortcut events through `PasteShortcutEvents.make`: shortcut modifiers belong
  on key-down; the final key-up has empty flags. This also applies to per-app shortcuts.
- Always post key-up after key-down, including task cancellation during the 20 ms gap.
- Keep the physical-modifier checks before posting. Do not reset global keyboard state
  as a workaround or release a user's held modifier independently of a paste sequence.
- Checking individual key states instead of flags alone does NOT fix this regression:
  both were contaminated by synthetic events in the reproduction.
- Clipboard reads are not paste acknowledgements. Use concrete text and the existing
  three-second restore grace period; restore only while the transaction owns the clipboard.
- Do not blindly retry Cmd+V: it can duplicate text.

## Automated regression checks

`PasteboardTests` covers constructed shortcut events (including custom modifier
combinations), premature restoration after clipboard reads, subsequent user copies,
clipboard ownership, multiple items/types, and an initially empty clipboard.
The event tests inspect events without posting keystrokes into the user's desktop.

```sh
cd macos
xcodegen generate
xcodebuild -project Dictascade.xcodeproj -scheme PasteboardTests \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

## End-to-end verification

Before modifying this sequence again, test in an isolated ordinary text editor with
real Cmd+V, the general pasteboard, and clipboard restoration enabled. Preserve all
original clipboard items/types; never log their contents. Stop if the test window
loses focus. Do not type extra keys between the two paste requests.

1. Paste A, wait beyond the three-second restoration, then paste B.
2. Paste A, request B after 0.6 seconds (before restoration).
3. Paste A, copy new text while restoration is pending, then paste B.
4. Verify A and B each appear exactly once, the intended clipboard contents survive,
   and the final modifier flags are clear. Also verify a genuinely held shortcut
   modifier still prevents a conflicting automatic paste.
5. Repeat consecutive dictations in actual destination apps after installation.

The isolated reproduction on 2026-11-01 used copies of the production PasteService,
PasteboardTransaction and real NSTextView paste handling. Only `keyUp.flags` differed
between variants. Both slow and fast pairs failed with the original sequence and
passed with empty key-up flags. The intervening-copy case also passed. All 31 checks
passed (including expected reproduction failures and byte-for-byte restoration of
all saved user clipboard representations). This does not replace manual checks of
physical keyboard interaction or app-specific paste shortcuts.

# Automatic paste: Chromium 155–156 drop synthetic pastes (2026-11-02)

## Symptom and cause

In Helium 0.20.2.1 (Chromium 156.0.8078.73) automatic paste and "Use Last Transcription"
inserted nothing, while a manual Cmd+V afterwards worked. PasteService logged a normal
`Sent paste shortcut`; nothing in Dictascade failed.

Chromium CL 8217390 (155) cancels a paste's default insertion when the clipboard sequence
token changes during the paste. On macOS the token for a new pasteboard `changeCount` is
minted twice (`ClipboardMac::ClipboardChanged()` arrives as a posted task), so the
**first paste after another application writes the pasteboard is dropped**: the page
receives a `paste` event with the correct text, `beforeinput` has empty data, nothing is
inserted. A second paste of the same contents works, which is why the manual Cmd+V
succeeded and why "Use Last Transcription" (which writes the clipboard again) failed too.
Fixed upstream by CL 8503629 ("Keep same clipboard sequence token for same changeCount"),
shipping in Chromium 157. Public reports: anomalyco/hex#136, #212, PR #289;
Beingpax/VoiceInk#1000; LuisUrrutia/VoiceInk PR #41.

## Measurements in Helium (scripts/paste-harness)

| Method | Result |
|---|---|
| Production sequence (clipboard, 75 ms, Cmd+V) | 0/21 |
| Wait 1 s / 3 s after writing the clipboard | 0/4, 1/4 |
| Real-keyboard chord (Cmd down, V, V up, Cmd up) | 1/4 |
| Edit > Paste via Accessibility `AXPress` | 0/4 |
| Make the app validate its Paste menu item first | ~50% |
| Two Cmd+V in a row (diagnostic only) | first always dropped, second inserted |
| Unicode keyboard events (`KeyboardTyper`) | 20/20, plus 8/8 with Shift+Return line breaks in a chat-like field |

Clipboard paste passed 8/8 (short, ~400, ~3300 characters, multi-line with emoji) in
Chrome 156.0.8078.74, Safari, TextEdit, Terminal, iTerm and VS Code. Typing is **not**
a universal replacement: Safari reordered fast chunks (2/8 correct), TextEdit turned
straight quotes into smart quotes, and a typed Return executes terminal commands.

## Current behaviour

- `PasteService` chooses a strategy before touching the clipboard: the application's
  insertion method from Settings (Automatic / Paste / Type), otherwise **type** when
  `ChromiumEngineDetector` finds a Chromium 155–156 engine in the frontmost app bundle
  (`Contents/Frameworks/*.framework/Versions/<a.b.c.d>`, any version present), otherwise
  the unchanged clipboard paste. The workaround disables itself once a browser ships 157.
- `KeyboardTyper` sends ≤20 UTF-16 units per event without splitting grapheme clusters,
  line breaks as Shift+Return (modifier on key-down only, as with paste shortcuts), stops
  when focus moves or a modifier is held, and then copies the full text to the clipboard.
  Typing does not use the clipboard; the previous paste's pending restore is applied first.
- Do not add delays, Accessibility menu presses, or double pastes as a fix: they were
  measured above, and a double paste duplicates text wherever the first paste succeeds.

## Harness

`scripts/paste-harness` injects text into the frontmost app outside Dictascade and
verifies the result. It aborts when focus leaves the target; do not use the keyboard or
mouse while it runs. Generated files go to `$TMPDIR/paste-harness`.

```sh
cd scripts/paste-harness
python3 -I server.py 8765 &                              # page with a chat-like textarea
open -na Helium --args --new-window http://127.0.0.1:8765/
python3 -I driver.py helium cmdv,type short,medium,long,multi 2 3
```

Methods: `cmdv` (production replica), `cmdv:<ms>`, `chord`, `menu`, `prime[:<ms>]`,
`double`, `type`. Targets: helium (8765), chrome (8766), safari (8767), textedit,
terminal / iterm (run `reader.py <$TMPDIR/paste-harness/out/<target>.raw>` in a new
window), vscode (folder `$TMPDIR/paste-harness/vsc` with `files.autoSave` 100 ms).
End-to-end in the app: trigger "Use Last Transcription" in the test page and check the
`PasteService` log for `Typing transcription:` or `Sent paste shortcut`.
