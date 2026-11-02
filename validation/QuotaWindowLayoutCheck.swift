import CoreGraphics
import Foundation

@main
struct QuotaWindowLayoutCheck {
    static func main() {
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            if !condition() { failures.append(name) }
        }

        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let summary = CGRect(x: 1240, y: 560, width: 88, height: 318)
        let expanded = QuotaWindowLayout.expandedFrame(
            from: summary,
            expandedSize: QuotaWindowLayout.detailsContentSize,
            visibleFrame: visible
        )
        check(expanded.fitsVisibleFrame, "details fit the reference visible frame")
        check(expanded.frame.maxX == summary.maxX, "expansion preserves the right edge when space is sufficient")
        check(expanded.frame.maxY == summary.maxY, "expansion preserves the top edge when space is sufficient")

        let returned = QuotaWindowLayout.summaryFrame(
            from: expanded.frame,
            summarySize: QuotaWindowLayout.summaryContentSize,
            visibleFrame: visible
        )
        check(returned.fitsVisibleFrame, "summary fits after collapsing")
        check(returned.frame.maxX == expanded.frame.maxX, "collapse preserves the right edge")
        check(returned.frame.maxY == expanded.frame.maxY, "collapse preserves the top edge")

        let offscreen = QuotaWindowLayout.clamped(
            CGRect(x: -40, y: 880, width: 88, height: 318),
            to: visible
        )
        check(offscreen.fitsVisibleFrame, "offscreen summary is clamped into the visible frame")
        check(visible.contains(offscreen.frame), "clamped summary is fully visible")

        let tooTallContent = QuotaWindowLayout.visibleContentHeight(
            desiredHeight: 540,
            windowChromeHeight: 28,
            visibleFrameHeight: 400
        )
        check(tooTallContent == 372, "details content height leaves room for window chrome")
        check(QuotaWindowLayout.visibleContentHeight(desiredHeight: 540, windowChromeHeight: 28, visibleFrameHeight: 10) == 1,
              "details content height stays positive on an unusably short display")

        let impossible = QuotaWindowLayout.clamped(
            CGRect(x: 0, y: 0, width: 400, height: 200),
            to: CGRect(x: 0, y: 0, width: 300, height: 500)
        )
        check(!impossible.fitsVisibleFrame, "oversized window is reported as not fully placeable")
        let invalid = QuotaWindowLayout.clamped(.zero, to: visible)
        check(!invalid.fitsVisibleFrame, "invalid geometry fails closed")

        check(QuotaValueFormatter.percent(0) == "0%", "zero percent remains a numeric value")
        check(QuotaValueFormatter.percent(100) == "100%", "full remaining percent formats")
        check(QuotaValueFormatter.percent(nil) == "未知", "missing percent is distinct")
        check(QuotaValueFormatter.percent(101) == "异常", "out-of-range percent is distinct")
        check(QuotaValueFormatter.resetCount(0) == "0 次", "zero reset count remains numeric")
        check(QuotaValueFormatter.resetCount(nil) == "未知", "missing reset count is distinct")
        check(QuotaValueFormatter.resetCount(-1) == "异常", "negative reset count is distinct")
        check(QuotaValueFormatter.progress(nil) == nil, "unknown percent has no progress value")
        check(QuotaValueFormatter.progress(101) == nil, "invalid percent has no progress value")
        check(QuotaValueFormatter.progress(0) == 0, "zero percent has zero progress")

        if failures.isEmpty {
            print("QuotaWindowLayoutCheck: PASS (22 assertions)")
        } else {
            fputs("QuotaWindowLayoutCheck: FAIL\n" + failures.map { "- \($0)" }.joined(separator: "\n") + "\n", stderr)
            exit(1)
        }
    }
}
