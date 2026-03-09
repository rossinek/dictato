import SwiftUI

struct HomeView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            if !appState.isModelLoaded {
                modelLoadingView
            } else {
                buttonRow
                modePills
            }

            Spacer()
        }
        .padding(20)
        .navigationTitle("Dictato")
        .sheet(item: $appState.lastTranscriptionResult) { transcription in
            ResultSheet(transcription: transcription) {
                appState.lastTranscriptionResult = nil
            }
        }
    }

    // MARK: - Subviews

    private var modelLoadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(appState.modelLoadingProgress)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var pillsDisabled: Bool {
        appState.isError || appState.isPostProcessing || appState.isTranscribing
    }

    @Namespace private var pillNamespace
    @Environment(\.colorScheme) private var colorScheme

    private var modePills: some View {
        HStack(spacing: 2) {
            ForEach(Array(appState.modes.enumerated()), id: \.element.id) { index, mode in
                Text(mode.name)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background {
                        if appState.selectedModeIndex == index {
                            Capsule()
                                .fill(colorScheme == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.1))
                                .matchedGeometryEffect(id: "selectedPill", in: pillNamespace)
                        }
                    }
                    .foregroundStyle(appState.selectedModeIndex == index ? .white : .secondary)
                    .onTapGesture {
                        if !pillsDisabled {
                            withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                                appState.selectMode(index: index)
                            }
                        }
                    }
            }
        }
        .padding(4)
        .glassEffect(.regular)
        .opacity(pillsDisabled ? 0.4 : 1.0)
        .animation(.default, value: pillsDisabled)
    }

    // MARK: - Central Button

    @State private var pulsing = false

    private var centralButtonIcon: String {
        if appState.isError { return "xmark" }
        if appState.isPostProcessing { return "sparkles" }
        if appState.isTranscribing { return "waveform" }
        if appState.isPaused { return "play.fill" }
        if appState.isRecording { return "stop.fill" }
        return "mic.fill"
    }

    private var centralButtonColor: Color {
        if appState.isError { return .red }
        if appState.isPostProcessing { return .blue }
        if appState.isTranscribing { return .orange }
        if appState.isPaused { return .yellow }
        return .red
    }

    private var centralButtonEnabled: Bool {
        !appState.isError && !appState.isPostProcessing && !appState.isTranscribing
    }

    private var shouldPulse: Bool {
        appState.isRecording || appState.isPostProcessing
    }

    private var hasLeftSecondary: Bool {
        appState.isRecording || appState.isPaused || appState.isTranscribing || appState.isPostProcessing || appState.isError
    }

    private var hasRightSecondary: Bool {
        appState.isError
    }

    private var leftSecondaryIcon: String {
        if appState.isRecording { return "pause.fill" }
        if appState.isPaused { return "trash" }
        if appState.isTranscribing || appState.isPostProcessing { return "xmark" }
        if appState.isError { return "arrow.counterclockwise" }
        return "circle"
    }

    private var leftSecondaryTint: Color? {
        if appState.isPaused { return .red }
        return nil
    }

    private var buttonRow: some View {
        GlassEffectContainer(spacing: 20) {
            HStack(spacing: 4) {
                // Left secondary — always present, animated via offset+opacity
                smallCircleButton(icon: leftSecondaryIcon, tint: leftSecondaryTint, visible: hasLeftSecondary) {
                    withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
                        if appState.isRecording { appState.togglePause() }
                        else if appState.isPaused { appState.discardRecording() }
                        else if appState.isTranscribing || appState.isPostProcessing { appState.cancelTranscription() }
                        else if appState.isError { appState.dismissError() }
                    }
                }
                .offset(x: hasLeftSecondary ? 0 : 52)
                .allowsHitTesting(hasLeftSecondary)

                // Main button
                Button {
                    withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
                        if appState.isPaused {
                            appState.togglePause()
                        } else if appState.isRecording {
                            appState.stopAndTranscribe()
                        } else {
                            appState.startRecording()
                        }
                    }
                } label: {
                    Image(systemName: centralButtonIcon)
                        .font(.system(size: 32))
                        .foregroundStyle(centralButtonColor)
                        .frame(width: 80, height: 80)
                        .scaleEffect(pulsing ? 1.08 : 1.0)
                        .contentTransition(.symbolEffect(.replace))
                }
                .glassEffect(.clear.tint(centralButtonColor.opacity(0.1)).interactive(), in: .circle)
                .disabled(!centralButtonEnabled)
                .zIndex(1)
                .onChange(of: shouldPulse) { _, newValue in
                    if newValue {
                        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                            pulsing = true
                        }
                    } else {
                        withAnimation(.default) {
                            pulsing = false
                        }
                    }
                }

                // Right secondary — always present, animated via offset+opacity
                smallCircleButton(icon: "square.and.arrow.up", tint: .blue, visible: hasRightSecondary) {
                    withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
                        appState.saveFailedRecording()
                    }
                }
                .offset(x: hasRightSecondary ? 0 : -52)
                .allowsHitTesting(hasRightSecondary)
                .sheet(item: $appState.failedRecordingURL) { url in
                    ShareSheet(activityItems: [url])
                }
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.2), value: hasLeftSecondary)
        .animation(.spring(duration: 0.4, bounce: 0.2), value: hasRightSecondary)
        .animation(.spring(duration: 0.3, bounce: 0.15), value: leftSecondaryIcon)
    }

    private func smallCircleButton(icon: String, tint: Color?, visible: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(tint ?? .primary)
                .opacity(visible ? 1 : 0)
                .frame(width: 48, height: 48)
        }
        .glassEffect(.clear.interactive(), in: .circle)
    }

}

