import CoreGraphics
import Foundation
import PencilKit

/// Geometry helper that replaces a freehand `PKStroke` with a perfectly straight
/// line between its first and last sample, preserving ink, transform and mask.
///
/// The snapped stroke keeps the original endpoints exactly and interpolates
/// every per-point attribute (time offset, size, opacity, force, azimuth,
/// altitude) linearly between them, so the result reads as the same pen dragged
/// along a ruler rather than a different stroke.
enum StraightLineSnapper {
    /// Endpoints closer than this (pt) are not worth snapping (dots/taps).
    static let minimumSnapLength: CGFloat = 12
    /// Number of samples in the replacement stroke.
    static let interpolationSteps: Int = 48

    /// Returns a straightened copy of `stroke`, or `nil` when it has fewer than
    /// 2 samples or its endpoints are closer than `minimumSnapLength`.
    ///
    /// The new path holds `interpolationSteps + 1` points spread evenly along
    /// the segment from the first to the last original sample; the original
    /// path's creation date is reused when available.
    static func straightened(_ stroke: PKStroke) -> PKStroke? {
        let originalPath = stroke.path
        let sampleCount = originalPath.count
        guard sampleCount >= 2 else { return nil }

        let first = originalPath[0]
        let last = originalPath[sampleCount - 1]
        let start = first.location
        let end = last.location

        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        guard (deltaX * deltaX + deltaY * deltaY).squareRoot() >= minimumSnapLength else {
            return nil
        }

        var points: [PKStrokePoint] = []
        points.reserveCapacity(interpolationSteps + 1)
        for step in 0...interpolationSteps {
            let progress = CGFloat(step) / CGFloat(interpolationSteps)
            points.append(interpolatedPoint(from: first, to: last, progress: progress))
        }

        let originalCreationDate: Date? = originalPath.creationDate
        let straightPath = PKStrokePath(
            controlPoints: points,
            creationDate: originalCreationDate ?? Date()
        )
        return PKStroke(ink: stroke.ink, path: straightPath, transform: stroke.transform, mask: stroke.mask)
    }

    /// Replaces the last stroke of `drawing` with its straightened version.
    /// Returns the new drawing, the replaced index and the replacement stroke.
    ///
    /// Returns `nil` when the drawing is empty or when the last stroke cannot be
    /// snapped (fewer than 2 samples, or shorter than `minimumSnapLength`).
    static func straightenedLastStroke(in drawing: PKDrawing) -> (drawing: PKDrawing, strokeIndex: Int, stroke: PKStroke)? {
        var strokes = drawing.strokes
        guard let last = strokes.last, let replacement = straightened(last) else {
            return nil
        }
        let index = strokes.count - 1
        strokes[index] = replacement
        return (drawing: PKDrawing(strokes: strokes), strokeIndex: index, stroke: replacement)
    }

    /// Linearly interpolates every attribute of a `PKStrokePoint` between two
    /// endpoint samples. `progress` runs from 0 (start) to 1 (end).
    private static func interpolatedPoint(from start: PKStrokePoint, to end: PKStrokePoint, progress: CGFloat) -> PKStrokePoint {
        let location = CGPoint(
            x: start.location.x + (end.location.x - start.location.x) * progress,
            y: start.location.y + (end.location.y - start.location.y) * progress
        )
        let size = CGSize(
            width: start.size.width + (end.size.width - start.size.width) * progress,
            height: start.size.height + (end.size.height - start.size.height) * progress
        )
        let timeOffset = start.timeOffset + (end.timeOffset - start.timeOffset) * TimeInterval(progress)
        let opacity = start.opacity + (end.opacity - start.opacity) * progress
        let force = start.force + (end.force - start.force) * progress
        let azimuth = start.azimuth + (end.azimuth - start.azimuth) * progress
        let altitude = start.altitude + (end.altitude - start.altitude) * progress
        return PKStrokePoint(
            location: location,
            timeOffset: timeOffset,
            size: size,
            opacity: opacity,
            force: force,
            azimuth: azimuth,
            altitude: altitude
        )
    }
}
