import AppKit
import CoreGraphics
import ScreenCaptureKit

enum CaptureIntent: Equatable, Sendable {
    case image
    case text
    case delayedImage(seconds: TimeInterval)
    case scrolling
}

struct DisplayRegion: Equatable, Sendable {
    let rect: CGRect
    let displayID: CGDirectDisplayID
    let displayFrame: CGRect
    let scale: CGFloat

    @MainActor
    init?(rect: CGRect, screen: NSScreen) {
        guard let displayID = screen.screenwrenDisplayID,
              rect.isFiniteAndNonempty,
              screen.frame.contains(rect) else { return nil }

        self.rect = rect
        self.displayID = displayID
        displayFrame = screen.frame
        scale = screen.backingScaleFactor
    }

    @MainActor
    var isValid: Bool {
        guard rect.isFiniteAndNonempty,
              let screen = NSScreen.screens.first(where: { $0.screenwrenDisplayID == displayID }) else { return false }
        return screen.frame.screenwrenApproximatelyEquals(displayFrame)
            && abs(screen.backingScaleFactor - scale) < 0.001
            && screen.frame.contains(rect)
    }

    var screenCaptureRect: CGRect {
        displaySpaceRect(for: rect, displayFrame: displayFrame, displayBounds: CGDisplayBounds(displayID))
    }
}

enum SelectionTarget {
    case region(DisplayRegion)
    case window(WindowCandidate)
}

struct WindowIdentity: Equatable, Sendable {
    let windowID: CGWindowID
    let processID: pid_t
    let bundleIdentifier: String?
}

enum RepeatTarget: Equatable, Sendable {
    case region(DisplayRegion)
    case window(WindowIdentity)

    var menuTitle: String {
        switch self {
        case .region: "Repeat Last Region"
        case .window: "Repeat Last Window"
        }
    }

    init(_ target: SelectionTarget) {
        switch target {
        case let .region(region): self = .region(region)
        case let .window(candidate): self = .window(candidate.identity)
        }
    }
}

struct WindowCandidate {
    let window: SCWindow
    let appKitFrame: CGRect

    var windowID: CGWindowID { window.windowID }
    var identity: WindowIdentity {
        WindowIdentity(
            windowID: window.windowID,
            processID: window.owningApplication?.processID ?? 0,
            bundleIdentifier: window.owningApplication?.bundleIdentifier
        )
    }

    @MainActor
    static func eligible(excluding processID: pid_t = ProcessInfo.processInfo.processIdentifier) async throws -> [WindowCandidate] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        RegionCaptureFilterCache.shared.seed(with: content, excluding: processID)
        let primaryScreenMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let windowsByID = Dictionary(uniqueKeysWithValues: content.windows.compactMap { window -> (CGWindowID, SCWindow)? in
            guard window.isOnScreen,
                  window.windowLayer == 0,
                  window.owningApplication?.processID != processID,
                  window.frame.width >= 40,
                  window.frame.height >= 40 else { return nil }
            return (window.windowID, window)
        })

        let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        return windowInfo.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  windowAlphaIsEligible((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue),
                  let window = windowsByID[CGWindowID(number.uint32Value)] else { return nil }
            let frame = window.frame
            return WindowCandidate(
                window: window,
                appKitFrame: CGRect(
                    x: frame.minX,
                    y: primaryScreenMaxY - frame.maxY,
                    width: frame.width,
                    height: frame.height
                )
            )
        }
    }

    @MainActor
    static func resolve(_ identity: WindowIdentity) async throws -> WindowCandidate? {
        try await eligible().first { candidate in
            let current = candidate.identity
            return current.windowID == identity.windowID
                && current.processID == identity.processID
                && (identity.bundleIdentifier == nil || current.bundleIdentifier == identity.bundleIdentifier)
        }
    }
}

func windowAlphaIsEligible(_ alpha: Double?) -> Bool {
    alpha.map { $0 > 0.01 } ?? true
}

enum CaptureSupportError: LocalizedError {
    case displayChanged
    case missingDisplay
    case missingImage

    var errorDescription: String? {
        switch self {
        case .displayChanged: "The selected display changed. Select the region again."
        case .missingDisplay: "ScreenCaptureKit couldn’t find the selected display."
        case .missingImage: "ScreenCaptureKit returned no image."
        }
    }
}

@MainActor
private final class RegionCaptureFilterCache {
    static let shared = RegionCaptureFilterCache()
    private var filters: [CGDirectDisplayID: (SCDisplay, SCContentFilter)] = [:]

    func seed(with content: SCShareableContent, excluding processID: pid_t = ProcessInfo.processInfo.processIdentifier) {
        guard let excludedApplication = content.applications
            .first(where: { $0.processID == processID }) else { return }
        for display in content.displays {
            filters[display.displayID] = (
                display,
                SCContentFilter(display: display, excludingApplications: [excludedApplication], exceptingWindows: [])
            )
        }
    }

    func filter(for displayID: CGDirectDisplayID) async throws -> (SCDisplay, SCContentFilter) {
        if let cached = filters[displayID] { return cached }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        seed(with: content)
        if let cached = filters[displayID] { return cached }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureSupportError.missingDisplay
        }
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
        return (display, SCContentFilter(display: display, excludingWindows: ownWindows))
    }

    func invalidate() {
        filters.removeAll()
    }
}