// MARK: - Result Sheet

private struct ResultSheet: View {
    let transcription: Transcription
    let onDismiss: () -> Void
    @State private var selectedTab: Int
    @State private var copied = false

    init(transcription: Transcription, onDismiss: @escaping () -> Void) {
        self.transcription = transcription
        self.onDismiss = onDismiss
        self._selectedTab = State(initialValue: transcription.postProcessedText != nil ? 1 : 0)
    }

    private var displayedText: String {
        if selectedTab == 1, let processed = transcription.postProcessedText {
            return processed
        }
        return transcription.text
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if transcription.postProcessedText != nil {
                    HStack(spacing: 0) {
                        tabButton("Original", tag: 0)
                        tabButton("Post-processed", tag: 1)
                    }
                    .background(Color.secondary.opacity(0.2), in: Capsule())
                }

                ScrollView {
                    Text(displayedText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }

                if let modeName = transcription.modeName {
                    Text(modeName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    UIPasteboard.general.string = displayedText
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied!" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
            }
            .padding()
            .navigationTitle("Transcription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDismiss() }
                }
            }
        }
    }

    private func tabButton(_ label: String, tag: Int) -> some View {
        Text(label)
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(selectedTab == tag ? Color.accentColor : Color.clear, in: Capsule())
            .foregroundStyle(selectedTab == tag ? .white : .secondary)
            .onTapGesture { selectedTab = tag }
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - URL Identifiable

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

// MARK: - Previews

#Preview("Ready") {
    NavigationStack {
        HomeView(appState: .preview())
    }
}

#Preview("Recording") {
    NavigationStack {
        HomeView(appState: .preview(isRecording: true))
    }
}

#Preview("Paused") {
    NavigationStack {
        HomeView(appState: .preview(isPaused: true))
    }
}

#Preview("Transcribing") {
    NavigationStack {
        HomeView(appState: .preview(isTranscribing: true))
    }
}

#Preview("Post-processing") {
    NavigationStack {
        HomeView(appState: .preview(isPostProcessing: true))
    }
}

#Preview("Error") {
    NavigationStack {
        HomeView(appState: .preview(isError: true))
    }
}

#Preview("Loading") {
    NavigationStack {
        HomeView(appState: .preview(isModelLoaded: false))
    }
}
