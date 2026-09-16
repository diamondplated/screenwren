import AppKit
import Carbon.HIToolbox
import XCTest

@testable import ScreenWren

@MainActor
private final class ReviewPointerWindow: NSWindow {
    override var mouseLocationOutsideOfEventStream: NSPoint { CGPoint(x: 100, y: 100) }
}

final class ReviewFixTests: XCTestCase {
    func testNewShortcutDefaultsYieldToSavedAssignmentsAndStayDisabledUntilReset() throws {
        let name = "ScreenWrenTests.ShortcutUpgrade.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let oldStore = ShortcutStore(defaults: defaults)
        let captureKey = try XCTUnwrap(ShortcutCommand.recents.defaultShortcut)
        let textKey = try XCTUnwrap(ShortcutCommand.togglePins.defaultShortcut)
        oldStore.set(captureKey, for: .capture)
        oldStore.set(textKey, for: .copyText)

        let upgraded = ShortcutStore(defaults: defaults)
        XCTAssertEqual(upgraded.shortcut(for: .capture), captureKey)
        XCTAssertEqual(upgraded.shortcut(for: .copyText), textKey)
        XCTAssertNil(upgraded.shortcut(for: .recents))
        XCTAssertNil(upgraded.shortcut(for: .togglePins))
        let values = Dictionary(uniqueKeysWithValues: ShortcutCommand.allCases.map { ($0, upgraded.shortcut(for: $0)) })
        XCTAssertTrue(conflictingShortcutCommands(values).isEmpty)

        upgraded.set(ShortcutCommand.capture.defaultShortcut, for: .capture)
        XCTAssertNil(ShortcutStore(defaults: defaults).shortcut(for: .recents))
        upgraded.restoreDefaults()
        for command in ShortcutCommand.allCases {
            XCTAssertEqual(upgraded.shortcut(for: command), command.defaultShortcut)
        }
    }

