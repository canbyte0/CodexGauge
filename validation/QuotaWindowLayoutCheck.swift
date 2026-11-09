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
        let minimumHostSize = CGSize(width: 900, height: 700)
        let mainWindow = CGRect(x: 120, y: 80, width: 1280, height: 900)
        let smallPreview = CGRect(x: 900, y: 120, width: 400, height: 300)
        check(QuotaWindowCandidateSelector.select(frames: [mainWindow], minimumSize: minimumHostSize) == .unique(index: 0),
              "one main-sized window is selected")
        check(QuotaWindowCandidateSelector.select(frames: [mainWindow, smallPreview], minimumSize: minimumHostSize) == .unique(index: 0),
              "small preview after main window is ignored")
        check(QuotaWindowCandidateSelector.select(frames: [smallPreview, mainWindow], minimumSize: minimumHostSize) == .unique(index: 1),
              "small preview before main window is ignored")
        check(QuotaWindowCandidateSelector.select(
            frames: [smallPreview, CGRect(x: 20, y: 30, width: 800, height: 600)], minimumSize: minimumHostSize
        ) == .none, "multiple small auxiliary windows do not become a candidate")
        check(QuotaWindowCandidateSelector.select(frames: [smallPreview], minimumSize: minimumHostSize) == .none,
              "only a small window remains hidden")
        let secondMainWindow = CGRect(x: -1500, y: -800, width: 1000, height: 800)
        check(QuotaWindowCandidateSelector.select(frames: [mainWindow, secondMainWindow], minimumSize: minimumHostSize) == .ambiguous,
              "multiple main-sized windows remain ambiguous")
        let boundaryWindow = CGRect(x: 0, y: 0, width: 900, height: 700)
        check(QuotaWindowCandidateSelector.select(frames: [boundaryWindow], minimumSize: minimumHostSize) == .unique(index: 0),
              "exact minimum size is eligible")
        check(QuotaWindowCandidateSelector.select(
            frames: [CGRect(x: 0, y: 0, width: 899.999, height: 700)], minimumSize: minimumHostSize
        ) == .none, "frame below minimum width is excluded")
        let invalidFrames = [
            CGRect.null,
            CGRect.zero,
            CGRect(x: CGFloat.nan, y: 0, width: 1200, height: 900),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 900)
        ]
        check(QuotaWindowCandidateSelector.select(frames: invalidFrames + [mainWindow], minimumSize: minimumHostSize) == .unique(index: 4),
              "invalid frames are skipped without displacing the main window")
        check(QuotaWindowCandidateSelector.select(frames: invalidFrames, minimumSize: minimumHostSize) == .none,
              "invalid frames do not produce a candidate")
        check(QuotaWindowCandidateSelector.select(frames: [secondMainWindow], minimumSize: minimumHostSize) == .unique(index: 0),
              "a valid main window at negative coordinates is eligible")
        check(QuotaWindowCandidateSelector.select(frames: [mainWindow], minimumSize: CGSize(width: CGFloat.nan, height: 700)) == .none,
              "invalid minimum size fails closed")

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
            print("QuotaWindowLayoutCheck: PASS (34 assertions)")
        } else {
            fputs("QuotaWindowLayoutCheck: FAIL\n" + failures.map { "- \($0)" }.joined(separator: "\n") + "\n", stderr)
            exit(1)
        }
    }
}
