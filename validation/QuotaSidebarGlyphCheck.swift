import AppKit
import SwiftUI

@MainActor
private final class GlyphCheckScheduler: QuotaTickScheduling {
    private var tick: (@MainActor () -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(_ tick: @escaping @MainActor () -> Void) {
        startCount += 1
        self.tick = tick
    }

    func stop() {
        stopCount += 1
        tick = nil
    }

    func fire() { tick?() }
}

private struct GlyphReadPlan {
    let usedPercent: Any
    let fiveHourResetOffset: TimeInterval?
    let weekResetOffset: TimeInterval?
    let fail: Bool

    static func remaining(_ value: Double, fiveHourResetOffset: TimeInterval? = 43_200,
                          weekResetOffset: TimeInterval? = -60) -> Self {
        Self(usedPercent: 100 - value, fiveHourResetOffset: fiveHourResetOffset,
             weekResetOffset: weekResetOffset, fail: false)
    }

    static func unknown(fiveHourResetOffset: TimeInterval? = 43_200,
                        weekResetOffset: TimeInterval? = -60) -> Self {
        Self(usedPercent: NSNull(), fiveHourResetOffset: fiveHourResetOffset,
             weekResetOffset: weekResetOffset, fail: false)
    }

    static func invalid(fiveHourResetOffset: TimeInterval? = 43_200,
                        weekResetOffset: TimeInterval? = -60) -> Self {
        Self(usedPercent: 101.0, fiveHourResetOffset: fiveHourResetOffset,
             weekResetOffset: weekResetOffset, fail: false)
    }

    static func failure() -> Self {
        Self(usedPercent: NSNull(), fiveHourResetOffset: nil, weekResetOffset: nil, fail: true)
    }
}

private final class GlyphCheckTransport: QuotaTransport {
    var onNotification: ((String) -> Void)?
    var onExit: (() -> Void)?
    var onEvent: ((String) -> Void)?
    private let plans: [GlyphReadPlan]
    private let now: () -> Date
    private var planIndex = 0
    private(set) var startCount = 0
    private(set) var accountCount = 0
    private(set) var limitsCount = 0

    init(plans: [GlyphReadPlan], now: @escaping () -> Date) {
        self.plans = plans
        self.now = now
    }

    func start(_ done: @escaping (Result<Void, Error>) -> Void) {
        startCount += 1
        done(.success(()))
    }

    func account(_ done: @escaping (Result<[String: Any], Error>) -> Void) {
        accountCount += 1
        done(.success(["account": ["type": "chatgptAuthTokens", "email": "glyph-check@example.invalid"]]))
    }

    func limits(_ done: @escaping (Result<[String: Any], Error>) -> Void) {
        limitsCount += 1
        let plan = plans[min(planIndex, plans.count - 1)]
        planIndex += 1
        if plan.fail {
            done(.failure(NSError(domain: "glyph-check", code: 1)))
            return
        }
        func window(_ duration: Int, _ resetOffset: TimeInterval?) -> [String: Any] {
            var value: [String: Any] = ["windowDurationMins": duration, "usedPercent": plan.usedPercent]
            if let resetOffset { value["resetsAt"] = now().timeIntervalSince1970 + resetOffset }
            return value
        }
        done(.success(["rateLimits": [
            "limitId": "codex",
            "primary": window(300, plan.fiveHourResetOffset),
            "secondary": window(10080, plan.weekResetOffset)
        ]]))
    }

    func stop() {}
    func stopAndWait() {}
}

@main
struct QuotaSidebarGlyphCheck {
    @MainActor
    private static func pump(_ seconds: TimeInterval = 0.16) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    @MainActor
    private static func pngData<V: View>(for view: NSHostingView<V>) -> Data {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            fatalError("could not allocate the no-window glyph bitmap")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("could not encode glyph bitmap")
        }
        return data
    }

    @MainActor
    private static func saveGlyph(tier: QuotaSidebarGlyphTier, appearance: NSAppearance.Name, name: String) throws -> String {
        let root = ZStack {
            Color(nsColor: .windowBackgroundColor)
            QuotaSidebarGlyph(tier: tier).scaleEffect(4)
                .frame(width: 112, height: 112)
        }.frame(width: 120, height: 120)
        let view = NSHostingView(rootView: root)
        view.frame = CGRect(x: 0, y: 0, width: 120, height: 120)
        view.appearance = NSAppearance(named: appearance)
        pump()
        let data = pngData(for: view)
        let relativePath = "docs/acceptance/anchored-quota-button/task99/validation/\(name).png"
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(relativePath)
        try data.write(to: url)
        return relativePath
    }

