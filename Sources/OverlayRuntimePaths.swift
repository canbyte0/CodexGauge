import Darwin
import Foundation

enum OverlayRuntimePaths {
    static let directoryNameInfoKey = "OverlayRuntimeDirectoryName"

    enum PathError: LocalizedError {
        case missingBundleIdentifier
        case missingDirectoryName
        case invalidComponent(String)
        case createFailed(path: String, reason: String)
        case notWritable(path: String)
        case pidFileAlreadyExists(path: String)
        case pidOwnershipMismatch(path: String)
        case pidWriteFailed(path: String, reason: String)
        case pidRemoveFailed(path: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .missingBundleIdentifier:
                return "The running bundle has no bundle identifier."
            case .missingDirectoryName:
                return "The candidate does not define OverlayRuntimeDirectoryName."
            case let .invalidComponent(value):
                return "Invalid runtime path component: \(value)"
            case let .createFailed(path, reason):
                return "Cannot create runtime directory at \(path): \(reason)"
            case let .notWritable(path):
                return "Runtime directory is not writable: \(path)"
            case let .pidFileAlreadyExists(path):
                return "A PID file already exists; refusing to replace it: \(path)"
            case let .pidOwnershipMismatch(path):
                return "PID file no longer belongs to this process: \(path)"
            case let .pidWriteFailed(path, reason):
                return "Cannot write PID file at \(path): \(reason)"
            case let .pidRemoveFailed(path, reason):
                return "Cannot remove PID file at \(path): \(reason)"
            }
        }
    }

    static func runtimeDirectory(for bundle: Bundle = .main) throws -> URL {
        try runtimeDirectory(
            bundleURL: bundle.bundleURL,
            bundleIdentifier: bundle.bundleIdentifier,
            directoryName: bundle.object(forInfoDictionaryKey: directoryNameInfoKey) as? String
        )
    }

    static func runtimeDirectory(
        bundleURL: URL,
        bundleIdentifier: String?,
        directoryName: String?,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            throw PathError.missingBundleIdentifier
        }
        guard let directoryName, !directoryName.isEmpty else {
            throw PathError.missingDirectoryName
        }
        guard isSinglePathComponent(bundleIdentifier), isSinglePathComponent(directoryName) else {
            throw PathError.invalidComponent("\(directoryName)/\(bundleIdentifier)")
        }

        let candidateDirectory = bundleURL.standardizedFileURL.deletingLastPathComponent()
        let revisionRoot = candidateDirectory.deletingLastPathComponent()
        let directory = revisionRoot
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch {
            throw PathError.createFailed(path: directory.path, reason: String(describing: error))
        }

        guard fileManager.isWritableFile(atPath: directory.path) else {
            throw PathError.notWritable(path: directory.path)
        }
        return directory
    }

    static func writePID(_ processIdentifier: Int32, to fileURL: URL) throws {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PathError.pidFileAlreadyExists(path: fileURL.path)
        }
        guard let data = "\(processIdentifier)\n".data(using: .utf8) else {
            throw PathError.pidWriteFailed(path: fileURL.path, reason: "PID encoding failed")
        }
        let temporaryURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).pid.tmp")
        do {
            try data.write(to: temporaryURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: temporaryURL.path
            )
            let linkResult = temporaryURL.path.withCString { source in
                fileURL.path.withCString { destination in Darwin.link(source, destination) }
            }
            guard linkResult == 0 else {
                let code = errno
                if code == EEXIST { throw PathError.pidFileAlreadyExists(path: fileURL.path) }
                throw PathError.pidWriteFailed(path: fileURL.path, reason: String(cString: strerror(code)))
            }
            do {
                try FileManager.default.removeItem(at: temporaryURL)
            } catch {
                _ = Darwin.unlink(fileURL.path)
                throw PathError.pidWriteFailed(path: fileURL.path, reason: String(describing: error))
            }
        } catch let error as PathError {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw PathError.pidWriteFailed(path: fileURL.path, reason: String(describing: error))
        }
    }

    @discardableResult
    static func removePID(_ processIdentifier: Int32, at fileURL: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        do {
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard contents == "\(processIdentifier)" else {
                throw PathError.pidOwnershipMismatch(path: fileURL.path)
            }
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch let error as PathError {
            throw error
        } catch {
            throw PathError.pidRemoveFailed(path: fileURL.path, reason: String(describing: error))
        }
    }

    private static func isSinglePathComponent(_ value: String) -> Bool {
        value != "." && value != ".." &&
            !value.contains("/") && !value.contains("\\") &&
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
