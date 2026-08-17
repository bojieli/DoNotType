import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import DoNotTypeCore
import SwiftUI
import UniformTypeIdentifiers

/// Import and export stay in one screen so opened JSON or a QR image is visible before it changes
/// credentials or endpoints. The editor is deliberately plain text: it is also the paste route.
struct SettingsTransferView: View {
    @Bindable var model: SettingsModel

    @State private var json = ""
    @State private var status: String?
    @State private var statusIsError = false
    @State private var exporting = false
    @State private var importingFile = false
    @State private var importingQRImage = false
    @State private var qrExport: QRExport?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                "Exports include API keys in plaintext",
                systemImage: "exclamationmark.shield.fill"
            )
            .font(.headline)
            .foregroundStyle(.orange)

            Text(
                "Treat the JSON file and QR code like a password. A file or QR image is loaded below "
                    + "for review first; check its provider and endpoint before importing it."
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack {
                Button("Load current settings", action: loadCurrentSettings)
                Button("Copy JSON", action: copyJSON)
                Button("Save JSON…") { exporting = true }
                Button("Show QR code", action: showQRCode)
                Divider().frame(height: 20)
                Button("Open JSON…") { importingFile = true }
                Button("Import QR image…") { importingQRImage = true }
                Spacer()
            }

            TextEditor(text: $json)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .border(.quaternary)
                .accessibilityLabel("Settings JSON")

            HStack {
                Button("Import settings") {
                    Task { await importEditor() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let status {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(statusIsError ? .red : .secondary)
                        .textSelection(.enabled)
                }
                Spacer()
            }
        }
        .padding(20)
        .task { if json.isEmpty { loadCurrentSettings() } }
        .fileExporter(
            isPresented: $exporting,
            document: SettingsJSONFile(json: json),
            contentType: .json,
            defaultFilename: "donottype-settings.json"
        ) { result in
            switch result {
            case .success: setStatus("Settings JSON saved.")
            case .failure(let error): setStatus(error.localizedDescription, isError: true)
            }
        }
        .fileImporter(
            isPresented: $importingFile,
            allowedContentTypes: [.json, .plainText]
        ) { result in
            switch result {
            case .success(let url): loadFile(url)
                case .failure(let error): setStatus(error.localizedDescription, isError: true)
            }
        }
        .fileImporter(
            isPresented: $importingQRImage,
            allowedContentTypes: [.image]
        ) { result in
            switch result {
            case .success(let url): loadQRImage(url)
            case .failure(let error): setStatus(error.localizedDescription, isError: true)
            }
        }
        .sheet(item: $qrExport) { export in
            QRExportSheet(export: export)
        }
    }

    private func loadCurrentSettings() {
        do {
            json = try model.settingsTransferDocument().jsonString()
            setStatus("Loaded the current settings.")
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    private func copyJSON() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        setStatus("Settings JSON copied.")
    }

    private func showQRCode() {
        do {
            let document = try SettingsTransferDocument.decode(json)
            let qrValue = try SettingsTransferQRCode.encode(document)
            guard let image = QRCode.image(for: qrValue, size: 560) else {
                setStatus(
                    "These settings do not fit in one QR code. Save or copy the JSON instead.",
                    isError: true)
                return
            }
            qrExport = QRExport(image: image, containsSecrets: document.containsSecrets)
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    private func loadFile(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if let size = values.fileSize, size > SettingsTransferDocument.maximumBytes {
                throw SettingsTransferError.tooLarge(
                    maximumBytes: SettingsTransferDocument.maximumBytes)
            }
            let document = try SettingsTransferDocument.decode(Data(contentsOf: url))
            json = try document.jsonString()
            setStatus("Loaded \(url.lastPathComponent). Review it, then choose Import settings.")
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    private func loadQRImage(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            guard let value = QRCode.message(in: try Data(contentsOf: url)) else {
                throw QRImportError.noQRCode
            }
            let document = try SettingsTransferQRCode.decode(value)
            json = try document.jsonString()
            setStatus("QR image loaded. Review it, then choose Import settings.")
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    private func importEditor() async {
        do {
            let document = try SettingsTransferDocument.decode(json)
            try await model.importSettingsTransfer(document)
            json = try model.settingsTransferDocument().jsonString()
            setStatus("Settings imported. API keys were stored in Keychain.")
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    private func setStatus(_ value: String, isError: Bool = false) {
        status = value
        statusIsError = isError
    }
}

private struct SettingsJSONFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .plainText] }
    var json: String

    init(json: String) { self.json = json }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
            data.count <= SettingsTransferDocument.maximumBytes,
            let json = String(data: data, encoding: .utf8)
        else { throw SettingsTransferError.invalidUTF8 }
        self.json = json
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(json.utf8))
    }
}

private struct QRExport: Identifiable {
    let id = UUID()
    let image: NSImage
    let containsSecrets: Bool
}

private enum QRCode {
    static func image(for value: String, size: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        // The QR-only transfer envelope is compressed, leaving enough room for medium error
        // correction. That is more dependable when a phone photographs a laptop display.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let extent = output.extent.integral
        // Core Image omits the standard four-module quiet zone. A solid white border is
        // particularly important when this sheet is displayed in macOS dark mode.
        let quietZone: CGFloat = 4
        let canvas = CGRect(
            x: 0,
            y: 0,
            width: extent.width + quietZone * 2,
            height: extent.height + quietZone * 2)
        let positioned = output.transformed(
            by: .init(
                translationX: quietZone - extent.minX,
                y: quietZone - extent.minY))
        let padded = positioned.composited(
            over: CIImage(color: .white).cropped(to: canvas))
        let scale = floor(min(size / canvas.width, size / canvas.height))
        guard scale >= 1 else { return nil }
        let rendered = padded.transformed(by: .init(scaleX: scale, y: scale))
        let representation = NSCIImageRep(ciImage: rendered)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }

    static func message(in data: Data) -> String? {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]),
            let detector = CIDetector(
                ofType: CIDetectorTypeQRCode,
                context: CIContext(),
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
            )
        else { return nil }
        return detector.features(in: image)
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            .first
    }
}

private enum QRImportError: LocalizedError {
    case noQRCode

    var errorDescription: String? {
        "No readable QR code was found in that image."
    }
}

private struct QRExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let export: QRExport

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: export.image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 560, height: 560)
                .accessibilityLabel("Settings QR code")
            if export.containsSecrets {
                Label("This QR code contains API keys.", systemImage: "lock.open.fill")
                    .foregroundStyle(.orange)
            }
            Text(
                "Keep the entire square and its white border visible to the phone camera. "
                    + "If it fills the viewfinder, move the phone farther away.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }
}
