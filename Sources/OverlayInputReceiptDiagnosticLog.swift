import Foundation

enum OverlayInputReceiptComponent: String {
    case host
    case overlay
}

enum OverlayInputReceiptEvent: String {
    case processStarted
    case windowRegistered
    case windowUnregistered
    case localMonitorInstalled
    case localMonitorUnavailable
    case localMouseReceipt
    case transactionStarted
    case overlayLocalMonitorInstalled
    case overlayLocalMonitorUnavailable
    case overlayLocalMouseReceipt
    case globalCallbackEntry
    case globalTaskScheduled
    case globalTaskEntered
    case globalGuardOutcome
    case globalTaskOwnerUnavailable
    case monitorRemoved
    case processTerminating
    case transactionEnded
    case budgetExhausted
}

enum OverlayInputReceiptStream: String, Hashable {
    case hostMouse
    case overlayLocalMouse
    case overlayGlobal
    case overlayTask
    case overlayGuard
}

enum OverlayInputReceiptRole: String {
    case host
    case overlay
    case other
    case unknown
}

enum OverlayInputReceiptGuard: String {
    case passed
    case staleContext
    case detailsHidden
    case missingContext
}

enum OverlayInputReceiptReason: String {
    case setupFailed
    case windowRemoved
    case noManagedWindows
    case applicationTerminating
    case transactionClosed
    case transactionReplaced
    case transactionCancelled
    case streamBudgetExhausted
    case recordBudgetExhausted
}

enum OverlayInputReceiptDiagnosticGate {
    static func isEnabled(bundleIdentifier: String?, expectedBundleIdentifier: String, explicitFlag: Bool) -> Bool {
        bundleIdentifier == expectedBundleIdentifier && explicitFlag
    }
}

/// A bounded, append-only diagnostic sink. Its API accepts only project identities,
/// categories, Booleans, timestamps and coordinates; it cannot serialize NSEvent text
/// or arbitrary process/window descriptions.
final class OverlayInputReceiptDiagnosticLog {
    private static let sharedAppendLock = NSLock()
    private let lock = NSLock()
    private let fileURL: URL
    private let component: OverlayInputReceiptComponent
    private let processID: Int32
    private let maximumRecords: Int
    private let maximumPerStream = 4
    private var totalRecords = 0
    private var nextSequence = 0
    private var streamCounts: [OverlayInputReceiptStream: Int] = [:]
    private var pendingTraces: Set<Int> = []
    private var isFinished = false
    private var isDisabled = false
    private var didLogFailure = false

    init(
        runtimeDirectory: URL,
        fileName: String,
        component: OverlayInputReceiptComponent,
        processID: Int32,
        maximumRecords: Int,
        enabled: Bool = true
    ) {
        self.fileURL = runtimeDirectory.appendingPathComponent(fileName, isDirectory: false)
        self.component = component
        self.processID = processID
        self.maximumRecords = max(2, maximumRecords)
        self.isDisabled = !enabled
    }

