import AppKit
import SwiftUI

/// The floating pill at the bottom of the screen while recording.
///
/// A borderless, non-activating panel: it must never steal focus, because the whole point is that
/// the user keeps typing into whatever app they were already in. `.statusBar` level puts it above
/// full-screen apps, and `canJoinAllSpaces` keeps it visible when they switch desktops mid-thought.
@MainActor
final class RecordingOverlay {
    private var panel: NSPanel?
    private var dismissWork: Task<Void, Never>?
    private let state = OverlayState()

    /// Live microphone level, 0...1, driving the waveform.
    func update(level: Float) {
        state.level = Double(max(0, min(1, level * 6)))  // speech sits low in the range
    }

    func update(phase: OverlayState.Phase) {
        state.phase = phase
    }

    func show(phase: OverlayState.Phase, hint: String) {
        dismissWork?.cancel()
        state.phase = phase
        state.hint = hint

        if panel == nil { panel = makePanel() }
        position(panel)
        panel?.orderFrontRegardless()
        // Animated inside SwiftUI rather than on the window: animating an NSPanel's alpha while
        // it is being ordered in produces a visible flash on the first frame.
        withAnimation(.spring(duration: 0.28, bounce: 0.22)) { state.isPresented = true }
    }

    /// Flashes a confirmation, then dismisses itself.
    func confirmInserted(characters: Int) {
        update(phase: .inserted(characters))
        hide(after: .milliseconds(900))
    }

    func hide(after delay: Duration = .zero) {
        dismissWork?.cancel()
        let work = Task { @MainActor in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }

            withAnimation(.easeIn(duration: 0.18)) { state.isPresented = false }
            // Ordering the panel out before the animation finishes would cut it off mid-fade.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            panel?.orderOut(nil)
        }
        dismissWork = work
    }

    // MARK: - Private

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Without this the panel takes key focus and the user's caret goes away.
        panel.hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: OverlayView(state: state))
        hosting.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = hosting
        return panel
    }

    /// Bottom-centre of whichever screen has the mouse, so it follows a multi-display setup.
    private func position(_ panel: NSPanel?) {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.minY + 64))
    }
}

@MainActor
@Observable
final class OverlayState {
    enum Phase: Equatable {
        case recording
        case transcribing
        /// A long dictation split across several requests. Shown only when there is more than one,
        /// because "1 of 1" is noise — but a nine-minute recording that sits on "Transcribing…"
        /// for half a minute looks hung, and this is what distinguishes slow from stuck.
        case transcribingChunk(done: Int, of: Int)
        /// Brief confirmation that words were inserted, so success is visible rather than a
        /// silent disappearance the user has to infer from the text appearing.
        case inserted(Int)
        case failed(String)
    }

    var phase: Phase = .recording
    var level: Double = 0
    var hint: String = ""
    /// Drives the appear/disappear transition.
    var isPresented = false
}

private struct OverlayView: View {
    @Bindable var state: OverlayState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            // A pill that scales and fades in reads as "this appeared for you"; one that pops
            // reads as a glitch. Respecting reduce-motion is not optional for something that
            // shows up unannounced in the corner of the screen.
            .opacity(state.isPresented ? 1 : 0)
            .scaleEffect(reduceMotion ? 1 : (state.isPresented ? 1 : 0.88))
            .offset(y: reduceMotion ? 0 : (state.isPresented ? 0 : 12))
    }

    private var content: some View {
        HStack(spacing: 12) {
            switch state.phase {
            case .recording:
                Waveform(level: state.level)
                    .frame(width: 76, height: 22)
                Text(state.hint)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text("Transcribing…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            case .transcribingChunk(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(width: 76)
                Text("Transcribing… part \(min(done + 1, total)) of \(total)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .monospacedDigit()
            case .inserted(let characters):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
                Text("Inserted \(characters) character\(characters == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .frame(maxWidth: 320, alignment: .leading)
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 44)
        .animation(.easeInOut(duration: 0.2), value: state.phase)
        .background(
            Capsule().fill(Color.black.opacity(0.82))
        )
        .overlay(
            Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Level-driven bars. Deliberately not a real spectrum — this is a liveness indicator, and what
/// people need from it is "the mic is hearing me", which amplitude answers.
private struct Waveform: View {
    let level: Double

    private static let bars = 5
    /// Fixed per-bar weights, so the shape reads as a waveform rather than a row of equal blocks
    /// while staying perfectly steady when the room is silent.
    private static let weights: [Double] = [0.45, 0.75, 1.0, 0.7, 0.5]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<Self.bars, id: \.self) { index in
                    Capsule()
                        .fill(.white.opacity(0.9))
                        .frame(width: 4, height: height(index: index, phase: phase))
                }
            }
            .animation(.easeOut(duration: 0.06), value: level)
        }
    }

    private func height(index: Int, phase: Double) -> Double {
        // A slow travelling wave keeps it alive during pauses without implying signal.
        let travel = sin(phase * 4 + Double(index) * 0.9) * 0.5 + 0.5
        let amplitude = max(0.12, level) * Self.weights[index]
        return 4 + 18 * min(1, amplitude * (0.65 + 0.35 * travel))
    }
}
