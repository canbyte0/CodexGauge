import CoreFoundation
import CryptoKit
import Darwin
import Foundation

struct QuotaHostIdentity: Equatable, Hashable {
    let bundleIdentifier: String
    let buildVersion: String
    let shortVersion: String
    let infoPlistSHA256: String

    static func read(from infoPlistURL: URL) throws -> Self {
        let data = try QuotaHostCompatibility.readBoundedFile(infoPlistURL)
        let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = propertyList as? [String: Any],
              let bundleIdentifier = dictionary["CFBundleIdentifier"] as? String,
              let buildVersion = dictionary["CFBundleVersion"] as? String,
              let shortVersion = dictionary["CFBundleShortVersionString"] as? String
        else { throw QuotaHostCompatibilityError.invalidHostInfoPlist }

        return Self(
            bundleIdentifier: bundleIdentifier,
            buildVersion: buildVersion,
            shortVersion: shortVersion,
            infoPlistSHA256: QuotaHostCompatibility.sha256(data)
        )
    }

    static func decode(_ data: Data) throws -> Self {
        let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = propertyList as? [String: Any],
              let bundleIdentifier = dictionary["CFBundleIdentifier"] as? String,
              let buildVersion = dictionary["CFBundleVersion"] as? String,
              let shortVersion = dictionary["CFBundleShortVersionString"] as? String
        else { throw QuotaHostCompatibilityError.invalidHostInfoPlist }

        return Self(
            bundleIdentifier: bundleIdentifier,
            buildVersion: buildVersion,
            shortVersion: shortVersion,
            infoPlistSHA256: QuotaHostCompatibility.sha256(data)
        )
    }
}

struct QuotaHostCompatibilityProfile: Equatable, Hashable {
    let bundleIdentifier: String
    let buildVersion: String
    let shortVersion: String
    let infoPlistSHA256: String

    init(bundleIdentifier: String, buildVersion: String, shortVersion: String, infoPlistSHA256: String) {
        self.bundleIdentifier = bundleIdentifier
        self.buildVersion = buildVersion
        self.shortVersion = shortVersion
        self.infoPlistSHA256 = infoPlistSHA256
    }

    init(identity: QuotaHostIdentity) {
        bundleIdentifier = identity.bundleIdentifier
        buildVersion = identity.buildVersion
        shortVersion = identity.shortVersion
        infoPlistSHA256 = identity.infoPlistSHA256
    }

    func matches(_ identity: QuotaHostIdentity) -> Bool {
        bundleIdentifier == identity.bundleIdentifier &&
            buildVersion == identity.buildVersion &&
            shortVersion == identity.shortVersion &&
            infoPlistSHA256 == identity.infoPlistSHA256
    }
}

struct QuotaHostCompatibilityConfiguration {
    enum Source: String {
        case bundledDefault
        case external
    }

    let profiles: [QuotaHostCompatibilityProfile]
    let source: Source

    func allows(_ identity: QuotaHostIdentity) -> Bool {
        profiles.contains { $0.matches(identity) }
    }
}

struct QuotaHostCompatibilityRegistration {
    enum Outcome: String {
        case added
        case updated
        case unchanged
    }

    let identity: QuotaHostIdentity
    let outcome: Outcome
    let initializedExternalFile: Bool
    let configuration: QuotaHostCompatibilityConfiguration
}

enum QuotaHostCompatibilityError: Error, CustomStringConvertible {
    case missingBundledDefault
    case unreadableConfiguration
    case invalidConfiguration(String)
    case oversizedFile
    case invalidHostInfoPlist

    var description: String {
        switch self {
        case .missingBundledDefault:
            return "The bundled host compatibility default is missing."
        case .unreadableConfiguration:
            return "The external host compatibility configuration could not be read."
        case .invalidConfiguration(let reason):
            return "Invalid host compatibility configuration: \(reason)"
        case .oversizedFile:
            return "The host compatibility file exceeds the size limit."
        case .invalidHostInfoPlist:
            return "The host Info.plist is missing required string identity fields."
        }
    }
}

