import SwiftUI

/// The About tab: which build this is, and the licences of everything it ships. Takes no model
/// because nothing here is editable.
struct AboutView: View {
    /// Loaded once rather than on every body evaluation: the text is fixed for the life of the
    /// process, and re-reading the bundle on each redraw buys nothing.
    @State private var licenses = AboutView.loadLicenses()

    var body: some View {
        Form {
            Section {
                Text("DoNotType").font(.headline)
                LabeledContent("Version", value: version)
                LabeledContent("Commit", value: buildInfo("DNTBuildCommit"))
                LabeledContent("Built", value: buildInfo("DNTBuildTimestamp"))
                Link(
                    "github.com/bojieli/DoNotType",
                    destination: URL(string: "https://github.com/bojieli/DoNotType")!)
            }

            Section("Licenses") {
                // Scrollable rather than clipped: the notices are the kind of text nobody reads
                // until they need a specific line of it, and then they need all of it.
                ScrollView {
                    Text(licenses)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 220)
            }
        }
        .formStyle(.grouped)
    }

    private var version: String {
        let bundle = Bundle.main
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// `dev` when the key is absent, which is every launch that skipped the Makefile's stamp
    /// step — a `swift run` binary has no business claiming a commit it may no longer match.
    private func buildInfo(_ key: String) -> String {
        Bundle.main.infoDictionary?[key] as? String ?? "dev"
    }

    private static func loadLicenses() -> String {
        var parts: [String] = []
        for name in ["THIRD-PARTY-NOTICES", "LICENSE"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "txt"),
                let text = try? String(contentsOf: url, encoding: .utf8)
            {
                parts.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        // The Silero notice sits in SwiftPM's per-target resource bundle, not next to the app's
        // own resources — Bundle.module is only visible inside DoNotTypeCore, so from here the
        // bundle has to be found by name.
        if let coreURL = Bundle.main.url(
            forResource: "DoNotType_DoNotTypeCore", withExtension: "bundle"),
            let core = Bundle(url: coreURL),
            let url = core.url(forResource: "SILERO-VAD-NOTICE", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        {
            parts.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return parts.isEmpty
            ? "Licence texts ship inside the app bundle; none were found here."
            : parts.joined(separator: "\n\n")
    }
}
