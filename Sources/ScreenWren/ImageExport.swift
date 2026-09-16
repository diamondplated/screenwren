import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImageExportFormat: String, CaseIterable, Codable {
    case png, jpeg
    var title: String { self == .png ? "PNG (lossless)" : "JPEG" }
    var contentType: UTType { self == .png ? .png : .jpeg }
    var fileExtension: String { self == .png ? "png" : "jpg" }
}
enum ImageExportResolution: String, CaseIterable, Codable {
    case original, logical
    var title: String { self == .original ? "Original pixels" : "1× (screen points)" }
}
struct ImageExportOptions: Equatable, Sendable {
    var format: ImageExportFormat = .png
    var resolution: ImageExportResolution = .original
    var quality: Double = 0.85
    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(
            format: ImageExportFormat(rawValue: defaults.string(forKey: "export.format") ?? "") ?? .png,
            resolution: ImageExportResolution(rawValue: defaults.string(forKey: "export.resolution") ?? "")
                ?? .original,
            quality: defaults.object(forKey: "export.quality") == nil
                ? 0.85 : min(1, max(0.1, defaults.double(forKey: "export.quality"))))
    }
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(format.rawValue, forKey: "export.format")
        defaults.set(resolution.rawValue, forKey: "export.resolution")
        defaults.set(quality, forKey: "export.quality")
    }
}
func exportPixelSize(width: Int, height: Int, sourceScale: CGFloat, options: ImageExportOptions) -> CGSize {
    let scale = options.resolution == .logical && sourceScale.isFinite ? max(1, sourceScale) : 1
    return CGSize(
        width: max(1, (CGFloat(width) / scale).rounded()), height: max(1, (CGFloat(height) / scale).rounded()))
}
func encodedImage(_ image: CGImage, sourceScale: CGFloat = 1, options: ImageExportOptions) throws -> Data {
    let size = exportPixelSize(width: image.width, height: image.height, sourceScale: sourceScale, options: options)
    guard size.width * size.height <= 64_000_000 else { throw ImageOperationsError.outputTooLarge }
    let prepared: CGImage
    if size.width != CGFloat(image.width) || size.height != CGFloat(image.height) || options.format == .jpeg {
        prepared = try renderCGImage(width: Int(size.width), height: Int(size.height)) { context in
            if options.format == .jpeg {
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(origin: .zero, size: size))
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(origin: .zero, size: size))
        }
    } else {
        prepared = image
    }
    let data = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            data, options.format.contentType.identifier as CFString, 1, nil)
    else { throw ImageOperationsError.couldNotRender }
    let properties: [CFString: Any] =
        options.format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: min(1, max(0.1, options.quality))] : [:]
    CGImageDestinationAddImage(destination, prepared, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw ImageOperationsError.couldNotRender }
    return data as Data
}

@MainActor
final class ImageExportWindow: NSWindowController, NSWindowDelegate {
    private let image: CGImage
    private let sourceScale: CGFloat
    private let format = NSPopUpButton()
    private let resolution = NSPopUpButton()
    private let quality = NSSlider(value: 85, minValue: 10, maxValue: 100, target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "Preparing export…")
    private let saveButton = NSButton(title: "Save…", target: nil, action: nil)
    private var encoded: Data?
    private var task: Task<Void, Never>?
    private var revision = 0
    var onClose: (() -> Void)?

