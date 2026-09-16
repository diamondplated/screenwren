import AppKit
import CoreGraphics

struct DesktopDisplay: Equatable, Sendable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let scale: CGFloat
}
struct DesktopCaptureSlice: Equatable, Sendable {
    let display: DesktopDisplay
    let region: CGRect
    let outputFrame: CGRect  // Pixel coordinates with a bottom-left origin.
}
struct DesktopCapturePlan: Equatable, Sendable {
    let rect: CGRect
    let scale: CGFloat
    let size: CGSize
    let slices: [DesktopCaptureSlice]
}
func desktopCapturePlan(rect: CGRect, displays: [DesktopDisplay], outputScale: CGFloat? = nil) throws
    -> DesktopCapturePlan
{
    guard [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite), rect.width >= 1, rect.height >= 1,
        !displays.isEmpty, displays.allSatisfy({ $0.scale.isFinite && $0.scale >= 1 && $0.scale <= 4 })
    else { throw ImageOperationsError.invalidDimensions }
    let covered = displays.filter { !$0.frame.intersection(rect).isEmpty }
    guard !covered.isEmpty else { throw CaptureSupportError.missingDisplay }
    let scale = outputScale ?? covered.map(\.scale).max() ?? 1
    guard scale.isFinite, scale >= 1, scale <= 4 else { throw ImageOperationsError.invalidDimensions }
    let size = CGSize(width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
    guard size.width > 0, size.height > 0, size.width <= 30_000, size.height <= 30_000,
        size.width * size.height <= 64_000_000
    else { throw ImageOperationsError.outputTooLarge }
    let slices = covered.map { display -> DesktopCaptureSlice in
        let region = display.frame.intersection(rect)
        let x = ((region.minX - rect.minX) * scale).rounded()
        let y = ((region.minY - rect.minY) * scale).rounded()
        let maxX = ((region.maxX - rect.minX) * scale).rounded()
        let maxY = ((region.maxY - rect.minY) * scale).rounded()
        return DesktopCaptureSlice(
            display: display, region: region, outputFrame: CGRect(x: x, y: y, width: maxX - x, height: maxY - y))
    }
    return DesktopCapturePlan(rect: rect, scale: scale, size: size, slices: slices)
}
struct DesktopRegion: Equatable {
    let plan: DesktopCapturePlan
    let regions: [DisplayRegion]
    @MainActor init?(rect: CGRect, screens: [NSScreen], scale: CGFloat) {
        let displays = screens.compactMap { screen -> DesktopDisplay? in
            guard let id = screen.screenwrenDisplayID else { return nil }
            return DesktopDisplay(id: id, frame: screen.frame, scale: screen.backingScaleFactor)
        }
        guard let plan = try? desktopCapturePlan(rect: rect, displays: displays, outputScale: scale) else { return nil }
        let regions = plan.slices.compactMap { slice -> DisplayRegion? in
            guard let screen = screens.first(where: { $0.screenwrenDisplayID == slice.display.id }) else { return nil }
            return DisplayRegion(rect: slice.region, screen: screen)
        }
        guard regions.count == plan.slices.count else { return nil }
        self.plan = plan
        self.regions = regions
    }
    @MainActor var isValid: Bool { regions.allSatisfy(\.isValid) }
}
func composeDesktopImages(_ images: [CGImage], plan: DesktopCapturePlan) throws -> CGImage {
    guard images.count == plan.slices.count, !images.isEmpty else { throw CaptureSupportError.missingImage }
    return try renderCGImage(width: Int(plan.size.width), height: Int(plan.size.height)) { context in
        context.interpolationQuality = .high
        for (index, image) in images.enumerated() { context.draw(image, in: plan.slices[index].outputFrame) }
    }
}
@MainActor
func acquireDesktopScreenshot(for region: DesktopRegion) async throws -> CGImage {
    guard region.isValid else { throw CaptureSupportError.displayChanged }
    var images: [CGImage] = []
    for slice in region.regions {
        try Task.checkCancellation()
        images.append(try await acquireScreenshot(for: .region(slice)))
    }
    guard region.isValid else { throw CaptureSupportError.displayChanged }
    let batch = SendableImageBatch(images: images)
    let plan = region.plan
    return try await Task.detached(priority: .userInitiated) {
        SendableImage(image: try composeDesktopImages(batch.images, plan: plan))
    }.value.image
}
