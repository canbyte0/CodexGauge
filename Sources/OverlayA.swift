import AppKit
import CoreGraphics
import CoreFoundation
import Foundation

private enum PaletteMode: String {
    case system
    case light
    case dark

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

private struct HostWindow {
    let windowNumber: CGWindowID
    let pid: pid_t
    let cgBounds: CGRect
    let appKitFrame: CGRect
}

private struct HostWindowIdentity: Equatable {
    let windowNumber: CGWindowID
    let pid: pid_t

    init(_ host: HostWindow) {
        windowNumber = host.windowNumber
        pid = host.pid
    }

    init(pid: pid_t, windowNumber: CGWindowID) {
        self.pid = pid
        self.windowNumber = windowNumber
    }
}

private struct QuartzWindowCandidate {
    let identity: HostWindowIdentity?
    let bounds: CGRect
}

private struct MouseEventTargetFields {
    let unixProcessID: pid_t?
    let windowNumber: CGWindowID?

    var processIDFieldValid: Bool { unixProcessID != nil }
    var windowIDFieldValid: Bool { windowNumber != nil }
}

private struct VerifiedMouseEventTarget {
    let identity: HostWindowIdentity
    let processIDMatchesWindowOwner: Bool
    let processIDMatchesOverlay: Bool
}

private enum MouseEventTargetResolution {
    case verified(VerifiedMouseEventTarget)
    case unknown(String)

    var identity: HostWindowIdentity? {
        guard case let .verified(target) = self else { return nil }
        return target.identity
    }
}

private enum ExternalMouseDecision: Equatable {
    case closeExactSource
    case keep(String)
}

private struct ExternalMouseCloseDisposition: Equatable {
    let reason: String
    let restoreIfSafe: Bool
}

private struct RailLayout {
    let isVisible: Bool
    let railWidth: CGFloat
    let railFrame: CGRect
    let emptyAnchor: CGRect
    let updatedAt: Date
}

private struct DetailsOpenContext {
    let id: UUID
    let rowIdentifier: String
    let hostWindowNumber: CGWindowID
    let hostPID: pid_t
    let openingFrontmostRole: String
    let source: String
    let clickID: UUID?
    let displayID: UUID?
}

private enum NonactivatingDetailsStage: Equatable {
    case preKey
    case postKey
    case ongoing
}

private struct NonactivatingDetailsStageEvidence {
    let stage: NonactivatingDetailsStage
    let isProbe: Bool
    let overlayIsActive: Bool
    let currentTransactionIsExact: Bool
    let transactionIsUnique: Bool
    let frontmostPIDMatchesHost: Bool
    let sourceWindowAndLayoutAreValid: Bool
    let clickDisplayBindingIsValid: Bool
    let panelBelongsToTransaction: Bool
    let panelUsesNonactivatingStyle: Bool
    let panelIsVisible: Bool
    let panelIsKey: Bool
    let appKeyWindowIsPanel: Bool
    let responderBelongsToDetails: Bool
}

private enum NonactivatingDetailsStagePolicy {
    static func allows(_ evidence: NonactivatingDetailsStageEvidence) -> Bool {
        guard evidence.isProbe,
              evidence.currentTransactionIsExact,
              evidence.transactionIsUnique,
              evidence.frontmostPIDMatchesHost,
              evidence.sourceWindowAndLayoutAreValid,
              evidence.clickDisplayBindingIsValid
        else { return false }

        if evidence.stage == .preKey {
            return !evidence.overlayIsActive
        }

        let detailsOwnInteraction = evidence.panelBelongsToTransaction &&
            evidence.panelUsesNonactivatingStyle &&
            evidence.panelIsVisible &&
            evidence.panelIsKey &&
            evidence.appKeyWindowIsPanel &&
            evidence.responderBelongsToDetails
        guard !evidence.overlayIsActive || detailsOwnInteraction else { return false }
        return detailsOwnInteraction
    }
}

@MainActor
private final class RetiredDetailsProbeContext {
    let context: DetailsOpenContext
    let panelWindowNumber: Int?
    weak var panel: NSWindow?
    weak var rootView: NSView?
    var sampledFromRefreshPlacement = false
    var sampledFromWorkspaceActivation = false

    init(context: DetailsOpenContext, panel: NSWindow?, rootView: NSView?) {
        self.context = context
        self.panelWindowNumber = panel?.windowNumber
        self.panel = panel
        self.rootView = rootView
    }
}

private enum DetailsInteractionSetupResult {
    case ready
    case waitingForKey
    case failed(String)
}

private enum OpeningActivationRetryDecision: Equatable {
    case retry
    case continueOpening
    case hideForOtherApplication
    case invalidSource
    case wait
    case staleContext
    case alreadyRetried
}

private struct SummaryPointerGesture {
    let id: UUID
    let rowIdentifier: String
    let host: HostWindowIdentity?
    let displayID: UUID?
    let startedAt: Date
    var actionReached = false
}

private struct DemoLayoutRequest {
    let id: String
    let hostPID: pid_t
    let windowNumber: CGWindowID
    let sentAt: Date
}

private enum DemoBridge {
    static let openDetails = Notification.Name("OverlayA.Demo.openDetails")
    static let closeDetails = Notification.Name("OverlayA.Demo.closeDetails")
    static let layout = Notification.Name("OverlayA.Demo.layout")
    static let requestLayout = Notification.Name("OverlayA.Demo.requestLayout")
    static let activateWindow = Notification.Name("OverlayA.Demo.activateWindow")
}

private final class SummaryPanel: NSPanel {
    var rowIdentifier = "unknown"
    var displayedHostIdentity: HostWindowIdentity?
    var displayID: UUID?
    var pointerEventHandler: ((SummaryPanel, NSEvent, String) -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .leftMouseDown || event.type == .leftMouseUp else {
            super.sendEvent(event)
            return
        }

        if event.type == .leftMouseDown {
            pointerEventHandler?(self, event, "panel-mouseDown")
        } else {
            pointerEventHandler?(self, event, "panel-mouseUp-before-action")
        }
        super.sendEvent(event)
        if event.type == .leftMouseUp {
            pointerEventHandler?(self, event, "panel-mouseUp-after-action")
        }
    }
}

@MainActor
private final class NonactivatingDetailsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private class SummaryInputButton: NSButton {
    var rowIdentifier = "unknown"
    var pointerEventHandler: ((SummaryInputButton, NSEvent, String) -> Void)?

    override func mouseDown(with event: NSEvent) {
        pointerEventHandler?(self, event, "mouseDown")
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        pointerEventHandler?(self, event, "mouseUp-before-action")
        super.mouseUp(with: event)
        pointerEventHandler?(self, event, "mouseUp-after-action")
    }
}

private final class SummaryButton: SummaryInputButton {
    var titleText = ""
    var valueText = ""
    var accessibilityText = ""

    override func draw(_ dirtyRect: NSRect) {
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let title = NSString(string: titleText)
        let value = NSString(string: valueText)
        let titleSize = title.size(withAttributes: titleAttributes)
        let valueSize = value.size(withAttributes: valueAttributes)
        title.draw(
            at: NSPoint(x: (bounds.width - titleSize.width) / 2, y: bounds.height - titleSize.height - 1),
            withAttributes: titleAttributes
        )
        value.draw(
            at: NSPoint(x: (bounds.width - valueSize.width) / 2, y: 1),
            withAttributes: valueAttributes
        )
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { accessibilityText }
}

private final class TimeButton: SummaryInputButton {
    var timeText = ""
    var accessibilityText = ""

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let value = NSString(string: timeText)
        let size = value.size(withAttributes: attributes)
        value.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { accessibilityText }
}

private final class DetailsRootView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
}

private final class DemoValues {
    let fiveHourRemaining = 96
    let weekRemaining = 66
    let resetCredits = 2
    private(set) var snapshotAt = Date()

    var fiveHourReset: Date { snapshotAt.addingTimeInterval(4 * 60 * 60 + 58 * 60) }
    var weekReset: Date { snapshotAt.addingTimeInterval(4 * 24 * 60 * 60 + 13 * 60 * 60) }

    func refresh() {
        snapshotAt = Date()
    }
}

@MainActor
private final class OverlayAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let values = DemoValues()
    private let summaryHeight = OverlayPlacement.summarySize.height
    private let summaryWidth = OverlayPlacement.summarySize.width
    private let pointerGestureMaximumAge: TimeInterval = 3

    private var targetBundleID = Bundle.main.object(forInfoDictionaryKey: "OverlayTargetBundleIdentifier") as? String ?? "com.openai.codex"
    private let expectedCodexPath = "/Applications/ChatGPT.app"
    private var timer: Timer?
    private var clockTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var demoObservers: [NSObjectProtocol] = []
    private var rowPanels: [SummaryPanel] = []
    private var summaryButtons: [NSButton] = []
    private var popover: NSPopover?
    private var nonactivatingDetailsPanel: NonactivatingDetailsPanel?
    private var detailsKeyEventMonitor: Any?
    private var detailsMouseEventMonitor: Any?
    private var detailsReceiptDiagnosticLocalMouseMonitor: Any?
    private var detailsReceiptDiagnosticLog: OverlayInputReceiptDiagnosticLog?
    private var detailsReceiptDiagnosticContextID: UUID?
    private var activeHost: HostWindow?
    private var detailsContext: DetailsOpenContext?
    private var openingDetailsContext: DetailsOpenContext?
    private var openingDetailsObservers: [NSObjectProtocol] = []
    private var openingDetailsTimeoutTimer: Timer?
    private weak var openingDetailsButton: NSButton?
    private var activationRetryContextID: UUID?
    private let openingDetailsTimeout: TimeInterval = 3
    private var pendingSummaryPointerGesture: SummaryPointerGesture?
    private let probeDiagnosticRecordLimit = 48
    private var probeEventSequence: UInt64 = 0
    private var probeRecordContextID: UUID?
    private var probeRecordCount = 0
    private var probeGuardSessionContextID: UUID?
    private var probeGuardEvents: [String] = []
    private var retiredDetailsProbeContext: RetiredDetailsProbeContext?
    private var closeDisposition: (reason: String, restoreIfSafe: Bool)?
    private var demoLayouts: [String: RailLayout] = [:]
    private var lastDemoLayoutRequest: Date?
    private var pendingDemoLayoutRequest: DemoLayoutRequest?
    private var appearanceMode = PaletteMode.system
    private var lastReason = "starting"
    private var openedViaDemoBridge = false
    private var runtimeDirectoryURL: URL?
    private var ownsPIDFile = false
    private let terminationSignal = OverlayTerminationSignal()
    private var logURL: URL? { runtimeDirectoryURL?.appendingPathComponent("overlay-a.log") }
    private var pidURL: URL? { runtimeDirectoryURL?.appendingPathComponent("overlay-a.pid") }

    private var isDemoTarget: Bool {
        targetBundleID == "org.openai.codex.QuotaOverlayA.DemoHost"
    }

    private var isNonactivatingDetailsProbe: Bool {
        isDemoTarget && (Bundle.main.object(forInfoDictionaryKey: "OverlayNonactivatingDetailsProbe") as? Bool == true)
    }

    private var isMouseReceiptDiagnosticsEnabled: Bool {
        isNonactivatingDetailsProbe && OverlayInputReceiptDiagnosticGate.isEnabled(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            expectedBundleIdentifier: "org.openai.codex.QuotaOverlayA.Demo",
            explicitFlag: Bundle.main.object(forInfoDictionaryKey: "OverlayMouseReceiptDiagnostics") as? Bool == true
        )
    }

    private var detailsAreVisible: Bool {
        if isNonactivatingDetailsProbe { return nonactivatingDetailsPanel?.isVisible == true }
        return popover?.isShown == true
    }

    private var currentDetailsWindow: NSWindow? {
        if isNonactivatingDetailsProbe { return nonactivatingDetailsPanel }
        return popover?.contentViewController?.view.window
    }

