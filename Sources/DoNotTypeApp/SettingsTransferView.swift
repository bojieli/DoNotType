@preconcurrency import AVFoundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import DoNotTypeCore
import SwiftUI
import UniformTypeIdentifiers

/// Import and export stay in one screen so scanned or opened JSON is visible before it changes
/// credentials or endpoints. The editor is deliberately plain text: it is also the paste route.
struct SettingsTransferView: View {
    @Bindable var model: SettingsModel

    @State private var json = ""
    @State private var status: String?
    @State private var statusIsError = false
    @State private var exporting = false
    @State private var importingFile = false
    @State private var scanning = false
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
                "Treat the JSON file and QR code like a password. A file or scan is loaded below "
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
                Button("Scan QR code…") { scanning = true }
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
        .sheet(item: $qrExport) { export in
            QRExportSheet(export: export)
        }
        .sheet(isPresented: $scanning) {
            QRScannerSheet { value in
                json = value
                setStatus("QR code scanned. Review the JSON, then choose Import settings.")
                scanning = false
            }
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
            let compact = try document.jsonString(prettyPrinted: false)
            guard let image = QRCode.image(for: compact, size: 560) else {
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
        filter.correctionLevel = "L"
        guard let output = filter.outputImage else { return nil }
        let extent = output.extent.integral
        let scale = floor(min(size / extent.width, size / extent.height))
        guard scale >= 1 else { return nil }
        let rendered = output.transformed(by: .init(scaleX: scale, y: scale))
        let representation = NSCIImageRep(ciImage: rendered)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
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
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }
}

private struct QRScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCode: (String) -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Point the camera at a DoNotType settings QR code.").font(.headline)
            CameraQRScanner(onCode: onCode)
                .frame(width: 620, height: 420)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("Nothing is imported until you review the JSON and choose Import settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Cancel") { dismiss() }
        }
        .padding(20)
    }
}

private struct CameraQRScanner: NSViewRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeNSView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.previewLayer.session = context.coordinator.session
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: CameraPreviewView, context: Context) {}

    static func dismantleNSView(_ nsView: CameraPreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
        let session = AVCaptureSession()
        private let onCode: (String) -> Void
        private var configured = false
        private var delivered = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func start() {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: configureAndStart()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    guard granted else { return }
                    self?.configureAndStart()
                }
            default: break
            }
        }

        private func configureAndStart() {
            guard !configured,
                let camera = AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: camera),
                session.canAddInput(input)
            else { return }
            configured = true
            session.beginConfiguration()
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            session.commitConfiguration()
            session.startRunning()
        }

        func stop() { if session.isRunning { session.stopRunning() } }

        nonisolated func captureOutput(
            _ output: AVCaptureOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?
                .stringValue
            else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !delivered else { return }
                delivered = true
                onCode(value)
            }
        }
    }
}

private final class CameraPreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}
