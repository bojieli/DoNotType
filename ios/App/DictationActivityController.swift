import ActivityKit
import Foundation

/// A truthful system surface for a keyboard-owned dictation.
///
/// A Live Activity does not keep the app alive. Background audio owns the warm microphone session;
/// this mirrors that session on the Lock Screen and Dynamic Island so it is never invisible.
@MainActor
final class DictationActivityController {
    private var activity: Activity<DictationActivityAttributes>?

    init() {
        activity = Activity<DictationActivityAttributes>.activities.first
    }

    func showListening() {
        present(.init(phase: .listening, detail: "Tap Stop in the DoNotType keyboard", readyUntil: nil))
    }

    func showTranscribing() {
        present(.init(phase: .transcribing, detail: "Preparing text for insertion", readyUntil: nil))
    }

    func showReady(until: Date?) {
        let detail = until == nil ? "Microphone ready until DoNotType closes" : "Keyboard microphone is ready"
        present(.init(phase: .ready, detail: detail, readyUntil: until))
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        let final = DictationActivityAttributes.ContentState(
            phase: .ready, detail: "Keyboard microphone closed", readyUntil: Date())
        Task {
            await activity.end(
                ActivityContent(state: final, staleDate: Date()),
                dismissalPolicy: .immediate)
        }
    }

    private func present(_ state: DictationActivityAttributes.ContentState) {
        let staleDate = state.phase == .ready ? state.readyUntil : nil
        let content = ActivityContent(state: state, staleDate: staleDate)
        if let activity {
            Task { await activity.update(content) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: DictationActivityAttributes(source: "keyboard"),
                content: content,
                pushType: nil)
        } catch {
            // Dictation itself must never depend on a status surface the user can disable.
        }
    }
}