    private var currentDetailsContent: DetailsViewController? {
        if isNonactivatingDetailsProbe {
            return nonactivatingDetailsPanel?.contentViewController as? DetailsViewController
        }
        return popover?.contentViewController as? DetailsViewController
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard terminationSignal.install(onTermination: { NSApp.terminate(nil) }) else {
            NSLog("Overlay A could not install the SIGTERM event source; refusing startup")
            NSApp.terminate(nil)
            return
        }
        guard prepareRuntimeFiles() else {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        makeSummaryPanels()
        installObservers()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPlacement() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateClock() }
        }
        RunLoop.main.add(clockTimer!, forMode: .common)
        installDemoBridgeIfNeeded()
        refreshPlacement()
    }

    func applicationWillTerminate(_ notification: Notification) {
        finishRetiredProbeObservation(reason: "application-termination")
        terminationSignal.stopMonitoring()
        removeDetailsEventMonitors(contextID: detailsContext?.id ?? openingDetailsContext?.id, reason: "termination")
        timer?.invalidate()
        timer = nil
        clockTimer?.invalidate()
        clockTimer = nil
        closeDetails(reason: "termination", restoreIfSafe: false)
        hideSummary(reason: "termination")
        finishRetiredProbeObservation(reason: "application-termination-after-cleanup")
        if let contextID = probeGuardSessionContextID {
            endNonactivatingProbeGuardSession(contextID: contextID)
        }
        probeGuardEvents.removeAll()
        probeRecordContextID = nil
        probeRecordCount = 0
        rowPanels.forEach { $0.close() }
        rowPanels.removeAll()
        summaryButtons.removeAll()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        demoObservers.forEach(DistributedNotificationCenter.default().removeObserver)
        demoObservers.removeAll()
        let stopReason = terminationSignal.receivedTerminationSignal ? "SIGTERM" : "application"
        writeLog("stop process=\(ProcessInfo.processInfo.processIdentifier) reason=\(stopReason)")
        removePIDFile()
        if !terminationSignal.restorePreviousSignalDisposition() {
            NSLog("Overlay A could not restore the previous SIGTERM disposition")
        }
    }

    private func makeSummaryPanels() {
        let rows: [(String, CGFloat, CGFloat, () -> SummaryInputButton)] = [
            ("five-hour", 178, 38, { self.makeMetricButton(label: "5h", value: "96%", accessibility: "模拟数据，5 小时额度剩余百分之九十六") }),
            ("week", 130, 38, { self.makeMetricButton(label: "周", value: "66%", accessibility: "模拟数据，周额度剩余百分之六十六") }),
            ("reset", 82, 38, { self.makeMetricButton(label: "重置", value: "2 次", accessibility: "模拟数据，限额重置剩余两次") }),
            ("time", 54, 22, { self.makeTimeButton() }),
        ]

        for (rowIdentifier, offset, height, makeButton) in rows {
            let panel = SummaryPanel(
                contentRect: NSRect(x: 0, y: 0, width: summaryWidth, height: height),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.rowIdentifier = rowIdentifier
            panel.pointerEventHandler = { [weak self] panel, event, phase in
                self?.recordSummaryPanelPointerEvent(phase, panel: panel, event: event)
            }
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = false
            panel.hidesOnDeactivate = false
            panel.level = .normal
            panel.collectionBehavior = [.moveToActiveSpace]
            panel.animationBehavior = .none
            panel.isReleasedWhenClosed = false
            panel.appearance = appearanceMode.appearance

            let button = makeButton()
            button.rowIdentifier = rowIdentifier
            button.pointerEventHandler = { [weak self] button, event, phase in
                self?.recordSummaryButtonPointerEvent(phase, button: button, event: event)
            }
            button.frame = NSRect(x: 0, y: 0, width: summaryWidth, height: height)
            button.isBordered = false
            button.focusRingType = .none
            button.setButtonType(.momentaryChange)
            panel.contentView = button
            rowPanels.append(panel)
            summaryButtons.append(button)
            _ = offset
        }
    }

    private func makeMetricButton(label: String, value: String, accessibility: String) -> SummaryButton {
        let button = SummaryButton()
        button.titleText = label
        button.valueText = value
        button.accessibilityText = accessibility
        button.target = self
        button.action = #selector(openDetails(_:))
        return button
    }

    private func makeTimeButton() -> TimeButton {
        let button = TimeButton()
        button.timeText = formattedNow()
        button.accessibilityText = "模拟数据覆盖层当前时间 Asia/Shanghai \(button.timeText)"
        button.target = self
        button.action = #selector(openDetails(_:))
        return button
    }

    private func installObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let activationObserver = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sampleRetiredProbeContextIfNeeded(from: "workspace-did-activate-application")
                let pendingContextID = self.openingDetailsContext?.id
                if let context = self.openingDetailsContext {
                    self.writeLog("details-open-workspace-activation contextID=\(context.id.uuidString) frontmostRole=\(self.foregroundRole()) overlayActive=\(NSApp.isActive) hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none")")
                }
                self.refreshPlacement()
                self.resumePendingDetails(contextID: pendingContextID, trigger: "workspace-did-activate-application")
            }
        }
        workspaceObservers.append(activationObserver)
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshPlacement() }
            })
        }
    }

    private func installDemoBridgeIfNeeded() {
        guard isDemoTarget else { return }
        let center = DistributedNotificationCenter.default()
        let open = center.addObserver(forName: DemoBridge.openDetails, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let button = self.summaryButtons.first else { return }
                self.openedViaDemoBridge = true
                self.openDetails(button)
            }
        }
        let close = center.addObserver(forName: DemoBridge.closeDetails, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard !self.isNonactivatingDetailsProbe else {
                    self.writeLog("details-close-denied source=demo-bridge reason=probe-bridge-close-disabled")
                    return
                }
                self.closeDetails(reason: "demo-bridge", restoreIfSafe: false)
            }
        }
        let layout = center.addObserver(forName: DemoBridge.layout, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in self?.receiveDemoLayout(notification.userInfo) }
        }
        demoObservers = [open, close, layout]
    }

    private func refreshPlacement() {
        sampleRetiredProbeContextIfNeeded(from: "refresh-placement")
        guard let front = NSWorkspace.shared.frontmostApplication else {
            hideSummary(reason: "no-frontmost-app")
            return
        }

        let now = Date()
        let pointerGesture = currentSummaryPointerGesture(now: now)
        let detailsOpen = detailsAreVisible
        let shownContext = detailsOpen ? detailsContext : nil
        let pendingContext = openingDetailsContext
        let probeContext = detailsContext ?? pendingContext
        let probeOverlayIsActive = isNonactivatingDetailsProbe && NSApp.isActive
        if isNonactivatingDetailsProbe, detailsContext != nil, !detailsOpen {
            closeDetails(reason: "details-panel-not-visible", restoreIfSafe: false)
            hideSummary(reason: "details-panel-not-visible")
            return
        }
        if isNonactivatingDetailsProbe, probeOverlayIsActive, probeContext == nil {
            hideSummary(reason: "nonactivating-overlay-active-without-details-owner")
            return
        }

        let isOverlayFrontmost = front.processIdentifier == ProcessInfo.processInfo.processIdentifier
        let displayedIdentity = isOverlayFrontmost && !isNonactivatingDetailsProbe
            ? displayedSummaryHostIdentity()
            : nil
        let sourceIdentity = pendingContext.map { HostWindowIdentity(pid: $0.hostPID, windowNumber: $0.hostWindowNumber) }
            ?? shownContext.map { HostWindowIdentity(pid: $0.hostPID, windowNumber: $0.hostWindowNumber) }
            ?? pointerGesture?.host
            ?? displayedIdentity
        let targetApp: NSRunningApplication?
        if isNonactivatingDetailsProbe {
            guard front.bundleIdentifier == targetBundleID else {
                hideSummary(reason: isOverlayFrontmost ? "overlay-frontmost-in-probe" : "other-app-frontmost")
                return
            }
            if let probeContext, front.processIdentifier != probeContext.hostPID {
                closeDetails(reason: "details-host-process-changed", restoreIfSafe: false)
                hideSummary(reason: "details-host-process-changed")
                return
            }
            targetApp = front
        } else if front.bundleIdentifier == targetBundleID {
            targetApp = front
        } else if isOverlayFrontmost, let sourceIdentity {
            targetApp = NSRunningApplication(processIdentifier: sourceIdentity.pid)
        } else {
            hideSummary(reason: isOverlayFrontmost ? "overlay-source-unavailable" : "other-app-frontmost")
            return
        }

        guard let targetApp,
              !targetApp.isTerminated,
              !targetApp.isHidden,
              isAllowedTarget(targetApp),
              let host = currentHostWindow(pid: targetApp.processIdentifier),
              host.appKitFrame.width >= 700,
              host.appKitFrame.height >= 660,
              !looksFullscreen(host.appKitFrame)
        else {
            hideSummary(reason: reasonForCurrentState())
            return
        }

        var sourceWindowAndLayoutIsValid = false
        if let sourceIdentity {
            let failureReason = detailsOpen || pendingContext != nil
                ? "details-host-or-anchor-invalid"
                : "summary-input-host-invalid"
            guard let sourceHost = currentHostWindow(for: sourceIdentity) else {
                hideSummary(reason: failureReason)
                return
            }

            requestDemoLayoutsIfNeeded(for: sourceHost, now: now)
            guard validPlacement(for: sourceHost) != nil else {
                hideSummary(reason: failureReason)
                return
            }
            sourceWindowAndLayoutIsValid = HostWindowIdentity(sourceHost) == sourceIdentity &&
                sourceIdentity.pid == host.pid &&
                sourceIdentity.windowNumber == host.windowNumber

            if host.windowNumber != sourceIdentity.windowNumber {
                if detailsOpen, let context = shownContext {
                    writeLog("details-host-window-changed old=\(context.hostWindowNumber) new=\(host.windowNumber) source=\(context.source) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none")")
                    closeDetails(reason: "host-window-changed", restoreIfSafe: false)
                } else if pendingContext != nil {
                    cancelOpeningDetails(reason: "host-window-changed")
                } else if pointerGesture != nil {
                    cancelSummaryPointerGesture(reason: "host-window-changed")
                }

                if isNonactivatingDetailsProbe || isOverlayFrontmost {
                    hideSummary(reason: "details-host-window-changed")
                    return
                }
            }
        }

        requestDemoLayoutsIfNeeded(for: host, now: now)
        guard let placement = validPlacement(for: host) else {
            hideSummary(reason: lastLayoutFailure)
            return
        }

        activeHost = host
        let rowOffsets: [(CGFloat, CGFloat)] = [(124, 38), (76, 38), (28, 38), (0, 22)]
        for (index, panel) in rowPanels.enumerated() {
            let (offset, height) = rowOffsets[index]
            let targetFrame = NSRect(x: placement.minX, y: placement.minY + offset, width: summaryWidth, height: height)
            let identity = HostWindowIdentity(host)
            let displayChanged = panel.displayedHostIdentity != identity || panel.displayID == nil || !panel.isVisible
            if displayChanged {
                let displayID = UUID()
                panel.displayedHostIdentity = identity
                panel.displayID = displayID
            }
            panel.setFrame(targetFrame, display: false)
            if displayChanged, let displayID = panel.displayID {
                let button = panel.contentView as? SummaryInputButton
                let buttonFrame = button.map { panel.convertToScreen($0.convert($0.bounds, to: nil)) }
                writeLog("summary-placement displayID=\(displayID.uuidString) row=\(panel.rowIdentifier) hostPID=\(identity.pid) hostWindow=\(identity.windowNumber) panelFrame=\(string(targetFrame)) buttonBounds=\(button.map { string($0.bounds) } ?? "none") buttonFrame=\(buttonFrame.map(string) ?? "none")")
            }
            panel.order(.above, relativeTo: Int(host.windowNumber))
        }

        if isNonactivatingDetailsProbe,
           detailsOpen || pendingContext != nil || detailsContext != nil || probeOverlayIsActive {
            guard let context = probeContext,
                  context.hostPID == host.pid,
                  context.hostWindowNumber == host.windowNumber,
                  sourceWindowAndLayoutIsValid,
                  updateNonactivatingDetailsPanelPosition(
                    context: context,
                    frontmostApplication: front,
                    overlayIsActive: probeOverlayIsActive,
                    sourceWindowAndLayoutIsValid: sourceWindowAndLayoutIsValid
                  )
            else {
                closeDetails(reason: "details-stage-owner-or-source-invalid", restoreIfSafe: false)
                hideSummary(reason: "details-stage-owner-or-source-invalid")
                return
            }
        }
        updateClock()
        if lastReason != "visible" {
            let frames = rowPanels.map { string($0.frame) }.joined(separator: ";")
            writeLog("show hostWindow=\(host.windowNumber) cg=\(string(host.cgBounds)) appKit=\(string(host.appKitFrame)) rail=\(string(demoLayouts[key(for: host)]?.railFrame ?? .zero)) anchor=\(string(demoLayouts[key(for: host)]?.emptyAnchor ?? .zero)) rows=\(frames) stateSource=\(isDemoTarget ? "demo-host-bridge" : "unknown-formal-state") overlayActive=\(NSApp.isActive)")
            lastReason = "visible"
        }
    }

    private func currentSummaryPointerGesture(now: Date) -> SummaryPointerGesture? {
        guard let gesture = pendingSummaryPointerGesture else { return nil }
        let age = now.timeIntervalSince(gesture.startedAt)
        guard age >= 0, age <= pointerGestureMaximumAge else {
            cancelSummaryPointerGesture(reason: "gesture-expired")
            return nil
        }
        return gesture
    }

    private func displayedSummaryHostIdentity() -> HostWindowIdentity? {
        guard !rowPanels.isEmpty,
              rowPanels.allSatisfy({ $0.isVisible && $0.displayID != nil }),
              let identity = rowPanels[0].displayedHostIdentity,
              rowPanels.allSatisfy({ $0.displayedHostIdentity == identity })
        else { return nil }
        return identity
    }

    private func currentHostWindow(for identity: HostWindowIdentity) -> HostWindow? {
        guard let app = NSRunningApplication(processIdentifier: identity.pid),
              !app.isTerminated,
              !app.isHidden,
              isAllowedTarget(app),
              currentHostWindow(pid: identity.pid)?.windowNumber == identity.windowNumber,
              let exactHost = hostWindow(pid: identity.pid, windowNumber: identity.windowNumber)
        else { return nil }
        return exactHost
    }

    private func currentValidHostWindow(for identity: HostWindowIdentity, now: Date = Date()) -> HostWindow? {
        guard let host = currentHostWindow(for: identity) else { return nil }
        requestDemoLayoutsIfNeeded(for: host, now: now)
        guard validPlacement(for: host) != nil else { return nil }
        return host
    }

    private func beginNonactivatingProbeTransaction(_ context: DetailsOpenContext) {
        finishRetiredProbeObservation(reason: "superseded-by-new-probe-transaction")
        if let previousContextID = probeGuardSessionContextID {
            endNonactivatingProbeGuardSession(contextID: previousContextID)
        }
        probeEventSequence = 0
        probeRecordContextID = context.id
        probeRecordCount = 0
        probeGuardSessionContextID = context.id
        probeGuardEvents.removeAll(keepingCapacity: true)
#if OVERLAY_A_GUARD_RECORDER_LIFECYCLE_REGRESSION
        // 生命周期回归不初始化 NSApplication，只省略与记录会话无关的 AppKit 状态采样。
#else
        recordNonactivatingProbeState(checkpoint: "before-source-guard", context: context, panel: nil, rootView: nil)
#endif
    }

    private func reserveProbeRecord(contextID: UUID) -> Bool {
        guard probeRecordContextID == contextID,
              probeRecordCount < probeDiagnosticRecordLimit
        else { return false }
        probeRecordCount += 1
        return true
    }

    private func nextProbeEventSequence() -> UInt64 {
        probeEventSequence += 1
        return probeEventSequence
    }

    private static func evaluateProbeGuardOperand(
        _ evaluate: () -> Bool,
        onEvaluation: ((Bool, TimeInterval, TimeInterval) -> Void)?
    ) -> Bool {
        guard let onEvaluation else { return evaluate() }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = evaluate()
        let endedAt = ProcessInfo.processInfo.systemUptime
        onEvaluation(result, startedAt, endedAt)
        return result
    }

    private func probeGuardOperand(
        contextID: UUID,
        predicate: String,
        value: @autoclosure () -> Bool
    ) -> Bool {
        guard probeGuardSessionContextID == contextID,
              reserveProbeRecord(contextID: contextID)
        else {
            return Self.evaluateProbeGuardOperand(value, onEvaluation: nil)
        }

        let callback: (Bool, TimeInterval, TimeInterval) -> Void = { [weak self] result, startedAt, endedAt in
            guard let self else { return }
            let sequence = self.nextProbeEventSequence()
            self.probeGuardEvents.append(
                "probe-guard checkpoint=guard-operand contextID=\(contextID.uuidString) seq=\(sequence) predicate=\(predicate) result=\(result) evalStartUptime=\(String(format: "%.6f", startedAt)) evalEndUptime=\(String(format: "%.6f", endedAt))"
            )
        }
        return Self.evaluateProbeGuardOperand(value, onEvaluation: callback)
    }

    private func flushNonactivatingProbeGuardEvents(contextID: UUID) {
        guard probeGuardSessionContextID == contextID else { return }
        for event in probeGuardEvents { writeLog(event) }
        probeGuardEvents.removeAll(keepingCapacity: true)
    }

    private func endNonactivatingProbeGuardSession(contextID: UUID) {
        guard probeGuardSessionContextID == contextID else { return }
        flushNonactivatingProbeGuardEvents(contextID: contextID)
        guard probeGuardSessionContextID == contextID else { return }
        probeGuardSessionContextID = nil
    }

    private func recordNonactivatingProbeState(
        checkpoint: String,
        context: DetailsOpenContext,
        panel: NSWindow?,
        rootView: NSView?,
        panelWindowNumberOverride: Int? = nil,
        retiredContext: Bool = false
    ) {
        guard reserveProbeRecord(contextID: context.id)
        else { return }

        let sampleStartedAt = ProcessInfo.processInfo.systemUptime
        let nsAppActive = NSApp.isActive
        let runningApplicationActive = NSRunningApplication.current.isActive
        let frontmost = NSWorkspace.shared.frontmostApplication
        let overlayPID = ProcessInfo.processInfo.processIdentifier
        let frontmostRole: String
        if let frontmost {
            if frontmost.processIdentifier == context.hostPID {
                frontmostRole = "host"
            } else if frontmost.processIdentifier == overlayPID {
                frontmostRole = "overlay"
            } else {
                frontmostRole = "other"
            }
        } else {
            frontmostRole = "unknown"
        }

        let panelVisible = panel.map { String($0.isVisible) } ?? "unknown"
        let panelKey = panel.map { String($0.isKeyWindow) } ?? "unknown"
        let appKeyWindowIsPanel = panel.map { String(NSApp.keyWindow === $0) } ?? "unknown"
        let firstResponder = panel?.firstResponder
        let firstResponderIsRoot: String
        if panel != nil, let rootView, let firstResponder {
            firstResponderIsRoot = String(firstResponder === rootView)
        } else {
            firstResponderIsRoot = "unknown"
        }
        let firstResponderIsDetailsControl: String
        if panel != nil {
            firstResponderIsDetailsControl = String(firstResponder.map { $0 is NSControl } ?? false)
        } else {
            firstResponderIsDetailsControl = "unknown"
        }
        let eventType = NSApp.currentEvent.map { String(describing: $0.type) } ?? "none"
        let runLoopMode = nonactivatingProbeRunLoopModeCategory()
        let sampleEndedAt = ProcessInfo.processInfo.systemUptime
        let sequence = nextProbeEventSequence()
        let detailWindow = panelWindowNumberOverride ?? panel?.windowNumber
        writeLog(
            "probe-state checkpoint=\(checkpoint) seq=\(sequence) sampleStartUptime=\(String(format: "%.6f", sampleStartedAt)) sampleEndUptime=\(String(format: "%.6f", sampleEndedAt)) contextID=\(context.id.uuidString) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none") row=\(context.rowIdentifier) source=\(context.source) openingFrontmostRole=\(context.openingFrontmostRole) hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber) detailWindow=\(detailWindow?.description ?? "unknown") nsAppActive=\(nsAppActive) runningApplicationActiveCached=\(runningApplicationActive) workspaceFrontmostRole=\(frontmostRole) panelVisible=\(panelVisible) panelKey=\(panelKey) appKeyWindowIsPanel=\(appKeyWindowIsPanel) firstResponderIsDetailsRoot=\(firstResponderIsRoot) firstResponderIsDetailsControl=\(firstResponderIsDetailsControl) eventType=\(eventType) runLoopMode=\(runLoopMode) postCancel=\(retiredContext) retiredContext=\(retiredContext)"
        )
    }

    private func nonactivatingProbeRunLoopModeCategory() -> String {
        Self.probeRunLoopModeCategory(CFRunLoopCopyCurrentMode(CFRunLoopGetMain()))
    }

    private static func probeRunLoopModeCategory(_ mode: CFRunLoopMode?) -> String {
        guard let mode else { return "none" }
        if mode == CFRunLoopMode.defaultMode { return "default" }
        let rawValue = mode.rawValue
        let trackingMode = RunLoop.Mode.eventTracking.rawValue as NSString as CFString
        if rawValue == trackingMode { return "tracking" }
        let modalMode = RunLoop.Mode.modalPanel.rawValue as NSString as CFString
        if rawValue == modalMode { return "modal" }
        return "other"
    }

    private func sampleRetiredProbeContextIfNeeded(from trigger: String) {
        guard let retired = retiredDetailsProbeContext else { return }

        switch trigger {
        case "refresh-placement":
            guard !retired.sampledFromRefreshPlacement else { return }
            retired.sampledFromRefreshPlacement = true
        case "workspace-did-activate-application":
            guard !retired.sampledFromWorkspaceActivation else { return }
            retired.sampledFromWorkspaceActivation = true
        default:
            return
        }

        recordNonactivatingProbeState(
            checkpoint: "post-cancel-\(trigger)",
            context: retired.context,
            panel: retired.panel,
            rootView: retired.rootView,
            panelWindowNumberOverride: retired.panelWindowNumber,
            retiredContext: true
        )
        if retired.sampledFromRefreshPlacement && retired.sampledFromWorkspaceActivation {
            finishRetiredProbeObservation(reason: "both-natural-followups-observed")
        }
    }

    private func finishRetiredProbeObservation(reason: String) {
        guard let retired = retiredDetailsProbeContext else { return }
        let sampleStartedAt = ProcessInfo.processInfo.systemUptime
        let refresh = retired.sampledFromRefreshPlacement ? "observed" : "not-observed"
        let workspace = retired.sampledFromWorkspaceActivation ? "observed" : "not-observed"
        let missing = [
            retired.sampledFromRefreshPlacement ? nil : "refreshPlacement",
            retired.sampledFromWorkspaceActivation ? nil : "workspaceActivation",
        ].compactMap { $0 }.joined(separator: ",")
        if reserveProbeRecord(contextID: retired.context.id) {
            let sequence = nextProbeEventSequence()
            let sampleEndedAt = ProcessInfo.processInfo.systemUptime
            writeLog("probe-retired-observation-end checkpoint=retired-observation-end contextID=\(retired.context.id.uuidString) seq=\(sequence) sampleStartUptime=\(String(format: "%.6f", sampleStartedAt)) sampleEndUptime=\(String(format: "%.6f", sampleEndedAt)) reason=\(reason) postCancel=true retiredContext=true refreshPlacement=\(refresh) workspaceActivation=\(workspace) missing=\(missing.isEmpty ? "none" : missing)")
        }
        retiredDetailsProbeContext = nil
    }

    private func cancelOpeningDetails(reason: String) {
        guard let context = openingDetailsContext else {
            removeOpeningDetailsReadinessHooks()
            return
        }
        flushNonactivatingProbeGuardEvents(contextID: context.id)
        let diagnosticPanel = nonactivatingDetailsPanel
        let diagnosticRoot = diagnosticPanel?.contentViewController?.view
        if isNonactivatingDetailsProbe {
            recordNonactivatingProbeState(
                checkpoint: "cancel-before-cleanup",
                context: context,
                panel: diagnosticPanel,
                rootView: diagnosticRoot
            )
        }
        removeOpeningDetailsReadinessHooks()
        if isNonactivatingDetailsProbe {
            finishRetiredProbeObservation(reason: "replaced-by-new-cancelled-context")
            let retired = RetiredDetailsProbeContext(context: context, panel: diagnosticPanel, rootView: diagnosticRoot)
            removeDetailsEventMonitors(contextID: context.id, reason: reason)
            diagnosticPanel?.orderOut(nil)
            diagnosticPanel?.close()
            nonactivatingDetailsPanel = nil
            if detailsContext?.id == context.id { detailsContext = nil }
            openingDetailsContext = nil
            retiredDetailsProbeContext = retired
            recordNonactivatingProbeState(
                checkpoint: "cancel-after-cleanup",
                context: context,
                panel: diagnosticPanel,
                rootView: diagnosticRoot,
                panelWindowNumberOverride: retired.panelWindowNumber,
                retiredContext: true
            )
            writeLog("details-open-cancelled contextID=\(context.id.uuidString) reason=\(reason) source=\(context.source) row=\(context.rowIdentifier) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none") openingFrontmost=\(context.openingFrontmostRole) hostWindow=\(context.hostWindowNumber) hostPID=\(context.hostPID)")
            endNonactivatingProbeGuardSession(contextID: context.id)
            return
        }
        if popover?.isShown == true {
            detailsContext = detailsContext ?? context
        } else {
            if detailsContext?.id == context.id { detailsContext = nil }
            popover = nil
        }
        openingDetailsContext = nil
        writeLog("details-open-cancelled contextID=\(context.id.uuidString) reason=\(reason) source=\(context.source) row=\(context.rowIdentifier) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none") openingFrontmost=\(context.openingFrontmostRole) hostWindow=\(context.hostWindowNumber) hostPID=\(context.hostPID)")
        endNonactivatingProbeGuardSession(contextID: context.id)
    }

    private func installOpeningDetailsReadinessHooks(contextID: UUID, button: NSButton) {
        removeOpeningDetailsReadinessHooks()
        openingDetailsButton = button
        let activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.writeLog("details-open-activation-callback contextID=\(contextID.uuidString) currentContextID=\(self.openingDetailsContext?.id.uuidString ?? "none") source=nsapplication-did-become-active frontmostRole=\(self.foregroundRole()) overlayActive=\(NSApp.isActive)")
                self.continueOpeningDetails(contextID: contextID, trigger: "application-did-become-active")
            }
        }
        let keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor in
                guard let self else { return }
                self.writeLog("details-open-key-callback contextID=\(contextID.uuidString) currentContextID=\(self.openingDetailsContext?.id.uuidString ?? "none") window=\(window.windowNumber) frontmostRole=\(self.foregroundRole()) overlayActive=\(NSApp.isActive)")
                self.openingDetailsWindowBecameKey(window, contextID: contextID)
            }
        }
        openingDetailsObservers = [activationObserver, keyObserver]
        let timeout = Timer.scheduledTimer(withTimeInterval: openingDetailsTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.openingDetailsReadinessTimedOut(contextID: contextID) }
        }
        openingDetailsTimeoutTimer = timeout
        RunLoop.main.add(timeout, forMode: .common)
    }

#if OVERLAY_A_OPENING_BUTTON_REGRESSION
    @MainActor
    static func runOpeningButtonRegressionCheck() {
        let delegate = OverlayAppDelegate()
        let firstButton = NSButton(frame: .zero)
        let secondButton = NSButton(frame: .zero)
        let firstContextID = UUID()
        let secondContextID = UUID()
        let testRuntimeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("overlay-a-opening-button-regression-\(UUID().uuidString)", isDirectory: true)
        delegate.runtimeDirectoryURL = testRuntimeDirectory
        defer { try? FileManager.default.removeItem(at: testRuntimeDirectory) }

        delegate.installOpeningDetailsReadinessHooks(contextID: firstContextID, button: firstButton)
        precondition(delegate.openingDetailsButton === firstButton, "first production hook install lost its sender")
        precondition(delegate.openingDetailsObservers.count == 2 && delegate.openingDetailsTimeoutTimer != nil,
                     "first production hook install did not register both observers and timeout")
        let firstTimeout = delegate.openingDetailsTimeoutTimer!

        delegate.installOpeningDetailsReadinessHooks(contextID: secondContextID, button: secondButton)
        precondition(delegate.openingDetailsButton === secondButton, "replacement production hook install lost its sender")
        precondition(delegate.openingDetailsObservers.count == 2 && delegate.openingDetailsTimeoutTimer != nil,
                     "replacement production hook install accumulated old observers or timeout")
        precondition(!firstTimeout.isValid, "replacement production hook install did not invalidate the previous timeout")
        let secondTimeout = delegate.openingDetailsTimeoutTimer!

        delegate.openingDetailsContext = DetailsOpenContext(
            id: secondContextID,
            rowIdentifier: "regression",
            hostWindowNumber: 1,
            hostPID: 1,
            openingFrontmostRole: "host",
            source: "regression-check",
            clickID: nil,
            displayID: nil
        )
        delegate.continueOpeningDetails(contextID: firstContextID, trigger: "regression-stale-context")
        precondition(delegate.openingDetailsContext?.id == secondContextID, "stale context replaced the current transaction")
        precondition(delegate.openingDetailsButton === secondButton, "stale context changed the current sender")

        delegate.cancelOpeningDetails(reason: "regression-check-cleanup")
        precondition(delegate.openingDetailsContext == nil, "production cancellation retained its transaction")
        precondition(delegate.openingDetailsButton == nil, "production cancellation retained its sender")
        precondition(delegate.openingDetailsObservers.isEmpty && delegate.openingDetailsTimeoutTimer == nil,
                     "production cancellation retained hooks")
        precondition(!secondTimeout.isValid, "production cancellation did not invalidate its timeout")

        precondition(
            Self.openingActivationRetryDecision(
                contextIsCurrent: true,
                retryAlreadyIssued: false,
                frontmostRole: "host",
                overlayIsActive: false,
                sourceIsValid: true
            ) == .retry,
            "valid pending host click did not permit its single cooperative retry"
        )
        precondition(
            Self.openingActivationRetryDecision(
                contextIsCurrent: false,
                retryAlreadyIssued: false,
                frontmostRole: "host",
                overlayIsActive: false,
                sourceIsValid: true
            ) == .staleContext,
            "stale click context permitted activation"
        )
        precondition(
            Self.openingActivationRetryDecision(
                contextIsCurrent: true,
                retryAlreadyIssued: false,
                frontmostRole: "other",
                overlayIsActive: false,
                sourceIsValid: true
            ) == .hideForOtherApplication,
            "other-app frontmost state did not preserve the hide guard"
        )
        precondition(
            Self.openingActivationRetryDecision(
                contextIsCurrent: true,
                retryAlreadyIssued: false,
                frontmostRole: "host",
                overlayIsActive: false,
                sourceIsValid: false
            ) == .invalidSource,
            "invalid host source permitted activation"
        )
        precondition(
            Self.openingActivationRetryDecision(
                contextIsCurrent: true,
                retryAlreadyIssued: true,
                frontmostRole: "host",
                overlayIsActive: false,
                sourceIsValid: true
            ) == .alreadyRetried,
            "activation retry was not bounded to one request"
        )
        precondition(
            Self.openingActivationRetryDecision(
                contextIsCurrent: true,
                retryAlreadyIssued: false,
                frontmostRole: "overlay",
                overlayIsActive: true,
                sourceIsValid: true
            ) == .continueOpening,
            "already active overlay did not continue the current transaction"
        )
        precondition(
            Self.openingActivationRetryDecision(
                contextIsCurrent: true,
                retryAlreadyIssued: false,
                frontmostRole: "overlay",
                overlayIsActive: false,
                sourceIsValid: true
            ) == .wait,
            "activation transition was mistaken for a completed activation"
        )
        print("opening-button-production-path install=2 replacement=1 stale-context=ignored cancel=clean hooks=2→0 PASS")
        print("opening-activation-retry valid-host=one-shot stale=blocked other-app=hide invalid-source=blocked already-active=continue PASS")
    }
#endif

