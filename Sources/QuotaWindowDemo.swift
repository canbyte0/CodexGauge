import AppKit
import Combine
import SwiftUI

private enum QuotaWindowMode: Equatable {
    case summary
    case details
}

private struct QuotaFixture {
    let fiveHourRemaining: Int
    let weekRemaining: Int
    let resetCount: Int
    let fiveHourReset: Date
    let weekReset: Date
    let snapshotTime: Date

    static func make(at now: Date) -> QuotaFixture {
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let todayAt1745 = calendar.date(
            bySettingHour: 17,
            minute: 45,
            second: 0,
            of: now
        ) ?? now.addingTimeInterval(3_600)
        let fiveHourReset = todayAt1745 > now
            ? todayAt1745
            : calendar.date(byAdding: .day, value: 1, to: todayAt1745) ?? now.addingTimeInterval(3_600)

        let weekReset = calendar.nextDate(
            after: now,
            matching: DateComponents(hour: 9, minute: 0, second: 0, weekday: 6),
            matchingPolicy: .nextTime,
            direction: .forward
        ) ?? now.addingTimeInterval(3_600)

        return QuotaFixture(
            fiveHourRemaining: 96,
            weekRemaining: 66,
            resetCount: 2,
            fiveHourReset: fiveHourReset,
            weekReset: weekReset,
            snapshotTime: now
        )
    }
}

@MainActor
private final class QuotaWindowModel: NSObject, ObservableObject {
    @Published private(set) var mode: QuotaWindowMode = .summary
    @Published private(set) var fixture = QuotaFixture.make(at: Date())
    @Published private(set) var clockNow = Date()
    @Published private(set) var contentSize = QuotaWindowLayout.summaryContentSize

    private var clockTimer: Timer?

    func showDetails(contentHeight: CGFloat) {
        contentSize = CGSize(width: QuotaWindowLayout.detailsContentSize.width, height: contentHeight)
        mode = .details
    }

    func showSummary() {
        contentSize = QuotaWindowLayout.summaryContentSize
        mode = .summary
    }

    func refreshExample() {
        fixture = QuotaFixture.make(at: Date())
        clockNow = Date()
    }

    func startClock() {
        guard clockTimer == nil else { return }
        let timer = Timer(timeInterval: 15, target: self, selector: #selector(updateClock), userInfo: nil, repeats: true)
        clockTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        updateClock(timer)
    }

    func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    @objc private func updateClock(_ timer: Timer) {
        clockNow = Date()
    }
}

@MainActor
private final class QuotaWindow: NSWindow {
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
private final class QuotaWindowController: NSObject, NSWindowDelegate {
    private let model: QuotaWindowModel
    private let log: DemoRuntimeLog
    private var window: QuotaWindow?
    private var summaryFrameBeforeExpansion: CGRect?
    private var detailsWereMoved = false
    private var applyingFrame = false
    private var nextWindowIdentity = 1
    private var windowIdentity: Int?

    init(model: QuotaWindowModel, log: DemoRuntimeLog) {
        self.model = model
        self.log = log
    }

    func showSummaryWindow() {
        if window == nil {
            createWindow()
        }
        guard let window else { return }
        // 菜单命令统一回到摘要，避免重开时依赖 NSHostingView 的隐式尺寸更新。
        model.showSummary()
        summaryFrameBeforeExpansion = nil
        detailsWereMoved = false
        window.setContentSize(QuotaWindowLayout.summaryContentSize)
        positionInitialSummary(window)
        window.makeKeyAndOrderFront(nil)
        model.startClock()
        log.write("window-show mode=summary id=\(windowIdentity ?? 0) frame=\(describe(window.frame))")
    }

