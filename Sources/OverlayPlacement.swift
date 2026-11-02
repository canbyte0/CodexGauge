import CoreGraphics
import Foundation

enum OverlayPlacement {
    enum Visibility {
        case unknown
        case collapsed
        case expanded
    }

    enum Failure: String {
        case visibilityUnknown = "rail-state-unknown"
        case collapsed = "rail-collapsed"
        case stale = "rail-state-stale"
        case invalidGeometry = "geometry-invalid"
        case railTooNarrow = "rail-width-insufficient"
        case railOutsideHost = "rail-outside-host"
        case emptyAreaOutsideRail = "empty-area-outside-rail"
        case emptyAreaTooSmall = "empty-area-insufficient"
        case summaryOutsideSafeArea = "summary-outside-safe-area"
    }

    struct Input {
        let hostFrame: CGRect
        let railFrame: CGRect
        let reportedRailWidth: CGFloat
        let emptyArea: CGRect
        let visibility: Visibility
        let updatedAt: Date?
        let now: Date
    }

    struct Decision {
        let summaryFrame: CGRect?
        let failure: Failure?

        var isVisible: Bool { summaryFrame != nil }
    }

    static let summarySize = CGSize(width: 48, height: 162)
    static let horizontalMargin: CGFloat = 4
    static let verticalMargin: CGFloat = 8
    static let maximumStateAge: TimeInterval = 5

    static func evaluate(_ input: Input) -> Decision {
        guard input.visibility != .unknown else { return rejected(.visibilityUnknown) }
        guard input.visibility != .collapsed else { return rejected(.collapsed) }
        guard let updatedAt = input.updatedAt else { return rejected(.stale) }
        let age = input.now.timeIntervalSince(updatedAt)
        guard age >= 0, age <= maximumStateAge else { return rejected(.stale) }

        guard valid(input.hostFrame), valid(input.railFrame), valid(input.emptyArea),
              input.reportedRailWidth.isFinite, input.reportedRailWidth > 0
        else { return rejected(.invalidGeometry) }

        let requiredWidth = summarySize.width + horizontalMargin * 2
        guard input.reportedRailWidth >= requiredWidth,
              abs(input.railFrame.width - input.reportedRailWidth) <= 1
        else { return rejected(.railTooNarrow) }

        guard input.hostFrame.insetBy(dx: -1, dy: -1).contains(input.railFrame) else {
            return rejected(.railOutsideHost)
        }
        guard input.railFrame.contains(input.emptyArea) else {
            return rejected(.emptyAreaOutsideRail)
        }

        let safeArea = input.emptyArea.insetBy(dx: horizontalMargin, dy: verticalMargin)
        guard safeArea.width >= summarySize.width,
              safeArea.height >= summarySize.height
        else { return rejected(.emptyAreaTooSmall) }

        let summary = CGRect(
            x: input.emptyArea.midX - summarySize.width / 2,
            y: input.emptyArea.minY + verticalMargin,
            width: summarySize.width,
            height: summarySize.height
        )
        guard safeArea.contains(summary), input.railFrame.contains(summary) else {
            return rejected(.summaryOutsideSafeArea)
        }
        return Decision(summaryFrame: summary, failure: nil)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && !rect.isEmpty &&
            rect.minX.isFinite && rect.minY.isFinite &&
            rect.width.isFinite && rect.height.isFinite
    }

    private static func rejected(_ failure: Failure) -> Decision {
        Decision(summaryFrame: nil, failure: failure)
    }
}

enum DemoLayoutRefreshPolicy {
    static let refreshLeadTime: TimeInterval = 2
    static let requestTimeout: TimeInterval = 0.75
    static let minimumRequestInterval: TimeInterval = 1

    static func shouldRequest(
        now: Date,
        updatedAt: Date?,
        lastRequestAt: Date?,
        inFlightSince: Date?
    ) -> Bool {
        let age = updatedAt.map { now.timeIntervalSince($0) } ?? .infinity
        let refreshDue = updatedAt == nil || !age.isFinite || age < 0 || age >= refreshLeadTime
        guard refreshDue else { return false }

        if let inFlightSince,
           now.timeIntervalSince(inFlightSince) < requestTimeout {
            return false
        }
        if let lastRequestAt,
           now.timeIntervalSince(lastRequestAt) < minimumRequestInterval {
            return false
        }
        return true
    }
}
