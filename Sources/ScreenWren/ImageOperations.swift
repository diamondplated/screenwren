import AppKit
import CoreGraphics
import CoreImage

enum ImageOperationsError: Error, Equatable, LocalizedError {
    case invalidDimensions
    case invalidRectangle
    case couldNotCreateContext
    case couldNotRender
    case couldNotEncodePNG
    case noFrames
    case tooManyFrames(limit: Int)
    case frameSizeMismatch(index: Int)
    case duplicateFrame(index: Int)
    case overlapNotFound(index: Int)
    case overlapAmbiguous(index: Int)
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidDimensions: "The image dimensions are invalid."
        case .invalidRectangle: "The selected rectangle is empty."
        case .couldNotCreateContext: "ScreenWren couldn’t create an image context."
        case .couldNotRender: "ScreenWren couldn’t render the image."
        case .couldNotEncodePNG: "ScreenWren couldn’t encode the image as PNG."
        case .noFrames: "There are no scrolling frames to stitch."
        case .tooManyFrames(let limit): "Scrolling capture is limited to \(limit) frames."
        case .frameSizeMismatch(let index): "Scrolling frame \(index + 1) has a different size."
        case .duplicateFrame(let index): "Scrolling frame \(index + 1) duplicates the previous frame."
        case .overlapNotFound(let index): "ScreenWren couldn’t find a safe overlap for scrolling frame \(index + 1)."
        case .overlapAmbiguous(let index): "The overlap for scrolling frame \(index + 1) is ambiguous."
        case .outputTooLarge: "The resulting image is too large."
        }
    }
}

func makeSRGBImageContext(width: Int, height: Int) throws -> CGContext {
    guard width > 0, height > 0 else {
        throw ImageOperationsError.invalidDimensions
    }
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        throw ImageOperationsError.couldNotCreateContext
    }
    return context
}

func renderCGImage(
    width: Int,
    height: Int,
    drawing: (CGContext) -> Void
) throws -> CGImage {
    let context = try makeSRGBImageContext(width: width, height: height)
    drawing(context)
    guard let image = context.makeImage() else {
        throw ImageOperationsError.couldNotRender
    }
    return image
}

func copiedCGImage(_ image: CGImage) throws -> CGImage {
    try renderCGImage(width: image.width, height: image.height) { context in
        context.draw(image, in: image.pixelBounds)
    }
}

/// Rectangle-based operations use `CGImage` pixel coordinates (origin at the upper-left).
func redactedCGImage(_ image: CGImage, in rectangle: CGRect) throws -> CGImage {
    let rectangle = try image.validPixelRectangle(rectangle)
    let drawingRectangle = image.bottomLeftRectangle(fromTopLeft: rectangle)
    return try renderCGImage(width: image.width, height: image.height) { context in
        context.draw(image, in: image.pixelBounds)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(drawingRectangle)
    }
}

/// A visual obscuring effect only. Blur is reversible enough that it must not be presented as redaction.
func blurredNonsecureCGImage(
    _ image: CGImage,
    in rectangle: CGRect,
    radius: CGFloat = 18
) throws -> CGImage {
    guard radius > 0 else { return try copiedCGImage(image) }
    let rectangle = try image.validPixelRectangle(rectangle)
    let filterRectangle = image.bottomLeftRectangle(fromTopLeft: rectangle)
    let original = CIImage(cgImage: image)
    let blurredPatch = original
        .clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        .cropped(to: filterRectangle)
    let result = blurredPatch.composited(over: original)
    guard let rendered = CIContext(options: [.cacheIntermediates: false])
        .createCGImage(result, from: original.extent) else {
        throw ImageOperationsError.couldNotRender
    }
    return rendered
}

func croppedCGImage(_ image: CGImage, to rectangle: CGRect) throws -> CGImage {
    let rectangle = try image.validPixelRectangle(rectangle)
    guard let cropped = image.cropping(to: rectangle) else {
        throw ImageOperationsError.couldNotRender
    }
    return cropped
}

func resizedCGImagePreservingAspect(_ image: CGImage, width: Int) throws -> CGImage {
    guard width > 0, image.width > 0, image.height > 0 else {
        throw ImageOperationsError.invalidDimensions
    }
    let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
    return try renderCGImage(width: width, height: height) { context in
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
}

func rotated90CGImage(_ image: CGImage, clockwise: Bool) throws -> CGImage {
    try renderCGImage(width: image.height, height: image.width) { context in
        if clockwise {
            context.translateBy(x: 0, y: CGFloat(image.width))
            context.rotate(by: -.pi / 2)
        } else {
            context.translateBy(x: CGFloat(image.height), y: 0)
            context.rotate(by: .pi / 2)
        }
        context.draw(image, in: image.pixelBounds)
    }
}

func pngData(for image: CGImage) throws -> Data {
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw ImageOperationsError.couldNotEncodePNG
    }
    return data
}