    @MainActor private func selector(
        origin: CGPoint = .zero, scale: CGFloat = 2, options: SelectionOptions = SelectionOptions()
    ) -> (SelectionView, ReviewPointerWindow) {
        _ = NSApplication.shared
        let view = SelectionView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300), pixelScale: scale,
            prompt: "Test", allowsWindows: true, options: options)
        let window = ReviewPointerWindow(
            contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.bounds.origin = origin
        view.selectionBounds = CGRect(x: 0, y: 0, width: origin.x + 400, height: origin.y + 300)
        window.contentView = view
        return (view, window)
    }

    @MainActor private func key(_ code: Int, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: UInt16(code)))
    }

    @MainActor private func mouse(
        _ kind: NSEvent.EventType, at point: CGPoint = CGPoint(x: 100, y: 100), in window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: kind, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @MainActor func testWindowSnapSpaceAndReturnUseDesktopCoordinates() throws {
        let (view, window) = selector(origin: CGPoint(x: 400, y: 300))
        defer { window.close() }
        view.updateWindowHits([
            .init(windowID: 42, frame: CGRect(x: 450, y: 350, width: 200, height: 200), applicationName: "Fixture")
        ])
        var selected: CGWindowID?
        view.onFinish = { if case .window(let id) = $0 { selected = id } }
        view.keyDown(with: try key(kVK_Space, in: window))
        view.keyDown(with: try key(kVK_Return, in: window))
        XCTAssertEqual(selected, 42, "No intervening mouse movement should be needed")
    }

    @MainActor func testWindowEnumerationUsesDesktopCoordinatesWhenItFinishesAfterSpace() throws {
        let (view, window) = selector(origin: CGPoint(x: 400, y: 300))
        defer { window.close() }
        view.keyDown(with: try key(kVK_Space, in: window))
        view.updateWindowHits([
            .init(windowID: 43, frame: CGRect(x: 450, y: 350, width: 200, height: 200), applicationName: "Fixture")
        ])
        var selected: CGWindowID?
        view.onFinish = { if case .window(let id) = $0 { selected = id } }
        view.keyDown(with: try key(kVK_Return, in: window))
        XCTAssertEqual(selected, 43)
    }

    @MainActor func testFixedSizeWindowModeClicksSnapButDragsStillSelectRegions() throws {
        for dragging in [false, true] {
            let (view, window) = selector(options: SelectionOptions(fixedSize: CGSize(width: 100, height: 100)))
            defer { window.close() }
            view.updateWindowHits([.init(windowID: 44, frame: view.bounds, applicationName: "Fixture")])
            view.mouseMoved(with: try mouse(.mouseMoved, in: window))
            view.keyDown(with: try key(kVK_Space, in: window))
            var selected: SelectionChoice?
            view.onFinish = { selected = $0 }
            view.mouseDown(with: try mouse(.leftMouseDown, in: window))
            if dragging {
                view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 150, y: 130), in: window))
            }
            view.mouseUp(with: try mouse(.leftMouseUp, in: window))
            switch selected {
            case .window(let id):
                XCTAssertFalse(dragging)
                XCTAssertEqual(id, 44)
            case .region(let rect):
                XCTAssertTrue(dragging)
                XCTAssertEqual(rect.size, CGSize(width: 50, height: 50))
            case nil: XCTFail("Expected a completed selection")
            }
        }
    }

    @MainActor func testOddPixelPresetsProduceExactFrozenImageDimensionsIncludingEdges() throws {
        for scale: CGFloat in [1, 2] {
            let image = try renderCGImage(width: Int(400 * scale), height: Int(300 * scale)) { _ in }
            for point in [CGPoint(x: 100, y: 100), CGPoint(x: 100.25, y: 99.75), .zero, CGPoint(x: 400, y: 300)] {
                let (view, window) = selector(
                    scale: scale, options: SelectionOptions(fixedSize: CGSize(width: 101, height: 99)))
                defer { window.close() }
                var rect: CGRect?
                view.onFinish = { if case .region(let selection) = $0 { rect = selection } }
                view.mouseDown(with: try mouse(.leftMouseDown, at: point, in: window))
                view.mouseUp(with: try mouse(.leftMouseUp, at: point, in: window))
                let output = try cropFrozenImage(image, selection: XCTUnwrap(rect), viewSize: view.frame.size)
                XCTAssertEqual(output.width, 101)
                XCTAssertEqual(output.height, 99)
            }
        }
    }

    @MainActor func testMovingAPresetWithSpaceKeepsFrozenPixelsAligned() throws {
        let (view, window) = selector(options: SelectionOptions(fixedSize: CGSize(width: 101, height: 99)))
        defer { window.close() }
        var rect: CGRect?
        view.onFinish = { if case .region(let selection) = $0 { rect = selection } }
        view.mouseDown(with: try mouse(.leftMouseDown, in: window))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 125.25, y: 110.75), in: window))
        view.keyDown(with: try key(kVK_Space, in: window))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 160.75, y: 140.25), in: window))
        view.mouseUp(with: try mouse(.leftMouseUp, in: window))
        let image = try renderCGImage(width: 800, height: 600) { _ in }
        let output = try cropFrozenImage(image, selection: XCTUnwrap(rect), viewSize: view.frame.size)
        XCTAssertEqual(output.width, 101)
        XCTAssertEqual(output.height, 99)
    }

    @MainActor private func verifyCaptureBeyondRecentBudget(clipboardChanged: Bool) throws {
        _ = NSApplication.shared
        let name = "ScreenWrenTests.RecentBudget.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let coordinator = CaptureCoordinator(
            preferences: WorkflowPreferences(defaults: defaults), pasteboard: pasteboard, recentMemoryLimit: 1)
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer {
            for window in NSApp.windows
            where !before.contains(ObjectIdentifier(window)) && window.contentViewController is EditorViewController {
                window.performClose(nil)
            }
        }
        let count = pasteboard.changeCount
        let generation = ClipboardDeliveryOrder.shared.begin()
        if clipboardChanged {
            pasteboard.clearContents()
            pasteboard.setString("newer content", forType: .string)
        }
        let image = try renderCGImage(width: 20, height: 20) { _ in }
        coordinator.finishImageCapture(
            image, scale: 2, destination: .clipboard,
            clipboardGeneration: generation, clipboardChangeCount: count)
        XCTAssertTrue(coordinator.recentCaptures.isEmpty)
        if clipboardChanged {
            XCTAssertEqual(pasteboard.string(forType: .string), "newer content")
            XCTAssertEqual(
                coordinator.menuState.editorCount, 1, "Keep the image recoverable without overwriting the clipboard")
        } else {
            XCTAssertNotNil(pasteboard.data(forType: .tiff))
            XCTAssertEqual(coordinator.menuState.editorCount, 0, "A successful copy should remain quiet")
        }
    }

    @MainActor func testCaptureBeyondRecentBudgetFallsBackToEditorWhenClipboardChanges() throws {
        try verifyCaptureBeyondRecentBudget(clipboardChanged: true)
    }

    @MainActor func testCaptureBeyondRecentBudgetStaysQuietWhenCopied() throws {
        try verifyCaptureBeyondRecentBudget(clipboardChanged: false)
    }
}
