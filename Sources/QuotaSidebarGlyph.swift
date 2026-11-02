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
        guard case .value(let remaining) = field else { return .unknown }
        return classify(remaining: remaining)
    }

    @MainActor
    static func current(for model: QuotaWindowModel) -> Self {
        guard let snapshot = model.snapshot else { return .unknown }
        return classify(remaining: snapshot.fiveHour.remaining, pending: model.expired(snapshot.fiveHour))
    }
}

enum QuotaSidebarGlyphGeometry {
    static let lineCount = 3
    static let lineWidth: CGFloat = 1.8
    static let dimmedOpacity = 0.30

    static func arc(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 12, y: 3))
        path.addCurve(to: CGPoint(x: 3, y: 12),
                      control1: CGPoint(x: 7.0294, y: 3),
                      control2: CGPoint(x: 3, y: 7.0294))
        path.addCurve(to: CGPoint(x: 12, y: 21),
                      control1: CGPoint(x: 3, y: 16.9706),
                      control2: CGPoint(x: 7.0294, y: 21))
        path.addCurve(to: CGPoint(x: 21, y: 12),
                      control1: CGPoint(x: 16.9706, y: 21),
                      control2: CGPoint(x: 21, y: 16.9706))
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
}

private struct QuotaSidebarArcShape: Shape {
    func path(in rect: CGRect) -> Path { QuotaSidebarGlyphGeometry.arc(in: rect) }
}

private struct QuotaSidebarLineShape: Shape {
    let index: Int
    func path(in rect: CGRect) -> Path { QuotaSidebarGlyphGeometry.line(index: index, in: rect) }
}

struct QuotaSidebarGlyph: View {
    let tier: QuotaSidebarGlyphTier

    private var tint: Color { Color(nsColor: .secondaryLabelColor) }
    private var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: QuotaSidebarGlyphGeometry.lineWidth, lineCap: .round, lineJoin: .round)
    }

    var body: some View {
        ZStack {
            QuotaSidebarArcShape()
                .stroke(tint, style: strokeStyle)
            ForEach(0..<QuotaSidebarGlyphGeometry.lineCount, id: \.self) { index in
                QuotaSidebarLineShape(index: index)
                    .stroke(tint.opacity(tier.dimmedLineIndices.contains(index) ? QuotaSidebarGlyphGeometry.dimmedOpacity : 1), style: strokeStyle)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

@MainActor
struct QuotaAnchorButtonView: View {
    @ObservedObject var model: QuotaWindowModel
    let action: () -> Void

    private var tier: QuotaSidebarGlyphTier { QuotaSidebarGlyphTier.current(for: model) }

    var body: some View {
        Button(action: action) {
            QuotaSidebarGlyph(tier: tier)
                .frame(width: 24, height: 24)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(tier.accessibilityLabel)
        .help(tier.accessibilityLabel)
    }
}
