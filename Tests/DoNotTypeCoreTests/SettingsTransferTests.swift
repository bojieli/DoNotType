import Foundation
import Testing

@testable import DoNotTypeCore

struct SettingsTransferTests {
    private func document() -> SettingsTransferDocument {
        SettingsTransferDocument(
            selectedProvider: "google",
            providers: [
                "google": .init(
                    model: "gemini-test", endpoint: "https://example.test/v1",
                    apiKey: "secret"),
                "xai": .init(model: "grok-stt"),
            ],
            fidelity: "light",
            fallback: .init(provider: "xai", afterSeconds: 8),
            retention: "oneWeek",
            keepAudio: false,
            dictionary: .init(
                manual: ["DoNotType"], learned: ["MLX"], learnsFromEdits: true),
            iOS: .init(liveStyle: "verbatim"))
    }

    @Test func roundTripsPrettyAndCompactJSON() throws {
        let expected = document()

        #expect(try SettingsTransferDocument.decode(expected.encoded()) == expected)
        #expect(
            try SettingsTransferDocument.decode(expected.encoded(prettyPrinted: false)) == expected)
        #expect(expected.containsSecrets)
    }

    /// A profile written before the typography block existed still imports, and one that carries
    /// it survives the round trip. Both halves matter: the block is optional in the format, and
    /// optional plus silently dropped is how a setting stops crossing devices.
    @Test func typographySurvivesTheRoundTripAndIsOptional() throws {
        var withTypography = document()
        withTypography.typography = .init(
            spacing: TypographySpacing.tight.rawValue,
            chineseScript: ChineseScript.traditional.rawValue,
            formattingSample: "中文 English。")
        #expect(try SettingsTransferDocument.decode(withTypography.encoded()) == withTypography)

        let older = document()
        #expect(older.typography == nil)
        #expect(try SettingsTransferDocument.decode(older.encoded()).typography == nil)
    }

    @Test func rejectsWrongFormatAndUnknownVersion() throws {
        var wrongFormat = document()
        wrongFormat.format = "some.other.application"
        #expect(throws: SettingsTransferError.wrongFormat("some.other.application")) {
            try wrongFormat.encoded()
        }

        var future = document()
        future.version = 99
        #expect(throws: SettingsTransferError.unsupportedVersion(99)) {
            try future.encoded()
        }
    }

    @Test func rejectsIncompleteProviderReferences() throws {
        var missingPrimary = document()
        missingPrimary.selectedProvider = "missing"
        #expect(throws: SettingsTransferError.missingSelectedProvider) {
            try missingPrimary.validate()
        }

        var sameFallback = document()
        sameFallback.fallback = .init(provider: "google", afterSeconds: 8)
        #expect(throws: SettingsTransferError.fallbackMatchesPrimary) {
            try sameFallback.validate()
        }
    }

    @Test func decoderHasSizeLimit() {
        let oversized = Data(repeating: 0, count: SettingsTransferDocument.maximumBytes + 1)
        #expect(
            throws: SettingsTransferError.tooLarge(
                maximumBytes: SettingsTransferDocument.maximumBytes)
        ) {
            try SettingsTransferDocument.decode(oversized)
        }
    }

    @Test func qrEnvelopeIsCompactAndBackwardsCompatible() throws {
        let expected = document()
        let raw = try expected.jsonString(prettyPrinted: false)
        let encoded = try SettingsTransferQRCode.encode(expected)

        #expect(encoded.hasPrefix(SettingsTransferQRCode.prefix))
        #expect(encoded.utf8.count < raw.utf8.count)
        #expect(try SettingsTransferQRCode.decode(encoded) == expected)
        #expect(try SettingsTransferQRCode.decode(raw) == expected)
    }

    @Test func qrEnvelopeRejectsDamagedData() {
        #expect(throws: SettingsTransferError.self) {
            try SettingsTransferQRCode.decode("\(SettingsTransferQRCode.prefix)not-compressed")
        }
    }
}
