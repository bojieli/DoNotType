import Foundation

/// Finds this target's own resource bundle, without going through `Bundle.module`.
///
/// SwiftPM generates `Bundle.module` as:
///
///     Bundle.main.bundleURL.appendingPathComponent("DoNotType_DoNotTypeCore.bundle")
///
/// falling back to an **absolute path into the machine that compiled the binary**. Neither is right
/// once the executable is wrapped in a `.app`: `Bundle.main.bundleURL` is the `.app` itself, and a
/// resource cannot live at the `.app` root — everything signed has to sit under `Contents/`, which
/// is why `make app` puts the bundle in `Contents/Resources/`. So the app layout can never satisfy
/// the generated accessor, and what actually resolved it was the compile-time fallback.
///
/// That is why this survived so long. On the machine that built it the fallback directory exists,
/// so the app works everywhere it is tested; on a machine that merely *downloaded* it, the fallback
/// points at somebody else's `/Users/runner/work/...` and `Bundle.module` reaches its `fatalError`.
/// Every CI-built release was one recording away from dying that way, and no local run could show
/// it. Found by installing a release through Homebrew and transcribing one file with the `dnt` that
/// ships inside the bundle.
///
/// Candidates are tried against the *resource*, not merely against whether a bundle loads, because
/// several of these paths resolve to a real bundle that does not carry it — the `.xctest` bundle
/// under `swift test` being the one that caught this list out first.
enum CoreResources {
    static let bundleName = "DoNotType_DoNotTypeCore"

    /// Resolves one of this target's resources, or nil when no layout carries it.
    ///
    /// Deliberately nil rather than a trap. `Bundle.module` turns a missing resource into a
    /// `fatalError`, which escalates a recoverable "this build has no local VAD" into a crash of
    /// whatever process happened to touch it; the caller here already has an error for that case.
    static func url(forResource name: String, withExtension ext: String) -> URL? {
        for bundle in candidates {
            if let url = bundle.url(forResource: name, withExtension: ext) { return url }
        }
        return nil
    }

    /// Every bundle that might hold this target's resources, cheapest and most likely first.
    private static let candidates: [Bundle] = {
        // Bundle(for:) needs a class, and this target is otherwise structs and enums all the way
        // down. Statically linked, it answers with whatever binary the core ended up inside.
        let anchor = Bundle(for: ResourceAnchor.self)

        var directories: [URL] = []
        func consider(_ url: URL?) {
            guard let url else { return }
            if !directories.contains(url) { directories.append(url) }
        }

        // The app layout (`Contents/Resources`) and the plain SwiftPM executable layout, where the
        // sibling bundle sits in the same directory as the binary. One URL covers both.
        consider(Bundle.main.resourceURL)
        // What the generated accessor checks, kept so any layout satisfying it still works.
        consider(Bundle.main.bundleURL)
        // A framework or test host that embedded the core instead of statically linking it.
        consider(anchor.resourceURL)
        consider(anchor.bundleURL)
        // `swift test`: the sibling bundle is beside the `.xctest`, not inside it.
        consider(anchor.bundleURL.deletingLastPathComponent())
        consider(Bundle.main.bundleURL.deletingLastPathComponent())

        var bundles: [Bundle] = []
        for directory in directories {
            let url = directory.appendingPathComponent("\(bundleName).bundle")
            if let bundle = Bundle(url: url) { bundles.append(bundle) }
        }
        // Some layouts (iOS among them) flatten a target's resources straight into the host bundle
        // rather than keeping a sibling, so ask those two directly as well.
        bundles.append(anchor)
        bundles.append(Bundle.main)
        return bundles
    }()
}

/// Only exists to give `Bundle(for:)` a class inside this module.
private final class ResourceAnchor {}
