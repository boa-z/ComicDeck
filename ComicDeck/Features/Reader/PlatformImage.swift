import Foundation
import SwiftUI

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#elseif os(macOS)
import AppKit
typealias PlatformImage = NSImage
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #elseif os(macOS)
        self.init(nsImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    nonisolated var platformSize: CGSize {
        #if os(iOS)
        size
        #elseif os(macOS)
        size
        #endif
    }

    var platformPNGData: Data? {
        #if os(iOS)
        pngData()
        #elseif os(macOS)
        guard
            let tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffRepresentation)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
        #endif
    }

    var platformJPEGData: Data? {
        #if os(iOS)
        jpegData(compressionQuality: 0.92)
        #elseif os(macOS)
        guard
            let tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffRepresentation)
        else {
            return nil
        }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        #endif
    }

    nonisolated var platformMemoryCost: Int {
        #if os(iOS)
        guard let cgImage else {
            return Int(size.width * size.height * scale * scale * 4)
        }
        return cgImage.bytesPerRow * cgImage.height
        #elseif os(macOS)
        if let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cgImage.bytesPerRow * cgImage.height
        }
        return Int(size.width * size.height * 4)
        #endif
    }
}
