import SwiftUI

/// Version, build provenance, and the licenses the app ships under.
///
/// The commit and timestamp are stamped into the built Info.plist by a post-build script (see
/// ios/project.yml), because "it broke" is actionable only if the exact build can be named.
/// The license texts are read from the bundle rather than duplicated here, so this screen
/// credits exactly what shipped — the same files a source checkout carries.
struct AboutView: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("App", value: "DoNotType")
                LabeledContent("Version", value: version)
                LabeledContent("Commit", value: info("DNTBuildCommit"))
                LabeledContent("Built", value: info("DNTBuildTimestamp"))
                Link(destination: URL(string: "https://github.com/bojieli/DoNotType")!) {
                    Label("Source on GitHub", systemImage: "link")
                }
                .accessibilityIdentifier("about-github-link")
            }

            // The Form scrolls as a whole, so plain Text is the whole license viewer.
            Section("License") {
                Text(resourceText("LICENSE", withExtension: nil))
                    .font(.caption.monospaced())
            }

            Section("Third-Party Notices") {
                Text(resourceText("THIRD-PARTY-NOTICES", withExtension: "txt"))
                    .font(.caption)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// `short (build)`, same split as every other platform's About box.
    private var version: String {
        let short = info("CFBundleShortVersionString")
        let build = info("CFBundleVersion")
        return "\(short) (\(build))"
    }

    private func info(_ key: String) -> String {
        Bundle.main.infoDictionary?[key] as? String ?? "dev"
    }

    private func resourceText(_ name: String, withExtension ext: String?) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            // Bundled by ios/project.yml; a missing file means the project config drifted.
            return "Not found in the app bundle."
        }
        return text
    }
}
