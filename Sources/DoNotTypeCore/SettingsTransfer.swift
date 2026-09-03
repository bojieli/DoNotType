import Foundation

/// The portable settings document shared by the Apple clients and intended for the other clients
/// to adopt as well. Values that belong to an enum are stored as strings: an older client can
/// ignore a platform block it does not understand, while the client applying the document can
/// validate the values against the cases it actually supports.
public struct SettingsTransferDocument: Codable, Equatable, Sendable {
    public static let formatIdentifier = "app.donottype.settings"
    public static let currentVersion = 1
    public static let maximumBytes = 1_048_576

    public struct Provider: Codable, Equatable, Sendable {
        public var model: String
        public var textModel: String?
        public var endpoint: String?
        public var apiKey: String?

        public init(
            model: String, textModel: String? = nil, endpoint: String? = nil,
            apiKey: String? = nil
        ) {
            self.model = model
            self.textModel = textModel
            self.endpoint = endpoint
            self.apiKey = apiKey
        }
    }

    public struct Fallback: Codable, Equatable, Sendable {
        public var provider: String
        public var afterSeconds: Double

        public init(provider: String, afterSeconds: Double) {
            self.provider = provider
            self.afterSeconds = afterSeconds
        }
    }

    public struct Dictionary: Codable, Equatable, Sendable {
        public var manual: [String]
        public var learned: [String]
        public var learnsFromEdits: Bool

        public init(manual: [String], learned: [String], learnsFromEdits: Bool) {
            self.manual = manual
            self.learned = learned
            self.learnsFromEdits = learnsFromEdits
        }
    }

    /// Preferences that have no iOS equivalent. Other clients leave this block untouched.
    public struct Desktop: Codable, Equatable, Sendable {
        public var trigger: String
        public var hotkeyMode: String
        public var cancelShortcut: String
        public var finishAndSendAction: String
        public var secondaryTrigger: String?
        public var secondaryStyle: String
        /// The key bound to Translate. Absent in a profile written before Translate had a key of
        /// its own, when a target language in `Typography` overrode both of the other keys
        /// instead — so an old document leaves the importing device's binding alone rather than
        /// clearing it.
        public var translateTrigger: String?
        public var interactionSounds: Bool
        public var launchAtLogin: Bool
        public var groundingEnabled: Bool
        public var screenshotEnabled: Bool
        public var keytermBiasing: Bool
        public var blockedBundleIDs: [String]
        public var blockedURLPrefixes: [String]
        public var logLevel: String
        public var logContent: Bool
        public var fileMode: String

        public init(
            trigger: String, hotkeyMode: String, cancelShortcut: String,
            finishAndSendAction: String, secondaryTrigger: String?, secondaryStyle: String,
            translateTrigger: String? = nil,
            interactionSounds: Bool, launchAtLogin: Bool, groundingEnabled: Bool,
            screenshotEnabled: Bool, keytermBiasing: Bool, blockedBundleIDs: [String],
            blockedURLPrefixes: [String], logLevel: String, logContent: Bool, fileMode: String
        ) {
            self.trigger = trigger
            self.hotkeyMode = hotkeyMode
            self.cancelShortcut = cancelShortcut
            self.finishAndSendAction = finishAndSendAction
            self.secondaryTrigger = secondaryTrigger
            self.secondaryStyle = secondaryStyle
            self.translateTrigger = translateTrigger
            self.interactionSounds = interactionSounds
            self.launchAtLogin = launchAtLogin
            self.groundingEnabled = groundingEnabled
            self.screenshotEnabled = screenshotEnabled
            self.keytermBiasing = keytermBiasing
            self.blockedBundleIDs = blockedBundleIDs
            self.blockedURLPrefixes = blockedURLPrefixes
            self.logLevel = logLevel
            self.logContent = logContent
            self.fileMode = fileMode
        }
    }

