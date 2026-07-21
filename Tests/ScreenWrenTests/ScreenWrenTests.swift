import AppKit
import Carbon.HIToolbox
import CoreGraphics
import UniformTypeIdentifiers
import XCTest
@testable import ScreenWren

final class ScreenWrenLogicTests: XCTestCase {
    func testScreenCapturePermissionPhasesIncludeAnActionableRelaunchState() {
        XCTAssertEqual(screenCapturePermissionPhase(isAllowed: true, wasRequested: true, requestGranted: true), .allowed)
        XCTAssertEqual(screenCapturePermissionPhase(isAllowed: false, wasRequested: false, requestGranted: false), .needsPermission)
        XCTAssertEqual(screenCapturePermissionPhase(isAllowed: false, wasRequested: true, requestGranted: false), .openSettings)
        XCTAssertEqual(screenCapturePermissionPhase(isAllowed: false, wasRequested: true, requestGranted: true), .needsRelaunch)
    }

    func testCaptureGenerationRejectsStaleCompletion() {
        XCTAssertTrue(isCurrentCapture(8, currentGeneration: 8))
        XCTAssertFalse(isCurrentCapture(7, currentGeneration: 8))
    }

    func testHotKeyIDsDispatchOnlyTheirOwnCommand() {
        let capture = EventHotKeyID(signature: 0x5357524E, id: 1)
        let text = EventHotKeyID(signature: 0x5357524E, id: 2)
        XCTAssertTrue(hotKeyIdentifiersMatch(capture, capture))
        XCTAssertFalse(hotKeyIdentifiersMatch(capture, text))
    }

    func testLoupePointsAtClampedSamplePixelIncludingMaximumSelectionEdges() {
        let selection = CGRect(x: 10, y: 20, width: 30, height: 40)
        XCTAssertEqual(
            loupePixel(
                at: CGPoint(x: 40, y: 60),
                inside: selection,
                viewSize: CGSize(width: 100, height: 100),
                imageSize: CGSize(width: 200, height: 200)
            ),
            CGPoint(x: 79, y: 80)
        )

        let sample = CGRect(x: 0, y: 0, width: 15, height: 15)
        let frame = CGRect(x: 20, y: 30, width: 150, height: 150)
        XCTAssertEqual(
            loupeCrosshairPoint(pixel: .zero, sample: sample, frame: frame),
            CGPoint(x: 25, y: 175)
        )
    }

    func testFrozenSelectionMapsAppKitBottomLeftToImageTopLeft() throws {
        let rectangle = try XCTUnwrap(frozenImagePixelRect(
            selection: CGRect(x: 10, y: 70, width: 30, height: 20),
            viewSize: CGSize(width: 100, height: 100),
            imageSize: CGSize(width: 200, height: 200)
        ))
        XCTAssertEqual(rectangle, CGRect(x: 20, y: 20, width: 60, height: 40))
    }

    func testShortcutConflictsAreDetectedBeforeRegistration() {
        let duplicate = Shortcut(
            keyCode: UInt32(kVK_ANSI_P),
            carbonModifiers: UInt32(controlKey),
            keyEquivalent: "p",
            keyLabel: "P"
        )
        let values: [ShortcutCommand: Shortcut?] = [
            .capture: duplicate,
            .copyText: duplicate,
            .repeatCapture: nil,
        ]
        XCTAssertEqual(conflictingShortcutCommands(values), [.capture, .copyText])
    }

    func testRepeatTargetUsesSpecificMenuLabel() {
        XCTAssertEqual(
            RepeatTarget.window(WindowIdentity(windowID: 7, processID: 9, bundleIdentifier: "example.app")).menuTitle,
            "Repeat Last Window"
        )
    }

    func testEditorSingleKeyCommandsNeverStealTextEntry() {
        XCTAssertEqual(
            editorKeyboardCommand(
                keyCode: UInt16(kVK_ANSI_A),
                modifiers: [],
                isTextEntry: false,
                hasSheet: false,
                hasRegionOverlay: false
            ),
            .arrow
        )
        XCTAssertEqual(
            editorKeyboardCommand(
                keyCode: UInt16(kVK_Return),
                modifiers: [.command],
                isTextEntry: false,
                hasSheet: false,
                hasRegionOverlay: false
            ),
            .copyAndClose
        )
        XCTAssertNil(editorKeyboardCommand(
            keyCode: UInt16(kVK_ANSI_A),
            modifiers: [],
            isTextEntry: true,
            hasSheet: false,
            hasRegionOverlay: false
        ))
        XCTAssertNil(editorKeyboardCommand(
            keyCode: UInt16(kVK_ANSI_R),
            modifiers: [],
            isTextEntry: false,
            hasSheet: true,
            hasRegionOverlay: false
        ))
    }

