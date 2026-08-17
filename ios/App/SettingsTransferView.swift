@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import DoNotTypeCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct SettingsTransferView: View {
    @Bindable var model: DictationModel

    @State private var json = ""
    @State private var status: String?
    @State private var statusIsError = false
    @State private var exporting = false
    @State private var importingFile = false
    @State private var scanning = false
    @State private var qrExport: QRExport?

    var body: some View {
        List {
            Section {
                Label(
                    "Exports include API keys in plaintext",
                    systemImage: "exclamationmark.shield.fill"
                )
                .foregroundStyle(.orange)
                Text(
                    "Treat the JSON file and QR code like a password. Check the provider and "
                        + "endpoint below before importing."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("JSON") {
                TextEditor(text: $json)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 260)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Settings JSON")
                    .accessibilityIdentifier("settings-transfer-json")

                HStack {
                    Button("Paste") {
                        if let value = UIPasteboard.general.string {
                            json = value
                            setStatus("Pasted JSON. Review it before importing.")
                        }
                    }
                    Spacer()
                    Button("Copy") {
                        UIPasteboard.general.string = json
                        setStatus("Settings JSON copied.")
                    }
                }
            }

            Section("Export") {
                Button("Load current settings", action: loadCurrentSettings)
                Button("Save JSON file…") { exporting = true }
                Button("Show QR code", action: showQRCode)
            }

            Section {
                Button("Open JSON file…") { importingFile = true }
                Button("Scan QR code…") { scanning = true }
                Button("Import settings") {
                    Task { await importEditor() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let status {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(statusIsError ? .red : .secondary)
                }
            } header: {
                Text("Import")
            } footer: {
                Text(
                    "Opening or scanning only loads the JSON. Import is a separate step because "
                        + "the document can replace credentials and network endpoints."
                )
            }
        }
        .navigationTitle("Settings transfer")
        .navigationBarTitleDisplayMode(.inline)
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
        .fullScreenCover(isPresented: $scanning) {
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

    private func showQRCode() {
        do {
            let document = try SettingsTransferDocument.decode(json)
            let compact = try document.jsonString(prettyPrinted: false)
            guard let image = QRCode.image(for: compact) else {
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
            setStatus("Loaded \(url.lastPathComponent). Review it before importing.")
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
    let image: UIImage
    let containsSecrets: Bool
}

private enum QRCode {
    static func image(for value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "L"
        guard let output = filter.outputImage else { return nil }
        let transformed = output.transformed(by: .init(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

private struct QRExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let export: QRExport

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(uiImage: export.image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding()
                    .accessibilityLabel("Settings QR code")
                if export.containsSecrets {
                    Label("This QR code contains API keys.", systemImage: "lock.open.fill")
                        .foregroundStyle(.orange)
                }
            }
            .navigationTitle("Settings QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct QRScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCode: (String) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            CameraQRScanner(onCode: onCode).ignoresSafeArea()
            VStack(spacing: 8) {
                Text("Scan a DoNotType settings QR code")
                    .font(.headline)
                Text("You can review it before importing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
        }
        .overlay(alignment: .topTrailing) {
            Button("Cancel") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding()
        }
    }
}

private struct CameraQRScanner: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.previewLayer.session = context.coordinator.session
        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: CameraPreviewView, coordinator: Coordinator) {
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

private final class CameraPreviewView: UIView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}