    /// How transcripts are written down. Shared by all four clients rather than living in
    /// `Desktop`, because typography is not a desktop concept: a transcript spaced one way on a
    /// laptop and another on the phone reading the same profile is the drift this block prevents.
    ///
    /// Optional, so a document written before it existed still imports. An importing client
    /// validates the strings against the cases it has and refuses the whole document if they do
    /// not parse, exactly as it does for `fidelity`.
    public struct Typography: Codable, Equatable, Sendable {
        public var spacing: String
        public var chineseScript: String
        /// What the example box holds. Absent in a profile written before the box replaced the
        /// style dropdown, in which case the two legacy fields below are migrated instead.
        public var dictationExample: String?
        /// Retired. Still **written**, so a profile made here imports correctly into an older
        /// build: an example arrives there as `custom` with the same text, which is the same
        /// request. Still **read**, so a profile made there imports correctly here — see
        /// `DictationExample.migrating`.
        public var dictationStyle: String?
        /// The user's own style text for each stage. Two fields rather than one, because the two
        /// stages are different jobs: the dictation style may not reword and the rewrite style is
        /// there to. Kept even while a preset is selected, so switching away and back does not
        /// silently delete something somebody wrote.
        public var customDictationStyle: String?
        public var customRewriteStyle: String?
        /// Empty, or absent altogether in a profile written before translation existed, means the
        /// dictation stays in the language that was spoken.
        public var translateTo: String?

        public init(
            spacing: String, chineseScript: String,
            dictationExample: String? = nil,
            dictationStyle: String? = nil,
            customDictationStyle: String? = nil,
            customRewriteStyle: String? = nil,
            translateTo: String? = nil
        ) {
            self.spacing = spacing
            self.chineseScript = chineseScript
            self.dictationExample = dictationExample
            self.dictationStyle = dictationStyle
            self.customDictationStyle = customDictationStyle
            self.customRewriteStyle = customRewriteStyle
            self.translateTo = translateTo
        }
    }

    /// The phone chooses its mode from the chip; a desktop chooses it with which key it holds.
    public struct IOS: Codable, Equatable, Sendable {
        public var liveStyle: String

        public init(liveStyle: String) { self.liveStyle = liveStyle }
    }

    public var format: String
    public var version: Int
    public var selectedProvider: String
    public var providers: [String: Provider]
    public var fidelity: String
    public var fallback: Fallback?
    public var retention: String
    public var keepAudio: Bool
    public var dictionary: Dictionary
    public var typography: Typography?
    public var desktop: Desktop?
    public var iOS: IOS?

    public init(
        selectedProvider: String, providers: [String: Provider], fidelity: String,
        fallback: Fallback?, retention: String, keepAudio: Bool, dictionary: Dictionary,
        typography: Typography? = nil, desktop: Desktop? = nil, iOS: IOS? = nil
    ) {
        format = Self.formatIdentifier
        version = Self.currentVersion
        self.selectedProvider = selectedProvider
        self.providers = providers
        self.fidelity = fidelity
        self.fallback = fallback
        self.retention = retention
        self.keepAudio = keepAudio
        self.dictionary = dictionary
        self.typography = typography
        self.desktop = desktop
        self.iOS = iOS
    }

    public var containsSecrets: Bool {
        providers.values.contains { !($0.apiKey ?? "").isEmpty }
    }

    public func encoded(prettyPrinted: Bool = true) throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func jsonString(prettyPrinted: Bool = true) throws -> String {
        guard let value = String(data: try encoded(prettyPrinted: prettyPrinted), encoding: .utf8)
        else { throw SettingsTransferError.invalidUTF8 }
        return value
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else {
            throw SettingsTransferError.tooLarge(maximumBytes: maximumBytes)
        }
        let document: Self
        do {
            document = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw SettingsTransferError.invalidJSON(error.localizedDescription)
        }
        try document.validate()
        return document
    }

    public static func decode(_ json: String) throws -> Self {
        try decode(Data(json.utf8))
    }

    public func validate() throws {
        guard format == Self.formatIdentifier else {
            throw SettingsTransferError.wrongFormat(format)
        }
        guard version == Self.currentVersion else {
            throw SettingsTransferError.unsupportedVersion(version)
        }
        guard !selectedProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            providers[selectedProvider] != nil
        else { throw SettingsTransferError.missingSelectedProvider }
        if let fallback {
            guard providers[fallback.provider] != nil else {
                throw SettingsTransferError.missingFallbackProvider(fallback.provider)
            }
            guard fallback.provider != selectedProvider else {
                throw SettingsTransferError.fallbackMatchesPrimary
            }
            guard fallback.afterSeconds.isFinite else {
                throw SettingsTransferError.invalidFallbackDelay
            }
        }
    }
}

