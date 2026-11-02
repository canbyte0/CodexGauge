import AppKit
import Darwin

private enum MockHostConstants {
    static let bundleIdentifier = "local.msl.QuotaButton.MockHost"
    static let railWidth: CGFloat = 62
    static let buttonSize = CGSize(width: 44, height: 44)
    static let leftInset: CGFloat = 9
    static let centerFromWindowTop: CGFloat = 560
    static let rowPitch: CGFloat = 52.75
    static let glyphSize: CGFloat = 20

    static func anchorSlotFrame(for windowFrame: CGRect) -> CGRect {
        CGRect(
            x: windowFrame.minX + leftInset,
            y: windowFrame.maxY - centerFromWindowTop - buttonSize.height / 2,
            width: buttonSize.width,
            height: buttonSize.height
        )
    }

    static func navigationGlyphFrame(for windowFrame: CGRect, centerFromTop: CGFloat) -> CGRect {
        let center = CGPoint(
            x: windowFrame.minX + railWidth / 2,
            y: windowFrame.maxY - centerFromTop
        )
        return CGRect(
            x: center.x - glyphSize / 2,
            y: center.y - glyphSize / 2,
            width: glyphSize,
            height: glyphSize
        )
    }
}

@MainActor
private final class MockHostView: NSView {
    private var railVisible = true
    private let stateChanged: (Bool) -> Void
    var isRailVisible: Bool { railVisible }
    private let status = NSTextField(labelWithString: "模拟宿主运行中 · 无真实聊天或账号内容")
    private let mockInput = NSTextField(string: "")
    private let logger: MockHostRuntimeLog
    private let showSecondWindow: () -> Void

