import AppKit
import Carbon.HIToolbox
import ImageIO
import XCTest

@testable import ScreenWren

final class WorkflowTests: XCTestCase {
    private func solid(_ color: CGColor, width: Int = 20, height: Int = 20) throws -> CGImage {
        try renderCGImage(width: width, height: height) { context in
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> NSColor {
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }
    @MainActor private func preferences() -> (WorkflowPreferences, UserDefaults, String) {
        let name = "ScreenWrenTests.Workflow.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (WorkflowPreferences(defaults: defaults), defaults, name)
    }

    @MainActor func testCopyOnlyDoesNotOpenAnEditorAndRetainsRecoverableCapture() throws {
        _ = NSApplication.shared
        let (preferences, defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(preferences.destination, .clipboard)
        XCTAssertFalse(preferences.showsThumbnail)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("previous", forType: .string)
        let coordinator = CaptureCoordinator(preferences: preferences, pasteboard: pasteboard)
        let before = NSApp.windows.filter(\.isVisible).count
        coordinator.finishImageCapture(
            try solid(CGColor(gray: 1, alpha: 1)), scale: 2, destination: preferences.destination,
            clipboardGeneration: ClipboardDeliveryOrder.shared.begin(), clipboardChangeCount: pasteboard.changeCount)
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
        XCTAssertEqual(coordinator.recentCaptures.count, 1)
        XCTAssertEqual(coordinator.recentCaptures.first?.scale, 2)
        XCTAssertEqual(NSApp.windows.filter(\.isVisible).count, before)
    }
    @MainActor func testCapturePreservesNewerPasteboardOwner() throws {
        _ = NSApplication.shared
        let (preferences, defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let previous = pasteboard.changeCount
        let generation = ClipboardDeliveryOrder.shared.begin()
        pasteboard.clearContents()
        pasteboard.setString("newer content", forType: .string)
        let coordinator = CaptureCoordinator(preferences: preferences, pasteboard: pasteboard)
        coordinator.finishImageCapture(
            try solid(CGColor(gray: 1, alpha: 1)), scale: 1, destination: .clipboard, clipboardGeneration: generation,
            clipboardChangeCount: previous)
        XCTAssertEqual(pasteboard.string(forType: .string), "newer content")
        XCTAssertEqual(coordinator.recentCaptures.count, 1)
    }
    @MainActor func testReviewAndCancelNeverCopyOrRetainAnUnreviewedRecent() throws {
        _ = NSApplication.shared
        let (preferences, defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("untouched", forType: .string)
        let previous = pasteboard.changeCount
        let coordinator = CaptureCoordinator(preferences: preferences, pasteboard: pasteboard)
        coordinator.finishImageCapture(
            try solid(CGColor(gray: 1, alpha: 1)), scale: 1, destination: .review,
            clipboardGeneration: ClipboardDeliveryOrder.shared.begin(), clipboardChangeCount: previous)
        XCTAssertTrue(coordinator.recentCaptures.isEmpty)
        XCTAssertEqual(pasteboard.changeCount, previous)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "Review Redactions" && $0.isVisible })
        window.performClose(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "untouched")
        XCTAssertTrue(coordinator.recentCaptures.isEmpty)
    }
    @MainActor func testReviewTicketRejectsNewerExplicitCopyOrPasteboardChange() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let ticket = ClipboardTicket(on: pasteboard)
        XCTAssertTrue(ticket.isCurrent(on: pasteboard))
        pasteboard.clearContents()
        pasteboard.setString("new", forType: .string)
        XCTAssertFalse(ticket.isCurrent(on: pasteboard))
        let second = ClipboardTicket(on: pasteboard)
        _ = ClipboardDeliveryOrder.shared.begin()
        XCTAssertFalse(second.isCurrent(on: pasteboard))
    }
    @MainActor func testCapturePreferencesPersistWithoutCaptureDataAndRejectInvalidPresets() {
        let (preferences, defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        preferences.destination = .review
        preferences.fixedSize = CGSize(width: 640, height: 480)
        preferences.aspectRatio = 4.0 / 3
        preferences.presets = [
            SelectionPreset(name: "", width: 400, height: 300), SelectionPreset(name: "Card", width: 640, height: 480),
        ]
        let restored = WorkflowPreferences(defaults: defaults)
        XCTAssertEqual(restored.destination, .review)
        XCTAssertEqual(restored.fixedSize, CGSize(width: 640, height: 480))
        XCTAssertEqual(restored.presets.count, 1)
        XCTAssertEqual(restored.presets[0].name, "Card")
    }
    func testFixedSelectionAndRatioStayWithinDesktop() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertEqual(
            constrainedSelection(
                from: .zero, to: CGPoint(x: 790, y: 590), bounds: bounds, fixedSize: CGSize(width: 100, height: 80),
                ratio: nil), CGRect(x: 700, y: 520, width: 100, height: 80))
        let ratio = constrainedSelection(
            from: CGPoint(x: 20, y: 20), to: CGPoint(x: 700, y: 400), bounds: bounds, fixedSize: nil, ratio: 16.0 / 9)
        XCTAssertEqual(ratio.width / ratio.height, 16.0 / 9, accuracy: 0.0001)
        XCTAssertTrue(bounds.contains(ratio))
        let moved = adjustedSelection(
            CGRect(x: 740, y: 550, width: 60, height: 50), dx: 100, dy: 100, resizing: false, bounds: bounds)
        XCTAssertEqual(moved, CGRect(x: 740, y: 550, width: 60, height: 50))
    }
    @MainActor func testPrecisionSelectionWaitsForReturnAndMovesByOnePhysicalPixel() throws {
        _ = NSApplication.shared
        let view = SelectionView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300), pixelScale: 2, prompt: "Test", allowsWindows: false,
            options: SelectionOptions(adjustBeforeCapture: true))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        var captured: CGRect?
        view.onFinish = { if case .region(let rect) = $0 { captured = rect } }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 20, y: 30)))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 120, y: 130)))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 120, y: 130)))
        XCTAssertNil(captured)
        let right = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: UInt16(kVK_RightArrow))!
        view.keyDown(with: right)
        let enter = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
            keyCode: UInt16(kVK_Return))!
        view.keyDown(with: enter)
        XCTAssertEqual(captured, CGRect(x: 20.5, y: 30, width: 100, height: 100))
    }
    func testMixedScaleDesktopCompositionHasNoSeamOrCoordinateShift() throws {
        let displays = [
            DesktopDisplay(id: 1, frame: CGRect(x: -100, y: 0, width: 100, height: 100), scale: 1),
            DesktopDisplay(id: 2, frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2),
        ]
        let plan = try desktopCapturePlan(rect: CGRect(x: -20, y: 20, width: 40, height: 30), displays: displays)
        XCTAssertEqual(plan.size, CGSize(width: 80, height: 60))
        XCTAssertEqual(
            plan.slices.map(\.outputFrame),
            [CGRect(x: 0, y: 0, width: 40, height: 60), CGRect(x: 40, y: 0, width: 40, height: 60)])
        let image = try composeDesktopImages(
            [
                solid(CGColor(red: 1, green: 0, blue: 0, alpha: 1), width: 20, height: 30),
                solid(CGColor(red: 0, green: 0, blue: 1, alpha: 1), width: 40, height: 60),
            ], plan: plan)
        XCTAssertGreaterThan(try pixel(image, 39, 30).redComponent, 0.95)
        XCTAssertGreaterThan(try pixel(image, 40, 30).blueComponent, 0.95)
    }
    @MainActor func testFourPixelFixedSelectionWorksOnRetina() throws {
        _ = NSApplication.shared
        let view = SelectionView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300), pixelScale: 2, prompt: "Test", allowsWindows: false,
            options: SelectionOptions(fixedSize: CGSize(width: 4, height: 4)))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        var captured: CGRect?
        view.onFinish = { if case .region(let rect) = $0 { captured = rect } }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: CGPoint(x: 20, y: 30), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
        XCTAssertEqual(captured?.size, CGSize(width: 2, height: 2))
    }
    func testDesktopGapIsTransparentAndInvalidOrHugePlansAreRejected() throws {
        let displays = [
            DesktopDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 20, height: 20), scale: 1),
            DesktopDisplay(id: 2, frame: CGRect(x: 30, y: 0, width: 20, height: 20), scale: 1),
        ]
        let plan = try desktopCapturePlan(rect: CGRect(x: 0, y: 0, width: 50, height: 20), displays: displays)
        let image = try composeDesktopImages(
            [solid(CGColor(gray: 1, alpha: 1)), solid(CGColor(gray: 1, alpha: 1))], plan: plan)
        XCTAssertLessThan(try pixel(image, 25, 10).alphaComponent, 0.01)
        XCTAssertThrowsError(
            try desktopCapturePlan(rect: CGRect(x: 22, y: 0, width: 4, height: 20), displays: displays))
        XCTAssertThrowsError(
            try desktopCapturePlan(rect: CGRect(x: 0, y: 0, width: 100_000, height: 100_000), displays: displays))
        XCTAssertThrowsError(try composeDesktopImages([], plan: plan))
    }
    func testJPEGExportUsesLogicalResolutionAndFlattensTransparencyToWhite() throws {
        let image = try solid(CGColor(gray: 0, alpha: 0), width: 80, height: 40)
        let data = try encodedImage(
            image, sourceScale: 2, options: ImageExportOptions(format: .jpeg, resolution: .logical, quality: 0.9))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let output = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(output.width, 40)
        XCTAssertEqual(output.height, 20)
        XCTAssertGreaterThan(try pixel(output, 5, 5).redComponent, 0.97)
        XCTAssertGreaterThan(try pixel(output, 5, 5).alphaComponent, 0.99)
    }
    func testPNGExportPreservesPixelsAndTransparency() throws {
        let image = try solid(CGColor(gray: 0, alpha: 0), width: 21, height: 13)
        let data = try encodedImage(image, sourceScale: 2, options: ImageExportOptions())
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let output = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(output.width, 21)
        XCTAssertEqual(output.height, 13)
        XCTAssertLessThan(try pixel(output, 4, 4).alphaComponent, 0.01)
    }
    func testCombinePreservesImageOrderAndBoundsForEveryLayout() throws {
        let red = try solid(CGColor(red: 1, green: 0, blue: 0, alpha: 1), width: 20, height: 10)
        let blue = try solid(CGColor(red: 0, green: 0, blue: 1, alpha: 1), width: 10, height: 20)
        let vertical = try combinedImages([red, blue], layout: .vertical)
        XCTAssertEqual(vertical.width, 20)
        XCTAssertEqual(vertical.height, 46)
        XCTAssertGreaterThan(try pixel(vertical, 5, 4).redComponent, 0.95)
        XCTAssertGreaterThan(try pixel(vertical, 5, 30).blueComponent, 0.95)
        let horizontal = try combinedImages([red, blue], layout: .horizontal)
        XCTAssertEqual(horizontal.width, 46)
        XCTAssertEqual(horizontal.height, 20)
        let grid = try compositionPlan(
            sizes: [CGSize(width: 20, height: 10), CGSize(width: 10, height: 20), CGSize(width: 20, height: 10)],
            layout: .grid)
        XCTAssertEqual(grid.frames[2].origin, CGPoint(x: 0, y: 36))
        XCTAssertThrowsError(
            try compositionPlan(
                sizes: [CGSize(width: 30_000, height: 30_000), CGSize(width: 1, height: 1)], layout: .vertical))
        XCTAssertThrowsError(try combinedImages([red], layout: .vertical))
    }
    func testRedactionSuggestionsAndPixelsAreConservative() throws {
        let line = RecognizedLine(
            text: "Contact alice@example.com", bounds: CGRect(x: 0.1, y: 0.7, width: 0.7, height: 0.1))
        let suggestions = redactionSuggestions(in: [line], emails: true, phones: false, matching: "")
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].bounds, line.bounds)
        XCTAssertTrue(redactionSuggestions(in: [line], emails: false, phones: false, matching: "").isEmpty)
        XCTAssertEqual(
            redactionSuggestions(in: [line], emails: false, phones: false, matching: "ALICE@EXAMPLE.COM").count, 1)
        let white = try solid(CGColor(gray: 1, alpha: 1), width: 100, height: 100)
        let redacted = try applyRedactions(white, bounds: suggestions.map(\.bounds))
        XCTAssertLessThan(try pixel(redacted, 20, 25).redComponent, 0.01)
        XCTAssertGreaterThan(try pixel(redacted, 20, 25).alphaComponent, 0.99)
        XCTAssertGreaterThan(try pixel(redacted, 20, 75).redComponent, 0.99)
    }
    func testTableFormattingKeepsMissingCellsAndRowOrder() {
        let lines = [
            RecognizedLine(text: "A", bounds: CGRect(x: 0.1, y: 0.8, width: 0.02, height: 0.05)),
            RecognizedLine(text: "B", bounds: CGRect(x: 0.5, y: 0.8, width: 0.02, height: 0.05)),
            RecognizedLine(text: "C", bounds: CGRect(x: 0.5, y: 0.6, width: 0.02, height: 0.05)),
        ]
        XCTAssertEqual(formattedRecognizedText(lines.reversed(), layout: .table), "A\tB\n\tC")
    }
    func testCodeFormattingPreservesIndentationWithoutRewritingText() {
        let lines = [
            RecognizedLine(text: "if x:", bounds: CGRect(x: 0.1, y: 0.8, width: 0.1, height: 0.06)),
            RecognizedLine(text: "run()", bounds: CGRect(x: 0.18, y: 0.72, width: 0.1, height: 0.06)),
        ]
        XCTAssertEqual(formattedRecognizedText(lines, layout: .code), "if x:\n    run()")
    }
    @MainActor func testThumbnailNeverBecomesKeyAndClosingCancelsIt() throws {
        _ = NSApplication.shared
        let quick = QuickCaptureWindow(image: try solid(CGColor(gray: 1, alpha: 1)), onAction: { _ in })
        XCTAssertFalse(try XCTUnwrap(quick.window).canBecomeKey)
        var closed = 0
        quick.onClose = { closed += 1 }
        quick.close()
        quick.close()
        XCTAssertEqual(closed, 1)
    }
    @MainActor func testNewCaptureShortcutsDoNotConflict() {
        let shortcuts = Dictionary(uniqueKeysWithValues: ShortcutCommand.allCases.map { ($0, $0.defaultShortcut) })
        XCTAssertTrue(conflictingShortcutCommands(shortcuts).isEmpty)
        XCTAssertNotNil(ShortcutCommand.recents.defaultShortcut)
        XCTAssertNotNil(ShortcutCommand.togglePins.defaultShortcut)
    }
    @MainActor func testEditorRedactionDoesNotSupersedePendingClipboardDelivery() async throws {
        _ = NSApplication.shared
        var applied = false
        let controller = RedactionReviewWindow(
            image: try solid(CGColor(gray: 1, alpha: 1)), actionTitle: "Apply to Editor", copiesOnApproval: false
        ) { _, ticket in
            XCTAssertNil(ticket)
            applied = true
        }
        defer { controller.close() }
        var pending = try XCTUnwrap(controller.window?.contentView).subviews
        var apply: NSButton?
        while let view = pending.popLast() {
            if let button = view as? NSButton, button.title == "Apply to Editor" { apply = button }
            pending.append(contentsOf: view.subviews)
        }
        let button = try XCTUnwrap(apply)
        for _ in 0..<200 where !button.isEnabled { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(button.isEnabled)
        let generation = ClipboardDeliveryOrder.shared.begin()
        button.performClick(nil)
        for _ in 0..<200 where !applied { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(applied)
        XCTAssertTrue(ClipboardDeliveryOrder.shared.isCurrent(generation))
    }

    @MainActor func testNewWindowLayoutsUsingSyntheticImages() async throws {
        _ = NSApplication.shared
        let (preferences, defaults, name) = preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let fixture = try renderCGImage(width: 800, height: 360) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 360))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 23, weight: .medium), .foregroundColor: NSColor.black,
            ]
            for (index, line) in [
                "SCREENWREN TEST CAPTURE", "Contact: alex@example.com", "Phone: +1 202-555-0123",
                "Item          Qty       Total", "Widgets       2         40.00", "Adapters      1         12.00",
            ].enumerated() {
                (line as NSString).draw(at: CGPoint(x: 30, y: 310 - index * 47), withAttributes: attributes)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        let recent = RecentPickerWindow(onAction: { _, _ in }, onCombine: { _, _ in }, onDelete: { _ in })
        recent.update([SessionCapture(image: fixture), SessionCapture(image: fixture)])
        let controllers: [(String, NSWindowController)] = [
            ("preferences", WorkflowPreferencesWindow(preferences: preferences)),
            ("export", ImageExportWindow(image: fixture, sourceScale: 2)),
            ("recents", recent),
            ("text", TextPreviewWindow(image: fixture)),
            ("redaction", RedactionReviewWindow(image: fixture, actionTitle: "Approve & Copy", onApply: { _, _ in })),
            ("pin", PinnedWindowController(image: fixture, sourceScale: 2)),
            ("thumbnail", QuickCaptureWindow(image: fixture, onAction: { _ in })),
        ]
        defer { controllers.forEach { $0.1.close() } }
        try await Task.sleep(for: .milliseconds(500))
        for (name, controller) in controllers {
            let root = try XCTUnwrap(controller.window?.contentView)
            root.layoutSubtreeIfNeeded()
            if name == "export" { XCTAssertEqual(root.bounds.width, 540, accuracy: 1) }
            if name == "thumbnail" { XCTAssertEqual(root.bounds.width, 290, accuracy: 1) }
            var pending = root.subviews
            while let view = pending.popLast() {
                if view is NSScrollView { continue }
                if let slider = view as? NSSlider {
                    XCTAssertGreaterThanOrEqual(slider.bounds.width, 60, "\(name): slider is too narrow")
                }
                if let button = view as? NSButton, !button.isHidden {
                    let rect = button.convert(button.bounds, to: root)
                    XCTAssertGreaterThan(rect.width, 0, "\(name): \(button.title)")
                    XCTAssertTrue(
                        root.bounds.insetBy(dx: -2, dy: -2).contains(rect),
                        "\(name): \(button.title) outside window: \(rect)")
                }
                pending.append(contentsOf: view.subviews)
            }
            if let directory = ProcessInfo.processInfo.environment["SCREENWREN_FEATURE_PREVIEWS"] {
                let folder = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.cacheDisplay(in: root.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                    to: folder.appendingPathComponent(name + ".png"))
                if name == "preferences" {
                    try pngData(for: fixture).write(to: folder.appendingPathComponent("fixture.png"))
                }
            }
        }
    }

}