private struct SendableCGImage: @unchecked Sendable {
    let image: CGImage
}

@MainActor
func pngDataOffMain(for image: CGImage) async throws -> Data {
    let payload = SendableCGImage(image: image)
    return try await Task.detached(priority: .userInitiated) {
        try Task.checkCancellation()
        return try pngData(for: payload.image)
    }.value
}

func uncompressedByteEstimate(for image: CGImage) -> Int {
    let (pixels, pixelOverflow) = image.width.multipliedReportingOverflow(by: image.height)
    let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
    return pixelOverflow || byteOverflow ? .max : bytes
}

func checkedScrollingOutputHeight(
    width: Int,
    currentHeight: Int,
    frameHeight: Int,
    overlap: Int,
    maxOutputHeight: Int = 30_000,
    maxPixels: Int = 120_000_000
) throws -> Int {
    guard width > 0,
          currentHeight >= 0,
          frameHeight > 0,
          overlap >= 0,
          overlap < frameHeight,
          maxOutputHeight > 0,
          maxPixels > 0 else { throw ImageOperationsError.invalidDimensions }
    let (outputHeight, heightOverflow) = currentHeight.addingReportingOverflow(frameHeight - overlap)
    let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: outputHeight)
    guard !heightOverflow,
          !pixelOverflow,
          outputHeight <= maxOutputHeight,
          pixelCount <= maxPixels else { throw ImageOperationsError.outputTooLarge }
    return outputHeight
}

func stitchCGImagesVertically(
    _ frames: [CGImage],
    maxFrames: Int = 20,
    maxOutputHeight: Int = 30_000,
    maxPixels: Int = 120_000_000
) throws -> CGImage {
    guard maxFrames > 0, maxOutputHeight > 0, maxPixels > 0 else {
        throw ImageOperationsError.invalidDimensions
    }
    guard let first = frames.first else { throw ImageOperationsError.noFrames }
    guard frames.count <= maxFrames else { throw ImageOperationsError.tooManyFrames(limit: maxFrames) }
    guard first.width > 0, first.height > 0 else { throw ImageOperationsError.invalidDimensions }

    for (index, frame) in frames.enumerated().dropFirst() where frame.width != first.width || frame.height != first.height {
        throw ImageOperationsError.frameSizeMismatch(index: index)
    }

    var overlaps: [Int] = []
    var outputHeight = first.height
    for index in frames.indices.dropFirst() {
        let overlap: Int
        do {
            overlap = try conservativeVerticalOverlap(previous: frames[index - 1], next: frames[index])
        } catch OverlapError.duplicate {
            throw ImageOperationsError.duplicateFrame(index: index)
        } catch OverlapError.notFound {
            throw ImageOperationsError.overlapNotFound(index: index)
        } catch OverlapError.ambiguous {
            throw ImageOperationsError.overlapAmbiguous(index: index)
        }
        overlaps.append(overlap)
        outputHeight = try checkedScrollingOutputHeight(
            width: first.width,
            currentHeight: outputHeight,
            frameHeight: first.height,
            overlap: overlap,
            maxOutputHeight: maxOutputHeight,
            maxPixels: maxPixels
        )
    }

    let (pixelCount, pixelOverflow) = first.width.multipliedReportingOverflow(by: outputHeight)
    guard !pixelOverflow, outputHeight <= maxOutputHeight, pixelCount <= maxPixels else {
        throw ImageOperationsError.outputTooLarge
    }

    return try renderCGImage(width: first.width, height: outputHeight) { context in
        var frameOriginY = outputHeight - first.height
        for (index, frame) in frames.enumerated() {
            context.draw(frame, in: CGRect(x: 0, y: frameOriginY, width: first.width, height: first.height))
            if index < overlaps.count {
                frameOriginY -= first.height - overlaps[index]
            }
        }
    }
}

func validatedScrollingOverlap(previous: CGImage, next: CGImage, newFrameIndex: Int = 1) throws -> Int {
    guard previous.width == next.width, previous.height == next.height else {
        throw ImageOperationsError.frameSizeMismatch(index: newFrameIndex)
    }
    do {
        return try conservativeVerticalOverlap(previous: previous, next: next)
    } catch OverlapError.duplicate {
        throw ImageOperationsError.duplicateFrame(index: newFrameIndex)
    } catch OverlapError.notFound {
        throw ImageOperationsError.overlapNotFound(index: newFrameIndex)
    } catch OverlapError.ambiguous {
        throw ImageOperationsError.overlapAmbiguous(index: newFrameIndex)
    }
}

