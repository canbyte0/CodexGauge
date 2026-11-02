import AppKit
import CoreGraphics
import Darwin
import SwiftUI

private enum QuotaButtonProfile {
    #if QUOTA_ANCHORED_TESTING
    static let hostBundleIdentifier = "local.msl.QuotaButton.MockHost"
    #else
    static let hostBundleIdentifier = "com.openai.codex"
    #endif

    // Candidate profile derived from the user's 2026-10-29 top-navigation reference.
    // The outer button frame is expressed in AppKit screen points from the host frame.
    static let buttonSize = CGSize(width: 44, height: 44)
    static let leftInset: CGFloat = 9
    static let topInset: CGFloat = 538
    static let centerFromWindowTop: CGFloat = 560
    static let nativeRowPitch: CGFloat = 52.75
    static let glyphSize: CGFloat = 20
    static let minimumWindowSize = CGSize(width: 900, height: 700)
    #if !QUOTA_ANCHORED_TESTING
    // Exact installed host identity checked from /Applications/ChatGPT.app/Contents/Info.plist on 2026-11-02.
    // The anchored button profile is enabled only for this host bundle/build/version.
    static let supportedHostBuildVersion = "23880"
    static let supportedHostShortVersion = "26.1027.51404"
    static let supportedHostInfoPlistSHA256 = "7a3920d56d052cdf4bf803a92e2098be015eaf9263589d51e04ac4121f16eed7"
    #endif
}

private struct QuotaHostAnchor {
    let application: NSRunningApplication
    let pid: pid_t
    let windowNumber: CGWindowID
    let quartzBounds: CGRect?
    let appKitFrame: CGRect
    let screen: NSScreen

    var buttonFrame: CGRect {
        CGRect(
            x: appKitFrame.minX + QuotaButtonProfile.leftInset,
            y: appKitFrame.maxY - QuotaButtonProfile.topInset - QuotaButtonProfile.buttonSize.height,
            width: QuotaButtonProfile.buttonSize.width,
            height: QuotaButtonProfile.buttonSize.height
        )
    }
}

private enum QuotaHostAnchorFailure: String, Error {
    case noFrontmostTarget = "target-not-frontmost"
    case appHidden = "target-hidden-or-terminated"
    case unsupportedHostBuild = "host-build-not-verified-for-reference-profile"
    case mockHostStateUnavailable = "mock-host-state-unavailable"
    case mockHostRailHidden = "mock-host-rail-hidden"
    case windowListUnavailable = "window-list-unavailable"
    case noWindow = "target-window-unavailable"
    case ambiguousWindows = "target-window-ambiguous"
    case invalidGeometry = "target-window-geometry-invalid"
    case screenMappingUnavailable = "screen-mapping-unavailable"
    case buttonOutsideWindow = "button-outside-target-window"
    case buttonOutsideVisibleScreen = "button-outside-visible-screen"
}

@MainActor
private enum QuotaHostWindowLocator {
    static func locate(
        frontmostApplication: NSRunningApplication?,
        ownBundleIdentifier: String,
        retainedHostPID: pid_t?,
        detailsAreVisible: Bool
    ) -> Result<QuotaHostAnchor, QuotaHostAnchorFailure> {
        let target = QuotaButtonProfile.hostBundleIdentifier
        let application: NSRunningApplication?

        if frontmostApplication?.bundleIdentifier == target {
            application = frontmostApplication
        } else if frontmostApplication?.bundleIdentifier == ownBundleIdentifier,
                  detailsAreVisible,
                  let retainedHostPID {
            application = NSWorkspace.shared.runningApplications.first {
                $0.processIdentifier == retainedHostPID && $0.bundleIdentifier == target
            }
        } else {
            application = nil
        }

        guard let application else { return .failure(.noFrontmostTarget) }
        guard !application.isTerminated, !application.isHidden else { return .failure(.appHidden) }

        #if QUOTA_ANCHORED_TESTING
        return locateMockHost(application)
        #else
        return locateProductionHost(application)
        #endif
    }

