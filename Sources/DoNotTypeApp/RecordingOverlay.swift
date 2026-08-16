import AppKit
import DoNotTypeCore
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

    /// Adds however many bars the microphone has produced since the last redraw.
    func append(levels: [AudioLevelMeter.Bar]) {
        state.append(levels)
    }

    func update(phase: OverlayState.Phase) {
        state.phase = phase
    }

    func show(phase: OverlayState.Phase, hint: String) {
        dismissWork?.cancel()
        state.phase = phase
        state.hint = hint
        state.clearLevels()

        if panel == nil { panel = makePanel() }
        position(panel)
        panel?.orderFrontRegardless()
        // Animated inside SwiftUI rather than on the window: animating an NSPanel's alpha while
        // it is being ordered in produces a visible flash on the first frame.
        withAnimation(.spring(duration: 0.28, bounce: 0.22)) { state.isPresented = true }
    }

    /// Flashes a confirmation, then dismisses itself.
    ///
    /// - Parameter rewriteFailed: the words landed but the rewrite that was asked for did not
    ///   happen. Worth saying: somebody who held the rewrite key and got their own words back
    ///   would otherwise have to notice, and the usual cause is a backend that cannot rewrite at
    ///   all rather than anything they did.
    func confirmInserted(characters: Int, rewriteFailed: Bool = false) {
        update(phase: .inserted(characters, rewriteFailed: rewriteFailed))
        hide(after: rewriteFailed ? .seconds(3) : .milliseconds(900))
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
        // Wider than any pill it will hold, rather than the size of one.
        //
        // A window clips its content to its own frame, and the pill sizes itself to whatever it is
        // currently saying — which at 220 points was routinely more than it had room for. SwiftUI
        // does not overflow: it wraps, and then it truncates. So the effect was invisible in the
        // code and plain on screen. "Release or tap to send" broke onto two lines, and a failure
        // message reached the two-line limit and ended in an ellipsis, which is the one thing this
        // project does not do to an error — that text is what somebody copies to find out what
        // went wrong.
        //
        // Transparent and mouse-ignoring, so the room it does not draw in costs nothing, and the
        // pill goes on centring itself inside it.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 64),
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
        /// The second request, which is a different thing being waited on and often the slower of
        /// the two. This said "Transcribing…" while a model rewrote a transcript that was already
        /// finished — so the one phase where the wait is the *model's* thinking was the one phase
        /// that did not say so.
        case deriving(RewriteStyle)
        /// Brief confirmation that words were inserted, so success is visible rather than a
        /// silent disappearance the user has to infer from the text appearing.
        case inserted(Int, rewriteFailed: Bool)
        case failed(String)
    }

    /// How much of the recording the meter shows: 24 bars of 60 ms, so a second and a half.
    ///
    /// Long enough that the sentence you are in the middle of saying is on screen, short enough
    /// that the bars stay wide enough to read.
    static let visibleBars = 24

    var phase: Phase = .recording
    var hint: String = ""
    /// The visible history, oldest first. Always full: the meter starts flat rather than growing
    /// in from the left, because an empty meter and a silent one should not look different.
    private(set) var levels = [AudioLevelMeter.Bar](repeating: .silent, count: visibleBars)
    /// Drives the appear/disappear transition.
    var isPresented = false

    func append(_ bars: [AudioLevelMeter.Bar]) {
        guard !bars.isEmpty else { return }
        levels = Array((levels + bars).suffix(Self.visibleBars))
    }

    func clearLevels() {
        levels = [AudioLevelMeter.Bar](repeating: .silent, count: Self.visibleBars)
    }
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
                LevelMeter(bars: state.levels)
                    .frame(width: LevelMeter.width, height: 22)
                Text(state.hint)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            case .transcribing:
                ThinkingDots()
                Text("Transcribing…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            case .transcribingChunk(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(width: LevelMeter.width)
                    // A determinate bar here, not the dots: with several parts in flight there is
                    // real progress to report, and reporting it beats implying it.
                Text("Transcribing… part \(min(done + 1, total)) of \(total)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .monospacedDigit()
            case .deriving(let style):
                ThinkingDots()
                Text(TranscriptMode.rewrite(style).progressLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            case .inserted(let characters, let rewriteFailed):
                Image(systemName: rewriteFailed
                    ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(rewriteFailed ? .orange : .green)
                    .transition(.scale.combined(with: .opacity))
                Text(
                    "Inserted \(characters) character\(characters == 1 ? "" : "s")"
                        + (rewriteFailed ? " — not rewritten" : ""))
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

/// The last second and a half of the microphone, walking leftwards.
///
/// What replaced it is worth saying, because it looked like this one. The old meter was five bars
/// driven by a single current level, animated by a travelling sine so that they kept moving during
/// pauses. Two things were wrong with that. The level it drew was `min(1, rms * 6)`, which spent
/// most of a normally-recorded voice pinned at full height — see `AudioLevelMeter` for the
/// measurement — so it could report that sound was arriving but never how much. And the movement
/// was invented: the bars swayed identically whether the mic was hearing a sentence or nothing at
/// all, which is the one question somebody looks at a level meter to answer.
///
/// Here every bar is 60 ms of audio that actually happened, and the meter moves because the audio
/// does. Silence is a flat line still scrolling: the mic is live and hearing nothing. That reads as
/// a report rather than as decoration, and it is why this stays animated under Reduce Motion when
/// the transcribing dots do not — the motion is the measurement.
private struct LevelMeter: View {
    let bars: [AudioLevelMeter.Bar]

    private static let barWidth = 3.0
    private static let spacing = 2.0
    /// Sized from the bar count so the pill's width does not depend on two numbers agreeing.
    static var width: Double {
        Double(OverlayState.visibleBars) * barWidth
            + Double(OverlayState.visibleBars - 1) * spacing
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: Self.spacing) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                    Capsule()
                        // Amber is not decoration: the input is loud enough to be clipped on the
                        // way in, and a recording distorted before it is sent is worth one colour.
                        .fill(bar.isClipping ? Color.orange : .white.opacity(0.9))
                        .frame(width: Self.barWidth, height: height(bar, in: geometry.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // One bar's worth, so the uneven arrival of buffers does not show up as a stutter.
            // Longer than this and the waveform smears into a blur that flatters the signal.
            .animation(.linear(duration: 0.05), value: bars)
        }
    }

    /// Silence is a row of dots rather than nothing at all: a meter that disappears when the room
    /// is quiet cannot be told apart from one that has stopped.
    private func height(_ bar: AudioLevelMeter.Bar, in available: Double) -> Double {
        max(Self.barWidth, available * bar.level)
    }
}

/// The "still working" animation, shown once speech has stopped.
///
/// Deliberately unlike the recording waveform, which is driven by the microphone. After the user
/// stops talking there is no input left to reflect, so a level-driven animation would be
/// decoration pretending to be a signal. What this has to convey is only "not hung" — the failure
/// it prevents is someone deciding nothing happened and pressing the key again mid-request.
///
/// Occupies the same width as the waveform so the pill does not resize between phases; a capsule
/// that jumps as it changes state reads as a glitch.
private struct ThinkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    // Each dot lags the one before it, so the group reads as motion in one
                    // direction rather than three things blinking independently.
                    let local = reduceMotion ? 0.5 : abs(sin(time * 3 - Double(index) * 0.7))
                    Circle()
                        .fill(.white.opacity(0.45 + 0.5 * local))
                        .frame(width: 6 + 3 * local, height: 6 + 3 * local)
                }
            }
            .frame(width: LevelMeter.width, alignment: .center)
        }
    }
}