    func testEditorSelectionMapsTopToTop() throws {
        let image = CGRect(x: 0, y: 0, width: 100, height: 100)
        let top = try XCTUnwrap(editorImageRectangle(
            selection: CGRect(x: 0, y: 80, width: 100, height: 20),
            overlayBounds: image,
            visibleImageFrame: image,
            imageBounds: image
        ))
        let bottom = try XCTUnwrap(editorImageRectangle(
            selection: CGRect(x: 0, y: 0, width: 100, height: 20),
            overlayBounds: image,
            visibleImageFrame: image,
            imageBounds: image
        ))
        XCTAssertEqual(top, CGRect(x: 0, y: 0, width: 100, height: 20))
        XCTAssertEqual(bottom, CGRect(x: 0, y: 80, width: 100, height: 20))

        let pannedTop = try XCTUnwrap(editorImageRectangle(
            selection: CGRect(x: 0, y: 80, width: 100, height: 20),
            overlayBounds: image,
            visibleImageFrame: CGRect(x: 0, y: 500, width: 100, height: 400),
            imageBounds: CGRect(x: 0, y: 0, width: 100, height: 1_000)
        ))
        XCTAssertEqual(pannedTop, CGRect(x: 0, y: 100, width: 100, height: 80))
    }

    func testImageOperationsAndScrollingFixtures() throws {
        XCTAssertNoThrow(try runImageOperationsSelfCheck())

        let frame = try renderCGImage(width: 32, height: 32) { context in
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        XCTAssertThrowsError(try validateScrollingPair(previous: frame, next: frame)) { error in
            XCTAssertEqual(error as? ImageOperationsError, .duplicateFrame(index: 1))
        }
        XCTAssertEqual(
            try checkedScrollingOutputHeight(
                width: 1_000,
                currentHeight: 29_000,
                frameHeight: 2_000,
                overlap: 1_000
            ),
            30_000
        )
        XCTAssertThrowsError(
            try checkedScrollingOutputHeight(
                width: 1_000,
                currentHeight: 30_000,
                frameHeight: 2_000,
                overlap: 1_000
            )
        ) { error in
            XCTAssertEqual(error as? ImageOperationsError, .outputTooLarge)
        }
    }

    func testPNGFilenameIsFilesystemSafe() {
        let name = timestampedPNGFilename(for: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(name.hasPrefix("ScreenWren Capture "))
        XCTAssertTrue(name.hasSuffix(".png"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertFalse(name.contains("/"))
    }

    func testOCRReadingOrderIsTopToBottomThenLeftToRight() {
        let boxes = [
            CGRect(x: 0.60, y: 0.805, width: 0.20, height: 0.05),
            CGRect(x: 0.10, y: 0.30, width: 0.20, height: 0.05),
            CGRect(x: 0.10, y: 0.80, width: 0.20, height: 0.05),
        ]
        XCTAssertEqual(readingOrderIndices(for: boxes), [2, 0, 1])
    }

    func testInstantInspectCopiesAnExactSelectionBeforeTheFullTranscript() {
        XCTAssertEqual(
            instantInspectText(selectedText: "  exact\nselection  ", fullText: "whole image"),
            "  exact\nselection  "
        )
        XCTAssertEqual(instantInspectText(selectedText: " \n ", fullText: "whole image"), "whole image")
        XCTAssertNil(instantInspectText(selectedText: nil, fullText: " \n "))
    }

    func testInstantInspectNeverChoosesArbitrarilyAmongMultipleSubjects() {
        XCTAssertEqual(instantInspectSubjectDecision(count: 0), .none)
        XCTAssertEqual(instantInspectSubjectDecision(count: 1), .copySingle)
        XCTAssertEqual(instantInspectSubjectDecision(count: 2), .pickOne)
    }

    func testInstantInspectRevisionRejectsLateAnalysis() {
        XCTAssertTrue(isCurrentInstantInspectRevision(4, current: 4))
        XCTAssertFalse(isCurrentInstantInspectRevision(3, current: 4))
    }

    func testBarcodeRectMapsVisionBottomLeftIntoOverlayTopLeft() {
        let rect = instantInspectBarcodeRect(
            visionRect: CGRect(x: 0.25, y: 0.60, width: 0.50, height: 0.20),
            contentRect: CGRect(x: 0.10, y: 0.20, width: 0.80, height: 0.50),
            overlayBounds: CGRect(x: 0, y: 0, width: 1_000, height: 600)
        )
        XCTAssertEqual(rect.minX, 300, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 180, accuracy: 0.001)
        XCTAssertEqual(rect.width, 400, accuracy: 0.001)
        XCTAssertEqual(rect.height, 60, accuracy: 0.001)
    }

    func testBarcodeURLsRequireAnExplicitWebDestination() {
        XCTAssertEqual(instantInspectSafeURL("https://example.com/path")?.host, "example.com")
        XCTAssertNil(instantInspectSafeURL("javascript:alert(1)"))
        XCTAssertNil(instantInspectSafeURL("file:///tmp/example"))
        XCTAssertNil(instantInspectSafeURL("not a URL"))
    }

    @MainActor
    func testVisionOCRReadsRenderedFixture() async throws {
        let image = try renderCGImage(width: 720, height: 180) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 720, height: 180))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            ("SCREENWREN OCR 2468" as NSString).draw(
                at: CGPoint(x: 32, y: 52),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 58, weight: .bold),
                    .foregroundColor: NSColor.black,
                ]
            )
            NSGraphicsContext.restoreGraphicsState()
        }
        let text = try await recognizedText(in: image)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("SCREENWREN OCR"), "Recognized: \(text)")
        XCTAssertTrue(text.contains("2468"), "Recognized: \(text)")
    }

    func testTransparentWindowsAreNotSnapCandidates() {
        XCTAssertTrue(windowAlphaIsEligible(nil))
        XCTAssertTrue(windowAlphaIsEligible(1))
        XCTAssertFalse(windowAlphaIsEligible(0))
        XCTAssertFalse(windowAlphaIsEligible(0.005))
    }

    func testRegionFilterIsCachedOnlyWithAnAppWideExclusion() {
        XCTAssertTrue(shouldCacheRegionFilter(hasExcludedApplication: true))
        XCTAssertFalse(shouldCacheRegionFilter(hasExcludedApplication: false))
    }

    @MainActor
    func testOnlyLatestClipboardDeliveryTokenCanCommit() {
        let order = ClipboardDeliveryOrder()
        let first = order.begin()
        XCTAssertTrue(order.isCurrent(first))
        let second = order.begin()
        XCTAssertFalse(order.isCurrent(first))
        XCTAssertTrue(order.isCurrent(second))
    }

    func testClipboardChangeCountDetectsAnExternalReplacement() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("screenwren.qa.\(UUID().uuidString)"))
        let initial = pasteboard.changeCount
        XCTAssertTrue(clipboardStateIsUnchanged(since: initial, on: pasteboard))
        pasteboard.clearContents()
        XCTAssertFalse(clipboardStateIsUnchanged(since: initial, on: pasteboard))
    }

    @MainActor
    func testEditorExposesEveryPromisedAction() throws {
        let image = try renderCGImage(width: 80, height: 60) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        }
        let editor = EditorViewController(image: image, initialStatus: "QA") { _ in }
        editor.loadViewIfNeeded()
        let menu = editor.makeMoreMenu()
        let titles = Set(menu.items.map(\.title))
        for expected in [
            "Redact…", "Blur (Not Secure)…", "Crop…", "Resize…",
            "Rotate Left", "Rotate Right", "Reset Image", "Pin Above Windows",
            "Save PNG…",
        ] {
            XCTAssertTrue(titles.contains(expected), "Missing editor action: \(expected)")
        }
        XCTAssertTrue(titles.contains(where: { $0.localizedCaseInsensitiveContains("share") }))
        let redo = try XCTUnwrap(menu.items.first(where: { $0.title == "Redo Image Change" }))
        XCTAssertEqual(redo.keyEquivalent, "Z")
        XCTAssertTrue(redo.keyEquivalentModifierMask.contains([.command, .shift]))
        XCTAssertTrue(editor.responds(to: #selector(EditorViewController.saveDocument(_:))))
    }

    @MainActor
    func testReadinessWindowLaysOutAndRendersItsPermissionControls() throws {
        _ = NSApplication.shared
        let suiteName = "ScreenWrenTests.Readiness.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = ShortcutManager(store: ShortcutStore(defaults: defaults), actions: [:])
        let readiness = ReadinessWindowController(
            shortcutManager: manager,
            launchAtLogin: LaunchAtLoginController()
        )
        let window = try XCTUnwrap(readiness.window)
        let root = try XCTUnwrap(window.contentViewController?.view)
        root.layoutSubtreeIfNeeded()

        var queue = [root]
        var views: [NSView] = []
        while let view = queue.popLast() {
            views.append(view)
            queue.append(contentsOf: view.subviews)
        }
        let text = views.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n")
        XCTAssertTrue(text.contains("Make ScreenWren ready"))
        XCTAssertTrue(text.contains("Screen & System Audio Recording"))
        XCTAssertTrue(text.contains("Keyboard Shortcuts"))
        XCTAssertEqual(views.compactMap { $0 as? ShortcutRecorderField }.count, ShortcutCommand.allCases.count)
        XCTAssertGreaterThan(views.filter { !$0.frame.isEmpty }.count, 20)
        XCTAssertEqual(root.bounds.size, CGSize(width: 620, height: 690))

        if let output = ProcessInfo.processInfo.environment["SCREENWREN_READINESS_PREVIEW"] {
            let representation = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: representation)
            let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }

    @MainActor
    func testApplicationMenuRoutesCommandSAndRedo() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        delegate.installMainMenu()
        let mainMenu = try XCTUnwrap(NSApp.mainMenu)
        let fileMenu = try XCTUnwrap(mainMenu.items.compactMap(\.submenu).first(where: { $0.title == "File" }))
        let save = try XCTUnwrap(fileMenu.items.first(where: { $0.action == #selector(EditorViewController.saveDocument(_:)) }))
        XCTAssertEqual(save.keyEquivalent, "s")
        XCTAssertTrue(save.keyEquivalentModifierMask.contains(.command))
        let copyAndClose = try XCTUnwrap(fileMenu.items.first(where: { $0.action == #selector(EditorViewController.copyAndClose(_:)) }))
        XCTAssertEqual(copyAndClose.keyEquivalent, "\r")
        XCTAssertEqual(copyAndClose.keyEquivalentModifierMask, [.command])
        let editMenu = try XCTUnwrap(mainMenu.items.compactMap(\.submenu).first(where: { $0.title == "Edit" }))
        let redo = try XCTUnwrap(editMenu.items.first(where: { $0.title == "Redo" }))
        XCTAssertEqual(redo.keyEquivalent, "Z")
        XCTAssertTrue(redo.keyEquivalentModifierMask.contains([.command, .shift]))
    }

    @MainActor
    func testPinIsCurrentSpaceFloatingPanel() throws {
        let image = try renderCGImage(width: 80, height: 60) { _ in }
        let pin = PinnedWindowController(image: image)
        let panel = try XCTUnwrap(pin.window as? NSPanel)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    @MainActor
    func testLazyPNGPromiseWritesExactBytes() async throws {
        let expected = Data([0x46, 0x4c, 0x41, 0x53, 0x48])
        let provider = makePNGFilePromiseProvider(filename: "fixture.png") { expected }
        let delegate = try XCTUnwrap(provider.userInfo as? PNGFilePromiseDelegate)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: destination) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.filePromiseProvider(provider, writePromiseTo: destination) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
        XCTAssertEqual(try Data(contentsOf: destination), expected)
    }

    @MainActor
    func testLazyShareProviderOffersExactPNGBytes() async throws {
        let expected = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a])
        let provider = makePNGItemProvider(filename: "fixture.png") { expected }
        XCTAssertEqual(provider.suggestedName, "fixture.png")
        XCTAssertTrue(provider.registeredTypeIdentifiers.contains(UTType.png.identifier))
        XCTAssertTrue(NSSharingServicePicker(items: [provider]).standardShareMenuItem.isEnabled)
        let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: EditorError.couldNotRender) }
            }
        }
        XCTAssertEqual(data, expected)
    }
}