    init(frame frameRect: NSRect, logger: MockHostRuntimeLog, stateChanged: @escaping (Bool) -> Void, showSecondWindow: @escaping () -> Void) {
        self.logger = logger
        self.stateChanged = stateChanged
        self.showSecondWindow = showSecondWindow
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let heading = NSTextField(labelWithString: "SIMULATED HOST · 第87号顶部导航对齐")
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        heading.alignment = .center
        addSubview(heading)

        let subtitle = NSTextField(wrappingLabelWithString: "仅模拟导航几何：文件夹、布局、分支与额度同中心线，垂直间距约53pt；额度槽位距完整窗口顶边560pt。")
        subtitle.alignment = .center
        subtitle.textColor = .secondaryLabelColor
        addSubview(subtitle)

        mockInput.placeholderString = "模拟输入框（只用于观察焦点）"
        mockInput.setAccessibilityLabel("模拟宿主输入框")
        addSubview(mockInput)

        status.alignment = .center
        status.textColor = .secondaryLabelColor
        addSubview(status)

        addAction("移动窗口", selector: #selector(moveHost), tag: 1)
        addAction("增高窗口32pt", selector: #selector(increaseHostHeight), tag: 2, width: 142)
        addAction("缩短窗口32pt", selector: #selector(decreaseHostHeight), tag: 3, width: 142)
        addAction("切换模拟窄栏", selector: #selector(toggleRail), tag: 4)
        addAction("打开第二窗口（应隐藏）", selector: #selector(openSecondWindow), tag: 5, width: 180)
        addAction("重新激活宿主", selector: #selector(activateHost), tag: 6)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let size = bounds.size
        subviews.first(where: { $0 is NSTextField && ($0 as? NSTextField)?.stringValue.hasPrefix("SIMULATED HOST") == true })?.frame = CGRect(x: 110, y: size.height * 0.67, width: max(480, size.width - 190), height: 28)
        subviews.first(where: { $0 is NSTextField && ($0 as? NSTextField)?.stringValue.hasPrefix("仅模拟导航几何") == true })?.frame = CGRect(x: 140, y: size.height * 0.57, width: max(420, size.width - 260), height: 44)
        mockInput.frame = CGRect(x: MockHostConstants.railWidth + 180, y: size.height * 0.42, width: max(300, size.width - MockHostConstants.railWidth - 360), height: 32)
        status.frame = CGRect(x: MockHostConstants.railWidth + 50, y: 36, width: max(500, size.width - MockHostConstants.railWidth - 100), height: 24)

        let actionY = size.height * 0.29
        var x = MockHostConstants.railWidth + 70
        for view in subviews.compactMap({ $0 as? NSButton }).sorted(by: { $0.tag < $1.tag }) {
            view.frame = CGRect(x: x, y: actionY, width: view.frame.width, height: 30)
            x += view.frame.width + 12
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard railVisible else { return }
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: MockHostConstants.railWidth, height: bounds.height)).fill()
        NSColor.separatorColor.setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: MockHostConstants.railWidth - 0.5, y: 0))
        separator.line(to: NSPoint(x: MockHostConstants.railWidth - 0.5, y: bounds.height))
        separator.lineWidth = 1
        separator.stroke()

        let windowFrame = window?.frame ?? CGRect(origin: .zero, size: bounds.size)
        let upperSymbols = ["house", "photo.on.rectangle", "clock", "books.vertical", "at", "ellipsis"]
        for (index, symbol) in upperSymbols.enumerated() {
            let frame = MockHostConstants.navigationGlyphFrame(
                for: windowFrame,
                centerFromTop: 73.5 + CGFloat(index) * MockHostConstants.rowPitch
            )
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "模拟导航项") {
                image.isTemplate = true
                NSColor.secondaryLabelColor.set()
                image.draw(in: viewRect(forScreenRect: frame))
            }
        }

        let lowerRows: [(symbol: String, centerFromTop: CGFloat)] = [
            ("folder", MockHostConstants.centerFromWindowTop - 3 * MockHostConstants.rowPitch),
            ("square.grid.2x2", MockHostConstants.centerFromWindowTop - 2 * MockHostConstants.rowPitch),
            ("point.3.connected.trianglepath.dotted", MockHostConstants.centerFromWindowTop - MockHostConstants.rowPitch),
        ]
        for row in lowerRows {
            let frame = MockHostConstants.navigationGlyphFrame(for: windowFrame, centerFromTop: row.centerFromTop)
            if let image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: "模拟顶部导航项") {
                image.isTemplate = true
                NSColor.secondaryLabelColor.set()
                image.draw(in: viewRect(forScreenRect: frame))
            }
        }

        let separatorY = windowFrame.maxY - 350
        let separatorFrame = viewRect(forScreenRect: CGRect(
            x: windowFrame.minX + 14,
            y: separatorY,
            width: MockHostConstants.railWidth - 28,
            height: 1
        ))
        NSColor.separatorColor.setStroke()
        let rowDivider = NSBezierPath()
        rowDivider.move(to: CGPoint(x: separatorFrame.minX, y: separatorFrame.midY))
        rowDivider.line(to: CGPoint(x: separatorFrame.maxX, y: separatorFrame.midY))
        rowDivider.lineWidth = 1
        rowDivider.stroke()

        // This outlined slot belongs only to the synthetic host and is not product chrome.
        NSColor.systemBlue.withAlphaComponent(0.42).setStroke()
        let slotFrame = viewRect(forScreenRect: MockHostConstants.anchorSlotFrame(for: windowFrame))
        let slot = NSBezierPath(roundedRect: slotFrame, xRadius: 10, yRadius: 10)
        slot.lineWidth = 1
        slot.setLineDash([3, 3], count: 2, phase: 0)
        slot.stroke()

        let avatar = NSRect(x: 12, y: 10, width: 32, height: 32)
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(ovalIn: avatar).fill()
    }

    @objc private func moveHost() {
        guard let window else { return }
        var frame = window.frame
        frame.origin.x += 72
        frame.origin.y += 38
        if let screenFrame = window.screen?.frame {
            frame.origin.x = min(max(frame.origin.x, screenFrame.minX), screenFrame.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, screenFrame.minY), screenFrame.maxY - frame.height)
        }
        window.setFrame(frame, display: true, animate: false)
        status.stringValue = "宿主已程序化移动 · 顶部导航槽位应保持相对位置"
        logger.write("mock-host-move frame=\(describe(frame))")
    }

    private func viewRect(forScreenRect rect: CGRect) -> CGRect {
        guard let window else { return rect }
        return convert(window.convertFromScreen(rect), from: nil)
    }

    @objc private func increaseHostHeight() {
        resizeHostHeight(delta: 32, event: "height-increase")
    }

