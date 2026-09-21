import UIKit

/// Builds and caches the light squared-paper ("quadretti") pattern used as the
/// canvas background. One small tile image is rendered once and reused through
/// `UIColor(patternImage:)`, so memory cost is constant (a few KB) no matter how
/// far the infinite canvas grows.
///
/// - Note: Apply the pattern to a content-anchored view placed *inside* the
///   scroll view (for example the background of the view hosting the ink). A
///   viewport-anchored `backgroundColor` would keep the grid pinned to the
///   screen, so the paper would not scroll with the ink and the illusion of an
///   infinite sheet would break.
@MainActor
enum CanvasGridPattern {
    /// Default distance, in points, between two adjacent grid lines.
    static let defaultSpacing: CGFloat = 24

    /// Cached pattern colours keyed by spacing and trait state.
    private static var colorCache: [String: UIColor] = [:]
    /// Cached tile images keyed by spacing and trait state.
    private static var imageCache: [String: UIImage] = [:]

    /// Cached pattern colour for the given spacing + trait environment.
    ///
    /// The colour wraps the tile from `makeTileImage(spacing:traitCollection:)`;
    /// it is a plain pattern colour, not a dynamic one, so the caller resolves
    /// (and re-resolves on trait changes) with the current trait collection.
    static func makeGridColor(spacing: CGFloat, traitCollection: UITraitCollection) -> UIColor {
        let roundedSpacing = max(round(spacing * 2.0) / 2.0, 4.0)
        let key = cacheKey(spacing: roundedSpacing, traitCollection: traitCollection)
        if let color = cachedValue(forKey: key, in: colorCache) {
            return color
        }
        let image = makeTileImage(spacing: roundedSpacing, traitCollection: traitCollection)
        let color = UIColor(patternImage: image)
        store(color, forKey: key, in: &colorCache)
        return color
    }

    /// The single cached tile image behind `makeGridColor`.
    ///
    /// The tile is `spacing` x `spacing` points and strokes only its right and
    /// bottom edges, so tiling it reproduces a full square mesh with single
    /// (never doubled) 1-device-pixel lines. Rendering happens once per cache
    /// key; later calls return the cached image.
    static func makeTileImage(spacing: CGFloat, traitCollection: UITraitCollection) -> UIImage {
        let key = cacheKey(spacing: spacing, traitCollection: traitCollection)
        if let image = cachedValue(forKey: key, in: imageCache) {
            return image
        }

        let scale = effectiveDisplayScale(for: traitCollection)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true

        let tileSize = CGSize(width: spacing, height: spacing)
        let renderer = UIGraphicsImageRenderer(size: tileSize, format: format)
        let image = renderer.image { rendererContext in
            let context = rendererContext.cgContext
            let bounds = CGRect(origin: .zero, size: tileSize)

            let background = UIColor.systemBackground.resolvedColor(with: traitCollection)
            context.setFillColor(background.cgColor)
            context.fill(bounds)

            let lineWidth = 1.0 / scale
            let lineColor = UIColor.label.withAlphaComponent(0.12).resolvedColor(with: traitCollection)
            context.setStrokeColor(lineColor.cgColor)
            context.setLineWidth(lineWidth)

            // Centre the 1-device-pixel line on the last device-pixel column
            // and row so it stays crisp and tiles seamlessly into the next cell.
            let offset = lineWidth / 2
            context.beginPath()
            context.move(to: CGPoint(x: spacing - offset, y: 0))
            context.addLine(to: CGPoint(x: spacing - offset, y: spacing))
            context.move(to: CGPoint(x: 0, y: spacing - offset))
            context.addLine(to: CGPoint(x: spacing, y: spacing - offset))
            context.strokePath()
        }

        store(image, forKey: key, in: &imageCache)
        return image
    }

    /// Cache key combining spacing, effective display scale and the trait
    /// dimensions that change the rendered colours.
    private static func cacheKey(spacing: CGFloat, traitCollection: UITraitCollection) -> String {
        let scale = effectiveDisplayScale(for: traitCollection)
        return "\(spacing)-\(scale)-\(traitCollection.userInterfaceStyle.rawValue)-\(traitCollection.accessibilityContrast.rawValue)-\(traitCollection.activeAppearance.rawValue)"
    }

    /// Returns `traitCollection.displayScale`, falling back to `1` when the
    /// trait collection carries no usable scale (invalid for a renderer).
    private static func effectiveDisplayScale(for traitCollection: UITraitCollection) -> CGFloat {
        traitCollection.displayScale > 0 ? traitCollection.displayScale : 1
    }

    /// Returns a previously cached value for `key`, if any.
    private static func cachedValue<T>(forKey key: String, in cache: [String: T]) -> T? {
        cache[key]
    }

    /// Stores `value` under `key` in `cache`, bounding capacity to prevent memory bloat during zooming.
    private static func store<T>(_ value: T, forKey key: String, in cache: inout [String: T]) {
        if cache.count > 64 {
            cache.removeAll(keepingCapacity: true)
        }
        cache[key] = value
    }
}
