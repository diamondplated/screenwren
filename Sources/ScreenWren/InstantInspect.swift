import AppKit
import Carbon.HIToolbox
import CoreGraphics
import ImageIO
import Vision
@preconcurrency import VisionKit

enum InstantInspectPresentation: Equatable {
    case inactive
    case inspect
    case subjectPicker
}

enum InstantInspectSubjectDecision: Equatable {
    case none
    case copySingle
    case pickOne
}

func instantInspectSubjectDecision(count: Int) -> InstantInspectSubjectDecision {
    switch count {
    case 0: .none
    case 1: .copySingle
    default: .pickOne
    }
}

func instantInspectText(selectedText: String?, fullText: String?) -> String? {
    if let selectedText,
       !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return selectedText
    }
    guard let fullText,
          !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return fullText
}

func isCurrentInstantInspectRevision(_ requested: UInt64, current: UInt64) -> Bool {
    requested == current
}

func instantInspectBarcodeRect(
    visionRect: CGRect,
    contentRect: CGRect,
    overlayBounds: CGRect
) -> CGRect {
    let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    let source = visionRect.standardized.intersection(unit)
    guard !source.isNull, !source.isEmpty else { return .zero }
    return CGRect(
        x: overlayBounds.minX + (contentRect.minX + source.minX * contentRect.width) * overlayBounds.width,
        y: overlayBounds.minY + (contentRect.minY + (1 - source.maxY) * contentRect.height) * overlayBounds.height,
        width: source.width * contentRect.width * overlayBounds.width,
        height: source.height * contentRect.height * overlayBounds.height
    )
}

func instantInspectSafeURL(_ string: String?) -> URL? {
    guard let string,
          let url = URL(string: string),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          url.host?.isEmpty == false else { return nil }
    return url
}

struct InstantInspectTextResult {
    let revision: UInt64
    let text: String
}

struct InstantInspectBarcodeHit: Sendable {
    let revision: UInt64
    let normalizedBounds: CGRect
    let payloadString: String?
    let payloadData: Data?
    let confidence: Float

    var summary: String {
        if let payloadString {
            let flattened = payloadString.components(separatedBy: .controlCharacters).joined(separator: " ")
            return flattened.count > 64 ? "\(flattened.prefix(61))…" : flattened
        }
        return "Binary code (\(payloadData?.count ?? 0) bytes)"
    }
}

@MainActor
final class InstantInspectSubject {
    let revision: UInt64
    fileprivate let subject: ImageAnalysisOverlayView.Subject

    fileprivate init(revision: UInt64, subject: ImageAnalysisOverlayView.Subject) {
        self.revision = revision
        self.subject = subject
    }

    func image() async throws -> NSImage {
        try await subject.image
    }
}

enum InstantInspectSubjectChoice {
    case unavailable
    case none
    case single(InstantInspectSubject)
    case multiple
}

private func detectInstantInspectBarcodes(
    in image: CGImage,
    revision: UInt64
) async throws -> [InstantInspectBarcodeHit] {
    var request = DetectBarcodesRequest()
    request.symbologies = request.supportedSymbologies
    return try await request.perform(on: image).compactMap { observation in
        let payloadString = observation.payloadString.flatMap { $0.isEmpty ? nil : $0 }
        guard payloadString != nil || observation.payloadData != nil else { return nil }
        return InstantInspectBarcodeHit(
            revision: revision,
            normalizedBounds: observation.boundingRegion.boundingBox.cgRect,
            payloadString: payloadString,
            payloadData: observation.payloadData,
            confidence: observation.confidence
        )
    }
}

@MainActor
final class InstantInspectController: NSObject, ImageAnalysisOverlayViewDelegate {
    let analysisOverlayView = ImageAnalysisOverlayView(frame: .zero)
    let hitOverlayView = InstantInspectHitView(frame: .zero)

    var onEscape: (() -> Void)?
    var onBarcodeHit: ((InstantInspectBarcodeHit, CGPoint) -> Void)?
    var onSubjectPoint: ((CGPoint) -> Void)?

    private let analyzer = ImageAnalyzer()
    private var image: CGImage?
    private var analysis: ImageAnalysis?
    private var subjects: Set<ImageAnalysisOverlayView.Subject>?
    private(set) var barcodes: [InstantInspectBarcodeHit] = []
    private(set) var revision: UInt64 = 0
    private var analysisTask: Task<Void, Never>?
    private var subjectTask: Task<Void, Never>?
    private var barcodeTask: Task<Void, Never>?

