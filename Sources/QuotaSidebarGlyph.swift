import AppKit
import SwiftUI

enum QuotaSidebarGlyphTier: Equatable {
    case full
    case underSeventy
    case underTwenty
    case empty
    case pending
    case unknown

    var dimmedLineIndices: Set<Int> {
        switch self {
        case .full, .pending, .unknown: []
        case .underSeventy: [2]
        case .underTwenty: [1, 2]
        case .empty: [0, 1, 2]
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .full: "额度；5h 剩余至少 70%"
        case .underSeventy: "额度；5h 剩余 20% 至 70%"
        case .underTwenty: "额度；5h 剩余低于 20%"
        case .empty: "额度；5h 已无剩余额度"
        case .pending: "额度；5h 额度待更新"
        case .unknown: "额度；5h 额度未知"
        }
    }

    static func classify(remaining: Double?, pending: Bool = false) -> Self {
        if pending { return .pending }
        guard let remaining, remaining.isFinite, (0...100).contains(remaining) else { return .unknown }
        if remaining >= 70 { return .full }
        if remaining >= 20 { return .underSeventy }
        if remaining > 0 { return .underTwenty }
        return .empty
    }

    static func classify(remaining field: QuotaField<Double>, pending: Bool = false) -> Self {
        if pending { return .pending }
        return classify(remaining: validRemainingPercent(from: field))
    }

    static func validRemainingPercent(from field: QuotaField<Double>) -> Double? {
        guard case .value(let remaining) = field,
              remaining.isFinite, (0...100).contains(remaining) else { return nil }
        return remaining
    }

    @MainActor
    static func current(for model: QuotaWindowModel) -> Self {
        QuotaSidebarGlyphState.current(for: model).tier
    }
}

struct QuotaSidebarGlyphState: Equatable {
    let tier: QuotaSidebarGlyphTier
    let remainingPercent: Double?
    let isLastRecord: Bool

    var accessibilityLabel: String {
        QuotaSidebarGlyphValueFormatter.accessibilityLabel(
            tier: tier, remainingPercent: remainingPercent, isLastRecord: isLastRecord
        )
    }

    @MainActor
    static func current(for model: QuotaWindowModel) -> Self {
        guard let snapshot = model.snapshot else {
            return Self(tier: .unknown, remainingPercent: nil, isLastRecord: false)
        }

        let remainingPercent = QuotaSidebarGlyphTier.validRemainingPercent(from: snapshot.fiveHour.remaining)
        let tier = QuotaSidebarGlyphTier.classify(remaining: remainingPercent)
        let isLastRecord = remainingPercent != nil && model.expired(snapshot.fiveHour)
        return Self(tier: tier, remainingPercent: remainingPercent, isLastRecord: isLastRecord)
    }
}

enum QuotaSidebarGlyphValueFormatter {
    static func number(remainingPercent: Double?) -> String {
        guard let remainingPercent, remainingPercent.isFinite,
              (0...100).contains(remainingPercent) else { return "—" }
        return String(QuotaRealParser.percent(.value(remainingPercent)).dropLast())
    }

    static func accessibilityLabel(
        tier: QuotaSidebarGlyphTier, remainingPercent: Double?, isLastRecord: Bool
    ) -> String {
        let baseLabel: String
        if let remainingPercent, remainingPercent.isFinite, (0...100).contains(remainingPercent) {
            baseLabel = "额度；5h 剩余 \(QuotaRealParser.percent(.value(remainingPercent)))"
        } else {
            baseLabel = tier.accessibilityLabel
        }
        return isLastRecord ? "\(baseLabel)；上次记录，待更新" : baseLabel
    }
}

enum QuotaSidebarGlyphGeometry {
    static let lineCount = 3
    static let lineWidth: CGFloat = 1.8
    static let dimmedOpacity = 0.30
    static let renderSize: CGFloat = 36

