import Foundation
import CoreGraphics
import CoreText

/// Folha de contactos em PDF (A4): miniaturas em grelha com nome e dados de cada foto, para clientes e agências.
enum ContactSheet {
    struct Item: Sendable {
        let url: URL
        let title: String
        let subtitle: String
    }

    struct Layout: Equatable {
        let columns: Int
        let rowsPerPage: Int
        let pages: Int
    }

    static let pageSize = CGSize(width: 595, height: 842)
    private static let margin: CGFloat = 36
    private static let header: CGFloat = 46
    private static let footer: CGFloat = 20
    private static let caption: CGFloat = 24
    private static let spacing: CGFloat = 10

    static func layout(count: Int, columns: Int) -> Layout {
        let columns = min(max(columns, 1), 8)
        let cell = cellSize(columns: columns)
        let usable = pageSize.height - margin * 2 - header - footer
        let rows = max(Int((usable + spacing) / (cell.height + spacing)), 1)
        let perPage = rows * columns
        return Layout(columns: columns, rowsPerPage: rows, pages: max((count + perPage - 1) / perPage, 1))
    }

    private static func cellSize(columns: Int) -> CGSize {
        let width = (pageSize.width - margin * 2 - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        return CGSize(width: width, height: width * 0.75 + caption)
    }

    /// Devolve o número de páginas escritas.
    @discardableResult
    static func render(_ items: [Item], title: String, subtitle: String, columns: Int = 4, to url: URL) throws -> Int {
        var box = CGRect(origin: .zero, size: pageSize)
        let info = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Photographer's Pocket Knife"] as CFDictionary
        guard let context = CGContext(url as CFURL, mediaBox: &box, info) else { throw CocoaError(.fileWriteUnknown) }
        let layout = layout(count: items.count, columns: columns)
        let cell = cellSize(columns: layout.columns)
        let perPage = layout.rowsPerPage * layout.columns
        let imageHeight = cell.width * 0.75

        for page in 0..<layout.pages {
            context.beginPDFPage(nil)
            draw(title, size: 16, bold: true, at: CGPoint(x: margin, y: pageSize.height - margin - 16), width: pageSize.width - margin * 2, in: context)
            draw(subtitle, size: 9, gray: 0.45, at: CGPoint(x: margin, y: pageSize.height - margin - 32), width: pageSize.width - margin * 2, in: context)
            draw("\(page + 1) / \(layout.pages)", size: 8, gray: 0.5, at: CGPoint(x: pageSize.width - margin - 40, y: margin - 14), width: 60, in: context)

            let start = page * perPage
            guard start < items.count else { context.endPDFPage(); continue }
            for (offset, item) in items[start..<min(start + perPage, items.count)].enumerated() {
                let row = offset / layout.columns
                let column = offset % layout.columns
                let x = margin + CGFloat(column) * (cell.width + spacing)
                let top = pageSize.height - margin - header - CGFloat(row) * (cell.height + spacing)
                let frame = CGRect(x: x, y: top - imageHeight, width: cell.width, height: imageHeight)
                context.setFillColor(CGColor(gray: 0.94, alpha: 1))
                context.fill(frame)
                if let image = ThumbnailCache.shared.thumbnail(for: item.url, maxPixel: 800)?.cgImage {
                    let scale = min(frame.width / CGFloat(image.width), frame.height / CGFloat(image.height))
                    let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
                    context.interpolationQuality = .high
                    context.draw(image, in: CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height))
                }
                draw(item.title, size: 7.5, bold: true, at: CGPoint(x: x, y: frame.minY - 10), width: cell.width, in: context)
                draw(item.subtitle, size: 6.5, gray: 0.45, at: CGPoint(x: x, y: frame.minY - 19), width: cell.width, in: context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return layout.pages
    }

    private static func draw(_ text: String, size: CGFloat, bold: Bool = false, gray: CGFloat = 0.1, at point: CGPoint, width: CGFloat, in context: CGContext) {
        guard !text.isEmpty else { return }
        let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
        ]
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        if CTLineGetTypographicBounds(line, nil, nil, nil) > Double(width) {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            line = CTLineCreateTruncatedLine(line, Double(width), .end, ellipsis) ?? line
        }
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
