import AppKit
import Carbon.HIToolbox
import CoreGraphics
import CoreImage
import PaperKit
import PencilKit
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

private let subjectRenderContext = CIContext()

enum ImageActionError: Error {
    case couldNotRenderSubject
}

enum EditorError: Error {
    case couldNotRender
}

enum EditorKeyboardCommand: Equatable {
    case arrow
    case rectangle
    case highlighter
    case text
    case numberedStep
    case escape
    case copyAndClose
}

func editorKeyboardCommand(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags,
    isTextEntry: Bool,
    hasSheet: Bool,
    hasRegionOverlay: Bool
) -> EditorKeyboardCommand? {
    guard !isTextEntry, !hasSheet, !hasRegionOverlay else { return nil }
    let flags = modifiers.intersection([.command, .control, .option, .shift])
    if flags == .command,
       keyCode == UInt16(kVK_Return) || keyCode == UInt16(kVK_ANSI_KeypadEnter) {
        return .copyAndClose
    }
    guard flags.isEmpty else { return nil }
    return switch Int(keyCode) {
    case kVK_ANSI_A: .arrow
    case kVK_ANSI_R: .rectangle
    case kVK_ANSI_H: .highlighter
    case kVK_ANSI_T: .text
    case kVK_ANSI_N: .numberedStep
    case kVK_Escape: .escape
    default: nil
    }
}

func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
    CGRect(
        x: min(start.x, end.x),
        y: min(start.y, end.y),
        width: abs(end.x - start.x),
        height: abs(end.y - start.y)
    )
}

func loupePixel(
    at point: CGPoint,
    inside selection: CGRect,
    viewSize: CGSize,
    imageSize: CGSize
) -> CGPoint {
    guard viewSize.width > 0, viewSize.height > 0,
          imageSize.width > 0, imageSize.height > 0 else { return .zero }
    let xScale = imageSize.width / viewSize.width
    let yScale = imageSize.height / viewSize.height
    let x = !selection.isEmpty && point.x == selection.maxX ? point.x - (0.5 / xScale) : point.x
    let y = !selection.isEmpty && point.y == selection.maxY ? point.y - (0.5 / yScale) : point.y
    let pixelX = min(max(0, Int(floor(x * xScale))), Int(imageSize.width) - 1)
    let pixelYFromBottom = Int(floor(y * yScale))
    let pixelY = min(max(0, Int(imageSize.height) - 1 - pixelYFromBottom), Int(imageSize.height) - 1)
    return CGPoint(x: pixelX, y: pixelY)
}

func loupeCrosshairPoint(pixel: CGPoint, sample: CGRect, frame: CGRect) -> CGPoint {
    guard sample.width > 0, sample.height > 0 else { return CGPoint(x: frame.midX, y: frame.midY) }
    let xFraction = (pixel.x - sample.minX + 0.5) / sample.width
    let yFractionFromTop = (pixel.y - sample.minY + 0.5) / sample.height
    return CGPoint(
        x: frame.minX + xFraction * frame.width,
        y: frame.maxY - yFractionFromTop * frame.height
    )
}

func screenCaptureRect(from appKitRect: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
    CGRect(x: appKitRect.minX, y: primaryScreenMaxY - appKitRect.maxY, width: appKitRect.width, height: appKitRect.height)
}

func isCurrentCapture(_ requestedGeneration: UInt64, currentGeneration: UInt64) -> Bool {
    requestedGeneration == currentGeneration
}

func hotKeyIdentifiersMatch(_ expected: EventHotKeyID, _ received: EventHotKeyID) -> Bool {
    expected.signature == received.signature && expected.id == received.id
}

func editorImageRectangle(
    selection: CGRect,
    overlayBounds: CGRect,
    visibleImageFrame: CGRect,
    imageBounds: CGRect
) -> CGRect? {
    guard overlayBounds.width > 0, overlayBounds.height > 0 else { return nil }
    let contentRectangle = CGRect(
        x: visibleImageFrame.minX + selection.minX / overlayBounds.width * visibleImageFrame.width,
        y: visibleImageFrame.minY + selection.minY / overlayBounds.height * visibleImageFrame.height,
        width: selection.width / overlayBounds.width * visibleImageFrame.width,
        height: selection.height / overlayBounds.height * visibleImageFrame.height
    )
    let mapped = CGRect(
        x: contentRectangle.minX,
        y: imageBounds.minY + imageBounds.maxY - contentRectangle.maxY,
        width: contentRectangle.width,
        height: contentRectangle.height
    )
    let clipped = mapped.standardized.intersection(imageBounds).integral.intersection(imageBounds)
    return clipped.isNull || clipped.isEmpty ? nil : clipped
}

@MainActor
final class ClipboardDeliveryOrder {
    static let shared = ClipboardDeliveryOrder()
    private var generation: UInt64 = 0

    func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    func isCurrent(_ requestedGeneration: UInt64) -> Bool {
        requestedGeneration == generation
    }
}

func clipboardStateIsUnchanged(
    since changeCount: Int,
    on pasteboard: NSPasteboard = .general
) -> Bool {
    pasteboard.changeCount == changeCount
}

func readingOrderIndices(for boundingBoxes: [CGRect]) -> [Int] {
    let topToBottom = boundingBoxes.indices.sorted { lhs, rhs in
        let left = boundingBoxes[lhs]
        let right = boundingBoxes[rhs]
        if left.maxY != right.maxY { return left.maxY > right.maxY }
        if left.minX != right.minX { return left.minX < right.minX }
        return lhs < rhs
    }

    var rows: [(anchor: CGRect, indices: [Int])] = []
    for index in topToBottom {
        let box = boundingBoxes[index]
        if let last = rows.indices.last {
            let anchor = rows[last].anchor
            let verticalOverlap = min(anchor.maxY, box.maxY) - max(anchor.minY, box.minY)
            if verticalOverlap >= min(anchor.height, box.height) * 0.5 {
                rows[last].indices.append(index)
                continue
            }
        }
        rows.append((box, [index]))
    }

    return rows.flatMap { row in
        row.indices.sorted { lhs, rhs in
            if boundingBoxes[lhs].minX != boundingBoxes[rhs].minX {
                return boundingBoxes[lhs].minX < boundingBoxes[rhs].minX
            }
            return lhs < rhs
        }
    }
}

func recognizedText(in image: CGImage) async throws -> String {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.automaticallyDetectsLanguage = true
    let observations = try await request.perform(on: image)
    let order = readingOrderIndices(for: observations.map { $0.boundingRegion.boundingBox.cgRect })
    return order
        .map { observations[$0].transcript }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
}

func liftedSubject(in image: CGImage) async throws -> CGImage? {
    let handler = ImageRequestHandler(image)
    guard let observation = try await handler.perform(GenerateForegroundInstanceMaskRequest()),
          !observation.allInstances.isEmpty else { return nil }
    let buffer = try observation.generateMaskedImage(
        for: observation.allInstances,
        imageFrom: handler,
        croppedToInstancesExtent: true
    )
    let subject = CIImage(cvPixelBuffer: buffer)
    guard let image = subjectRenderContext.createCGImage(subject, from: subject.extent) else {
        throw ImageActionError.couldNotRenderSubject
    }
    return image
}