/// The typography block of an imported profile, once every value in it has been validated.
///
/// A struct rather than the tuple it started as: six positional fields read as `.0` and `.4` at
/// the call site, and nobody can tell which is which. In the core because both Apple clients
/// validate the same block and then apply it in their own way.
public struct ImportedTypography: Sendable, Equatable {
    public var spacing: TypographySpacing
    public var script: ChineseScript
    /// What the example box should hold — already migrated from the legacy pair when the profile
    /// predates it, so an applying client has one string and no branch.
    public var example: String
    public var customRewrite: String
    public var translateTo: String

    public init(
        spacing: TypographySpacing, script: ChineseScript, example: String,
        customRewrite: String, translateTo: String
    ) {
        self.spacing = spacing
        self.script = script
        self.example = example
        self.customRewrite = customRewrite
        self.translateTo = translateTo
    }
}

/// Compact, versioned transport used only inside a QR code.
///
/// A full settings document can technically fit below QR's byte limit while producing such a
/// dense symbol that a phone camera cannot reliably resolve it from a laptop display. Deflate
/// removes the repeated JSON field names and Base64 keeps the result scanner-safe. Decoding still
/// accepts the original raw JSON so QR codes made by older releases remain importable.
public enum SettingsTransferQRCode {
    public static let prefix = "DNT1:"
    private static let maximumEnvelopeBytes = 16_384

    public static func encode(_ document: SettingsTransferDocument) throws -> String {
        let json = try document.encoded(prettyPrinted: false)
        let compressed = Data(referencing: try (json as NSData).compressed(using: .zlib))
        let base64URL = compressed.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return prefix + base64URL
    }

    public static func decode(_ value: String) throws -> SettingsTransferDocument {
        guard value.hasPrefix(prefix) else {
            return try SettingsTransferDocument.decode(value)
        }
        guard value.utf8.count <= maximumEnvelopeBytes else {
            throw SettingsTransferError.invalidJSON("The QR payload is too large.")
        }

        var base64 = String(value.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let compressed = Data(base64Encoded: base64) else {
            throw SettingsTransferError.invalidJSON("The QR payload is damaged.")
        }
        let json: Data
        do {
            json = Data(referencing: try (compressed as NSData).decompressed(using: .zlib))
        } catch {
            throw SettingsTransferError.invalidJSON("The QR payload is damaged.")
        }
        return try SettingsTransferDocument.decode(json)
    }
}

public enum SettingsTransferError: Error, LocalizedError, Equatable, Sendable {
    case tooLarge(maximumBytes: Int)
    case invalidUTF8
    case invalidJSON(String)
    case wrongFormat(String)
    case unsupportedVersion(Int)
    case missingSelectedProvider
    case missingFallbackProvider(String)
    case fallbackMatchesPrimary
    case invalidFallbackDelay

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let maximumBytes):
            "The settings file is larger than the \(maximumBytes / 1_048_576) MB limit."
        case .invalidUTF8:
            "The settings document is not valid UTF-8 text."
        case .invalidJSON(let detail):
            "This is not a valid DoNotType settings document: \(detail)"
        case .wrongFormat(let value):
            "This JSON has format “\(value)”, not DoNotType settings."
        case .unsupportedVersion(let version):
            "Settings format version \(version) is not supported by this version of DoNotType."
        case .missingSelectedProvider:
            "The selected provider is missing from the provider settings."
        case .missingFallbackProvider(let provider):
            "The fallback provider “\(provider)” is missing from the provider settings."
        case .fallbackMatchesPrimary:
            "The fallback provider cannot be the selected provider."
        case .invalidFallbackDelay:
            "The fallback delay is not a finite number."
        }
    }
}

/// A syntactically valid transfer can still name a value a particular client does not support.
public enum SettingsTransferApplyError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedValue(field: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedValue(let field, let value):
            "This version does not support “\(value)” for \(field)."
        }
    }
}
