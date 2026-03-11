import ActivityKit
import Foundation

struct RecordingAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var isTranscribing: Bool
    }

    var modeName: String
    var startTime: Date
}