    func prepareForTermination() {
        model.stopClock()
        window?.delegate = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        model.stopClock()
        if model.mode == .details, let window {
            let screen = activeScreen(for: window)
            let summaryContent = QuotaWindowLayout.summaryContentSize
            let summaryOuterSize = window.frameRect(forContentRect: CGRect(origin: .zero, size: summaryContent)).size
            let placement: QuotaWindowPlacement
            if !detailsWereMoved, let original = summaryFrameBeforeExpansion {
                placement = QuotaWindowLayout.clamped(
                    CGRect(origin: original.origin, size: summaryOuterSize),
                    to: screen.visibleFrame
                )
            } else {
                placement = QuotaWindowLayout.summaryFrame(
                    from: window.frame,
                    summarySize: summaryOuterSize,
                    visibleFrame: screen.visibleFrame
                )
            }
            persistSummaryPosition(origin: placement.frame.origin, screen: screen)
        } else {
            persistSummaryPosition()
        }
        model.showSummary()
        summaryFrameBeforeExpansion = nil
        detailsWereMoved = false
        log.write("window-close id=\(windowIdentity ?? 0)")
    }

    func windowDidMove(_ notification: Notification) {
        guard !applyingFrame, let window else { return }
        if model.mode == .details {
            detailsWereMoved = true
            log.write("window-move mode=details id=\(windowIdentity ?? 0) frame=\(describe(window.frame))")
        } else {
            persistSummaryPosition()
            log.write("window-move mode=summary id=\(windowIdentity ?? 0) frame=\(describe(window.frame))")
        }
    }

    private func createWindow() {
        let contentRect = CGRect(origin: .zero, size: QuotaWindowLayout.summaryContentSize)
        let createdWindow = QuotaWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        createdWindow.isReleasedWhenClosed = false
        createdWindow.title = "额度示例"
        createdWindow.titleVisibility = .hidden
        createdWindow.titlebarAppearsTransparent = true
        createdWindow.isMovableByWindowBackground = true
        createdWindow.level = .normal
        createdWindow.delegate = self
        createdWindow.onEscape = { [weak self] in
            guard let self, self.model.mode == .details else { return }
            self.collapseToSummary(reason: "escape")
        }

        let rootView = QuotaWindowRootView(
            model: model,
            onExpand: { [weak self] in self?.expandToDetails() },
            onCollapse: { [weak self] in self?.collapseToSummary(reason: "return-button") },
            onRefresh: { [weak self] in self?.refreshExample() }
        )
        createdWindow.contentView = NSHostingView(rootView: rootView)
        window = createdWindow
        windowIdentity = nextWindowIdentity
        nextWindowIdentity += 1
        log.write("window-create id=\(windowIdentity ?? 0) content=88x318 frame=\(describe(createdWindow.frame))")
    }

    private func positionInitialSummary(_ window: NSWindow) {
        let preferredScreen = persistedDisplayHint.flatMap { hint in
            NSScreen.screens.first { screenDisplayNumber($0)?.uint32Value == hint }
        } ?? NSScreen.main ?? NSScreen.screens.first!
        let visibleFrame = preferredScreen.visibleFrame
        let storedX = UserDefaults.standard.object(forKey: "summaryOriginX") as? Double
        let storedY = UserDefaults.standard.object(forKey: "summaryOriginY") as? Double
        let requestedOrigin = CGPoint(
            x: storedX ?? (visibleFrame.midX - window.frame.width / 2),
            y: storedY ?? (visibleFrame.midY - window.frame.height / 2)
        )
        let requested = CGRect(origin: requestedOrigin, size: window.frame.size)
        let placement = QuotaWindowLayout.clamped(requested, to: visibleFrame)
        applyFrame(placement.frame, to: window)
        if !placement.fitsVisibleFrame {
            log.write("placement-warning mode=summary reason=frame-exceeds-visible-frame frame=\(describe(placement.frame))")
        }
        persistSummaryPosition()
    }

