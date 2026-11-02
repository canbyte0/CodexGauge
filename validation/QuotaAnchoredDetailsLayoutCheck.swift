import CoreGraphics
import Foundation

@main
struct QuotaAnchoredDetailsLayoutCheck {
    private static var checks = 0

    static func main() {
        check(
            QuotaWindowLayout.anchoredDetailsContentHeight(
                naturalContentHeight: 238,
                windowChromeHeight: 32,
                visibleFrameHeight: 900
            ) == 238,
            "short actual content remains natural height"
        )
        check(
            QuotaWindowLayout.anchoredDetailsContentHeight(
                naturalContentHeight: 640,
                windowChromeHeight: 32,
                visibleFrameHeight: 900
            ) == 640,
            "multi-row actual content remains natural height"
        )

        let naturalHeight: CGFloat = 1_080
        let smallScreenHeight: CGFloat = 600
        let largeScreenHeight: CGFloat = 1_200
        let smallViewport = QuotaWindowLayout.anchoredDetailsContentHeight(
            naturalContentHeight: naturalHeight,
            windowChromeHeight: 32,
            visibleFrameHeight: smallScreenHeight
        )
        let largeViewport = QuotaWindowLayout.anchoredDetailsContentHeight(
            naturalContentHeight: naturalHeight,
            windowChromeHeight: 32,
            visibleFrameHeight: largeScreenHeight
        )
        check(smallViewport == 568, "overflow is capped at available screen height")
        check(largeViewport == naturalHeight, "larger screen restores saved natural height")

        let button = CGRect(x: 300, y: 400, width: 44, height: 44)
        let screen = CGRect(x: 0, y: 0, width: 1_400, height: 1_000)
        let shortPlacement = QuotaWindowLayout.anchoredDetailsFrame(
            buttonFrame: button,
            outerSize: CGSize(width: 340, height: 238 + 32),
            visibleFrame: screen
        )
        let tallPlacement = QuotaWindowLayout.anchoredDetailsFrame(
            buttonFrame: button,
            outerSize: CGSize(width: 340, height: 640 + 32),
            visibleFrame: screen
        )
        check(abs(shortPlacement.frame.midY - button.midY) < 0.01, "short panel follows button center")
        check(abs(tallPlacement.frame.midY - button.midY) < 0.01, "taller panel follows button center using current height")
        check(shortPlacement.frame.height != tallPlacement.frame.height, "follow placement does not revert to fixed details height")

        let cappedPlacement = QuotaWindowLayout.anchoredDetailsFrame(
            buttonFrame: CGRect(x: 300, y: 20, width: 44, height: 44),
            outerSize: CGSize(width: 340, height: smallScreenHeight),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_400, height: smallScreenHeight)
        )
        check(cappedPlacement.fitsVisibleFrame, "screen-capped panel remains within visible frame")
        check(QuotaWindowLayout.anchoredDetailsContentHeight(naturalContentHeight: .nan, windowChromeHeight: 32, visibleFrameHeight: 900) == nil, "non-finite measurement is rejected")
        check(QuotaWindowLayout.anchoredDetailsContentHeight(naturalContentHeight: 0, windowChromeHeight: 32, visibleFrameHeight: 900) == nil, "empty measurement is rejected")

        print("PASS \(checks) anchored details sizing checks")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: \(name)") }
    }
}