func validateScrollingPair(previous: CGImage, next: CGImage, newFrameIndex: Int = 1) throws {
    _ = try validatedScrollingOverlap(previous: previous, next: next, newFrameIndex: newFrameIndex)
}

// ponytail: manual scrolling uses a conservative pixel heuristic; move to feature matching only if real captures prove this too strict.
private func conservativeVerticalOverlap(previous: CGImage, next: CGImage) throws -> Int {
    let sampleWidth = min(32, previous.width)
    let previousPixels = try grayscaleRows(of: previous, width: sampleWidth)
    let nextPixels = try grayscaleRows(of: next, width: sampleWidth)
    let height = previous.height

    if overlapScore(previousPixels, nextPixels, width: sampleWidth, height: height, overlap: height) <= 1.5 {
        throw OverlapError.duplicate
    }

    let minimumOverlap = max(2, Int((Double(height) * 0.05).rounded(.up)))
    let maximumOverlap = min(height - 1, Int((Double(height) * 0.95).rounded(.down)))
    guard minimumOverlap <= maximumOverlap else { throw OverlapError.notFound }

    var scores: [(overlap: Int, score: Double)] = []
    scores.reserveCapacity(maximumOverlap - minimumOverlap + 1)
    for overlap in minimumOverlap...maximumOverlap {
        scores.append((overlap, overlapScore(previousPixels, nextPixels, width: sampleWidth, height: height, overlap: overlap)))
    }
    guard let best = scores.min(by: { $0.score < $1.score }), best.score <= 8 else {
        throw OverlapError.notFound
    }

    let runnerUp = scores
        .filter { abs($0.overlap - best.overlap) > 2 }
        .map(\.score)
        .min() ?? .infinity
    guard runnerUp - best.score >= 0.75 else { throw OverlapError.ambiguous }
    return best.overlap
}

private enum OverlapError: Error {
    case duplicate
    case notFound
    case ambiguous
}

private func overlapScore(
    _ previous: [UInt8],
    _ next: [UInt8],
    width: Int,
    height: Int,
    overlap: Int
) -> Double {
    let rowsToCompare = min(64, overlap)
    var difference = 0
    for sample in 0..<rowsToCompare {
        let rowOffset = rowsToCompare == 1 ? 0 : sample * (overlap - 1) / (rowsToCompare - 1)
        let previousStart = (height - overlap + rowOffset) * width
        let nextStart = rowOffset * width
        for column in 0..<width {
            difference += abs(Int(previous[previousStart + column]) - Int(next[nextStart + column]))
        }
    }
    return Double(difference) / Double(rowsToCompare * width)
}

private func grayscaleRows(of image: CGImage, width: Int) throws -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: width * image.height)
    let created = pixels.withUnsafeMutableBytes { bytes -> Bool in
        guard let context = CGContext(
            data: bytes.baseAddress,
            width: width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return false }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
        return true
    }
    guard created else { throw ImageOperationsError.couldNotCreateContext }
    return pixels
}

private extension CGImage {
    var pixelBounds: CGRect {
        CGRect(x: 0, y: 0, width: width, height: height)
    }

    func validPixelRectangle(_ rectangle: CGRect) throws -> CGRect {
        let rectangle = rectangle.standardized
            .intersection(pixelBounds)
            .integral
            .intersection(pixelBounds)
        guard !rectangle.isNull, !rectangle.isEmpty else {
            throw ImageOperationsError.invalidRectangle
        }
        return rectangle
    }

    func bottomLeftRectangle(fromTopLeft rectangle: CGRect) -> CGRect {
        CGRect(
            x: rectangle.minX,
            y: CGFloat(height) - rectangle.maxY,
            width: rectangle.width,
            height: rectangle.height
        )
    }
}

