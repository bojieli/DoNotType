@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import DoNotTypeCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit
import VisionKit

struct SettingsTransferView: View {
    @Bindable var model: DictationModel

    @State private var json = ""
    @State private var status: String?
    @State private var statusIsError = false
    @State private var exporting = false
    @State private var importingFile = false
    @State private var importingQRImage = false
    @State private var scanning = false
    @State private var qrExport: QRExport?
    @State private var requestedInitialScan = false
    private let startsScanning: Bool

    init(model: DictationModel, startsScanning: Bool = false) {
        self.model = model
        self.startsScanning = startsScanning
    }

    var body: some View {
        List {
            Section {
                Label(
                    "Exports include API keys in plaintext",
                    systemImage: "exclamationmark.shield.fill"
                )
                .foregroundStyle(.orange)
                Text(
                    "Treat the JSON file and QR code like a password. A scanned code is imported "
                        + "immediately after validation; files and QR images can be reviewed below."
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
                Button("Import QR image…") { importingQRImage = true }
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
                    "Opening a file or QR image only loads the JSON for review. Scanning a QR code "
                        + "imports its settings immediately and shows a completion screen."
                )
            }
        }
        .navigationTitle("Settings transfer")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if json.isEmpty { loadCurrentSettings() }
            guard startsScanning, !requestedInitialScan else { return }
            requestedInitialScan = true
            // A cover whose state is already true while this view is still being pushed can be
            // dropped because there is no attached presenter yet. Yield once so the navigation
            // destination reaches the window, then present the scanner.
            await Task.yield()
            scanning = true
        }
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
        .fullScreenCover(isPresented: $scanning) {
            QRScannerSheet(simulatedCode: simulatedScannedCode, importCode: importScannedCode)
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
            let qrValue = try SettingsTransferQRCode.encode(document)
            guard let image = QRCode.image(for: qrValue) else {
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

    private func loadQRImage(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            guard let value = QRCode.message(in: try Data(contentsOf: url)) else {
                throw QRImportError.noQRCode
            }
            let document = try SettingsTransferQRCode.decode(value)
            json = try document.jsonString()
            setStatus("QR image loaded. Review the JSON, then choose Import settings.")
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    private func importScannedCode(_ value: String) async throws {
        let document = try SettingsTransferQRCode.decode(value)
        try await model.importSettingsTransfer(document)
        json = try model.settingsTransferDocument().jsonString()
        setStatus("Settings imported from QR code. API keys were stored in Keychain.")
    }

    /// Camera input is unavailable in the simulator. This test-only payload exercises the same
    /// decode, validation, persistence, and completion UI as a real detected QR code.
    private var simulatedScannedCode: String? {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-ui-testing-completed-qr-scan") else {
            return nil
        }
        return try? SettingsTransferQRCode.encode(model.settingsTransferDocument())
        #else
        return nil
        #endif
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
    /// Core Image produces only the QR symbol. A scanner also needs the standard four-module
    /// light quiet zone, especially when the code is displayed against a dark window.
    static func image(for value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        // The QR-only transfer envelope is compressed, leaving enough room for medium error
        // correction. That is more dependable when another device photographs this display.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let quietZone: CGFloat = 4
        let extent = output.extent.integral
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
        let transformed = padded.transformed(by: .init(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
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
                Text(
                    "Keep the entire square and its white border visible to the camera. "
                        + "If it fills the viewfinder, move farther away.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
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
    @State private var cameraState = QRScannerState.starting
    @State private var phase: QRImportPhase
    private let simulatedCode: String?
    let importCode: (String) async throws -> Void

    init(
        simulatedCode: String? = nil,
        importCode: @escaping (String) async throws -> Void
    ) {
        self.simulatedCode = simulatedCode
        self.importCode = importCode
        _phase = State(initialValue: simulatedCode == nil ? .scanning : .importing)
    }

    var body: some View {
        Group {
            switch phase {
            case .scanning:
                ZStack {
                    Color.black.ignoresSafeArea()
                    CameraQRScanner(
                        onCode: beginImport,
                        onStateChange: { cameraState = $0 }
                    )
                    .ignoresSafeArea()

                    RoundedRectangle(cornerRadius: 24)
                        .stroke(.white, style: StrokeStyle(lineWidth: 3, dash: [18, 8]))
                        .frame(width: 286, height: 286)

                    VStack(spacing: 8) {
                        Text("Scan a DoNotType settings QR code")
                            .font(.headline)
                        Text(cameraState.message)
                            .font(.footnote)
                            .multilineTextAlignment(.center)

                        if cameraState == .permissionDenied {
                            Button("Open Camera Settings") {
                                guard let url = URL(string: UIApplication.openSettingsURLString)
                                else { return }
                                UIApplication.shared.open(url)
                            }
                            .buttonStyle(.borderedProminent)
                        } else if cameraState == .starting {
                            ProgressView()
                        }
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 52)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 38)

                    Button("Cancel") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding()
                }
            case .importing:
                QRImportResultView(
                    symbol: "arrow.down.circle",
                    symbolColor: .accentColor,
                    title: "Importing settings…",
                    message: "Validating the QR code and storing its settings securely."
                ) {
                    ProgressView()
                }
            case .imported:
                QRImportResultView(
                    symbol: "checkmark.circle.fill",
                    symbolColor: .green,
                    title: "Settings imported",
                    message: "Your DoNotType settings are ready. API keys were stored in Keychain."
                ) {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accessibilityIdentifier("finish-qr-import")
                }
            case .failed(let message):
                QRImportResultView(
                    symbol: "xmark.circle.fill",
                    symbolColor: .red,
                    title: "Couldn’t import settings",
                    message: message
                ) {
                    VStack(spacing: 12) {
                        Button("Scan again") {
                            cameraState = .starting
                            phase = .scanning
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(phase == .importing)
        .task {
            guard let simulatedCode else { return }
            await finishImport(simulatedCode)
        }
    }

    private func beginImport(_ value: String) {
        guard phase == .scanning else { return }
        phase = .importing
        Task { await finishImport(value) }
    }

    private func finishImport(_ value: String) async {
        do {
            try await importCode(value)
            phase = .imported
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

private enum QRImportPhase: Equatable {
    case scanning
    case importing
    case imported
    case failed(String)
}

private struct QRImportResultView<Actions: View>: View {
    let symbol: String
    let symbolColor: Color
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: symbol)
                .font(.system(size: 72, weight: .semibold))
                .foregroundStyle(symbolColor)
                .accessibilityHidden(true)
            Text(title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            actions()
                .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
    }
}

private enum QRScannerState: Equatable, Sendable {
    case starting
    case scanning
    case permissionDenied
    case cameraUnavailable
    case failed

    var message: String {
        switch self {
        case .starting:
            "Starting the camera…"
        case .scanning:
            "Keep all four corners inside the frame. Move farther away if the code fills it."
        case .permissionDenied:
            "Camera access is off. Allow it in Settings, then return here."
        case .cameraUnavailable:
            "The back camera is unavailable. You can import a QR image instead."
        case .failed:
            "The camera could not start. Close this scanner and try again."
        }
    }
}

private struct CameraQRScanner: View {
    let onCode: (String) -> Void
    let onStateChange: (QRScannerState) -> Void

    var body: some View {
        if DataScannerViewController.isSupported {
            VisionKitQRScanner(onCode: onCode, onStateChange: onStateChange)
        } else {
            AVFoundationQRScanner(onCode: onCode, onStateChange: onStateChange)
        }
    }
}

/// VisionKit uses Apple's full document-scanning pipeline rather than AVFoundation's lightweight
/// metadata detector. Its accurate mode, camera selection, guidance, and zoom handling make dense
/// settings codes displayed on a desktop monitor substantially easier to resolve.
private struct VisionKitQRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onStateChange: (QRScannerState) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode, onStateChange: onStateChange)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .accurate,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        context.coordinator.start(scanner)
        return scanner
    }

    func updateUIViewController(
        _ uiViewController: DataScannerViewController,
        context: Context
    ) {}

    static func dismantleUIViewController(
        _ uiViewController: DataScannerViewController,
        coordinator: Coordinator
    ) {
        coordinator.stop(uiViewController)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCode: (String) -> Void
        private let onStateChange: (QRScannerState) -> Void
        private var startupTask: Task<Void, Never>?
        private var delivered = false

        init(
            onCode: @escaping (String) -> Void,
            onStateChange: @escaping (QRScannerState) -> Void
        ) {
            self.onCode = onCode
            self.onStateChange = onStateChange
        }

        func start(_ scanner: DataScannerViewController) {
            onStateChange(.starting)
            startupTask = Task { @MainActor [weak self, weak scanner] in
                guard let self, let scanner else { return }
                let authorized: Bool
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .authorized:
                    authorized = true
                case .notDetermined:
                    authorized = await AVCaptureDevice.requestAccess(for: .video)
                case .denied, .restricted:
                    authorized = false
                @unknown default:
                    onStateChange(.failed)
                    return
                }

                guard !Task.isCancelled else { return }
                guard authorized else {
                    onStateChange(.permissionDenied)
                    return
                }
                guard DataScannerViewController.isAvailable else {
                    onStateChange(.cameraUnavailable)
                    return
                }
                do {
                    try scanner.startScanning()
                    onStateChange(.scanning)
                } catch {
                    onStateChange(.failed)
                }
            }
        }

        func stop(_ scanner: DataScannerViewController) {
            startupTask?.cancel()
            scanner.stopScanning()
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !delivered else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                    let value = barcode.payloadStringValue
                else { continue }
                delivered = true
                dataScanner.stopScanning()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onCode(value)
                return
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            switch error {
            case .cameraRestricted:
                onStateChange(.permissionDenied)
            case .unsupported:
                onStateChange(.cameraUnavailable)
            @unknown default:
                onStateChange(.failed)
            }
        }
    }
}

/// Fallback for devices on which VisionKit's data scanner is not supported.
private struct AVFoundationQRScanner: UIViewRepresentable {
    let onCode: (String) -> Void
    let onStateChange: (QRScannerState) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode, onStateChange: onStateChange)
    }

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
        private let sessionQueue = DispatchQueue(label: "app.donottype.qr-camera")
        private let onCode: (String) -> Void
        private let onStateChange: (QRScannerState) -> Void
        private var configured = false
        private var delivered = false

        init(
            onCode: @escaping (String) -> Void,
            onStateChange: @escaping (QRScannerState) -> Void
        ) {
            self.onCode = onCode
            self.onStateChange = onStateChange
        }

        func start() {
            updateState(.starting)
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: configureAndStart()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    guard let self else { return }
                    if granted {
                        configureAndStart()
                    } else {
                        updateState(.permissionDenied)
                    }
                }
            case .denied, .restricted: updateState(.permissionDenied)
            @unknown default: updateState(.failed)
            }
        }

        private func configureAndStart() {
            sessionQueue.async { [weak self] in
                guard let self else { return }
                if configured {
                    if !session.isRunning { session.startRunning() }
                    updateState(session.isRunning ? .scanning : .failed)
                    return
                }
                guard let camera = AVCaptureDevice.default(
                    .builtInWideAngleCamera,
                    for: .video,
                    position: .back)
                else {
                    updateState(.cameraUnavailable)
                    return
                }
                guard let input = try? AVCaptureDeviceInput(device: camera),
                    session.canAddInput(input)
                else {
                    updateState(.failed)
                    return
                }

                session.beginConfiguration()
                session.sessionPreset = .high
                session.addInput(input)
                let output = AVCaptureMetadataOutput()
                guard session.canAddOutput(output) else {
                    session.commitConfiguration()
                    updateState(.failed)
                    return
                }
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
                session.commitConfiguration()

                if (try? camera.lockForConfiguration()) != nil {
                    if camera.isFocusModeSupported(.continuousAutoFocus) {
                        camera.focusMode = .continuousAutoFocus
                    }
                    if camera.isExposureModeSupported(.continuousAutoExposure) {
                        camera.exposureMode = .continuousAutoExposure
                    }
                    camera.unlockForConfiguration()
                }

                configured = true
                session.startRunning()
                updateState(session.isRunning ? .scanning : .failed)
            }
        }

        func stop() {
            sessionQueue.async { [weak self] in
                guard let self, session.isRunning else { return }
                session.stopRunning()
            }
        }

        private func updateState(_ state: QRScannerState) {
            DispatchQueue.main.async { [weak self] in self?.onStateChange(state) }
        }

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
                UINotificationFeedbackGenerator().notificationOccurred(.success)
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
