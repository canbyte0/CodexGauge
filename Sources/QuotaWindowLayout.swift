import CoreGraphics
import Foundation

struct QuotaWindowPlacement {
    let frame: CGRect
    let fitsVisibleFrame: Bool
}

enum QuotaWindowLayout {
    static let summaryContentSize = CGSize(width: 88, height: 318)
    static let detailsContentSize = CGSize(width: 320, height: 540)
    static let detailsMeasurementFallbackContentHeight: CGFloat = 240

    static func expandedFrame(
        from summaryFrame: CGRect,
        expandedSize: CGSize,
        visibleFrame: CGRect
    ) -> QuotaWindowPlacement {
        let requested = CGRect(
            x: summaryFrame.maxX - expandedSize.width,
            y: summaryFrame.maxY - expandedSize.height,
            width: expandedSize.width,
            height: expandedSize.height
        )
        return clamped(requested, to: visibleFrame)
    }

    static func summaryFrame(
        from expandedFrame: CGRect,
        summarySize: CGSize,
        visibleFrame: CGRect
    ) -> QuotaWindowPlacement {
        let requested = CGRect(
            x: expandedFrame.maxX - summarySize.width,
            y: expandedFrame.maxY - summarySize.height,
            width: summarySize.width,
            height: summarySize.height
        )
        return clamped(requested, to: visibleFrame)
    }

    static func centeredFrame(size: CGSize, visibleFrame: CGRect) -> QuotaWindowPlacement {
        let requested = CGRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        return clamped(requested, to: visibleFrame)
    }

    static func clamped(_ frame: CGRect, to visibleFrame: CGRect) -> QuotaWindowPlacement {
        guard valid(frame), valid(visibleFrame) else {
            return QuotaWindowPlacement(frame: .zero, fitsVisibleFrame: false)
        }

        let maxX = max(visibleFrame.minX, visibleFrame.maxX - frame.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - frame.height)
        let result = CGRect(
            x: min(max(frame.minX, visibleFrame.minX), maxX),
            y: min(max(frame.minY, visibleFrame.minY), maxY),
            width: frame.width,
            height: frame.height
        )
        return QuotaWindowPlacement(
            frame: result,
            fitsVisibleFrame: visibleFrame.contains(result)
        )
    }

    static func visibleContentHeight(
        desiredHeight: CGFloat,
        windowChromeHeight: CGFloat,
        visibleFrameHeight: CGFloat
    ) -> CGFloat {
        max(1, min(desiredHeight, visibleFrameHeight - windowChromeHeight))
    }

    static func anchoredDetailsContentHeight(
        naturalContentHeight: CGFloat,
        windowChromeHeight: CGFloat,
        visibleFrameHeight: CGFloat
    ) -> CGFloat? {
        guard naturalContentHeight.isFinite, naturalContentHeight > 0,
              windowChromeHeight.isFinite, windowChromeHeight >= 0,
              visibleFrameHeight.isFinite, visibleFrameHeight > windowChromeHeight else { return nil }
        return min(naturalContentHeight, visibleFrameHeight - windowChromeHeight)
    }

    static func anchoredDetailsFrame(
        buttonFrame: CGRect,
        outerSize: CGSize,
        visibleFrame: CGRect
    ) -> QuotaWindowPlacement {
        guard valid(buttonFrame), outerSize.width.isFinite, outerSize.width > 0,
              outerSize.height.isFinite, outerSize.height > 0 else {
            return QuotaWindowPlacement(frame: .zero, fitsVisibleFrame: false)
        }
        let requested = CGRect(
            x: buttonFrame.maxX + 8,
            y: buttonFrame.midY - outerSize.height / 2,
            width: outerSize.width,
            height: outerSize.height
        )
        return clamped(requested, to: visibleFrame)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && !rect.isEmpty &&
            rect.minX.isFinite && rect.minY.isFinite &&
            rect.width.isFinite && rect.height.isFinite
    }
}

enum QuotaValueFormatter {
    static func percent(_ value: Int?) -> String {
        guard let value else { return "未知" }
        guard (0...100).contains(value) else { return "异常" }
        return "\(value)%"
    }

    static func resetCount(_ value: Int?) -> String {
        guard let value else { return "未知" }
        guard value >= 0 else { return "异常" }
        return "\(value) 次"
    }

    static func progress(_ value: Int?) -> Double? {
        guard let value, (0...100).contains(value) else { return nil }
        return Double(value) / 100
    }
}