    static func arc(in rect: CGRect) -> Path {
        scaled(Path(ellipseIn: circleBounds), to: rect)
    }

    static func progressArc(in rect: CGRect, remainingPercent: Double?) -> Path {
        guard let remainingPercent, remainingPercent.isFinite,
              (0...100).contains(remainingPercent), remainingPercent > 0 else { return Path() }
        if remainingPercent == 100 {
            return scaled(Path(ellipseIn: circleBounds), to: rect)
        }

        var path = Path()
        path.addRelativeArc(
            center: CGPoint(x: 12, y: 12),
            radius: 9,
            startAngle: .degrees(-90),
            delta: .degrees(360 * remainingPercent / 100)
        )
        return scaled(path, to: rect)
    }

    static func line(index: Int, in rect: CGRect) -> Path {
        let definitions: [(x: CGFloat, top: CGFloat)] = [(8, 13.5), (12, 10.5), (16, 7.5)]
        guard definitions.indices.contains(index) else { return Path() }
        let definition = definitions[index]
        var path = Path()
        path.move(to: CGPoint(x: definition.x, y: definition.top))
        path.addLine(to: CGPoint(x: definition.x, y: 16))
        return scaled(path, to: rect)
    }

    private static func scaled(_ path: Path, to rect: CGRect) -> Path {
        path.applying(CGAffineTransform(
            a: rect.width / 24, b: 0, c: 0, d: rect.height / 24,
            tx: rect.minX, ty: rect.minY
        ))
    }

    private static let circleBounds = CGRect(x: 3, y: 3, width: 18, height: 18)
}

private struct QuotaSidebarArcShape: Shape {
    func path(in rect: CGRect) -> Path { QuotaSidebarGlyphGeometry.arc(in: rect) }
}

private struct QuotaSidebarProgressShape: Shape {
    let remainingPercent: Double?
    func path(in rect: CGRect) -> Path {
        QuotaSidebarGlyphGeometry.progressArc(in: rect, remainingPercent: remainingPercent)
    }
}

private struct QuotaSidebarLineShape: Shape {
    let index: Int
    func path(in rect: CGRect) -> Path { QuotaSidebarGlyphGeometry.line(index: index, in: rect) }
}

struct QuotaSidebarGlyph: View {
    let tier: QuotaSidebarGlyphTier
    let remainingPercent: Double?

    init(tier: QuotaSidebarGlyphTier, remainingPercent: Double? = nil) {
        self.tier = tier
        self.remainingPercent = remainingPercent
    }

    private var tint: Color { Color(nsColor: .secondaryLabelColor) }
    private var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: QuotaSidebarGlyphGeometry.lineWidth, lineCap: .round, lineJoin: .round)
    }

    var body: some View {
        ZStack {
            QuotaSidebarArcShape()
                .stroke(tint.opacity(QuotaSidebarGlyphGeometry.dimmedOpacity), style: strokeStyle)
            QuotaSidebarProgressShape(remainingPercent: remainingPercent)
                .stroke(tint, style: strokeStyle)
            Text(QuotaSidebarGlyphValueFormatter.number(remainingPercent: remainingPercent))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
        }
        .frame(width: QuotaSidebarGlyphGeometry.renderSize, height: QuotaSidebarGlyphGeometry.renderSize)
        .accessibilityHidden(true)
    }
}

@MainActor
struct QuotaAnchorButtonView: View {
    @ObservedObject var model: QuotaWindowModel
    let action: () -> Void

    private var glyphState: QuotaSidebarGlyphState { QuotaSidebarGlyphState.current(for: model) }

    var body: some View {
        Button(action: action) {
            QuotaSidebarGlyph(tier: glyphState.tier, remainingPercent: glyphState.remainingPercent)
                .frame(width: QuotaSidebarGlyphGeometry.renderSize, height: QuotaSidebarGlyphGeometry.renderSize)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(glyphState.accessibilityLabel)
        .help(glyphState.accessibilityLabel)
    }
}