@MainActor
func runSelfCheck() {
    precondition(normalizedRect(from: CGPoint(x: 90, y: 70), to: CGPoint(x: 10, y: 20)) == CGRect(x: 10, y: 20, width: 80, height: 50))
    precondition(normalizedRect(from: .zero, to: CGPoint(x: 12, y: 8)) == CGRect(x: 0, y: 0, width: 12, height: 8))
    precondition(screenCaptureRect(from: CGRect(x: 10, y: 20, width: 80, height: 50), primaryScreenMaxY: 100) == CGRect(x: 10, y: 30, width: 80, height: 50))
    precondition(isCurrentCapture(4, currentGeneration: 4))
    precondition(!isCurrentCapture(4, currentGeneration: 5))
    precondition(hotKeyIdentifiersMatch(
        EventHotKeyID(signature: 0x5357524E, id: 2),
        EventHotKeyID(signature: 0x5357524E, id: 2)
    ))
    precondition(!hotKeyIdentifiersMatch(
        EventHotKeyID(signature: 0x5357524E, id: 2),
        EventHotKeyID(signature: 0x5357524E, id: 3)
    ))
    precondition(editorImageRectangle(
        selection: CGRect(x: 0, y: 80, width: 100, height: 20),
        overlayBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
        visibleImageFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
        imageBounds: CGRect(x: 0, y: 0, width: 100, height: 100)
    ) == CGRect(x: 0, y: 0, width: 100, height: 20))
    precondition(editorImageRectangle(
        selection: CGRect(x: 0, y: 80, width: 100, height: 20),
        overlayBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
        visibleImageFrame: CGRect(x: 0, y: 500, width: 100, height: 400),
        imageBounds: CGRect(x: 0, y: 0, width: 100, height: 1_000)
    ) == CGRect(x: 0, y: 100, width: 100, height: 80))
    runCaptureSupportSelfCheck()
    do {
        try runImageOperationsSelfCheck()
    } catch {
        fatalError("ScreenWren image self-check failed: \(error)")
    }
    precondition(timestampedPNGFilename(for: Date(timeIntervalSince1970: 0)).hasSuffix(".png"))

    do {
        _ = NSApplication.shared
        let qaDelegate = AppDelegate()
        qaDelegate.installMainMenu()
        let saveMenuItem = NSApp.mainMenu?.items
            .compactMap(\.submenu)
            .first(where: { $0.title == "File" })?
            .items.first(where: { $0.action == #selector(EditorViewController.saveDocument(_:)) })
        precondition(saveMenuItem?.keyEquivalent == "s")
        let fixture = try renderCGImage(width: 80, height: 60) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        }
        let editor = EditorViewController(image: fixture, initialStatus: "QA") { _ in }
        editor.loadViewIfNeeded()
        let menuTitles = Set(editor.makeMoreMenu().items.map(\.title))
        for expected in ["Review Suggested Redactions…", "Preview Structured Text…", "Redact…", "Blur (Not Secure)…", "Crop…", "Resize…", "Rotate Left", "Rotate Right", "Pin Above Windows", "Export PNG / JPEG…", "Save PNG Directly…"] {
            precondition(menuTitles.contains(expected), "Missing editor command: \(expected)")
        }
        precondition(menuTitles.contains(where: { $0.localizedCaseInsensitiveContains("share") }))
        let shareProvider = makePNGItemProvider(filename: "ScreenWren QA.png") { Data([0x89, 0x50, 0x4e, 0x47]) }
        precondition(shareProvider.registeredTypeIdentifiers.contains(UTType.png.identifier))
        precondition(NSSharingServicePicker(items: [shareProvider]).standardShareMenuItem.isEnabled)
        let pin = PinnedWindowController(image: fixture)
        precondition(pin.window is NSPanel)
        precondition(pin.window?.collectionBehavior.contains(.canJoinAllSpaces) == false)
        pin.close()
    } catch {
        fatalError("ScreenWren component self-check failed: \(error)")
    }
    print("ScreenWren self-check passed")
}

struct ScreenWrenStatus {
    let message: String
    var symbolName = "viewfinder"
    var badge: String? = nil
}

struct CaptureMenuState {
    var canRepeat = false
    var repeatTitle = "Repeat Last Capture"
    var hasTimedCapture = false
    var isScrolling = false
    var isStitching = false
    var scrollingSegments = 0
    var recentDates: [Date] = []
    var editorCount = 0
}

struct SendableImageBatch: @unchecked Sendable {
    let images: [CGImage]
}

struct SendableImage: @unchecked Sendable {
    let image: CGImage
}

private struct SendableImageTransform: @unchecked Sendable {
    let image: CGImage
    let transform: @Sendable (CGImage) throws -> CGImage
}

@MainActor
@main
enum ScreenWrenApp {
    static let delegate = AppDelegate()

    static func main() {
        if CommandLine.arguments.contains("--self-check") {
            runSelfCheck()
            return
        }

        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let captureCoordinator = CaptureCoordinator()
    private var statusItem: NSStatusItem?
    private var shortcutManager: ShortcutManager!
    private let launchAtLogin = LaunchAtLoginController()
    private var readinessWindow: ReadinessWindowController?
    private var workflowWindow: WorkflowPreferencesWindow?
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let statusImage = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "ScreenWren — Capture Region")
        statusImage?.isTemplate = true
        statusItem.button?.image = statusImage
        statusItem.button?.toolTip = "ScreenWren — Capture Region (⌃P)"

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        self.statusItem = statusItem

        shortcutManager = ShortcutManager(actions: [
            .capture: { [weak captureCoordinator] in captureCoordinator?.primaryAction() },
            .copyText: { [weak captureCoordinator] in captureCoordinator?.beginTextCapture() },
            .repeatCapture: { [weak captureCoordinator] in captureCoordinator?.repeatLastCapture() },
            .frontWindow: { [weak captureCoordinator] in captureCoordinator?.captureFrontWindow() },
            .freeze: { [weak captureCoordinator] in captureCoordinator?.beginFreezeCapture() },
            .recents: { [weak captureCoordinator] in captureCoordinator?.showRecentPicker() },
            .togglePins: { [weak captureCoordinator] in captureCoordinator?.togglePins() },
        ])
        shortcutManager.onChange = { [weak self] in
            self?.updateShortcutStatus()
            self?.rebuildMenu()
        }
        shortcutManager.registerAll()

        captureCoordinator.onStateChange = { [weak self] in self?.rebuildMenu() }
        captureCoordinator.onStatus = { [weak self] status in self?.showStatus(status) }
        captureCoordinator.onPermissionRequired = { [weak self] captureWasDenied in
            self?.showReadiness(captureWasDenied: captureWasDenied)
        }
        rebuildMenu()

        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--qa-capture") {
            guard arguments.indices.contains(flag + 1) else {
                fputs("ScreenWren: --qa-capture needs an output PNG path.\n", stderr)
                NSApp.terminate(nil)
                return
            }
            runQACapture(to: URL(fileURLWithPath: arguments[flag + 1]))
        } else if let flag = arguments.firstIndex(of: "--open-image") {
            guard arguments.indices.contains(flag + 1),
                  let image = NSImage(contentsOfFile: arguments[flag + 1]),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                fputs("ScreenWren: couldn’t open the image passed to --open-image.\n", stderr)
                NSApp.terminate(nil)
                return
            }
            DispatchQueue.main.async { [captureCoordinator] in
                captureCoordinator.openEditor(image: cgImage, copied: false)
            }
        }
        // Ordinary launches, including login launches, stay quiet until a command.
    }

    private func runQACapture(to outputURL: URL) {
        guard CGPreflightScreenCaptureAccess(), let screen = NSScreen.main else {
            fputs("ScreenWren QA: screen capture permission is unavailable.\n", stderr)
            NSApp.terminate(nil)
            return
        }
        let size = CGSize(width: min(120, screen.frame.width), height: min(80, screen.frame.height))
        let rect = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2, width: size.width, height: size.height)
        guard let region = DisplayRegion(rect: rect, screen: screen) else {
            fputs("ScreenWren QA: could not make a display region.\n", stderr)
            NSApp.terminate(nil)
            return
        }
        Task { @MainActor in
            do {
                let image = try await acquireScreenshot(for: .region(region))
                let expectedWidth = Int((size.width * screen.backingScaleFactor).rounded())
                let expectedHeight = Int((size.height * screen.backingScaleFactor).rounded())
                guard image.width == expectedWidth, image.height == expectedHeight else {
                    throw CaptureError.scrollingGeometryChanged
                }
                try pngData(for: image).write(to: outputURL, options: .atomic)
                print("ScreenWren QA capture passed: \(image.width) × \(image.height)")
                NSApp.terminate(nil)
            } catch {
                fputs("ScreenWren QA capture failed: \(error.localizedDescription)\n", stderr)
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return false
    }

    @objc private func capture() {
        captureCoordinator.primaryAction()
    }

    @objc private func captureText() {
        captureCoordinator.beginTextCapture()
    }

    @objc private func repeatCapture() {
        captureCoordinator.repeatLastCapture()
    }

    @objc private func captureFrontWindow() {
        captureCoordinator.captureFrontWindow()
    }

    @objc private func freezeScreen() {
        captureCoordinator.beginFreezeCapture()
    }

    @objc private func timedCapture() {
        captureCoordinator.beginTimedCapture()
    }

    @objc private func cancelTimedCapture() {
        captureCoordinator.cancelTimedCapture()
    }

    @objc private func startScrollingCapture() {
        captureCoordinator.beginScrollingCapture()
    }

    @objc private func finishScrollingCapture() {
        captureCoordinator.finishScrollingCapture()
    }

    @objc private func cancelScrollingCapture() {
        captureCoordinator.cancelScrollingCapture()
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        captureCoordinator.openRecent(at: sender.tag)
    }

    @objc private func clearRecents() {
        captureCoordinator.clearRecents()
    }

    @objc private func showEditors() {
        captureCoordinator.showEditors()
    }

    @objc private func openWorkflowPreferences() {
        if workflowWindow == nil { workflowWindow = WorkflowPreferencesWindow() }
        workflowWindow?.showWindow(nil)
        workflowWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func showRecentPicker() { captureCoordinator.showRecentPicker() }
    @objc private func togglePins() { captureCoordinator.togglePins() }
    @objc private func unlockPins() { captureCoordinator.unlockPins() }
    @objc private func structuredTextCapture() { captureCoordinator.beginStructuredTextCapture() }

    @objc private func openReadiness() {
        showReadiness()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func item(
        _ title: String,
        action: Selector,
        shortcut command: ShortcutCommand? = nil,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let configured = command.flatMap { shortcutManager?.shortcut(for: $0) }
        let item = NSMenuItem(title: title, action: action, keyEquivalent: configured?.keyEquivalent ?? key)
        item.keyEquivalentModifierMask = configured?.modifierFlags ?? modifiers
        item.target = self
        return item
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let state = captureCoordinator.menuState

        let captureItem = item(
            state.isScrolling ? "Add Scrolling Segment" : "Capture Region or Window…",
            action: #selector(capture),
            shortcut: .capture
        )
        captureItem.isEnabled = !state.isStitching
        menu.addItem(captureItem)
        let frontWindowItem = item("Capture Front Window Now", action: #selector(captureFrontWindow), shortcut: .frontWindow)
        frontWindowItem.isEnabled = !state.isScrolling
        menu.addItem(frontWindowItem)
        let freezeItem = item("Freeze Screen & Select…", action: #selector(freezeScreen), shortcut: .freeze)
        freezeItem.isEnabled = !state.isScrolling
        menu.addItem(freezeItem)
        let textItem = item("Copy Text from Region…", action: #selector(captureText), shortcut: .copyText)
        textItem.isEnabled = !state.isScrolling
        menu.addItem(textItem)
        let structuredText = item("Capture Text With Preview…", action: #selector(structuredTextCapture))
        structuredText.isEnabled = !state.isScrolling
        menu.addItem(structuredText)
        let repeatItem = item(state.repeatTitle, action: #selector(repeatCapture), shortcut: .repeatCapture)
        repeatItem.isEnabled = state.canRepeat && !state.isScrolling
        menu.addItem(repeatItem)
        let timedItem = item("Timed Capture (3 Seconds)…", action: #selector(timedCapture))
        timedItem.isEnabled = !state.isScrolling
        menu.addItem(timedItem)
        if state.hasTimedCapture {
            menu.addItem(item("Cancel Timed Capture", action: #selector(cancelTimedCapture)))
        }

        menu.addItem(.separator())
        if state.isScrolling {
            if state.isStitching {
                let stitching = NSMenuItem(title: "Stitching \(state.scrollingSegments) Segments…", action: nil, keyEquivalent: "")
                stitching.isEnabled = false
                menu.addItem(stitching)
            } else {
                menu.addItem(item("Finish Scrolling Capture (\(state.scrollingSegments) Segments)", action: #selector(finishScrollingCapture)))
                menu.addItem(item("Cancel Scrolling Capture", action: #selector(cancelScrollingCapture)))
            }
        } else {
            menu.addItem(item("Start Scrolling Capture…", action: #selector(startScrollingCapture)))
        }

        menu.addItem(item("Browse Recent Captures…", action: #selector(showRecentPicker), shortcut: .recents))
        menu.addItem(item("Hide / Restore All Pins", action: #selector(togglePins), shortcut: .togglePins))
        menu.addItem(item("Unlock All Pins", action: #selector(unlockPins)))
        let recentsItem = NSMenuItem(title: "Recents — Session Only", action: nil, keyEquivalent: "")
        let recentsMenu = NSMenu()
        if state.recentDates.isEmpty {
            let empty = NSMenuItem(title: "No Recent Captures", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentsMenu.addItem(empty)
        } else {
            for (index, date) in state.recentDates.enumerated() {
                let title = date.formatted(date: .omitted, time: .standard)
                let recent = item(title, action: #selector(openRecent(_:)))
                recent.tag = index
                recent.image = captureCoordinator.recentThumbnail(at: index)
                recentsMenu.addItem(recent)
            }
            recentsMenu.addItem(.separator())
            recentsMenu.addItem(item("Clear Recents", action: #selector(clearRecents)))
        }
        recentsItem.submenu = recentsMenu
        menu.addItem(recentsItem)

        menu.addItem(.separator())
        let editorsItem = item("Show Open Editors (\(state.editorCount))", action: #selector(showEditors))
        editorsItem.isEnabled = state.editorCount > 0
        menu.addItem(editorsItem)
        menu.addItem(item("Capture Preferences…", action: #selector(openWorkflowPreferences)))
        menu.addItem(item("ScreenWren Readiness…", action: #selector(openReadiness)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ScreenWren", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func showStatus(_ status: ScreenWrenStatus) {
        guard let button = statusItem?.button else { return }
        button.toolTip = status.message
        if let badge = status.badge {
            button.image = nil
            button.title = badge
        } else {
            button.title = ""
            let image = NSImage(systemSymbolName: status.symbolName, accessibilityDescription: status.message)
            image?.isTemplate = true
            button.image = image
        }
    }

    private func updateShortcutStatus() {
        guard let button = statusItem?.button else { return }
        if shortcutManager.failures.isEmpty {
            let image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "ScreenWren — Capture Region")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "ScreenWren — ready"
        } else {
            let image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "ScreenWren — shortcut unavailable")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "ScreenWren — open Readiness to fix a shortcut"
        }
    }

    private func showReadiness(captureWasDenied: Bool = false) {
        if readinessWindow == nil {
            let readiness = ReadinessWindowController(
                shortcutManager: shortcutManager,
                launchAtLogin: launchAtLogin
            )
            readiness.onTryCapture = { [weak captureCoordinator] in captureCoordinator?.primaryAction() }
            readinessWindow = readiness
        }
        if captureWasDenied { readinessWindow?.capturePermissionWasDenied() }
        readinessWindow?.show()
    }

    func installMainMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        mainMenu.addItem(applicationItem)
        let applicationMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openReadiness), keyEquivalent: ",")
        settingsItem.target = self
        applicationMenu.addItem(settingsItem)
        let capturePreferences = NSMenuItem(title: "Capture Preferences…", action: #selector(openWorkflowPreferences), keyEquivalent: ",")
        capturePreferences.keyEquivalentModifierMask = [.command, .option]
        capturePreferences.target = self
        applicationMenu.addItem(capturePreferences)
        let recentPicker = NSMenuItem(title: "Browse Recent Captures…", action: #selector(showRecentPicker), keyEquivalent: "")
        recentPicker.target = self; applicationMenu.addItem(recentPicker)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(NSMenuItem(title: "Quit ScreenWren", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        applicationItem.submenu = applicationMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Export Image…", action: #selector(EditorViewController.saveDocument(_:)), keyEquivalent: "s")
        let copyAndClose = fileMenu.addItem(
            withTitle: "Copy and Close",
            action: #selector(EditorViewController.copyAndClose(_:)),
            keyEquivalent: "\r"
        )
        copyAndClose.keyEquivalentModifierMask = [.command]
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        NSApp.mainMenu = mainMenu
    }
}

final class HotKey: @unchecked Sendable {
    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private let hotKeyIdentifier: EventHotKeyID
    private let action: @MainActor @Sendable () -> Void

    init?(identifier: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor @Sendable () -> Void) {
        hotKeyIdentifier = EventHotKeyID(signature: 0x5357524E, id: identifier) // SWRN
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                var pressedIdentifier = EventHotKeyID()
                var actualSize = 0
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    &actualSize,
                    &pressedIdentifier
                )
                guard parameterStatus == noErr,
                      hotKeyIdentifiersMatch(hotKey.hotKeyIdentifier, pressedIdentifier) else {
                    return OSStatus(eventNotHandledErr)
                }
                Task { @MainActor in hotKey.action() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        guard handlerStatus == noErr else { return nil }

        let registrationStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyIdentifier,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &hotKeyRef
        )

        guard registrationStatus == noErr else {
            if let eventHandler { RemoveEventHandler(eventHandler) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

@MainActor
final class CaptureCoordinator: NSObject {
    typealias RecentCapture = SessionCapture

    struct ScrollingSession {
        let region: DisplayRegion
        var images: [CGImage]
        var estimatedOutputHeight: Int
    }

    var onStateChange: (() -> Void)?
    var onStatus: ((ScreenWrenStatus) -> Void)?
    var onPermissionRequired: ((Bool) -> Void)?
    private var selectionWindow: SelectionWindowController?
    private var editors: [EditorWindowController] = []
    private var pins: [PinnedWindowController] = []
    private var applicationToRestore: NSRunningApplication?
    private var generation: UInt64 = 0
    private var lastTarget: RepeatTarget?
    private var recents: [RecentCapture] = []
    private var timedTask: Task<Void, Never>?
    private var scrollingSession: ScrollingSession?
    private var isStitching = false
    private var recentPicker: RecentPickerWindow?
    private var quickCapture: QuickCaptureWindow?
    private var auxiliaryWindows: [NSWindowController] = []
    private var combinationTask: Task<Void, Never>?
    private var pinsAreHidden = false
    private let preferences: WorkflowPreferences
    private let pasteboard: NSPasteboard
    private let recentMemoryLimit: Int
    var recentCaptures: [SessionCapture] { recents }

    init(preferences: WorkflowPreferences = .shared, pasteboard: NSPasteboard = .general,
         recentMemoryLimit: Int = 128 * 1_024 * 1_024) {
        self.preferences = preferences
        self.pasteboard = pasteboard
        self.recentMemoryLimit = recentMemoryLimit
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cancelSelection),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    var menuState: CaptureMenuState {
        CaptureMenuState(
            canRepeat: lastTarget.map { target in
                if case let .region(region) = target { return region.isValid }
                if case let .desktop(region) = target { return region.isValid }
                return true
            } ?? false,
            repeatTitle: lastTarget?.menuTitle ?? "Repeat Last Capture",
            hasTimedCapture: timedTask != nil,
            isScrolling: scrollingSession != nil,
            isStitching: isStitching,
            scrollingSegments: scrollingSession?.images.count ?? 0,
            recentDates: recents.map(\.date),
            editorCount: editors.count
        )
    }

    func primaryAction() {
        if selectionWindow != nil { cancelSelection() }
        else if isStitching { announce("Wait for scrolling stitch to finish", beep: true) }
        else if scrollingSession != nil { addScrollingSegment() }
        else { beginSelection(intent: .image) }
    }

    @objc private func cancelSelection() {
        guard let selectionWindow else { return }
        selectionWindow.cancel()
        _ = supersedePendingCapture()
    }

    func beginStructuredTextCapture() {
        guard scrollingSession == nil else { return }
        beginSelection(intent: .structuredText)
    }

    func beginTextCapture() {
        guard scrollingSession == nil else {
            announce("Finish or cancel scrolling capture first", beep: true)
            return
        }
        beginSelection(intent: .text)
    }

    func beginTimedCapture() {
        guard scrollingSession == nil else {
            announce("Finish or cancel scrolling capture first", beep: true)
            return
        }
        beginSelection(intent: .delayedImage(seconds: 3))
    }

    func beginScrollingCapture() {
        guard scrollingSession == nil else { return }
        beginSelection(intent: .scrolling)
    }

    func captureFrontWindow() {
        guard scrollingSession == nil else {
            announce("Finish or cancel scrolling capture first", beep: true)
            return
        }
        guard requireScreenCapturePermission() else { return }
        selectionWindow?.cancel()
        let captureGeneration = supersedePendingCapture()
        let clipboardGeneration = ClipboardDeliveryOrder.shared.begin()
        let clipboardChangeCount = pasteboard.changeCount
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let candidate = try await WindowCandidate.eligible().first else {
                    self.announce("No capturable front window found", beep: true)
                    return
                }
                guard isCurrentCapture(captureGeneration, currentGeneration: self.generation) else { return }
                await self.capture(
                    target: .window(candidate),
                    intent: .image,
                    generation: captureGeneration,
                    clipboardGeneration: clipboardGeneration,
                    clipboardChangeCount: clipboardChangeCount,
                    rememberTarget: true
                )
            } catch {
                guard isCurrentCapture(captureGeneration, currentGeneration: self.generation) else { return }
                self.reportCaptureError(error)
            }
        }
    }

    func beginFreezeCapture() {
        guard scrollingSession == nil else {
            announce("Finish or cancel scrolling capture first", beep: true)
            return
        }
        guard requireScreenCapturePermission() else { return }
        selectionWindow?.cancel()
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else { return }
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let restoreApplication = frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : frontmostApplication
        let captureGeneration = supersedePendingCapture()
        let clipboardGeneration = ClipboardDeliveryOrder.shared.begin()
        let clipboardChangeCount = pasteboard.changeCount
        let destination = preferences.destination
        quickCapture?.close()
        announce("Freezing screen…", symbol: "snowflake")

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let frozenImage = try await acquireFullDisplayScreenshot(for: screen)
                guard isCurrentCapture(captureGeneration, currentGeneration: self.generation) else { return }
                let controller = SelectionWindowController(
                    screen: screen,
                    prompt: "Select from the frozen screen",
                    allowsWindows: false,
                    backgroundImage: frozenImage
                ) { [weak self] target in
                    guard let self else { return }
                    self.selectionWindow = nil
                    guard isCurrentCapture(captureGeneration, currentGeneration: self.generation) else { return }
                    guard case let .region(region) = target else {
                        restoreApplication?.activate(options: [])
                        self.announce("Frozen capture cancelled")
                        self.onStateChange?()
                        return
                    }
                    do {
                        let localSelection = region.rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
                        let image = try cropFrozenImage(
                            frozenImage,
                            selection: localSelection,
                            viewSize: screen.frame.size
                        )
                        restoreApplication?.activate(options: [])
                        self.finishImageCapture(image, scale: screen.backingScaleFactor, destination: destination,
                            clipboardGeneration: clipboardGeneration, clipboardChangeCount: clipboardChangeCount)
                        self.lastTarget = .region(region)
                        self.onStateChange?()
                    } catch {
                        restoreApplication?.activate(options: [])
                        self.reportCaptureError(error)
                    }
                }
                self.selectionWindow = controller
                controller.show()
            } catch {
                guard isCurrentCapture(captureGeneration, currentGeneration: self.generation) else { return }
                self.reportCaptureError(error)
            }
        }
    }

    private func beginSelection(intent: CaptureIntent) {
        let applicationFromSupersededSelector: NSRunningApplication?
        if let activeSelection = selectionWindow {
            applicationFromSupersededSelector = applicationToRestore
            activeSelection.cancel()
        } else {
            applicationFromSupersededSelector = nil
        }

        guard requireScreenCapturePermission() else { return }

        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else { return }
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        applicationToRestore = applicationFromSupersededSelector
            ?? (frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : frontmostApplication)
        let captureGeneration = supersedePendingCapture()
        let clipboardGeneration = ClipboardDeliveryOrder.shared.begin()
        let clipboardChangeCount = pasteboard.changeCount
        let prompt: String
        switch intent {
        case .image: prompt = "Drag to capture a region"
        case .text, .structuredText: prompt = "Drag around text"
        case .delayedImage: prompt = "Select where the menu or tooltip will appear"
        case .scrolling: prompt = "Drag the scrolling viewport"
        }
        let allowsWindowSnap: Bool
        switch intent {
        case .image, .text, .structuredText: allowsWindowSnap = true
        case .delayedImage, .scrolling: allowsWindowSnap = false
        }

        let controller = SelectionWindowController(
            screen: screen,
            prompt: prompt,
            allowsWindows: allowsWindowSnap,
            spansDisplays: intent != .scrolling
        ) { [weak self] target in
            guard let self else { return }
            self.selectionWindow = nil
            let restoreApplication = self.applicationToRestore
            self.applicationToRestore = nil
            guard let target else {
                restoreApplication?.activate(options: [])
                self.announce("Capture cancelled")
                self.onStateChange?()
                return
            }
            guard isCurrentCapture(captureGeneration, currentGeneration: self.generation) else { return }

            switch intent {
            case let .delayedImage(seconds):
                restoreApplication?.activate(options: [])
                self.armTimedCapture(
                    target: target,
                    seconds: seconds,
                    generation: captureGeneration,
                    clipboardGeneration: clipboardGeneration,
                    clipboardChangeCount: clipboardChangeCount
                )
            case .text, .structuredText:
                restoreApplication?.activate(options: [])
                Task { @MainActor in
                    await Task.yield()
                    await self.capture(
                        target: target,
                        intent: intent,
                        generation: captureGeneration,
                        clipboardGeneration: clipboardGeneration,
                        clipboardChangeCount: clipboardChangeCount,
                        rememberTarget: false
                    )
                }
            case .scrolling:
                restoreApplication?.activate(options: [])
                Task { @MainActor in
                    await Task.yield()
                    await self.startScrollingSession(target: target, generation: captureGeneration)
                }
            case .image:
                restoreApplication?.activate(options: [])
                Task { @MainActor in
                    await Task.yield()
                    await self.capture(
                        target: target,
                        intent: .image,
                        generation: captureGeneration,
                        clipboardGeneration: clipboardGeneration,
                        clipboardChangeCount: clipboardChangeCount,
                        rememberTarget: true
                    )
                }
            }
        }
        controller.onLoupeNeeded = { [weak self, weak controller] display in
            guard let self, let controller else { return }
            self.loadLoupe(for: display, controller: controller, generation: captureGeneration)
        }
        quickCapture?.close()
        selectionWindow = controller
        controller.show()

        guard intent != .scrolling else { return }
        Task { @MainActor [weak self, weak controller] in
            do {
                let candidates = try await WindowCandidate.eligible()
                guard let self,
                      let controller,
                      isCurrentCapture(captureGeneration, currentGeneration: self.generation),
                      self.selectionWindow === controller else { return }
                controller.updateWindowCandidates(candidates)
            } catch {
                // Region selection stays live when optional window enumeration fails.
                guard isScreenCapturePermissionError(error), let self, let controller,
                      isCurrentCapture(captureGeneration, currentGeneration: self.generation),
                      self.selectionWindow === controller else { return }
                self.reportCaptureError(error)
            }
        }

    }

    private func loadLoupe(for display: NSScreen, controller: SelectionWindowController, generation captureGeneration: UInt64) {
        Task { @MainActor [weak self, weak controller] in
            do {
                let image = try await acquireFullDisplayScreenshot(for: display)
                guard let self, let controller,
                      isCurrentCapture(captureGeneration, currentGeneration: self.generation),
                      self.selectionWindow === controller else { return }
                controller.updateLoupeImage(image, for: display)
            } catch {
                guard isScreenCapturePermissionError(error), let self, let controller,
                      isCurrentCapture(captureGeneration, currentGeneration: self.generation),
                      self.selectionWindow === controller else { return }
                self.reportCaptureError(error)
            }
        }
    }

    func repeatLastCapture() {
        guard scrollingSession == nil else { return }
        selectionWindow?.cancel()
        guard requireScreenCapturePermission() else { return }
        guard let repeatTarget = lastTarget else {
            onStateChange?()
            announce("Capture a region or window first", beep: true)
            return
        }
        let captureGeneration = supersedePendingCapture()
        let clipboardGeneration = ClipboardDeliveryOrder.shared.begin()
        let clipboardChangeCount = pasteboard.changeCount
        Task { @MainActor [weak self] in
            guard let self else { return }
            let target: SelectionTarget
            do {
                switch repeatTarget {
                case let .desktop(region):
                    guard region.isValid else { throw CaptureSupportError.displayChanged }
                    target = .desktop(region)
                case let .region(region):
                    guard region.isValid else {
                        self.lastTarget = nil
                        self.onStateChange?()
                        self.announce("The display changed — select the region again", beep: true)
                        return
                    }
                    target = .region(region)
                case let .window(identity):
                    guard let window = try await WindowCandidate.resolve(identity) else {
                        self.announce("That exact window is no longer available", beep: true)
                        return
                    }
                    target = .window(window)
                }
                guard isCurrentCapture(captureGeneration, currentGeneration: self.generation) else { return }
                await self.capture(
                    target: target,
                    intent: .image,
                    generation: captureGeneration,
                    clipboardGeneration: clipboardGeneration,
                    clipboardChangeCount: clipboardChangeCount,
                    rememberTarget: false
                )
            } catch {
                guard isCurrentCapture(captureGeneration, currentGeneration: self.generation) else { return }
                self.reportCaptureError(error)
            }
        }
    }

    private func armTimedCapture(
        target: SelectionTarget,
        seconds: TimeInterval,
        generation: UInt64,
        clipboardGeneration: UInt64,
        clipboardChangeCount: Int
    ) {
        timedTask?.cancel()
        let wholeSeconds = max(1, Int(seconds.rounded()))
        timedTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.onStateChange?()
            for remaining in stride(from: wholeSeconds, through: 1, by: -1) {
                guard !Task.isCancelled, isCurrentCapture(generation, currentGeneration: self.generation) else { return }
                self.announce("Timed capture in \(remaining)", badge: "\(remaining)")
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled, isCurrentCapture(generation, currentGeneration: self.generation) else { return }
            self.timedTask = nil
            self.onStateChange?()
            await self.capture(
                target: target,
                intent: .image,
                generation: generation,
                clipboardGeneration: clipboardGeneration,
                clipboardChangeCount: clipboardChangeCount,
                rememberTarget: true
            )
        }
    }

    func cancelTimedCapture() {
        guard timedTask != nil else { return }
        generation &+= 1
        timedTask?.cancel()
        timedTask = nil
        onStateChange?()
        announce("Timed capture cancelled")
    }

    private func capture(
        target: SelectionTarget,
        intent: CaptureIntent,
        generation captureGeneration: UInt64,
        clipboardGeneration: UInt64,
        clipboardChangeCount: Int,
        rememberTarget: Bool
    ) async {
        let destination = preferences.destination
        do {
            let image = try await acquireScreenshot(for: target)
            guard isCurrentCapture(captureGeneration, currentGeneration: generation) else { return }

            switch intent {
            case .text:
                let text = try await recognizedText(in: image)
                guard isCurrentCapture(captureGeneration, currentGeneration: generation) else { return }
                guard ClipboardDeliveryOrder.shared.isCurrent(clipboardGeneration) else {
                    announce("Copy superseded by a newer action")
                    return
                }
                guard clipboardStateIsUnchanged(since: clipboardChangeCount, on: pasteboard) else {
                    announce("Newer clipboard content preserved")
                    return
                }
                guard !text.isEmpty else {
                    announce("No text found", beep: true)
                    return
                }
                pasteboard.clearContents()
                guard pasteboard.setString(text, forType: .string) else {
                    throw CaptureError.clipboardWriteFailed
                }
                announce("Text copied — \(text.count) characters", symbol: "text.viewfinder")

            case .structuredText:
                showTextPreview(image)
            case .image, .delayedImage:
                finishImageCapture(image, scale: target.pixelScale, destination: destination,
                    clipboardGeneration: clipboardGeneration, clipboardChangeCount: clipboardChangeCount)
                if rememberTarget { lastTarget = RepeatTarget(target) }
                onStateChange?()

            case .scrolling:
                break
            }
        } catch is CancellationError {
        } catch {
            guard isCurrentCapture(captureGeneration, currentGeneration: generation) else { return }
            reportCaptureError(error)
        }
    }

    private func deliverImage(_ image: CGImage) throws {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        pasteboard.clearContents()
        guard pasteboard.writeObjects([nsImage]) else {
            throw CaptureError.clipboardWriteFailed
        }
    }

    private func startScrollingSession(target: SelectionTarget, generation captureGeneration: UInt64) async {
        guard case let .region(region) = target else {
            announce("Scrolling capture needs a region", beep: true)
            return
        }
        do {
            let image = try await acquireScreenshot(for: target)
            guard isCurrentCapture(captureGeneration, currentGeneration: generation) else { return }
            _ = try checkedScrollingMemoryUsage(currentBytes: 0, adding: uncompressedByteEstimate(for: image))
            let outputHeight = try checkedScrollingOutputHeight(
                width: image.width,
                currentHeight: 0,
                frameHeight: image.height,
                overlap: 0
            )
            scrollingSession = ScrollingSession(region: region, images: [image], estimatedOutputHeight: outputHeight)
            announce("Scrolling segment 1 added — scroll down with overlap, then press ⌃P", symbol: "rectangle.stack")
            onStateChange?()
        } catch {
            guard isCurrentCapture(captureGeneration, currentGeneration: generation) else { return }
            reportCaptureError(error)
        }
    }

    private func addScrollingSegment() {
        guard !isStitching, let session = scrollingSession else { return }
        guard session.images.count < 20 else {
            announce("Scrolling capture is limited to 20 segments", beep: true)
            return
        }
        guard session.region.isValid else {
            cancelScrollingCapture(message: "Display changed — scrolling capture cancelled")
            return
        }
        let captureGeneration = supersedePendingCapture(cancelTimed: false)
        announce("Capturing scrolling segment…", symbol: "rectangle.stack")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let image = try await acquireScreenshot(for: .region(session.region))
                guard isCurrentCapture(captureGeneration, currentGeneration: self.generation),
                      var current = self.scrollingSession,
                      let first = current.images.first,
                      let previous = current.images.last,
                      image.width == first.width,
                      image.height == first.height else { throw CaptureError.scrollingGeometryChanged }
                let pair = SendableImageBatch(images: [previous, image])
                let frameIndex = current.images.count
                let overlap = try await Task.detached(priority: .userInitiated) {
                    try validatedScrollingOverlap(
                        previous: pair.images[0],
                        next: pair.images[1],
                        newFrameIndex: frameIndex
                    )
                }.value
                guard isCurrentCapture(captureGeneration, currentGeneration: self.generation) else { return }
                let projectedHeight = try checkedScrollingOutputHeight(
                    width: image.width,
                    currentHeight: current.estimatedOutputHeight,
                    frameHeight: image.height,
                    overlap: overlap
                )
                let usedBytes = try current.images.reduce(0) {
                    try checkedScrollingMemoryUsage(currentBytes: $0, adding: uncompressedByteEstimate(for: $1))
                }
                _ = try checkedScrollingMemoryUsage(currentBytes: usedBytes, adding: uncompressedByteEstimate(for: image))
                current.images.append(image)
                current.estimatedOutputHeight = projectedHeight
                self.scrollingSession = current
                self.announce("Scrolling segment \(current.images.count) added — scroll down with overlap", symbol: "rectangle.stack")
                self.onStateChange?()
            } catch {
                guard isCurrentCapture(captureGeneration, currentGeneration: self.generation) else { return }
                self.reportCaptureError(error)
            }
        }
    }

    func finishScrollingCapture() {
        guard !isStitching else {
            announce("Scrolling capture is already stitching", beep: true)
            return
        }
        guard let session = scrollingSession, session.images.count >= 2 else {
            announce("Add at least two scrolling segments", beep: true)
            return
        }
        let captureGeneration = supersedePendingCapture(cancelTimed: false)
        isStitching = true
        onStateChange?()
        announce("Stitching \(session.images.count) segments…", symbol: "rectangle.stack")
        let batch = SendableImageBatch(images: session.images)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isStitching = false
                self.onStateChange?()
            }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    SendableImage(image: try stitchCGImagesVertically(batch.images))
                }.value
                let image = result.image
                guard isCurrentCapture(captureGeneration, currentGeneration: self.generation) else { return }
                self.scrollingSession = nil
                self.openEditor(image: image, copied: false)
                self.announce("Scrolling capture ready — review before copying", symbol: "rectangle.stack")
                self.onStateChange?()
            } catch {
                guard isCurrentCapture(captureGeneration, currentGeneration: self.generation) else { return }
                self.reportCaptureError(error)
            }
        }
    }

    func cancelScrollingCapture() {
        cancelScrollingCapture(message: "Scrolling capture cancelled")
    }

    private func cancelScrollingCapture(message: String) {
        guard scrollingSession != nil else { return }
        guard !isStitching else {
            announce("Wait for scrolling stitch to finish", beep: true)
            return
        }
        generation &+= 1
        scrollingSession = nil
        announce(message)
        onStateChange?()
    }

    func openRecent(at index: Int) {
        guard recents.indices.contains(index) else { return }
        openEditor(image: recents[index].image, copied: false, sourceScale: recents[index].scale)
        announce("Recent capture reopened")
    }

    func recentThumbnail(at index: Int) -> NSImage? {
        guard recents.indices.contains(index) else { return nil }
        let image = recents[index].image
        let maxSize = NSSize(width: 40, height: 24)
        let scale = min(maxSize.width / CGFloat(image.width), maxSize.height / CGFloat(image.height), 1)
        return NSImage(
            cgImage: image,
            size: NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        )
    }

    func clearRecents() {
        combinationTask?.cancel()
        recents.removeAll()
        recentPicker?.update(recents)
        quickCapture?.close()
        onStateChange?()
        announce("Recents cleared")
    }

    func showEditors() {
        guard !editors.isEmpty else { return }
        editors.forEach { $0.showWindow(nil) }
        editors.last?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        announce("Showing \(editors.count) editor\(editors.count == 1 ? "" : "s")")
    }

    @discardableResult
    private func addRecent(_ image: CGImage, scale: CGFloat = 1) -> Bool {
        let recent = RecentCapture(image: image, date: Date(), scale: scale)
        guard recent.byteCount <= recentMemoryLimit else { return false }
        recents.insert(recent, at: 0)
        while recents.count > 5 || recents.reduce(0, { $0 + $1.byteCount }) > recentMemoryLimit {
            recents.removeLast()
        }
        recentPicker?.update(recents)
        return true
    }

    private func supersedePendingCapture(cancelTimed: Bool = true) -> UInt64 {
        generation &+= 1
        combinationTask?.cancel()
        if cancelTimed {
            timedTask?.cancel()
            timedTask = nil
        }
        onStateChange?()
        return generation
    }

    private func requireScreenCapturePermission() -> Bool {
        guard CGPreflightScreenCaptureAccess() else {
            showPermissionRecovery(captureWasDenied: false)
            return false
        }
        return true
    }

    private func reportCaptureError(_ error: Error) {
        guard isScreenCapturePermissionError(error) else {
            announce(error.localizedDescription, beep: true)
            return
        }
        showPermissionRecovery(captureWasDenied: true)
    }

    private func showPermissionRecovery(captureWasDenied: Bool) {
        cancelSelection()
        scrollingSession = nil
        _ = supersedePendingCapture()
        invalidateRegionCaptureFilters()
        onPermissionRequired?(captureWasDenied)
        announce("Screen access is unavailable — check permission, then quit and reopen", symbol: "exclamationmark.triangle")
    }

    @objc private func screenParametersChanged() {
        generation &+= 1
        invalidateRegionCaptureFilters()
        let activeSelection = selectionWindow
        selectionWindow = nil
        activeSelection?.cancel()
        if case .region = lastTarget { lastTarget = nil }
        if case .desktop = lastTarget { lastTarget = nil }
        if timedTask != nil { cancelTimedCapture() }
        if scrollingSession != nil {
            if isStitching {
                scrollingSession = nil
                announce("Display changed — scrolling capture cancelled")
            } else {
                cancelScrollingCapture(message: "Display changed — scrolling capture cancelled")
            }
        }
        onStateChange?()
    }

    func openEditor(image: CGImage, copied: Bool, sourceScale: CGFloat = 1) {
        let editor = EditorWindowController(image: image, copied: copied, sourceScale: sourceScale) { [weak self] image in
            self?.pin(image: image, sourceScale: sourceScale)
        }
        editor.onClose = { [weak self, weak editor] in
            guard let editor else { return }
            self?.editors.removeAll { $0 === editor }
            self?.onStateChange?()
        }
        editors.append(editor)
        onStateChange?()
        editor.showWindow(nil)
        NSApp.activate()
    }

    private func pin(image: CGImage, sourceScale: CGFloat = 1) {
        let pin = PinnedWindowController(image: image, sourceScale: sourceScale)
        pin.onClose = { [weak self, weak pin] in
            guard let pin else { return }
            self?.pins.removeAll { $0 === pin }
        }
        pins.append(pin)
        if pins.count > 5 {
            pins.removeFirst().close()
        }
        if !pinsAreHidden { pin.showWindow(nil) }
        announce("Pinned above windows", symbol: "pin")
    }

    func finishImageCapture(_ image: CGImage, scale: CGFloat, destination: CaptureDestination,
                                    clipboardGeneration: UInt64, clipboardChangeCount: Int) {
        if destination == .review {
            showRedactionReview(image, scale: scale)
            announce("Review the capture before copying", symbol: "eye")
            return
        }
        let clipboardEligible = ClipboardDeliveryOrder.shared.isCurrent(clipboardGeneration) && clipboardStateIsUnchanged(since: clipboardChangeCount, on: pasteboard)
        var copied = false
        if destination.copiesImmediately && clipboardEligible {
            do { try deliverImage(image); copied = true } catch {}
        }
        let retained = addRecent(image, scale: scale)
        switch destination {
        case .clipboard:
            if !copied && (clipboardEligible || !retained) {
                openEditor(image: image, copied: false, sourceScale: scale)
            }
        case .editor: openEditor(image: image, copied: copied, sourceScale: scale)
        case .pin: pin(image: image, sourceScale: scale)
        case .save: showExport(image, scale: scale)
        case .review: break
        }
        if preferences.showsThumbnail && destination == .clipboard {
            quickCapture?.close()
            quickCapture = QuickCaptureWindow(image: image) { [weak self] action in self?.actOnImage(action, image: image, scale: scale) }
            quickCapture?.onClose = { [weak self] in self?.quickCapture = nil }
            quickCapture?.present()
        }
        announce(copied ? "Captured and copied" : (destination.copiesImmediately ? "Capture ready — clipboard unchanged" : "Capture ready"))
        onStateChange?()
    }

    private func actOnImage(_ action: RecentAction, image: CGImage, scale: CGFloat) {
        switch action {
        case .copy:
            _ = ClipboardDeliveryOrder.shared.begin()
            do { try deliverImage(image); announce("Copied") } catch { reportCaptureError(error) }
        case .edit: openEditor(image: image, copied: false, sourceScale: scale)
        case .pin: pin(image: image, sourceScale: scale)
        case .save: showExport(image, scale: scale)
        }
    }

    private func showExport(_ image: CGImage, scale: CGFloat) { presentAuxiliary(ImageExportWindow(image: image, sourceScale: scale)) }
    private func showTextPreview(_ image: CGImage) { presentAuxiliary(TextPreviewWindow(image: image)) }
    private func showRedactionReview(_ image: CGImage, scale: CGFloat) {
        let review = RedactionReviewWindow(image: image, actionTitle: "Approve & Copy") { [weak self] image, ticket in
            guard let self, let ticket else { return }
            self.addRecent(image, scale: scale)
            if ticket.isCurrent(on: self.pasteboard) {
                do { try self.deliverImage(image); self.announce("Reviewed image copied") } catch { self.reportCaptureError(error) }
            } else { self.openEditor(image: image, copied: false, sourceScale: scale); self.announce("Reviewed image ready — newer clipboard content preserved") }
            self.onStateChange?()
        }
        presentAuxiliary(review)
    }

    private func presentAuxiliary(_ controller: NSWindowController) {
        auxiliaryWindows.append(controller)
        let close: () -> Void = { [weak self, weak controller] in
            guard let controller else { return }; self?.auxiliaryWindows.removeAll { $0 === controller }
        }
        if let export = controller as? ImageExportWindow { export.onClose = close }
        if let text = controller as? TextPreviewWindow { text.onClose = close }
        if let review = controller as? RedactionReviewWindow { review.onClose = close }
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); NSApp.activate()
    }

    func showRecentPicker() {
        cancelSelection()
        if recentPicker == nil {
            recentPicker = RecentPickerWindow(onAction: { [weak self] action, id in
                guard let self, let record = self.recents.first(where: { $0.id == id }) else { return }
                self.actOnImage(action, image: record.image, scale: record.scale)
            }, onCombine: { [weak self] ids, layout in self?.combineRecents(ids, layout: layout) }, onDelete: { [weak self] ids in
                guard let self else { return }
                self.combinationTask?.cancel()
                self.recents.removeAll { ids.contains($0.id) }
                self.recentPicker?.update(self.recents)
                self.onStateChange?()
            })
            recentPicker?.onClose = { [weak self] in self?.combinationTask?.cancel() }
        }
        recentPicker?.update(recents); recentPicker?.showWindow(nil); recentPicker?.window?.makeKeyAndOrderFront(nil); NSApp.activate()
    }

    private func combineRecents(_ ids: [UUID], layout: CompositionLayout) {
        combinationTask?.cancel()
        let selected = recents.filter { ids.contains($0.id) }.sorted { $0.date < $1.date }
        guard selected.count >= 2 else { return }
        let batch = SendableImageBatch(images: selected.map(\.image))
        combinationTask = Task { @MainActor [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) { SendableImage(image: try combinedImages(batch.images, layout: layout)) }.value
                try Task.checkCancellation(); guard let self else { return }
                self.openEditor(image: result.image, copied: false)
            } catch is CancellationError {} catch { self?.reportCaptureError(error) }
        }
    }

    func togglePins() {
        guard !pins.isEmpty else { announce("No pinned captures"); return }
        pinsAreHidden.toggle()
        for pin in pins { if pinsAreHidden { pin.window?.orderOut(nil) } else { pin.window?.orderFrontRegardless() } }
        announce(pinsAreHidden ? "Pins hidden" : "Pins restored", symbol: "pin")
    }
    func unlockPins() { pins.forEach { $0.unlock() }; announce("Pins accept clicks again", symbol: "pin") }

    private func announce(_ message: String, symbol: String = "viewfinder", badge: String? = nil, beep: Bool = false) {
        if beep { NSSound.beep() }
        onStatus?(ScreenWrenStatus(message: "ScreenWren — \(message)", symbolName: symbol, badge: badge))
        NSAccessibility.post(
            element: NSApp!,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )
    }
}

enum CaptureError: LocalizedError {
    case missingImage
    case clipboardWriteFailed
    case scrollingGeometryChanged

    var errorDescription: String? {
        switch self {
        case .missingImage: "ScreenCaptureKit returned no image."
        case .clipboardWriteFailed: "The captured image couldn’t be placed on the clipboard."
        case .scrollingGeometryChanged: "The scrolling viewport changed size. Start again."
        }
    }
}

@MainActor
private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class SelectionWindowController: NSWindowController {
    private let screen: NSScreen
    private let selectionView: SelectionView
    private let onSelection: (SelectionTarget?) -> Void
    private var overlays: [(screen: NSScreen, window: NSWindow, view: SelectionView)] = []
    private var candidatesByID: [CGWindowID: WindowCandidate] = [:]
    private var finished = false
    private let desktopFrame: CGRect
    private let outputScale: CGFloat
    private var loupeDisplay: NSScreen?
    var onLoupeNeeded: ((NSScreen) -> Void)?

    init(screen: NSScreen, prompt: String, allowsWindows: Bool, backgroundImage: CGImage? = nil,
         spansDisplays: Bool = false, options: SelectionOptions? = nil, onSelection: @escaping (SelectionTarget?) -> Void) {
        self.screen = screen; self.onSelection = onSelection
        let screens = spansDisplays && backgroundImage == nil ? NSScreen.screens : [screen]
        let desktop = screens.reduce(CGRect.null) { $0.union($1.frame) }
        desktopFrame = desktop
        outputScale = screens.map(\.backingScaleFactor).max() ?? screen.backingScaleFactor
        let options = options ?? WorkflowPreferences.shared.selectionOptions
        selectionView = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size), pixelScale: outputScale, prompt: prompt, allowsWindows: allowsWindows, backgroundImage: backgroundImage, options: options)
        let primary = Self.makeWindow(for: screen)
        super.init(window: primary)
        for display in screens {
            let isPrimary = display === screen
            let view = isPrimary ? selectionView : SelectionView(frame: CGRect(origin: .zero, size: display.frame.size), pixelScale: outputScale, prompt: prompt, allowsWindows: allowsWindows, options: options)
            let window = isPrimary ? primary : Self.makeWindow(for: display)
            view.bounds.origin = CGPoint(x: display.frame.minX - desktop.minX, y: display.frame.minY - desktop.minY)
            view.selectionBounds = CGRect(origin: .zero, size: desktop.size)
            view.setAccessibilityElement(true); view.setAccessibilityRole(.group); view.setAccessibilityLabel("Screen capture target")
            view.setAccessibilityHelp("Drag a region. Hold Shift on release to adjust. Arrow keys move; Option–arrows resize; Return captures; Escape cancels.")
            view.onChange = { [weak self, weak view] in
                guard let self, let view else { return }
                for overlay in self.overlays where overlay.view !== view { overlay.view.synchronize(from: view) }
                if let overlay = self.overlays.first(where: { $0.view.bounds.contains(view.pointerLocation) }) { self.requestLoupe(for: overlay.screen) }
            }
            view.onFinish = { [weak self] choice in self?.finish(choice) }
            window.contentView = view; window.makeFirstResponder(view)
            overlays.append((display, window, view))
        }
    }
    private static func makeWindow(for screen: NSScreen) -> NSWindow {
        let window = SelectionWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.level = .screenSaver; window.backgroundColor = .clear; window.isOpaque = false; window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]; window.acceptsMouseMovedEvents = true
        return window
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func finish(_ choice: SelectionChoice?) {
        guard !finished else { return }; finished = true
        overlays.forEach { $0.window.orderOut(nil) }
        switch choice {
        case let .region(local):
            let global = local.offsetBy(dx: desktopFrame.minX, dy: desktopFrame.minY)
            if overlays.count == 1 { onSelection(DisplayRegion(rect: global, screen: screen).map(SelectionTarget.region)) }
            else { onSelection(DesktopRegion(rect: global, screens: overlays.map(\.screen), scale: outputScale).map(SelectionTarget.desktop)) }
        case let .window(id): onSelection(candidatesByID[id].map(SelectionTarget.window))
        case nil: onSelection(nil)
        }
    }
    func updateWindowCandidates(_ candidates: [WindowCandidate]) {
        candidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.windowID, $0) })
        let hits = candidates.map {
            SelectionView.WindowHit(
                windowID: $0.windowID,
                frame: $0.appKitFrame.offsetBy(dx: -desktopFrame.minX, dy: -desktopFrame.minY),
                applicationName: $0.window.owningApplication?.applicationName ?? "Window"
            )
        }
        for overlay in overlays { overlay.view.updateWindowHits(hits) }
    }
    private func requestLoupe(for screen: NSScreen) {
        guard onLoupeNeeded != nil, loupeDisplay !== screen else { return }
        loupeDisplay = screen
        overlays.forEach { $0.view.clearLoupeImage() }
        onLoupeNeeded?(screen)
    }
    func updateLoupeImage(_ image: CGImage, for screen: NSScreen? = nil) {
        let target = screen ?? self.screen
        guard loupeDisplay === target, let overlay = overlays.first(where: { $0.screen === target }) else { return }
        overlay.view.updateLoupeImage(image)
    }
    func show() {
        NSApp.activate()
        for overlay in overlays { overlay.window.orderFrontRegardless(); overlay.window.invalidateCursorRects(for: overlay.view) }
        window?.makeKeyAndOrderFront(nil); NSCursor.crosshair.set()
        requestLoupe(for: screen)
        NSAccessibility.post(element: selectionView, notification: .announcementRequested,
                             userInfo: [.announcement: selectionView.prompt, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    func cancel() { finish(nil) }
}

enum SelectionChoice {
    case region(CGRect)
    case window(CGWindowID)
}

final class SelectionView: NSView {
    struct WindowHit {
        let windowID: CGWindowID
        let frame: CGRect
        let applicationName: String
    }

    var onFinish: ((SelectionChoice?) -> Void)?
    var onChange: (() -> Void)?
    var selectionBounds: CGRect = .zero
    private let options: SelectionOptions
    private var awaitingConfirmation = false
    let prompt: String
    private let pixelScale: CGFloat
    private let allowsWindows: Bool
    private var startPoint: CGPoint?
    private var selection = CGRect.zero
    private var didDrag = false
    private(set) var windowMode = false
    private var windowHits: [WindowHit] = []
    private var highlightedWindowIndex: Int?
    private var tracking: NSTrackingArea?
    private var backgroundImage: NSImage?
    private var loupeImage: CGImage?
    private var activePoint = CGPoint.zero
    var pointerLocation: CGPoint { activePoint }
    private var isMovingSelection = false
    private var moveAnchor = CGPoint.zero
    private var selectionAtMoveStart = CGRect.zero

    init(
        frame: NSRect,
        pixelScale: CGFloat,
        prompt: String,
        allowsWindows: Bool,
        backgroundImage: CGImage? = nil,
        options: SelectionOptions = SelectionOptions()
    ) {
        self.options = options
        self.pixelScale = pixelScale
        self.prompt = prompt
        self.allowsWindows = allowsWindows
        if let backgroundImage {
            self.backgroundImage = NSImage(cgImage: backgroundImage, size: frame.size)
            loupeImage = backgroundImage
        }
        super.init(frame: frame)
        selectionBounds = bounds
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    func synchronize(from other: SelectionView) {
        selection = other.selection; startPoint = other.startPoint; didDrag = other.didDrag
        activePoint = other.activePoint; windowMode = other.windowMode; awaitingConfirmation = other.awaitingConfirmation
        if let index = other.highlightedWindowIndex, other.windowHits.indices.contains(index) {
            let id = other.windowHits[index].windowID
            highlightedWindowIndex = windowHits.firstIndex { $0.windowID == id }
        } else { highlightedWindowIndex = nil }
        needsDisplay = true
    }
    private var fixedSizeInPoints: CGSize? { options.fixedSize.map { CGSize(width: $0.width / pixelScale, height: $0.height / pixelScale) } }
    private var minimumSelectionSize: CGFloat { 4 / pixelScale }
    private func changed() { needsDisplay = true; onChange?() }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    func updateWindowHits(_ hits: [WindowHit]) {
        windowHits = hits.compactMap { hit in
            let localFrame = hit.frame.intersection(bounds)
            guard localFrame.width >= 4, localFrame.height >= 4 else { return nil }
            return WindowHit(windowID: hit.windowID, frame: localFrame, applicationName: hit.applicationName)
        }
        updateHighlightedWindow(at: convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
    }

    func clearLoupeImage() { loupeImage = nil; needsDisplay = true }

    func updateLoupeImage(_ image: CGImage) {
        loupeImage = image
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseMoved(with event: NSEvent) {
        guard startPoint == nil else { return }
        activePoint = convert(event.locationInWindow, from: nil)
        if !windowMode, let size = fixedSizeInPoints, !awaitingConfirmation {
            selection = constrainedSelection(from: activePoint, to: activePoint, bounds: selectionBounds, fixedSize: size, ratio: nil, pixelScale: pixelScale)
            didDrag = true
        }
        updateHighlightedWindow(at: activePoint)
        changed()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        activePoint = point
        awaitingConfirmation = false
        startPoint = point
        selection = constrainedSelection(from: point, to: point, bounds: selectionBounds, fixedSize: windowMode ? nil : fixedSizeInPoints, ratio: options.aspectRatio, pixelScale: pixelScale)
        didDrag = !windowMode && fixedSizeInPoints != nil
        updateHighlightedWindow(at: point)
        changed()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        activePoint = point
        if isMovingSelection {
            let delta = CGPoint(x: point.x - moveAnchor.x, y: point.y - moveAnchor.y)
            selection = constrainedSelection(
                from: .zero,
                to: CGPoint(x: selectionAtMoveStart.midX + delta.x, y: selectionAtMoveStart.midY + delta.y),
                bounds: selectionBounds, fixedSize: selectionAtMoveStart.size, ratio: nil, pixelScale: pixelScale
            )
        } else {
            selection = constrainedSelection(from: startPoint, to: point, bounds: selectionBounds, fixedSize: fixedSizeInPoints, ratio: options.aspectRatio, pixelScale: pixelScale)
        }
        didDrag = selection.width >= minimumSelectionSize || selection.height >= minimumSelectionSize
        changed()
    }

    override func mouseUp(with event: NSEvent) {
        isMovingSelection = false
        if didDrag, selection.width >= minimumSelectionSize, selection.height >= minimumSelectionSize {
            if options.adjustBeforeCapture || event.modifierFlags.contains(.shift) {
                awaitingConfirmation = true; startPoint = nil; changed(); return
            }
            onFinish?(.region(selection))
            return
        }
        if !didDrag, windowMode, let highlightedWindowIndex, windowHits.indices.contains(highlightedWindowIndex) {
            onFinish?(.window(windowHits[highlightedWindowIndex].windowID))
            return
        }
        startPoint = nil
        selection = .zero
        didDrag = false
        NSSound.beep()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if awaitingConfirmation, selection.width >= minimumSelectionSize, selection.height >= minimumSelectionSize { onFinish?(.region(selection)); return }
            if windowMode, let index = highlightedWindowIndex, windowHits.indices.contains(index) { onFinish?(.window(windowHits[index].windowID)) }
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            guard didDrag else { return }
            let step: CGFloat = (event.modifierFlags.contains(.shift) ? 10 : 1) / pixelScale
            let dx: CGFloat = Int(event.keyCode) == kVK_LeftArrow ? -step : (Int(event.keyCode) == kVK_RightArrow ? step : 0)
            let dy: CGFloat = Int(event.keyCode) == kVK_DownArrow ? -step : (Int(event.keyCode) == kVK_UpArrow ? step : 0)
            selection = adjustedSelection(selection, dx: dx, dy: dy, resizing: event.modifierFlags.contains(.option), bounds: selectionBounds, ratio: options.aspectRatio, minimumSize: minimumSelectionSize)
            awaitingConfirmation = true; changed()
        case kVK_Escape:
            onFinish?(nil)
        case kVK_Space:
            if startPoint != nil, didDrag, !isMovingSelection {
                isMovingSelection = true
                moveAnchor = activePoint
                selectionAtMoveStart = selection
                changed()
            } else if startPoint == nil, allowsWindows, !event.isARepeat {
                windowMode.toggle()
                selection = .zero
                didDrag = false
                awaitingConfirmation = false
                if !windowMode { highlightedWindowIndex = nil }
                else { updateHighlightedWindow(at: convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)) }
                changed()
            }
        case kVK_Tab where windowMode && !windowHits.isEmpty:
            let delta = event.modifierFlags.contains(.shift) ? -1 : 1
            let current = highlightedWindowIndex ?? (delta > 0 ? -1 : 0)
            highlightedWindowIndex = (current + delta + windowHits.count) % windowHits.count
            changed()
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Space {
            if isMovingSelection, !selection.isEmpty {
                startPoint = CGPoint(
                    x: activePoint.x >= selection.midX ? selection.minX : selection.maxX,
                    y: activePoint.y >= selection.midY ? selection.minY : selection.maxY
                )
            }
            isMovingSelection = false
            needsDisplay = true
        } else {
            super.keyUp(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundImage?.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
        NSColor.black.withAlphaComponent(0.40).setFill()
        bounds.fill()

        if !didDrag, windowMode,
           let highlightedWindowIndex,
           windowHits.indices.contains(highlightedWindowIndex),
           let context = NSGraphicsContext.current?.cgContext {
            let hit = windowHits[highlightedWindowIndex]
            reveal(hit.frame, in: context)
            drawBorder(around: hit.frame)
            let appName = hit.applicationName
            let labelY = hit.frame.minY >= 38 ? hit.frame.minY - 34 : hit.frame.maxY + 8
            drawPill(appName, centerX: hit.frame.midX, y: labelY)
        }

        if didDrag, !selection.isEmpty, let context = NSGraphicsContext.current?.cgContext {
            reveal(selection, in: context)
            drawBorder(around: selection)
            let width = Int((selection.width * pixelScale).rounded())
            let height = Int((selection.height * pixelScale).rounded())
            let visible = selection.intersection(bounds)
            let labelY = visible.minY >= bounds.minY + 38 ? visible.minY - 34 : visible.maxY + 8
            if !visible.isEmpty { drawPill("\(width) × \(height)", centerX: visible.midX, y: labelY) }
            if bounds.contains(activePoint) { drawLoupe(at: activePoint) }
        }

        let modeHint = allowsWindows ? (windowMode ? "Window snap on  •  Space for region only" : "Region only  •  Space for window snap") : "Region selection"
        drawPill(awaitingConfirmation ? "Arrows move · Option–arrows resize · Return captures · Esc cancels" : "\(prompt) · \(modeHint) · Shift-release to adjust · Esc cancels", centerX: bounds.midX, y: bounds.maxY - 58)
    }

    private func updateHighlightedWindow(at point: CGPoint) {
        highlightedWindowIndex = windowMode ? windowHits.firstIndex(where: { $0.frame.contains(point) }) : nil
        needsDisplay = true
    }

    private func drawBorder(around rect: CGRect) {
        NSColor.black.withAlphaComponent(0.55).setStroke()
        let outerBorder = NSBezierPath(rect: rect.insetBy(dx: 1.5, dy: 1.5))
        outerBorder.lineWidth = 3
        outerBorder.stroke()

        NSColor.controlAccentColor.setStroke()
        let innerBorder = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        innerBorder.lineWidth = 1
        innerBorder.stroke()
    }

    private func reveal(_ rect: CGRect, in context: CGContext) {
        guard let backgroundImage else {
            context.clear(rect)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        backgroundImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawLoupe(at point: CGPoint) {
        guard let image = loupeImage, bounds.width > 0, bounds.height > 0 else { return }
        let pixel = loupePixel(
            at: CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY),
            inside: selection.offsetBy(dx: -bounds.minX, dy: -bounds.minY),
            viewSize: bounds.size,
            imageSize: CGSize(width: image.width, height: image.height)
        )
        let centerX = Int(pixel.x)
        let centerY = Int(pixel.y)
        let sampleSide = 15
        let sample = CGRect(
            x: min(max(0, centerX - sampleSide / 2), max(0, image.width - sampleSide)),
            y: min(max(0, centerY - sampleSide / 2), max(0, image.height - sampleSide)),
            width: min(sampleSide, image.width),
            height: min(sampleSide, image.height)
        )
        guard let crop = image.cropping(to: sample) else { return }

        let size: CGFloat = 126
        let proposedX = point.x + 24 + size <= bounds.maxX ? point.x + 24 : point.x - 24 - size
        let proposedY = point.y - size - 24 >= bounds.minY ? point.y - size - 24 : point.y + 24
        let frame = CGRect(
            x: min(max(bounds.minX + 8, proposedX), bounds.maxX - size - 8),
            y: min(max(bounds.minY + 8, proposedY), bounds.maxY - size - 8),
            width: size,
            height: size
        )
        let crosshairPoint = loupeCrosshairPoint(pixel: pixel, sample: sample, frame: frame)

        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
        clip.addClip()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: crop, size: frame.size).draw(
            in: frame,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.none.rawValue]
        )
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.withAlphaComponent(0.7).setStroke()
        let border = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        border.lineWidth = 2
        border.stroke()
        NSColor.controlAccentColor.setStroke()
        let crosshair = NSBezierPath()
        crosshair.move(to: CGPoint(x: crosshairPoint.x, y: frame.minY))
        crosshair.line(to: CGPoint(x: crosshairPoint.x, y: frame.maxY))
        crosshair.move(to: CGPoint(x: frame.minX, y: crosshairPoint.y))
        crosshair.line(to: CGPoint(x: frame.maxX, y: crosshairPoint.y))
        crosshair.lineWidth = 1
        crosshair.stroke()
    }

    private func drawPill(_ text: String, centerX: CGFloat, y: CGFloat) {
        let label = text as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = label.size(withAttributes: attributes)
        let pillSize = NSSize(width: textSize.width + 16, height: textSize.height + 8)
        let origin = CGPoint(
            x: min(max(centerX - pillSize.width / 2, bounds.minX + 8), bounds.maxX - pillSize.width - 8),
            y: min(max(y, bounds.minY + 8), bounds.maxY - pillSize.height - 8)
        )
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: CGRect(origin: origin, size: pillSize), xRadius: 7, yRadius: 7).fill()
        label.draw(at: CGPoint(x: origin.x + 8, y: origin.y + 4), withAttributes: attributes)
    }
}

final class ImageRegionSelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private let prompt: String
    private var startPoint: CGPoint?
    private var selection = CGRect.zero

    init(frame: CGRect, prompt: String) {
        self.prompt = prompt
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(prompt)
        setAccessibilityHelp("Drag a rectangle. Press Escape to cancel.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        startPoint = point
        selection = CGRect(origin: point, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        selection = normalizedRect(from: startPoint, to: convert(event.locationInWindow, from: nil)).intersection(bounds)
        updateAccessibilityValue()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard selection.width >= 4, selection.height >= 4 else {
            NSSound.beep()
            startPoint = nil
            selection = .zero
            needsDisplay = true
            return
        }
        onFinish?(selection)
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            onFinish?(nil)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if selection.width >= 4, selection.height >= 4 { onFinish?(selection) }
            else { NSSound.beep() }
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            if selection.isEmpty {
                let size = CGSize(width: min(240, bounds.width / 2), height: min(160, bounds.height / 2))
                selection = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            if event.modifierFlags.contains(.option) {
                switch Int(event.keyCode) {
                case kVK_LeftArrow: selection.size.width = max(4, selection.width - step)
                case kVK_RightArrow: selection.size.width = min(bounds.maxX - selection.minX, selection.width + step)
                case kVK_DownArrow: selection.size.height = max(4, selection.height - step)
                default: selection.size.height = min(bounds.maxY - selection.minY, selection.height + step)
                }
            } else {
                var dx: CGFloat = 0
                var dy: CGFloat = 0
                if event.keyCode == UInt16(kVK_LeftArrow) { dx = -step }
                if event.keyCode == UInt16(kVK_RightArrow) { dx = step }
                if event.keyCode == UInt16(kVK_DownArrow) { dy = -step }
                if event.keyCode == UInt16(kVK_UpArrow) { dy = step }
                selection.origin.x = min(max(0, selection.minX + dx), bounds.maxX - selection.width)
                selection.origin.y = min(max(0, selection.minY + dy), bounds.maxY - selection.height)
            }
            updateAccessibilityValue()
            needsDisplay = true
        default:
            super.keyDown(with: event)
        }
    }

    private func updateAccessibilityValue() {
        setAccessibilityValue(
            "x \(Int(selection.minX)), y \(Int(selection.minY)), width \(Int(selection.width)), height \(Int(selection.height))"
        )
    }

    override func draw(_ dirtyRect: CGRect) {
        NSColor.black.withAlphaComponent(0.38).setFill()
        bounds.fill()
        if !selection.isEmpty, let context = NSGraphicsContext.current?.cgContext {
            context.clear(selection)
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 2
            border.stroke()
        }

        let label = prompt as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = label.size(withAttributes: attributes)
        let pill = CGRect(
            x: max(8, bounds.midX - textSize.width / 2 - 10),
            y: bounds.maxY - textSize.height - 34,
            width: textSize.width + 20,
            height: textSize.height + 12
        )
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
        label.draw(at: CGPoint(x: pill.minX + 10, y: pill.minY + 6), withAttributes: attributes)
    }
}

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let imageUndoManager = UndoManager()

    init(image: CGImage, copied: Bool, sourceScale: CGFloat = 1, onPin: @escaping (CGImage) -> Void) {
        let content = EditorViewController(image: image, initialStatus: copied ? "Copied" : "Ready", sourceScale: sourceScale, onPin: onPin)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = content
        window.setContentSize(NSSize(width: 1040, height: 720))
        window.title = "ScreenWren"
        window.subtitle = "\(image.width) × \(image.height)"
        window.minSize = NSSize(width: 720, height: 520)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(sender)
    }

    func windowWillClose(_ notification: Notification) {
        (contentViewController as? EditorViewController)?.cancelPendingAction()
        onClose?()
        onClose = nil
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        imageUndoManager
    }
}

@MainActor
final class EditorViewController: NSViewController, @preconcurrency PaperMarkupViewController.Delegate {
    private struct Snapshot {
        let image: CGImage
        let markup: PaperMarkup
    }

    private enum RegionOperation {
        case redact
        case blur
        case crop

        var prompt: String {
            switch self {
            case .redact: "Drag to securely redact — Esc cancels"
            case .blur: "Drag to blur (not secure) — Esc cancels"
            case .crop: "Drag the area to keep — Esc cancels"
            }
        }
    }

    private let sourceScale: CGFloat
    private var exportWindow: ImageExportWindow?
    private var textWindow: TextPreviewWindow?
    private var redactionWindow: RedactionReviewWindow?
    private let originalImage: CGImage
    private var workingImage: CGImage
    private var imageBounds: CGRect
    private let imageView: NSImageView
    private let markupController: PaperMarkupViewController
    private let toolbarController: MarkupToolbarViewController
    private let instantInspect = InstantInspectController()
    private let inspectButton: NSButton
    private let statusLabel: NSTextField
    private let onPin: (CGImage) -> Void
    private let progressIndicator = NSProgressIndicator()
    private var actionButtons: [NSButton] = []
    private var actionTask: Task<Void, Never>?
    private var actionIsActive = false
    private var regionOverlay: ImageRegionSelectionView?
    private var sharingPicker: NSSharingServicePicker?
    private var dragExportView: PNGPromiseDragView?
    private var didFitImage = false
    private var inspectPresentation = InstantInspectPresentation.inactive
    private var editorKeyMonitor: Any?
    private var nextStepNumber = 1

    init(image: CGImage, initialStatus: String, sourceScale: CGFloat = 1, onPin: @escaping (CGImage) -> Void) {
        self.sourceScale = sourceScale
        originalImage = image
        workingImage = image
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        imageBounds = bounds
        imageView = NSImageView(frame: bounds)
        markupController = PaperMarkupViewController(markup: PaperMarkup(bounds: bounds), supportedFeatureSet: .latest)
        toolbarController = MarkupToolbarViewController(supportedFeatureSet: .latest)
        inspectButton = NSButton(title: "Inspect", target: nil, action: nil)
        statusLabel = NSTextField(labelWithString: initialStatus)
        self.onPin = onPin
        super.init(nibName: nil, bundle: nil)

        let drawingTool = PKInkingTool(.monoline, color: .systemRed, width: 3)
        markupController.drawingTool = drawingTool
        markupController.zoomRange = 0.02...8
        toolbarController.selectedDrawingTool = drawingTool

        imageView.image = NSImage(cgImage: image, size: bounds.size)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.borderColor = NSColor.separatorColor.cgColor
        imageView.layer?.borderWidth = 1
        imageView.setAccessibilityElement(true)
        imageView.setAccessibilityRole(.image)
        imageView.setAccessibilityLabel("Captured image, \(image.width) by \(image.height) pixels")
        markupController.contentView = imageView
        markupController.delegate = self
        toolbarController.delegate = markupController
        instantInspect.track(imageView)
        instantInspect.onEscape = { [weak self] in self?.leaveInspectMode() }
        instantInspect.onBarcodeHit = { [weak self] hit, point in self?.showBarcodeMenu(for: hit, at: point) }
        instantInspect.onSubjectPoint = { [weak self] point in self?.copySubject(at: point) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let topBar = NSVisualEffectView()
        topBar.material = .headerView
        topBar.blendingMode = .withinWindow
        topBar.state = .active
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        addChild(toolbarController)
        toolbarController.view.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(toolbarController.view)

        inspectButton.target = self
        inspectButton.action = #selector(toggleInspectMode(_:))
        inspectButton.setButtonType(.toggle)
        inspectButton.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)
        inspectButton.imagePosition = .imageLeading
        inspectButton.keyEquivalent = "i"
        inspectButton.keyEquivalentModifierMask = [.command, .shift]
        inspectButton.toolTip = "Select text, subjects, and codes in the image (⇧⌘I)"

        let textButton = NSButton(title: "Copy Text", target: self, action: #selector(copyText(_:)))
        textButton.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil)
        textButton.imagePosition = .imageLeading
        textButton.keyEquivalent = "t"
        textButton.keyEquivalentModifierMask = [.command, .shift]
        textButton.toolTip = "Copy recognized text (⇧⌘T)"

        let subjectButton = NSButton(title: "Copy Subject", target: self, action: #selector(copySubject(_:)))
        subjectButton.image = NSImage(systemSymbolName: "person.crop.rectangle", accessibilityDescription: nil)
        subjectButton.imagePosition = .imageLeading
        subjectButton.keyEquivalent = "l"
        subjectButton.keyEquivalentModifierMask = [.command, .shift]
        subjectButton.toolTip = "Copy a transparent subject cutout (⇧⌘L)"

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let copyButton = NSButton(title: "Copy Edited Image", target: self, action: #selector(copyUpdated))
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyButton.imagePosition = .imageLeading
        copyButton.bezelColor = .controlAccentColor
        copyButton.keyEquivalent = "c"
        copyButton.keyEquivalentModifierMask = [.command, .shift]
        copyButton.toolTip = "Copy the image with your markup (⇧⌘C)"

        let moreButton = NSButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More image actions") ?? NSImage(), target: self, action: #selector(showMoreMenu(_:)))
        moreButton.bezelStyle = .texturedRounded
        moreButton.toolTip = "Redact, adjust, pin, save, share, or drag"
        moreButton.setAccessibilityLabel("More image actions")

        let dragIcon = NSImage(systemSymbolName: "arrow.up.doc", accessibilityDescription: "Drag edited image as PNG") ?? NSImage()
        let dragView = PNGPromiseDragView(image: dragIcon) { [weak self] in
            self?.makeExportProvider() ?? makePNGFilePromiseProvider { throw EditorError.couldNotRender }
        }
        dragExportView = dragView
        dragView.toolTip = "Drag the edited image as a PNG"
        dragView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false

        actionButtons = [inspectButton, textButton, subjectButton, copyButton, moreButton]
        let actions = NSStackView(views: [progressIndicator, statusLabel, inspectButton, textButton, subjectButton, separator, copyButton, dragView, moreButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        actions.setCustomSpacing(14, after: statusLabel)
        actions.setCustomSpacing(14, after: subjectButton)
        actions.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(actions)

        addChild(markupController)
        markupController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(markupController.view)

        instantInspect.analysisOverlayView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(instantInspect.analysisOverlayView, positioned: .above, relativeTo: markupController.view)
        instantInspect.hitOverlayView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(instantInspect.hitOverlayView, positioned: .above, relativeTo: instantInspect.analysisOverlayView)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 56),

            toolbarController.view.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 8),
            toolbarController.view.topAnchor.constraint(equalTo: topBar.topAnchor, constant: 6),
            toolbarController.view.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -6),
            toolbarController.view.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -12),

            actions.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),
            actions.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.heightAnchor.constraint(equalToConstant: 22),
            dragView.widthAnchor.constraint(equalToConstant: 28),
            dragView.heightAnchor.constraint(equalToConstant: 28),

            markupController.view.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            markupController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            markupController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            markupController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            instantInspect.analysisOverlayView.topAnchor.constraint(equalTo: markupController.view.topAnchor),
            instantInspect.analysisOverlayView.leadingAnchor.constraint(equalTo: markupController.view.leadingAnchor),
            instantInspect.analysisOverlayView.trailingAnchor.constraint(equalTo: markupController.view.trailingAnchor),
            instantInspect.analysisOverlayView.bottomAnchor.constraint(equalTo: markupController.view.bottomAnchor),

            instantInspect.hitOverlayView.topAnchor.constraint(equalTo: instantInspect.analysisOverlayView.topAnchor),
            instantInspect.hitOverlayView.leadingAnchor.constraint(equalTo: instantInspect.analysisOverlayView.leadingAnchor),
            instantInspect.hitOverlayView.trailingAnchor.constraint(equalTo: instantInspect.analysisOverlayView.trailingAnchor),
            instantInspect.hitOverlayView.bottomAnchor.constraint(equalTo: instantInspect.analysisOverlayView.bottomAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installEditorKeyMonitor()
        guard !didFitImage else { return }
        didFitImage = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.markupController.setContentVisibleFrame(self.imageBounds.insetBy(dx: -24, dy: -24), animated: false)
            self.instantInspect.install(image: self.workingImage)
            self.instantInspect.updateGeometry()
        }
    }

    override func viewWillDisappear() {
        removeEditorKeyMonitor()
        super.viewWillDisappear()
    }

    private func installEditorKeyMonitor() {
        guard editorKeyMonitor == nil else { return }
        editorKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleEditorKeyEvent(event)
        }
    }

    private func removeEditorKeyMonitor() {
        if let editorKeyMonitor {
            NSEvent.removeMonitor(editorKeyMonitor)
            self.editorKeyMonitor = nil
        }
    }

    private func handleEditorKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard event.window === view.window,
              actionTask == nil else { return event }
        let responder = view.window?.firstResponder
        let isTextEntry = responder is NSTextView || responder is ShortcutRecorderField
        guard let command = editorKeyboardCommand(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            isTextEntry: isTextEntry,
            hasSheet: view.window?.attachedSheet != nil,
            hasRegionOverlay: regionOverlay != nil
        ) else { return event }

        switch command {
        case .arrow:
            prepareForKeyboardMarkup()
            markupController.markupToolbarViewController(
                toolbarController,
                insertNewLineWithStartMarker: false,
                endMarker: true
            )
            report("Arrow inserted — drag to position it")
        case .rectangle:
            prepareForKeyboardMarkup()
            markupController.markupToolbarViewController(toolbarController, insertNewShape: .rectangle)
            report("Rectangle inserted — drag to position it")
        case .highlighter:
            prepareForKeyboardMarkup(selectionMode: false)
            let tool = PKInkingTool(.marker, color: NSColor.systemYellow.withAlphaComponent(0.42), width: 18)
            markupController.drawingTool = tool
            toolbarController.selectedDrawingTool = tool
            markupController.indirectPointerTouchMode = .drawing
            toolbarController.selectedIndirectPointerTouchMode = .drawing
            report("Highlighter selected — drag to mark")
        case .text:
            prepareForKeyboardMarkup()
            markupController.markupToolbarViewControllerInsertNewTextbox(toolbarController)
            report("Text box inserted — start typing")
        case .numberedStep:
            prepareForKeyboardMarkup()
            insertNumberedStep()
        case .escape:
            if inspectPresentation != .inactive {
                leaveInspectMode()
            } else {
                markupController.indirectPointerTouchMode = .selection
                toolbarController.selectedIndirectPointerTouchMode = .selection
                report("Selection mode")
            }
        case .copyAndClose:
            copyAndClose(nil)
        }
        return nil
    }

    private func prepareForKeyboardMarkup(selectionMode: Bool = true) {
        if inspectPresentation != .inactive { setInspectPresentation(.inactive) }
        if selectionMode {
            markupController.indirectPointerTouchMode = .selection
            toolbarController.selectedIndirectPointerTouchMode = .selection
        }
        view.window?.makeFirstResponder(markupController.view)
    }

    private func insertNumberedStep() {
        guard var markup = markupController.markup else { return }
        let circledNumbers = [
            "❶", "❷", "❸", "❹", "❺", "❻", "❼", "❽", "❾", "❿",
            "⓫", "⓬", "⓭", "⓮", "⓯", "⓰", "⓱", "⓲", "⓳", "⓴",
        ]
        let number = nextStepNumber
        let marker = number <= circledNumbers.count ? circledNumbers[number - 1] : "\(number)"
        let visible = markupController.contentVisibleFrame.intersection(imageBounds)
        let center = visible.isNull || visible.isEmpty
            ? CGPoint(x: imageBounds.midX, y: imageBounds.midY)
            : CGPoint(x: visible.midX, y: visible.midY)
        let side = min(max(54, min(imageBounds.width, imageBounds.height) * 0.08), 96)
        let frame = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
            .intersection(imageBounds)
        let text = NSAttributedString(
            string: marker,
            attributes: [
                .font: NSFont.systemFont(ofSize: max(32, side * 0.72), weight: .bold),
                .foregroundColor: NSColor.systemRed,
            ]
        )
        markup.insertNewTextbox(attributedText: text, frame: frame)
        applyMarkup(markup, status: "Step \(number) inserted — drag to position it")
        nextStepNumber += 1
    }

    private func applyMarkup(_ markup: PaperMarkup, status: String, registerUndo: Bool = true) {
        let previous = markupController.markup
        markupController.markup = markup
        if registerUndo, let previous {
            undoManager?.registerUndo(withTarget: self) { target in
                target.applyMarkup(previous, status: "Undid numbered step")
            }
            undoManager?.setActionName("Numbered Step")
        }
        report(status)
    }

    @objc private func toggleInspectMode(_ sender: NSButton) {
        guard actionTask == nil, regionOverlay == nil else { return }
        if inspectPresentation == .inactive {
            setInspectPresentation(.inspect)
            report("Inspecting — select text or click a detected code · Esc returns to Edit")
        } else {
            leaveInspectMode()
        }
    }

    private func leaveInspectMode() {
        setInspectPresentation(.inactive)
        report("Edit mode")
    }

    private func setInspectPresentation(_ presentation: InstantInspectPresentation) {
        inspectPresentation = presentation
        inspectButton.state = presentation == .inactive ? .off : .on
        if presentation == .inactive { instantInspect.resetInteraction() }
        refreshEditorInteraction()
        if presentation != .inactive, !actionIsActive {
            view.window?.makeFirstResponder(instantInspect.firstResponder(for: presentation))
        }
    }

    private func refreshEditorInteraction() {
        let interactive = !actionIsActive && regionOverlay == nil
        markupController.isEditable = interactive && inspectPresentation == .inactive
        instantInspect.setPresentation(inspectPresentation, interactive: interactive)
    }

    @objc private func showMoreMenu(_ sender: NSButton) {
        guard actionTask == nil, regionOverlay == nil else { return }
        let menu = makeMoreMenu()
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.minY - 4), in: sender)
    }

    func makeMoreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let undo = editorMenuItem("Undo Image Change", action: #selector(undoImageChange), key: "z")
        undo.isEnabled = view.window?.undoManager?.canUndo == true
        menu.addItem(undo)
        let redo = editorMenuItem("Redo Image Change", action: #selector(redoImageChange), key: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        redo.isEnabled = view.window?.undoManager?.canRedo == true
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(editorMenuItem("Review Suggested Redactions…", action: #selector(reviewRedactions)))
        menu.addItem(editorMenuItem("Preview Structured Text…", action: #selector(previewStructuredText)))
        menu.addItem(editorMenuItem("Redact…", action: #selector(beginRedact)))
        menu.addItem(editorMenuItem("Blur (Not Secure)…", action: #selector(beginBlur)))
        menu.addItem(.separator())
        menu.addItem(editorMenuItem("Crop…", action: #selector(beginCrop)))
        menu.addItem(editorMenuItem("Resize…", action: #selector(resizeImage)))
        menu.addItem(editorMenuItem("Rotate Left", action: #selector(rotateLeft)))
        menu.addItem(editorMenuItem("Rotate Right", action: #selector(rotateRight)))
        menu.addItem(editorMenuItem("Reset Image", action: #selector(resetImage)))
        menu.addItem(.separator())
        menu.addItem(editorMenuItem("Pin Above Windows", action: #selector(pinImage)))
        menu.addItem(editorMenuItem("Export PNG / JPEG…", action: #selector(exportImage), key: "s"))
        menu.addItem(editorMenuItem("Save PNG Directly…", action: #selector(savePNG)))
        let shareProvider = makeShareProvider()
        let picker = NSSharingServicePicker(items: [shareProvider])
        sharingPicker = picker
        menu.addItem(picker.standardShareMenuItem)
        if !instantInspect.barcodes.isEmpty {
            menu.addItem(.separator())
            let codes = NSMenuItem(title: "Detected Codes", action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: "Detected Codes")
            for hit in instantInspect.barcodes {
                let code = NSMenuItem(title: hit.summary, action: nil, keyEquivalent: "")
                code.submenu = barcodeMenu(for: hit)
                submenu.addItem(code)
            }
            codes.submenu = submenu
            menu.addItem(codes)
        }
        return menu
    }

    private func showBarcodeMenu(for hit: InstantInspectBarcodeHit, at point: CGPoint) {
        guard instantInspect.isCurrent(revision: hit.revision) else { return }
        barcodeMenu(for: hit).popUp(positioning: nil, at: point, in: instantInspect.hitOverlayView)
    }

    private func barcodeMenu(for hit: InstantInspectBarcodeHit) -> NSMenu {
        let menu = NSMenu(title: hit.summary)
        let copy = NSMenuItem(title: "Copy Value", action: #selector(copyBarcodeValue(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = hit
        menu.addItem(copy)
        if let url = instantInspectSafeURL(hit.payloadString) {
            let title = url.host.map { "Open \($0)" } ?? "Open URL"
            let open = NSMenuItem(title: title, action: #selector(openBarcodeURL(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = hit
            menu.addItem(open)
        }
        return menu
    }

    @objc private func copyBarcodeValue(_ sender: NSMenuItem) {
        guard let hit = sender.representedObject as? InstantInspectBarcodeHit,
              instantInspect.isCurrent(revision: hit.revision) else { return }
        _ = ClipboardDeliveryOrder.shared.begin()
        NSPasteboard.general.clearContents()
        let copied: Bool
        if let string = hit.payloadString {
            copied = NSPasteboard.general.setString(string, forType: .string)
        } else if let data = hit.payloadData {
            copied = NSPasteboard.general.setData(data, forType: NSPasteboard.PasteboardType(UTType.data.identifier))
        } else {
            copied = false
        }
        report(copied ? "Code value copied" : "Couldn’t copy code value", beep: !copied)
    }

    @objc private func openBarcodeURL(_ sender: NSMenuItem) {
        guard let hit = sender.representedObject as? InstantInspectBarcodeHit,
              instantInspect.isCurrent(revision: hit.revision),
              let url = instantInspectSafeURL(hit.payloadString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func undoImageChange() {
        view.window?.undoManager?.undo()
    }

    @objc private func redoImageChange() {
        view.window?.undoManager?.redo()
    }

    private func editorMenuItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : [.command]
        item.target = self
        return item
    }

    @objc private func beginRedact() { beginRegionOperation(.redact) }
    @objc private func beginBlur() { beginRegionOperation(.blur) }
    @objc private func beginCrop() { beginRegionOperation(.crop) }

    private func beginRegionOperation(_ operation: RegionOperation) {
        guard actionTask == nil, regionOverlay == nil else { return }
        if inspectPresentation != .inactive { setInspectPresentation(.inactive) }
        let overlay = ImageRegionSelectionView(frame: markupController.view.frame, prompt: operation.prompt)
        overlay.autoresizingMask = [.width, .height]
        overlay.onFinish = { [weak self, weak overlay] rectangle in
            guard let self else { return }
            overlay?.removeFromSuperview()
            self.regionOverlay = nil
            self.actionButtons.forEach { $0.isEnabled = true }
            self.dragExportView?.isHidden = false
            self.refreshEditorInteraction()
            guard let rectangle else {
                self.report("Image action cancelled")
                return
            }
            guard let pixelRectangle = self.imagePixelRectangle(from: rectangle, overlayBounds: overlay?.bounds ?? .zero),
                  pixelRectangle.width >= 4,
                  pixelRectangle.height >= 4 else {
                self.report("Select at least 4 × 4 image pixels", beep: true)
                return
            }
            self.performRegionOperation(operation, rectangle: pixelRectangle)
        }
        regionOverlay = overlay
        refreshEditorInteraction()
        actionButtons.forEach { $0.isEnabled = false }
        dragExportView?.isHidden = true
        view.addSubview(overlay, positioned: .above, relativeTo: markupController.view)
        view.window?.makeFirstResponder(overlay)
        report(operation.prompt)
    }

    private func imagePixelRectangle(from rectangle: CGRect, overlayBounds: CGRect) -> CGRect? {
        editorImageRectangle(
            selection: rectangle,
            overlayBounds: overlayBounds,
            visibleImageFrame: markupController.contentVisibleFrame,
            imageBounds: imageBounds
        )
    }

    private func performRegionOperation(_ operation: RegionOperation, rectangle: CGRect) {
        switch operation {
        case .redact:
            performDestructiveImageAction(message: "Redacting and flattening…", status: "Redacted and flattened") {
                try redactedCGImage($0, in: rectangle)
            }
        case .blur:
            performDestructiveImageAction(message: "Blurring and flattening…", status: "Blurred and flattened — not secure") {
                try blurredNonsecureCGImage($0, in: rectangle)
            }
        case .crop:
            if rectangle.standardized == imageBounds.integral {
                report("Crop already matches the whole image")
                return
            }
            performDestructiveImageAction(message: "Cropping and flattening…", status: "Cropped and flattened") {
                try croppedCGImage($0, to: rectangle)
            }
        }
    }

    @objc private func rotateLeft() {
        performDestructiveImageAction(message: "Rotating and flattening…", status: "Rotated left and flattened") {
            try rotated90CGImage($0, clockwise: false)
        }
    }

    @objc private func rotateRight() {
        performDestructiveImageAction(message: "Rotating and flattening…", status: "Rotated right and flattened") {
            try rotated90CGImage($0, clockwise: true)
        }
    }

    @objc private func resizeImage() {
        guard actionTask == nil, regionOverlay == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Resize image"
        alert.informativeText = "Enter a pixel width. ScreenWren preserves the aspect ratio."
        alert.addButton(withTitle: "Resize")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "\(workingImage.width)")
        field.frame = CGRect(x: 0, y: 0, width: 240, height: 24)
        field.placeholderString = "Width in pixels"
        field.setAccessibilityLabel("Width in pixels")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let width = Int(field.stringValue), (1...20_000).contains(width) else {
            report("Enter a width from 1 to 20,000", beep: true)
            return
        }
        let height = max(1, Int((Double(workingImage.height) * Double(width) / Double(workingImage.width)).rounded()))
        guard height <= 30_000, width * height <= 120_000_000 else {
            report("That resized image would be too large", beep: true)
            return
        }
        performDestructiveImageAction(message: "Resizing and flattening…", status: "Resized to \(width) × \(height) and flattened") {
            try resizedCGImagePreservingAspect($0, width: width)
        }
    }

    @objc private func resetImage() {
        guard actionTask == nil, regionOverlay == nil else { return }
        let bounds = CGRect(x: 0, y: 0, width: originalImage.width, height: originalImage.height)
        applySnapshot(Snapshot(image: originalImage, markup: PaperMarkup(bounds: bounds)), status: "Reset to original image")
    }

    private func performDestructiveImageAction(
        message: String,
        status: String,
        transform: @escaping @Sendable (CGImage) throws -> CGImage
    ) {
        guard actionTask == nil, let previous = currentSnapshot() else { return }
        beginImageAction(message)
        actionTask = Task { @MainActor [weak self] in
            defer { self?.finishImageAction() }
            guard let self else { return }
            do {
                let flattened = try await self.renderEditedImage()
                try Task.checkCancellation()
                let job = SendableImageTransform(image: flattened, transform: transform)
                let changed = try await Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return SendableImage(image: try job.transform(job.image))
                }.value.image
                try Task.checkCancellation()
                self.replaceWithFlattenedImage(changed, previous: previous, status: status)
            } catch is CancellationError {
            } catch {
                self.report(error.localizedDescription, beep: true)
            }
        }
    }

    @objc private func exportImage() {
        withFlattenedImage("Preparing export…") { [weak self] image in
            guard let self else { return }; self.exportWindow?.close()
            let window = ImageExportWindow(image: image, sourceScale: self.sourceScale)
            self.exportWindow = window; window.onClose = { [weak self] in self?.exportWindow = nil }
            window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil)
            self.report("Export preview opened")
        }
    }
    @objc private func previewStructuredText() {
        withFlattenedImage("Preparing text preview…") { [weak self] image in
            guard let self else { return }; self.textWindow?.close()
            let window = TextPreviewWindow(image: image); self.textWindow = window
            window.onClose = { [weak self] in self?.textWindow = nil }; window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil)
            self.report("Text preview opened")
        }
    }
    @objc private func reviewRedactions() {
        guard let previous = currentSnapshot() else { return }
        withFlattenedImage("Preparing redaction review…") { [weak self] image in
            guard let self else { return }; self.redactionWindow?.close()
            let window = RedactionReviewWindow(image: image, actionTitle: "Apply to Editor", copiesOnApproval: false) { [weak self] result, _ in
                self?.replaceWithFlattenedImage(result, previous: previous, status: "Redactions applied — copy when ready")
            }
            self.redactionWindow = window; window.onClose = { [weak self] in self?.redactionWindow = nil }
            if let parent = self.view.window, let sheet = window.window { parent.beginSheet(sheet) }
            self.report("Review redactions before applying")
        }
    }
    private func withFlattenedImage(_ message: String, completion: @escaping (CGImage) -> Void) {
        guard actionTask == nil, regionOverlay == nil else { return }; beginImageAction(message)
        actionTask = Task { @MainActor [weak self] in
            defer { self?.finishImageAction() }
            guard let self else { return }
            do { let image = try await self.renderEditedImage(); try Task.checkCancellation(); completion(image) }
            catch is CancellationError {} catch { self.report(error.localizedDescription, beep: true) }
        }
    }

    @objc private func savePNG() {
        guard actionTask == nil, regionOverlay == nil, let window = view.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = timestampedPNGFilename()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.beginImageAction("Rendering PNG…")
            self.actionTask = Task { @MainActor [weak self] in
                defer { self?.finishImageAction() }
                guard let self else { return }
                do {
                    let image = try await self.renderEditedImage()
                    try Task.checkCancellation()
                    let payload = SendableImage(image: image)
                    try await Task.detached(priority: .userInitiated) {
                        try Task.checkCancellation()
                        try pngData(for: payload.image).write(to: url, options: .atomic)
                    }.value
                    self.report("Saved \(url.lastPathComponent)")
                } catch is CancellationError {
                } catch {
                    self.report("Couldn’t save PNG", beep: true)
                }
            }
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        exportImage()
    }

    @objc private func pinImage() {
        guard actionTask == nil, regionOverlay == nil else { return }
        beginImageAction("Preparing pin…")
        actionTask = Task { @MainActor [weak self] in
            defer { self?.finishImageAction() }
            guard let self else { return }
            do {
                let image = try await self.renderEditedImage()
                try Task.checkCancellation()
                self.onPin(image)
                self.report("Pinned above windows")
            } catch is CancellationError {
            } catch {
                self.report("Couldn’t pin image", beep: true)
            }
        }
    }

    @objc private func copyText(_ sender: NSButton) {
        guard actionTask == nil, regionOverlay == nil else { return }
        let selectedText = instantInspect.selectedText
        let copiedSelection = selectedText != nil
        let clipboardGeneration = ClipboardDeliveryOrder.shared.begin()
        let clipboardChangeCount = NSPasteboard.general.changeCount
        beginImageAction("Reading text…")
        actionTask = Task { @MainActor [weak self] in
            defer { self?.finishImageAction() }
            guard let self else { return }
            do {
                guard let result = try await self.instantInspect.textForCopy(selectedText: selectedText) else {
                    self.report("No text found", beep: true)
                    return
                }
                try Task.checkCancellation()
                guard self.instantInspect.isCurrent(revision: result.revision) else {
                    self.report("Image changed before text could be copied")
                    return
                }
                guard ClipboardDeliveryOrder.shared.isCurrent(clipboardGeneration) else {
                    self.report("Copy superseded by a newer action")
                    return
                }
                guard clipboardStateIsUnchanged(since: clipboardChangeCount) else {
                    self.report("Newer clipboard content preserved")
                    return
                }
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(result.text, forType: .string) else {
                    self.report("Couldn’t copy text", beep: true)
                    return
                }
                self.report(copiedSelection ? "Selected text copied" : "Text copied")
            } catch is CancellationError {
            } catch {
                self.report("Couldn’t read text", beep: true)
            }
        }
    }

    @objc private func copySubject(_ sender: NSButton) {
        guard actionTask == nil, regionOverlay == nil else { return }
        let sourceImage = workingImage
        let requestedRevision = instantInspect.revision
        let clipboardGeneration = ClipboardDeliveryOrder.shared.begin()
        let clipboardChangeCount = NSPasteboard.general.changeCount
        beginImageAction("Finding subjects…")
        actionTask = Task { @MainActor [weak self] in
            defer { self?.finishImageAction() }
            guard let self else { return }
            do {
                let choice = await self.instantInspect.subjectChoice()
                try Task.checkCancellation()
                guard self.instantInspect.isCurrent(revision: requestedRevision) else {
                    self.report("Image changed before subject detection finished")
                    return
                }

                switch choice {
                case .single(let subject):
                    let image = try await subject.image()
                    try Task.checkCancellation()
                    if self.writeSubjectImage(
                        image,
                        revision: subject.revision,
                        clipboardGeneration: clipboardGeneration,
                        clipboardChangeCount: clipboardChangeCount
                    ) {
                        self.report("Subject copied")
                    }
                case .multiple:
                    self.setInspectPresentation(.subjectPicker)
                    self.report("Click the subject to copy · Esc returns to Edit")
                case .none, .unavailable:
                    guard let subject = try await liftedSubject(in: sourceImage) else {
                        self.report("No subject found", beep: true)
                        return
                    }
                    try Task.checkCancellation()
                    let size = NSSize(width: subject.width, height: subject.height)
                    if self.writeSubjectImage(
                        NSImage(cgImage: subject, size: size),
                        revision: requestedRevision,
                        clipboardGeneration: clipboardGeneration,
                        clipboardChangeCount: clipboardChangeCount
                    ) {
                        self.report("Subject copied")
                    }
                }
            } catch is CancellationError {
            } catch {
                self.report("Couldn’t lift subject", beep: true)
            }
        }
    }

    private func copySubject(at point: CGPoint) {
        guard inspectPresentation == .subjectPicker, actionTask == nil, regionOverlay == nil else { return }
        let requestedRevision = instantInspect.revision
        let clipboardGeneration = ClipboardDeliveryOrder.shared.begin()
        let clipboardChangeCount = NSPasteboard.general.changeCount
        beginImageAction("Lifting selected subject…")
        actionTask = Task { @MainActor [weak self] in
            defer { self?.finishImageAction() }
            guard let self else { return }
            do {
                guard let subject = await self.instantInspect.subject(at: point) else {
                    self.report("Click directly on a highlighted subject", beep: true)
                    return
                }
                let image = try await subject.image()
                try Task.checkCancellation()
                guard self.instantInspect.isCurrent(revision: requestedRevision) else {
                    self.report("Image changed before subject copy finished")
                    return
                }
                if self.writeSubjectImage(
                    image,
                    revision: subject.revision,
                    clipboardGeneration: clipboardGeneration,
                    clipboardChangeCount: clipboardChangeCount
                ) {
                    self.setInspectPresentation(.inspect)
                    self.report("Subject copied")
                }
            } catch is CancellationError {
            } catch {
                self.report("Couldn’t lift subject", beep: true)
            }
        }
    }

    private func writeSubjectImage(
        _ image: NSImage,
        revision: UInt64,
        clipboardGeneration: UInt64,
        clipboardChangeCount: Int
    ) -> Bool {
        guard instantInspect.isCurrent(revision: revision) else {
            report("Image changed before subject copy finished")
            return false
        }
        guard ClipboardDeliveryOrder.shared.isCurrent(clipboardGeneration) else {
            report("Copy superseded by a newer action")
            return false
        }
        guard clipboardStateIsUnchanged(since: clipboardChangeCount) else {
            report("Newer clipboard content preserved")
            return false
        }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([image]) else {
            report("Couldn’t copy subject", beep: true)
            return false
        }
        return true
    }

    func cancelPendingAction() {
        exportWindow?.close(); textWindow?.close(); redactionWindow?.close()
        removeEditorKeyMonitor()
        actionTask?.cancel()
        actionTask = nil
        actionIsActive = false
        instantInspect.cancel()
        inspectPresentation = .inactive
        inspectButton.state = .off
        regionOverlay?.removeFromSuperview()
        regionOverlay = nil
        actionButtons.forEach { $0.isEnabled = true }
        dragExportView?.isHidden = false
        refreshEditorInteraction()
    }

    private func beginImageAction(_ message: String) {
        actionIsActive = true
        actionButtons.forEach { $0.isEnabled = false }
        dragExportView?.isHidden = true
        refreshEditorInteraction()
        progressIndicator.startAnimation(nil)
        report(message)
    }

    private func finishImageAction() {
        actionTask = nil
        actionIsActive = false
        actionButtons.forEach { $0.isEnabled = true }
        dragExportView?.isHidden = false
        refreshEditorInteraction()
        if inspectPresentation != .inactive {
            view.window?.makeFirstResponder(instantInspect.firstResponder(for: inspectPresentation))
        }
        progressIndicator.stopAnimation(nil)
    }

    @objc private func copyUpdated() {
        copyRenderedImage(closeAfterSuccess: false)
    }

    @objc func copyAndClose(_ sender: Any?) {
        guard !(view.window?.firstResponder is NSTextView),
              view.window?.attachedSheet == nil,
              regionOverlay == nil else { return }
        copyRenderedImage(closeAfterSuccess: true)
    }

    private func copyRenderedImage(closeAfterSuccess: Bool) {
        guard actionTask == nil, regionOverlay == nil else { return }
        let clipboardGeneration = ClipboardDeliveryOrder.shared.begin()
        let clipboardChangeCount = NSPasteboard.general.changeCount
        beginImageAction("Rendering image…")
        actionTask = Task { @MainActor [weak self] in
            defer { self?.finishImageAction() }
            guard let self else { return }
            do {
                let image = try await self.renderEditedImage()
                try Task.checkCancellation()
                guard ClipboardDeliveryOrder.shared.isCurrent(clipboardGeneration) else {
                    self.report("Copy superseded by a newer action")
                    return
                }
                guard clipboardStateIsUnchanged(since: clipboardChangeCount) else {
                    self.report("Newer clipboard content preserved")
                    return
                }
                let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: bounds.size)]) else {
                    self.report("Couldn’t copy image", beep: true)
                    return
                }
                self.report("Edited image copied")
                if closeAfterSuccess {
                    self.view.window?.performClose(nil)
                }
            } catch is CancellationError {
            } catch {
                self.report("Couldn’t render image", beep: true)
            }
        }
    }

    private func makeExportProvider() -> NSFilePromiseProvider {
        guard let snapshot = currentSnapshot() else {
            return makePNGFilePromiseProvider { throw EditorError.couldNotRender }
        }
        return makePNGFilePromiseProvider { @MainActor in
            let rendered = try await Self.renderSnapshot(snapshot)
            return try await pngDataOffMain(for: rendered)
        }
    }

    private func makeShareProvider() -> NSItemProvider {
        guard let snapshot = currentSnapshot() else {
            return makePNGItemProvider { throw EditorError.couldNotRender }
        }
        return makePNGItemProvider { @MainActor in
            let rendered = try await Self.renderSnapshot(snapshot)
            return try await pngDataOffMain(for: rendered)
        }
    }

    private func renderEditedImage() async throws -> CGImage {
        guard let snapshot = currentSnapshot() else { throw EditorError.couldNotRender }
        return try await Self.renderSnapshot(snapshot)
    }

    private static func renderSnapshot(_ snapshot: Snapshot) async throws -> CGImage {
        let sourceImage = snapshot.image
        let markup = snapshot.markup
        guard
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: sourceImage.width,
                height: sourceImage.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw EditorError.couldNotRender }
        let bounds = CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height)
        context.draw(sourceImage, in: bounds)
        await markup.draw(in: context, frame: bounds)
        try Task.checkCancellation()
        guard let image = context.makeImage() else { throw EditorError.couldNotRender }
        return image
    }

    private func currentSnapshot() -> Snapshot? {
        guard let markup = markupController.markup else { return nil }
        return Snapshot(image: workingImage, markup: markup)
    }

    private func applySnapshot(_ snapshot: Snapshot, status: String, registerUndo: Bool = true) {
        let previous = currentSnapshot()
        workingImage = snapshot.image
        workingImageDidChange(to: snapshot.image)
        imageBounds = CGRect(x: 0, y: 0, width: snapshot.image.width, height: snapshot.image.height)
        imageView.frame = imageBounds
        imageView.image = NSImage(cgImage: snapshot.image, size: imageBounds.size)
        imageView.setAccessibilityLabel("Captured image, \(snapshot.image.width) by \(snapshot.image.height) pixels")
        markupController.markup = snapshot.markup
        view.window?.subtitle = "\(snapshot.image.width) × \(snapshot.image.height)"
        markupController.setContentVisibleFrame(imageBounds.insetBy(dx: -24, dy: -24), animated: false)
        instantInspect.updateGeometry()
        report(undoManager?.isRedoing == true ? "Redid image change" : status)

        if registerUndo, let previous {
            undoManager?.registerUndo(withTarget: self) { target in
                target.applySnapshot(previous, status: "Undid image change")
            }
            undoManager?.setActionName("Image Change")
        }
    }

    private func replaceWithFlattenedImage(_ image: CGImage, previous: Snapshot, status: String) {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        workingImage = image
        workingImageDidChange(to: image)
        imageBounds = bounds
        imageView.frame = bounds
        imageView.image = NSImage(cgImage: image, size: bounds.size)
        imageView.setAccessibilityLabel("Captured image, \(image.width) by \(image.height) pixels")
        markupController.markup = PaperMarkup(bounds: bounds)
        view.window?.subtitle = "\(image.width) × \(image.height)"
        markupController.setContentVisibleFrame(bounds.insetBy(dx: -24, dy: -24), animated: false)
        instantInspect.updateGeometry()
        undoManager?.registerUndo(withTarget: self) { target in
            target.applySnapshot(previous, status: "Undid image change")
        }
        undoManager?.setActionName("Image Change")
        report(status)
    }

    private func workingImageDidChange(to image: CGImage) {
        instantInspect.install(image: image)
        if inspectPresentation == .subjectPicker {
            setInspectPresentation(.inspect)
        }
    }

    func paperMarkupViewControllerDidChangeContentVisibleFrame(
        _ paperMarkupViewController: PaperMarkupViewController
    ) {
        instantInspect.updateGeometry()
    }

    private func report(_ message: String, beep: Bool = false) {
        statusLabel.stringValue = message
        if beep { NSSound.beep() }
        NSAccessibility.post(
            element: NSApp!,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )
    }
}