    #if !QUOTA_ANCHORED_TESTING
    private static func locateProductionHost(_ application: NSRunningApplication) -> Result<QuotaHostAnchor, QuotaHostAnchorFailure> {
        guard application.bundleIdentifier == QuotaButtonProfile.hostBundleIdentifier,
              let bundleURL = application.bundleURL,
              let hostInfo = Bundle(url: bundleURL)?.infoDictionary,
              let hostBuild = hostInfo["CFBundleVersion"] as? String,
              let hostShortVersion = hostInfo["CFBundleShortVersionString"] as? String,
              let candidateInfo = Bundle.main.infoDictionary,
              let profileBundleID = candidateInfo["QuotaHostProfileBundleIdentifier"] as? String,
              let profileBuild = candidateInfo["QuotaHostProfileBuildVersion"] as? String,
              let profileShortVersion = candidateInfo["QuotaHostProfileShortVersion"] as? String,
              let profileInfoPlistSHA256 = candidateInfo["QuotaHostProfileInfoPlistSHA256"] as? String,
              hostBuild == QuotaButtonProfile.supportedHostBuildVersion,
              hostShortVersion == QuotaButtonProfile.supportedHostShortVersion,
              profileBundleID == QuotaButtonProfile.hostBundleIdentifier,
              profileBuild == QuotaButtonProfile.supportedHostBuildVersion,
              profileShortVersion == QuotaButtonProfile.supportedHostShortVersion,
              profileInfoPlistSHA256 == QuotaButtonProfile.supportedHostInfoPlistSHA256
        else { return .failure(.unsupportedHostBuild) }

        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return .failure(.windowListUnavailable)
        }