    @MainActor
    private static func saveButton<V: View>(view: NSHostingView<V>, name: String) throws -> (String, Data) {
        let data = pngData(for: view)
        let relativePath = "docs/acceptance/anchored-quota-button/task99/validation/\(name).png"
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(relativePath)
        try data.write(to: url)
        return (relativePath, data)
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("FAIL \(name)") }
        print("PASS \(name)")
    }

    @MainActor
    private static func loadModel(plans: [GlyphReadPlan], now: @escaping () -> Date) ->
        (QuotaWindowModel, GlyphCheckTransport, GlyphCheckScheduler) {
        let transport = GlyphCheckTransport(plans: plans, now: now)
        let scheduler = GlyphCheckScheduler()
        let model = QuotaWindowModel(provider: transport, now: now,
            refreshPolicy: .backgroundEvery60Seconds, scheduler: scheduler)
        model.startBackgroundRefresh()
        pump()
        return (model, transport, scheduler)
    }

    @MainActor
    static func main() throws {
        _ = NSApplication.shared

        let boundaries: [(Double, QuotaSidebarGlyphTier)] = [
            (100, .full), (70.001, .full), (70, .full),
            (69.999, .underSeventy), (20.001, .underSeventy), (20, .underSeventy),
            (19.999, .underTwenty), (0.001, .underTwenty), (0, .empty)
        ]
        for (value, expected) in boundaries {
            check(QuotaSidebarGlyphTier.classify(remaining: value) == expected,
                  "threshold-\(value)-\(expected)")
        }
        check(QuotaSidebarGlyphTier.classify(remaining: -0.001) == .unknown, "negative-is-unknown")
        check(QuotaSidebarGlyphTier.classify(remaining: 100.001) == .unknown, "over-100-is-unknown")
        check(QuotaSidebarGlyphTier.classify(remaining: .nan) == .unknown, "nan-is-unknown")
        check(QuotaSidebarGlyphTier.classify(remaining: .infinity) == .unknown, "infinity-is-unknown")
        check(QuotaSidebarGlyphTier.classify(remaining: nil) == .unknown, "missing-is-unknown")
        check(QuotaSidebarGlyphTier.classify(remaining: QuotaField<Double>.unknown) == .unknown, "field-unknown-is-neutral")
        check(QuotaSidebarGlyphTier.classify(remaining: QuotaField<Double>.invalid) == .unknown, "field-invalid-is-neutral")
        check(QuotaSidebarGlyphTier.classify(remaining: QuotaField<Double>.unsupported) == .unknown, "field-unsupported-is-neutral")
        check(QuotaSidebarGlyphTier.classify(remaining: 100, pending: true) == .pending, "pending-precedes-valid-percent")
        check(QuotaSidebarGlyphTier.pending.accessibilityLabel.contains("待更新"), "pending-help-is-specific")
        check(QuotaSidebarGlyphTier.unknown.accessibilityLabel.contains("未知"), "unknown-help-is-specific")
        check(QuotaSidebarGlyphTier.pending.dimmedLineIndices.isEmpty && QuotaSidebarGlyphTier.unknown.dimmedLineIndices.isEmpty,
              "unavailable-icon-is-neutral")
        check(QuotaSidebarGlyphTier.full.dimmedLineIndices.isEmpty, "full-has-no-dim-lines")
        check(QuotaSidebarGlyphTier.underSeventy.dimmedLineIndices == [2], "middle-tier-dims-right-only")
        check(QuotaSidebarGlyphTier.underTwenty.dimmedLineIndices == [1, 2], "low-tier-dims-middle-and-right")
        check(QuotaSidebarGlyphTier.empty.dimmedLineIndices == [0, 1, 2], "zero-dims-all-lines")

        let canvas = CGRect(x: 0, y: 0, width: 24, height: 24)
        let arcBounds = QuotaSidebarGlyphGeometry.arc(in: canvas).boundingRect
        check(QuotaSidebarGlyphGeometry.lineCount == 3 && QuotaSidebarGlyphGeometry.lineWidth == 1.8,
              "glyph-line-count-and-width")
        check(abs(arcBounds.minX - 3) < 0.001 && abs(arcBounds.minY - 3) < 0.001 &&
              abs(arcBounds.width - 18) < 0.001 && abs(arcBounds.height - 18) < 0.001,
              "arc-geometry-unchanged")
        for (index, x, top) in [(0, 8.0, 13.5), (1, 12.0, 10.5), (2, 16.0, 7.5)] {
            let bounds = QuotaSidebarGlyphGeometry.line(index: index, in: canvas).boundingRect
            check(abs(bounds.minX - x) < 0.001 && abs(bounds.minY - top) < 0.001 &&
                  abs(bounds.height - (16 - top)) < 0.001,
                  "line-\(index)-geometry-unchanged")
        }
        check(QuotaSidebarGlyphGeometry.dimmedOpacity == 0.30, "dim-opacity")

        let tierCases: [(QuotaSidebarGlyphTier, String)] = [
            (.full, "full"), (.underSeventy, "under-70"), (.underTwenty, "under-20"), (.empty, "zero")
        ]
        var lightImages: [String: String] = [:]
        var darkImages: [String: String] = [:]
        for (tier, name) in tierCases {
            lightImages[name] = try saveGlyph(tier: tier, appearance: .aqua, name: "glyph-\(name)-light")
            darkImages[name] = try saveGlyph(tier: tier, appearance: .darkAqua, name: "glyph-\(name)-dark")
        }
        let neutralLight = try saveGlyph(tier: .unknown, appearance: .aqua, name: "glyph-unknown-light")
        let neutralDark = try saveGlyph(tier: .pending, appearance: .darkAqua, name: "glyph-pending-dark")

        let base = Date(timeIntervalSince1970: 2_000_000_000)
        var currentTime = base
        let values: [Double] = [80, 69.999, 20, 19.999, 0.001, 0]
        let plans = values.map { GlyphReadPlan.remaining($0, weekResetOffset: -60) }
        let transport = GlyphCheckTransport(plans: plans, now: { currentTime })
        let scheduler = GlyphCheckScheduler()
        let model = QuotaWindowModel(provider: transport, now: { currentTime },
            refreshPolicy: .backgroundEvery60Seconds, scheduler: scheduler)
        let buttonRoot = ZStack {
            Color(nsColor: .windowBackgroundColor)
            QuotaAnchorButtonView(model: model, action: {}).scaleEffect(3)
        }.frame(width: 144, height: 144)
        let button = NSHostingView(rootView: buttonRoot)
        button.frame = CGRect(x: 0, y: 0, width: 144, height: 144)
        button.appearance = NSAppearance(named: .aqua)
        pump()
        check(QuotaSidebarGlyphTier.current(for: model) == .unknown, "same-button-view-starts-with-neutral-unknown")
        check(transport.limitsCount == 0 && scheduler.startCount == 0, "no-read-before-startup")
        let (neutralModelImage, _) = try saveButton(view: button, name: "model-neutral-before-first-read")
        model.startBackgroundRefresh()
        pump()
        check(model.mode == .summary, "details-remain-closed")
        check(transport.startCount == 1 && transport.accountCount == 1 && transport.limitsCount == 1 && scheduler.startCount == 1,
              "one-startup-read-and-one-existing-scheduler")

        var observed: [[String: Any]] = []
        var imagesByTier: [String: Data] = [:]
        var previousTier: QuotaSidebarGlyphTier?
        var previousImageData: Data?
        var modelImages: [String: String] = [:]
        for (index, value) in values.enumerated() {
            if index > 0 {
                currentTime = currentTime.addingTimeInterval(60)
                scheduler.fire()
                pump()
            }
            let expected = QuotaSidebarGlyphTier.classify(remaining: value)
            let actual = QuotaSidebarGlyphTier.current(for: model)
            check(actual == expected, "same-model-background-update-\(value)-\(actual)")
            guard let snapshot = model.snapshot, case .value(let actualRemaining) = snapshot.fiveHour.remaining else {
                fatalError("missing parsed value during same-model update")
            }
            check(abs(actualRemaining - value) < 0.0000001, "raw-double-preserved-\(value)")
            check(model.mode == .summary, "details-still-closed-\(index)")
            let limitsBeforeRender = transport.limitsCount
            let (path, imageData) = try saveButton(view: button, name: "model-tier-\(index)-\(value)")
            check(transport.limitsCount == limitsBeforeRender, "render-adds-no-quota-request-\(index)")
            let tierName = String(describing: actual)
            if let previous = imagesByTier[tierName] {
                check(previous == imageData, "same-tier-render-is-identical-\(tierName)-\(index)")
            } else { imagesByTier[tierName] = imageData }
            if let previousTier, previousTier != actual, let previousImageData {
                check(previousImageData != imageData, "same-hosting-view-bitmap-changes-\(previousTier)-to-\(actual)")
            }
            previousTier = actual
            previousImageData = imageData
            modelImages["\(value)"] = path
            observed.append(["remaining": actualRemaining, "tier": tierName, "limitsCount": limitsBeforeRender, "image": path])
        }
        check(transport.limitsCount == values.count && transport.accountCount == 1 && scheduler.startCount == 1,
              "background-ticks-use-existing-scheduler-and-reads")
        model.shutdown()

        let (unknownModel, unknownTransport, _) = loadModel(plans: [.unknown()], now: { base })
        check(QuotaSidebarGlyphTier.current(for: unknownModel) == .unknown, "model-unknown-field-is-neutral")
        check(unknownTransport.limitsCount == 1, "unknown-fixture-loaded-once")
        unknownModel.shutdown()

        let (invalidModel, invalidTransport, _) = loadModel(plans: [.invalid()], now: { base })
        check(QuotaSidebarGlyphTier.current(for: invalidModel) == .unknown, "model-invalid-field-is-neutral")
        check(invalidTransport.limitsCount == 1, "invalid-fixture-loaded-once")
        invalidModel.shutdown()

        let (dueModel, dueTransport, _) = loadModel(
            plans: [.remaining(70, fiveHourResetOffset: 0, weekResetOffset: 86_400)], now: { base })
        check(QuotaSidebarGlyphTier.current(for: dueModel) == .pending, "five-hour-reset-due-is-pending")
        check(dueTransport.limitsCount == 1, "five-hour-reset-due-no-extra-read")
        dueModel.shutdown()

        let (weekExpiredModel, weekTransport, _) = loadModel(
            plans: [.remaining(20, fiveHourResetOffset: 86_400, weekResetOffset: -1)], now: { base })
        check(QuotaSidebarGlyphTier.current(for: weekExpiredModel) == .underSeventy, "expired-week-does-not-hide-valid-five-hour-value")
        check(weekTransport.limitsCount == 1, "expired-week-no-extra-read")
        weekExpiredModel.shutdown()

        let (missingResetModel, _, _) = loadModel(
            plans: [.remaining(19.999, fiveHourResetOffset: nil, weekResetOffset: nil)], now: { base })
        check(QuotaSidebarGlyphTier.current(for: missingResetModel) == .underTwenty, "missing-reset-with-fresh-value-remains-usable")
        missingResetModel.shutdown()

        var failureTime = base
        let (failureModel, failureTransport, failureScheduler) = loadModel(
            plans: [.remaining(50), .failure()], now: { failureTime })
        failureTime = failureTime.addingTimeInterval(121)
        failureScheduler.fire()
        pump()
        check(QuotaSidebarGlyphTier.current(for: failureModel) == .pending, "stale-refresh-failure-becomes-pending")
        check(failureTransport.limitsCount == 2 && failureTransport.accountCount == 1 && failureScheduler.startCount == 1,
              "failure-refresh-counts-follow-existing-policy")
        let pendingFailureImage = try saveGlyph(tier: QuotaSidebarGlyphTier.current(for: failureModel),
            appearance: .aqua, name: "glyph-pending-after-failure")
        failureModel.shutdown()

        let result: [String: Any] = [
            "status": "PASS",
            "thresholds": observed,
            "screenshots": ["light": lightImages, "dark": darkImages,
                            "neutralLight": neutralLight, "neutralDark": neutralDark,
                            "modelNeutralBeforeFirstRead": neutralModelImage,
                            "modelTierImages": modelImages, "pendingAfterFailure": pendingFailureImage],
            "modelSubscription": ["detailsMode": "summary throughout background updates", "providerStart": transport.startCount,
                                  "accountReads": transport.accountCount, "limitsReads": transport.limitsCount,
                                  "schedulerStarts": scheduler.startCount, "renderAddedRequests": false],
            "unavailableCases": ["unknown field", "invalid field", "failed refresh", "stale snapshot", "5h reset due",
                                 "expired week with valid 5h", "fresh value with missing reset", "nonfinite and out-of-range helper inputs"],
            "scope": "Production QuotaSidebarGlyph and QuotaAnchorButtonView in windowless NSHostingViews; in-memory QuotaTransport only; no host locator, formal app window, real CLI, or Codex UI."
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
}