    override init() {
        super.init()
        analysisOverlayView.delegate = self
        analysisOverlayView.preferredInteractionTypes = [.textSelection, .dataDetectors, .imageSubject]
        analysisOverlayView.isHidden = true
        hitOverlayView.analysisOverlayView = analysisOverlayView
        hitOverlayView.isHidden = true
        hitOverlayView.onEscape = { [weak self] in self?.onEscape?() }
        hitOverlayView.onBarcode = { [weak self] hit, point in self?.onBarcodeHit?(hit, point) }
        hitOverlayView.onSubjectPoint = { [weak self] point in self?.onSubjectPoint?(point) }
    }

    func track(_ imageView: NSImageView) {
        analysisOverlayView.trackingImageView = imageView
    }

    func install(image: CGImage) {
        revision &+= 1
        cancelTasks()
        self.image = image
        analysis = nil
        subjects = nil
        barcodes = []
        analysisOverlayView.analysis = nil
        analysisOverlayView.resetSelection()
        analysisOverlayView.highlightedSubjects = []
        hitOverlayView.barcodes = []

        let requestedRevision = revision
        if ImageAnalyzer.isSupported {
            analysisTask = Task(priority: .utility) { @MainActor [weak self, image] in
                guard let self else { return }
                do {
                    let configuration = ImageAnalyzer.Configuration(.text)
                    let value = try await analyzer.analyze(image, orientation: .up, configuration: configuration)
                    try Task.checkCancellation()
                    guard isCurrentInstantInspectRevision(requestedRevision, current: revision) else { return }
                    analysis = value
                    analysisOverlayView.analysis = value
                    startSubjectPrewarm(revision: requestedRevision)
                } catch is CancellationError {
                } catch {
                    // The existing Vision OCR and foreground-mask paths remain the on-demand fallback.
                }
            }
        }

        barcodeTask = Task(priority: .utility) { @MainActor [weak self, image] in
            guard let self else { return }
            do {
                let value = try await detectInstantInspectBarcodes(in: image, revision: requestedRevision)
                try Task.checkCancellation()
                guard isCurrentInstantInspectRevision(requestedRevision, current: revision) else { return }
                barcodes = value
                hitOverlayView.barcodes = value
            } catch is CancellationError {
            } catch {
                // Codes are an enhancement; OCR and editing stay available when detection fails.
            }
        }
    }

    func textForCopy(selectedText: String?) async throws -> InstantInspectTextResult? {
        let requestedRevision = revision
        if let selected = instantInspectText(selectedText: selectedText, fullText: nil) {
            return InstantInspectTextResult(revision: requestedRevision, text: selected)
        }

        await analysisTask?.value
        guard isCurrentInstantInspectRevision(requestedRevision, current: revision),
              let image else { return nil }
        if let text = instantInspectText(selectedText: nil, fullText: analysis?.transcript) {
            return InstantInspectTextResult(revision: requestedRevision, text: text)
        }

        let fallback = try await recognizedText(in: image)
        try Task.checkCancellation()
        guard isCurrentInstantInspectRevision(requestedRevision, current: revision),
              let text = instantInspectText(selectedText: nil, fullText: fallback) else { return nil }
        return InstantInspectTextResult(revision: requestedRevision, text: text)
    }

    var selectedText: String? {
        guard analysisOverlayView.hasActiveTextSelection else { return nil }
        return instantInspectText(selectedText: analysisOverlayView.selectedText, fullText: nil)
    }

    func subjectChoice() async -> InstantInspectSubjectChoice {
        let requestedRevision = revision
        await analysisTask?.value
        guard isCurrentInstantInspectRevision(requestedRevision, current: revision), analysis != nil else {
            return .unavailable
        }
        startSubjectPrewarm(revision: requestedRevision)
        await subjectTask?.value
        guard isCurrentInstantInspectRevision(requestedRevision, current: revision),
              let subjects else { return .unavailable }
        switch instantInspectSubjectDecision(count: subjects.count) {
        case .none:
            return .none
        case .copySingle:
            guard let subject = subjects.first else { return .none }
            return .single(InstantInspectSubject(revision: requestedRevision, subject: subject))
        case .pickOne:
            return .multiple
        }
    }

    func subject(at point: CGPoint) async -> InstantInspectSubject? {
        let requestedRevision = revision
        guard let subject = await analysisOverlayView.subject(at: point),
              isCurrentInstantInspectRevision(requestedRevision, current: revision) else { return nil }
        return InstantInspectSubject(revision: requestedRevision, subject: subject)
    }