#if OVERLAY_A_PROBE_GUARD_REGRESSION
    static func runProbeGuardRegressionCheck() {
        var evaluated: [String] = []
        var recorded: [(name: String, value: Bool, startedAt: TimeInterval, endedAt: TimeInterval)] = []
        func operand(_ name: String, _ value: Bool) -> Bool {
            Self.evaluateProbeGuardOperand(
                {
                    evaluated.append(name)
                    return value
                },
                onEvaluation: { result, startedAt, endedAt in
                    recorded.append((name, result, startedAt, endedAt))
                }
            )
        }

        let shortCircuited = operand("first", true) && operand("reject", false) && operand("unreached", true)
        precondition(!shortCircuited, "guard wrapper changed a rejected predicate result")
        precondition(evaluated == ["first", "reject"], "guard wrapper evaluated a short-circuited predicate")
        precondition(recorded.map(\.name) == evaluated, "guard wrapper recorded an operand outside evaluation order")
        precondition(recorded.map(\.value) == [true, false], "guard wrapper did not preserve actual Bool values")
        precondition(recorded.allSatisfy { $0.endedAt >= $0.startedAt }, "guard wrapper produced invalid monotonic spans")

        evaluated.removeAll()
        recorded.removeAll()
        let accepted = operand("accepted-one", true) && operand("accepted-two", true)
        precondition(accepted, "guard wrapper changed accepted predicate results")
        precondition(evaluated == ["accepted-one", "accepted-two"], "guard wrapper duplicated an accepted predicate")
        precondition(recorded.map(\.name) == evaluated && recorded.map(\.value) == [true, true],
                     "guard wrapper did not record accepted operands once and in order")

        var undiagnosedCalls = 0
        let undiagnosed = Self.evaluateProbeGuardOperand({
            undiagnosedCalls += 1
            return false
        }, onEvaluation: nil)
        precondition(!undiagnosed && undiagnosedCalls == 1, "non-probe guard path did not evaluate exactly once")
        let trackingMode = CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as NSString as CFString)
        let modalMode = CFRunLoopMode(rawValue: RunLoop.Mode.modalPanel.rawValue as NSString as CFString)
        let otherMode = CFRunLoopMode(rawValue: "other-mode" as NSString as CFString)
        precondition(Self.probeRunLoopModeCategory(nil) == "none", "missing run-loop mode was not categorized")
        precondition(Self.probeRunLoopModeCategory(.defaultMode) == "default", "default run-loop mode was not categorized")
        precondition(Self.probeRunLoopModeCategory(trackingMode) == "tracking", "tracking run-loop mode was not categorized")
        precondition(Self.probeRunLoopModeCategory(modalMode) == "modal", "modal run-loop mode was not categorized")
        precondition(Self.probeRunLoopModeCategory(otherMode) == "other", "unrecognized run-loop mode was not reduced to other")
        print("probe-guard-wrapper actual-bool=preserved short-circuit=preserved evaluation-count=once diagnostic-callback=optional PASS")
        print("probe-runloop-mode-classification default/tracking/modal/other/none PASS")
    }
#endif

#if OVERLAY_A_DETAILS_STAGE_POLICY_REGRESSION
    static func runNonactivatingDetailsStagePolicyRegressionCheck() {
        func evidence(
            stage: NonactivatingDetailsStage,
            overlayIsActive: Bool = false,
            isProbe: Bool = true,
            currentTransactionIsExact: Bool = true,
            transactionIsUnique: Bool = true,
            frontmostPIDMatchesHost: Bool = true,
            sourceWindowAndLayoutAreValid: Bool = true,
            clickDisplayBindingIsValid: Bool = true,
            panelBelongsToTransaction: Bool = true,
            panelUsesNonactivatingStyle: Bool = true,
            panelIsVisible: Bool = true,
            panelIsKey: Bool = true,
            appKeyWindowIsPanel: Bool = true,
            responderBelongsToDetails: Bool = true
        ) -> NonactivatingDetailsStageEvidence {
            NonactivatingDetailsStageEvidence(
                stage: stage,
                isProbe: isProbe,
                overlayIsActive: overlayIsActive,
                currentTransactionIsExact: currentTransactionIsExact,
                transactionIsUnique: transactionIsUnique,
                frontmostPIDMatchesHost: frontmostPIDMatchesHost,
                sourceWindowAndLayoutAreValid: sourceWindowAndLayoutAreValid,
                clickDisplayBindingIsValid: clickDisplayBindingIsValid,
                panelBelongsToTransaction: panelBelongsToTransaction,
                panelUsesNonactivatingStyle: panelUsesNonactivatingStyle,
                panelIsVisible: panelIsVisible,
                panelIsKey: panelIsKey,
                appKeyWindowIsPanel: appKeyWindowIsPanel,
                responderBelongsToDetails: responderBelongsToDetails
            )
        }

        precondition(
            NonactivatingDetailsStagePolicy.allows(evidence(stage: .preKey)),
            "valid pre-key transaction must preserve the inactive opening stage"
        )
        precondition(
            !NonactivatingDetailsStagePolicy.allows(evidence(stage: .preKey, overlayIsActive: true)),
            "pre-key stage must reject an already active overlay"
        )
        precondition(
            NonactivatingDetailsStagePolicy.allows(evidence(stage: .postKey, overlayIsActive: true)),
            "post-key stage must permit the confirmed details-owned active transition"
        )
        precondition(
            NonactivatingDetailsStagePolicy.allows(evidence(stage: .ongoing, overlayIsActive: true)),
            "ongoing details-owned control responder must remain valid"
        )

        let invalidOwnershipCases: [(String, NonactivatingDetailsStageEvidence)] = [
            ("probe", evidence(stage: .postKey, isProbe: false)),
            ("transaction", evidence(stage: .postKey, currentTransactionIsExact: false)),
            ("duplicate-transaction", evidence(stage: .postKey, transactionIsUnique: false)),
            ("frontmost-pid", evidence(stage: .postKey, frontmostPIDMatchesHost: false)),
            ("source-window-layout", evidence(stage: .postKey, sourceWindowAndLayoutAreValid: false)),
            ("click-display", evidence(stage: .postKey, clickDisplayBindingIsValid: false)),
            ("panel-owner", evidence(stage: .postKey, panelBelongsToTransaction: false)),
            ("panel-style", evidence(stage: .postKey, panelUsesNonactivatingStyle: false)),
            ("panel-visible", evidence(stage: .postKey, panelIsVisible: false)),
            ("panel-key", evidence(stage: .postKey, panelIsKey: false)),
            ("app-key-window", evidence(stage: .postKey, appKeyWindowIsPanel: false)),
            ("unowned-control-responder", evidence(stage: .ongoing, responderBelongsToDetails: false)),
        ]
        for (name, candidate) in invalidOwnershipCases {
            precondition(!NonactivatingDetailsStagePolicy.allows(candidate), "invalid \(name) evidence was accepted")
        }

        print("details-stage-policy pre-key-inactive-only PASS")
        print("details-stage-policy post-key-and-ongoing-active-with-exact-owner PASS")
        print("details-stage-policy rejects probe/context/PID/layout/click-display/panel/key/responder mismatches PASS")
        print("details-stage-policy details-owned-control accepted; arbitrary unowned control rejected PASS")
    }
#endif

#if OVERLAY_A_GUARD_RECORDER_LIFECYCLE_REGRESSION
    static func runProbeGuardRecorderLifecycleRegressionCheck() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("overlay-a-guard-recorder-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch {
            preconditionFailure("could not create private recorder regression directory: \(error)")
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let delegate = OverlayAppDelegate()
        delegate.runtimeDirectoryURL = directory
        let logURL = directory.appendingPathComponent("overlay-a.log")
        var evaluated: [String] = []

        func makeContext(_ id: UUID = UUID()) -> DetailsOpenContext {
            DetailsOpenContext(
                id: id,
                rowIdentifier: "regression",
                hostWindowNumber: 1,
                hostPID: 1,
                openingFrontmostRole: "host",
                source: "static-regression",
                clickID: nil,
                displayID: nil
            )
        }

        func guardRecords() -> [String] {
            guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
            return text.components(separatedBy: .newlines)
                .filter { $0.contains("probe-guard checkpoint=guard-operand") }
        }

        func field(_ key: String, in line: String) -> String? {
            line.split(separator: " ")
                .first { $0.hasPrefix("\(key)=") }
                .map { String($0.dropFirst(key.count + 1)) }
        }

        let operand: (UUID, String, Bool) -> Bool = { contextID, name, result in
            delegate.probeGuardOperand(contextID: contextID, predicate: name, value: {
                evaluated.append(name)
                return result
            }())
        }

        let firstContext = makeContext()
        delegate.beginNonactivatingProbeTransaction(firstContext)
        let firstBatch = operand(firstContext.id, "source-first", true)
            && operand(firstContext.id, "source-last", true)
        precondition(firstBatch, "accepted source batch was rejected")
        delegate.flushNonactivatingProbeGuardEvents(contextID: firstContext.id)
        precondition(delegate.probeGuardSessionContextID == firstContext.id,
                     "flush ended the active diagnostic session")
        precondition(guardRecords().count == 2, "first batch was not written by the production recorder")

        evaluated.removeAll()
        let secondBatch = operand(firstContext.id, "post-order-first", true)
            && operand(firstContext.id, "post-order-second", true)
        precondition(secondBatch, "accepted post-order batch was rejected")
        delegate.flushNonactivatingProbeGuardEvents(contextID: firstContext.id)
        precondition(evaluated == ["post-order-first", "post-order-second"],
                     "post-order predicates were not evaluated once and in order")
        precondition(guardRecords().count == 4, "second flush did not preserve the same transaction")

        evaluated.removeAll()
        let rejectedBatch = operand(firstContext.id, "post-setup-panel-key", true)
            && operand(firstContext.id, "post-setup-root-responder", false)
            && operand(firstContext.id, "post-setup-overlay-inactive", true)
        precondition(!rejectedBatch, "post-setup false Bool was changed")
        precondition(evaluated == ["post-setup-panel-key", "post-setup-root-responder"],
                     "post-setup false did not preserve short-circuit order")
        delegate.flushNonactivatingProbeGuardEvents(contextID: firstContext.id)
        let firstContextRows = guardRecords().filter {
            $0.contains("contextID=\(firstContext.id.uuidString)")
        }
        precondition(firstContextRows.count == 6, "three flushed batches did not record six reached operands")
        precondition(firstContextRows.contains(where: { $0.contains("predicate=post-setup-root-responder result=false") }),
                     "actual false post-setup operand was not recorded")
        precondition(!firstContextRows.contains(where: { $0.contains("predicate=post-setup-overlay-inactive") }),
                     "short-circuited operand was recorded")

        evaluated.removeAll()
        precondition(operand(firstContext.id, "cancel-pending", true), "pending cancel operand changed")
        precondition(delegate.probeGuardEvents.count == 1, "pending event was not retained before scope end")
        delegate.endNonactivatingProbeGuardSession(contextID: firstContext.id)
        precondition(delegate.probeGuardSessionContextID == nil, "scope end did not close the session")
        precondition(guardRecords().contains(where: { $0.contains("predicate=cancel-pending result=true") }),
                     "scope end did not flush its pending production record")

        evaluated.removeAll()
        let staleResult = operand(firstContext.id, "stale-after-end", false)
        precondition(!staleResult && evaluated == ["stale-after-end"],
                     "ended-context predicate was not evaluated exactly once")
        precondition(!guardRecords().contains(where: { $0.contains("predicate=stale-after-end") }),
                     "ended context recorded a later guard")
        delegate.endNonactivatingProbeGuardSession(contextID: firstContext.id)

        let replacementContext = makeContext()
        delegate.beginNonactivatingProbeTransaction(replacementContext)
        evaluated.removeAll()
        precondition(operand(replacementContext.id, "replacement-pending", true),
                     "replacement context operand changed")
        delegate.endNonactivatingProbeGuardSession(contextID: firstContext.id)
        delegate.flushNonactivatingProbeGuardEvents(contextID: firstContext.id)
        precondition(delegate.probeGuardSessionContextID == replacementContext.id
                     && delegate.probeGuardEvents.count == 1,
                     "stale end/flush touched the newer context")

        let nextContext = makeContext()
        delegate.beginNonactivatingProbeTransaction(nextContext)
        precondition(guardRecords().contains(where: {
            $0.contains("contextID=\(replacementContext.id.uuidString)")
                && $0.contains("predicate=replacement-pending")
        }), "replacement did not flush its previous context")
        delegate.endNonactivatingProbeGuardSession(contextID: replacementContext.id)
        delegate.flushNonactivatingProbeGuardEvents(contextID: replacementContext.id)
        precondition(delegate.probeGuardSessionContextID == nextContext.id,
                     "late prior-context cleanup cleared the current context")
        evaluated.removeAll()
        precondition(operand(nextContext.id, "current-after-stale-cleanup", true),
                     "current context operand changed after stale cleanup")
        delegate.flushNonactivatingProbeGuardEvents(contextID: nextContext.id)
        let nextRows = guardRecords().filter {
            $0.contains("contextID=\(nextContext.id.uuidString)")
        }
        precondition(nextRows.count == 1 && field("seq", in: nextRows[0]) == "1",
                     "new context did not start an independent sequence")
        delegate.endNonactivatingProbeGuardSession(contextID: nextContext.id)

        let budgetContext = makeContext()
        delegate.beginNonactivatingProbeTransaction(budgetContext)
        let budgetStart = guardRecords().count
        evaluated.removeAll()
        for index in 1...48 {
            precondition(operand(budgetContext.id, "budget-\(index)", true),
                         "a within-budget operand was rejected")
            if index.isMultiple(of: 6) {
                delegate.flushNonactivatingProbeGuardEvents(contextID: budgetContext.id)
            }
        }
        precondition(delegate.probeRecordCount == 48, "the transaction budget did not reach 48")
        let overflowResult = operand(budgetContext.id, "budget-overflow", false)
        precondition(!overflowResult && evaluated.count == 49,
                     "over-limit operand was not evaluated once with its original Bool")
        delegate.flushNonactivatingProbeGuardEvents(contextID: budgetContext.id)
        let budgetRows = Array(guardRecords().dropFirst(budgetStart))
            .filter { $0.contains("contextID=\(budgetContext.id.uuidString)") }
        precondition(budgetRows.count == 48, "multiple flushes reset the 48-record transaction limit")
        let budgetSequences = budgetRows.compactMap { field("seq", in: $0) }
        precondition(budgetSequences == (1...48).map(String.init),
                     "budget flushes changed the transaction sequence")
        precondition(!budgetRows.contains(where: { $0.contains("predicate=budget-overflow") }),
                     "over-limit operand was recorded")
        delegate.endNonactivatingProbeGuardSession(contextID: budgetContext.id)

        let undiagnosedDelegate = OverlayAppDelegate()
        undiagnosedDelegate.runtimeDirectoryURL = directory.appendingPathComponent("disabled")
        var undiagnosedEvaluationCount = 0
        let undiagnosedContextID = UUID()
        let undiagnosed = undiagnosedDelegate.probeGuardOperand(
            contextID: undiagnosedContextID,
            predicate: "disabled",
            value: {
                undiagnosedEvaluationCount += 1
                return true
            }()
        )
        precondition(undiagnosed && undiagnosedEvaluationCount == 1,
                     "inactive diagnostic scope changed the predicate")
        precondition(undiagnosedDelegate.probeGuardEvents.isEmpty
                     && undiagnosedDelegate.logURL.map { !FileManager.default.fileExists(atPath: $0.path) } == true,
                     "inactive diagnostic scope collected a record")

        print("guard-recorder-multi-batch batches=3 post-setup-false-prefix=2 actual-producer-flush=PASS")
        print("guard-recorder-scope end-flush=PASS ended-context-no-record=PASS stale-context-isolation=PASS replacement=PASS")
        print("guard-recorder-budget records=48 flushes=8 overflow-evaluated-once-not-recorded=PASS sequence=1...48")
        print("guard-recorder-disabled evaluation=once records=0 PASS")
    }