enum QuotaHostCompatibility {
    static let schemaVersion = 1
    static let configurationFileName = "host-compatibility.json"
    static let bundledResourceName = "QuotaHostCompatibility"
    static let maximumConfigurationBytes = 65_536
    static let maximumInfoPlistBytes = 4_194_304
    static let targetBundleIdentifier = "com.openai.codex"

    private static let configurationKeys: Set<String> = ["schemaVersion", "profiles"]
    private static let profileKeys: Set<String> = [
        "bundleIdentifier", "buildVersion", "shortVersion", "infoPlistSHA256"
    ]

    static func appSupportURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("CodexGauge", isDirectory: true)
            .appendingPathComponent(configurationFileName, isDirectory: false)
    }

    static func loadForApplication(bundle: Bundle = .main) throws -> QuotaHostCompatibilityConfiguration {
        let bundledURL = try bundledDefaultURL(bundle: bundle)
        return try load(
            externalConfigURL: appSupportURL(),
            bundledDefaultURL: bundledURL
        )
    }

    static func prepareForApplicationLaunch(
        hostInfoPlistURL: URL,
        bundle: Bundle = .main
    ) throws -> QuotaHostCompatibilityRegistration {
        try prepareCurrentHost(
            hostInfoPlistURL: hostInfoPlistURL,
            externalConfigURL: appSupportURL(),
            bundledDefaultURL: bundledDefaultURL(bundle: bundle)
        )
    }

    static func prepareCurrentHost(
        hostInfoPlistURL: URL,
        externalConfigURL: URL,
        bundledDefaultURL: URL,
        fileManager: FileManager = .default,
        writer: ((Data, URL) throws -> Void)? = nil
    ) throws -> QuotaHostCompatibilityRegistration {
        let identity = try QuotaHostIdentity.read(from: hostInfoPlistURL)
        guard identity.bundleIdentifier == targetBundleIdentifier,
              isValidBuildVersion(identity.buildVersion),
              isValidShortVersion(identity.shortVersion),
              isLowercaseSHA256(identity.infoPlistSHA256)
        else { throw QuotaHostCompatibilityError.invalidHostInfoPlist }

        let initial = try load(
            externalConfigURL: externalConfigURL,
            bundledDefaultURL: bundledDefaultURL,
            fileManager: fileManager
        )
        var profiles = initial.profiles
        let currentProfile = QuotaHostCompatibilityProfile(identity: identity)
        let matchingIndex = profiles.firstIndex {
            $0.bundleIdentifier == identity.bundleIdentifier &&
                $0.buildVersion == identity.buildVersion &&
                $0.shortVersion == identity.shortVersion
        }

        let outcome: QuotaHostCompatibilityRegistration.Outcome
        if let matchingIndex {
            if profiles[matchingIndex] == currentProfile {
                outcome = .unchanged
            } else {
                profiles[matchingIndex] = currentProfile
                outcome = .updated
            }
        } else {
            profiles.append(currentProfile)
            outcome = .added
        }

        let initializedExternalFile = initial.source == .bundledDefault
        if initializedExternalFile || outcome != .unchanged {
            let data = try encodeConfiguration(profiles: profiles)
            _ = try decodeProfiles(from: data)
            if let writer {
                try writer(data, externalConfigURL)
            } else {
                try writeAtomically(data, to: externalConfigURL)
            }
        }

        let reloaded = try load(
            externalConfigURL: externalConfigURL,
            bundledDefaultURL: bundledDefaultURL,
            fileManager: fileManager
        )
        guard reloaded.source == .external, reloaded.allows(identity) else {
            throw QuotaHostCompatibilityError.invalidConfiguration("registered identity was not present after reload")
        }
        return QuotaHostCompatibilityRegistration(
            identity: identity,
            outcome: outcome,
            initializedExternalFile: initializedExternalFile,
            configuration: reloaded
        )
    }

    static func load(
        externalConfigURL: URL,
        bundledDefaultURL: URL,
        fileManager: FileManager = .default
    ) throws -> QuotaHostCompatibilityConfiguration {
        let siblingNames: [String]
        do {
            siblingNames = try fileManager.contentsOfDirectory(
                atPath: externalConfigURL.deletingLastPathComponent().path
            )
        } catch {
            guard isMissingPath(error) else { throw QuotaHostCompatibilityError.unreadableConfiguration }
            siblingNames = []
        }
        if siblingNames.contains(externalConfigURL.lastPathComponent) {
            let data = try readBoundedFile(externalConfigURL, maximumBytes: maximumConfigurationBytes)
            return QuotaHostCompatibilityConfiguration(
                profiles: try decodeProfiles(from: data), source: .external
            )
        }

        let bundledData: Data
        do {
            bundledData = try readBoundedFile(bundledDefaultURL, maximumBytes: maximumConfigurationBytes)
        } catch {
            throw QuotaHostCompatibilityError.missingBundledDefault
        }
        return QuotaHostCompatibilityConfiguration(
            profiles: try decodeProfiles(from: bundledData), source: .bundledDefault
        )
    }

    static func decodeProfiles(from data: Data) throws -> [QuotaHostCompatibilityProfile] {
        guard !data.isEmpty else { throw QuotaHostCompatibilityError.invalidConfiguration("empty file") }
        guard data.count <= maximumConfigurationBytes else { throw QuotaHostCompatibilityError.oversizedFile }

        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw QuotaHostCompatibilityError.invalidConfiguration("malformed JSON")
        }

        guard let root = value as? [String: Any], Set(root.keys) == configurationKeys else {
            throw QuotaHostCompatibilityError.invalidConfiguration("expected only schemaVersion and profiles")
        }
        guard let schema = root["schemaVersion"] as? NSNumber,
              CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.stringValue == String(schemaVersion)
        else { throw QuotaHostCompatibilityError.invalidConfiguration("unsupported schemaVersion") }
        guard let rawProfiles = root["profiles"] as? [Any], !rawProfiles.isEmpty else {
            throw QuotaHostCompatibilityError.invalidConfiguration("profiles must be a nonempty array")
        }

        var profiles: [QuotaHostCompatibilityProfile] = []
        var identities: Set<String> = []
        for rawProfile in rawProfiles {
            guard let dictionary = rawProfile as? [String: Any], Set(dictionary.keys) == profileKeys,
                  let bundleIdentifier = dictionary["bundleIdentifier"] as? String,
                  let buildVersion = dictionary["buildVersion"] as? String,
                  let shortVersion = dictionary["shortVersion"] as? String,
                  let infoPlistSHA256 = dictionary["infoPlistSHA256"] as? String
            else { throw QuotaHostCompatibilityError.invalidConfiguration("profile fields are incomplete or unknown") }

            guard bundleIdentifier == targetBundleIdentifier else {
                throw QuotaHostCompatibilityError.invalidConfiguration("unsupported bundleIdentifier")
            }
            guard isValidBuildVersion(buildVersion), isValidShortVersion(shortVersion),
                  isLowercaseSHA256(infoPlistSHA256)
            else { throw QuotaHostCompatibilityError.invalidConfiguration("invalid profile identity") }

            let identityKey = "\(bundleIdentifier)\u{0}\(buildVersion)\u{0}\(shortVersion)"
            guard identities.insert(identityKey).inserted else {
                throw QuotaHostCompatibilityError.invalidConfiguration("duplicate or ambiguous version entry")
            }
            profiles.append(QuotaHostCompatibilityProfile(
                bundleIdentifier: bundleIdentifier,
                buildVersion: buildVersion,
                shortVersion: shortVersion,
                infoPlistSHA256: infoPlistSHA256
            ))
        }
        return profiles
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func readBoundedFile(_ url: URL, maximumBytes: Int? = nil) throws -> Data {
        let limit = maximumBytes ?? maximumInfoPlistBytes
        var metadata = Darwin.stat()
        let status = url.path.withCString { Darwin.lstat($0, &metadata) }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw QuotaHostCompatibilityError.unreadableConfiguration
        }
        if metadata.st_size > off_t(limit) { throw QuotaHostCompatibilityError.oversizedFile }
        let data = try Data(contentsOf: url, options: [])
        guard data.count <= limit else { throw QuotaHostCompatibilityError.oversizedFile }
        return data
    }

    private static func bundledDefaultURL(bundle: Bundle) throws -> URL {
        guard let rawSchema = bundle.object(forInfoDictionaryKey: "QuotaHostCompatibilitySchemaVersion") as? NSNumber,
              CFGetTypeID(rawSchema) != CFBooleanGetTypeID(), rawSchema.stringValue == String(schemaVersion)
        else {
            throw QuotaHostCompatibilityError.invalidConfiguration("unsupported bundled schema metadata")
        }
        guard let bundledURL = bundle.url(forResource: bundledResourceName, withExtension: "json") else {
            throw QuotaHostCompatibilityError.missingBundledDefault
        }
        return bundledURL
    }

    private static func encodeConfiguration(profiles: [QuotaHostCompatibilityProfile]) throws -> Data {
        let rows = profiles.map { profile in
            [
                "bundleIdentifier": profile.bundleIdentifier,
                "buildVersion": profile.buildVersion,
                "shortVersion": profile.shortVersion,
                "infoPlistSHA256": profile.infoPlistSHA256
            ]
        }
        let json = try JSONSerialization.data(
            withJSONObject: ["schemaVersion": schemaVersion, "profiles": rows],
            options: [.prettyPrinted, .sortedKeys]
        )
        var data = json
        data.append(0x0A)
        return data
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let directoryURL = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )

        var directoryMetadata = Darwin.stat()
        let directoryStatus = directoryURL.path.withCString { Darwin.lstat($0, &directoryMetadata) }
        guard directoryStatus == 0,
              (directoryMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
        else {
            if directoryStatus != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            throw QuotaHostCompatibilityError.unreadableConfiguration
        }

        var existingMetadata = Darwin.stat()
        let existingStatus = url.path.withCString { Darwin.lstat($0, &existingMetadata) }
        if existingStatus == 0 {
            guard (existingMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
                throw QuotaHostCompatibilityError.unreadableConfiguration
            }
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var descriptorIsOpen = true
        var temporaryFileExists = true
        defer {
            if descriptorIsOpen { _ = Darwin.close(descriptor) }
            if temporaryFileExists { _ = temporaryURL.path.withCString { Darwin.unlink($0) } }
        }

        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var offset = 0
        while offset < data.count {
            let amount = data.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return Darwin.write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
            }
            if amount < 0, errno == EINTR { continue }
            guard amount > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            offset += amount
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let closeStatus = Darwin.close(descriptor)
        descriptorIsOpen = false
        guard closeStatus == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        let renameStatus = temporaryURL.path.withCString { sourcePath in
            url.path.withCString { destinationPath in Darwin.rename(sourcePath, destinationPath) }
        }
        guard renameStatus == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        temporaryFileExists = false
    }

    private static func isMissingPath(_ error: Error) -> Bool {
        if let cocoaError = error as? CocoaError, cocoaError.code == .fileReadNoSuchFile {
            return true
        }
        if let posixError = error as? POSIXError, posixError.code == .ENOENT {
            return true
        }
        let underlying = error as NSError
        return underlying.domain == NSPOSIXErrorDomain && underlying.code == POSIXErrorCode.ENOENT.rawValue
    }

    private static func isValidBuildVersion(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    private static func isValidShortVersion(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return !components.isEmpty && components.count <= 8 && value.utf8.count <= 128 &&
            components.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}
