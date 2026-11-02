import AppKit
import Foundation

private enum DemoBridge {
    static let openDetails = Notification.Name("OverlayA.Demo.openDetails")
    static let closeDetails = Notification.Name("OverlayA.Demo.closeDetails")
    static let layout = Notification.Name("OverlayA.Demo.layout")
    static let requestLayout = Notification.Name("OverlayA.Demo.requestLayout")
    static let activateWindow = Notification.Name("OverlayA.Demo.activateWindow")
}

@MainActor
private final class DemoHostView: NSView {
    private let railWidth: CGFloat = 56
    private let railBackground = NSColor.controlBackgroundColor
    private let avatarRect = NSRect(x: 12, y: 10, width: 32, height: 32)
    private let contentLabel = NSTextField(labelWithString: "仅用于验证窗口定位与输入")
    private let focusField = NSTextField(string: "")
    private let navigationButtons: [NSButton]
    private let openSecondWindow: () -> Void
    private var railVisible = true
    private var canPublishLayout = true
    private var status = "测试宿主 · 不含聊天或额度数据"
    private var lastPublishedLayout = ""

    init(frame frameRect: NSRect, openSecondWindow: @escaping () -> Void) {
        self.openSecondWindow = openSecondWindow
        let symbols = ["house", "clock", "square.grid.2x2", "tray", "at", "ellipsis", "folder", "shippingbox"]
        navigationButtons = symbols.enumerated().map { index, symbol in
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(), target: nil, action: nil)
            button.identifier = NSUserInterfaceItemIdentifier("nav-\(index)")
            button.setButtonType(.momentaryChange)
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = .labelColor
            button.setAccessibilityLabel("模拟原有导航项 \(index + 1)")
            return button
        }
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        contentLabel.font = .systemFont(ofSize: 14)
        contentLabel.textColor = .secondaryLabelColor
        contentLabel.alignment = .center
        contentLabel.stringValue = "测试宿主 · 不含聊天或额度数据"
        addSubview(contentLabel)
        focusField.placeholderString = "点击此处后测试焦点是否保持"
        focusField.setAccessibilityLabel("模拟聊天输入框")
        addSubview(focusField)
        for (index, button) in navigationButtons.enumerated() {
            button.target = self
            button.action = #selector(navigationTapped(_:))
            button.tag = index
            addSubview(button)
        }

