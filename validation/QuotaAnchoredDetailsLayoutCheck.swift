import CoreGraphics
import Foundation

@main
struct QuotaAnchoredDetailsLayoutCheck {
    private static var checks = 0

    static func main() {
        let chromeHeight: CGFloat = 32
        let alignedBottomY: CGFloat = 407.6
        let ampleVisibleMaxY: CGFloat = 1_400
        check(
            QuotaWindowLayout.anchoredDetailsContentHeight(
                naturalContentHeight: 238,
                windowChromeHeight: chromeHeight,
                alignedBottomY: alignedBottomY,
                visibleFrameMaxY: ampleVisibleMaxY
            ) == 238,
            "short actual content remains natural height with space above the aligned bottom"
        )
        check(
            QuotaWindowLayout.anchoredDetailsContentHeight(
                naturalContentHeight: 640,
                windowChromeHeight: chromeHeight,
                alignedBottomY: alignedBottomY,
                visibleFrameMaxY: ampleVisibleMaxY
            ) == 640,
            "multi-row actual content remains natural height with space above the aligned bottom"
        )

        let naturalHeight: CGFloat = 1_080
        let smallVisibleMaxY: CGFloat = 600
        let largeVisibleMaxY: CGFloat = 1_200
        let smallViewport = QuotaWindowLayout.anchoredDetailsContentHeight(
            naturalContentHeight: naturalHeight,
            windowChromeHeight: chromeHeight,
            alignedBottomY: 0,
            visibleFrameMaxY: smallVisibleMaxY
        )
        let largeViewport = QuotaWindowLayout.anchoredDetailsContentHeight(
            naturalContentHeight: naturalHeight,
            windowChromeHeight: chromeHeight,
            alignedBottomY: 0,
            visibleFrameMaxY: largeVisibleMaxY
        )
        check(smallViewport == 568, "overflow is capped at available screen height")
        check(largeViewport == naturalHeight, "larger screen restores saved natural height")

        let button = CGRect(x: 300, y: 400, width: 44, height: 44)
        let screen = CGRect(x: 0, y: 0, width: 1_400, height: ampleVisibleMaxY)
        let iconBottomY = button.midY - 14.4
        let shortPlacement = QuotaWindowLayout.anchoredDetailsFrame(
            buttonFrame: button,
            alignedBottomY: iconBottomY,
            outerSize: CGSize(width: 340, height: 238 + 32),
            visibleFrame: screen
        )
        let tallPlacement = QuotaWindowLayout.anchoredDetailsFrame(
            buttonFrame: button,
            alignedBottomY: iconBottomY,
            outerSize: CGSize(width: 340, height: 640 + 32),
            visibleFrame: screen
        )
        check(abs(shortPlacement.frame.minY - iconBottomY) < 0.01, "short panel bottom aligns to visible glyph bottom")
        check(abs(tallPlacement.frame.minY - iconBottomY) < 0.01, "tall panel bottom aligns to the same visible glyph bottom")
        check(abs(shortPlacement.frame.minX - (button.maxX + 8)) < 0.01, "details panel keeps its horizontal gap")
        check(shortPlacement.frame.height != tallPlacement.frame.height, "bottom alignment uses each current natural height")
        check(shortPlacement.fitsVisibleFrame && tallPlacement.fitsVisibleFrame, "both natural panels fit when space is sufficient")

        let fallbackViewport = QuotaWindowLayout.anchoredDetailsContentHeight(
            naturalContentHeight: QuotaWindowLayout.detailsMeasurementFallbackContentHeight,
            windowChromeHeight: chromeHeight,
            alignedBottomY: 500,
            visibleFrameMaxY: 600
        )
        check(fallbackViewport == 68, "250ms fallback uses space above the aligned bottom")

        let titlebarOnlyContent = QuotaWindowLayout.anchoredDetailsContentHeight(
            naturalContentHeight: 238,
            windowChromeHeight: chromeHeight,
            alignedBottomY: 590,
            visibleFrameMaxY: 600
        )
        check(titlebarOnlyContent == 1, "tiny available space keeps a minimal content height")
        let shortScreen = CGRect(x: 0, y: 0, width: 1_400, height: 600)
        let clampedPlacement = QuotaWindowLayout.anchoredDetailsFrame(
            buttonFrame: button,
            alignedBottomY: 590,
            outerSize: CGSize(width: 340, height: (titlebarOnlyContent ?? 1) + chromeHeight),
            visibleFrame: shortScreen
        )
        check(clampedPlacement.fitsVisibleFrame, "unavailable titlebar space falls back to safe screen clamping")
        check(shortScreen.contains(clampedPlacement.frame), "clamped panel stays on screen when bottom alignment cannot fit")

        check(QuotaWindowLayout.anchoredDetailsContentHeight(
            naturalContentHeight: .nan, windowChromeHeight: chromeHeight,
            alignedBottomY: alignedBottomY, visibleFrameMaxY: ampleVisibleMaxY
        ) == nil, "non-finite natural measurement is rejected")
        check(QuotaWindowLayout.anchoredDetailsContentHeight(
            naturalContentHeight: 0, windowChromeHeight: chromeHeight,
            alignedBottomY: alignedBottomY, visibleFrameMaxY: ampleVisibleMaxY
        ) == nil, "empty measurement is rejected")
        check(QuotaWindowLayout.anchoredDetailsContentHeight(
            naturalContentHeight: 238, windowChromeHeight: chromeHeight,
            alignedBottomY: .infinity, visibleFrameMaxY: ampleVisibleMaxY
        ) == nil, "non-finite alignment anchor is rejected")
        let ampleScreen = CGRect(x: 0, y: 0, width: 1_400, height: ampleVisibleMaxY)
        check(!QuotaWindowLayout.anchoredDetailsFrame(
            buttonFrame: button, alignedBottomY: .nan,
            outerSize: CGSize(width: 340, height: 270), visibleFrame: ampleScreen
        ).fitsVisibleFrame, "non-finite frame anchor fails closed")

        print("PASS \(checks) anchored details sizing checks")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: \(name)") }
    }
}
