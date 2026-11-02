import AppKit
import Combine
import SwiftUI

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
final class QuotaWindowController: NSObject, NSWindowDelegate {
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

    var isWindowVisible: Bool { window?.isVisible == true }

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
        createdWindow.title = "CLI账号额度"
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
            onRefresh: { [weak self] in self?.refreshQuota() }
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

    private func refreshQuota() {
        model.refresh()
        log.write("manual-refresh mode=\(model.mode.logName) id=\(windowIdentity ?? 0)")
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
            SummaryMetric(label: "5h", value: model.snapshot.map { model.summary($0.fiveHour.remaining, window: $0.fiveHour) } ?? "—")
            Divider().padding(.horizontal, 10)
            SummaryMetric(label: "周", value: model.snapshot.map { model.summary($0.week.remaining, window: $0.week) } ?? "—")
            Divider().padding(.horizontal, 10)
            SummaryMetric(label: "重置", value: model.resetSummary)
            Divider().padding(.horizontal, 10)
            Text(QuotaDateFormat.clock(model.clockNow))
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            Spacer(minLength: 0)
            #if QUOTA_TESTING
            Text("验收测试数据").font(.system(size: 9, weight: .semibold)).foregroundStyle(.orange)
            #endif
            HStack(alignment: .center) {
                Text(model.summaryStatusText)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.8)
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
struct DetailsView: View {
    enum DisplayMode: Equatable {
        case standard
        case anchoredCompact
    }

    @ObservedObject var model: QuotaWindowModel
    let onCollapse: () -> Void
    let onRefresh: () -> Void
    var backTitle: String = "返回摘要"
    var displayMode: DisplayMode = .standard
    var onContentHeight: ((CGFloat) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            if displayMode == .standard {
                HStack {
                    Button(action: onCollapse) { Label(backTitle, systemImage: "chevron.left") }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                    Spacer()
                }.padding(.horizontal, 16).padding(.vertical, 11)
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    #if QUOTA_TESTING
                    Text("验收测试数据").font(.system(size: 13, weight: .bold)).foregroundStyle(.orange)
                    #endif
                    Text("额度详情").font(.system(size: 20, weight: .semibold))
                    if displayMode == .standard {
                        Text("CLI账号额度 · 工作区未提供")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 3)
                    }
                    Text(model.statusText)
                        .font(.system(size: displayMode == .anchoredCompact ? 13 : 12))
                        .padding(.top, 4)
                    if model.choices.count > 1 {
                        Picker("额度来源", selection: Binding(get: { model.selection ?? model.snapshot?.bucketID ?? "" }, set: { model.select($0) })) {
                            Text("请选择").tag("")
                            ForEach(model.choices, id: \.self) { Text($0).tag($0) }
                        }.padding(.vertical, 8).disabled(model.loading)
                    }
                    if let snapshot = model.snapshot {
                        if displayMode == .standard {
                            Text("额度桶：\(snapshot.bucketName)").lineLimit(2).truncationMode(.tail)
                                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 4)
                        }
                        DetailQuotaSection(title: "5h 剩余", value: snapshot.fiveHour, now: model.clockNow, stale: model.expired(snapshot.fiveHour), compactTypography: displayMode == .anchoredCompact)
                        Divider()
                        DetailQuotaSection(title: "周剩余", value: snapshot.week, now: model.clockNow, stale: model.expired(snapshot.week), compactTypography: displayMode == .anchoredCompact)
                        Divider()
                        HStack {
                            Text(model.stale ? "上次记录 · 限额重置" : "限额重置")
                            Spacer()
                            Text(QuotaRealParser.count(snapshot.resets)).monospacedDigit()
                        }.font(.system(size: displayMode == .anchoredCompact ? 14 : 13)).padding(.vertical, 12)
                        if displayMode == .anchoredCompact {
                            resetCreditRows(snapshot)
                        }
                    } else {
                        Text("暂无额度记录").foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                    Divider()
                    if displayMode == .standard {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("当前时间").font(.system(size: 13, weight: .medium))
                            Text(QuotaDateFormat.full(model.clockNow)).font(.system(size: 14, design: .monospaced))
                            Text("Asia/Shanghai").font(.system(size: 11)).foregroundStyle(.secondary)
                        }.padding(.vertical, 12)
                        Divider()
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("最后成功更新")
                                .font(.system(size: displayMode == .anchoredCompact ? 13 : 12, weight: .medium))
                            Text(model.snapshot.map { QuotaDateFormat.snapshot($0.observedAt) } ?? "—")
                                .font(.system(size: displayMode == .anchoredCompact ? 13 : 12, design: .monospaced))
                        }
                        Spacer()
                        if displayMode == .anchoredCompact {
                            Button(action: onRefresh) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.primary.opacity(0.08))
                                        .frame(width: 36, height: 32)
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 16, weight: .medium))
                                }
                                .frame(width: 40, height: 36)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(model.loading ? "刷新中" : "刷新额度")
                            .accessibilityLabel(model.loading ? "刷新中" : "刷新额度")
                            .disabled(model.loading)
                        } else {
                            Button(action: onRefresh) { Label(model.loading ? "刷新中" : "刷新额度", systemImage: "arrow.clockwise") }
                                .buttonStyle(.bordered).controlSize(.small).disabled(model.loading)
                        }
                    }.padding(.vertical, 12)
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 16)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: QuotaDetailsContentHeightPreferenceKey.self, value: geometry.size.height)
                    }
                }
            }
        }.frame(width: QuotaWindowLayout.detailsContentSize.width)
            .background(Color(nsColor: .windowBackgroundColor))
            .onPreferenceChange(QuotaDetailsContentHeightPreferenceKey.self) { height in
                guard displayMode == .anchoredCompact, height.isFinite, height > 0 else { return }
                onContentHeight?(height)
            }
    }

    @ViewBuilder
    private func resetCreditRows(_ snapshot: QuotaSnapshot) -> some View {
        let lines = QuotaResetCreditPresentation.lines(snapshot: snapshot, now: model.clockNow, stale: model.stale)
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(lines.enumerated()), id: \.offset) { entry in
                    switch entry.element {
                    case .credit(let ordinal, let expiry, let expired, let stale):
                        HStack(alignment: .firstTextBaseline) {
                            Text("第\(ordinal)次").fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 8)
                            Text(resetCreditCountdownText(expiry, now: model.clockNow))
                                .monospacedDigit()
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 8)
                            Text(resetCreditExpiryText(expiry, expired: expired, stale: stale))
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                                .layoutPriority(1)
                        }
                    case .note(let text, let stale):
                        Text(stale ? "上次记录 · \(text)" : text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.top, 1)
            .padding(.bottom, 8)
        }
    }

    private func resetCreditExpiryText(_ expiry: QuotaResetCreditExpiry, expired: Bool, stale: Bool) -> String {
        let prefix = stale ? "上次记录 · " : ""
        switch expiry {
        case .date(let date):
            return prefix + QuotaDateFormat.reset(date) + (expired ? " 已到期，等待更新" : " 到期")
        case .never:
            return prefix + "不过期"
        case .unknown:
            return prefix + "到期时间未知"
        }
    }

    private func resetCreditCountdownText(_ expiry: QuotaResetCreditExpiry, now: Date) -> String {
        switch expiry {
        case .date(let date):
            guard date > now else { return "已到期" }
            return QuotaCountdownFormatter.string(until: date, now: now)
        case .never, .unknown:
            return "—"
        }
    }
}

