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
        done(.success(["rateLimitsByLimitId": ["codex": [
            "limitId": "codex",
            "primary": window(300, plan.fiveHourResetOffset),
            "secondary": window(10080, plan.weekResetOffset)
        ]]]))
    }

    func stop() {}
    func stopAndWait() {}
}

private struct GlyphTask108ButtonCapture {
    let state: QuotaSidebarGlyphState
    let paths: [String: String]
    let images: [String: Data]
}

@MainActor
private final class GlyphTask108CheckRecorder {
    private(set) var passed: [String] = []

    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("FAIL \(name)") }
        passed.append(name)
        print("PASS \(name)")
    }
}

@MainActor
private final class GlyphTask109CheckRecorder {
    private(set) var passed: [String] = []

    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("FAIL \(name)") }
        passed.append(name)
        print("PASS \(name)")
    }
}

@main
struct QuotaSidebarGlyphCheck {
    private static var validationOutputDirectory = "docs/acceptance/anchored-quota-button/task101/validation"

    @MainActor
    private static func prepareValidationOutputDirectory() throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(validationOutputDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

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
    private static func saveGlyph(
        tier: QuotaSidebarGlyphTier, remainingPercent: Double? = nil,
        appearance: NSAppearance.Name, name: String
    ) throws -> String {
        let root = ZStack {
            Color(nsColor: .windowBackgroundColor)
            QuotaSidebarGlyph(tier: tier, remainingPercent: remainingPercent).scaleEffect(4)
                .frame(width: 112, height: 112)
        }.frame(width: 120, height: 120)
        let view = NSHostingView(rootView: root)
        view.frame = CGRect(x: 0, y: 0, width: 120, height: 120)
        view.appearance = NSAppearance(named: appearance)
        pump()
        let data = pngData(for: view)
        let relativePath = "\(validationOutputDirectory)/\(name).png"
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(relativePath)
        try data.write(to: url)
        return relativePath
    }

    @MainActor
    private static func saveButton<V: View>(view: NSHostingView<V>, name: String) throws -> (String, Data) {
        let data = pngData(for: view)
        let relativePath = "\(validationOutputDirectory)/\(name).png"
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(relativePath)
        try data.write(to: url)
        return (relativePath, data)
    }

    @MainActor
    private static func captureButtonState<V: View>(
        view: NSHostingView<V>, model: QuotaWindowModel, transport: GlyphCheckTransport,
        expectedTier: QuotaSidebarGlyphTier, expectedLastRecord: Bool, name: String,
        labelContains: [String] = []
    ) throws -> (path: String, image: Data, state: QuotaSidebarGlyphState) {
        let state = QuotaSidebarGlyphState.current(for: model)
        check(state.tier == expectedTier, "\(name)-tier-\(state.tier)")
        check(state.isLastRecord == expectedLastRecord, "\(name)-last-record-\(state.isLastRecord)")
        for phrase in labelContains {
            check(state.accessibilityLabel.contains(phrase), "\(name)-help-contains-\(phrase)")
        }
        let readsBeforeRender = transport.limitsCount
        let (path, image) = try saveButton(view: view, name: name)
        check(transport.limitsCount == readsBeforeRender, "\(name)-render-adds-no-quota-read")
        return (path, image, state)
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
    private static func captureTask108Button<V: View>(
        view: NSHostingView<V>, model: QuotaWindowModel, transport: GlyphCheckTransport,
        recorder: GlyphTask108CheckRecorder, name: String, expectedTier: QuotaSidebarGlyphTier,
        expectedRemainingPercent: Double?, expectedLastRecord: Bool = false,
        labelContains: [String] = []
    ) throws -> GlyphTask108ButtonCapture {
        let state = QuotaSidebarGlyphState.current(for: model)
        recorder.check(state.tier == expectedTier, "\(name)-tier-\(state.tier)")
        recorder.check(state.isLastRecord == expectedLastRecord, "\(name)-last-record-\(state.isLastRecord)")
        if let expectedRemainingPercent {
            recorder.check(state.remainingPercent.map { abs($0 - expectedRemainingPercent) < 0.000_001 } == true,
                           "\(name)-raw-remaining-\(state.remainingPercent ?? -1)")
        } else {
            recorder.check(state.remainingPercent == nil, "\(name)-no-fabricated-percent")
        }
        for phrase in labelContains {
            recorder.check(state.accessibilityLabel.contains(phrase), "\(name)-help-contains-\(phrase)")
        }

        var paths: [String: String] = [:]
        var images: [String: Data] = [:]
        let readsBeforeRender = transport.limitsCount
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            view.appearance = NSAppearance(named: appearance)
            pump()
            let (path, image) = try saveButton(view: view, name: "button-\(name)-\(theme)")
            paths[theme] = path
            images[theme] = image
            recorder.check(transport.limitsCount == readsBeforeRender,
                           "\(name)-\(theme)-render-adds-no-quota-read")
        }
        return GlyphTask108ButtonCapture(state: state, paths: paths, images: images)
    }

    @MainActor
    private static func runTask108() throws {
        let recorder = GlyphTask108CheckRecorder()
        try prepareValidationOutputDirectory()
        _ = NSApplication.shared

        let canvas = CGRect(x: 0, y: 0, width: 24, height: 24)
        let trackBounds = QuotaSidebarGlyphGeometry.arc(in: canvas).boundingRect
        recorder.check(abs(trackBounds.minX - 3) < 0.001 && abs(trackBounds.minY - 3) < 0.001 &&
                       abs(trackBounds.width - 18) < 0.001 && abs(trackBounds.height - 18) < 0.001,
                       "full-ring-track-keeps-18-unit-normalized-diameter")
        recorder.check(QuotaSidebarGlyphGeometry.progressArc(in: canvas, remainingPercent: 0).isEmpty,
                       "zero-has-track-without-active-arc")
        recorder.check(QuotaSidebarGlyphGeometry.progressArc(in: canvas, remainingPercent: nil).isEmpty,
                       "unknown-has-no-active-arc")

        for (percent, endpoint, name) in [
            (25.0, CGPoint(x: 21, y: 12), "quarter-clockwise-to-right"),
            (50.0, CGPoint(x: 12, y: 21), "half-clockwise-to-bottom"),
            (75.0, CGPoint(x: 3, y: 12), "three-quarter-clockwise-to-left")
        ] {
            let path = QuotaSidebarGlyphGeometry.progressArc(in: canvas, remainingPercent: percent)
            let end = path.currentPoint
            recorder.check(end.map { abs($0.x - endpoint.x) < 0.001 && abs($0.y - endpoint.y) < 0.001 } == true,
                           "\(name)-endpoint-\(end.map(String.init(describing:)) ?? "nil")")
        }
        let fractionalPercent = 33.333
        let fractionalEnd = QuotaSidebarGlyphGeometry.progressArc(
            in: canvas, remainingPercent: fractionalPercent
        ).currentPoint
        let fractionalAngle = -Double.pi / 2 + fractionalPercent / 100 * 2 * Double.pi
        let expectedFractionalEnd = CGPoint(
            x: 12 + 9 * cos(fractionalAngle), y: 12 + 9 * sin(fractionalAngle)
        )
        recorder.check(fractionalEnd.map {
            abs($0.x - expectedFractionalEnd.x) < 0.001 && abs($0.y - expectedFractionalEnd.y) < 0.001
        } == true, "fractional-raw-percent-keeps-continuous-arc-length")
        let fullProgressBounds = QuotaSidebarGlyphGeometry.progressArc(
            in: canvas, remainingPercent: 100
        ).boundingRect
        recorder.check(abs(fullProgressBounds.minX - trackBounds.minX) < 0.001 &&
                       abs(fullProgressBounds.minY - trackBounds.minY) < 0.001 &&
                       abs(fullProgressBounds.width - trackBounds.width) < 0.001 &&
                       abs(fullProgressBounds.height - trackBounds.height) < 0.001,
                       "100-percent-uses-closed-circle-matching-track")

        for fieldNameAndValue: (String, QuotaField<Double>) in [
            ("unknown", .unknown), ("invalid", .invalid), ("unsupported", .unsupported),
            ("nan", .value(.nan)), ("positive-infinity", .value(.infinity)),
            ("negative-infinity", .value(-.infinity)), ("negative", .value(-0.001)),
            ("over-100", .value(100.001))
        ] {
            let (name, field) = fieldNameAndValue
            let remaining = QuotaSidebarGlyphTier.validRemainingPercent(from: field)
            recorder.check(remaining == nil &&
                           QuotaSidebarGlyphGeometry.progressArc(in: canvas, remainingPercent: remaining).isEmpty,
                           "\(name)-has-neutral-track-only")
        }
        recorder.check(
            QuotaSidebarGlyphTier.full.dimmedLineIndices.isEmpty &&
            QuotaSidebarGlyphTier.underSeventy.dimmedLineIndices == [2] &&
            QuotaSidebarGlyphTier.underTwenty.dimmedLineIndices == [1, 2] &&
            QuotaSidebarGlyphTier.empty.dimmedLineIndices == [0, 1, 2] &&
            QuotaSidebarGlyphTier.unknown.dimmedLineIndices.isEmpty,
            "inner-three-line-tier-rules-unchanged"
        )

        let base = Date(timeIntervalSince1970: 2_000_000_000)
        var currentTime = base
        let plans = [
            GlyphReadPlan.remaining(0),
            .remaining(25), .remaining(50), .remaining(75), .remaining(100),
            .remaining(fractionalPercent), .remaining(80), .remaining(75),
            .unknown(), .invalid(),
            .remaining(23, fiveHourResetOffset: 0, weekResetOffset: 86_400),
            .failure(), .remaining(41)
        ]
        let transport = GlyphCheckTransport(plans: plans, now: { currentTime })
        let scheduler = GlyphCheckScheduler()
        let model = QuotaWindowModel(provider: transport, now: { currentTime },
            refreshPolicy: .backgroundEvery60Seconds, scheduler: scheduler)
        let buttonRoot = ZStack {
            Color(nsColor: .windowBackgroundColor)
            QuotaAnchorButtonView(model: model, action: {}).scaleEffect(2)
        }.frame(width: 88, height: 88)
        let button = NSHostingView(rootView: buttonRoot)
        button.frame = CGRect(x: 0, y: 0, width: 88, height: 88)

        let beforeRead = QuotaSidebarGlyphState.current(for: model)
        recorder.check(beforeRead.tier == .unknown && beforeRead.remainingPercent == nil &&
                       !beforeRead.accessibilityLabel.contains("%"),
                       "no-snapshot-is-unknown-not-fabricated-zero")
        button.appearance = NSAppearance(named: .aqua)
        let (noSnapshotPath, noSnapshotImage) = try saveButton(view: button, name: "button-no-snapshot-light")
        recorder.check(transport.limitsCount == 0 && scheduler.startCount == 0,
                       "no-read-before-background-refresh-start")

        model.startBackgroundRefresh()
        pump()
        recorder.check(model.mode == .summary && transport.startCount == 1 &&
                       transport.accountCount == 1 && transport.limitsCount == 1 && scheduler.startCount == 1,
                       "one-existing-background-start-and-initial-read")

        let displayCases: [(String, Double?, QuotaSidebarGlyphTier)] = [
            ("zero", 0, .empty), ("quarter", 25, .underSeventy),
            ("half", 50, .underSeventy), ("three-quarter", 75, .full),
            ("full", 100, .full), ("fractional", fractionalPercent, .underSeventy),
            ("eighty", 80, .full), ("seventy-five", 75, .full),
            ("unknown", nil, .unknown), ("invalid", nil, .unknown)
        ]
        var screenshotPaths: [String: [String: String]] = [:]
        var capturedImages: [String: [String: Data]] = [:]
        var capturedStates: [String: [String: Any]] = [:]

        for (index, displayCase) in displayCases.enumerated() {
            let (name, expectedRemaining, expectedTier) = displayCase
            if index > 0 {
                currentTime = currentTime.addingTimeInterval(60)
                scheduler.fire()
                pump()
            }
            let captured = try captureTask108Button(
                view: button, model: model, transport: transport, recorder: recorder,
                name: name, expectedTier: expectedTier, expectedRemainingPercent: expectedRemaining,
                labelContains: expectedRemaining == nil ? ["未知"] : []
            )
            screenshotPaths[name] = captured.paths
            capturedImages[name] = captured.images
            capturedStates[name] = [
                "tier": String(describing: captured.state.tier),
                "remainingPercent": captured.state.remainingPercent as Any? ?? NSNull(),
                "isLastRecord": captured.state.isLastRecord,
                "accessibilityLabel": captured.state.accessibilityLabel,
                "limitsReads": transport.limitsCount
            ]
        }
        recorder.check(capturedStates["eighty"]?["tier"] as? String ==
                       capturedStates["seventy-five"]?["tier"] as? String,
                       "80-to-75-percent-retains-same-tier")
        recorder.check(capturedImages["eighty"]?["light"] != capturedImages["seventy-five"]?["light"] &&
                       capturedImages["eighty"]?["dark"] != capturedImages["seventy-five"]?["dark"],
                       "80-to-75-same-tier-changes-progress-bitmap-in-both-appearances")
        recorder.check(capturedImages["unknown"]?["light"] == capturedImages["invalid"]?["light"] &&
                       capturedImages["unknown"]?["dark"] == capturedImages["invalid"]?["dark"],
                       "unknown-and-invalid-have-identical-neutral-progress")
        recorder.check(capturedImages["unknown"]?["light"] == noSnapshotImage,
                       "initial-no-snapshot-and-unknown-share-neutral-button-image")

        currentTime = currentTime.addingTimeInterval(60)
        scheduler.fire()
        pump()
        let due = try captureTask108Button(
            view: button, model: model, transport: transport, recorder: recorder,
            name: "last-record-23-reset-due", expectedTier: .underSeventy,
            expectedRemainingPercent: 23, expectedLastRecord: true,
            labelContains: ["上次记录", "待更新", "23%"]
        )
        screenshotPaths["last-record-23-reset-due"] = due.paths
        capturedImages["last-record-23-reset-due"] = due.images
        capturedStates["last-record-23-reset-due"] = [
            "tier": String(describing: due.state.tier),
            "remainingPercent": due.state.remainingPercent as Any? ?? NSNull(),
            "isLastRecord": due.state.isLastRecord,
            "accessibilityLabel": due.state.accessibilityLabel,
            "limitsReads": transport.limitsCount
        ]

        currentTime = currentTime.addingTimeInterval(60)
        scheduler.fire()
        pump()
        recorder.check(model.snapshot?.observedAt == currentTime.addingTimeInterval(-60),
                       "failed-refresh-retains-current-snapshot")
        let afterFailure = try captureTask108Button(
            view: button, model: model, transport: transport, recorder: recorder,
            name: "last-record-23-after-failure", expectedTier: .underSeventy,
            expectedRemainingPercent: 23, expectedLastRecord: true,
            labelContains: ["上次记录", "待更新", "23%"]
        )
        screenshotPaths["last-record-23-after-failure"] = afterFailure.paths
        capturedImages["last-record-23-after-failure"] = afterFailure.images
        capturedStates["last-record-23-after-failure"] = [
            "tier": String(describing: afterFailure.state.tier),
            "remainingPercent": afterFailure.state.remainingPercent as Any? ?? NSNull(),
            "isLastRecord": afterFailure.state.isLastRecord,
            "accessibilityLabel": afterFailure.state.accessibilityLabel,
            "limitsReads": transport.limitsCount
        ]
        recorder.check(due.images["light"] == afterFailure.images["light"] &&
                       due.images["dark"] == afterFailure.images["dark"],
                       "refresh-failure-keeps-last-valid-percentage-appearance")

        let readsBeforeClear = transport.limitsCount
        model.select("codex")
        recorder.check(model.snapshot == nil, "clearing-current-snapshot-removes-previous-percentage")
        let clearedState = QuotaSidebarGlyphState.current(for: model)
        recorder.check(clearedState.tier == .unknown && clearedState.remainingPercent == nil &&
                       !clearedState.isLastRecord && clearedState.accessibilityLabel.contains("未知"),
                       "cleared-snapshot-is-neutral-without-last-record-copy")
        let readsAfterSelection = transport.limitsCount
        button.appearance = NSAppearance(named: .aqua)
        let (clearedLightPath, clearedLightImage) = try saveButton(view: button, name: "button-cleared-light")
        screenshotPaths["cleared"] = ["light": clearedLightPath]
        capturedImages["cleared"] = ["light": clearedLightImage]
        capturedStates["cleared"] = [
            "tier": String(describing: clearedState.tier), "remainingPercent": NSNull(),
            "isLastRecord": clearedState.isLastRecord,
            "accessibilityLabel": clearedState.accessibilityLabel,
            "limitsReads": readsAfterSelection
        ]
        recorder.check(transport.limitsCount == readsAfterSelection,
                       "render-after-snapshot-clear-adds-no-quota-read")
        recorder.check(readsAfterSelection == readsBeforeClear + 1,
                       "snapshot-clear-uses-no-extra-request-beyond-existing-selection-refresh")
        recorder.check(clearedLightImage == capturedImages["unknown"]?["light"],
                       "cleared-snapshot-image-matches-neutral-unknown")

        let renderAddedNoReads = transport.startCount == 1 && transport.accountCount == 1 &&
            scheduler.startCount == 1 && transport.limitsCount == displayCases.count + 3
        recorder.check(renderAddedNoReads, "all-renders-use-existing-model-scheduler-and-requests")
        model.shutdown()

        let result: [String: Any] = [
            "status": "PASS",
            "assertions": recorder.passed.count,
            "checks": recorder.passed,
            "screenshots": screenshotPaths,
            "states": capturedStates,
            "noSnapshotImage": noSnapshotPath,
            "modelSubscription": ["detailsMode": "summary", "providerStarts": transport.startCount,
                                  "accountReads": transport.accountCount, "limitsReads": transport.limitsCount,
                                  "schedulerStarts": scheduler.startCount, "renderAddedRequests": false],
            "coverage": ["remainingPercentages": [0, 25, 50, 75, 100, fractionalPercent],
                         "sameTierTransition": "80 to 75 percent on same QuotaAnchorButtonView and model",
                         "unavailable": ["no snapshot", "unknown", "invalid", "unsupported", "NaN", "infinities", "out-of-range"],
                         "lastKnown": ["five-hour reset due", "refresh failure retains value", "snapshot clear removes value"],
                         "appearance": ["light", "dark"], "extraReadsDuringRender": false],
            "scope": "Production QuotaAnchorButtonView and QuotaSidebarGlyph in windowless NSHostingView; in-memory QuotaTransport only; no host locator, formal app window, real CLI, or Codex UI."
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        let resultURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("\(validationOutputDirectory)/glyph-check-result.json")
        try data.write(to: resultURL)
        print("PASS \(recorder.passed.count) task108 glyph progress checks")
    }

    @MainActor
    private static func runTask109() throws {
        let recorder = GlyphTask109CheckRecorder()
        try prepareValidationOutputDirectory()
        _ = NSApplication.shared

        let formattingCases: [(String, Double?, String)] = [
            ("zero", 0, "0"), ("seven", 7, "7"), ("seventy-five", 75, "75"),
            ("hundred", 100, "100"), ("sub-one", 0.25, "<1"),
            ("over-ninety-nine", 99.75, ">99"), ("details-rounding", 75.4, "75")
        ]
        var formattedValues: [String: String] = [:]
        for (name, value, expected) in formattingCases {
            let actual = QuotaSidebarGlyphValueFormatter.number(remainingPercent: value)
            recorder.check(actual == expected, "format-\(name)-\(actual)")
            formattedValues[name] = actual
        }
        for (name, value) in [
            ("unknown", Optional<Double>.none), ("nan", .some(.nan)),
            ("positive-infinity", .some(.infinity)), ("negative", .some(-0.01)),
            ("over-100", .some(100.01))
        ] {
            recorder.check(QuotaSidebarGlyphValueFormatter.number(remainingPercent: value) == "—",
                           "format-\(name)-neutral-dash")
        }
        recorder.check(
            QuotaSidebarGlyphValueFormatter.accessibilityLabel(
                tier: .full, remainingPercent: 7, isLastRecord: false
            ) == "额度；5h 剩余 7%",
            "accessibility-includes-exact-formatted-value"
        )
        recorder.check(
            QuotaSidebarGlyphValueFormatter.accessibilityLabel(
                tier: .underTwenty, remainingPercent: 7, isLastRecord: true
            ).hasSuffix("；上次记录，待更新"),
            "accessibility-preserves-last-record-status"
        )
        recorder.check(
            QuotaSidebarGlyphValueFormatter.accessibilityLabel(
                tier: .unknown, remainingPercent: nil, isLastRecord: false
            ).contains("未知"),
            "accessibility-preserves-unknown-status"
        )

        let base = Date(timeIntervalSince1970: 2_000_000_000)
        var currentTime = base
        let transport = GlyphCheckTransport(plans: [
            .remaining(75), .remaining(7), .failure(), .remaining(75)
        ], now: { currentTime })
        let scheduler = GlyphCheckScheduler()
        let model = QuotaWindowModel(provider: transport, now: { currentTime },
            refreshPolicy: .backgroundEvery60Seconds, scheduler: scheduler)
        let button = NSHostingView(rootView: QuotaAnchorButtonView(model: model, action: {})
            .frame(width: 44, height: 44))
        button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)

        let initial = QuotaSidebarGlyphState.current(for: model)
        recorder.check(initial.remainingPercent == nil &&
                       QuotaSidebarGlyphValueFormatter.number(remainingPercent: initial.remainingPercent) == "—",
                       "no-snapshot-renders-neutral-number")
        button.layoutSubtreeIfNeeded()
        recorder.check(transport.limitsCount == 0 && scheduler.startCount == 0,
                       "initial-projection-and-render-add-no-read")

        model.startBackgroundRefresh()
        pump()
        let fresh = QuotaSidebarGlyphState.current(for: model)
        recorder.check(fresh.remainingPercent == 75 &&
                       QuotaSidebarGlyphValueFormatter.number(remainingPercent: fresh.remainingPercent) == "75" &&
                       !fresh.isLastRecord && fresh.accessibilityLabel.contains("75%"),
                       "same-button-starts-with-exact-75")
        var readsAfterModelUpdate = transport.limitsCount
        button.layoutSubtreeIfNeeded()
        recorder.check(transport.limitsCount == readsAfterModelUpdate,
                       "75-render-adds-no-read")

        currentTime = currentTime.addingTimeInterval(60)
        scheduler.fire()
        pump()
        let changed = QuotaSidebarGlyphState.current(for: model)
        recorder.check(changed.remainingPercent == 7 &&
                       QuotaSidebarGlyphValueFormatter.number(remainingPercent: changed.remainingPercent) == "7" &&
                       !changed.isLastRecord && changed.accessibilityLabel.contains("7%"),
                       "same-button-updates-to-7")
        readsAfterModelUpdate = transport.limitsCount
        button.layoutSubtreeIfNeeded()
        recorder.check(transport.limitsCount == readsAfterModelUpdate,
                       "7-render-adds-no-read")

        currentTime = currentTime.addingTimeInterval(60)
        scheduler.fire()
        pump()
        let failed = QuotaSidebarGlyphState.current(for: model)
        recorder.check(model.snapshot?.observedAt == currentTime.addingTimeInterval(-60) &&
                       failed.remainingPercent == 7 &&
                       QuotaSidebarGlyphValueFormatter.number(remainingPercent: failed.remainingPercent) == "7" &&
                       failed.isLastRecord && failed.accessibilityLabel.contains("7%") &&
                       failed.accessibilityLabel.contains("上次记录，待更新"),
                       "failed-refresh-retains-value-and-accessibility-status")
        readsAfterModelUpdate = transport.limitsCount
        button.layoutSubtreeIfNeeded()
        recorder.check(transport.limitsCount == readsAfterModelUpdate,
                       "last-record-render-adds-no-read")

        let readsBeforeClear = transport.limitsCount
        model.select("codex")
        let cleared = QuotaSidebarGlyphState.current(for: model)
        recorder.check(model.snapshot == nil && cleared.remainingPercent == nil &&
                       QuotaSidebarGlyphValueFormatter.number(remainingPercent: cleared.remainingPercent) == "—" &&
                       !cleared.isLastRecord && cleared.accessibilityLabel.contains("未知"),
                       "cleared-snapshot-shows-dash-not-old-value")
        readsAfterModelUpdate = transport.limitsCount
        button.layoutSubtreeIfNeeded()
        recorder.check(transport.limitsCount == readsAfterModelUpdate &&
                       readsAfterModelUpdate == readsBeforeClear + 1,
                       "clear-render-adds-no-read-beyond-existing-selection-refresh")
        recorder.check(model.mode == .summary && transport.startCount == 1 &&
                       transport.accountCount == 1 && scheduler.startCount == 1 &&
                       transport.limitsCount == 4,
                       "short-sequence-uses-existing-model-lifecycle-only")
        model.shutdown()

        let result: [String: Any] = [
            "status": "PASS",
            "assertions": recorder.passed.count,
            "checks": recorder.passed,
            "formats": formattedValues,
            "snapshotSequence": ["75", "7", "retained 7 after failed refresh", "dash after clear"],
            "modelSubscription": ["detailsMode": "summary", "providerStarts": transport.startCount,
                                  "accountReads": transport.accountCount, "limitsReads": transport.limitsCount,
                                  "schedulerStarts": scheduler.startCount, "renderAddedRequests": false],
            "scope": "Existing production QuotaAnchorButtonView in windowless NSHostingView; in-memory QuotaTransport only; no host locator, formal app window, real CLI, or Codex UI."
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        let resultURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("\(validationOutputDirectory)/glyph-check-result.json")
        try data.write(to: resultURL)
        print("PASS \(recorder.passed.count) task109 glyph number checks")
    }

    @MainActor
    static func main() throws {
        if CommandLine.arguments.contains("--task109") {
            validationOutputDirectory = "docs/acceptance/anchored-quota-button/task109/validation"
            try runTask109()
            return
        }
        if CommandLine.arguments.contains("--task108") {
            validationOutputDirectory = "docs/acceptance/anchored-quota-button/task108/validation"
            try runTask108()
            return
        }
        try prepareValidationOutputDirectory()
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
              "full-ring-geometry")
        for (index, x, top) in [(0, 8.0, 13.5), (1, 12.0, 10.5), (2, 16.0, 7.5)] {
            let bounds = QuotaSidebarGlyphGeometry.line(index: index, in: canvas).boundingRect
            check(abs(bounds.minX - x) < 0.001 && abs(bounds.minY - top) < 0.001 &&
                  abs(bounds.height - (16 - top)) < 0.001,
                  "line-\(index)-geometry-unchanged")
        }
        check(QuotaSidebarGlyphGeometry.dimmedOpacity == 0.30, "dim-opacity")

        let tierCases: [(QuotaSidebarGlyphTier, Double?, String)] = [
            (.full, 100, "full"), (.underSeventy, 50, "under-70"),
            (.underTwenty, 10, "under-20"), (.empty, 0, "zero")
        ]
        var lightImages: [String: String] = [:]
        var darkImages: [String: String] = [:]
        for (tier, remainingPercent, name) in tierCases {
            lightImages[name] = try saveGlyph(tier: tier, remainingPercent: remainingPercent,
                                              appearance: .aqua, name: "glyph-\(name)-light")
            darkImages[name] = try saveGlyph(tier: tier, remainingPercent: remainingPercent,
                                             appearance: .darkAqua, name: "glyph-\(name)-dark")
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

        var lastKnownTime = base
        let lastKnownPlans = [
            GlyphReadPlan.remaining(23, fiveHourResetOffset: 43_200, weekResetOffset: 86_400),
            .failure(),
            .failure(),
            .remaining(15, fiveHourResetOffset: 43_200, weekResetOffset: 86_400),
            .remaining(0, fiveHourResetOffset: 43_200, weekResetOffset: 86_400),
            .remaining(80, fiveHourResetOffset: 43_200, weekResetOffset: 86_400),
            .remaining(23, fiveHourResetOffset: 0, weekResetOffset: 86_400),
            .remaining(80, fiveHourResetOffset: 43_200, weekResetOffset: 86_400)
        ]
        let (lastKnownModel, lastKnownTransport, lastKnownScheduler) = loadModel(
            plans: lastKnownPlans, now: { lastKnownTime })
        let lastKnownButtonRoot = ZStack {
            Color(nsColor: .windowBackgroundColor)
            QuotaAnchorButtonView(model: lastKnownModel, action: {}).scaleEffect(3)
        }.frame(width: 144, height: 144)
        let lastKnownButton = NSHostingView(rootView: lastKnownButtonRoot)
        lastKnownButton.frame = CGRect(x: 0, y: 0, width: 144, height: 144)
        lastKnownButton.appearance = NSAppearance(named: .aqua)
        pump()
        check(lastKnownModel.mode == .summary, "last-known-details-stay-closed-at-start")
        check(lastKnownTransport.limitsCount == 1 && lastKnownTransport.accountCount == 1 &&
              lastKnownTransport.startCount == 1 && lastKnownScheduler.startCount == 1,
              "last-known-sequence-one-start-and-first-read")

        var lastKnownImages: [String: String] = [:]
        var lastKnownLabels: [String: String] = [:]
        var lastKnownReadCounts: [String: Int] = [:]
        let fresh23 = try captureButtonState(
            view: lastKnownButton, model: lastKnownModel, transport: lastKnownTransport,
            expectedTier: .underSeventy, expectedLastRecord: false, name: "last-known-23-fresh")
        check(fresh23.state.accessibilityLabel == "额度；5h 剩余 \(QuotaRealParser.percent(.value(23)))",
              "fresh-23-help-uses-exact-value-without-last-record-suffix")
        lastKnownImages["23-fresh"] = fresh23.path
        lastKnownLabels["23-fresh"] = fresh23.state.accessibilityLabel
        lastKnownReadCounts["23-fresh"] = lastKnownTransport.limitsCount

        lastKnownTime = base.addingTimeInterval(60)
        lastKnownScheduler.fire()
        pump()
        check(lastKnownModel.statusText == "上次数据 · 刷新失败", "failure-keeps-existing-detail-status")
        check(lastKnownModel.snapshot?.observedAt == base, "failure-retains-current-snapshot")
        let failed23 = try captureButtonState(
            view: lastKnownButton, model: lastKnownModel, transport: lastKnownTransport,
            expectedTier: .underSeventy, expectedLastRecord: true, name: "last-known-23-after-failure",
            labelContains: ["上次记录", "待更新", "23%"])
        lastKnownImages["23-failed"] = failed23.path
        lastKnownLabels["23-failed"] = failed23.state.accessibilityLabel
        lastKnownReadCounts["23-failed"] = lastKnownTransport.limitsCount
        check(fresh23.image == failed23.image, "failure-changes-help-not-23-percent-bars-or-arc")

        lastKnownTime = base.addingTimeInterval(121)
        lastKnownScheduler.fire()
        pump()
        check(lastKnownModel.stale, "last-known-snapshot-exceeds-120-seconds")
        check(lastKnownModel.statusText == "上次数据 · 刷新失败", "stale-detail-status-remains-refresh-failed")
        check(lastKnownModel.snapshot?.observedAt == base, "retry-failure-retains-original-snapshot")
        let stale23 = try captureButtonState(
            view: lastKnownButton, model: lastKnownModel, transport: lastKnownTransport,
            expectedTier: .underSeventy, expectedLastRecord: true, name: "last-known-23-after-120-seconds",
            labelContains: ["上次记录", "待更新", "23%"])
        lastKnownImages["23-stale"] = stale23.path
        lastKnownLabels["23-stale"] = stale23.state.accessibilityLabel
        lastKnownReadCounts["23-stale"] = lastKnownTransport.limitsCount
        check(fresh23.image == stale23.image && failed23.image == stale23.image,
              "stale-copy-changes-not-23-percent-bars-or-arc")
        check(lastKnownTransport.limitsCount == 3, "only-background-policy-added-the-retry-read")

        let recoverySteps: [(TimeInterval, QuotaSidebarGlyphTier, String)] = [
            (241, .underTwenty, "last-known-recovered-15"),
            (301, .empty, "last-known-recovered-0"),
            (361, .full, "last-known-recovered-80")
        ]
        for (offset, expectedTier, name) in recoverySteps {
            lastKnownTime = base.addingTimeInterval(offset)
            lastKnownScheduler.fire()
            pump()
            check(lastKnownModel.mode == .summary, "\(name)-details-stay-closed")
            check(lastKnownModel.statusText == "已更新", "\(name)-model-recovers")
            let captured = try captureButtonState(
                view: lastKnownButton, model: lastKnownModel, transport: lastKnownTransport,
                expectedTier: expectedTier, expectedLastRecord: false, name: name)
            lastKnownImages[name] = captured.path
            lastKnownLabels[name] = captured.state.accessibilityLabel
            lastKnownReadCounts[name] = lastKnownTransport.limitsCount
        }

        lastKnownTime = base.addingTimeInterval(421)
        lastKnownScheduler.fire()
        pump()
        guard let resetDueSnapshot = lastKnownModel.snapshot else { fatalError("missing reset-due snapshot") }
        check(lastKnownModel.expired(resetDueSnapshot.fiveHour), "five-hour-reset-is-due")
        check(lastKnownModel.statusText == "等待更新", "reset-due-detail-status-remains-unchanged")
        let resetDue23 = try captureButtonState(
            view: lastKnownButton, model: lastKnownModel, transport: lastKnownTransport,
            expectedTier: .underSeventy, expectedLastRecord: true, name: "last-known-23-reset-due",
            labelContains: ["上次记录", "待更新", "23%"])
        lastKnownImages["23-reset-due"] = resetDue23.path
        lastKnownLabels["23-reset-due"] = resetDue23.state.accessibilityLabel
        lastKnownReadCounts["23-reset-due"] = lastKnownTransport.limitsCount
        check(fresh23.image == resetDue23.image, "reset-due-copy-changes-not-23-percent-bars-or-arc")

        let readsBeforeSnapshotClear = lastKnownTransport.limitsCount
        lastKnownModel.select("codex")
        check(lastKnownModel.snapshot == nil, "source-selection-clears-snapshot-immediately")
        let cleared = try captureButtonState(
            view: lastKnownButton, model: lastKnownModel, transport: lastKnownTransport,
            expectedTier: .unknown, expectedLastRecord: false, name: "cleared-snapshot-is-neutral",
            labelContains: ["未知"])
        lastKnownImages["cleared"] = cleared.path
        lastKnownLabels["cleared"] = cleared.state.accessibilityLabel
        lastKnownReadCounts["cleared"] = lastKnownTransport.limitsCount
        check(lastKnownTransport.limitsCount == readsBeforeSnapshotClear + 1,
              "selection-causes-only-its-existing-refresh-read")
        pump()
        check(lastKnownModel.mode == .summary, "post-clear-refresh-details-stay-closed")
        let afterClearRead = try captureButtonState(
            view: lastKnownButton, model: lastKnownModel, transport: lastKnownTransport,
            expectedTier: .full, expectedLastRecord: false, name: "post-clear-read-80")
        lastKnownImages["post-clear-80"] = afterClearRead.path
        lastKnownLabels["post-clear-80"] = afterClearRead.state.accessibilityLabel
        lastKnownReadCounts["post-clear-80"] = lastKnownTransport.limitsCount
        check(lastKnownTransport.limitsCount == 8 && lastKnownTransport.accountCount == 1 &&
              lastKnownTransport.startCount == 1 && lastKnownScheduler.startCount == 1,
              "same-model-sequence-uses-only-startup-background-and-selection-reads")
        lastKnownModel.shutdown()

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
        check(QuotaSidebarGlyphTier.current(for: dueModel) == .full, "five-hour-reset-due-keeps-numeric-tier")
        check(QuotaSidebarGlyphState.current(for: dueModel).isLastRecord,
              "five-hour-reset-due-is-labeled-last-record")
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

        let result: [String: Any] = [
            "status": "PASS",
            "thresholds": observed,
            "screenshots": ["light": lightImages, "dark": darkImages,
                            "neutralLight": neutralLight, "neutralDark": neutralDark,
                            "modelNeutralBeforeFirstRead": neutralModelImage,
                            "modelTierImages": modelImages,
                            "lastKnownSnapshotSequence": lastKnownImages],
            "lastKnownSnapshot": ["labels": lastKnownLabels, "limitsReadsAfterEachRender": lastKnownReadCounts,
                                  "same23PercentBitmapFreshFailedStaleAndResetDue": true,
                                  "sameModelAndSameProductionHostingView": true,
                                  "detailsMode": "summary throughout",
                                  "backgroundStarts": lastKnownScheduler.startCount,
                                  "providerStarts": lastKnownTransport.startCount,
                                  "accountReads": lastKnownTransport.accountCount,
                                  "limitsReads": lastKnownTransport.limitsCount,
                                  "renderAddedRequests": false],
            "modelSubscription": ["detailsMode": "summary throughout background updates", "providerStart": transport.startCount,
                                  "accountReads": transport.accountCount, "limitsReads": transport.limitsCount,
                                  "schedulerStarts": scheduler.startCount, "renderAddedRequests": false],
            "unavailableCases": ["unknown field", "invalid field", "cleared snapshot", "nonfinite and out-of-range helper inputs"],
            "lastKnownCases": ["refresh failure", "snapshot older than 120 seconds", "5h reset due", "recovered 15 percent",
                               "recovered zero", "recovered 80 percent", "rendering added no quota requests"],
            "preservedCases": ["expired week with valid 5h", "fresh value with missing reset",
                               "nonfinite and out-of-range helper inputs"],
            "scope": "Production QuotaSidebarGlyph and QuotaAnchorButtonView in windowless NSHostingViews; same model and in-memory QuotaTransport for last-known sequence; no host locator, formal app window, real CLI, or Codex UI."
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
}
