import DoNotTypeCore
import SwiftUI

/// Shows exactly what was sent with one dictation.
///
/// This is the open-source answer to a competitor encrypting its captured context to a server key
/// you do not hold: if an app reads your screen, you should be able to read what it read. It
/// renders the stored `ScreenContext` back through the real `ContextEncoder`, so what appears here
/// is the text that actually went over the wire rather than a summary of it.
struct ContextInspectorView: View {
    let record: DictationRecord
    @Environment(\.dismiss) private var dismiss

    private var parts: [InputPart] {
        guard let context = record.context else { return [] }
        return ContextEncoder().encode(context)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if record.context == nil {
                ContentUnavailableView(
                    "No context was sent",
                    systemImage: "eye.slash",
                    description: Text(
                        "Grounding was off, the app was on the blocklist, or the accessibility "
                            + "tree returned nothing."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                            partView(index: index, part: part)
                        }
                        audioNote
                        transcriptComparison
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 620, height: 560)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("What was sent")
                    .font(.headline)
                Text(record.createdAt, format: .dateTime.day().month().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let app = record.appName {
                    Text("\(app)\(record.windowTitle.map { " — \($0)" } ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(record.provider) · \(record.model)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let context = record.context {
                    Text("~\(ContextEncoder().estimatedTokens(context)) context tokens")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    @ViewBuilder
    private func partView(index: Int, part: InputPart) -> some View {
        switch part {
        case .text(let value):
            VStack(alignment: .leading, spacing: 6) {
                partLabel("Part \(index + 1) · text", detail: "\(value.count) characters")
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }

        case .image(let data, _):
            VStack(alignment: .leading, spacing: 6) {
                partLabel(
                    "Part \(index + 1) · screenshot",
                    detail: "\(data.count / 1024) KB · sent because the accessibility tree was thin")
                if let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.quaternary, lineWidth: 1))
                }
            }

        case .audio:
            EmptyView()  // the recording is described separately below
        }
    }

    private var audioNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            partLabel("Audio", detail: "your recording")
            Text(
                record.audioFileName == nil
                    ? "Not retained. Audio is kept only for dictations that still need retrying, "
                        + "unless you turn on \"Keep audio\"."
                    : "Retained so this dictation can be retried.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// Both versions, side by side, when a rewrite was applied. Seeing what changed is the point
    /// of storing the verbatim transcript separately.
    @ViewBuilder
    private var transcriptComparison: some View {
        if let styled = record.styledText {
            VStack(alignment: .leading, spacing: 6) {
                partLabel("What you said", detail: "verbatim, always stored")
                Text(record.text)
                    .font(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

                partLabel(
                    "What was inserted",
                    detail: record.style.map { "rewritten · \($0.rawValue)" } ?? "rewritten")
                Text(styled)
                    .font(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func partLabel(_ title: String, detail: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
