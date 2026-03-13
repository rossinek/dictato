import SwiftUI

// MARK: - Center-Snapping Scroll

private struct PillFramesKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

private struct CenterSnappingBehavior: ScrollTargetBehavior {
    let pillFrames: [CGRect]

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let proposedCenter = target.rect.midX
        guard let nearest = pillFrames.min(by: {
            abs($0.midX - proposedCenter) < abs($1.midX - proposedCenter)
        }) else { return }
        target.rect.origin.x = nearest.midX - context.containerSize.width / 2
        target.rect.size.width = context.containerSize.width
        target.anchor = .leading
    }
}

struct HomeView: View {
    @ObservedObject var appState: AppState
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isLandscape: Bool {
        verticalSizeClass == .compact
    }

    var body: some View {
        VStack(spacing: 4) {
            VStack(spacing: 2) {
                DictascadeIcon()
                    .frame(width: 36, height: 36)
                    .foregroundStyle(.primary.opacity(0.4))
              VStack {
                Text("dicta")
                  .font(.system(size: 22, weight: .semibold, design: .monospaced))
                  .tracking(4)
                  .textCase(.lowercase)
                  .padding(.trailing, 16)

                Text("scade")
                  .font(.system(size: 22, weight: .semibold, design: .monospaced))
                  .tracking(4)
                  .textCase(.lowercase)
                  .padding(.leading, 18)
              }
            }
            .padding(.top, 20)

            Spacer()

            if !appState.isModelLoaded {
                modelLoadingView
            } else if isLandscape {
                HStack(spacing: 0) {
                    AudioVisualizerView(levels: appState.audioLevels)
                        .opacity(appState.isRecording ? 1 : 0)
                        .animation(.easeInOut(duration: 0.3), value: appState.isRecording)
                        .frame(maxWidth: .infinity)
                    VStack {
                        buttonRow
                        modePills
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                AudioVisualizerView(levels: appState.audioLevels)
                    .frame(height: 100)
                    .padding(.vertical, 32)
                    .opacity(appState.isRecording ? 1 : 0)
                    .animation(.easeInOut(duration: 0.3), value: appState.isRecording)
                buttonRow
                modePills
            }

            Spacer()
        }
        .padding(20)
        .navigationBarHidden(true)
        .onChange(of: appState.isModelLoaded) { _, loaded in
            if loaded, appState.pendingDeepLink != nil {
                handleDeepLink()
            }
        }
        .onChange(of: appState.pendingDeepLink) { _, link in
            if link != nil, appState.isModelLoaded {
                handleDeepLink()
            }
        }
        .sheet(item: $appState.lastTranscriptionResult) { transcription in
            ResultSheet(transcription: transcription) {
                appState.lastTranscriptionResult = nil
            }
        }
    }

    // MARK: - Subviews

    private func handleDeepLink() {
        guard case .record(let modeName) = appState.pendingDeepLink else { return }
        appState.pendingDeepLink = nil
        if let modeName {
            let normalize = { (s: String) -> String in
                s.lowercased()
                    .replacingOccurrences(of: "+", with: " ")
                    .replacingOccurrences(of: "-", with: " ")
                    .replacingOccurrences(of: "_", with: " ")
            }
            let param = normalize(modeName)
            if let index = appState.modes.firstIndex(where: { normalize($0.name) == param }) {
                appState.selectMode(index: index)
            }
        }
        appState.startRecording()
    }

    @State private var ringRotation: Double = 0

    private var modelLoadingView: some View {
        GlassEffectContainer {
            VStack(spacing: 20) {
                loadingRing
                loadingLabel
            }
        }
    }

    private var loadingRing: some View {
        ZStack {
            // Track ring
            Circle()
                .stroke(.primary.opacity(0.08), lineWidth: 3)

            // Progress or spinning ring
            if isIndeterminate {
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(
                        phaseColor.opacity(0.6),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(ringRotation))
                    .onAppear {
                        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                            ringRotation = 360
                        }
                    }
            } else {
                Circle()
                    .trim(from: 0, to: appState.modelLoadingFraction)
                    .stroke(
                        phaseColor,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: appState.modelLoadingFraction)
            }

            // Center icon
            if case .downloading = appState.modelLoadingPhase {
                LoopingArrowIcon(color: phaseColor)
            } else {
                Image(systemName: phaseIcon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(phaseColor)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.smooth, value: phaseIcon)
            }
        }
        .frame(width: 80, height: 80)
        .clipShape(.circle)
        .glassEffect(.clear.tint(phaseColor.opacity(0.08)), in: .circle)
    }

    private var loadingLabel: some View {
        HStack(spacing: 6) {
            Text(appState.modelLoadingProgress)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            if !isIndeterminate {
                Text("\(Int(appState.modelLoadingFraction * 100))%")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.5))
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(.regular)
        .animation(.default, value: appState.modelLoadingProgress)
    }

    private var phaseColor: Color {
        switch appState.modelLoadingPhase {
        case .idle, .listing: return .secondary
        case .downloading: return .blue
        case .compiling: return .orange
        case .loading: return .green
        case .initializing: return .purple
        case .ready: return .green
        case .failed: return .red
        }
    }

    private var phaseIcon: String {
        switch appState.modelLoadingPhase {
        case .idle, .listing: return "sparkle"
        case .downloading: return "arrow.down"
        case .compiling: return "cpu"
        case .loading: return "memorychip"
        case .initializing: return "bolt"
        case .ready: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var isIndeterminate: Bool {
        switch appState.modelLoadingPhase {
        case .idle, .listing: return true
        default: return false
        }
    }

    private var pillsDisabled: Bool {
        appState.isError || appState.isPostProcessing || appState.isTranscribing
    }

    @State private var scrolledModeID: TranscriptionMode.ID?
    @State private var pillFrames: [CGRect] = []
    @Namespace private var pillNamespace

    private var modePills: some View {
        GeometryReader { geo in
            let sideSpace = geo.size.width / 2
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: sideSpace)
                    GlassEffectContainer {
                        HStack(spacing: 8) {
                            ForEach(Array(appState.modes.enumerated()), id: \.element.id) { index, mode in
                                Text(mode.name)
                                    .font(.caption)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .foregroundStyle(appState.selectedModeIndex == index ? .primary : .secondary)
                                    .glassEffect(appState.selectedModeIndex == index ? .clear : .identity, in: .capsule)
                                    .glassEffectID("modePillGlass", in: pillNamespace)
                                    .glassEffectTransition(.matchedGeometry)
                                    .background {
                                        GeometryReader { pillGeo in
                                            Color.clear.preference(
                                                key: PillFramesKey.self,
                                                value: [pillGeo.frame(in: .named("pillScroll"))]
                                            )
                                        }
                                    }
                                    .onTapGesture {
                                        if !pillsDisabled {
                                            withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                                                appState.selectMode(index: index)
                                                scrolledModeID = mode.id
                                            }
                                        }
                                    }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .scrollTargetLayout()
                    Color.clear.frame(width: sideSpace)
                }
                .coordinateSpace(name: "pillScroll")
            }
            .scrollTargetBehavior(CenterSnappingBehavior(pillFrames: pillFrames))
            .scrollPosition(id: $scrolledModeID, anchor: .center)
            .onPreferenceChange(PillFramesKey.self) { pillFrames = $0 }
        }
        .frame(height: 46)
        .mask(
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 70)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 70)
            }
        )
        .onAppear {
            if appState.modes.indices.contains(appState.selectedModeIndex) {
                scrolledModeID = appState.modes[appState.selectedModeIndex].id
            }
        }
        .onChange(of: scrolledModeID) { _, newID in
            if let newID, let index = appState.modes.firstIndex(where: { $0.id == newID }) {
                if !pillsDisabled {
                    appState.selectMode(index: index)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
        }
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

struct ResultSheet: View {
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
                        .font(.body.weight(.medium))
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .glassEffect(.regular.tint(.blue.opacity(0.15)).interactive())
                .padding(.horizontal)
                .padding(.bottom, 8)
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

// MARK: - Dictascade Icon

private struct DictascadeIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 20
        let sy = rect.height / 20
        var p = Path()
        // From SVG: M1 3.5a.5.5 0 0 1 .5-.5H7a2 2 0 0 1 2 2v4.5h6c1.035 0 2 .741 2 1.8V16h1.5a.5.5 0 0 1 0 1H13c-1.035 0-2-.741-2-1.8v-4.7H5a2 2 0 0 1-2-2V4H1.5a.5.5 0 0 1-.5-.5
        p.move(to: CGPoint(x: 1 * sx, y: 3.5 * sy))
        // top-left arc (.5x.5 rounded corner) → to (1.5, 3)
        p.addQuadCurve(to: CGPoint(x: 1.5 * sx, y: 3 * sy), control: CGPoint(x: 1 * sx, y: 3 * sy))
        p.addLine(to: CGPoint(x: 7 * sx, y: 3 * sy))
        // arc to (9, 5) — 2x2 rounded corner
        p.addQuadCurve(to: CGPoint(x: 9 * sx, y: 5 * sy), control: CGPoint(x: 9 * sx, y: 3 * sy))
        p.addLine(to: CGPoint(x: 9 * sx, y: 9.5 * sy))
        p.addLine(to: CGPoint(x: 15 * sx, y: 9.5 * sy))
        // arc to (17, 11.3) — curve
        p.addQuadCurve(to: CGPoint(x: 17 * sx, y: 11.3 * sy), control: CGPoint(x: 17 * sx, y: 9.5 * sy))
        p.addLine(to: CGPoint(x: 17 * sx, y: 16 * sy))
        p.addLine(to: CGPoint(x: 18.5 * sx, y: 16 * sy))
        // arc .5x.5 → to (19, 16.5)
        p.addQuadCurve(to: CGPoint(x: 19 * sx, y: 16.5 * sy), control: CGPoint(x: 19 * sx, y: 16 * sy))
        // arc .5x.5 → to (18.5, 17)
        p.addQuadCurve(to: CGPoint(x: 18.5 * sx, y: 17 * sy), control: CGPoint(x: 19 * sx, y: 17 * sy))
        p.addLine(to: CGPoint(x: 13 * sx, y: 17 * sy))
        // arc to (11, 15.2) — curve
        p.addQuadCurve(to: CGPoint(x: 11 * sx, y: 15.2 * sy), control: CGPoint(x: 11 * sx, y: 17 * sy))
        p.addLine(to: CGPoint(x: 11 * sx, y: 10.5 * sy))
        p.addLine(to: CGPoint(x: 5 * sx, y: 10.5 * sy))
        // arc to (3, 8.5) — 2x2 rounded corner
        p.addQuadCurve(to: CGPoint(x: 3 * sx, y: 8.5 * sy), control: CGPoint(x: 3 * sx, y: 10.5 * sy))
        p.addLine(to: CGPoint(x: 3 * sx, y: 4 * sy))
        p.addLine(to: CGPoint(x: 1.5 * sx, y: 4 * sy))
        // arc .5x.5 → to (1, 3.5)
        p.addQuadCurve(to: CGPoint(x: 1 * sx, y: 3.5 * sy), control: CGPoint(x: 1 * sx, y: 4 * sy))
        p.closeSubpath()
        return p
    }
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

#Preview("Downloading") {
    NavigationStack {
        HomeView(appState: .preview(
            isModelLoaded: false,
            loadingPhase: .downloading(completedFiles: 14, totalFiles: 23),
            loadingFraction: 0.24,
            loadingProgress: "Downloading 14 of 23 files..."
        ))
    }
}

#Preview("Compiling") {
    NavigationStack {
        HomeView(appState: .preview(
            isModelLoaded: false,
            loadingPhase: .compiling(modelName: "Encoder.mlmodelc"),
            loadingFraction: 0.42,
            loadingProgress: "Compiling Encoder..."
        ))
    }
}

#Preview("Loading Model") {
    NavigationStack {
        HomeView(appState: .preview(
            isModelLoaded: false,
            loadingPhase: .loading(modelName: "Encoder.mlmodelc"),
            loadingFraction: 0.82,
            loadingProgress: "Loading Encoder..."
        ))
    }
}