    @objc private func decreaseHostHeight() {
        resizeHostHeight(delta: -32, event: "height-decrease")
    }

    private func resizeHostHeight(delta: CGFloat, event: String) {
        guard let window else { return }
        var frame = window.frame
        frame.size.height = max(window.minSize.height, frame.height + delta)
        if let screenFrame = window.screen?.frame {
            frame.size.height = min(frame.size.height, screenFrame.height)
            if frame.maxY > screenFrame.maxY {
                frame.origin.y = screenFrame.maxY - frame.height
            }
        }
        window.setFrame(frame, display: true, animate: false)
        status.stringValue = "窗口高度已改变 · 顶部导航槽位应保持距完整窗口顶边560pt"
        logger.write("mock-host-\(event) frame=\(describe(frame))")
    }

    @objc private func toggleRail() {
        railVisible.toggle()
        status.stringValue = railVisible ? "模拟窄栏已展开" : "模拟窄栏已隐藏（检测能力边界验证）"
        logger.write("mock-host-rail-visible value=\(railVisible)")
        stateChanged(railVisible)
        needsDisplay = true
    }

    @objc private func openSecondWindow() { showSecondWindow() }

    @objc private func activateHost() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func addAction(_ title: String, selector: Selector, tag: Int, width: CGFloat = 126) {
        let button = NSButton(title: title, target: self, action: selector)
        button.tag = tag
        button.bezelStyle = .rounded
        button.setAccessibilityLabel(title)
        button.frame.size.width = width
        addSubview(button)
    }

    private func describe(_ rect: CGRect) -> String {
        "x=\(Int(rect.minX)),y=\(Int(rect.minY)),w=\(Int(rect.width)),h=\(Int(rect.height))"
    }
}

@MainActor
private final class MockSecondWindowView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let label = NSTextField(labelWithString: "SIMULATED SECOND HOST WINDOW")
        label.alignment = .center
        label.frame = CGRect(x: 20, y: frameRect.height / 2, width: frameRect.width - 40, height: 30)
        addSubview(label)
        let hint = NSTextField(labelWithString: "出现两个合格窗口时，候选按钮应隐藏")
        hint.alignment = .center
        hint.textColor = .secondaryLabelColor
        hint.frame = CGRect(x: 20, y: frameRect.height / 2 - 34, width: frameRect.width - 40, height: 24)
        addSubview(hint)
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
private final class MockHostRuntimeLog {
    let directory: URL
    let fileURL: URL
    let pidURL: URL
    let stateURL: URL