func runImageOperationsSelfCheck() throws {
    func requireError(
        _ expected: ImageOperationsError,
        _ operation: () throws -> Void
    ) {
        do {
            try operation()
            preconditionFailure("Expected image operation error: \(expected)")
        } catch let error as ImageOperationsError {
            precondition(error == expected, "Expected \(expected), got \(error)")
        } catch {
            preconditionFailure("Expected \(expected), got \(error)")
        }
    }

    let source = try renderCGImage(width: 20, height: 120) { context in
        for row in 0..<120 {
            let shade = CGFloat((row * 37) % 251) / 255
            context.setFillColor(CGColor(gray: shade, alpha: 1))
            context.fill(CGRect(x: 0, y: row, width: 20, height: 1))
        }
    }
    let top = try croppedCGImage(source, to: CGRect(x: 0, y: 0, width: 20, height: 80))
    let bottom = try croppedCGImage(source, to: CGRect(x: 0, y: 40, width: 20, height: 80))
    let stitched = try stitchCGImagesVertically([top, bottom], maxOutputHeight: 200, maxPixels: 10_000)
    let stitchedPNG = try pngData(for: stitched)
    let sourcePixels = try grayscaleRows(of: source, width: 20)
    let stitchedPixels = try grayscaleRows(of: stitched, width: 20)
    precondition(stitched.width == 20 && stitched.height == 120, "got \(stitched.width)x\(stitched.height)")
    precondition(sourcePixels == stitchedPixels)
    precondition(stitchedPNG.isEmpty == false)
    precondition(uncompressedByteEstimate(for: stitched) == 20 * 120 * 4)

    requireError(.duplicateFrame(index: 1)) {
        _ = try stitchCGImagesVertically([top, top])
    }
    requireError(.outputTooLarge) {
        _ = try stitchCGImagesVertically([top, bottom], maxOutputHeight: 100)
    }
    requireError(.tooManyFrames(limit: 20)) {
        _ = try stitchCGImagesVertically(Array(repeating: top, count: 21))
    }
    let black = try renderCGImage(width: 20, height: 80) { context in
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 80))
    }
    let whiteMismatch = try renderCGImage(width: 20, height: 80) { context in
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 80))
    }
    requireError(.overlapNotFound(index: 1)) {
        _ = try stitchCGImagesVertically([black, whiteMismatch])
    }

    let resized = try resizedCGImagePreservingAspect(source, width: 10)
    precondition(resized.width == 10 && resized.height == 60)
    let rotated = try rotated90CGImage(source, clockwise: true)
    precondition(rotated.width == 120 && rotated.height == 20)

    let rotationFixture = try renderCGImage(width: 2, height: 3) { context in
        for row in 0..<3 {
            for column in 0..<2 {
                let shade = CGFloat(30 + row * 60 + column * 20) / 255
                context.setFillColor(CGColor(gray: shade, alpha: 1))
                context.fill(CGRect(x: column, y: row, width: 1, height: 1))
            }
        }
    }
    let clockwise = try rotated90CGImage(rotationFixture, clockwise: true)
    let originalPixels = try grayscaleRows(of: rotationFixture, width: 2)
    let clockwisePixels = try grayscaleRows(of: clockwise, width: 3)
    for row in 0..<2 {
        for column in 0..<3 {
            precondition(
                clockwisePixels[row * 3 + column] == originalPixels[(2 - column) * 2 + row],
                "rotation fixture mismatch: original=\(originalPixels) rotated=\(clockwisePixels)"
            )
        }
    }

    let white = try renderCGImage(width: 8, height: 8) { context in
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }
    let redacted = try redactedCGImage(white, in: CGRect(x: 2, y: 2, width: 4, height: 4))
    let redactedPixels = try grayscaleRows(of: redacted, width: 8)
    let checkerboard = try renderCGImage(width: 8, height: 8) { context in
        for row in 0..<8 {
            for column in 0..<8 where (row + column).isMultiple(of: 2) {
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: column, y: row, width: 1, height: 1))
            }
        }
    }
    let blurred = try blurredNonsecureCGImage(checkerboard, in: CGRect(x: 0, y: 0, width: 8, height: 4), radius: 2)
    let checkerboardPixels = try grayscaleRows(of: checkerboard, width: 8)
    let blurredPixels = try grayscaleRows(of: blurred, width: 8)
    precondition(redactedPixels.filter { $0 == 0 }.count == 16)
    precondition(blurred.width == 8)
    precondition(zip(checkerboardPixels.prefix(32), blurredPixels.prefix(32)).contains { abs(Int($0) - Int($1)) > 8 })
    precondition(zip(checkerboardPixels.suffix(32), blurredPixels.suffix(32)).allSatisfy { abs(Int($0) - Int($1)) <= 1 })

    let topRedacted = try redactedCGImage(white, in: CGRect(x: 2, y: 0, width: 4, height: 2))
    let topRedactedPixels = try grayscaleRows(of: topRedacted, width: 8)
    for row in 0..<2 {
        for column in 0..<8 {
            precondition(topRedactedPixels[row * 8 + column] == ((2..<6).contains(column) ? 0 : 255))
        }
    }
    precondition(topRedactedPixels.suffix(16).allSatisfy { $0 == 255 })
}

#if IMAGE_OPERATIONS_STANDALONE_SELF_CHECK
@main
private enum ImageOperationsSelfCheck {
    static func main() throws {
        try runImageOperationsSelfCheck()
        print("Image operations self-check passed")
    }
}
#endif
