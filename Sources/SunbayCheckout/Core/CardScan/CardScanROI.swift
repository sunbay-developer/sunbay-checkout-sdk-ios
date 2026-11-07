import CoreGraphics

/// Maps the on-screen scan guide to a Vision `regionOfInterest`, so recognition only looks at the
/// part of the camera frame where the card is. Smaller area means faster frames and less noise.
///
/// Pure geometry (no UIKit / AVFoundation), so it is testable on the host.
enum CardScanROI {
    /// - Parameters:
    ///   - guide: The guide rectangle in the preview view's coordinates (top-left origin).
    ///   - viewSize: The preview view's size. The preview uses aspect-fill.
    ///   - imageSize: The upright (already rotated) camera image size in pixels.
    ///   - horizontalMargin: Extra width on each side, as a fraction of the guide width.
    ///   - verticalMargin: Extra height on each side, as a fraction of the guide height. Generous by
    ///     default so the PAN is still covered if the card sits slightly off the frame.
    /// - Returns: A rect in Vision's normalized, lower-left-origin space, clamped to `0...1`. Falls
    ///   back to the whole image if the inputs are degenerate.
    static func normalizedRegion(
        guide: CGRect,
        viewSize: CGSize,
        imageSize: CGSize,
        horizontalMargin: CGFloat = 0.08,
        verticalMargin: CGFloat = 0.5
    ) -> CGRect {
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard viewSize.width > 0, viewSize.height > 0, imageSize.width > 0, imageSize.height > 0,
            guide.width > 0, guide.height > 0
        else { return whole }

        // Aspect-fill: the image is scaled to cover the view and centered (the overflow is cropped).
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let offsetX = (viewSize.width - imageSize.width * scale) / 2
        let offsetY = (viewSize.height - imageSize.height * scale) / 2

        let expanded = guide.insetBy(dx: -guide.width * horizontalMargin, dy: -guide.height * verticalMargin)
        // View -> image pixels (top-left origin).
        let x = (expanded.minX - offsetX) / scale
        let y = (expanded.minY - offsetY) / scale
        let w = expanded.width / scale
        let h = expanded.height / scale

        // Normalize and flip Y into Vision's lower-left origin.
        let normalized = CGRect(
            x: x / imageSize.width,
            y: 1 - (y + h) / imageSize.height,
            width: w / imageSize.width,
            height: h / imageSize.height)
        let clamped = normalized.intersection(whole)
        return clamped.isNull || clamped.width < 0.05 || clamped.height < 0.05 ? whole : clamped
    }
}