        let pid = application.processIdentifier
        let ownedVisibleWindows = rawWindows.compactMap { item -> (CGWindowID, CGRect)? in
            guard ownerPID(item) == pid,
                  (item[kCGWindowLayer as String] as? Int ?? -1) == 0,
                  let number = windowNumber(item),
                  let bounds = quartzRect(item),
                  (item[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0
            else { return nil }
            return (number, bounds)
        }

        guard !ownedVisibleWindows.isEmpty else { return .failure(.noWindow) }
        // Count all visible layer-zero windows first, including small settings and modal windows.
        guard ownedVisibleWindows.count == 1 else { return .failure(.ambiguousWindows) }
        guard let (windowNumber, quartzBounds) = ownedVisibleWindows.first,
              quartzBounds.width >= QuotaButtonProfile.minimumWindowSize.width,
              quartzBounds.height >= QuotaButtonProfile.minimumWindowSize.height,
              let (appKitFrame, screen) = convertToAppKit(quartzBounds),
              appKitFrame.width >= QuotaButtonProfile.minimumWindowSize.width,
              appKitFrame.height >= QuotaButtonProfile.minimumWindowSize.height
        else { return .failure(.screenMappingUnavailable) }

        let anchor = QuotaHostAnchor(
            application: application,
            pid: pid,
            windowNumber: windowNumber,
            quartzBounds: quartzBounds,
            appKitFrame: appKitFrame,
            screen: screen
        )
        guard anchor.appKitFrame.insetBy(dx: -1, dy: -1).contains(anchor.buttonFrame) else {
            return .failure(.buttonOutsideWindow)
        }
        guard screen.visibleFrame.contains(anchor.buttonFrame) else {
            return .failure(.buttonOutsideVisibleScreen)
        }
        return .success(anchor)
    }
    #endif

    #if QUOTA_ANCHORED_TESTING
    private static func locateMockHost(_ application: NSRunningApplication) -> Result<QuotaHostAnchor, QuotaHostAnchorFailure> {
        let revisionRoot = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let stateURL = revisionRoot
            .appendingPathComponent("runtime/local.msl.QuotaButton.MockHost", isDirectory: true)
            .appendingPathComponent("mock-host-state.json")
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              state["bundleIdentifier"] as? String == QuotaButtonProfile.hostBundleIdentifier,
              (state["pid"] as? Int32 ?? Int32(state["pid"] as? Int ?? -1)) == application.processIdentifier,
              let windows = state["windows"] as? [[String: Any]]
        else { return .failure(.mockHostStateUnavailable) }

        let visibleWindows = windows.filter {
            ($0["visible"] as? Bool ?? false) && !($0["miniaturized"] as? Bool ?? false)
        }
        guard !visibleWindows.isEmpty else { return .failure(.noWindow) }
        guard visibleWindows.count == 1, let row = visibleWindows.first,
              row["main"] as? Bool == true
        else { return .failure(.ambiguousWindows) }
        guard row["railVisible"] as? Bool == true else { return .failure(.mockHostRailHidden) }
        guard let windowNumber = cgWindowNumber(row["windowNumber"]),
              let appKitFrame = appKitRect(row),
              appKitFrame.width >= QuotaButtonProfile.minimumWindowSize.width,
              appKitFrame.height >= QuotaButtonProfile.minimumWindowSize.height
        else { return .failure(.invalidGeometry) }

        let matchingScreens = NSScreen.screens.filter { $0.frame.contains(appKitFrame) }
        guard matchingScreens.count == 1, let screen = matchingScreens.first else {
            return .failure(.screenMappingUnavailable)
        }
        let anchor = QuotaHostAnchor(
            application: application,
            pid: application.processIdentifier,
            windowNumber: windowNumber,
            quartzBounds: nil,
            appKitFrame: appKitFrame,
            screen: screen
        )
        guard appKitFrame.insetBy(dx: -1, dy: -1).contains(anchor.buttonFrame) else {
            return .failure(.buttonOutsideWindow)
        }
        guard screen.visibleFrame.contains(anchor.buttonFrame) else {
            return .failure(.buttonOutsideVisibleScreen)
        }
        return .success(anchor)
    }

    private static func cgWindowNumber(_ value: Any?) -> CGWindowID? {
        if let number = value as? Int, number > 0, number <= Int(UInt32.max) { return CGWindowID(number) }
        if let number = value as? UInt32, number > 0 { return number }
        return nil
    }

    private static func appKitRect(_ row: [String: Any]) -> CGRect? {
        guard let x = row["x"] as? Double,
              let y = row["y"] as? Double,
              let width = row["width"] as? Double,
              let height = row["height"] as? Double else { return nil }
        let rect = CGRect(x: x, y: y, width: width, height: height)
        guard !rect.isNull, !rect.isInfinite, !rect.isEmpty,
              rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return nil }
        return rect
    }
    #endif

    private static func windowNumber(_ item: [String: Any]) -> CGWindowID? {
        let value = item[kCGWindowNumber as String]
        if let number = value as? UInt32, number > 0 { return number }
        if let number = value as? Int, number > 0, number <= Int(UInt32.max) { return CGWindowID(number) }
        return nil
    }

    private static func ownerPID(_ item: [String: Any]) -> pid_t? {
        let value = item[kCGWindowOwnerPID as String]
        if let pid = value as? Int32, pid > 0 { return pid_t(pid) }
        if let pid = value as? Int, let exact = Int32(exactly: pid), exact > 0 { return pid_t(exact) }
        return nil
    }

    private static func quartzRect(_ item: [String: Any]) -> CGRect? {
        guard let bounds = item[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        let rect = CGRect(
            x: bounds["X"] ?? .nan,
            y: bounds["Y"] ?? .nan,
            width: bounds["Width"] ?? .nan,
            height: bounds["Height"] ?? .nan
        )
        guard !rect.isNull, !rect.isInfinite, !rect.isEmpty,
              rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return nil }
        return rect
    }