    private func expandToDetails() {
        guard let window, model.mode == .summary else { return }
        let screen = activeScreen(for: window)
        let chromeHeight = window.frame.height - window.contentView!.bounds.height
        let visibleContentHeight = QuotaWindowLayout.visibleContentHeight(
            desiredHeight: QuotaWindowLayout.detailsContentSize.height,
            windowChromeHeight: chromeHeight,
            visibleFrameHeight: screen.visibleFrame.height
        )
        let contentSize = CGSize(width: QuotaWindowLayout.detailsContentSize.width, height: visibleContentHeight)
        let expandedOuterSize = window.frameRect(forContentRect: CGRect(origin: .zero, size: contentSize)).size
        summaryFrameBeforeExpansion = window.frame
        detailsWereMoved = false
        let placement = QuotaWindowLayout.expandedFrame(
            from: summaryFrameBeforeExpansion ?? window.frame,
            expandedSize: expandedOuterSize,
            visibleFrame: screen.visibleFrame
        )
        model.showDetails(contentHeight: visibleContentHeight)
        window.setContentSize(contentSize)
        applyFrame(placement.frame, to: window)
        log.write(
            "mode-change mode=details id=\(windowIdentity ?? 0) content=\(Int(contentSize.width))x\(Int(contentSize.height)) frame=\(describe(window.frame)) fits=\(placement.fitsVisibleFrame)"
        )
    }

    private func collapseToSummary(reason: String) {
        guard let window, model.mode == .details else { return }
        let screen = activeScreen(for: window)
        let summaryContent = QuotaWindowLayout.summaryContentSize
        let summaryOuterSize = window.frameRect(forContentRect: CGRect(origin: .zero, size: summaryContent)).size
        let target: QuotaWindowPlacement
        if !detailsWereMoved, let original = summaryFrameBeforeExpansion {
            target = QuotaWindowLayout.clamped(
                CGRect(origin: original.origin, size: summaryOuterSize),
                to: screen.visibleFrame
            )
        } else {
            target = QuotaWindowLayout.summaryFrame(
                from: window.frame,
                summarySize: summaryOuterSize,
                visibleFrame: screen.visibleFrame
            )
        }
        model.showSummary()
        window.setContentSize(summaryContent)
        applyFrame(target.frame, to: window)
        summaryFrameBeforeExpansion = nil
        detailsWereMoved = false
        persistSummaryPosition()
        log.write("mode-change mode=summary reason=\(reason) id=\(windowIdentity ?? 0) frame=\(describe(window.frame)) fits=\(target.fitsVisibleFrame)")
    }

    private func refreshExample() {
        model.refreshExample()
        log.write("example-refresh mode=\(model.mode.logName) id=\(windowIdentity ?? 0)")
    }

    private func applyFrame(_ frame: CGRect, to window: NSWindow) {
        applyingFrame = true
        window.setFrame(frame, display: true, animate: false)
        applyingFrame = false
    }

    private func activeScreen(for window: NSWindow) -> NSScreen {
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? window.screen ?? NSScreen.main!
    }

    private func persistSummaryPosition() {
        guard let window, model.mode == .summary else { return }
        persistSummaryPosition(origin: window.frame.origin, screen: activeScreen(for: window))
    }

    private func persistSummaryPosition(origin: CGPoint, screen: NSScreen) {
        UserDefaults.standard.set(Double(origin.x), forKey: "summaryOriginX")
        UserDefaults.standard.set(Double(origin.y), forKey: "summaryOriginY")
        UserDefaults.standard.set(screenDisplayNumber(screen)?.uint32Value, forKey: "summaryDisplayHint")
    }

    private var persistedDisplayHint: UInt32? {
        (UserDefaults.standard.object(forKey: "summaryDisplayHint") as? NSNumber)?.uint32Value
    }

