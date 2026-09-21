//
//  PDFExporter.swift
//  LocalNotes
//

import UIKit
import PencilKit

/// Renders a `PKDrawing` into a true **vector**, multi-page A4 PDF.
///
/// Every stroke is rebuilt as a `UIBezierPath` and stroked into the PDF context, so the
/// output stays resolution independent and no bitmap of the drawing is ever allocated
/// (the app must not blow up on 1000-stroke notes).
@MainActor
enum PDFExporter {
    /// A4 at 72 dpi (PDF user-space points).
    static let pageSize = CGSize(width: 595.28, height: 841.89)

    /// Page margin.
    static let margin: CGFloat = 36

    /// Builds the PDF in memory. Never throws; an empty drawing produces one page with a placeholder line.
    static func makePDFData(from drawing: PKDrawing, title: String) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: title,
            kCGPDFContextCreator as String: "LocalNotes"
        ]
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: pageSize),
            format: format
        )
        return renderer.pdfData { context in
            draw(drawing: drawing, title: title, in: context)
        }
    }

    /// Writes the PDF atomically to `url`.
    static func writePDF(from drawing: PKDrawing, title: String, to url: URL) throws {
        do {
            try makePDFData(from: drawing, title: title).write(to: url, options: [.atomic])
        } catch {
            throw PDFExportError.writeFailed(underlying: error)
        }
    }

    // MARK: - Drawing

    /// Paginates the vector content of `drawing` and renders each page into `context`.
    ///
    /// The drawing is uniformly scaled down to fit the printable width (never up), then sliced
    /// vertically into page-sized windows of `fittedPageHeight` content points.
    private static func draw(
        drawing: PKDrawing,
        title: String,
        in context: UIGraphicsPDFRendererContext
    ) {
        let contentBounds = drawing.bounds

        guard !contentBounds.isEmpty,
              contentBounds.width > 0,
              contentBounds.height > 0 else {
            context.beginPage()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12),
                .foregroundColor: UIColor.secondaryLabel
            ]
            NSAttributedString(string: "This note is empty.", attributes: attributes)
                .draw(at: CGPoint(x: margin, y: margin))
            drawFooter(title: title, pageIndex: 0, pageCount: 1, in: context)
            return
        }

        let scale = min(1, (pageSize.width - 2 * margin) / contentBounds.width)
        let fittedPageHeight = (pageSize.height - 2 * margin) / max(scale, 0.0001)
        let pageCount = max(1, Int(ceil(contentBounds.height / fittedPageHeight)))

        for pageIndex in 0..<pageCount {
            context.beginPage()
            let cg = context.cgContext
            cg.saveGState()
            cg.clip(to: CGRect(
                x: margin,
                y: margin,
                width: pageSize.width - 2 * margin,
                height: pageSize.height - 2 * margin
            ))
            cg.translateBy(x: margin, y: margin)
            cg.scaleBy(x: scale, y: scale)
            cg.translateBy(
                x: -contentBounds.minX,
                y: -(contentBounds.minY + CGFloat(pageIndex) * fittedPageHeight)
            )
            for stroke in drawing.strokes {
                let rendered = strokePath(stroke)
                rendered.color.setStroke()
                rendered.path.stroke()
            }
            cg.restoreGState()
            drawFooter(title: title, pageIndex: pageIndex, pageCount: pageCount, in: context)
        }
    }

    /// Rebuilds a single `PKStroke` as a strokable vector path together with its ink colour.
    ///
    /// Sample locations are connected with straight segments (Pencil sampling is dense enough
    /// that this is visually identical to the original stroke) and the stroke transform is
    /// applied so the path lands in drawing coordinates.
    private static func strokePath(_ stroke: PKStroke) -> (path: UIBezierPath, color: UIColor) {
        let path = UIBezierPath()
        let samples = stroke.path
        if samples.count > 0 {
            path.move(to: samples[0].location)
            for index in 1..<samples.count {
                path.addLine(to: samples[index].location)
            }
        }
        path.apply(stroke.transform)
        path.lineWidth = max(averageSampleWidth(of: stroke), 1)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return (path, stroke.ink.color)
    }

    /// Mean `PKStrokePoint.size.width` across the stroke's samples.
    ///
    /// Falls back to `2.5` when the stroke carries no samples or reports a zero average width
    /// so degenerate strokes still render as a visible hairline.
    private static func averageSampleWidth(of stroke: PKStroke) -> CGFloat {
        let samples = stroke.path
        guard samples.count > 0 else { return 2.5 }
        var total: CGFloat = 0
        for index in 0..<samples.count {
            total += samples[index].size.width
        }
        let average = total / CGFloat(samples.count)
        return average == 0 ? 2.5 : average
    }

    // MARK: - Footer

    /// Draws the hairline rule and the `"<title> · page <i>/<n>"` caption at the bottom of the page.
    private static func drawFooter(
        title: String,
        pageIndex: Int,
        pageCount: Int,
        in context: UIGraphicsPDFRendererContext
    ) {
        let contentWidth = pageSize.width - 2 * margin
        let ruleRect = CGRect(
            x: margin,
            y: pageSize.height - margin + 2,
            width: contentWidth,
            height: 0.5
        )
        context.cgContext.setFillColor(UIColor.secondaryLabel.withAlphaComponent(0.25).cgColor)
        context.cgContext.fill(ruleRect)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: UIColor.secondaryLabel
        ]
        let caption = "\(title) · page \(pageIndex + 1)/\(pageCount)"
        NSAttributedString(string: caption, attributes: attributes)
            .draw(at: CGPoint(x: margin, y: pageSize.height - margin + 8))
    }
}

/// Errors surfaced by the PDF export pipeline.
enum PDFExportError: LocalizedError {
    /// The underlying file-system error prevented the PDF from being written.
    case writeFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let underlying):
            return "The note could not be exported as a PDF: \(underlying.localizedDescription)"
        }
    }
}