        let hideRail = NSButton(title: "模拟收起窄栏", target: self, action: #selector(toggleRail))
        hideRail.bezelStyle = .rounded
        hideRail.tag = 900
        addSubview(hideRail)

        let showRail = NSButton(title: "模拟展开窄栏", target: self, action: #selector(toggleRail))
        showRail.bezelStyle = .rounded
        showRail.tag = 901
        showRail.isHidden = true
        addSubview(showRail)

        let activateHost = NSButton(title: "激活模拟宿主", target: self, action: #selector(activateHostWindow))
        activateHost.bezelStyle = .rounded
        activateHost.tag = 904
        addSubview(activateHost)

        let moveResizeHost = NSButton(title: "移动并缩放", target: self, action: #selector(moveAndResizeHost))
        moveResizeHost.bezelStyle = .rounded
        moveResizeHost.tag = 905
        addSubview(moveResizeHost)

        let openDetails = NSButton(title: "触发详情测试桥", target: self, action: #selector(triggerDetailsBridge))
        openDetails.bezelStyle = .rounded
        openDetails.tag = 906
        addSubview(openDetails)

        let closeDetails = NSButton(title: "关闭详情测试桥", target: self, action: #selector(closeDetailsBridge))
        closeDetails.bezelStyle = .rounded
        closeDetails.tag = 907
        addSubview(closeDetails)

        let stopOverlay = NSButton(title: "停止覆盖层", target: self, action: #selector(stopOverlayProcess))
        stopOverlay.bezelStyle = .rounded
        stopOverlay.tag = 908
        addSubview(stopOverlay)

        let secondWindow = NSButton(title: "打开第二个模拟窗口", target: self, action: #selector(showSecondWindow))
        secondWindow.bezelStyle = .rounded
        secondWindow.tag = 909
        addSubview(secondWindow)

        let statusField = NSTextField(labelWithString: status)
        statusField.tag = 902
        statusField.alignment = .center
        statusField.textColor = .secondaryLabelColor
        addSubview(statusField)

        let instructions = NSTextField(labelWithString: "移动或缩放此窗口；摘要应跟随。切换到其他 App 或最小化时，摘要应隐藏。")
        instructions.tag = 903
        instructions.alignment = .center
        instructions.textColor = .secondaryLabelColor
        addSubview(instructions)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let size = bounds.size
        contentLabel.frame = NSRect(x: railWidth + 30, y: size.height * 0.62, width: max(250, size.width - railWidth - 60), height: 24)
        focusField.frame = NSRect(x: railWidth + 100, y: size.height * 0.42, width: max(260, size.width - railWidth - 200), height: 30)
        for (index, button) in navigationButtons.enumerated() {
            button.frame = NSRect(x: 10, y: size.height - 70 - CGFloat(index) * 44, width: 36, height: 34)
            button.isHidden = !railVisible
        }
        viewWithTag(900)?.frame = NSRect(x: railWidth + 24, y: size.height * 0.30, width: 130, height: 28)
        viewWithTag(900)?.isHidden = !railVisible
        viewWithTag(901)?.frame = NSRect(x: railWidth + 24, y: size.height * 0.30, width: 130, height: 28)
        viewWithTag(901)?.isHidden = railVisible
        viewWithTag(904)?.frame = NSRect(x: railWidth + 170, y: size.height * 0.30, width: 130, height: 28)
        viewWithTag(905)?.frame = NSRect(x: railWidth + 315, y: size.height * 0.30, width: 130, height: 28)
        viewWithTag(906)?.frame = NSRect(x: railWidth + 460, y: size.height * 0.30, width: 150, height: 28)
        viewWithTag(907)?.frame = NSRect(x: railWidth + 625, y: size.height * 0.30, width: 150, height: 28)
        viewWithTag(908)?.frame = NSRect(x: railWidth + 790, y: size.height * 0.30, width: 130, height: 28)
        viewWithTag(909)?.frame = NSRect(x: railWidth + 890, y: size.height * 0.30, width: 126, height: 28)
        viewWithTag(902)?.frame = NSRect(x: railWidth + 30, y: size.height * 0.53, width: max(250, size.width - railWidth - 60), height: 24)
        viewWithTag(903)?.frame = NSRect(x: railWidth + 30, y: size.height * 0.22, width: max(320, size.width - railWidth - 60), height: 42)
        needsDisplay = true
        DispatchQueue.main.async { [weak self] in self?.publishMockLayout() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if railVisible {
            railBackground.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: railWidth, height: bounds.height)).fill()
            NSColor.separatorColor.setStroke()
            let separator = NSBezierPath()
            separator.move(to: NSPoint(x: railWidth - 0.5, y: 0))
            separator.line(to: NSPoint(x: railWidth - 0.5, y: bounds.height))
            separator.lineWidth = 1
            separator.stroke()
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(ovalIn: avatarRect).fill()
            let person = NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)
            person?.draw(in: avatarRect.insetBy(dx: 8, dy: 7))
        }
    }

    @objc private func navigationTapped(_ sender: NSButton) {
        status = "已点击模拟导航项 \(sender.tag + 1)"
        (viewWithTag(902) as? NSTextField)?.stringValue = status
    }

    @objc private func toggleRail(_ sender: NSButton) {
        railVisible.toggle()
        sender.isHidden = true
        viewWithTag(railVisible ? 900 : 901)?.isHidden = false
        status = railVisible ? "模拟窄栏已展开" : "模拟窄栏已收起"
        (viewWithTag(902) as? NSTextField)?.stringValue = status
        needsLayout = true
        needsDisplay = true
    }

    @objc private func activateHostWindow(_ sender: NSButton) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func moveAndResizeHost(_ sender: NSButton) {
        guard let window else { return }
        var frame = window.frame
        frame.origin.x += 80
        frame.origin.y += 40
        frame.size.width -= 80
        frame.size.height -= 40
        window.setFrame(frame, display: true, animate: false)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func showSecondWindow(_ sender: NSButton) { openSecondWindow() }

    @objc private func triggerDetailsBridge(_ sender: NSButton) {
        DistributedNotificationCenter.default().postNotificationName(
            DemoBridge.openDetails, object: nil, deliverImmediately: true
        )
    }

    @objc private func closeDetailsBridge(_ sender: NSButton) {
        DistributedNotificationCenter.default().postNotificationName(
            DemoBridge.closeDetails, object: nil, deliverImmediately: true
        )
    }

    func publishMockLayout(force: Bool = false, requestID: String? = nil) {
        guard canPublishLayout, let window else { return }
        let lowestNavigationY = navigationButtons.map(\.frame.minY).min() ?? 0
        let anchorBottom = avatarRect.maxY + 8
        let anchorTop = lowestNavigationY - 8
        let railLocal = NSRect(x: 0, y: 0, width: railVisible ? railWidth : 0, height: bounds.height)
        let anchorLocal = railVisible && anchorTop > anchorBottom
            ? NSRect(x: 0, y: anchorBottom, width: railWidth, height: anchorTop - anchorBottom)
            : .zero
        let railOnScreen = window.convertToScreen(convert(railLocal, to: nil))
        let anchorOnScreen = window.convertToScreen(convert(anchorLocal, to: nil))
        let signature = [
            ProcessInfo.processInfo.processIdentifier, window.windowNumber,
            railVisible ? 1 : 0, railOnScreen.minX, railOnScreen.minY, railOnScreen.width, railOnScreen.height,
            anchorOnScreen.minX, anchorOnScreen.minY, anchorOnScreen.width, anchorOnScreen.height,
        ].map(String.init(describing:)).joined(separator: ",")
        guard force || signature != lastPublishedLayout else { return }
        lastPublishedLayout = signature
        var userInfo: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "windowID": window.windowNumber,
            "visible": railVisible,
            "railWidth": railVisible ? Double(railWidth) : 0,
            "railX": Double(railOnScreen.minX), "railY": Double(railOnScreen.minY),
            "railW": Double(railOnScreen.width), "railH": Double(railOnScreen.height),
            "anchorX": Double(anchorOnScreen.minX), "anchorY": Double(anchorOnScreen.minY),
            "anchorW": Double(anchorOnScreen.width), "anchorH": Double(anchorOnScreen.height),
            "timestamp": Date().timeIntervalSince1970,
        ]
        if let requestID { userInfo["requestID"] = requestID }
        DistributedNotificationCenter.default().postNotificationName(
            DemoBridge.layout, object: nil, userInfo: userInfo, deliverImmediately: true
        )
    }

    func stopPublishingLayouts() {
        canPublishLayout = false
    }

    @objc private func stopOverlayProcess(_ sender: NSButton) {
        guard let process = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "org.openai.codex.QuotaOverlayA.Demo"
        }) else { return }
        process.terminate()
    }
}

@MainActor
private final class DemoHostDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var windows: [NSWindow] = []
    private var windowObservers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    private var bridgeObservers: [NSObjectProtocol] = []
    private var runtimeDirectoryURL: URL?
    private var ownsPIDFile = false
    private var isTerminating = false
    private var inputReceiptDiagnosticLog: OverlayInputReceiptDiagnosticLog?
    private var inputReceiptMonitor: Any?
    private let terminationSignal = OverlayTerminationSignal()
    private var pidURL: URL? { runtimeDirectoryURL?.appendingPathComponent("demo-host.pid") }
    private var inputReceiptDiagnosticsEnabled: Bool {
        OverlayInputReceiptDiagnosticGate.isEnabled(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            expectedBundleIdentifier: "org.openai.codex.QuotaOverlayA.DemoHost",
            explicitFlag: Bundle.main.object(forInfoDictionaryKey: "OverlayMouseReceiptDiagnostics") as? Bool == true
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard terminationSignal.install(onTermination: { NSApp.terminate(nil) }) else {
            NSLog("Overlay A demo host could not install the SIGTERM event source; refusing startup")
            NSApp.terminate(nil)
            return
        }
        guard prepareRuntimeFiles() else {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        installInputReceiptDiagnosticsIfEnabled()
        installBridgeObservers()
        createWindow()
    }

    private func createWindow() {
        guard !isTerminating else { return }
        let content = DemoHostView(frame: NSRect(x: 0, y: 0, width: 1080, height: 740)) { [weak self] in
            self?.createWindow()
        }
        let window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Swift/ARC 通过现有强引用管理窗口，避免 AppKit 在关闭时额外释放。
        window.isReleasedWhenClosed = false
        window.title = "Overlay A · 空白模拟宿主 · \(windows.count + 1)"
        window.minSize = NSSize(width: 800, height: 660)
        window.contentView = content
        window.center()
        if let previous = windows.last {
            var frame = window.frame
            frame.origin.x = previous.frame.origin.x + 48
            frame.origin.y = previous.frame.origin.y - 36
            window.setFrame(frame, display: true)
        }
        windows.append(window)
        inputReceiptDiagnosticLog?.record(
            .windowRegistered,
            hostPID: ProcessInfo.processInfo.processIdentifier,
            hostWindowID: window.windowNumber,
            observedWindowID: window.windowNumber
        )
        window.delegate = self
        let center = NotificationCenter.default
        var observers: [NSObjectProtocol] = []
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window, weak content] _ in
                DispatchQueue.main.async { [weak self, weak window, weak content] in
                    guard let self, !self.isTerminating, let window, let content,
                          self.windows.contains(where: { $0 === window })
                    else { return }
                    content.publishMockLayout()
                }
            })
        }
        windowObservers[ObjectIdentifier(window)] = observers
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self, weak window, weak content] in
            guard let self, !self.isTerminating, let window, let content,
                  self.windows.contains(where: { $0 === window })
            else { return }
            content.publishMockLayout()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        unregisterWindow(window)
    }

    private func unregisterWindow(_ window: NSWindow) {
        (window.contentView as? DemoHostView)?.stopPublishingLayouts()
        inputReceiptDiagnosticLog?.record(
            .windowUnregistered,
            hostPID: ProcessInfo.processInfo.processIdentifier,
            hostWindowID: window.windowNumber,
            observedWindowID: window.windowNumber,
            reason: .windowRemoved
        )
        if let observers = windowObservers.removeValue(forKey: ObjectIdentifier(window)) {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        windows.removeAll { $0 === window }
        window.delegate = nil
        if windows.isEmpty {
            removeInputReceiptMonitor(reason: .noManagedWindows)
        }
    }

    private func installInputReceiptDiagnosticsIfEnabled() {
        guard inputReceiptDiagnosticsEnabled,
              let runtimeDirectoryURL
        else { return }
        let log = OverlayInputReceiptDiagnosticLog(
            runtimeDirectory: runtimeDirectoryURL,
            fileName: "host-input-receipt.log",
            component: .host,
            processID: ProcessInfo.processInfo.processIdentifier,
            maximumRecords: 24
        )
        inputReceiptDiagnosticLog = log
        log.record(.processStarted, hostPID: ProcessInfo.processInfo.processIdentifier)
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let log = self.inputReceiptDiagnosticLog else { return event }
            let eventWindow = event.window
            let matchedWindow = eventWindow.flatMap { candidate in
                self.windows.first(where: { $0 === candidate })
            }
            let windowID = matchedWindow?.windowNumber
            log.record(
                .localMouseReceipt,
                stream: .hostMouse,
                hostPID: ProcessInfo.processInfo.processIdentifier,
                hostWindowID: windowID,
                observedWindowID: windowID,
                targetRole: matchedWindow == nil ? .unknown : .host,
                targetWindowFieldPresent: eventWindow != nil,
                eventTimestamp: event.timestamp,
                windowX: matchedWindow == nil ? nil : Double(event.locationInWindow.x),
                windowY: matchedWindow == nil ? nil : Double(event.locationInWindow.y)
            )
            if !log.isStreamOpen(.hostMouse) {
                Task { @MainActor [weak self] in
                    self?.removeInputReceiptMonitor(reason: .streamBudgetExhausted)
                }
            }
            return event
        }
        guard let monitor else {
            log.record(.localMonitorUnavailable, hostPID: ProcessInfo.processInfo.processIdentifier, reason: .setupFailed)
            return
        }
        inputReceiptMonitor = monitor
        log.record(.localMonitorInstalled, hostPID: ProcessInfo.processInfo.processIdentifier)
    }

    private func removeInputReceiptMonitor(reason: OverlayInputReceiptReason) {
        guard let monitor = inputReceiptMonitor else { return }
        NSEvent.removeMonitor(monitor)
        inputReceiptMonitor = nil
        inputReceiptDiagnosticLog?.record(
            .monitorRemoved,
            hostPID: ProcessInfo.processInfo.processIdentifier,
            reason: reason
        )
    }

    private func installBridgeObservers() {
        let center = DistributedNotificationCenter.default()
        let request = center.addObserver(forName: DemoBridge.requestLayout, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in
                guard let self,
                      !self.isTerminating,
                      let pid = notification.userInfo?["pid"] as? NSNumber,
                      pid.int32Value == ProcessInfo.processInfo.processIdentifier,
                      let windowID = notification.userInfo?["windowID"] as? NSNumber,
                      let requestID = notification.userInfo?["requestID"] as? String,
                      self.windows.contains(where: { $0.windowNumber == Int(windowID.intValue) })
                else { return }
                let activeWindows = self.windows
                for window in activeWindows {
                    (window.contentView as? DemoHostView)?.publishMockLayout(force: true, requestID: requestID)
                }
            }
        }
        let activate = center.addObserver(forName: DemoBridge.activateWindow, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in
                guard let self,
                      !self.isTerminating,
                      let pid = notification.userInfo?["pid"] as? NSNumber,
                      pid.int32Value == ProcessInfo.processInfo.processIdentifier,
                      let number = notification.userInfo?["windowID"] as? NSNumber,
                      let window = self.windows.first(where: { $0.windowNumber == Int(number.intValue) }),
                      !window.isMiniaturized
                else { return }
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
        bridgeObservers = [request, activate]
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !isTerminating else { return }
        isTerminating = true
        terminationSignal.stopMonitoring()
        bridgeObservers.forEach(DistributedNotificationCenter.default().removeObserver)
        bridgeObservers.removeAll()

        let windowsToClose = windows
        for window in windowsToClose {
            window.close()
            unregisterWindow(window)
        }

        let remainingObservers = Array(windowObservers.values)
        for observers in remainingObservers {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        windowObservers.removeAll()
        windows.removeAll()
        removeInputReceiptMonitor(reason: .applicationTerminating)
        inputReceiptDiagnosticLog?.finish(
            event: .processTerminating,
            contextID: nil,
            reason: .applicationTerminating
        )
        inputReceiptDiagnosticLog = nil
        removePIDFile()
        if !terminationSignal.restorePreviousSignalDisposition() {
            NSLog("Overlay A demo host could not restore the previous SIGTERM disposition")
        }
    }

    private func prepareRuntimeFiles() -> Bool {
        do {
            runtimeDirectoryURL = try OverlayRuntimePaths.runtimeDirectory()
            guard let pidURL else {
                NSLog("Overlay A demo host runtime initialization failed: PID path is unavailable")
                return false
            }
            try OverlayRuntimePaths.writePID(ProcessInfo.processInfo.processIdentifier, to: pidURL)
            ownsPIDFile = true
            return true
        } catch {
            NSLog("Overlay A demo host runtime initialization failed bundleID=%@ path=%@ error=%@", Bundle.main.bundleIdentifier ?? "unknown", runtimeDirectoryURL?.path ?? "unavailable", String(describing: error))
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
            NSLog("Overlay A demo host PID cleanup failed path=%@ error=%@", pidURL.path, String(describing: error))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !isTerminating }
}

@main
@MainActor
private struct DemoHostMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = DemoHostDelegate()
        app.delegate = delegate
        app.run()
    }
}