    private func screenDisplayNumber(_ screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    private func describe(_ frame: CGRect) -> String {
        "x=\(Int(frame.minX)),y=\(Int(frame.minY)),w=\(Int(frame.width)),h=\(Int(frame.height))"
    }
}

private extension QuotaWindowMode {
    var logName: String { self == .summary ? "summary" : "details" }
}

@MainActor
private struct QuotaWindowRootView: View {
    @ObservedObject var model: QuotaWindowModel
    let onExpand: () -> Void
    let onCollapse: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        Group {
            switch model.mode {
            case .summary:
                SummaryView(model: model, onExpand: onExpand)
            case .details:
                DetailsView(model: model, onCollapse: onCollapse, onRefresh: onRefresh)
            }
        }
        .frame(width: model.contentSize.width, height: model.contentSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
private struct SummaryView: View {
    @ObservedObject var model: QuotaWindowModel
    let onExpand: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SummaryMetric(label: "5h", value: QuotaValueFormatter.percent(model.fixture.fiveHourRemaining))
            Divider().padding(.horizontal, 10)
            SummaryMetric(label: "周", value: QuotaValueFormatter.percent(model.fixture.weekRemaining))
            Divider().padding(.horizontal, 10)
            SummaryMetric(label: "重置", value: QuotaValueFormatter.resetCount(model.fixture.resetCount))
            Divider().padding(.horizontal, 10)
            Text(QuotaDateFormat.clock(model.clockNow))
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            Spacer(minLength: 0)
            HStack(alignment: .center) {
                Text("示例")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(action: onExpand) {
                    HStack(spacing: 3) {
                        Text("详情")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(width: QuotaWindowLayout.summaryContentSize.width, height: QuotaWindowLayout.summaryContentSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SummaryMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
    }
}

@MainActor
private struct DetailsView: View {
    @ObservedObject var model: QuotaWindowModel
    let onCollapse: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onCollapse) {
                    Label("返回摘要", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("额度详情")
                        .font(.system(size: 20, weight: .semibold))
                    Text("示例数据 · 不连接账号")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                        .padding(.bottom, 8)

                    DetailQuotaSection(
                        title: "5h 剩余",
                        value: QuotaValueFormatter.percent(model.fixture.fiveHourRemaining),
                        progress: model.fixture.fiveHourRemaining,
                        resetDate: model.fixture.fiveHourReset,
                        now: model.clockNow
                    )
                    Divider()
                    DetailQuotaSection(
                        title: "周剩余",
                        value: QuotaValueFormatter.percent(model.fixture.weekRemaining),
                        progress: model.fixture.weekRemaining,
                        resetDate: model.fixture.weekReset,
                        now: model.clockNow
                    )
                    Divider()

                    HStack {
                        Text("限额重置")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("剩余 \(QuotaValueFormatter.resetCount(model.fixture.resetCount))")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    .padding(.vertical, 12)
                    Divider()

                    VStack(alignment: .leading, spacing: 5) {
                        Text("当前时间")
                            .font(.system(size: 13, weight: .medium))
                        Text(QuotaDateFormat.full(model.clockNow))
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                        Text("Asia/Shanghai")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 12)
                    Divider()

                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("示例快照时间")
                                .font(.system(size: 12, weight: .medium))
                            Text(QuotaDateFormat.snapshot(model.fixture.snapshotTime))
                                .font(.system(size: 12, design: .monospaced))
                                .monospacedDigit()
                            Text("时钟更新不改变示例快照。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button(action: onRefresh) {
                            Label("刷新示例", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Color(nsColor: .secondaryLabelColor))
                    }
                    .padding(.vertical, 12)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
        }
        .frame(width: QuotaWindowLayout.detailsContentSize.width)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct DetailQuotaSection: View {
    let title: String
    let value: String
    let progress: Int?
    let resetDate: Date
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            if let amount = QuotaValueFormatter.progress(progress) {
                ProgressView(value: amount)
                    .progressViewStyle(.linear)
                    .tint(Color(nsColor: .labelColor).opacity(0.72))
            } else {
                Text("额度值未知或异常")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("重置于 \(QuotaDateFormat.reset(resetDate))")
                Text("约 \(QuotaDateFormat.countdown(until: resetDate, now: now)) 后")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11, design: .monospaced))
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 11)
    }
}

private enum QuotaDateFormat {
    private static let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    static func clock(_ date: Date) -> String {
        formatter("HH:mm").string(from: date)
    }

    static func full(_ date: Date) -> String {
        formatter("yyyy-MM-dd HH:mm").string(from: date)
    }

    static func snapshot(_ date: Date) -> String {
        formatter("yyyy-MM-dd HH:mm").string(from: date)
    }

    static func reset(_ date: Date) -> String {
        formatter("yyyy-MM-dd HH:mm").string(from: date)
    }

    static func countdown(until date: Date, now: Date) -> String {
        let totalSeconds = max(0, Int(date.timeIntervalSince(now)))
        let days = totalSeconds / 86_400
        let hours = (totalSeconds % 86_400) / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        if days > 0 { return "\(days)天 \(hours)小时 \(minutes)分" }
        if hours > 0 { return "\(hours)小时 \(minutes)分" }
        return "\(minutes)分"
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}

@MainActor
private final class DemoRuntimeLog {
    private let handle: FileHandle
    private let formatter: ISO8601DateFormatter

    init(directory: URL) throws {
        let logURL = directory.appendingPathComponent("quota-window.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: Data(), attributes: [.posixPermissions: NSNumber(value: 0o600)])
        }
        handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        formatter = ISO8601DateFormatter()
    }

    func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }

    func close() {
        try? handle.close()
    }
}

@MainActor
private final class QuotaWindowAppDelegate: NSObject, NSApplicationDelegate {
    private let model = QuotaWindowModel()
    private let terminationSignal = OverlayTerminationSignal()
    private var windowController: QuotaWindowController?
    private var runtimeLog: DemoRuntimeLog?
    private var pidFile: URL?
    private var terminationReason = "normal"
    private var pidWasWritten = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let directory = try OverlayRuntimePaths.runtimeDirectory()
            runtimeLog = try DemoRuntimeLog(directory: directory)
            pidFile = directory.appendingPathComponent("quota-window.pid")
            try OverlayRuntimePaths.writePID(ProcessInfo.processInfo.processIdentifier, to: pidFile!)
            pidWasWritten = true
            runtimeLog?.write("launch pid=\(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundleIdentifier ?? "unknown")")
            guard terminationSignal.install(onTermination: { [weak self] in
                guard let self else { return }
                self.terminationReason = "SIGTERM"
                self.runtimeLog?.write("stop process=\(ProcessInfo.processInfo.processIdentifier) reason=SIGTERM")
                NSApp.terminate(nil)
            }) else {
                throw DemoStartupError.signalHandlerUnavailable
            }
            configureMenu()
            windowController = QuotaWindowController(model: model, log: runtimeLog!)
            windowController?.showSummaryWindow()
        } catch {
            fputs("QuotaWindowDemo startup failed: \(error)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopClock()
        windowController?.prepareForTermination()
        _ = terminationSignal.restorePreviousSignalDisposition()
        runtimeLog?.write("exit reason=\(terminationReason) pid=\(ProcessInfo.processInfo.processIdentifier)")
        if pidWasWritten, let pidFile {
            do {
                _ = try OverlayRuntimePaths.removePID(ProcessInfo.processInfo.processIdentifier, at: pidFile)
            } catch {
                runtimeLog?.write("pid-cleanup-failed reason=\(String(describing: error))")
            }
        }
        runtimeLog?.close()
    }

    @objc private func showQuotaWindow(_ sender: Any?) {
        windowController?.showSummaryWindow()
    }

    @objc private func quitQuotaWindow(_ sender: Any?) {
        terminationReason = "menu"
        NSApp.terminate(nil)
    }

    private func configureMenu() {
        let mainMenu = NSMenu()
        let applicationMenuItem = NSMenuItem()
        mainMenu.addItem(applicationMenuItem)
        let applicationMenu = NSMenu(title: "额度示例窗")
        let showItem = NSMenuItem(title: "显示额度窗", action: #selector(showQuotaWindow(_:)), keyEquivalent: "")
        showItem.target = self
        applicationMenu.addItem(showItem)
        applicationMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出额度窗", action: #selector(quitQuotaWindow(_:)), keyEquivalent: "q")
        quitItem.target = self
        applicationMenu.addItem(quitItem)
        applicationMenuItem.title = "额度示例窗"
        applicationMenuItem.submenu = applicationMenu
        NSApp.mainMenu = mainMenu
    }
}

private enum DemoStartupError: Error {
    case signalHandlerUnavailable
}

@main
@MainActor
private struct QuotaWindowDemoMain {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = QuotaWindowAppDelegate()
        application.delegate = delegate
        application.run()
    }
}