private struct QuotaDetailsContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct DetailQuotaSection: View {
    let title: String
    let value: QuotaWindowValue
    let now: Date
    let stale: Bool
    var compactTypography = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(stale ? "上次记录 · " + title : title)
                    .font(.system(size: compactTypography ? 14 : 13, weight: .medium))
                Spacer()
                Text(QuotaRealParser.percent(value.remaining)).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            if case .value(let amount) = value.remaining, !stale {
                ProgressView(value: amount / 100).progressViewStyle(.linear)
            }
            if let reset = value.reset {
                if compactTypography {
                    HStack(alignment: .firstTextBaseline) {
                        Text("重置于 \(QuotaDateFormat.reset(reset))")
                        Spacer(minLength: 8)
                        Text(reset <= now ? "等待更新" : QuotaCountdownFormatter.string(until: reset, now: now))
                            .monospacedDigit()
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                } else {
                    Text(reset <= now ? "等待更新" : "重置于 \(QuotaDateFormat.reset(reset))")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            } else {
                if compactTypography {
                    HStack(alignment: .firstTextBaseline) {
                        Text("重置时间未知")
                        Spacer(minLength: 8)
                        Text("—").monospacedDigit().fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                } else {
                    Text("重置时间未知").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 11)
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

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}

@MainActor
final class DemoRuntimeLog {
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
    private var observers: [NSObjectProtocol] = []

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
            let workspace = NSWorkspace.shared.notificationCenter
            observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.sleep() } })
            observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.model.wake() } })
            model.onEvent = { [weak self] message in self?.runtimeLog?.write(message) }
            configureMenu()
            windowController = QuotaWindowController(model: model, log: runtimeLog!)
            windowController?.showSummaryWindow()
        } catch {
            fputs("QuotaWindow startup failed: \(error)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    func applicationDidHide(_ notification: Notification) { model.stopClock() }
    func applicationDidUnhide(_ notification: Notification) { if windowController?.isWindowVisible == true { model.startClock() } }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        model.shutdown()
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
        let applicationMenu = NSMenu(title: "额度窗")
        let showItem = NSMenuItem(title: "显示额度窗", action: #selector(showQuotaWindow(_:)), keyEquivalent: "")
        showItem.target = self
        applicationMenu.addItem(showItem)
        applicationMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出额度窗", action: #selector(quitQuotaWindow(_:)), keyEquivalent: "q")
        quitItem.target = self
        applicationMenu.addItem(quitItem)
        applicationMenuItem.title = "额度窗"
        applicationMenuItem.submenu = applicationMenu
        NSApp.mainMenu = mainMenu
    }
}

private enum DemoStartupError: Error {
    case signalHandlerUnavailable
}

#if !QUOTA_TESTING && !QUOTA_ANCHORED_BUTTON
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

#endif