#endif

    private func removeOpeningDetailsReadinessHooks() {
        openingDetailsTimeoutTimer?.invalidate()
        openingDetailsTimeoutTimer = nil
        for observer in openingDetailsObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        openingDetailsObservers.removeAll()
        openingDetailsButton = nil
        activationRetryContextID = nil
    }

    private static func openingActivationRetryDecision(
        contextIsCurrent: Bool,
        retryAlreadyIssued: Bool,
        frontmostRole: String,
        overlayIsActive: Bool,
        sourceIsValid: Bool
    ) -> OpeningActivationRetryDecision {
        guard contextIsCurrent else { return .staleContext }
        if frontmostRole == "other" { return .hideForOtherApplication }
        if overlayIsActive { return .continueOpening }
        guard frontmostRole == "host" else { return .wait }
        guard sourceIsValid else { return .invalidSource }
        return retryAlreadyIssued ? .alreadyRetried : .retry
    }

    private func retryCooperativeActivationOnce(contextID: UUID) {
        guard let context = openingDetailsContext else {
            writeLog("details-open-activation-retry-skipped contextID=\(contextID.uuidString) currentContextID=none reason=no-pending-transaction")
            return
        }
        guard context.id == contextID else {
            writeLog("details-open-activation-retry-skipped contextID=\(contextID.uuidString) currentContextID=\(context.id.uuidString) reason=stale-transaction")
            return
        }
        guard let button = openingDetailsButton else {
            writeLog("details-open-activation-retry-skipped contextID=\(context.id.uuidString) reason=opening-button-unavailable hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber)")
            cancelOpeningDetails(reason: "opening-button-unavailable")
            return
        }

        let role = foregroundRole()
        let sourceIsValid = openingSourceIsValid(context: context, button: button)
        let decision = Self.openingActivationRetryDecision(
            contextIsCurrent: true,
            retryAlreadyIssued: activationRetryContextID == contextID,
            frontmostRole: role,
            overlayIsActive: NSApp.isActive,
            sourceIsValid: sourceIsValid
        )
        writeLog("details-open-activation-retry-check contextID=\(context.id.uuidString) frontmostRole=\(role) overlayActive=\(NSApp.isActive) sourceValid=\(sourceIsValid) decision=\(String(describing: decision)) hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none")")

        switch decision {
        case .retry:
            activationRetryContextID = contextID
            NSApp.activate()
            writeLog("details-open-activation-requested contextID=\(context.id.uuidString) activation=cooperative retry=one-shot-after-click-turn frontmostRole=\(foregroundRole()) overlayActive=\(NSApp.isActive) hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none")")
            if NSApp.isActive {
                continueOpeningDetails(contextID: contextID, trigger: "activation-retry-immediate")
            }
        case .continueOpening:
            continueOpeningDetails(contextID: contextID, trigger: "activation-retry-already-active")
        case .hideForOtherApplication:
            hideSummary(reason: "other-app-frontmost")
        case .invalidSource:
            hideSummary(reason: "details-host-or-anchor-invalid")
        case .wait:
            writeLog("details-open-activation-retry-wait contextID=\(context.id.uuidString) reason=frontmost-or-active-transition hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber)")
        case .staleContext:
            writeLog("details-open-activation-retry-skipped contextID=\(contextID.uuidString) currentContextID=\(context.id.uuidString) reason=stale-transaction")
        case .alreadyRetried:
            writeLog("details-open-activation-retry-skipped contextID=\(context.id.uuidString) reason=retry-already-issued hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber)")
        }
    }

    private func resumePendingDetails(contextID: UUID?, trigger: String) {
        guard let contextID else { return }
        guard let context = openingDetailsContext, context.id == contextID else {
            writeLog("details-open-resume-skipped contextID=\(contextID.uuidString) currentContextID=\(openingDetailsContext?.id.uuidString ?? "none") trigger=\(trigger) reason=transaction-no-longer-current")
            return
        }
        guard !detailsAreVisible else {
            writeLog("details-open-resume-skipped contextID=\(context.id.uuidString) trigger=\(trigger) reason=popover-already-shown hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none")")
            return
        }
        writeLog("details-open-resume contextID=\(context.id.uuidString) trigger=\(trigger) frontmostRole=\(foregroundRole()) overlayActive=\(NSApp.isActive) hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none")")
        continueOpeningDetails(contextID: context.id, trigger: trigger)
    }

    private func openingSourceIsValid(context: DetailsOpenContext, button: NSButton) -> Bool {
        let identity = HostWindowIdentity(pid: context.hostPID, windowNumber: context.hostWindowNumber)
        guard let panel = button.window as? SummaryPanel,
              panel.isVisible,
              panel.contentView === button,
              panel.rowIdentifier == context.rowIdentifier,
              panel.displayedHostIdentity == identity,
              panel.displayID == context.displayID,
              currentValidHostWindow(for: identity)?.windowNumber == context.hostWindowNumber
        else { return false }
        return true
    }

    private func nonactivatingDetailsStageAllows(
        context: DetailsOpenContext,
        stage: NonactivatingDetailsStage,
        frontmostApplication: NSRunningApplication?,
        overlayIsActive: Bool,
        sourceWindowAndLayoutIsValid: Bool,
        button: NSButton?,
        panel: NonactivatingDetailsPanel? = nil,
        content: DetailsViewController? = nil
    ) -> Bool {
        let openingMatches = openingDetailsContext?.id == context.id
        let shownMatches = detailsContext?.id == context.id
        let noForeignTransaction = (openingDetailsContext == nil || openingMatches) &&
            (detailsContext == nil || shownMatches)
        let currentTransactionIsExact: Bool
        switch stage {
        case .preKey, .postKey:
            currentTransactionIsExact = openingMatches && !shownMatches
        case .ongoing:
            currentTransactionIsExact = shownMatches && !openingMatches
        }
        let transactionIsUnique = noForeignTransaction && (openingMatches != shownMatches)
        let panelOwnershipIsValid: Bool
        if let panel, let content {
            panelOwnershipIsValid = nonactivatingDetailsPanel === panel &&
                panel.contentViewController === content &&
                panel.contentView === content.view &&
                content.view.window === panel
        } else {
            panelOwnershipIsValid = false
        }
        let responderBelongsToDetails: Bool
        if let panel, let content {
            responderBelongsToDetails = Self.responder(panel.firstResponder, belongsTo: content.view)
        } else {
            responderBelongsToDetails = false
        }

        let evidence = NonactivatingDetailsStageEvidence(
            stage: stage,
            isProbe: isNonactivatingDetailsProbe,
            overlayIsActive: overlayIsActive,
            currentTransactionIsExact: currentTransactionIsExact,
            transactionIsUnique: transactionIsUnique,
            frontmostPIDMatchesHost: frontmostApplication?.processIdentifier == context.hostPID,
            sourceWindowAndLayoutAreValid: sourceWindowAndLayoutIsValid,
            clickDisplayBindingIsValid: button.map { probeClickDisplayBindingIsValid(context: context, button: $0) } ?? false,
            panelBelongsToTransaction: panelOwnershipIsValid,
            panelUsesNonactivatingStyle: panel?.styleMask.contains(.nonactivatingPanel) == true,
            panelIsVisible: panel?.isVisible == true,
            panelIsKey: panel?.isKeyWindow == true,
            appKeyWindowIsPanel: panel.map { NSApp.keyWindow === $0 } == true,
            responderBelongsToDetails: responderBelongsToDetails
        )
        return NonactivatingDetailsStagePolicy.allows(evidence)
    }

    private func probeClickDisplayBindingIsValid(context: DetailsOpenContext, button: NSButton) -> Bool {
        guard context.source != "demo-bridge",
              context.displayID != nil,
              let summaryButton = button as? SummaryInputButton,
              summaryButton === self.summaryButton(for: context),
              let panel = summaryButton.window as? SummaryPanel,
              panel.isVisible,
              panel.contentView === summaryButton,
              panel.rowIdentifier == context.rowIdentifier,
              panel.displayedHostIdentity == HostWindowIdentity(pid: context.hostPID, windowNumber: context.hostWindowNumber),
              panel.displayID == context.displayID
        else { return false }

        switch context.source {
        case "summary-mouse":
            return context.clickID != nil
        case "summary-keyboard", "summary-keyboard-or-accessibility":
            return true
        default:
            return false
        }
    }

    private func nonactivatingPreKeyStageAllows(context: DetailsOpenContext, button: NSButton) -> Bool {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let overlayIsActive = NSApp.isActive
        let sourceIsValid = openingSourceIsValid(context: context, button: button)
        return nonactivatingDetailsStageAllows(
            context: context,
            stage: .preKey,
            frontmostApplication: frontmostApplication,
            overlayIsActive: overlayIsActive,
            sourceWindowAndLayoutIsValid: sourceIsValid,
            button: button
        )
    }

    private static func responder(_ responder: NSResponder?, belongsTo rootView: NSView) -> Bool {
        guard let responder, let rootWindow = rootView.window else { return false }
        if responder === rootView { return true }

        guard let view = responder as? NSView, view.window === rootWindow else { return false }
        var ancestor: NSView? = view
        while let current = ancestor {
            if current === rootView { return true }
            ancestor = current.superview
        }
        return false
    }

    private func continueOpeningDetails(contextID: UUID, trigger: String) {
        guard !isNonactivatingDetailsProbe else {
            writeLog("details-open-continue-skipped callbackContextID=\(contextID.uuidString) trigger=\(trigger) reason=probe-readiness-is-synchronous")
            return
        }
        guard let context = openingDetailsContext else {
            writeLog("details-open-continue-skipped callbackContextID=\(contextID.uuidString) trigger=\(trigger) currentContextID=none reason=no-pending-transaction")
            return
        }
        guard context.id == contextID else {
            writeLog("details-open-continue-skipped callbackContextID=\(contextID.uuidString) trigger=\(trigger) currentContextID=\(context.id.uuidString) reason=stale-transaction")
            return
        }
        guard let button = openingDetailsButton else {
            writeLog("details-open-continue-skipped contextID=\(context.id.uuidString) trigger=\(trigger) reason=opening-button-unavailable hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none")")
            cancelOpeningDetails(reason: "opening-button-unavailable")
            return
        }
        guard let popover else {
            writeLog("details-open-continue-skipped contextID=\(context.id.uuidString) trigger=\(trigger) reason=popover-unavailable hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none")")
            cancelOpeningDetails(reason: "popover-unavailable")
            return
        }
        writeLog("details-open-continue-enter contextID=\(context.id.uuidString) trigger=\(trigger) shown=\(popover.isShown) frontmostRole=\(foregroundRole()) overlayActive=\(NSApp.isActive) hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none")")

        if popover.isShown {
            attemptDetailsInteractionReady(contextID: contextID, trigger: trigger)
            return
        }

        let role = foregroundRole()
        guard NSApp.isActive, role == "overlay" else {
            if role == "other" {
                hideSummary(reason: "other-app-frontmost")
            } else {
                writeLog("details-open-wait contextID=\(context.id.uuidString) trigger=\(trigger) frontmostRole=\(role) overlayActive=\(NSApp.isActive) reason=awaiting-overlay-activation hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none")")
            }
            return
        }

        guard openingSourceIsValid(context: context, button: button) else {
            hideSummary(reason: "details-host-or-anchor-invalid")
            return
        }

        detailsContext = context
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxX)
        guard popover.isShown else {
            cancelOpeningDetails(reason: "popover-not-shown")
            writeLog("details-open-failed contextID=\(context.id.uuidString) row=\(context.rowIdentifier) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none") reason=popover-not-shown trigger=\(trigger)")
            if foregroundRole() == "overlay",
               currentValidHostWindow(for: HostWindowIdentity(pid: context.hostPID, windowNumber: context.hostWindowNumber))?.windowNumber == context.hostWindowNumber {
                let request = requestRestoreOfSourceWindow(context)
                writeLog("details-open-restore contextID=\(context.id.uuidString) request=\(request) reason=popover-not-shown")
            }
            DispatchQueue.main.async { [weak self] in self?.refreshPlacement() }
            return
        }

        writeLog("details-open-popover-shown contextID=\(context.id.uuidString) row=\(context.rowIdentifier) trigger=\(trigger) hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none") detailWindow=\(popover.contentViewController?.view.window?.windowNumber.description ?? "none") detailKey=\(popover.contentViewController?.view.window?.isKeyWindow ?? false) overlayActive=\(NSApp.isActive)")
        attemptDetailsInteractionReady(contextID: contextID, trigger: "popover-show-return")
    }

    private func openingDetailsWindowBecameKey(_ window: NSWindow, contextID: UUID) {
        guard openingDetailsContext?.id == contextID else {
            writeLog("details-open-key-callback-skipped callbackContextID=\(contextID.uuidString) currentContextID=\(openingDetailsContext?.id.uuidString ?? "none") reason=stale-transaction window=\(window.windowNumber)")
            return
        }
        guard popover?.isShown == true else {
            writeLog("details-open-key-callback-skipped contextID=\(contextID.uuidString) reason=popover-not-shown window=\(window.windowNumber)")
            return
        }
        guard popover?.contentViewController?.view.window === window else {
            writeLog("details-open-key-callback-skipped contextID=\(contextID.uuidString) reason=window-mismatch window=\(window.windowNumber) expected=\(popover?.contentViewController?.view.window?.windowNumber.description ?? "none")")
            return
        }
        attemptDetailsInteractionReady(contextID: contextID, trigger: "detail-window-did-become-key")
    }

    private func attemptDetailsInteractionReady(contextID: UUID, trigger: String) {
        guard let context = openingDetailsContext else {
            writeLog("details-open-readiness-skipped callbackContextID=\(contextID.uuidString) trigger=\(trigger) currentContextID=none reason=no-pending-transaction")
            return
        }
        guard context.id == contextID else {
            writeLog("details-open-readiness-skipped callbackContextID=\(contextID.uuidString) trigger=\(trigger) currentContextID=\(context.id.uuidString) reason=stale-transaction")
            return
        }
        guard let button = openingDetailsButton else {
            writeLog("details-open-readiness-skipped contextID=\(context.id.uuidString) trigger=\(trigger) reason=opening-button-unavailable hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none")")
            cancelOpeningDetails(reason: "opening-button-unavailable")
            return
        }
        guard let popover else {
            writeLog("details-open-readiness-skipped contextID=\(context.id.uuidString) trigger=\(trigger) reason=popover-unavailable hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none")")
            cancelOpeningDetails(reason: "popover-unavailable")
            return
        }
        guard popover.isShown else {
            writeLog("details-open-readiness-skipped contextID=\(context.id.uuidString) trigger=\(trigger) reason=popover-not-shown hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none")")
            return
        }
        guard let content = popover.contentViewController as? DetailsViewController else {
            writeLog("details-open-readiness-skipped contextID=\(context.id.uuidString) trigger=\(trigger) reason=details-controller-unavailable hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none")")
            cancelOpeningDetails(reason: "details-controller-unavailable")
            return
        }
        writeLog("details-open-readiness-enter contextID=\(context.id.uuidString) trigger=\(trigger) detailWindow=\(content.view.window?.windowNumber.description ?? "none") detailKey=\(content.view.window?.isKeyWindow ?? false) frontmostRole=\(foregroundRole()) overlayActive=\(NSApp.isActive) hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none")")

        let role = foregroundRole()
        guard NSApp.isActive, role == "overlay" else {
            if role == "other" { hideSummary(reason: "other-app-frontmost") }
            else {
                writeLog("details-open-wait contextID=\(context.id.uuidString) trigger=\(trigger) frontmostRole=\(role) overlayActive=\(NSApp.isActive) reason=awaiting-overlay-activation hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber)")
            }
            return
        }

        guard openingSourceIsValid(context: context, button: button) else {
            hideSummary(reason: "details-host-or-anchor-invalid")
            return
        }

        switch configureDetailsInteraction(context: context, content: content) {
        case .waitingForKey:
            writeLog("details-open-wait contextID=\(context.id.uuidString) trigger=\(trigger) reason=detail-window-not-key hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none")")
        case .failed(let reason):
            cancelOpeningDetails(reason: "interaction-setup-\(reason)")
            closeDetails(reason: "interaction-setup-failed", restoreIfSafe: true)
        case .ready:
            detailsContext = context
            openingDetailsContext = nil
            removeOpeningDetailsReadinessHooks()
            writeLog("details-open contextID=\(context.id.uuidString) source=\(context.source) row=\(context.rowIdentifier) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none") hostWindow=\(context.hostWindowNumber) hostPID=\(context.hostPID) openingFrontmost=\(context.openingFrontmostRole) mockData=true readyTrigger=\(trigger) \(detailsFocusFields(context: context, window: content.view.window, rootView: content.view)) sourceResponder=unobservable-without-host-modification")
        }
    }

    private func openingDetailsReadinessTimedOut(contextID: UUID) {
        guard let context = openingDetailsContext, context.id == contextID else {
            writeLog("details-open-timeout-skipped callbackContextID=\(contextID.uuidString) currentContextID=\(openingDetailsContext?.id.uuidString ?? "none") reason=stale-transaction")
            return
        }
        let shown = popover?.isShown == true
        let detailWindow = popover?.contentViewController?.view.window
        writeLog("details-open-timeout contextID=\(context.id.uuidString) shown=\(shown) detailWindow=\(detailWindow?.windowNumber.description ?? "none") detailKey=\(detailWindow?.isKeyWindow ?? false) overlayActive=\(NSApp.isActive) frontmostRole=\(foregroundRole()) hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none")")
        cancelOpeningDetails(reason: "interaction-readiness-timeout")
        if shown {
            closeDetails(reason: "interaction-readiness-timeout", restoreIfSafe: true)
        } else if foregroundRole() == "overlay",
                  currentValidHostWindow(for: HostWindowIdentity(pid: context.hostPID, windowNumber: context.hostWindowNumber))?.windowNumber == context.hostWindowNumber {
            let request = requestRestoreOfSourceWindow(context)
            writeLog("details-open-restore contextID=\(context.id.uuidString) request=\(request) reason=interaction-readiness-timeout")
        }
        DispatchQueue.main.async { [weak self] in self?.refreshPlacement() }
    }

    private func cancelSummaryPointerGesture(reason: String) {
        guard let gesture = pendingSummaryPointerGesture else { return }
        pendingSummaryPointerGesture = nil
        let hostFields = gesture.host.map { "hostPID=\($0.pid) hostWindow=\($0.windowNumber)" } ?? "hostPID=none hostWindow=none"
        writeLog("summary-input-cancelled row=\(gesture.rowIdentifier) clickID=\(gesture.id.uuidString) displayID=\(gesture.displayID?.uuidString ?? "none") \(hostFields) reason=\(reason)")
    }

    private func foregroundRole() -> String {
        guard let front = NSWorkspace.shared.frontmostApplication else { return "none" }
        if front.processIdentifier == ProcessInfo.processInfo.processIdentifier { return "overlay" }
        return front.bundleIdentifier == targetBundleID ? "host" : "other"
    }

    private func recordSummaryPanelPointerEvent(_ phase: String, panel: SummaryPanel, event: NSEvent) {
        let now = Date()
        let role = foregroundRole()
        if phase == "panel-mouseDown" {
            cancelSummaryPointerGesture(reason: "superseded-by-new-mouseDown")
            let hostIdentity = panel.displayedHostIdentity
            let hostIsValid = panel.isVisible && panel.displayID != nil &&
                (role == "host" || role == "overlay") &&
                hostIdentity.flatMap { currentValidHostWindow(for: $0, now: now) } != nil
            let validHost = hostIsValid ? hostIdentity : nil
            if !hostIsValid {
                let reason = !panel.isVisible ? "panel-not-visible" :
                    (panel.displayID == nil || hostIdentity == nil ? "display-binding-missing" :
                        ((role != "host" && role != "overlay") ? "frontmost-\(role)" : "display-host-window-invalid"))
                writeLog("summary-input-source-invalid row=\(panel.rowIdentifier) displayID=\(panel.displayID?.uuidString ?? "none") displayedHostPID=\(hostIdentity?.pid.description ?? "none") displayedHostWindow=\(hostIdentity?.windowNumber.description ?? "none") frontmost=\(role) reason=\(reason)")
            }
            pendingSummaryPointerGesture = SummaryPointerGesture(
                id: UUID(),
                rowIdentifier: panel.rowIdentifier,
                host: validHost,
                displayID: panel.displayID,
                startedAt: now
            )
        }

        let gesture = currentSummaryPointerGesture(now: now)
        let matchingGesture = gesture?.rowIdentifier == panel.rowIdentifier && gesture?.displayID == panel.displayID ? gesture : nil
        let identity = matchingGesture?.host ?? panel.displayedHostIdentity
        let contextValid = identity.flatMap { currentValidHostWindow(for: $0, now: now) } != nil
        let localPoint = event.locationInWindow
        let screenPoint = panel.convertPoint(toScreen: localPoint)
        let button = panel.contentView as? SummaryInputButton
        let buttonPoint = button?.convert(localPoint, from: nil)
        let buttonBounds = button?.bounds
        let hitView = button.flatMap { value -> NSView? in
            guard let point = buttonPoint else { return nil }
            return value.hitTest(point)
        }
        let buttonFrame = button.map { panel.convertToScreen($0.convert($0.bounds, to: nil)) }
        let hostFields: String
        if let identity {
            hostFields = "hostPID=\(identity.pid) hostWindow=\(identity.windowNumber)"
        } else {
            hostFields = "hostPID=none hostWindow=none"
        }
        let buttonLocalFields = buttonPoint.map { "buttonPoint=(\(Int($0.x)),\(Int($0.y)))" } ?? "buttonPoint=none"
        let buttonBoundsFields = buttonBounds.map { "buttonBounds=\(string($0))" } ?? "buttonBounds=none"
        let buttonFrameFields = buttonFrame.map { "buttonFrame=\(string($0))" } ?? "buttonFrame=none"
        writeLog("summary-panel-input phase=\(phase) row=\(panel.rowIdentifier) event=\(String(describing: event.type)) frontmost=\(role) \(hostFields) displayedHostPID=\(panel.displayedHostIdentity?.pid.description ?? "none") displayedHostWindow=\(panel.displayedHostIdentity?.windowNumber.description ?? "none") contextValid=\(contextValid) displayID=\(panel.displayID?.uuidString ?? "none") clickID=\(matchingGesture?.id.uuidString ?? "none") buttonHit=\(hitView === button && button != nil) \(buttonLocalFields) \(buttonBoundsFields) \(buttonFrameFields) windowPoint=(\(Int(localPoint.x)),\(Int(localPoint.y))) screenPoint=(\(Int(screenPoint.x)),\(Int(screenPoint.y))) panelFrame=\(string(panel.frame))")

        if phase == "panel-mouseUp-after-action", let gesture = matchingGesture {
            if !gesture.actionReached {
                writeLog("summary-input-action-missing row=\(gesture.rowIdentifier) clickID=\(gesture.id.uuidString) displayID=\(gesture.displayID?.uuidString ?? "none") reason=button-action-not-reached")
            }
            pendingSummaryPointerGesture = nil
            if !gesture.actionReached {
                DispatchQueue.main.async { [weak self] in self?.refreshPlacement() }
            }
        }
    }

    private func recordSummaryButtonPointerEvent(_ phase: String, button: SummaryInputButton, event: NSEvent) {
        let now = Date()
        let role = foregroundRole()
        let panel = button.window as? SummaryPanel
        let gesture = currentSummaryPointerGesture(now: now)
        let observedGesture = gesture?.rowIdentifier == button.rowIdentifier && gesture?.displayID == panel?.displayID ? gesture : nil
        let matchingGesture = observedGesture.flatMap { gesture -> SummaryPointerGesture? in
            guard let gestureHost = gesture.host,
                  gesture.displayID != nil,
                  gestureHost == panel?.displayedHostIdentity
            else { return nil }
            return gesture
        }
        let identity = matchingGesture?.host ?? panel?.displayedHostIdentity
        let contextValid = identity.flatMap { currentValidHostWindow(for: $0, now: now) } != nil
        let localPoint = event.locationInWindow
        let screenPoint = button.window?.convertPoint(toScreen: localPoint)
        let buttonPoint = button.convert(localPoint, from: nil)
        let screenFields = screenPoint.map { "screenPoint=(\(Int($0.x)),\(Int($0.y)))" } ?? "screenPoint=none"
        let buttonFrame = button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
        let frameFields = buttonFrame.map { "buttonFrame=\(string($0))" } ?? "buttonFrame=none"
        let hostFields = identity.map { "hostPID=\($0.pid) hostWindow=\($0.windowNumber)" } ?? "hostPID=none hostWindow=none"
        let panelFields = panel.map { "displayedHostPID=\($0.displayedHostIdentity?.pid.description ?? "none") displayedHostWindow=\($0.displayedHostIdentity?.windowNumber.description ?? "none") displayID=\($0.displayID?.uuidString ?? "none") panelFrame=\(string($0.frame))" } ?? "displayedHostPID=none displayedHostWindow=none displayID=none panelFrame=none"
        writeLog("summary-button-input phase=\(phase) row=\(button.rowIdentifier) event=\(String(describing: event.type)) frontmost=\(role) \(hostFields) \(panelFields) contextValid=\(contextValid) clickID=\(observedGesture?.id.uuidString ?? "none") sourceBindingValid=\(matchingGesture != nil) buttonPoint=(\(Int(buttonPoint.x)),\(Int(buttonPoint.y))) buttonBounds=\(string(button.bounds)) \(screenFields) \(frameFields)")
    }

    private func reasonForCurrentState() -> String {
        guard let front = NSWorkspace.shared.frontmostApplication else { return "no-frontmost-app" }
        let app: NSRunningApplication?
        let detailsIdentity = openingDetailsContext.map { HostWindowIdentity(pid: $0.hostPID, windowNumber: $0.hostWindowNumber) }
            ?? (detailsAreVisible ? detailsContext.map { HostWindowIdentity(pid: $0.hostPID, windowNumber: $0.hostWindowNumber) } : nil)
            ?? currentSummaryPointerGesture(now: Date())?.host
        if front.bundleIdentifier == targetBundleID {
            app = front
        } else if front.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                  let detailsIdentity {
            app = NSRunningApplication(processIdentifier: detailsIdentity.pid)
        } else {
            return "other-app-frontmost"
        }
        guard let app, !app.isTerminated else { return "target-process-unavailable" }
        if !isAllowedTarget(app) { return "target-path-not-verified" }
        if app.isHidden { return "target-hidden" }
        if currentHostWindow(pid: app.processIdentifier) == nil { return "no-on-screen-window" }
        return lastLayoutFailure == "" ? "window-too-small-or-fullscreen" : lastLayoutFailure
    }

    private var lastLayoutFailure = "rail-state-unknown"

    private func key(for host: HostWindow) -> String { "\(host.pid):\(host.windowNumber)" }

    private func receiveDemoLayout(_ userInfo: [AnyHashable: Any]?) {
        guard isDemoTarget,
              let info = userInfo,
              let pidNumber = info["pid"] as? NSNumber,
              let windowNumber = info["windowID"] as? NSNumber,
              let visibleNumber = info["visible"] as? NSNumber,
              let railWidth = info["railWidth"] as? NSNumber,
              let railX = info["railX"] as? NSNumber,
              let railY = info["railY"] as? NSNumber,
              let railW = info["railW"] as? NSNumber,
              let railH = info["railH"] as? NSNumber,
              let anchorX = info["anchorX"] as? NSNumber,
              let anchorY = info["anchorY"] as? NSNumber,
              let anchorW = info["anchorW"] as? NSNumber,
              let anchorH = info["anchorH"] as? NSNumber,
              let timestamp = info["timestamp"] as? NSNumber
        else { return }

        let pid = pid_t(pidNumber.int32Value)
        guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == targetBundleID else { return }
        let windowID = CGWindowID(windowNumber.uint32Value)
        let layoutKey = "\(pid):\(windowID)"
        let receivedAt = Date()
        let updatedAt = Date(timeIntervalSince1970: timestamp.doubleValue)
        let previous = demoLayouts[layoutKey]
        if let previous, updatedAt < previous.updatedAt {
            writeLog("layout-response-ignored reason=out-of-order pid=\(pid) windowID=\(windowID) senderUpdatedAt=\(timestamp.doubleValue) storedUpdatedAt=\(previous.updatedAt.timeIntervalSince1970)")
            return
        }

        let layout = RailLayout(
            isVisible: visibleNumber.boolValue,
            railWidth: CGFloat(railWidth.doubleValue),
            railFrame: CGRect(x: railX.doubleValue, y: railY.doubleValue, width: railW.doubleValue, height: railH.doubleValue),
            emptyAnchor: CGRect(x: anchorX.doubleValue, y: anchorY.doubleValue, width: anchorW.doubleValue, height: anchorH.doubleValue),
            updatedAt: updatedAt
        )
        demoLayouts[layoutKey] = layout

        let requestID = info["requestID"] as? String
        let pending = pendingDemoLayoutRequest
        let isRequestedWindow = pending?.hostPID == pid && pending?.windowNumber == windowID
        let requestIDMatches = isRequestedWindow && requestID == pending?.id
        let isFreshUnsolicitedReply = isRequestedWindow && updatedAt >= (pending?.sentAt ?? .distantPast)
        if requestIDMatches || isFreshUnsolicitedReply {
            pendingDemoLayoutRequest = nil
        }
        let requestLag = isRequestedWindow ? receivedAt.timeIntervalSince(pending?.sentAt ?? receivedAt) : nil
        let geometryChanged = previous.map {
            $0.isVisible != layout.isVisible || $0.railWidth != layout.railWidth ||
                $0.railFrame != layout.railFrame || $0.emptyAnchor != layout.emptyAnchor
        } ?? true
        let stateAge = receivedAt.timeIntervalSince(updatedAt)
        writeLog("layout-response pid=\(pid) windowID=\(windowID) senderUpdatedAt=\(timestamp.doubleValue) stateAge=\(String(format: "%.3f", stateAge)) geometryChanged=\(geometryChanged) requestID=\(requestID ?? "none") requestMatched=\(requestIDMatches) requestLag=\(requestLag.map { String(format: "%.3f", $0) } ?? "none") visible=\(layout.isVisible)")
        let pendingContextID = openingDetailsContext?.id
        refreshPlacement()
        resumePendingDetails(contextID: pendingContextID, trigger: "demo-layout-response")
    }

    private func requestDemoLayoutsIfNeeded(for host: HostWindow, now: Date) {
        guard isDemoTarget else { return }
        let layout = demoLayouts[key(for: host)]
        guard DemoLayoutRefreshPolicy.shouldRequest(
            now: now,
            updatedAt: layout?.updatedAt,
            lastRequestAt: lastDemoLayoutRequest,
            inFlightSince: pendingDemoLayoutRequest?.sentAt
        ) else { return }

        let request = DemoLayoutRequest(
            id: UUID().uuidString,
            hostPID: host.pid,
            windowNumber: host.windowNumber,
            sentAt: now
        )
        lastDemoLayoutRequest = now
        pendingDemoLayoutRequest = request
        let stateAge = layout.map { String(format: "%.3f", now.timeIntervalSince($0.updatedAt)) } ?? "unknown"
        let reason = layout.map { _ in "refresh-before-expiry" } ?? "missing"
        writeLog("layout-request pid=\(host.pid) windowID=\(host.windowNumber) requestID=\(request.id) stateAge=\(stateAge) reason=\(reason)")
        DistributedNotificationCenter.default().postNotificationName(
            DemoBridge.requestLayout,
            object: nil,
            userInfo: [
                "pid": Int(host.pid),
                "windowID": Int(host.windowNumber),
                "requestID": request.id,
            ],
            deliverImmediately: true
        )
    }

    private func validPlacement(for host: HostWindow) -> CGRect? {
        let layout = isDemoTarget ? demoLayouts[key(for: host)] : nil
        let visibility: OverlayPlacement.Visibility
        if let layout {
            visibility = layout.isVisible ? .expanded : .collapsed
        } else {
            visibility = .unknown
        }
        let decision = OverlayPlacement.evaluate(.init(
            hostFrame: host.appKitFrame,
            railFrame: layout?.railFrame ?? .zero,
            reportedRailWidth: layout?.railWidth ?? 0,
            emptyArea: layout?.emptyAnchor ?? .zero,
            visibility: visibility,
            updatedAt: layout?.updatedAt,
            now: Date()
        ))
        if let failure = decision.failure {
            lastLayoutFailure = isDemoTarget
                ? "demo-\(failure.rawValue)"
                : "formal-rail-anchor-unavailable-\(failure.rawValue)"
            return nil
        }
        lastLayoutFailure = ""
        return decision.summaryFrame
    }

    private func isAllowedTarget(_ app: NSRunningApplication) -> Bool {
        guard targetBundleID == "com.openai.codex" else { return true }
        return app.bundleURL?.standardizedFileURL.path == expectedCodexPath
    }

    private func currentHostWindow(pid: pid_t) -> HostWindow? {
        hostWindow(pid: pid, windowNumber: nil)
    }

    private func hostWindow(pid: pid_t, windowNumber: CGWindowID?) -> HostWindow? {
        hostWindow(pid: pid, windowNumber: windowNumber, windowList: onScreenWindowInfo())
    }

    private func currentHostWindow(pid: pid_t, windowList: [[String: Any]]) -> HostWindow? {
        hostWindow(pid: pid, windowNumber: nil, windowList: windowList)
    }

    private func hostWindow(pid: pid_t, windowNumber: CGWindowID?, windowList: [[String: Any]]) -> HostWindow? {
        for item in windowList {
            let ownerPID = (item[kCGWindowOwnerPID as String] as? Int32) ?? Int32(item[kCGWindowOwnerPID as String] as? Int ?? -1)
            guard ownerPID == pid,
                  (item[kCGWindowLayer as String] as? Int ?? -1) == 0,
                  let number = item[kCGWindowNumber as String] as? UInt32,
                  windowNumber == nil || windowNumber == number
            else { continue }
            let bounds = item[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let cgRect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            guard cgRect.width >= 700, cgRect.height >= 400,
                  let appKit = convertToAppKit(cgRect)
            else { continue }
            return HostWindow(windowNumber: number, pid: pid, cgBounds: cgRect, appKitFrame: appKit)
        }
        return nil
    }

    private func convertToAppKit(_ rect: CGRect) -> CGRect? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            let cgScreen = CGDisplayBounds(displayID)
            guard cgScreen.contains(center), cgScreen.width > 0, cgScreen.height > 0 else { continue }
            let scaleX = cgScreen.width / screen.frame.width
            let scaleY = cgScreen.height / screen.frame.height
            let x = screen.frame.minX + (rect.minX - cgScreen.minX) / scaleX
            let y = screen.frame.minY + (cgScreen.maxY - rect.maxY) / scaleY
            return NSRect(x: x, y: y, width: rect.width / scaleX, height: rect.height / scaleY)
        }
        return nil
    }

    private func looksFullscreen(_ frame: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            let visible = screen.frame
            let overlap = visible.intersection(frame)
            return overlap.width >= visible.width * 0.985 && overlap.height >= visible.height * 0.985
        }
    }

    private func updateClock() {
        let now = formattedNow()
        if let time = summaryButtons.last as? TimeButton {
            time.timeText = now
            time.accessibilityText = "模拟数据覆盖层当前时间 Asia/Shanghai \(now)"
            time.needsDisplay = true
        }
        if let details = currentDetailsContent, detailsAreVisible {
            details.update(values: values)
        }
    }

    private func formattedNow() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date())
    }

    @objc private func openDetails(_ sender: NSButton) {
        let button = sender as? SummaryInputButton
        let panel = button?.window as? SummaryPanel
        let rowIdentifier = button?.rowIdentifier ?? "unknown"
        let event = NSApp.currentEvent
        let eventType = event.map { String(describing: $0.type) } ?? "none"
        let usedDemoBridge = openedViaDemoBridge
        openedViaDemoBridge = false
        if isNonactivatingDetailsProbe, usedDemoBridge {
            writeLog("details-open-denied row=\(rowIdentifier) reason=probe-demo-bridge-open-disabled")
            return
        }
        let gesture = currentSummaryPointerGesture(now: Date())
        let pointerActivation = event?.type == .leftMouseUp && !usedDemoBridge
        let observedGesture = gesture?.rowIdentifier == rowIdentifier ? gesture : nil
        let matchingGesture: SummaryPointerGesture?
        if let observedGesture,
           observedGesture.displayID != nil,
           observedGesture.displayID == panel?.displayID,
           let gestureHost = observedGesture.host,
           gestureHost == panel?.displayedHostIdentity {
            matchingGesture = observedGesture
        } else {
            matchingGesture = nil
        }
        let clickID = matchingGesture?.id ?? (pointerActivation ? observedGesture?.id : nil)
        let displayID = matchingGesture?.displayID ?? panel?.displayID
        if let observedGesture {
            var updatedGesture = observedGesture
            updatedGesture.actionReached = true
            pendingSummaryPointerGesture = updatedGesture
        }
        let hostIdentity = matchingGesture?.host ?? (pointerActivation ? nil : activeHost.map(HostWindowIdentity.init))
        let contextValid = hostIdentity.flatMap { currentValidHostWindow(for: $0) } != nil
        let openingFrontmostRole = foregroundRole()
        let hostFields = hostIdentity.map { "hostPID=\($0.pid) hostWindow=\($0.windowNumber)" } ?? "hostPID=none hostWindow=none"
        writeLog("details-open-attempt row=\(rowIdentifier) event=\(eventType) frontmost=\(openingFrontmostRole) \(hostFields) clickID=\(clickID?.uuidString ?? "none") displayID=\(displayID?.uuidString ?? "none") contextValid=\(contextValid)")

        if pointerActivation && matchingGesture == nil {
            writeLog("details-open-denied row=\(rowIdentifier) clickID=\(clickID?.uuidString ?? "none") displayID=\(displayID?.uuidString ?? "none") reason=click-display-binding-mismatch")
            return
        }

        guard let hostIdentity else {
            writeLog("details-open-denied row=\(rowIdentifier) clickID=\(clickID?.uuidString ?? "none") displayID=\(displayID?.uuidString ?? "none") reason=host-context-missing")
            return
        }
        if let pendingContext = openingDetailsContext {
            writeLog("details-open-ignored row=\(rowIdentifier) clickID=\(clickID?.uuidString ?? "none") displayID=\(displayID?.uuidString ?? "none") reason=opening-transaction-pending contextID=\(pendingContext.id.uuidString) pendingClickID=\(pendingContext.clickID?.uuidString ?? "none") pendingHostPID=\(pendingContext.hostPID) pendingHostWindow=\(pendingContext.hostWindowNumber)")
            return
        }
        if detailsAreVisible {
            writeLog("details-open-toggle-close row=\(rowIdentifier) clickID=\(clickID?.uuidString ?? "none") displayID=\(displayID?.uuidString ?? "none") source=\(detailsContext?.source ?? "unknown")")
            closeDetails(reason: "summary-toggle", restoreIfSafe: true)
            return
        }

        let isExplicitPointerAction = matchingGesture != nil
        guard openingFrontmostRole == "host" ||
              (openingFrontmostRole == "overlay" && (isExplicitPointerAction || usedDemoBridge))
        else {
            writeLog("details-open-denied row=\(rowIdentifier) clickID=\(clickID?.uuidString ?? "none") displayID=\(displayID?.uuidString ?? "none") reason=frontmost-\(openingFrontmostRole)")
            if openingFrontmostRole == "other" { hideSummary(reason: "other-app-frontmost") }
            return
        }

        guard contextValid,
              let host = currentValidHostWindow(for: hostIdentity)
        else {
            writeLog("details-open-denied row=\(rowIdentifier) clickID=\(clickID?.uuidString ?? "none") displayID=\(displayID?.uuidString ?? "none") reason=host-window-or-anchor-invalid")
            if openingFrontmostRole == "overlay" { hideSummary(reason: "details-host-or-anchor-invalid") }
            return
        }

        let source: String
        if usedDemoBridge {
            source = "demo-bridge"
        } else if isExplicitPointerAction {
            source = "summary-mouse"
        } else if event?.type == .keyDown {
            source = "summary-keyboard"
        } else {
            source = "summary-keyboard-or-accessibility"
        }
        let context = DetailsOpenContext(
            id: UUID(),
            rowIdentifier: rowIdentifier,
            hostWindowNumber: host.windowNumber,
            hostPID: host.pid,
            openingFrontmostRole: openingFrontmostRole,
            source: source,
            clickID: clickID,
            displayID: displayID
        )
        openingDetailsContext = context

        let content = DetailsViewController(values: values, appearanceChanged: { [weak self] mode in
            self?.setAppearance(mode)
        }, refreshRequested: { [weak self] in
            guard let self else { return }
            self.values.refresh()
            self.writeLog("mock-refresh snapshot=\(ISO8601DateFormatter().string(from: self.values.snapshotAt)) network=false")
            self.updateClock()
        })
        if isNonactivatingDetailsProbe {
            presentNonactivatingDetails(context: context, button: sender, content: content)
            return
        }
        let popover = NSPopover()
        popover.contentViewController = content
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        self.popover = popover
        installOpeningDetailsReadinessHooks(contextID: context.id, button: sender)
        writeLog("details-open-readiness-start contextID=\(context.id.uuidString) source=\(source) row=\(rowIdentifier) hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber) clickID=\(clickID?.uuidString ?? "none") displayID=\(displayID?.uuidString ?? "none") frontmostRole=\(openingFrontmostRole) overlayActive=\(NSApp.isActive) timeout=\(openingDetailsTimeout)")

        if NSApp.isActive {
            continueOpeningDetails(contextID: context.id, trigger: "already-active")
        } else {
            NSApp.activate()
            writeLog("details-open-activation-requested contextID=\(context.id.uuidString) activation=cooperative frontmostRole=\(foregroundRole()) overlayActive=\(NSApp.isActive) hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber) clickID=\(clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none")")
            if NSApp.isActive {
                continueOpeningDetails(contextID: context.id, trigger: "activation-immediate")
            } else {
                DispatchQueue.main.async { [weak self] in
                    Task { @MainActor in self?.retryCooperativeActivationOnce(contextID: context.id) }
                }
                writeLog("details-open-activation-retry-scheduled contextID=\(context.id.uuidString) trigger=after-click-event hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber) clickID=\(clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none")")
            }
        }
    }

    private func presentNonactivatingDetails(
        context: DetailsOpenContext,
        button: NSButton,
        content: DetailsViewController
    ) {
        openingDetailsButton = button
        beginNonactivatingProbeTransaction(context)
        guard probeGuardOperand(contextID: context.id, predicate: "probe-enabled", value: isNonactivatingDetailsProbe),
              probeGuardOperand(contextID: context.id, predicate: "opening-context-current", value: openingDetailsContext?.id == context.id),
              probeGuardOperand(contextID: context.id, predicate: "pre-key-stage-policy", value: nonactivatingPreKeyStageAllows(context: context, button: button))
        else {
            flushNonactivatingProbeGuardEvents(contextID: context.id)
            recordNonactivatingProbeState(checkpoint: "source-guard-rejected", context: context, panel: nil, rootView: nil)
            cancelOpeningDetails(reason: "probe-source-or-frontmost-invalid")
            return
        }
        flushNonactivatingProbeGuardEvents(contextID: context.id)
        recordNonactivatingProbeState(checkpoint: "source-guard-passed", context: context, panel: nil, rootView: nil)

        content.loadViewIfNeeded()
        let size = content.preferredContentSize
        guard probeGuardOperand(contextID: context.id, predicate: "details-width-positive", value: size.width > 0),
              probeGuardOperand(contextID: context.id, predicate: "details-height-positive", value: size.height > 0),
              let frame = nonactivatingDetailsFrame(button: button, size: size)
        else {
            flushNonactivatingProbeGuardEvents(contextID: context.id)
            recordNonactivatingProbeState(checkpoint: "anchor-guard-rejected", context: context, panel: nil, rootView: content.view)
            cancelOpeningDetails(reason: "probe-anchor-or-screen-unavailable")
            return
        }
        flushNonactivatingProbeGuardEvents(contextID: context.id)
        recordNonactivatingProbeState(checkpoint: "before-panel-create", context: context, panel: nil, rootView: content.view)

        let panel = NonactivatingDetailsPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = content
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .normal
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.animationBehavior = .none
        panel.appearance = appearanceMode.appearance
        panel.becomesKeyOnlyIfNeeded = false
        nonactivatingDetailsPanel = panel
        recordNonactivatingProbeState(checkpoint: "before-order-front-regardless", context: context, panel: panel, rootView: content.view)
        panel.orderFrontRegardless()
        recordNonactivatingProbeState(checkpoint: "after-order-front-regardless", context: context, panel: panel, rootView: content.view)

        guard probeGuardOperand(contextID: context.id, predicate: "panel-visible", value: panel.isVisible),
              probeGuardOperand(contextID: context.id, predicate: "pre-key-stage-policy", value: nonactivatingPreKeyStageAllows(context: context, button: button))
        else {
            flushNonactivatingProbeGuardEvents(contextID: context.id)
            recordNonactivatingProbeState(checkpoint: "post-order-guard-rejected", context: context, panel: panel, rootView: content.view)
            writeLog("details-open-panel-presented contextID=\(context.id.uuidString) visible=\(panel.isVisible) panelKey=\(panel.isKeyWindow) overlayActive=\(NSApp.isActive) frontmostRole=\(foregroundRole()) reason=pre-key-state-invalid hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber)")
            cancelOpeningDetails(reason: "probe-pre-key-state-invalid")
            return
        }
        flushNonactivatingProbeGuardEvents(contextID: context.id)
        recordNonactivatingProbeState(checkpoint: "post-order-guard-passed", context: context, panel: panel, rootView: content.view)

        switch configureDetailsInteraction(context: context, content: content) {
        case .waitingForKey:
            cancelOpeningDetails(reason: "probe-panel-not-key")
        case .failed(let reason):
            cancelOpeningDetails(reason: "probe-interaction-setup-\(reason)")
        case .ready:
            guard probeGuardOperand(contextID: context.id, predicate: "panel-is-key-window", value: panel.isKeyWindow),
                  probeGuardOperand(contextID: context.id, predicate: "details-root-is-first-responder", value: panel.firstResponder === content.view),
                  probeGuardOperand(contextID: context.id, predicate: "post-key-stage-policy", value: nonactivatingDetailsStageAllows(
                    context: context,
                    stage: .postKey,
                    frontmostApplication: NSWorkspace.shared.frontmostApplication,
                    overlayIsActive: NSApp.isActive,
                    sourceWindowAndLayoutIsValid: openingSourceIsValid(context: context, button: button),
                    button: button,
                    panel: panel,
                    content: content
                  ))
            else {
                flushNonactivatingProbeGuardEvents(contextID: context.id)
                recordNonactivatingProbeState(checkpoint: "post-setup-guard-rejected", context: context, panel: panel, rootView: content.view)
                cancelOpeningDetails(reason: "probe-post-setup-state-invalid")
                return
            }
            flushNonactivatingProbeGuardEvents(contextID: context.id)
            recordNonactivatingProbeState(checkpoint: "post-setup-guard-passed", context: context, panel: panel, rootView: content.view)
            detailsContext = context
            openingDetailsContext = nil
            removeOpeningDetailsReadinessHooks()
            recordNonactivatingProbeState(checkpoint: "after-details-context-commit", context: context, panel: panel, rootView: content.view)
            writeLog("details-open contextID=\(context.id.uuidString) source=\(context.source) row=\(context.rowIdentifier) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none") hostWindow=\(context.hostWindowNumber) hostPID=\(context.hostPID) openingFrontmost=\(context.openingFrontmostRole) mockData=true container=nonactivating-panel overlayActive=\(NSApp.isActive) panelKey=\(panel.isKeyWindow) firstResponderIsRoot=\(panel.firstResponder === content.view) \(detailsFocusFields(context: context, window: panel, rootView: content.view)) sourceResponder=unobservable-without-host-modification")
            endNonactivatingProbeGuardSession(contextID: context.id)
        }
    }

    private func updateNonactivatingDetailsPanelPosition(
        context: DetailsOpenContext,
        frontmostApplication: NSRunningApplication?,
        overlayIsActive: Bool,
        sourceWindowAndLayoutIsValid: Bool
    ) -> Bool {
        guard let panel = nonactivatingDetailsPanel,
              let content = panel.contentViewController as? DetailsViewController,
              let button = summaryButton(for: context),
              nonactivatingDetailsStageAllows(
                context: context,
                stage: .ongoing,
                frontmostApplication: frontmostApplication,
                overlayIsActive: overlayIsActive,
                sourceWindowAndLayoutIsValid: sourceWindowAndLayoutIsValid,
                button: button,
                panel: panel,
                content: content
              ),
              let frame = nonactivatingDetailsFrame(button: button, size: content.preferredContentSize)
        else { return false }
        panel.setFrame(frame, display: false, animate: false)
        return true
    }

    private func summaryButton(for context: DetailsOpenContext) -> SummaryInputButton? {
        let identity = HostWindowIdentity(pid: context.hostPID, windowNumber: context.hostWindowNumber)
        guard let panel = rowPanels.first(where: {
            $0.rowIdentifier == context.rowIdentifier &&
                $0.displayedHostIdentity == identity &&
                $0.displayID == context.displayID
        }) else { return nil }
        return panel.contentView as? SummaryInputButton
    }

    private func nonactivatingDetailsFrame(button: NSButton, size: NSSize) -> NSRect? {
        guard let window = button.window,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0
        else { return nil }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard !anchor.isNull, !anchor.isInfinite,
              let screen = window.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(anchor) })
        else { return nil }
        let visible = screen.visibleFrame
        guard size.width <= visible.width, size.height <= visible.height else { return nil }

        let gap: CGFloat = 8
        var x = anchor.maxX + gap
        if x + size.width > visible.maxX { x = anchor.minX - gap - size.width }
        x = min(max(x, visible.minX), visible.maxX - size.width)
        let y = min(max(anchor.midY - size.height / 2, visible.minY), visible.maxY - size.height)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closedPopover = notification.object as? NSPopover,
              let activePopover = popover,
              closedPopover === activePopover
        else {
            writeLog("details-popover-close-ignored reason=stale-instance")
            return
        }

        let pendingContext = openingDetailsContext
        let context = detailsContext ?? openingDetailsContext
        let disposition = closeDisposition
        let detailWindow = activePopover.contentViewController?.view.window
        let rootView = activePopover.contentViewController?.view
        let focusAtClose = context.map {
            detailsFocusFields(context: $0, window: detailWindow, rootView: rootView)
        } ?? "contextID=none"
        removeDetailsEventMonitors(contextID: context?.id, reason: disposition?.reason ?? "popover-closed")
        removeOpeningDetailsReadinessHooks()
        if let pendingContext {
            writeLog("details-open-cancelled contextID=\(pendingContext.id.uuidString) reason=popover-closed-before-interactive row=\(pendingContext.rowIdentifier) source=\(pendingContext.source) hostPID=\(pendingContext.hostPID) hostWindow=\(pendingContext.hostWindowNumber) clickID=\(pendingContext.clickID?.uuidString ?? "none") displayID=\(pendingContext.displayID?.uuidString ?? "none")")
        }
        detailsContext = nil
        openingDetailsContext = nil
        closeDisposition = nil
        popover = nil

        let front = NSWorkspace.shared.frontmostApplication
        var restoreOutcome = "not-requested"
        if disposition?.restoreIfSafe == true, let context {
            let sourceIdentity = HostWindowIdentity(pid: context.hostPID, windowNumber: context.hostWindowNumber)
            let sourceIsValid = currentValidHostWindow(for: sourceIdentity) != nil
            let sourceAppIsFrontmost = front?.processIdentifier == context.hostPID
            let overlayIsFrontmost = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            let currentSourceWindow = currentHostWindow(pid: context.hostPID)?.windowNumber

            if !sourceIsValid {
                restoreOutcome = "source-window-invalid"
            } else if sourceAppIsFrontmost, currentSourceWindow == context.hostWindowNumber {
                restoreOutcome = "source-window-already-frontmost"
            } else if overlayIsFrontmost,
                      activeHost.map(HostWindowIdentity.init) == sourceIdentity,
                      currentSourceWindow == context.hostWindowNumber {
                restoreOutcome = requestRestoreOfSourceWindow(context)
                if restoreOutcome.hasSuffix("requested") {
                    let restoreRequest = restoreOutcome
                    DispatchQueue.main.async { [weak self] in
                        self?.recordSourceFocusObservation(context, request: restoreRequest)
                    }
                }
            } else if sourceAppIsFrontmost {
                restoreOutcome = "source-app-window-mismatch"
            } else {
                restoreOutcome = "skipped-other-app-frontmost"
            }
        }
        writeLog("details-close contextID=\(context?.id.uuidString ?? "none") row=\(context?.rowIdentifier ?? "unknown") source=\(context?.source ?? "unknown") clickID=\(context?.clickID?.uuidString ?? "none") displayID=\(context?.displayID?.uuidString ?? "none") openingFrontmost=\(context?.openingFrontmostRole ?? "unknown") reason=\(disposition?.reason ?? "appkit-dismissal") hostPID=\(context?.hostPID.description ?? "none") hostWindow=\(context?.hostWindowNumber.description ?? "none") frontmostRole=\(foregroundRole()) restoreOutcome=\(restoreOutcome) \(focusAtClose) sourceResponder=unobservable-without-host-modification")
        DispatchQueue.main.async { [weak self] in self?.refreshPlacement() }
    }

    private func closeDetails(reason: String, restoreIfSafe: Bool) {
        if isNonactivatingDetailsProbe {
            closeNonactivatingDetails(reason: reason, restoreIfSafe: restoreIfSafe)
            return
        }
        guard popover?.isShown == true else { return }
        closeDisposition = (reason, restoreIfSafe)
        let context = detailsContext ?? openingDetailsContext
        let window = popover?.contentViewController?.view.window
        let rootView = popover?.contentViewController?.view
        let focus = context.map { detailsFocusFields(context: $0, window: window, rootView: rootView) } ?? "contextID=none"
        writeLog("details-close-request source=\(reason) restoreIfSafe=\(restoreIfSafe) contextID=\(context?.id.uuidString ?? "none") row=\(context?.rowIdentifier ?? "unknown") hostPID=\(context?.hostPID.description ?? "none") hostWindow=\(context?.hostWindowNumber.description ?? "none") clickID=\(context?.clickID?.uuidString ?? "none") displayID=\(context?.displayID?.uuidString ?? "none") frontmostRole=\(foregroundRole()) \(focus)")
        popover?.performClose(nil)
    }

    private func closeNonactivatingDetails(reason: String, restoreIfSafe: Bool) {
        let context = detailsContext ?? openingDetailsContext
        guard nonactivatingDetailsPanel != nil || context != nil else { return }
        let panel = nonactivatingDetailsPanel
        let content = panel?.contentViewController as? DetailsViewController
        if let context {
            recordNonactivatingProbeState(checkpoint: "details-close-before-cleanup", context: context, panel: panel, rootView: content?.view)
        }
        let focus = context.map {
            detailsFocusFields(context: $0, window: panel, rootView: content?.view)
        } ?? "contextID=none"
        removeDetailsEventMonitors(contextID: context?.id, reason: reason)
        removeOpeningDetailsReadinessHooks()
        panel?.orderOut(nil)
        panel?.close()
        if let context {
            recordNonactivatingProbeState(
                checkpoint: "details-close-after-window-close",
                context: context,
                panel: panel,
                rootView: content?.view,
                panelWindowNumberOverride: panel?.windowNumber
            )
        }
        nonactivatingDetailsPanel = nil
        detailsContext = nil
        openingDetailsContext = nil
        closeDisposition = nil

        let front = NSWorkspace.shared.frontmostApplication
        let sourceIsValid = context.map {
            currentValidHostWindow(for: HostWindowIdentity(pid: $0.hostPID, windowNumber: $0.hostWindowNumber))?.windowNumber == $0.hostWindowNumber
        } ?? false
        let sourceAppIsFrontmost = context.map { front?.processIdentifier == $0.hostPID } ?? false
        let outcome = restoreIfSafe && sourceIsValid && sourceAppIsFrontmost
            ? "passive-no-activation-request"
            : (restoreIfSafe ? "no-host-activation-requested" : "not-requested")
        writeLog("details-close contextID=\(context?.id.uuidString ?? "none") row=\(context?.rowIdentifier ?? "unknown") source=\(context?.source ?? "unknown") clickID=\(context?.clickID?.uuidString ?? "none") displayID=\(context?.displayID?.uuidString ?? "none") openingFrontmost=\(context?.openingFrontmostRole ?? "unknown") reason=\(reason) hostPID=\(context?.hostPID.description ?? "none") hostWindow=\(context?.hostWindowNumber.description ?? "none") frontmostRole=\(foregroundRole()) restoreOutcome=\(outcome) container=nonactivating-panel overlayActive=\(NSApp.isActive) \(focus) sourceResponder=unobservable-without-host-modification")
        if restoreIfSafe, let context {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.recordSourceFocusObservation(context, request: "nonactivating-panel-closed-no-host-activation")
                self.refreshPlacement()
            }
        } else {
            DispatchQueue.main.async { [weak self] in self?.refreshPlacement() }
        }
    }

    private func requestRestoreOfSourceWindow(_ context: DetailsOpenContext) -> String {
        let identity = HostWindowIdentity(pid: context.hostPID, windowNumber: context.hostWindowNumber)
        guard currentValidHostWindow(for: identity)?.windowNumber == context.hostWindowNumber else {
            return "source-window-invalid"
        }

        if isNonactivatingDetailsProbe { return "probe-no-host-activation-requested" }

        if isDemoTarget {
            DistributedNotificationCenter.default().postNotificationName(
                DemoBridge.activateWindow,
                object: nil,
                userInfo: ["pid": Int(context.hostPID), "windowID": Int(context.hostWindowNumber)],
                deliverImmediately: true
            )
            return "demo-window-requested"
        }

        guard let hostApp = NSRunningApplication(processIdentifier: context.hostPID),
              !hostApp.isTerminated,
              !hostApp.isHidden,
              isAllowedTarget(hostApp)
        else { return "source-app-unavailable" }

        return hostApp.activate(options: []) ? "source-app-requested" : "source-app-request-rejected"
    }

    private func recordSourceFocusObservation(_ context: DetailsOpenContext, request: String) {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let currentWindowNumber = currentHostWindow(pid: context.hostPID)?.windowNumber
        let sourceWindowVisible = hostWindow(pid: context.hostPID, windowNumber: context.hostWindowNumber) != nil
        let exactWindowForeground = frontmostPID == context.hostPID && currentWindowNumber == context.hostWindowNumber
        writeLog("details-focus-restore-observed contextID=\(context.id.uuidString) request=\(request) sourceAppFrontmost=\(frontmostPID == context.hostPID) sourceWindowVisible=\(sourceWindowVisible) currentHostWindow=\(currentWindowNumber?.description ?? "none") exactSourceWindowForeground=\(exactWindowForeground) sourceResponder=unobservable-without-host-modification")
    }

    private func configureDetailsInteraction(context: DetailsOpenContext, content: DetailsViewController) -> DetailsInteractionSetupResult {
        guard let detailsWindow = content.view.window else {
            writeLog("details-interaction-setup contextID=\(context.id.uuidString) result=missing-detail-window hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber)")
            return .failed("missing-detail-window")
        }

        if !detailsWindow.isKeyWindow {
            recordNonactivatingProbeState(checkpoint: "before-make-key", context: context, panel: detailsWindow, rootView: content.view)
            detailsWindow.makeKey()
            recordNonactivatingProbeState(checkpoint: "after-make-key", context: context, panel: detailsWindow, rootView: content.view)
        } else {
            recordNonactivatingProbeState(checkpoint: "make-key-skipped-already-key", context: context, panel: detailsWindow, rootView: content.view)
        }
        guard detailsWindow.isKeyWindow else {
            writeLog("details-interaction-setup contextID=\(context.id.uuidString) result=waiting-for-key detailWindow=\(detailsWindow.windowNumber) detailKey=false overlayActive=\(NSApp.isActive) firstResponder=not-attempted hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber)")
            return .waitingForKey
        }

        recordNonactivatingProbeState(checkpoint: "before-make-first-responder", context: context, panel: detailsWindow, rootView: content.view)
        let acceptedFirstResponder = detailsWindow.makeFirstResponder(content.view)
        recordNonactivatingProbeState(checkpoint: "after-make-first-responder", context: context, panel: detailsWindow, rootView: content.view)
        guard acceptedFirstResponder else {
            writeLog("details-interaction-setup contextID=\(context.id.uuidString) result=failed reason=first-responder-rejected detailWindow=\(detailsWindow.windowNumber) detailKey=\(detailsWindow.isKeyWindow) firstResponderAccepted=false hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber)")
            return .failed("first-responder-rejected")
        }

        let diagnosticLog = makeMouseReceiptDiagnosticLog(for: context)
        let knownOverlayWindows = Set(rowPanels.map(\.windowNumber) + [detailsWindow.windowNumber])
        let diagnosticLocalMonitor: Any?
        if let diagnosticLog {
            diagnosticLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                let eventWindowID = event.window?.windowNumber
                let isKnownOverlayWindow = eventWindowID.map(knownOverlayWindows.contains) == true
                diagnosticLog.record(
                    .overlayLocalMouseReceipt,
                    stream: .overlayLocalMouse,
                    contextID: context.id,
                    clickID: context.clickID,
                    displayID: context.displayID,
                    hostPID: context.hostPID,
                    hostWindowID: Int(context.hostWindowNumber),
                    observedWindowID: isKnownOverlayWindow ? eventWindowID : nil,
                    targetRole: isKnownOverlayWindow ? .overlay : .unknown,
                    eventTimestamp: event.timestamp,
                    windowX: isKnownOverlayWindow ? Double(event.locationInWindow.x) : nil,
                    windowY: isKnownOverlayWindow ? Double(event.locationInWindow.y) : nil
                )
                if !diagnosticLog.isStreamOpen(.overlayLocalMouse) {
                    Task { @MainActor [weak self] in
                        self?.removeMouseReceiptLocalMonitor(
                            contextID: context.id,
                            reason: .streamBudgetExhausted
                        )
                    }
                }
                return event
            }
            diagnosticLog.record(
                diagnosticLocalMonitor == nil ? .overlayLocalMonitorUnavailable : .overlayLocalMonitorInstalled,
                contextID: context.id,
                clickID: context.clickID,
                displayID: context.displayID,
                hostPID: context.hostPID,
                hostWindowID: Int(context.hostWindowNumber),
                observedWindowID: Int(detailsWindow.windowNumber),
                reason: diagnosticLocalMonitor == nil ? .setupFailed : nil
            )
        } else {
            diagnosticLocalMonitor = nil
        }

        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.keyCode == 53,
                  self.detailsContext?.id == context.id,
                  self.detailsAreVisible,
                  event.window?.windowNumber == self.currentDetailsWindow?.windowNumber
            else { return event }

            self.closeDetails(reason: "escape-keyDown", restoreIfSafe: true)
            return nil
        }
        let mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            // 同一份转换后的 CGEvent 同时提供位置与原始身份字段，避免重复转换造成观察差异。
            let cgEvent = event.cgEvent
            let point = cgEvent?.location
            let eventTargetFields = Self.mouseEventTargetFields(from: cgEvent)
            let eventTimestamp = event.timestamp
            let receivedAt = Date()
            let exactHostTarget = eventTargetFields.unixProcessID == context.hostPID &&
                eventTargetFields.windowNumber == context.hostWindowNumber
            let traceID = diagnosticLog?.record(
                .globalCallbackEntry,
                stream: .overlayGlobal,
                contextID: context.id,
                clickID: context.clickID,
                displayID: context.displayID,
                hostPID: context.hostPID,
                hostWindowID: Int(context.hostWindowNumber),
                targetRole: Self.mouseReceiptTargetRole(
                    fields: eventTargetFields,
                    hostPID: context.hostPID,
                    overlayPID: ProcessInfo.processInfo.processIdentifier
                ),
                targetPIDFieldPresent: eventTargetFields.processIDFieldValid,
                targetWindowFieldPresent: eventTargetFields.windowIDFieldValid,
                targetHostProcessMatched: eventTargetFields.unixProcessID == context.hostPID,
                targetHostWindowMatched: eventTargetFields.unixProcessID == context.hostPID && eventTargetFields.windowNumber == context.hostWindowNumber,
                targetOverlayProcessMatched: eventTargetFields.unixProcessID == ProcessInfo.processInfo.processIdentifier,
                eventTimestamp: eventTimestamp,
                globalX: exactHostTarget ? point.map { Double($0.x) } : nil,
                globalY: exactHostTarget ? point.map { Double($0.y) } : nil
            )
            if let diagnosticLog, let traceID {
                diagnosticLog.record(
                    .globalTaskScheduled,
                    stream: .overlayTask,
                    contextID: context.id,
                    clickID: context.clickID,
                    displayID: context.displayID,
                    traceID: traceID,
                    hostPID: context.hostPID,
                    hostWindowID: Int(context.hostWindowNumber),
                    eventTimestamp: eventTimestamp
                )
            }
            Task { @MainActor [weak self] in
                if let diagnosticLog, let traceID {
                    diagnosticLog.record(
                        .globalTaskEntered,
                        stream: .overlayTask,
                        contextID: context.id,
                        clickID: context.clickID,
                        displayID: context.displayID,
                        traceID: traceID,
                        hostPID: context.hostPID,
                        hostWindowID: Int(context.hostWindowNumber),
                        eventTimestamp: eventTimestamp
                    )
                }
                guard let self else {
                    if let diagnosticLog, let traceID {
                        diagnosticLog.record(
                            .globalTaskOwnerUnavailable,
                            stream: .overlayTask,
                            contextID: context.id,
                            clickID: context.clickID,
                            displayID: context.displayID,
                            traceID: traceID,
                            hostPID: context.hostPID,
                            hostWindowID: Int(context.hostWindowNumber),
                            eventTimestamp: eventTimestamp
                        )
                        diagnosticLog.completeTrace(traceID)
                    }
                    return
                }
                self.handleExternalMouseDown(
                    atQuartzPoint: point,
                    eventTargetFields: eventTargetFields,
                    eventTimestamp: eventTimestamp,
                    receivedAt: receivedAt,
                    contextID: context.id,
                    diagnosticLog: traceID == nil ? nil : diagnosticLog,
                    diagnosticTraceID: traceID
                )
            }
        }

        guard detailsWindow.isKeyWindow,
              acceptedFirstResponder,
              let keyMonitor,
              let mouseMonitor
        else {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            if let diagnosticLocalMonitor { NSEvent.removeMonitor(diagnosticLocalMonitor) }
            diagnosticLog?.finish(contextID: context.id, reason: .setupFailed)
            writeLog("details-interaction-setup contextID=\(context.id.uuidString) result=failed reason=monitor-registration detailWindow=\(detailsWindow.windowNumber) detailKey=\(detailsWindow.isKeyWindow) firstResponderAccepted=\(acceptedFirstResponder) localKeyMonitor=\(keyMonitor != nil) globalMouseMonitor=\(mouseMonitor != nil) hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber)")
            return .failed("monitor-registration")
        }
        detailsKeyEventMonitor = keyMonitor
        detailsMouseEventMonitor = mouseMonitor
        detailsReceiptDiagnosticLocalMouseMonitor = diagnosticLocalMonitor
        detailsReceiptDiagnosticLog = diagnosticLog
        detailsReceiptDiagnosticContextID = diagnosticLog == nil ? nil : context.id

        recordNonactivatingProbeState(checkpoint: "after-monitor-registration", context: context, panel: detailsWindow, rootView: content.view)
        writeLog("details-interaction-setup contextID=\(context.id.uuidString) result=ready hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none") container=\(isNonactivatingDetailsProbe ? "nonactivating-panel" : "applicationDefined-popover") detailWindow=\(detailsWindow.windowNumber) detailKey=\(detailsWindow.isKeyWindow) firstResponderAccepted=\(acceptedFirstResponder) localKeyMonitor=\(detailsKeyEventMonitor != nil) globalMouseMonitor=\(detailsMouseEventMonitor != nil) \(detailsFocusFields(context: context, window: detailsWindow, rootView: content.view))")
        return .ready
    }

    private func removeDetailsEventMonitors(contextID: UUID?, reason: String) {
        let removedKeyMonitor = detailsKeyEventMonitor != nil
        let removedMouseMonitor = detailsMouseEventMonitor != nil
        if let detailsKeyEventMonitor { NSEvent.removeMonitor(detailsKeyEventMonitor) }
        if let detailsMouseEventMonitor { NSEvent.removeMonitor(detailsMouseEventMonitor) }
        detailsKeyEventMonitor = nil
        detailsMouseEventMonitor = nil
        removeMouseReceiptDiagnostic(contextID: contextID, reason: diagnosticReason(for: reason))
        if removedKeyMonitor || removedMouseMonitor {
            writeLog("details-event-monitors-removed contextID=\(contextID?.uuidString ?? "none") reason=\(reason) localKey=\(removedKeyMonitor) globalMouse=\(removedMouseMonitor)")
        }
    }

    private func makeMouseReceiptDiagnosticLog(for context: DetailsOpenContext) -> OverlayInputReceiptDiagnosticLog? {
        guard isMouseReceiptDiagnosticsEnabled, let runtimeDirectoryURL else { return nil }
        let log = OverlayInputReceiptDiagnosticLog(
            runtimeDirectory: runtimeDirectoryURL,
            fileName: "overlay-input-receipt.log",
            component: .overlay,
            processID: ProcessInfo.processInfo.processIdentifier,
            maximumRecords: 48
        )
        log.record(
            .transactionStarted,
            contextID: context.id,
            clickID: context.clickID,
            displayID: context.displayID,
            hostPID: context.hostPID,
            hostWindowID: Int(context.hostWindowNumber)
        )
        return log.isStreamOpen(.overlayLocalMouse) ? log : nil
    }

    private func diagnosticReason(for reason: String) -> OverlayInputReceiptReason {
        switch reason {
        case "termination": .applicationTerminating
        case "details-context-replaced": .transactionReplaced
        case "popover-closed-before-interactive": .transactionCancelled
        default: .transactionClosed
        }
    }

    private func removeMouseReceiptLocalMonitor(contextID: UUID, reason: OverlayInputReceiptReason) {
        guard detailsReceiptDiagnosticContextID == contextID,
              let diagnosticLog = detailsReceiptDiagnosticLog,
              let monitor = detailsReceiptDiagnosticLocalMouseMonitor
        else { return }
        NSEvent.removeMonitor(monitor)
        detailsReceiptDiagnosticLocalMouseMonitor = nil
        diagnosticLog.record(
            .monitorRemoved,
            contextID: contextID,
            reason: reason
        )
    }

    private func removeMouseReceiptDiagnostic(contextID: UUID?, reason: OverlayInputReceiptReason) {
        guard let diagnosticLog = detailsReceiptDiagnosticLog,
              contextID == nil || detailsReceiptDiagnosticContextID == contextID
        else { return }
        if let monitor = detailsReceiptDiagnosticLocalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            detailsReceiptDiagnosticLocalMouseMonitor = nil
            diagnosticLog.record(.monitorRemoved, contextID: detailsReceiptDiagnosticContextID, reason: reason)
        }
        diagnosticLog.finish(contextID: detailsReceiptDiagnosticContextID, reason: reason)
        detailsReceiptDiagnosticLog = nil
        detailsReceiptDiagnosticContextID = nil
    }

    private static func mouseReceiptTargetRole(
        fields: MouseEventTargetFields,
        hostPID: pid_t,
        overlayPID: pid_t
    ) -> OverlayInputReceiptRole {
        if fields.unixProcessID == hostPID { return .host }
        if fields.unixProcessID == overlayPID { return .overlay }
        if fields.unixProcessID != nil { return .other }
        return .unknown
    }

    private static func isCurrentVisibleDetailsContext(
        currentContextID: UUID?,
        callbackContextID: UUID,
        detailsVisible: Bool
    ) -> Bool {
        currentContextID == callbackContextID && detailsVisible
    }

    private static func mouseEventTargetFields(from event: CGEvent?) -> MouseEventTargetFields {
        guard let event else {
            return MouseEventTargetFields(unixProcessID: nil, windowNumber: nil)
        }

        let rawPID = event.getIntegerValueField(.eventTargetUnixProcessID)
        let rawWindow = event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
        let processID = rawPID > 0 && rawPID <= Int64(Int32.max) ? pid_t(rawPID) : nil
        let windowNumber = rawWindow > 0 && rawWindow <= Int64(UInt32.max) ? CGWindowID(rawWindow) : nil
        return MouseEventTargetFields(unixProcessID: processID, windowNumber: windowNumber)
    }

    private static func resolveMouseEventTarget(
        fields: MouseEventTargetFields,
        windowList: [[String: Any]],
        overlayPID: pid_t
    ) -> MouseEventTargetResolution {
        guard let targetWindow = fields.windowNumber else { return .unknown("window-field-invalid") }
        guard let targetPID = fields.unixProcessID else { return .unknown("process-field-invalid") }

        let matchingWindows = windowList.filter { windowNumber(in: $0) == targetWindow }
        guard !matchingWindows.isEmpty else { return .unknown("window-owner-missing") }
        guard matchingWindows.count == 1 else { return .unknown("window-owner-ambiguous") }
        guard let ownerPID = ownerPID(in: matchingWindows[0]) else { return .unknown("window-owner-invalid") }

        // 仅允许事件 PID 与精确窗口 owner 一致，或与本观察器 PID 一致；后者是已观察到的全局监视器字段冲突形态。
        // 目标身份始终取自唯一窗口记录的 owner，不把观察器 PID 改写成 Host PID。
        guard targetPID == ownerPID || targetPID == overlayPID else {
            return .unknown("process-field-owner-conflict")
        }
        return .verified(VerifiedMouseEventTarget(
            identity: HostWindowIdentity(pid: ownerPID, windowNumber: targetWindow),
            processIDMatchesWindowOwner: targetPID == ownerPID,
            processIDMatchesOverlay: targetPID == overlayPID
        ))
    }

    private static func externalMouseEventTargetLogFields(
        fields: MouseEventTargetFields,
        resolution: MouseEventTargetResolution,
        sourceIdentity: HostWindowIdentity,
        overlayPID: pid_t
    ) -> String {
        let rawFieldValidity = "eventTargetPIDFieldValid=\(fields.processIDFieldValid) eventTargetWindowFieldValid=\(fields.windowIDFieldValid)"
        switch resolution {
        case let .verified(target):
            let identity = target.identity
            let matchesSource = identity == sourceIdentity
            let matchesOverlayProcess = identity.pid == overlayPID
            let validation = "eventTargetIdentityValid=true eventTargetOwnerUnique=true eventTargetPIDMatchesWindowOwner=\(target.processIDMatchesWindowOwner) eventTargetPIDFieldMatchesOverlayProcess=\(target.processIDMatchesOverlay) eventTargetMatchesSource=\(matchesSource) eventTargetMatchesOverlayProcess=\(matchesOverlayProcess)"
            guard identity.pid == sourceIdentity.pid || matchesOverlayProcess else {
                return "\(rawFieldValidity) eventTargetRole=other-process \(validation) eventTargetIdentity=redacted"
            }

            let role = identity.pid == sourceIdentity.pid ? "project-host" : "project-overlay"
            return "\(rawFieldValidity) eventTargetRole=\(role) \(validation) eventTargetPID=\(identity.pid) eventTargetWindow=\(identity.windowNumber)"
        case let .unknown(reason):
            return "\(rawFieldValidity) eventTargetRole=unknown eventTargetIdentityValid=false eventTargetOwnerUnique=false eventTargetMatchesSource=false eventTargetMatchesOverlayProcess=false eventTargetIdentity=redacted eventTargetOwnerLookup=\(reason)"
        }
    }

    private static func externalMouseDecision(
        point: CGPoint?,
        frontmostRole: String,
        sourceIdentity: HostWindowIdentity,
        currentHostIdentity: HostWindowIdentity?,
        sourceWindowVisible: Bool,
        sourcePlacementValid: Bool,
        sourceBounds: CGRect?,
        detailIdentity: HostWindowIdentity?,
        detailBounds: CGRect?,
        eventTargetIdentity: HostWindowIdentity?,
        ownPID: pid_t
    ) -> ExternalMouseDecision {
        guard let point, point.x.isFinite, point.y.isFinite else { return .keep("unknown-event-point") }
        guard let detailIdentity else { return .keep("detail-window-identity-unavailable") }
        if eventTargetIdentity == detailIdentity { return .keep("detail-window-event-target") }
        if let detailBounds, detailBounds.contains(point) { return .keep("detail-window-bounds") }
        guard frontmostRole == "host" else { return .keep("frontmost-\(frontmostRole)") }
        guard sourceWindowVisible else { return .keep("source-window-unavailable") }
        guard currentHostIdentity == sourceIdentity else { return .keep("different-host-window") }
        guard sourcePlacementValid else { return .keep("source-window-or-anchor-invalid") }
        guard let sourceBounds, !sourceBounds.isNull, !sourceBounds.isInfinite, sourceBounds.contains(point) else {
            return .keep("outside-source-window-bounds")
        }
        // 事件目标 PID 只作交叉核对；关闭依据是事件 window ID 对应的唯一窗口 owner。
        guard let eventTargetIdentity else { return .keep("event-target-identity-unknown") }
        if eventTargetIdentity == sourceIdentity { return .closeExactSource }
        if eventTargetIdentity.pid == sourceIdentity.pid {
            return .keep("different-host-window-event-target")
        }
        if eventTargetIdentity.pid == ownPID {
            return .keep("overlay-event-target")
        }
        return .keep("other-process-event-target")
    }

    private static func externalMouseCloseDisposition(for decision: ExternalMouseDecision) -> ExternalMouseCloseDisposition? {
        switch decision {
        case .closeExactSource:
            return ExternalMouseCloseDisposition(reason: "host-outside-click", restoreIfSafe: true)
        case .keep("source-window-unavailable"), .keep("source-window-or-anchor-invalid"):
            return ExternalMouseCloseDisposition(reason: "details-host-or-anchor-invalid", restoreIfSafe: false)
        case .keep("different-host-window"):
            return ExternalMouseCloseDisposition(reason: "host-window-changed", restoreIfSafe: false)
        case .keep:
            return nil
        }
    }

    private func handleExternalMouseDown(
        atQuartzPoint point: CGPoint?,
        eventTargetFields: MouseEventTargetFields,
        eventTimestamp: TimeInterval,
        receivedAt: Date,
        contextID: UUID,
        diagnosticLog: OverlayInputReceiptDiagnosticLog?,
        diagnosticTraceID: Int?
    ) {
        let context: DetailsOpenContext
        if let diagnosticLog, let diagnosticTraceID {
            if diagnosticLog.isEnabled {
                let currentContextID = detailsContext?.id
                let detailsVisible = detailsAreVisible
                let isCurrentVisible = Self.isCurrentVisibleDetailsContext(
                    currentContextID: currentContextID,
                    callbackContextID: contextID,
                    detailsVisible: detailsVisible
                )
                let currentContext = isCurrentVisible ? detailsContext : nil
                let guardOutcome: OverlayInputReceiptGuard
                if currentContextID != contextID {
                    guardOutcome = .staleContext
                } else if !detailsVisible {
                    guardOutcome = .detailsHidden
                } else if currentContext == nil {
                    guardOutcome = .missingContext
                } else {
                    guardOutcome = .passed
                }
                diagnosticLog.record(
                    .globalGuardOutcome,
                    stream: .overlayGuard,
                    contextID: contextID,
                    traceID: diagnosticTraceID,
                    hostPID: currentContext?.hostPID,
                    hostWindowID: currentContext.map { Int($0.hostWindowNumber) },
                    contextMatched: isCurrentVisible,
                    detailsVisible: detailsVisible,
                    guardOutcome: guardOutcome,
                    eventTimestamp: eventTimestamp
                )
                diagnosticLog.completeTrace(diagnosticTraceID)
                guard let currentContext else { return }
                context = currentContext
            } else {
                diagnosticLog.completeTrace(diagnosticTraceID)
                guard Self.isCurrentVisibleDetailsContext(
                    currentContextID: detailsContext?.id,
                    callbackContextID: contextID,
                    detailsVisible: detailsAreVisible
                ), let currentContext = detailsContext else { return }
                context = currentContext
            }
        } else {
            guard Self.isCurrentVisibleDetailsContext(
                currentContextID: detailsContext?.id,
                callbackContextID: contextID,
                detailsVisible: detailsAreVisible
            ), let currentContext = detailsContext else { return }
            context = currentContext
        }

        let processedAt = Date()
        let windowList = onScreenWindowInfo()
        let eventTargetResolution = Self.resolveMouseEventTarget(
            fields: eventTargetFields,
            windowList: windowList,
            overlayPID: ProcessInfo.processInfo.processIdentifier
        )
        let sourceIdentity = HostWindowIdentity(pid: context.hostPID, windowNumber: context.hostWindowNumber)
        let currentHost = currentHostWindow(pid: context.hostPID, windowList: windowList)
        let currentHostIdentity = currentHost.map(HostWindowIdentity.init)
        let exactSource = hostWindow(pid: context.hostPID, windowNumber: context.hostWindowNumber, windowList: windowList)
        let sourceWindowVisible = exactSource != nil
        let sourceIsCurrent = currentHostIdentity == sourceIdentity
        if sourceIsCurrent, let exactSource {
            requestDemoLayoutsIfNeeded(for: exactSource, now: processedAt)
        }
        let sourcePlacementValid = sourceIsCurrent && exactSource.map { validPlacement(for: $0) != nil } == true
        let sourceBounds = exactSource?.cgBounds
        let detailWindow = currentDetailsWindow
        let detailIdentity = detailWindow.map {
            HostWindowIdentity(pid: ProcessInfo.processInfo.processIdentifier, windowNumber: CGWindowID($0.windowNumber))
        }
        let detailBounds = detailIdentity.flatMap { quartzWindowBounds(pid: $0.pid, windowNumber: $0.windowNumber, windowList: windowList) }
        let candidate = point.flatMap { Self.windowListCandidate(atQuartzPoint: $0, windowList: windowList) }
        let role = foregroundRole()
        let decision = Self.externalMouseDecision(
            point: point,
            frontmostRole: role,
            sourceIdentity: sourceIdentity,
            currentHostIdentity: currentHostIdentity,
            sourceWindowVisible: sourceWindowVisible,
            sourcePlacementValid: sourcePlacementValid,
            sourceBounds: sourceBounds,
            detailIdentity: detailIdentity,
            detailBounds: detailBounds,
            eventTargetIdentity: eventTargetResolution.identity,
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
        let candidateCategory = externalMouseCandidateCategory(
            identity: candidate?.identity,
            sourceIdentity: sourceIdentity,
            detailIdentity: detailIdentity,
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
        let candidateHostField = candidate?.identity.flatMap { identity -> String? in
            guard identity.pid == context.hostPID else { return nil }
            return "candidateHostWindow=\(identity.windowNumber)"
        } ?? "candidateHostWindow=none"
        let eventTargetLogFields = Self.externalMouseEventTargetLogFields(
            fields: eventTargetFields,
            resolution: eventTargetResolution,
            sourceIdentity: sourceIdentity,
            overlayPID: ProcessInfo.processInfo.processIdentifier
        )
        let pointField = point.map { String(format: "(%.2f,%.2f)", $0.x, $0.y) } ?? "none"
        let decisionFields: (String, String)
        switch decision {
        case .closeExactSource:
            decisionFields = ("close", "exact-source-window-owner")
        case let .keep(reason):
            decisionFields = ("keep", reason)
        }
        writeLog("details-dismiss-observed source=external-mouse contextID=\(context.id.uuidString) row=\(context.rowIdentifier) hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none") eventReceivedEpoch=\(String(format: "%.6f", receivedAt.timeIntervalSince1970)) eventTimestampMonotonic=\(String(format: "%.6f", eventTimestamp)) eventProcessedEpoch=\(String(format: "%.6f", processedAt.timeIntervalSince1970)) pointSpace=quartz-global-display pointQuartz=\(pointField) sourceBoundsQuartz=\(sourceBounds.map(preciseString) ?? "unknown") sourceVisible=\(sourceWindowVisible) sourceCurrent=\(sourceIsCurrent) sourcePlacementValid=\(sourcePlacementValid) currentHostWindow=\(currentHostIdentity?.windowNumber.description ?? "none") detailWindow=\(detailIdentity?.windowNumber.description ?? "none") detailBoundsQuartz=\(detailBounds.map(preciseString) ?? "unknown") windowListCandidateCategory=\(candidateCategory) \(candidateHostField) windowListCandidateBoundsQuartz=\(candidate.map { preciseString($0.bounds) } ?? "unknown") \(eventTargetLogFields) frontmostRole=\(role) decision=\(decisionFields.0) reason=\(decisionFields.1)")

        if let disposition = Self.externalMouseCloseDisposition(for: decision) {
            if disposition.reason == "host-outside-click" {
                let rootView = currentDetailsContent?.view
                let focus = detailsFocusFields(context: context, window: detailWindow, rootView: rootView)
                writeLog("details-external-close-request source=host-outside-click contextID=\(context.id.uuidString) row=\(context.rowIdentifier) hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none") clickQuartz=\(pointField) pointSpace=quartz-global-display windowListCandidateCategory=\(candidateCategory) \(candidateHostField) \(eventTargetLogFields) decision=\(decisionFields.1) frontmostRole=\(role) \(focus)")
            }
            closeDetails(reason: disposition.reason, restoreIfSafe: disposition.restoreIfSafe)
        }
    }

    private func externalMouseCandidateCategory(
        identity: HostWindowIdentity?,
        sourceIdentity: HostWindowIdentity,
        detailIdentity: HostWindowIdentity?,
        ownPID: pid_t
    ) -> String {
        guard let identity else { return "unknown" }
        if identity == detailIdentity, detailIdentity != nil { return "detail" }
        if identity == sourceIdentity { return "source" }
        if identity.pid == sourceIdentity.pid { return "source-app-other-window" }
        if identity.pid == ownPID { return "overlay-window" }
        return "other-window"
    }

    private func onScreenWindowInfo() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }

    private static func windowNumber(in item: [String: Any]) -> CGWindowID? {
        let value = item[kCGWindowNumber as String]
        if let number = value as? UInt32, number > 0 { return number }
        if let number = value as? Int, number > 0, number <= Int(UInt32.max) { return CGWindowID(number) }
        return nil
    }

    private static func ownerPID(in item: [String: Any]) -> pid_t? {
        let value = item[kCGWindowOwnerPID as String]
        let rawPID = (value as? Int32) ?? (value as? Int).flatMap { Int32(exactly: $0) }
        guard let rawPID, rawPID > 0 else { return nil }
        return pid_t(rawPID)
    }

    private static func windowListCandidate(atQuartzPoint point: CGPoint, windowList: [[String: Any]]) -> QuartzWindowCandidate? {
        for item in windowList {
            guard let bounds = item[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            guard frame.contains(point) else { continue }
            let ownerPID = (item[kCGWindowOwnerPID as String] as? Int32) ?? Int32(item[kCGWindowOwnerPID as String] as? Int ?? -1)
            guard let number = item[kCGWindowNumber as String] as? UInt32, ownerPID >= 0 else {
                return QuartzWindowCandidate(identity: nil, bounds: frame)
            }
            return QuartzWindowCandidate(identity: HostWindowIdentity(pid: pid_t(ownerPID), windowNumber: number), bounds: frame)
        }
        return nil
    }

    private func quartzWindowBounds(pid: pid_t, windowNumber: CGWindowID, windowList: [[String: Any]]) -> CGRect? {
        for item in windowList {
            let ownerPID = (item[kCGWindowOwnerPID as String] as? Int32) ?? Int32(item[kCGWindowOwnerPID as String] as? Int ?? -1)
            guard ownerPID == pid,
                  (item[kCGWindowNumber as String] as? UInt32) == windowNumber,
                  let bounds = item[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            return CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        }
        return nil
    }

#if OVERLAY_A_EXTERNAL_MOUSE_REGRESSION
    static func runExternalMouseRegressionCheck() {
        let source = HostWindowIdentity(pid: 111, windowNumber: 22)
        let detail = HostWindowIdentity(pid: 333, windowNumber: 44)
        let hostBounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let detailBounds = CGRect(x: 100, y: 100, width: 240, height: 320)
        let otherApp = HostWindowIdentity(pid: 444, windowNumber: 55)
        let otherHostWindow = HostWindowIdentity(pid: 111, windowNumber: 23)
        let otherOverlayWindow = HostWindowIdentity(pid: 333, windowNumber: 66)
        func windowInfo(_ identity: HostWindowIdentity, bounds: CGRect = .zero) -> [String: Any] {
            [
                kCGWindowOwnerPID as String: Int32(identity.pid),
                kCGWindowNumber as String: UInt32(identity.windowNumber),
                kCGWindowBounds as String: [
                    "X": bounds.origin.x,
                    "Y": bounds.origin.y,
                    "Width": bounds.width,
                    "Height": bounds.height,
                ],
            ]
        }
        func eventFields(pid: Int64, window: Int64) -> MouseEventTargetFields {
            let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
            event.setIntegerValueField(.eventTargetUnixProcessID, value: pid)
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: window)
            return mouseEventTargetFields(from: event)
        }
        let sourceWindowInfo = windowInfo(source, bounds: hostBounds)
        let hostFields = eventFields(pid: Int64(source.pid), window: Int64(source.windowNumber))
        let hostResolution = resolveMouseEventTarget(fields: hostFields, windowList: [sourceWindowInfo], overlayPID: 333)
        let hostLogFields = externalMouseEventTargetLogFields(
            fields: hostFields,
            resolution: hostResolution,
            sourceIdentity: source,
            overlayPID: 333
        )
        precondition(hostLogFields.contains("eventTargetRole=project-host") &&
                     hostLogFields.contains("eventTargetOwnerUnique=true") &&
                     hostLogFields.contains("eventTargetPID=111") &&
                     hostLogFields.contains("eventTargetWindow=22") &&
                     hostLogFields.contains("eventTargetMatchesSource=true"),
                     "a unique Host window owner must provide the diagnosable project identity")

        let otherHostFields = eventFields(pid: Int64(otherHostWindow.pid), window: Int64(otherHostWindow.windowNumber))
        let otherHostResolution = resolveMouseEventTarget(
            fields: otherHostFields,
            windowList: [windowInfo(otherHostWindow)],
            overlayPID: 333
        )
        let otherHostLogFields = externalMouseEventTargetLogFields(
            fields: otherHostFields,
            resolution: otherHostResolution,
            sourceIdentity: source,
            overlayPID: 333
        )
        precondition(otherHostLogFields.contains("eventTargetRole=project-host") &&
                     otherHostLogFields.contains("eventTargetPID=111") &&
                     otherHostLogFields.contains("eventTargetWindow=23") &&
                     otherHostLogFields.contains("eventTargetMatchesSource=false"),
                     "another window from the confirmed project Host process may be distinguished")

        let overlayFields = eventFields(pid: Int64(detail.pid), window: Int64(detail.windowNumber))
        let overlayResolution = resolveMouseEventTarget(fields: overlayFields, windowList: [windowInfo(detail)], overlayPID: 333)
        let overlayLogFields = externalMouseEventTargetLogFields(
            fields: overlayFields,
            resolution: overlayResolution,
            sourceIdentity: source,
            overlayPID: 333
        )
        precondition(overlayLogFields.contains("eventTargetRole=project-overlay") &&
                     overlayLogFields.contains("eventTargetPID=333") &&
                     overlayLogFields.contains("eventTargetWindow=44") &&
                     overlayLogFields.contains("eventTargetMatchesOverlayProcess=true"),
                     "an exact Overlay window owner must remain diagnosable")

        let otherFields = eventFields(pid: Int64(otherApp.pid), window: Int64(otherApp.windowNumber))
        let otherResolution = resolveMouseEventTarget(fields: otherFields, windowList: [windowInfo(otherApp)], overlayPID: 333)
        let otherProcessLogFields = externalMouseEventTargetLogFields(
            fields: otherFields,
            resolution: otherResolution,
            sourceIdentity: source,
            overlayPID: 333
        )
        precondition(otherProcessLogFields.contains("eventTargetRole=other-process") &&
                     otherProcessLogFields.contains("eventTargetIdentityValid=true") &&
                     otherProcessLogFields.contains("eventTargetMatchesSource=false") &&
                     otherProcessLogFields.contains("eventTargetIdentity=redacted") &&
                     !otherProcessLogFields.contains("444") && !otherProcessLogFields.contains("55"),
                     "a non-project process identity must not appear in the formatted log fields")

        let unknownFields = mouseEventTargetFields(from: nil)
        let unknownResolution = resolveMouseEventTarget(fields: unknownFields, windowList: [], overlayPID: 333)
        let unknownLogFields = externalMouseEventTargetLogFields(
            fields: unknownFields,
            resolution: unknownResolution,
            sourceIdentity: source,
            overlayPID: 333
        )
        precondition(unknownLogFields.contains("eventTargetRole=unknown") &&
                     unknownLogFields.contains("eventTargetIdentityValid=false") &&
                     !unknownLogFields.contains("eventTargetPID=") &&
                     !unknownLogFields.contains("eventTargetWindow="),
                     "an unknown identity must remain explicit without invented values")

        // 复现 r16 实际组合：目标 PID 是本 Overlay，事件 window ID 的唯一 owner 却是当前 Host。
        let overlayPIDHostWindowFields = eventFields(pid: 333, window: 22)
        let ownerVerifiedHost = resolveMouseEventTarget(
            fields: overlayPIDHostWindowFields,
            windowList: [sourceWindowInfo],
            overlayPID: 333
        )
        guard case let .verified(overlayPIDHostWindow) = ownerVerifiedHost else {
            preconditionFailure("the exact Host window owner must resolve the observed Overlay-PID/Host-window shape")
        }
        precondition(overlayPIDHostWindow.identity == source &&
                     !overlayPIDHostWindow.processIDMatchesWindowOwner &&
                     overlayPIDHostWindow.processIDMatchesOverlay,
                     "the canonical identity must come from the exact owner and preserve the raw PID conflict")
        let fullScreenFirstOwnerList = resolveMouseEventTarget(
            fields: overlayPIDHostWindowFields,
            windowList: [
                windowInfo(otherApp, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440)),
                sourceWindowInfo,
            ],
            overlayPID: 333
        )
        precondition(fullScreenFirstOwnerList.identity == source,
                     "owner lookup must match the event window number instead of the first rectangle containing the point")
        let conflictLogFields = externalMouseEventTargetLogFields(
            fields: overlayPIDHostWindowFields,
            resolution: ownerVerifiedHost,
            sourceIdentity: source,
            overlayPID: 333
        )
        precondition(conflictLogFields.contains("eventTargetRole=project-host") &&
                     conflictLogFields.contains("eventTargetPIDMatchesWindowOwner=false") &&
                     conflictLogFields.contains("eventTargetPIDFieldMatchesOverlayProcess=true") &&
                     conflictLogFields.contains("eventTargetPID=111") &&
                     !conflictLogFields.contains("eventTargetPID=333"),
                     "a PID conflict must be explicit while logging only the owner-verified Host identity")

        let missingOwner = resolveMouseEventTarget(fields: overlayPIDHostWindowFields, windowList: [], overlayPID: 333)
        precondition(missingOwner.identity == nil, "a missing exact window owner must fail closed")
        if case let .unknown(reason) = missingOwner {
            precondition(reason == "window-owner-missing", "missing owner must keep a specific diagnostic category")
        } else {
            preconditionFailure("a missing exact window owner must not resolve")
        }

        let ownerConflict = resolveMouseEventTarget(
            fields: overlayPIDHostWindowFields,
            windowList: [windowInfo(HostWindowIdentity(pid: otherApp.pid, windowNumber: source.windowNumber))],
            overlayPID: 333
        )
        precondition(ownerConflict.identity == HostWindowIdentity(pid: otherApp.pid, windowNumber: source.windowNumber),
                     "a window owned by another process must resolve to that owner, never be rewritten to Host")
        let ownerConflictDecision = decide(CGPoint(x: 800, y: 400), eventTarget: ownerConflict.identity)
        precondition(ownerConflictDecision == .keep("other-process-event-target") &&
                     externalMouseCloseDisposition(for: ownerConflictDecision) == nil,
                     "a uniquely owned non-source window must neither dismiss nor restore the Host")
        let ownerConflictLogFields = externalMouseEventTargetLogFields(
            fields: overlayPIDHostWindowFields,
            resolution: ownerConflict,
            sourceIdentity: source,
            overlayPID: 333
        )
        precondition(ownerConflictLogFields.contains("eventTargetRole=other-process") &&
                     ownerConflictLogFields.contains("eventTargetIdentity=redacted") &&
                     !ownerConflictLogFields.contains("444") &&
                     !ownerConflictLogFields.contains("eventTargetWindow=22"),
                     "a non-project owner must not leak its PID or window number")
        let duplicateOwner = resolveMouseEventTarget(
            fields: overlayPIDHostWindowFields,
            windowList: [
                sourceWindowInfo,
                windowInfo(HostWindowIdentity(pid: otherApp.pid, windowNumber: source.windowNumber), bounds: hostBounds),
            ],
            overlayPID: 333
        )
        precondition(duplicateOwner.identity == nil,
                     "duplicate window IDs with conflicting owners must remain ambiguous")
        let duplicateLogFields = externalMouseEventTargetLogFields(
            fields: overlayPIDHostWindowFields,
            resolution: duplicateOwner,
            sourceIdentity: source,
            overlayPID: 333
        )
        precondition(duplicateLogFields.contains("eventTargetOwnerLookup=window-owner-ambiguous") &&
                     !duplicateLogFields.contains("eventTargetPID=") &&
                     !duplicateLogFields.contains("eventTargetWindow="),
                     "ambiguous ownership must be explicit without persisting either candidate identity")
        let arbitraryPIDConflict = resolveMouseEventTarget(
            fields: eventFields(pid: 444, window: 22),
            windowList: [sourceWindowInfo],
            overlayPID: 333
        )
        precondition(arbitraryPIDConflict.identity == nil,
                     "an unrelated process PID conflicting with the exact owner must fail closed")
        let arbitraryPIDDecision = decide(CGPoint(x: 800, y: 400), eventTarget: arbitraryPIDConflict.identity)
        precondition(arbitraryPIDDecision == .keep("event-target-identity-unknown") &&
                     externalMouseCloseDisposition(for: arbitraryPIDDecision) == nil,
                     "an unrelated process PID conflict must not close or restore the Host")
        let missingOwnerDecision = decide(CGPoint(x: 800, y: 400), eventTarget: missingOwner.identity)
        precondition(missingOwnerDecision == .keep("event-target-identity-unknown") &&
                     externalMouseCloseDisposition(for: missingOwnerDecision) == nil,
                     "missing window ownership must not close or restore the Host")
        let invalidPID = resolveMouseEventTarget(
            fields: eventFields(pid: Int64.max, window: 22),
            windowList: [sourceWindowInfo],
            overlayPID: 333
        )
        precondition(invalidPID.identity == nil,
                     "an out-of-range target PID field must not be repaired from window metadata")
        let missingWindow = resolveMouseEventTarget(
            fields: eventFields(pid: 111, window: 0),
            windowList: [sourceWindowInfo],
            overlayPID: 333
        )
        precondition(missingWindow.identity == nil, "a missing event window ID must fail closed")

        func decide(
            _ point: CGPoint?,
            role: String = "host",
            current: HostWindowIdentity? = source,
            visible: Bool = true,
            placementValid: Bool = true,
            bounds: CGRect? = hostBounds,
            detailFrame: CGRect? = detailBounds,
            detailID: HostWindowIdentity? = detail,
            eventTarget: HostWindowIdentity? = source
        ) -> ExternalMouseDecision {
            externalMouseDecision(
                point: point,
                frontmostRole: role,
                sourceIdentity: source,
                currentHostIdentity: current,
                sourceWindowVisible: visible,
                sourcePlacementValid: placementValid,
                sourceBounds: bounds,
                detailIdentity: detailID,
                detailBounds: detailFrame,
                eventTargetIdentity: eventTarget,
                ownPID: 333
            )
        }

        precondition(decide(CGPoint(x: 800, y: 400), eventTarget: ownerVerifiedHost.identity) == .closeExactSource,
                     "the observed PID conflict may close only through its exact source-window owner")
        let fullScreenCandidate = windowListCandidate(
            atQuartzPoint: CGPoint(x: 800, y: 400),
            windowList: [[
                kCGWindowBounds as String: ["X": CGFloat(0), "Y": CGFloat(0), "Width": CGFloat(2560), "Height": CGFloat(1440)],
                kCGWindowOwnerPID as String: Int32(otherApp.pid),
                kCGWindowNumber as String: UInt32(otherApp.windowNumber)
            ]]
        )
        precondition(fullScreenCandidate?.identity == otherApp,
                     "the full-screen rectangle fixture must remain a geometric candidate only")
        precondition(decide(CGPoint(x: 800, y: 400), eventTarget: ownerVerifiedHost.identity) == .closeExactSource,
                     "a full-screen rectangle candidate must not override the verified event-window owner")
        let otherProcessTarget = decide(CGPoint(x: 800, y: 400), eventTarget: otherApp)
        precondition(otherProcessTarget == .keep("other-process-event-target"),
                     "an event targeted to another process must remain a conflict")
        precondition(externalMouseCloseDisposition(for: otherProcessTarget) == nil,
                     "an event targeted to another process must not request dismissal or source restoration")
        precondition(decide(CGPoint(x: 120, y: 140), eventTarget: detail) == .keep("detail-window-event-target"),
                     "detail window hit must remain open")
        precondition(decide(CGPoint(x: 800, y: 400), detailID: nil) == .keep("detail-window-identity-unavailable"),
                     "missing detail identity must fail closed")
        precondition(decide(CGPoint(x: 800, y: 400), eventTarget: otherHostWindow) == .keep("different-host-window-event-target"),
                     "another host window must not be restored as the source")
        precondition(decide(CGPoint(x: 800, y: 400), eventTarget: otherOverlayWindow) == .keep("overlay-event-target"),
                     "overlay-owned event target must not be treated as a host click")
        precondition(decide(CGPoint(x: 800, y: 400), role: "other", eventTarget: otherApp) == .keep("frontmost-other"),
                     "other app frontmost must not close with source restoration")
        precondition(decide(CGPoint(x: 800, y: 400), role: "overlay", eventTarget: detail) == .keep("detail-window-event-target"),
                     "overlay detail hit must remain interactive")
        precondition(decide(CGPoint(x: 800, y: 400), eventTarget: missingOwner.identity) == .keep("event-target-identity-unknown"),
                     "unknown exact window owner must fail closed")
        precondition(decide(nil) == .keep("unknown-event-point"), "unknown point must fail closed")
        precondition(decide(CGPoint(x: 800, y: 400), current: otherHostWindow) == .keep("different-host-window"),
                     "stale source window must not be restored")
        precondition(decide(CGPoint(x: 800, y: 400), visible: false) == .keep("source-window-unavailable"),
                     "missing source window must fail closed")
        precondition(decide(CGPoint(x: 800, y: 400), placementValid: false) == .keep("source-window-or-anchor-invalid"),
                     "invalid placement must fail closed")
        precondition(decide(CGPoint(x: 1100, y: 400)) == .keep("outside-source-window-bounds"),
                     "point outside source bounds must fail closed")
        let exactClose = externalMouseCloseDisposition(for: .closeExactSource)
        precondition(exactClose == ExternalMouseCloseDisposition(reason: "host-outside-click", restoreIfSafe: true),
                     "exact source decision must use the normal source restoration path")
        precondition(externalMouseCloseDisposition(for: .keep("different-host-window")) ==
                     ExternalMouseCloseDisposition(reason: "host-window-changed", restoreIfSafe: false),
                     "different host window must close without restoring the old source")
        precondition(externalMouseCloseDisposition(for: .keep("different-host-window-event-target")) == nil,
                     "a different Host event target must never restore the old source")
        precondition(externalMouseCloseDisposition(for: .keep("other-process-event-target")) == nil,
                     "an event targeted to another process must not request a source dismissal")
        precondition(externalMouseCloseDisposition(for: .keep("frontmost-other")) == nil,
                     "other app frontmost must not request close/restoration through this click")

        let contextID = UUID()
        precondition(isCurrentVisibleDetailsContext(currentContextID: contextID, callbackContextID: contextID, detailsVisible: true),
                     "current visible context should process")
        precondition(!isCurrentVisibleDetailsContext(currentContextID: nil, callbackContextID: contextID, detailsVisible: false),
                     "removed context must reject a stale callback")
        precondition(!isCurrentVisibleDetailsContext(currentContextID: UUID(), callbackContextID: contextID, detailsVisible: true),
                     "old context callback must not process")
        print("external-mouse-production-path observed-overlay-pid+host-window+unique-owner=exact-source-close missing/duplicate/arbitrary-conflict=keep full-screen-rectangle=diagnostic-only detail/other-host/overlay/other-app-frontmost/unknown/stale/invalid=keep PASS")
        print("external-mouse-log-format raw-field-validity=separate owner-verified-project-identity=PID/window other-process-and-unknown=redacted PID-conflict=boolean-only PASS")
    }
#endif

    private func detailsFocusFields(context: DetailsOpenContext, window: NSWindow?, rootView: NSView?) -> String {
        let responder = window?.firstResponder
        let responderType = responder.map { String(reflecting: type(of: $0)) } ?? "none"
        let rootIsFirstResponder = window?.firstResponder.map { $0 === rootView } ?? false
        return "contextID=\(context.id.uuidString) row=\(context.rowIdentifier) hostPID=\(context.hostPID) hostWindow=\(context.hostWindowNumber) clickID=\(context.clickID?.uuidString ?? "none") displayID=\(context.displayID?.uuidString ?? "none") detailWindow=\(window?.windowNumber.description ?? "none") detailKey=\(window?.isKeyWindow ?? false) appKeyWindow=\(NSApp.keyWindow?.windowNumber.description ?? "none") firstResponderType=\(responderType) firstResponderIsDetailsRoot=\(rootIsFirstResponder) overlayActive=\(NSApp.isActive)"
    }

    private func setAppearance(_ mode: PaletteMode) {
        appearanceMode = mode
        for panel in rowPanels { panel.appearance = mode.appearance }
        if let popover { popover.appearance = mode.appearance }
        nonactivatingDetailsPanel?.appearance = mode.appearance
        writeLog("appearance=\(mode.rawValue)")
    }

    private func hideSummary(reason: String) {
        cancelOpeningDetails(reason: reason)
        cancelSummaryPointerGesture(reason: reason)
        if detailsAreVisible { closeDetails(reason: reason, restoreIfSafe: false) }
        let displayedSources = rowPanels.compactMap { panel -> String? in
            guard let identity = panel.displayedHostIdentity, let displayID = panel.displayID else { return nil }
            return "\(panel.rowIdentifier):\(identity.pid):\(identity.windowNumber):\(displayID.uuidString)"
        }.joined(separator: ",")
        for panel in rowPanels {
            panel.orderOut(nil)
            panel.displayedHostIdentity = nil
            panel.displayID = nil
        }
        activeHost = nil
        if lastReason != reason {
            writeLog("hide reason=\(reason) displayedSources=\(displayedSources.isEmpty ? "none" : displayedSources)")
            lastReason = reason
        }
    }

    private func prepareRuntimeFiles() -> Bool {
        do {
            let directory = try OverlayRuntimePaths.runtimeDirectory()
            runtimeDirectoryURL = directory
            let pidURL = directory.appendingPathComponent("overlay-a.pid")
            try OverlayRuntimePaths.writePID(ProcessInfo.processInfo.processIdentifier, to: pidURL)
            ownsPIDFile = true
            guard writeLog("start target=\(targetBundleID) mockData=true process=\(ProcessInfo.processInfo.processIdentifier)") else {
                removePIDFile()
                return false
            }
            return true
        } catch {
            NSLog("Overlay A runtime initialization failed bundleID=%@ error=%@", Bundle.main.bundleIdentifier ?? "unknown", String(describing: error))
            removePIDFile()
            return false
        }
    }

    private func removePIDFile() {
        guard ownsPIDFile, let pidURL else { return }
        do {
            try OverlayRuntimePaths.removePID(ProcessInfo.processInfo.processIdentifier, at: pidURL)
            ownsPIDFile = false
        } catch {
            NSLog("Overlay A PID cleanup failed path=%@ error=%@", pidURL.path, String(describing: error))
        }
    }

    @discardableResult
    private func writeLog(_ message: String) -> Bool {
        guard let logURL else {
            NSLog("Overlay A log write failed: runtime directory is unavailable")
            return false
        }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: logURL, options: .atomic)
            }
            return true
        } catch {
            NSLog("Overlay A log write failed path=%@ error=%@", logURL.path, String(describing: error))
            return false
        }
    }

    private func string(_ rect: CGRect) -> String {
        "x=\(Int(rect.origin.x)) y=\(Int(rect.origin.y)) w=\(Int(rect.width)) h=\(Int(rect.height))"
    }

    private func preciseString(_ rect: CGRect) -> String {
        String(format: "x=%.2f y=%.2f w=%.2f h=%.2f", rect.origin.x, rect.origin.y, rect.width, rect.height)
    }
}