    private static func convertToAppKit(_ rect: CGRect) -> (CGRect, NSScreen)? {
        var matches: [(screen: NSScreen, quartzScreen: CGRect, scaleX: CGFloat, scaleY: CGFloat)] = []
        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            let cgScreen = CGDisplayBounds(displayID)
            guard cgScreen.width > 0, cgScreen.height > 0 else { continue }
            let scaleX = cgScreen.width / screen.frame.width
            let scaleY = cgScreen.height / screen.frame.height
            guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else { continue }
            let quartzButton = CGRect(
                x: rect.minX + QuotaButtonProfile.leftInset * scaleX,
                y: rect.minY + QuotaButtonProfile.topInset * scaleY,
                width: QuotaButtonProfile.buttonSize.width * scaleX,
                height: QuotaButtonProfile.buttonSize.height * scaleY
            )
            guard cgScreen.contains(quartzButton) else { continue }
            matches.append((screen, cgScreen, scaleX, scaleY))
        }
        guard matches.count == 1, let match = matches.first else { return nil }
        let screen = match.screen
        let cgScreen = match.quartzScreen
        let scaleX = match.scaleX
        let scaleY = match.scaleY
        guard cgScreen.width > 0, cgScreen.height > 0 else { return nil }
        let converted = CGRect(
            x: screen.frame.minX + (rect.minX - cgScreen.minX) / scaleX,
            y: screen.frame.minY + (cgScreen.maxY - rect.maxY) / scaleY,
            width: rect.width / scaleX,
            height: rect.height / scaleY
        )
        return (converted, screen)
    }
}

@MainActor
private struct QuotaAnchorButtonView: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: QuotaButtonProfile.glyphSize, weight: .regular))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .frame(width: QuotaButtonProfile.buttonSize.width, height: QuotaButtonProfile.buttonSize.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: QuotaButtonProfile.buttonSize.width, height: QuotaButtonProfile.buttonSize.height)
        .contentShape(Rectangle())
        .accessibilityLabel("额度")
        .help("额度")
    }
}

@MainActor
private final class QuotaAnchorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class QuotaDetailsPanel: NSWindow {
    var onEscape: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, isKeyWindow {
            onEscape?()
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
private final class QuotaAnchoredButtonController: NSObject, NSWindowDelegate, NSMenuDelegate {
    private let model: QuotaWindowModel
    private let log: QuotaButtonRuntimeLog
    private let ownBundleIdentifier = Bundle.main.bundleIdentifier ?? ""
    private var buttonPanel: QuotaAnchorPanel?
    private var detailsPanel: QuotaDetailsPanel?
    private var detailsDeactivationObserver: NSObjectProtocol?
    private var detailsLocalMouseMonitor: Any?
    private weak var applicationMenuForDismissal: NSMenu?
    private var detailsSessionID: UInt64 = 0
    private var naturalDetailsContentHeight: CGFloat?
    private var effectiveDetailsContentHeight: CGFloat?
    private var timer: Timer?
    private var retainedHostPID: pid_t?
    private var latestAnchor: QuotaHostAnchor?
    private var lastFailure = ""
    private var lastAnchorSignature: String?
    private var stopped = false

    init(model: QuotaWindowModel, log: QuotaButtonRuntimeLog) {
        self.model = model
        self.log = log
    }

    func start() {
        guard !stopped else { return }
        createButtonPanelIfNeeded()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAnchor() }
        }
        timer?.tolerance = 0.05
        refreshAnchor()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        timer?.invalidate()
        timer = nil
        closeDetails()
        buttonPanel?.orderOut(nil)
        buttonPanel = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? QuotaDetailsPanel, panel === detailsPanel else { return }
        removeDetailsDismissalObservers()
        let hostApplication = latestAnchor?.application
        detailsPanel = nil
        clearDetailsContentHeights()
        model.stopClock()
        model.showSummary()
        restoreHostFocus(hostApplication)
    }

