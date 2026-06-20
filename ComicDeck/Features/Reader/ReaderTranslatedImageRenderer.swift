import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

nonisolated enum ReaderTranslatedImageRenderer {
    private struct TranslationBlock {
        let rect: CGRect
        let text: String
        let sourceTexts: [String]
    }

    static func render(_ image: PlatformImage, overlays: [ReaderTextBlock]) -> PlatformImage {
        guard !overlays.isEmpty else { return image }
        let imageSize = image.platformSize
        let blocks = mergeOverlaysIntoBlocks(overlays, imageSize: imageSize)
        #if os(iOS)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: imageSize, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: imageSize))
            for block in blocks {
                let layout = layoutRect(for: block.text, in: block.rect, imageSize: imageSize)
                UIColor.white.withAlphaComponent(0.94).setFill()
                UIBezierPath(roundedRect: layout.rect, cornerRadius: 8).fill()
                NSString(string: block.text).draw(in: layout.rect.insetBy(dx: 6, dy: 4), withAttributes: layout.attributes)
                readerDebugLog(
                    "translated block layout: sourceRect=\(block.rect), drawnRect=\(layout.rect), font=\(layout.font.pointSize), merged=\(block.sourceTexts.count)",
                    level: .debug
                )
            }
        }
        #elseif os(macOS)
        let pixelWidth = max(Int(imageSize.width.rounded(.up)), 1)
        let pixelHeight = max(Int(imageSize.height.rounded(.up)), 1)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return image
        }
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            context.draw(cgImage, in: CGRect(origin: .zero, size: imageSize))
        }
        for block in blocks {
            let layout = layoutRect(for: block.text, in: block.rect, imageSize: imageSize)
            NSColor.white.withAlphaComponent(0.94).setFill()
            NSBezierPath(roundedRect: layout.rect, xRadius: 8, yRadius: 8).fill()
            NSString(string: block.text).draw(in: layout.rect.insetBy(dx: 6, dy: 4), withAttributes: layout.attributes)
            readerDebugLog(
                "translated block layout: sourceRect=\(block.rect), drawnRect=\(layout.rect), font=\(layout.font.pointSize), merged=\(block.sourceTexts.count)",
                level: .debug
            )
        }
        guard let outputCGImage = context.makeImage() else {
            return image
        }
        let rendered = NSImage(cgImage: outputCGImage, size: imageSize)
        #endif
        readerDebugLog(
            "translated image rendered: overlays=\(overlays.count), blocks=\(blocks.count), size=\(Int(rendered.platformSize.width.rounded()))x\(Int(rendered.platformSize.height.rounded()))",
            level: .info
        )
        return rendered
    }

    static func renderAsync(_ image: PlatformImage, overlays: [ReaderTextBlock]) async -> PlatformImage {
        guard !overlays.isEmpty else { return image }
        return await Task.detached(priority: .userInitiated) {
            render(image, overlays: overlays)
        }.value
    }

    private static func mergeOverlaysIntoBlocks(_ overlays: [ReaderTextBlock], imageSize: CGSize) -> [TranslationBlock] {
        let rects = overlays.map { overlay in
            (
                overlay: overlay,
                rect: CGRect(
                    x: overlay.sourceRect.x * imageSize.width,
                    y: overlay.sourceRect.y * imageSize.height,
                    width: max(overlay.sourceRect.width * imageSize.width, 44),
                    height: max(overlay.sourceRect.height * imageSize.height, 24)
                ).integral
            )
        }.sorted { lhs, rhs in
            if abs(lhs.rect.minY - rhs.rect.minY) < 18 {
                return lhs.rect.minX < rhs.rect.minX
            }
            return lhs.rect.minY < rhs.rect.minY
        }

        var blocks: [TranslationBlock] = []
        for item in rects {
            if let last = blocks.last, shouldMerge(item.rect, into: last.rect) {
                let mergedRect = last.rect.union(item.rect).insetBy(dx: -6, dy: -4)
                let mergedText = [last.text, item.overlay.translatedText ?? item.overlay.sourceText]
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .joined(separator: "\n")
                let mergedSources = last.sourceTexts + [item.overlay.sourceText]
                blocks[blocks.count - 1] = TranslationBlock(
                    rect: clamp(mergedRect.integral, imageSize: imageSize),
                    text: mergedText,
                    sourceTexts: mergedSources
                )
            } else {
                blocks.append(
                    TranslationBlock(
                        rect: clamp(item.rect.insetBy(dx: -4, dy: -2).integral, imageSize: imageSize),
                        text: item.overlay.translatedText ?? item.overlay.sourceText,
                        sourceTexts: [item.overlay.sourceText]
                    )
                )
            }
        }
        readerDebugLog(
            "translation blocks merged: overlays=\(overlays.count), blocks=\(blocks.count)",
            level: .info
        )
        return blocks
    }

    private static func shouldMerge(_ lhs: CGRect, into rhs: CGRect) -> Bool {
        let verticalGap = max(lhs.minY - rhs.maxY, rhs.minY - lhs.maxY, 0)
        let horizontalGap = max(lhs.minX - rhs.maxX, rhs.minX - lhs.maxX, 0)
        let sameRow = abs(lhs.midY - rhs.midY) <= max(lhs.height, rhs.height) * 0.7
        let overlapsHorizontally = lhs.maxX >= rhs.minX - 16 && rhs.maxX >= lhs.minX - 16
        let overlapsVertically = lhs.maxY >= rhs.minY - 12 && rhs.maxY >= lhs.minY - 12
        return (sameRow && horizontalGap <= 36) || (overlapsHorizontally && verticalGap <= 28) || (overlapsVertically && horizontalGap <= 24)
    }

    private static func layoutRect(for text: String, in originRect: CGRect, imageSize: CGSize) -> (rect: CGRect, attributes: [NSAttributedString.Key: Any], font: PlatformFont) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byWordWrapping
        let maxWidth = min(max(originRect.width * 1.8, 72), max(imageSize.width - originRect.minX - 4, 72))
        let fontSizes: [CGFloat] = [16, 15, 14, 13, 12, 11, 10]

        for fontSize in fontSizes {
            let font = PlatformFont.systemFont(ofSize: fontSize, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: PlatformColor.black,
                .paragraphStyle: paragraph
            ]
            let textRect = NSString(string: text).boundingRect(
                with: CGSize(width: maxWidth - 12, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil
            )
            let candidate = CGRect(
                x: originRect.minX,
                y: originRect.minY,
                width: max(originRect.width, ceil(textRect.width) + 12),
                height: max(originRect.height, ceil(textRect.height) + 8)
            )
            let clamped = clamp(candidate.integral, imageSize: imageSize)
            if clamped.height >= ceil(textRect.height) + 8 {
                return (clamped, attributes, font)
            }
        }

        let font = PlatformFont.systemFont(ofSize: 10, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: PlatformColor.black,
            .paragraphStyle: paragraph
        ]
        return (clamp(originRect.integral, imageSize: imageSize), attributes, font)
    }

    private static func clamp(_ rect: CGRect, imageSize: CGSize) -> CGRect {
        let width = min(rect.width, imageSize.width)
        let height = min(rect.height, imageSize.height)
        let x = min(max(0, rect.minX), max(imageSize.width - width, 0))
        let y = min(max(0, rect.minY), max(imageSize.height - height, 0))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
