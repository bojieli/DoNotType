import ActivityKit
import Foundation

struct DictationActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case listening
            case transcribing
            case ready

            var label: String {
                switch self {
                case .listening: "Listening"
                case .transcribing: "Transcribing"
                case .ready: "Ready"
                }
            }

            var systemImage: String {
                switch self {
                case .listening: "waveform"
                case .transcribing: "ellipsis"
                case .ready: "mic.fill"
                }
            }
        }

        var phase: Phase
        var detail: String
        var readyUntil: Date?
    }

    var source: String
}