    private func refreshAnchor() {
        guard !stopped else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier == QuotaButtonProfile.hostBundleIdentifier {
            retainedHostPID = frontmost?.processIdentifier
        }

        switch QuotaHostWindowLocator.locate(
            frontmostApplication: frontmost,
            ownBundleIdentifier: ownBundleIdentifier,
            retainedHostPID: retainedHostPID,
            detailsAreVisible: detailsPanel?.isVisible == true
        ) {
        case .failure(let failure):
            let hadVisibleAnchor = lastAnchorSignature != nil
            // If the host is already frontmost, its app focus is already restored. If
            // this candidate is frontmost while the details window is open, retain
            // the host identity long enough to return activation when safety checks
            // close the details panel (for example, on an ambiguous host window).
            let hostToReactivate: NSRunningApplication? =
                frontmost?.bundleIdentifier == ownBundleIdentifier && detailsPanel?.isVisible == true
                    ? latestAnchor?.application
                    : nil
            latestAnchor = nil
            buttonPanel?.orderOut(nil)
            if detailsPanel?.isVisible == true {
                closeDetails(returnFocusToHost: hostToReactivate)
            }
            if lastFailure != failure.rawValue || hadVisibleAnchor {
                log.write("anchor-hidden reason=\(failure.rawValue) frontmostClass=\(frontmostClass(frontmost))")
                lastFailure = failure.rawValue
            }
            lastAnchorSignature = nil
        case .success(let anchor):
            if detailsPanel?.isVisible == true,
               let previous = latestAnchor,
               (previous.pid != anchor.pid || previous.windowNumber != anchor.windowNumber) {
                closeDetails(returnFocusToHost: anchor.application)
            }
            latestAnchor = anchor
            lastFailure = ""
            createButtonPanelIfNeeded()
            if let buttonPanel {
                setFrameIfNeeded(anchor.buttonFrame, for: buttonPanel)
                if !buttonPanel.isVisible { buttonPanel.orderFrontRegardless() }
            }
            if let detailsPanel, detailsPanel.isVisible {
                positionDetailsPanel(detailsPanel, beside: anchor.buttonFrame, screen: anchor.screen)
            }
            let signature = "pid=\(anchor.pid)|window=\(anchor.windowNumber)|host=\(describe(anchor.appKitFrame))|button=\(describe(anchor.buttonFrame))|visible=\(buttonPanel?.isVisible == true)|details=\(detailsPanel?.isVisible == true)"
            if signature != lastAnchorSignature {
                let source = anchor.quartzBounds == nil ? "mock-appkit-state" : "quartz-global-to-appkit"
                log.write("anchor-visible source=\(source) hostPID=\(anchor.pid) window=\(anchor.windowNumber) host=\(describe(anchor.appKitFrame)) button=\(describe(anchor.buttonFrame)) details=\(detailsPanel?.isVisible == true)")
                lastAnchorSignature = signature
            }
        }
    }