#Preview("Booting") {
    NavigationStack {
        HomeView(appState: .preview(
            isModelLoaded: false,
            loadingPhase: .initializing,
            loadingFraction: 0.95,
            loadingProgress: "Booting ASR engine..."
        ))
    }
}

// MARK: - Looping Arrow Animation

private struct LoopingArrowIcon: View {
    let color: Color

    var body: some View {
        KeyframeAnimator(initialValue: AnimationValues(), repeating: true) { values in
            Image(systemName: "arrow.down")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(color)
                .offset(y: values.y)
                .opacity(values.opacity)
        } keyframes: { _ in
            KeyframeTrack(\.y) {
                CubicKeyframe(0, duration: 0.4)        // ease in to center
                LinearKeyframe(0, duration: 0.5)        // hold at center
                LinearKeyframe(70, duration: 0.5)       // ease out downward
                LinearKeyframe(-70, duration: 0.01)     // snap back to top
            }
            KeyframeTrack(\.opacity) {
                LinearKeyframe(1, duration: 0.9)        // visible through hold
                CubicKeyframe(0, duration: 0.2)         // fade out at bottom
                LinearKeyframe(0, duration: 0.31)       // stay hidden during snap
                CubicKeyframe(1, duration: 0.2)         // fade in at top
            }
        }
    }

    private struct AnimationValues {
        var y: CGFloat = -70
        var opacity: Double = 0
    }
}
