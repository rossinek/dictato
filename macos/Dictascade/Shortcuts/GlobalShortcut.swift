import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording", default: .init(.space, modifiers: .option))
    static let pasteLastTranscription = Self("pasteLastTranscription", default: .init(.space, modifiers: [.option, .shift]))
}
