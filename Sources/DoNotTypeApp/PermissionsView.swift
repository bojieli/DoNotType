import AVFoundation
import AppKit
import SwiftUI

/// What the app needs, whether it has it, and how to grant it.
///
/// Checked at every launch, not just the first: macOS revokes Accessibility when an app's code
/// signature changes, and users turn things off in System Settings without connecting that to the
/// app going quiet. A tool whose hotkey silently stops working is worse than one that says why.
@MainActor
@Observable
final class PermissionsModel {
    struct Requirement: Identifiable {
        let id: String
        let title: String
        let detail: String
        let isRequired: Bool
        var isGranted: Bool
        let settingsURL: String
    }

    private(set) var requirements: [Requirement] = []

    var allRequiredGranted: Bool {
        requirements.filter(\.isRequired).allSatisfy(\.isGranted)
    }

    func refresh() {
        requirements = [
            Requirement(
                id: "accessibility",
                title: "Accessibility",
                detail:
                    "Needed twice over: to notice your hotkey anywhere in the system, and to paste "
                    + "the transcript into whatever you were typing in. Without it the app cannot "
                    + "work at all.",
                isRequired: true,
                isGranted: AccessibilityReader.isTrusted,
                settingsURL:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
            Requirement(
                id: "microphone",
                title: "Microphone",
                detail:
                    "Recording happens only while you hold the dictation key. Nothing is captured "
                    + "at any other time.",
                isRequired: true,
                isGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                settingsURL:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"),
            Requirement(
                id: "screen",
                title: "Screen Recording",
                detail:
                    "Optional. Used only when an app exposes no readable text — Figma, a "
                    + "GPU-rendered terminal, a PDF — so the model can still see what you are "
                    + "looking at. Most people never need it.",
                isRequired: false,
                isGranted: CGPreflightScreenCaptureAccess(),
                settingsURL:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
        ]
    }

    /// Triggers the system prompt where one exists, otherwise opens System Settings.
    func request(_ requirement: Requirement) async {
        switch requirement.id {
        case "accessibility":
            // Shows the prompt only once per signature; afterwards this is a no-op and the
            // Settings deep link is the way through.
            AccessibilityReader.requestTrust()
            openSettings(requirement)
        case "microphone":
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AudioRecorder.requestAccess()
            } else {
                openSettings(requirement)
            }
        case "screen":
            ScreenCapturer.requestPermission()
        default:
            openSettings(requirement)
        }
        refresh()
    }

    func openSettings(_ requirement: Requirement) {
        guard let url = URL(string: requirement.settingsURL) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The onboarding sheet. Shown at launch whenever something required is missing.
struct PermissionsView: View {
    @Bindable var model: PermissionsModel
    var onDone: () -> Void

    @State private var pollTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("DoNotType needs a few permissions")
                    .font(.title2.weight(.semibold))
                Text(
                    "macOS grants these per app signature, so they can also be revoked by a "
                        + "system update or a reinstall. This screen re-checks them every launch."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.requirements) { requirement in
                        RequirementRow(requirement: requirement) {
                            Task { await model.request(requirement) }
                        }
                        Divider()
                    }
                }
            }

            HStack {
                if model.allRequiredGranted {
                    Label("Ready to dictate", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("Grant the required items, then this window will let you continue.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.allRequiredGranted ? "Start dictating" : "Continue anyway") {
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 540, height: 520)
        .onAppear(perform: startPolling)
        .onDisappear { pollTimer?.invalidate() }
    }

    /// macOS sends no notification when a permission is granted in System Settings, so the only
    /// way for this window to update while the user is over there is to look again.
    private func startPolling() {
        model.refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { model.refresh() }
        }
    }
}

private struct RequirementRow: View {
    let requirement: PermissionsModel.Requirement
    var onGrant: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: requirement.isGranted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(requirement.isGranted ? .green : .secondary)
                .font(.title3)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(requirement.title).font(.headline)
                    if !requirement.isRequired {
                        Text("optional")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                Text(requirement.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if !requirement.isGranted {
                Button("Grant", action: onGrant)
            }
        }
        .padding(16)
    }
}
