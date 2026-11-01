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
