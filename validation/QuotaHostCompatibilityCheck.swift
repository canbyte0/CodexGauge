import Foundation

@main
enum QuotaHostCompatibilityCheck {
    private static var checks: [String] = []

    private static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("FAIL \(name)") }
        checks.append(name)
        print("PASS \(name)")
    }

    private static func rejects(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            fatalError("FAIL \(name)-was-accepted")
        } catch is QuotaHostCompatibilityError {
            checks.append(name)
            print("PASS \(name)")
        } catch {
            checks.append(name)
            print("PASS \(name)-rejected-\(error)")
        }
    }

    private static func writeConfig(_ profiles: [[String: Any]], schema: Any = 1,
                                    extraRoot: [String: Any] = [:]) throws -> Data {
        var root: [String: Any] = ["schemaVersion": schema, "profiles": profiles]
        for (key, value) in extraRoot { root[key] = value }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func profile(_ identity: QuotaHostIdentity, extra: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = [
            "bundleIdentifier": identity.bundleIdentifier,
            "buildVersion": identity.buildVersion,
            "shortVersion": identity.shortVersion,
            "infoPlistSHA256": identity.infoPlistSHA256
        ]
        for (key, item) in extra { value[key] = item }
        return value
    }

    private static func hostInfoPlist(
        build: String,
        version: String,
        bundleIdentifier: String = QuotaHostCompatibility.targetBundleIdentifier,
        additionalFields: [String: Any] = [:]
    ) throws -> Data {
        var values: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleVersion": build,
            "CFBundleShortVersionString": version
        ]
        for (key, value) in additionalFields { values[key] = value }
        return try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }

    private enum InjectedWriteFailure: Error { case denied }

    private static func task112(bundledURL: URL, resultURL: URL) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("codexgauge-task112-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let bundledProfiles = try QuotaHostCompatibility.decodeProfiles(from: Data(contentsOf: bundledURL))
        let historical = bundledProfiles[0]
        let historicalIdentity = QuotaHostIdentity(
            bundleIdentifier: historical.bundleIdentifier,
            buildVersion: historical.buildVersion,
            shortVersion: historical.shortVersion,
            infoPlistSHA256: historical.infoPlistSHA256
        )
        let hostDirectory = root.appendingPathComponent("host/Contents", isDirectory: true)
        try fileManager.createDirectory(at: hostDirectory, withIntermediateDirectories: true)
        let hostPlistURL = hostDirectory.appendingPathComponent("Info.plist")
        let hostData = try hostInfoPlist(build: "90001", version: "27.4.2")
        try hostData.write(to: hostPlistURL)
        let newIdentity = try QuotaHostIdentity.read(from: hostPlistURL)
        let externalURL = root.appendingPathComponent("Application Support/CodexGauge/host-compatibility.json")

        let first = try QuotaHostCompatibility.prepareCurrentHost(
            hostInfoPlistURL: hostPlistURL,
            externalConfigURL: externalURL,
            bundledDefaultURL: bundledURL
        )
        check(first.outcome == .added && first.initializedExternalFile,
              "first-open-initializes-external-config-and-adds-current-host")
        check(first.configuration.source == .external && first.configuration.allows(newIdentity) &&
              first.configuration.allows(historicalIdentity) && first.configuration.profiles.count == 2,
              "reload-allows-new-host-and-preserves-bundled-history")
        let firstBytes = try Data(contentsOf: externalURL)
        var idempotentWriterCalls = 0
        let repeated = try QuotaHostCompatibility.prepareCurrentHost(
            hostInfoPlistURL: hostPlistURL,
            externalConfigURL: externalURL,
            bundledDefaultURL: bundledURL,
            writer: { _, _ in idempotentWriterCalls += 1 }
        )
        let repeatedBytes = try Data(contentsOf: externalURL)
        check(repeated.outcome == .unchanged && !repeated.initializedExternalFile &&
              idempotentWriterCalls == 0 && repeatedBytes == firstBytes,
              "same-host-open-is-idempotent-and-does-not-write")

        let changedHostData = try hostInfoPlist(
            build: newIdentity.buildVersion,
            version: newIdentity.shortVersion,
            additionalFields: ["CFBundleDisplayName": "Synthetic Codex B"]
        )
        try changedHostData.write(to: hostPlistURL)
        let changedIdentity = try QuotaHostIdentity.read(from: hostPlistURL)
        let updated = try QuotaHostCompatibility.prepareCurrentHost(
            hostInfoPlistURL: hostPlistURL,
            externalConfigURL: externalURL,
            bundledDefaultURL: bundledURL
        )
        let updatedEntries = updated.configuration.profiles.filter {
            $0.bundleIdentifier == changedIdentity.bundleIdentifier &&
                $0.buildVersion == changedIdentity.buildVersion &&
                $0.shortVersion == changedIdentity.shortVersion
        }
        check(updated.outcome == .updated && updated.configuration.allows(changedIdentity) &&
              !updated.configuration.allows(newIdentity),
              "same-version-different-plist-hash-updates-current-entry")
        check(updatedEntries.count == 1 && updated.configuration.profiles.count == 2 &&
              updated.configuration.allows(historicalIdentity),
              "hash-update-does-not-duplicate-or-remove-history")

        var crowdedProfiles: [[String: Any]] = []
        var crowdedBytes = try writeConfig([])
        for index in 1...1_000 {
            let fillerIdentity = QuotaHostIdentity(
                bundleIdentifier: QuotaHostCompatibility.targetBundleIdentifier,
                buildVersion: String(100_000 + index),
                shortVersion: "1",
                infoPlistSHA256: String(repeating: "0", count: 64)
            )
            crowdedProfiles.append(profile(fillerIdentity))
            let candidateBytes = try writeConfig(crowdedProfiles)
            if candidateBytes.count >= QuotaHostCompatibility.maximumConfigurationBytes - 256,
               candidateBytes.count < QuotaHostCompatibility.maximumConfigurationBytes {
                crowdedBytes = candidateBytes
                break
            }
        }
        let expandedCrowdedBytes = try writeConfig(crowdedProfiles + [profile(changedIdentity)])
        check(crowdedBytes.count >= QuotaHostCompatibility.maximumConfigurationBytes - 256 &&
              crowdedBytes.count < QuotaHostCompatibility.maximumConfigurationBytes &&
              expandedCrowdedBytes.count > QuotaHostCompatibility.maximumConfigurationBytes,
              "oversize-fixture-is-valid-before-current-host-addition")
        let crowdedURL = root.appendingPathComponent("crowded/host-compatibility.json")
        try fileManager.createDirectory(at: crowdedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try crowdedBytes.write(to: crowdedURL)
        do {
            _ = try QuotaHostCompatibility.prepareCurrentHost(
                hostInfoPlistURL: hostPlistURL,
                externalConfigURL: crowdedURL,
                bundledDefaultURL: bundledURL
            )
            fatalError("FAIL oversized-result-was-written")
        } catch is QuotaHostCompatibilityError {
            checks.append("oversized-result-rejected-before-write")
        }
        let afterCrowdedAttempt = try Data(contentsOf: crowdedURL)
        check(afterCrowdedAttempt == crowdedBytes,
              "oversized-registration-preserves-existing-valid-config")

        let invalidHostURL = root.appendingPathComponent("invalid-host/Contents/Info.plist")
        try fileManager.createDirectory(at: invalidHostURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try hostInfoPlist(build: "90002", version: "27.4.3", bundleIdentifier: "com.other.app")
            .write(to: invalidHostURL)
        let beforeInvalidID = try Data(contentsOf: externalURL)
        do {
            _ = try QuotaHostCompatibility.prepareCurrentHost(
                hostInfoPlistURL: invalidHostURL,
                externalConfigURL: externalURL,
                bundledDefaultURL: bundledURL
            )
            fatalError("FAIL wrong-host-bundle-id-was-accepted")
        } catch is QuotaHostCompatibilityError {
            checks.append("wrong-host-bundle-id-rejected")
        }
        let afterInvalidID = try Data(contentsOf: externalURL)
        check(afterInvalidID == beforeInvalidID,
              "wrong-host-bundle-id-does-not-modify-config")

        let malformedURL = root.appendingPathComponent("malformed/host-compatibility.json")
        try fileManager.createDirectory(at: malformedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let malformedBytes = Data("{bad".utf8)
        try malformedBytes.write(to: malformedURL)
        do {
            _ = try QuotaHostCompatibility.prepareCurrentHost(
                hostInfoPlistURL: hostPlistURL,
                externalConfigURL: malformedURL,
                bundledDefaultURL: bundledURL
            )
            fatalError("FAIL malformed-external-config-was-accepted")
        } catch is QuotaHostCompatibilityError {
            checks.append("malformed-external-config-rejected")
        }
        let afterMalformed = try Data(contentsOf: malformedURL)
        check(afterMalformed == malformedBytes,
              "malformed-external-config-is-not-overwritten")

        let writeFailureURL = root.appendingPathComponent("write-failure/host-compatibility.json")
        try fileManager.createDirectory(at: writeFailureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oldConfigBytes = try Data(contentsOf: bundledURL)
        try oldConfigBytes.write(to: writeFailureURL)
        do {
            _ = try QuotaHostCompatibility.prepareCurrentHost(
                hostInfoPlistURL: hostPlistURL,
                externalConfigURL: writeFailureURL,
                bundledDefaultURL: bundledURL,
                writer: { _, _ in throw InjectedWriteFailure.denied }
            )
            fatalError("FAIL injected-config-write-failure-was-ignored")
        } catch is InjectedWriteFailure {
            checks.append("config-write-failure-rejected")
        }
        let afterWriteFailure = try Data(contentsOf: writeFailureURL)
        check(afterWriteFailure == oldConfigBytes,
              "config-write-failure-does-not-overwrite-existing-config")
        let afterFailure = try QuotaHostCompatibility.load(
            externalConfigURL: writeFailureURL,
            bundledDefaultURL: bundledURL
        )
        check(!afterFailure.allows(newIdentity) && afterFailure.allows(historicalIdentity),
              "failed-write-does-not-claim-new-host-is-allowed")

        let output: [String: Any] = [
            "status": "PASS",
            "assertions": checks.count,
            "checks": checks,
            "syntheticHost": [
                "bundleIdentifier": newIdentity.bundleIdentifier,
                "buildVersion": newIdentity.buildVersion,
                "shortVersion": newIdentity.shortVersion,
                "infoPlistSHA256": newIdentity.infoPlistSHA256
            ],
            "scope": "Task 112 registration lifecycle helper only; temporary host/config paths and injected write failure; no real Application Support or app launch."
        ]
        try fileManager.createDirectory(at: resultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let outputData = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        try outputData.write(to: resultURL)
        print("PASS \(checks.count) task112 compatibility registration checks")
    }

    private static func hash(_ url: URL) throws -> String {
        QuotaHostCompatibility.sha256(try Data(contentsOf: url))
    }

    static func main() throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--task112" {
            try task112(
                bundledURL: URL(fileURLWithPath: CommandLine.arguments[2]),
                resultURL: URL(fileURLWithPath: CommandLine.arguments[3])
            )
            return
        }
        guard CommandLine.arguments.count == 4 else {
            fatalError("usage: check <bundled-json> <result-json> <production-executable> | check --task112 <bundled-json> <result-json>")
        }
        let bundledURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let resultURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let productionExecutable = URL(fileURLWithPath: CommandLine.arguments[3])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexgauge-task111-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let bundledData = try Data(contentsOf: bundledURL)
        let bundledProfiles = try QuotaHostCompatibility.decodeProfiles(from: bundledData)
        check(bundledProfiles.count == 1 &&
              bundledProfiles[0].bundleIdentifier == QuotaHostCompatibility.targetBundleIdentifier &&
              bundledProfiles[0].buildVersion == "25241" &&
              bundledProfiles[0].shortVersion == "26.1103.31037",
              "bundled-default-is-current-profile")

        let syntheticPlist = try hostInfoPlist(build: "90001", version: "27.4.2")
        let futureIdentity = try QuotaHostIdentity.decode(syntheticPlist)
        let defaultCurrent = bundledProfiles[0]
        let defaultIdentity = QuotaHostIdentity(
            bundleIdentifier: defaultCurrent.bundleIdentifier,
            buildVersion: defaultCurrent.buildVersion,
            shortVersion: defaultCurrent.shortVersion,
            infoPlistSHA256: defaultCurrent.infoPlistSHA256
        )
        let externalURL = root.appendingPathComponent("missing-parent/CodexGauge/host-compatibility.json")
        let fallback = try QuotaHostCompatibility.load(
            externalConfigURL: externalURL, bundledDefaultURL: bundledURL
        )
        check(fallback.source == .bundledDefault && fallback.allows(defaultIdentity) &&
              !fallback.allows(futureIdentity), "missing-parent-falls-back-and-unapproved-future-is-denied")

        let configDirectory = root.appendingPathComponent("external", isDirectory: true)
        try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let configURL = configDirectory.appendingPathComponent(QuotaHostCompatibility.configurationFileName)
        try writeConfig([profile(futureIdentity)]).write(to: configURL)
        let override = try QuotaHostCompatibility.load(externalConfigURL: configURL, bundledDefaultURL: bundledURL)
        check(override.source == .external && override.allows(futureIdentity) &&
              !override.allows(defaultIdentity), "valid-external-config-authoritatively-replaces-default")

        for (name, data) in [
            ("empty-config-rejected", Data()),
            ("malformed-json-rejected", Data("{".utf8)),
            ("unknown-schema-rejected", try writeConfig([profile(futureIdentity)], schema: 2)),
            ("boolean-schema-rejected", try writeConfig([profile(futureIdentity)], schema: true)),
            ("unknown-root-field-rejected", try writeConfig([profile(futureIdentity)], extraRoot: ["coordinates": [:]])),
            ("empty-profiles-rejected", try writeConfig([])),
            ("unknown-profile-field-rejected", try writeConfig([profile(futureIdentity, extra: ["cliPath": "/tmp/cli"])])),
            ("duplicate-profile-rejected", try writeConfig([profile(futureIdentity), profile(futureIdentity)])),
            ("bad-build-rejected", try writeConfig([profile(futureIdentity, extra: ["buildVersion": "9x"])])),
            ("bad-short-version-rejected", try writeConfig([profile(futureIdentity, extra: ["shortVersion": "27..2"])])),
            ("uppercase-hash-rejected", try writeConfig([profile(futureIdentity, extra: ["infoPlistSHA256": futureIdentity.infoPlistSHA256.uppercased()])])),
            ("oversized-config-rejected", Data(repeating: 0x20, count: QuotaHostCompatibility.maximumConfigurationBytes + 1))
        ] {
            try data.write(to: configURL)
            rejects(name) {
                _ = try QuotaHostCompatibility.load(externalConfigURL: configURL, bundledDefaultURL: bundledURL)
            }
        }

        try fileManager.removeItem(at: configURL)
        try fileManager.createDirectory(at: configURL, withIntermediateDirectories: false)
        rejects("external-directory-rejected") {
            _ = try QuotaHostCompatibility.load(externalConfigURL: configURL, bundledDefaultURL: bundledURL)
        }
        try fileManager.removeItem(at: configURL)
        let brokenTarget = root.appendingPathComponent("missing-target")
        try fileManager.createSymbolicLink(at: configURL, withDestinationURL: brokenTarget)
        rejects("broken-symlink-does-not-fall-back") {
            _ = try QuotaHostCompatibility.load(externalConfigURL: configURL, bundledDefaultURL: bundledURL)
        }

        try fileManager.removeItem(at: configURL)
        let matched = QuotaHostCompatibilityConfiguration(
            profiles: [QuotaHostCompatibilityProfile(identity: futureIdentity)], source: .external
        )
        check(matched.allows(futureIdentity), "all-four-identity-fields-match")
        check(!matched.allows(QuotaHostIdentity(bundleIdentifier: "com.other.app", buildVersion: futureIdentity.buildVersion,
                                                shortVersion: futureIdentity.shortVersion, infoPlistSHA256: futureIdentity.infoPlistSHA256)),
              "bundle-identifier-mismatch-denied")
        check(!matched.allows(QuotaHostIdentity(bundleIdentifier: futureIdentity.bundleIdentifier, buildVersion: "90002",
                                                shortVersion: futureIdentity.shortVersion, infoPlistSHA256: futureIdentity.infoPlistSHA256)),
              "build-version-mismatch-denied")
        check(!matched.allows(QuotaHostIdentity(bundleIdentifier: futureIdentity.bundleIdentifier, buildVersion: futureIdentity.buildVersion,
                                                shortVersion: "27.4.3", infoPlistSHA256: futureIdentity.infoPlistSHA256)),
              "short-version-mismatch-denied")
        check(!matched.allows(QuotaHostIdentity(bundleIdentifier: futureIdentity.bundleIdentifier, buildVersion: futureIdentity.buildVersion,
                                                shortVersion: futureIdentity.shortVersion, infoPlistSHA256: String(repeating: "0", count: 64))),
              "info-plist-hash-mismatch-denied")

        try writeConfig([profile(defaultIdentity)]).write(to: configURL)
        let oldSnapshot = try QuotaHostCompatibility.load(externalConfigURL: configURL, bundledDefaultURL: bundledURL)
        let binaryHashBefore = try hash(productionExecutable)
        try writeConfig([profile(futureIdentity)]).write(to: configURL)
        let newSnapshot = try QuotaHostCompatibility.load(externalConfigURL: configURL, bundledDefaultURL: bundledURL)
        let binaryHashAfter = try hash(productionExecutable)
        check(oldSnapshot.allows(defaultIdentity) && !oldSnapshot.allows(futureIdentity),
              "loaded-snapshot-remains-stable-until-restart")
        check(!oldSnapshot.allows(futureIdentity) && newSnapshot.allows(futureIdentity),
              "same-compatibility-api-allows-new-profile-after-config-only-update")
        check(binaryHashBefore == binaryHashAfter, "external-config-update-does-not-change-built-app-binary")

        let result: [String: Any] = [
            "status": "PASS",
            "assertions": checks.count,
            "checks": checks,
            "futureFixture": [
                "bundleIdentifier": futureIdentity.bundleIdentifier,
                "buildVersion": futureIdentity.buildVersion,
                "shortVersion": futureIdentity.shortVersion,
                "infoPlistSHA256": futureIdentity.infoPlistSHA256
            ],
            "builtAppBinarySHA256BeforeAndAfter": binaryHashBefore,
            "scope": "Pure Foundation/CryptoKit compatibility loader; synthetic plist and temporary config only; no real Application Support, host windows, app launch or CLI."
        ]
        try fileManager.createDirectory(at: resultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let output = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: resultURL)
        print("PASS \(checks.count) task111 compatibility checks")
    }
}