    var destinationURL: URL { fileURL }

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isDisabled
    }

    func isStreamOpen(_ stream: OverlayInputReceiptStream) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isDisabled && streamCounts[stream, default: 0] < maximumPerStream
    }

    /// Completes in-memory trace ownership even when a record stream is saturated.
    /// Accepted traces are bounded by the global-entry stream budget.
    func completeTrace(_ traceID: Int) {
        lock.lock()
        defer { lock.unlock() }
        pendingTraces.remove(traceID)
        if isFinished && pendingTraces.isEmpty { isDisabled = true }
    }

    /// Returns this record's sequence number. For global callback-entry records it
    /// also becomes a local trace token, not an operating-system event identifier.
    @discardableResult
    func record(
        _ event: OverlayInputReceiptEvent,
        stream: OverlayInputReceiptStream? = nil,
        contextID: UUID? = nil,
        clickID: UUID? = nil,
        displayID: UUID? = nil,
        traceID: Int? = nil,
        hostPID: Int32? = nil,
        hostWindowID: Int? = nil,
        observedWindowID: Int? = nil,
        targetRole: OverlayInputReceiptRole? = nil,
        targetPIDFieldPresent: Bool? = nil,
        targetWindowFieldPresent: Bool? = nil,
        targetHostProcessMatched: Bool? = nil,
        targetHostWindowMatched: Bool? = nil,
        targetOverlayProcessMatched: Bool? = nil,
        contextMatched: Bool? = nil,
        detailsVisible: Bool? = nil,
        guardOutcome: OverlayInputReceiptGuard? = nil,
        eventTimestamp: Double? = nil,
        windowX: Double? = nil,
        windowY: Double? = nil,
        globalX: Double? = nil,
        globalY: Double? = nil,
        reason: OverlayInputReceiptReason? = nil
    ) -> Int? {
        lock.lock()
        defer { lock.unlock() }

        let isPendingCompletion = traceID.map(pendingTraces.contains) == true &&
            (event == .globalTaskScheduled || event == .globalTaskEntered || event == .globalGuardOutcome || event == .globalTaskOwnerUnavailable)
        guard !isDisabled, !isFinished || isPendingCompletion else { return nil }

        if let stream, streamCounts[stream, default: 0] >= maximumPerStream {
            return nil
        }
        guard totalRecords < maximumRecords - 1 else {
            appendBudgetExhaustedLocked(contextID: contextID, stream: stream)
            isDisabled = true
            return nil
        }

        let sequence = nextSequence
        nextSequence += 1
        var fields = baseFields(event: event, sequence: sequence, contextID: contextID, traceID: traceID)
        let targetIdentityIsRedacted = targetRole == .other || targetRole == .unknown
        if let clickID { fields["clickID"] = clickID.uuidString }
        if let displayID { fields["displayID"] = displayID.uuidString }
        if let stream {
            fields["stream"] = stream.rawValue
            let countAfter = streamCounts[stream, default: 0] + 1
            fields["streamBudgetExhausted"] = countAfter == maximumPerStream
        }
        if let hostPID { fields["hostPID"] = Int(hostPID) }
        if let hostWindowID { fields["hostWindowID"] = hostWindowID }
        if let observedWindowID, !targetIdentityIsRedacted { fields["observedWindowID"] = observedWindowID }
        if let targetRole { fields["targetRole"] = targetRole.rawValue }
        if let targetPIDFieldPresent { fields["targetPIDFieldPresent"] = targetPIDFieldPresent }
        if let targetWindowFieldPresent { fields["targetWindowFieldPresent"] = targetWindowFieldPresent }
        if let targetHostProcessMatched { fields["targetHostProcessMatched"] = targetHostProcessMatched }
        if let targetHostWindowMatched { fields["targetHostWindowMatched"] = targetHostWindowMatched }
        if let targetOverlayProcessMatched { fields["targetOverlayProcessMatched"] = targetOverlayProcessMatched }
        if let contextMatched { fields["contextMatched"] = contextMatched }
        if let detailsVisible { fields["detailsVisible"] = detailsVisible }
        if let guardOutcome { fields["guardOutcome"] = guardOutcome.rawValue }
        if let eventTimestamp { fields["eventTimestamp"] = eventTimestamp }
        if let windowX, !targetIdentityIsRedacted { fields["windowX"] = windowX }
        if let windowY, !targetIdentityIsRedacted { fields["windowY"] = windowY }
        if let globalX, !targetIdentityIsRedacted { fields["globalX"] = globalX }
        if let globalY, !targetIdentityIsRedacted { fields["globalY"] = globalY }
        if let reason { fields["reason"] = reason.rawValue }

        guard appendLocked(fields) else {
            disableAfterWriteFailureLocked()
            return nil
        }
        totalRecords += 1
        if let stream { streamCounts[stream, default: 0] += 1 }
        if event == .globalCallbackEntry { pendingTraces.insert(sequence) }
        if let traceID, event == .globalGuardOutcome || event == .globalTaskOwnerUnavailable {
            pendingTraces.remove(traceID)
            if isFinished && pendingTraces.isEmpty { isDisabled = true }
        }
        return sequence
    }

    func finish(
        event: OverlayInputReceiptEvent = .transactionEnded,
        contextID: UUID?,
        reason: OverlayInputReceiptReason
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished, !isDisabled else { return }

        if totalRecords >= maximumRecords - 1 {
            appendBudgetExhaustedLocked(contextID: contextID, stream: nil)
            isDisabled = true
        } else {
            let sequence = nextSequence
            nextSequence += 1
            var fields = baseFields(event: event, sequence: sequence, contextID: contextID, traceID: nil)
            fields["reason"] = reason.rawValue
            if appendLocked(fields) {
                totalRecords += 1
            } else {
                disableAfterWriteFailureLocked()
            }
        }
        isFinished = true
        if pendingTraces.isEmpty { isDisabled = true }
    }

    private func baseFields(
        event: OverlayInputReceiptEvent,
        sequence: Int,
        contextID: UUID?,
        traceID: Int?
    ) -> [String: Any] {
        var fields: [String: Any] = [
            "schema": 1,
            "component": component.rawValue,
            "event": event.rawValue,
            "sequence": sequence,
            "processPID": Int(processID),
            "observedUptime": ProcessInfo.processInfo.systemUptime,
        ]
        if let contextID { fields["contextID"] = contextID.uuidString }
        if let traceID { fields["traceID"] = traceID }
        return fields
    }

    private func appendBudgetExhaustedLocked(contextID: UUID?, stream: OverlayInputReceiptStream?) {
        guard totalRecords < maximumRecords else { return }
        let sequence = nextSequence
        nextSequence += 1
        var fields = baseFields(event: .budgetExhausted, sequence: sequence, contextID: contextID, traceID: nil)
        fields["reason"] = OverlayInputReceiptReason.recordBudgetExhausted.rawValue
        if let stream { fields["stream"] = stream.rawValue }
        if appendLocked(fields) { totalRecords += 1 } else { disableAfterWriteFailureLocked() }
    }

    private func appendLocked(_ fields: [String: Any]) -> Bool {
        Self.sharedAppendLock.lock()
        defer { Self.sharedAppendLock.unlock() }
        do {
            var data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
            data.append(0x0A)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                guard FileManager.default.createFile(
                    atPath: fileURL.path,
                    contents: Data(),
                    attributes: [.posixPermissions: NSNumber(value: 0o600)]
                ) else { return false }
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
            return true
        } catch {
            return false
        }
    }

    private func disableAfterWriteFailureLocked() {
        isDisabled = true
        guard !didLogFailure else { return }
        didLogFailure = true
        NSLog("Overlay mouse-receipt diagnostics disabled: append failed")
    }
}
