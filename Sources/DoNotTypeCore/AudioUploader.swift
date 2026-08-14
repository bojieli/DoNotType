import Foundation

/// Gets the recording to the model, by whichever route works.
///
/// Two paths, and the fallback between them is the point:
///
/// 1. **Pre-upload** — a resumable Files API session is opened *while the user is still speaking*,
///    so the handshake is paid for during recording rather than after it. On release the finished
///    file is uploaded and referenced by URI, which means the transcription request carries a few
///    hundred bytes of JSON instead of megabytes of base64.
/// 2. **Inline** — the whole recording, base64-encoded in the request.
///
/// Anything that goes wrong on path 1 falls through to path 2 rather than failing the dictation.
/// A flaky network should cost latency, never words.
///
/// One thing that emphatically does *not* work, tested rather than assumed: uploading audio in
/// chunks as it is captured. A WAV declares its length in the header, and a header written with
/// the streaming convention (`0xFFFFFFFF`) is rejected with `invalid argument` — the upload
/// succeeds and the transcription request then fails. So the file is uploaded once, complete.
public actor AudioUploader {
    /// Inline requests are capped at 20 MB including the prompt; base64 inflates by ~4/3, so
    /// anything past this must take the Files API path or be rejected.
    public static let inlineByteLimit = 14_000_000

    public enum Route: Sendable, Equatable {
        /// Referenced by Files API URI.
        case preUploaded(uri: String)
        /// Carried in the request body.
        case inline
    }

    public struct Plan: Sendable {
        public let part: InputPart
        public let route: Route
    }

    public enum UploadError: LocalizedError {
        case sessionRefused(String)
        case uploadFailed(String)
        case tooLargeForInline(bytes: Int)

        public var errorDescription: String? {
            switch self {
            case .sessionRefused(let detail): "Could not open an upload session: \(detail)"
            case .uploadFailed(let detail): "Upload failed: \(detail)"
            case .tooLargeForInline(let bytes):
                "Recording is \(bytes / 1_000_000) MB — too large to send inline, and the upload "
                    + "service could not be reached."
            }
        }
    }

    private let log = Log("upload")
    private let apiKey: String
    private let session: URLSession
    private let baseURL: URL

    /// Opened during recording, consumed at the end of it.
    private var pendingSessionURL: URL?
    private var sessionTask: Task<URL?, Never>?

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    /// Starts opening a resumable session, without waiting for it.
    ///
    /// Called at hotkey-down. `contentLength` is a guess at that point — the API only uses it as a
    /// hint, and the finalize step reports the real size.
    /// Opens the resumable session. Called at hotkey-down, before any audio exists.
    ///
    /// Deliberately declares no content length. The obvious thing is to send
    /// `X-Goog-Upload-Header-Content-Length` with a guess, and that is what this did — but the
    /// header is not a hint, it is a contract: finalising with a different number of bytes fails
    /// with *"Can not finalize upload. Current size is 44770. Expected final size is 704078."*
    ///
    /// That is unfixable by guessing better, because the size cannot be known here. The recording
    /// has not happened yet, and compression happens after it. Omitting the header is accepted and
    /// the finalise step reports the real length.
    public func prepare(mimeType: String = "audio/ogg") {
        guard sessionTask == nil else { return }
        sessionTask = Task { [apiKey, baseURL, session, log] in
            do {
                var request = URLRequest(
                    url: baseURL.appending(path: "/upload/v1beta/files")
                        .appending(queryItems: [URLQueryItem(name: "key", value: apiKey)]))
                request.httpMethod = "POST"
                request.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
                request.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
                request.setValue(
                    mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(
                    withJSONObject: ["file": ["display_name": "dictation"]])
                request.timeoutInterval = 15

                let (_, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse,
                    let value = http.value(forHTTPHeaderField: "x-goog-upload-url"),
                    let url = URL(string: value)
                else { return nil }
                return url
            } catch {
                // Not an error the user should see: the inline path still works.
                log.info("pre-upload session unavailable: \(error.localizedDescription)")
                return nil
            }
        }
    }

    /// Chooses a route for `audio` and returns the request part to send.
    ///
    /// Never throws for network reasons alone — it degrades to inline. It only throws when the
    /// recording is too large to inline *and* the upload service is unreachable, which is the one
    /// case with no way through.
    public func plan(for audio: AudioFile) async throws -> Plan {
        let sessionURL = await sessionTask?.value ?? nil
        sessionTask = nil

        // Compressed here rather than at the call site, so both routes get it. Doing it only on
        // the inline path was a real bug: pre-upload is the app's *primary* route, so the measured
        // saving — 960 kB to 60 kB for 30 seconds — reached the eval harness and nobody else.
        let audio = audio.compressedForUpload()

        if let sessionURL {
            do {
                let uri = try await finishUpload(audio: audio, to: sessionURL)
                return Plan(part: .audioURI(uri: uri, mimeType: audio.mimeType), route: .preUploaded(uri: uri))
            } catch {
                log.warning(
                    "pre-upload failed, falling back to inline: \(error.localizedDescription)")
            }
        }

        guard audio.data.count <= Self.inlineByteLimit else {
            // Long dictation plus a dead upload service. Retrying later is the only option, and
            // the caller stores the audio so that stays possible.
            throw UploadError.tooLargeForInline(bytes: audio.data.count)
        }
        return Plan(part: audio.part, route: .inline)
    }

    /// Discards a session opened for a recording that was cancelled.
    public func cancel() {
        sessionTask?.cancel()
        sessionTask = nil
        pendingSessionURL = nil
    }

    // MARK: - Private

    private func finishUpload(audio: AudioFile, to sessionURL: URL) async throws -> String {
        var request = URLRequest(url: sessionURL)
        request.httpMethod = "POST"
        request.setValue(String(audio.data.count), forHTTPHeaderField: "Content-Length")
        request.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        request.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        request.httpBody = audio.data
        request.timeoutInterval = 60

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw UploadError.uploadFailed("HTTP \(status)")
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let file = root["file"] as? [String: Any],
            let uri = file["uri"] as? String
        else {
            throw UploadError.uploadFailed("no file URI in the response")
        }
        return uri
    }
}

extension InputPart {
    /// Audio already uploaded to the Files API, referenced rather than carried.
    ///
    /// The key is `uri`; `file_uri` is rejected as an unknown parameter.
    public static func audioURI(uri: String, mimeType: String) -> InputPart {
        .remoteAudio(uri: uri, mimeType: mimeType)
    }
}