@MainActor
func invalidateRegionCaptureFilters() {
    RegionCaptureFilterCache.shared.invalidate()
}

func shouldCacheRegionFilter(hasExcludedApplication: Bool) -> Bool {
    hasExcludedApplication
}

@MainActor
func acquireScreenshot(for target: SelectionTarget) async throws -> CGImage {
    let configuration = SCScreenshotConfiguration()
    configuration.showsCursor = false
    configuration.dynamicRange = .sdr
    configuration.displayIntent = .local

    let output: SCScreenshotOutput
    switch target {
    case let .region(region):
        guard region.isValid else { throw CaptureSupportError.displayChanged }
        let (display, filter) = try await RegionCaptureFilterCache.shared.filter(for: region.displayID)
        let globalRect = region.screenCaptureRect
        configuration.sourceRect = CGRect(
            x: globalRect.minX - display.frame.minX,
            y: globalRect.minY - display.frame.minY,
            width: globalRect.width,
            height: globalRect.height
        )
        configuration.width = max(1, Int((region.rect.width * region.scale).rounded()))
        configuration.height = max(1, Int((region.rect.height * region.scale).rounded()))
        output = try await SCScreenshotManager.captureScreenshot(
            contentFilter: filter,
            configuration: configuration
        )

    case let .window(candidate):
        let filter = SCContentFilter(desktopIndependentWindow: candidate.window)
        let info = SCShareableContent.info(for: filter)
        configuration.width = max(1, Int((info.contentRect.width * CGFloat(info.pointPixelScale)).rounded()))
        configuration.height = max(1, Int((info.contentRect.height * CGFloat(info.pointPixelScale)).rounded()))
        output = try await SCScreenshotManager.captureScreenshot(
            contentFilter: filter,
            configuration: configuration
        )
    }

    guard let image = output.sdrImage else { throw CaptureSupportError.missingImage }
    return image
}

@MainActor
func acquireFullDisplayScreenshot(for screen: NSScreen) async throws -> CGImage {
    guard let region = DisplayRegion(rect: screen.frame, screen: screen) else {
        throw CaptureSupportError.displayChanged
    }
    return try await acquireScreenshot(for: .region(region))
}

func frozenImagePixelRect(
    selection: CGRect,
    viewSize: CGSize,
    imageSize: CGSize
) -> CGRect? {
    guard selection.width > 0,
          selection.height > 0,
          viewSize.width > 0,
          viewSize.height > 0,
          imageSize.width > 0,
          imageSize.height > 0 else { return nil }
    let xScale = imageSize.width / viewSize.width
    let yScale = imageSize.height / viewSize.height
    let raw = CGRect(
        x: selection.minX * xScale,
        y: (viewSize.height - selection.maxY) * yScale,
        width: selection.width * xScale,
        height: selection.height * yScale
    ).integral
    let bounds = CGRect(origin: .zero, size: imageSize)
    let clipped = raw.intersection(bounds)
    return clipped.isNull || clipped.isEmpty ? nil : clipped
}

func cropFrozenImage(_ image: CGImage, selection: CGRect, viewSize: CGSize) throws -> CGImage {
    guard let rectangle = frozenImagePixelRect(
        selection: selection,
        viewSize: viewSize,
        imageSize: CGSize(width: image.width, height: image.height)
    ), let cropped = image.cropping(to: rectangle) else {
        throw CaptureSupportError.missingImage
    }
    return cropped
}

func runCaptureSupportSelfCheck() {
    let converted = displaySpaceRect(
        for: CGRect(x: 110, y: 220, width: 80, height: 50),
        displayFrame: CGRect(x: 100, y: 200, width: 1_000, height: 800),
        displayBounds: CGRect(x: 1_920, y: 0, width: 1_000, height: 800)
    )
    precondition(converted == CGRect(x: 1_930, y: 730, width: 80, height: 50))
    precondition(frozenImagePixelRect(
        selection: CGRect(x: 10, y: 70, width: 30, height: 20),
        viewSize: CGSize(width: 100, height: 100),
        imageSize: CGSize(width: 200, height: 200)
    ) == CGRect(x: 20, y: 20, width: 60, height: 40))
}

private func displaySpaceRect(for rect: CGRect, displayFrame: CGRect, displayBounds: CGRect) -> CGRect {
    CGRect(
        x: displayBounds.minX + rect.minX - displayFrame.minX,
        y: displayBounds.minY + displayFrame.maxY - rect.maxY,
        width: rect.width,
        height: rect.height
    )
}

private extension CGRect {
    var isFiniteAndNonempty: Bool {
        [minX, minY, maxX, maxY].allSatisfy(\.isFinite) && width > 0 && height > 0
    }

    func screenwrenApproximatelyEquals(_ other: CGRect) -> Bool {
        abs(minX - other.minX) < 0.001
            && abs(minY - other.minY) < 0.001
            && abs(width - other.width) < 0.001
            && abs(height - other.height) < 0.001
    }
}

@MainActor
private extension NSScreen {
    var screenwrenDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