    init(bundle: Bundle = .main) throws {
        let bundleID = bundle.bundleIdentifier ?? "unknown"
        let candidateDirectory = bundle.bundleURL.deletingLastPathComponent()
        let revisionRoot = candidateDirectory.deletingLastPathComponent()
        directory = revisionRoot.appendingPathComponent("runtime", isDirectory: true).appendingPathComponent(bundleID, isDirectory: true)
        fileURL = directory.appendingPathComponent("mock-host.log")
        pidURL = directory.appendingPathComponent("mock-host.pid")
        stateURL = directory.appendingPathComponent("mock-host-state.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path), let handle = try? FileHandle(forWritingTo: fileURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func writePID(_ pid: pid_t) { try? "\(pid)\n".write(to: pidURL, atomically: true, encoding: .utf8) }
    func removePID() { try? FileManager.default.removeItem(at: pidURL) }

    func publishState(main: NSWindow?, second: NSWindow?, railVisible: Bool) {
        func row(for window: NSWindow, isMain: Bool) -> [String: Any] {
            var result: [String: Any] = [
                "windowNumber": window.windowNumber,
                "x": Double(window.frame.minX),
                "y": Double(window.frame.minY),
                "width": Double(window.frame.width),
                "height": Double(window.frame.height),
                "visible": window.isVisible,
                "miniaturized": window.isMiniaturized,
                "main": isMain,
                "railVisible": isMain ? railVisible : true,
            ]
            if isMain {
                let slot = MockHostConstants.anchorSlotFrame(for: window.frame)
                result["quotaSlot"] = [
                    "x": Double(slot.minX),
                    "y": Double(slot.minY),
                    "width": Double(slot.width),
                    "height": Double(slot.height),
                    "centerFromWindowTop": Double(MockHostConstants.centerFromWindowTop),
                    "nativeRowPitch": Double(MockHostConstants.rowPitch),
                ]
            }
            return result
        }
        var windows: [[String: Any]] = []
        if let main { windows.append(row(for: main, isMain: true)) }
        if let second { windows.append(row(for: second, isMain: false)) }
        let state: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundleIdentifier": MockHostConstants.bundleIdentifier,
            "windows": windows,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }
}

@MainActor
private final class QuotaButtonMockHostAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var logger: MockHostRuntimeLog?
    private var mainWindow: NSWindow?
    private var secondWindow: NSWindow?
    private var signalSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let log = try MockHostRuntimeLog()
            logger = log
            log.writePID(pid_t(ProcessInfo.processInfo.processIdentifier))
            log.write("mock-host-launch bundle=\(Bundle.main.bundleIdentifier ?? "unknown") pid=\(ProcessInfo.processInfo.processIdentifier)")

            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 8, width: 1100, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "SIMULATED HOST · 第87号顶部导航对齐验证"
            window.minSize = CGSize(width: 950, height: 660)
            window.contentView = MockHostView(
                frame: CGRect(origin: .zero, size: window.contentView?.bounds.size ?? CGSize(width: 1180, height: 820)),
                logger: log,
                stateChanged: { [weak self] value in self?.publishState(railVisible: value) },
                showSecondWindow: { [weak self] in self?.showSecondWindow() }
            )
            window.delegate = self
            window.makeKeyAndOrderFront(nil)
            mainWindow = window
            publishState(railVisible: true)
            log.write("mock-host-main-window frame=\(describe(window.frame)) windowNumber=\(window.windowNumber)")
            installMenu()
            installTerminationSignalHandler()
        } catch {
            NSLog("QuotaButtonMockHost startup failed: %@", String(describing: error))
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger?.write("mock-host-terminate")
        logger?.removePID()
        if let stateURL = logger?.stateURL { try? FileManager.default.removeItem(at: stateURL) }
        signalSource?.cancel()
        signalSource = nil
    }

    private func showSecondWindow() {
        if let secondWindow {
            secondWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: CGRect(x: 520, y: 300, width: 520, height: 380),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SIMULATED SECOND HOST WINDOW"
        window.contentView = MockSecondWindowView(frame: CGRect(origin: .zero, size: CGSize(width: 520, height: 380)))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        secondWindow = window
        publishState(railVisible: true)
        logger?.write("mock-host-second-window-open frame=\(describe(window.frame)) windowNumber=\(window.windowNumber)")
    }

    func windowDidMove(_ notification: Notification) { publishState(railVisible: currentRailVisibility) }
    func windowDidResize(_ notification: Notification) { publishState(railVisible: currentRailVisibility) }
    func windowDidMiniaturize(_ notification: Notification) { publishState(railVisible: currentRailVisibility) }
    func windowDidDeminiaturize(_ notification: Notification) { publishState(railVisible: currentRailVisibility) }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === secondWindow { secondWindow = nil }
        if window === mainWindow { mainWindow = nil }
        publishState(railVisible: currentRailVisibility)
    }

    private var currentRailVisibility: Bool {
        (mainWindow?.contentView as? MockHostView)?.isRailVisible ?? true
    }

    private func publishState(railVisible: Bool) {
        logger?.publishState(main: mainWindow, second: secondWindow, railVisible: railVisible)
    }

    private func installTerminationSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        signalSource = source
    }

    private func installMenu() {
        let mainMenu = NSMenu(title: "固定额度按钮模拟宿主")
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "固定额度按钮模拟宿主")
        let quitItem = NSMenuItem(title: "退出模拟宿主", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }

    private func describe(_ rect: CGRect) -> String {
        "x=\(Int(rect.minX)),y=\(Int(rect.minY)),w=\(Int(rect.width)),h=\(Int(rect.height))"
    }
}

@main
@MainActor
private struct QuotaButtonMockHostMain {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = QuotaButtonMockHostAppDelegate()
        application.delegate = delegate
        application.run()
    }
}