@MainActor
private final class DetailsViewController: NSViewController {
    private let values: DemoValues
    private let appearanceChanged: (PaletteMode) -> Void
    private let refreshRequested: () -> Void
    private let formatter = DateFormatter()
    private let nowLabel = NSTextField(labelWithString: "")
    private let fiveResetLabel = NSTextField(labelWithString: "")
    private let fiveCountdownLabel = NSTextField(labelWithString: "")
    private let weekResetLabel = NSTextField(labelWithString: "")
    private let weekCountdownLabel = NSTextField(labelWithString: "")
    private let snapshotLabel = NSTextField(labelWithString: "")
    private let fiveProgress = NSProgressIndicator()
    private let weekProgress = NSProgressIndicator()

    init(values: DemoValues, appearanceChanged: @escaping (PaletteMode) -> Void, refreshRequested: @escaping () -> Void) {
        self.values = values
        self.appearanceChanged = appearanceChanged
        self.refreshRequested = refreshRequested
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = DetailsRootView(frame: NSRect(x: 0, y: 0, width: 300, height: 440))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.layer?.cornerRadius = 12

        let title = heading("额度摘要")
        let mock = NSTextField(labelWithString: "模拟数据 · 不连接账号")
        mock.font = .systemFont(ofSize: 11, weight: .medium)
        mock.textColor = .secondaryLabelColor

        let five = sectionTitle("5h 剩余", value: "96%")
        fiveProgress.isIndeterminate = false
        fiveProgress.minValue = 0
        fiveProgress.maxValue = 100
        fiveProgress.doubleValue = 96
        fiveProgress.controlSize = .small
        fiveProgress.style = .bar
        fiveResetLabel.font = .systemFont(ofSize: 12)
        fiveResetLabel.textColor = .secondaryLabelColor
        fiveCountdownLabel.font = .systemFont(ofSize: 12)
        fiveCountdownLabel.textColor = .secondaryLabelColor

        let week = sectionTitle("周额度剩余", value: "66%")
        weekProgress.isIndeterminate = false
        weekProgress.minValue = 0
        weekProgress.maxValue = 100
        weekProgress.doubleValue = 66
        weekProgress.controlSize = .small
        weekProgress.style = .bar
        weekResetLabel.font = .systemFont(ofSize: 12)
        weekResetLabel.textColor = .secondaryLabelColor
        weekCountdownLabel.font = .systemFont(ofSize: 12)
        weekCountdownLabel.textColor = .secondaryLabelColor

        let credits = sectionTitle("限额重置", value: "剩余 2 次")
        let time = heading("当前时间")
        nowLabel.font = .systemFont(ofSize: 12)
        nowLabel.textColor = .secondaryLabelColor
        snapshotLabel.font = .systemFont(ofSize: 11)
        snapshotLabel.textColor = .secondaryLabelColor

        let refresh = NSButton(title: "刷新模拟数据", target: self, action: #selector(refresh))
        refresh.bezelStyle = .rounded
        refresh.controlSize = .small
        let appearance = NSSegmentedControl(labels: ["自动", "浅色", "深色"], trackingMode: .selectOne, target: self, action: #selector(changeAppearance(_:)))
        appearance.selectedSegment = 0
        appearance.controlSize = .small
        appearance.setAccessibilityLabel("覆盖层外观")

        let stack = NSStackView(views: [
            title, mock,
            five, fiveProgress, fiveResetLabel, fiveCountdownLabel,
            separator(),
            week, weekProgress, weekResetLabel, weekCountdownLabel,
            separator(), credits,
            separator(), time, nowLabel, snapshotLabel,
            refresh, appearance,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        for view in [fiveProgress, weekProgress] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 264).isActive = true
        }
        stack.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        stack.topAnchor.constraint(equalTo: root.topAnchor).isActive = true
        stack.bottomAnchor.constraint(equalTo: root.bottomAnchor).isActive = true
        self.view = root
        self.preferredContentSize = root.frame.size

        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
    }

    func update(values: DemoValues) {
        guard isViewLoaded else { return }
        let now = Date()
        fiveResetLabel.stringValue = "重置于 \(formatter.string(from: values.fiveHourReset)) Asia/Shanghai"
        fiveCountdownLabel.stringValue = "约 \(countdown(values.fiveHourReset.timeIntervalSince(now))) 后"
        weekResetLabel.stringValue = "重置于 \(formatter.string(from: values.weekReset)) Asia/Shanghai"
        weekCountdownLabel.stringValue = "约 \(countdown(values.weekReset.timeIntervalSince(now))) 后"
        nowLabel.stringValue = "Asia/Shanghai  ·  \(timeNow())"
        snapshotLabel.stringValue = "模拟快照更新于 \(formatter.string(from: values.snapshotAt)) Asia/Shanghai"
    }

    private func heading(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 16, weight: .semibold)
        field.textColor = .labelColor
        return field
    }

    private func sectionTitle(_ label: String, value: String) -> NSView {
        let left = NSTextField(labelWithString: label)
        left.font = .systemFont(ofSize: 14, weight: .medium)
        let right = NSTextField(labelWithString: value)
        right.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        let row = NSStackView(views: [left, right])
        row.orientation = .horizontal
        row.distribution = .equalSpacing
        row.widthAnchor.constraint(equalToConstant: 264).isActive = true
        return row
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 264).isActive = true
        return line
    }

