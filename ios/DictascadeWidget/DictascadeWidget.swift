import SwiftUI
import WidgetKit

@main
struct DictascadeWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingAttributes.self) { context in
            // Lock Screen / banner view
            HStack(spacing: 12) {
                Image(systemName: context.state.isTranscribing ? "waveform" : "mic.fill")
                    .font(.title2)
                    .foregroundStyle(context.state.isTranscribing ? .orange : .red)
                    .symbolEffect(.pulse, isActive: true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.isTranscribing ? "Transcribing..." : "Recording")
                        .font(.headline)
                    HStack(spacing: 4) {
                        Text(context.attributes.modeName)
                        if !context.state.isTranscribing {
                            Text("\u{2022}")
                            Text(context.attributes.startTime, style: .timer)
                                .monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if !context.state.isTranscribing {
                    Link(destination: URL(string: "dictascade://stop")!) {
                        Image(systemName: "stop.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.white, .red)
                    }
                }
            }
            .padding()

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isTranscribing ? "waveform" : "mic.fill")
                        .foregroundStyle(context.state.isTranscribing ? .orange : .red)
                        .symbolEffect(.pulse, isActive: true)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.isTranscribing ? "Transcribing..." : "Recording")
                            .font(.headline)
                        Text(context.attributes.modeName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !context.state.isTranscribing {
                        Link(destination: URL(string: "dictascade://stop")!) {
                            Image(systemName: "stop.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.white, .red)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.isTranscribing ? "waveform" : "mic.fill")
                    .foregroundStyle(context.state.isTranscribing ? .orange : .red)
                    .symbolEffect(.pulse, isActive: true)
            } compactTrailing: {
                Text(context.attributes.startTime, style: .timer)
                    .monospacedDigit()
                    .font(.caption)
            } minimal: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
            }
        }
    }
}