    func setPresentation(_ presentation: InstantInspectPresentation, interactive: Bool) {
        let visible = interactive && presentation != .inactive
        analysisOverlayView.isHidden = !visible
        hitOverlayView.isHidden = !visible
        guard visible else { return }

        switch presentation {
        case .inactive:
            break
        case .inspect:
            analysisOverlayView.preferredInteractionTypes = [.textSelection, .dataDetectors, .imageSubject]
            analysisOverlayView.highlightedSubjects = []
            hitOverlayView.picksSubject = false
        case .subjectPicker:
            analysisOverlayView.preferredInteractionTypes = .imageSubject
            analysisOverlayView.highlightedSubjects = subjects ?? []
            hitOverlayView.picksSubject = true
        }
        updateGeometry()
    }

    func resetInteraction() {
        analysisOverlayView.resetSelection()
        analysisOverlayView.highlightedSubjects = []
        hitOverlayView.picksSubject = false
    }

    func updateGeometry() {
        analysisOverlayView.setContentsRectNeedsUpdate()
        hitOverlayView.needsDisplay = true
    }

    func firstResponder(for presentation: InstantInspectPresentation) -> NSView {
        presentation == .subjectPicker ? hitOverlayView : analysisOverlayView
    }

    func isCurrent(revision requestedRevision: UInt64) -> Bool {
        isCurrentInstantInspectRevision(requestedRevision, current: revision)
    }

    func cancel() {
        cancelTasks()
        analysisOverlayView.analysis = nil
        analysisOverlayView.highlightedSubjects = []
        hitOverlayView.barcodes = []
    }

    func overlayView(
        _ overlayView: ImageAnalysisOverlayView,
        shouldHandleKeyDownEvent event: NSEvent
    ) -> Bool {
        if event.keyCode == UInt16(kVK_Escape) {
            onEscape?()
            return true
        }
        return true
    }

    private func startSubjectPrewarm(revision requestedRevision: UInt64) {
        guard subjectTask == nil,
              isCurrentInstantInspectRevision(requestedRevision, current: revision) else { return }
        analysisOverlayView.beginSubjectAnalysisIfNecessary()
        subjectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let value = await analysisOverlayView.subjects
            guard !Task.isCancelled,
                  isCurrentInstantInspectRevision(requestedRevision, current: revision) else { return }
            subjects = value
        }
    }

    private func cancelTasks() {
        analysisTask?.cancel()
        subjectTask?.cancel()
        barcodeTask?.cancel()
        analysisTask = nil
        subjectTask = nil
        barcodeTask = nil
    }
}

@MainActor
final class InstantInspectHitView: NSView {
    weak var analysisOverlayView: ImageAnalysisOverlayView?
    var onEscape: (() -> Void)?
    var onBarcode: ((InstantInspectBarcodeHit, CGPoint) -> Void)?
    var onSubjectPoint: ((CGPoint) -> Void)?
    var picksSubject = false
    var barcodes: [InstantInspectBarcodeHit] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Detected codes and subject picker")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !picksSubject, let analysisOverlayView else { return }
        NSColor.systemYellow.withAlphaComponent(0.16).setFill()
        NSColor.systemYellow.setStroke()
        for hit in barcodes {
            let rect = instantInspectBarcodeRect(
                visionRect: hit.normalizedBounds,
                contentRect: analysisOverlayView.contentsRect,
                overlayBounds: bounds
            )
            guard !rect.isEmpty else { continue }
            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            path.lineWidth = 2
            path.fill()
            path.stroke()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }
        return picksSubject || barcode(at: localPoint) != nil ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if picksSubject {
            onSubjectPoint?(point)
        } else if let hit = barcode(at: point) {
            onBarcode?(hit, point)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }

    private func barcode(at point: CGPoint) -> InstantInspectBarcodeHit? {
        guard let analysisOverlayView else { return nil }
        return barcodes
            .filter {
                instantInspectBarcodeRect(
                    visionRect: $0.normalizedBounds,
                    contentRect: analysisOverlayView.contentsRect,
                    overlayBounds: bounds
                ).contains(point)
            }
            .sorted {
                let lhs = $0.normalizedBounds.width * $0.normalizedBounds.height
                let rhs = $1.normalizedBounds.width * $1.normalizedBounds.height
                return lhs == rhs ? $0.confidence > $1.confidence : lhs < rhs
            }
            .first
    }
}