    private func createButtonPanelIfNeeded() {
        guard buttonPanel == nil else { return }
        let panel = QuotaAnchorPanel(
            contentRect: CGRect(origin: .zero, size: QuotaButtonProfile.buttonSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.contentView = NSHostingView(rootView: QuotaAnchorButtonView { [weak self] in self?.toggleDetails() })
        buttonPanel = panel
    }

    private func toggleDetails() {
        guard buttonPanel?.isVisible == true, latestAnchor != nil else {
            return
        }
        if detailsPanel?.isVisible == true {
            closeDetails(returnFocusToHost: latestAnchor?.application)
            return
        }
        openDetails()
    }

    private func openDetails() {
        guard let anchor = latestAnchor else { return }
        detailsSessionID &+= 1
        let openingSessionID = detailsSessionID
        naturalDetailsContentHeight = nil
        effectiveDetailsContentHeight = nil
        let panel = QuotaDetailsPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: QuotaWindowLayout.detailsContentSize.width, height: 1)),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.alphaValue = 0
        panel.isReleasedWhenClosed = false
        panel.title = "额度详情"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.closeDetails(returnFocusToHost: self?.latestAnchor?.application) }
        detailsPanel = panel
        panel.contentView = NSHostingView(rootView: DetailsView(
            model: model,
            onCollapse: { [weak self] in self?.closeDetails(returnFocusToHost: self?.latestAnchor?.application) },
            onRefresh: { [weak self] in self?.refreshQuota() },
            displayMode: .anchoredCompact,
            onContentHeight: { [weak self, weak panel] height in
                guard let self, let panel else { return }
                self.receiveDetailsContentHeight(height, for: panel, sessionID: openingSessionID)
            }
        ))
        model.startClock()
        positionDetailsPanel(panel, beside: anchor.buttonFrame, screen: anchor.screen)
        panel.orderFrontRegardless()
        installDetailsDismissalObservers()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.revealDetailsPanelIfMeasurementTimedOut(panel, sessionID: openingSessionID)
        }
    }

    func observeApplicationMenuForOutsideDismissal(_ menu: NSMenu) {
        applicationMenuForDismissal = menu
        menu.delegate = self
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === applicationMenuForDismissal,
              let sessionID = visibleDetailsSessionID else { return }
        passivelyCloseDetails(sessionID: sessionID, reason: "application-menu-open")
    }

    private var visibleDetailsSessionID: UInt64? {
        guard detailsPanel?.isVisible == true else { return nil }
        return detailsSessionID
    }

    private func installDetailsDismissalObservers() {
        guard detailsDeactivationObserver == nil, detailsLocalMouseMonitor == nil else { return }
        let observedSessionID = detailsSessionID
        detailsDeactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !NSApp.isActive else { return }
                self.passivelyCloseDetails(sessionID: observedSessionID, reason: "application-did-resign-active")
            }
        }
        let mouseDownMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        detailsLocalMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDownMask) { [weak self] event in
            // AppKit invokes local monitor handlers on the main thread. Returning the same
            // event preserves the click and lets the owning window handle it normally.
            MainActor.assumeIsolated {
                self?.handleLocalMouseDown(event)
            }
            return event
        }
    }

    private func handleLocalMouseDown(_ event: NSEvent) {
        guard let sessionID = visibleDetailsSessionID else { return }
        if event.window === buttonPanel || isDetailsInteractionWindow(event.window) { return }
        schedulePassiveDetailsClose(sessionID: sessionID, reason: "local-mouse-down-outside-details")
    }

    private func isDetailsInteractionWindow(_ candidate: NSWindow?) -> Bool {
        guard let detailsPanel else { return false }
        var window = candidate
        var visited = Set<ObjectIdentifier>()
        while let current = window, visited.insert(ObjectIdentifier(current)).inserted {
            if current === detailsPanel { return true }
            window = current.parent ?? current.sheetParent
        }
        return false
    }

    private func schedulePassiveDetailsClose(sessionID: UInt64, reason: String) {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.passivelyCloseDetails(sessionID: sessionID, reason: reason)
        }
    }

    private func passivelyCloseDetails(sessionID: UInt64, reason: String) {
        guard detailsSessionID == sessionID, detailsPanel?.isVisible == true else { return }
        log.write("details-passive-dismiss reason=\(reason)")
        closeDetails(returnFocusToHost: nil)
    }

    private func removeDetailsDismissalObservers() {
        if let detailsDeactivationObserver {
            NotificationCenter.default.removeObserver(detailsDeactivationObserver)
            self.detailsDeactivationObserver = nil
        }
        if let detailsLocalMouseMonitor {
            NSEvent.removeMonitor(detailsLocalMouseMonitor)
            self.detailsLocalMouseMonitor = nil
        }
        detailsSessionID &+= 1
    }

    private func closeDetails(returnFocusToHost hostApplication: NSRunningApplication? = nil) {
        guard let panel = detailsPanel else { return }
        removeDetailsDismissalObservers()
        detailsPanel = nil
        clearDetailsContentHeights()
        panel.delegate = nil
        panel.onEscape = nil
        panel.orderOut(nil)
        panel.close()
        model.stopClock()
        model.showSummary()
        restoreHostFocus(hostApplication)
    }

    private func restoreHostFocus(_ application: NSRunningApplication?) {
        guard let application, !application.isTerminated, !application.isHidden else { return }
        _ = application.activate(options: [])
    }

    private func receiveDetailsContentHeight(_ measuredHeight: CGFloat, for panel: QuotaDetailsPanel, sessionID: UInt64) {
        guard detailsPanel === panel, detailsSessionID == sessionID,
              measuredHeight.isFinite, measuredHeight > 0 else { return }
        let normalizedHeight = ceil(measuredHeight * 2) / 2
        let previousHeight = naturalDetailsContentHeight
        naturalDetailsContentHeight = normalizedHeight
        guard let anchor = latestAnchor else { return }
        positionDetailsPanel(panel, beside: anchor.buttonFrame, screen: anchor.screen)
        if panel.alphaValue < 1 {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
            panel.alphaValue = 1
        }
        if previousHeight == nil || abs((previousHeight ?? 0) - normalizedHeight) > 0.5 {
            log.write("details-content-measured session=\(sessionID) natural=\(Int(normalizedHeight)) effective=\(Int(effectiveDetailsContentHeight ?? normalizedHeight))")
        }
    }

    private func revealDetailsPanelIfMeasurementTimedOut(_ panel: QuotaDetailsPanel, sessionID: UInt64) {
        guard detailsPanel === panel, detailsSessionID == sessionID, panel.isVisible,
              panel.alphaValue < 1 else { return }
        guard let anchor = latestAnchor else { return }
        let chromeHeight = max(0, panel.frame.height - (panel.contentView?.bounds.height ?? 0))
        let availableHeight = max(1, anchor.screen.visibleFrame.height - chromeHeight)
        let fallbackHeight = min(QuotaWindowLayout.detailsMeasurementFallbackContentHeight, availableHeight)
        if abs((effectiveDetailsContentHeight ?? 0) - fallbackHeight) > 0.5 {
            effectiveDetailsContentHeight = fallbackHeight
            panel.setContentSize(CGSize(width: QuotaWindowLayout.detailsContentSize.width, height: fallbackHeight))
        }
        positionDetailsPanel(panel, beside: anchor.buttonFrame, screen: anchor.screen)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.alphaValue = 1
        log.write("details-content-measurement-fallback session=\(sessionID) viewport=\(Int(fallbackHeight))")
    }

    private func clearDetailsContentHeights() {
        naturalDetailsContentHeight = nil
        effectiveDetailsContentHeight = nil
    }

    private func positionDetailsPanel(_ panel: NSWindow, beside buttonFrame: CGRect, screen: NSScreen) {
        if let naturalDetailsContentHeight {
            let chromeHeight = max(0, panel.frame.height - (panel.contentView?.bounds.height ?? 0))
            if let constrainedHeight = QuotaWindowLayout.anchoredDetailsContentHeight(
                naturalContentHeight: naturalDetailsContentHeight,
                windowChromeHeight: chromeHeight,
                visibleFrameHeight: screen.visibleFrame.height
            ), abs((effectiveDetailsContentHeight ?? 0) - constrainedHeight) > 0.5 {
                effectiveDetailsContentHeight = constrainedHeight
                panel.setContentSize(CGSize(width: QuotaWindowLayout.detailsContentSize.width, height: constrainedHeight))
            }
        }
        let contentHeight = effectiveDetailsContentHeight ?? panel.contentView?.bounds.height ?? 1
        let contentSize = CGSize(width: QuotaWindowLayout.detailsContentSize.width, height: contentHeight)
        let outerSize = panel.frameRect(forContentRect: CGRect(origin: .zero, size: contentSize)).size
        let placement = QuotaWindowLayout.anchoredDetailsFrame(
            buttonFrame: buttonFrame,
            outerSize: outerSize,
            visibleFrame: screen.visibleFrame
        )
        setFrameIfNeeded(placement.frame, for: panel)
    }

    private func setFrameIfNeeded(_ frame: CGRect, for window: NSWindow) {
        let current = window.frame
        guard abs(current.minX - frame.minX) > 0.5 || abs(current.minY - frame.minY) > 0.5 ||
              abs(current.width - frame.width) > 0.5 || abs(current.height - frame.height) > 0.5 else { return }
        window.setFrame(frame, display: true, animate: false)
    }

    private func refreshQuota() {
        model.refresh()
    }

    private func describe(_ rect: CGRect) -> String {
        "x=\(Int(rect.minX)),y=\(Int(rect.minY)),w=\(Int(rect.width)),h=\(Int(rect.height))"
    }

    private func frontmostClass(_ application: NSRunningApplication?) -> String {
        guard let application else { return "none" }
        if application.bundleIdentifier == QuotaButtonProfile.hostBundleIdentifier { return "target" }
        if application.bundleIdentifier == ownBundleIdentifier { return "self" }
        return "other"
    }
}