    private func timeNow() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date())
    }

    private func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        if minutes > 0 { return "\(minutes) 分钟" }
        return "不到 1 分钟"
    }

    @objc private func refresh() { refreshRequested() }

    @objc private func changeAppearance(_ sender: NSSegmentedControl) {
        let mode: PaletteMode = switch sender.selectedSegment {
        case 1: .light
        case 2: .dark
        default: .system
        }
        appearanceChanged(mode)
    }
}

@main
@MainActor
private struct OverlayAMain {
    static func main() {
#if OVERLAY_A_EXTERNAL_MOUSE_REGRESSION
        OverlayAppDelegate.runExternalMouseRegressionCheck()
#elseif OVERLAY_A_OPENING_BUTTON_REGRESSION
        OverlayAppDelegate.runOpeningButtonRegressionCheck()
#elseif OVERLAY_A_PROBE_GUARD_REGRESSION
        OverlayAppDelegate.runProbeGuardRegressionCheck()
#elseif OVERLAY_A_DETAILS_STAGE_POLICY_REGRESSION
        OverlayAppDelegate.runNonactivatingDetailsStagePolicyRegressionCheck()
#elseif OVERLAY_A_GUARD_RECORDER_LIFECYCLE_REGRESSION
        OverlayAppDelegate.runProbeGuardRecorderLifecycleRegressionCheck()
#else
        let app = NSApplication.shared
        let delegate = OverlayAppDelegate()
        app.delegate = delegate
        app.run()
#endif
    }
}