    init(image: CGImage, sourceScale: CGFloat = 1) {
        self.image = image
        self.sourceScale = sourceScale
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 540, height: 440), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Export Capture"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let preview = NSImageView(
            image: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)))
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.heightAnchor.constraint(equalToConstant: 225).isActive = true
        preview.setAccessibilityLabel("Export preview")
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let options = ImageExportOptions.load()
        format.addItems(withTitles: ImageExportFormat.allCases.map(\.title))
        format.selectItem(at: options.format == .png ? 0 : 1)
        resolution.addItems(withTitles: ImageExportResolution.allCases.map(\.title))
        resolution.selectItem(at: options.resolution == .original ? 0 : 1)
        format.target = self
        format.action = #selector(updatePreview)
        resolution.target = self
        resolution.action = #selector(updatePreview)
        format.setAccessibilityLabel("Image format")
        resolution.setAccessibilityLabel("Export resolution")
        quality.doubleValue = options.quality * 100
        quality.target = self
        quality.action = #selector(updatePreview)
        quality.isContinuous = false
        quality.setAccessibilityLabel("JPEG quality")
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        let controls = NSStackView(views: [format, resolution])
        controls.spacing = 14
        let qualityRow = NSStackView(views: [NSTextField(labelWithString: "JPEG quality"), quality])
        qualityRow.spacing = 12
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        let content = NSStackView(views: [preview, controls, qualityRow, status, saveButton])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            preview.widthAnchor.constraint(equalTo: content.widthAnchor),
            quality.widthAnchor.constraint(equalToConstant: 280),
        ])
        window.center()
        updatePreview()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var options: ImageExportOptions {
        ImageExportOptions(
            format: ImageExportFormat.allCases[format.indexOfSelectedItem],
            resolution: ImageExportResolution.allCases[resolution.indexOfSelectedItem],
            quality: quality.doubleValue / 100)
    }
    @objc private func updatePreview() {
        task?.cancel()
        revision += 1
        let expected = revision
        encoded = nil
        saveButton.isEnabled = false
        quality.isEnabled = options.format == .jpeg
        status.stringValue = "Calculating encoded file size…"
        let options = options
        let sourceScale = sourceScale
        let payload = SendableImage(image: image)
        task = Task { @MainActor [weak self] in
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try encodedImage(payload.image, sourceScale: sourceScale, options: options)
                }.value
                try Task.checkCancellation()
                guard let self, self.revision == expected else { return }
                self.encoded = data
                self.saveButton.isEnabled = true
                let size = exportPixelSize(
                    width: payload.image.width, height: payload.image.height, sourceScale: sourceScale, options: options
                )
                self.status.stringValue =
                    "\(Int(size.width)) × \(Int(size.height)) · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))"
                    + (options.format == .jpeg ? " · JPEG uses a white background" : "")
            } catch is CancellationError {} catch {
                self?.status.stringValue = "Couldn’t prepare export: \(error.localizedDescription)"
            }
        }
    }
    @objc private func save() {
        guard let window, let data = encoded else { return }
        let options = options
        let panel = NSSavePanel()
        panel.allowedContentTypes = [options.format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue =
            (timestampedPNGFilename() as NSString).deletingPathExtension + "." + options.format.fileExtension
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.saveButton.isEnabled = false
            self.task = Task { @MainActor [weak self] in
                do {
                    try await Task.detached(priority: .userInitiated) { try data.write(to: url, options: .atomic) }
                        .value
                    options.save()
                    self?.status.stringValue = "Saved"
                    self?.saveButton.isEnabled = true
                } catch {
                    self?.status.stringValue = "Couldn’t save: \(error.localizedDescription)"
                    self?.saveButton.isEnabled = true
                }
            }
        }
    }
    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        task = nil
        encoded = nil
        onClose?()
    }
}

enum CompositionLayout: String, CaseIterable, Sendable {
    case vertical, horizontal, grid
    var title: String {
        switch self {
        case .vertical: "Vertical"
        case .horizontal: "Side by Side"
        case .grid: "Grid"
        }
    }
}
struct CompositionPlan {
    let size: CGSize
    let frames: [CGRect]  // Top-left coordinates, preserving original image pixels.
}
func compositionPlan(sizes: [CGSize], layout: CompositionLayout, gap: CGFloat = 16) throws -> CompositionPlan {
    guard (2...5).contains(sizes.count), gap >= 0, gap <= 100,
        sizes.allSatisfy({
            $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 && $0.width <= 30_000
                && $0.height <= 30_000
        })
    else { throw ImageOperationsError.invalidDimensions }
    var frames: [CGRect] = []
    switch layout {
    case .vertical:
        var y: CGFloat = 0
        for size in sizes {
            frames.append(CGRect(x: 0, y: y, width: size.width, height: size.height))
            y += size.height + gap
        }
    case .horizontal:
        var x: CGFloat = 0
        for size in sizes {
            frames.append(CGRect(x: x, y: 0, width: size.width, height: size.height))
            x += size.width + gap
        }
    case .grid:
        let cellWidth = sizes.map(\.width).max()!
        let cellHeight = sizes.map(\.height).max()!
        for (index, size) in sizes.enumerated() {
            frames.append(
                CGRect(
                    x: CGFloat(index % 2) * (cellWidth + gap), y: CGFloat(index / 2) * (cellHeight + gap),
                    width: size.width, height: size.height))
        }
    }
    let size = CGSize(width: frames.map(\.maxX).max()!, height: frames.map(\.maxY).max()!)
    guard size.width <= 30_000, size.height <= 30_000, size.width * size.height <= 64_000_000 else {
        throw ImageOperationsError.outputTooLarge
    }
    return CompositionPlan(size: size, frames: frames)
}
func combinedImages(_ images: [CGImage], layout: CompositionLayout) throws -> CGImage {
    let plan = try compositionPlan(sizes: images.map { CGSize(width: $0.width, height: $0.height) }, layout: layout)
    return try renderCGImage(width: Int(plan.size.width), height: Int(plan.size.height)) { context in
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: plan.size))
        for (index, image) in images.enumerated() {
            let frame = plan.frames[index]
            context.draw(
                image,
                in: CGRect(x: frame.minX, y: plan.size.height - frame.maxY, width: frame.width, height: frame.height))
        }
    }
}