@MainActor
private final class QuotaButtonRuntimeLog {
    let directory: URL
    let fileURL: URL
    let pidURL: URL

    init(bundle: Bundle = .main) throws {
        let bundleID = bundle.bundleIdentifier ?? "unknown"
        let candidateDirectory = bundle.bundleURL.deletingLastPathComponent()
        let revisionRoot = candidateDirectory.deletingLastPathComponent()
        directory = revisionRoot.appendingPathComponent("runtime", isDirectory: true).appendingPathComponent(bundleID, isDirectory: true)
        fileURL = directory.appendingPathComponent("quota-button.log")
        pidURL = directory.appendingPathComponent("quota-button.pid")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func writePID(_ pid: pid_t) {
        try? "\(pid)\n".write(to: pidURL, atomically: true, encoding: .utf8)
    }

    func removePID() {
        try? FileManager.default.removeItem(at: pidURL)
    }
}

@MainActor
private final class QuotaButtonAppDelegate: NSObject, NSApplicationDelegate {
    private var model: QuotaWindowModel?
    private var controller: QuotaAnchoredButtonController?
    private var runtimeLog: QuotaButtonRuntimeLog?
    private var signalSource: DispatchSourceSignal?
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let log = try QuotaButtonRuntimeLog()
            runtimeLog = log
            log.writePID(pid_t(ProcessInfo.processInfo.processIdentifier))
            let model = QuotaWindowModel(provider: QuotaRealProvider(), refreshPolicy: .backgroundEvery60Seconds)
            model.onEvent = { [weak log] event in log?.write(event) }
            let controller = QuotaAnchoredButtonController(model: model, log: log)
            self.model = model
            self.controller = controller
            controller.start()
            installMenu()
            installTerminationSignalHandler()
            let workspace = NSWorkspace.shared.notificationCenter
            workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak model] _ in
                Task { @MainActor in model?.sleep() }
            })
            workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak model] _ in
                Task { @MainActor in model?.wake() }
            })
            model.startBackgroundRefresh()
        } catch {
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { workspace.removeObserver(observer) }
        workspaceObservers.removeAll()
        controller?.stop()
        model?.shutdown()
        runtimeLog?.removePID()
        signalSource?.cancel()
        signalSource = nil
    }

    private func installTerminationSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        signalSource = source
    }

    private func installMenu() {
        let mainMenu = NSMenu(title: "额度按钮")
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "额度按钮")
        controller?.observeApplicationMenuForOutsideDismissal(appMenu)
        let quitItem = NSMenuItem(title: "退出额度按钮", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }
}

@main
@MainActor
private struct QuotaAnchoredButtonMain {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = QuotaButtonAppDelegate()
        application.delegate = delegate
        application.run()
    }
}
