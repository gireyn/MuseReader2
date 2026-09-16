#!/usr/bin/env swift

// Rasterize the bundled MuseScore mark into every launcher/AppIcon size.
// The renderer intentionally uses AppKit's SVG support so the checked-in
// vector is the source of truth for all raster platform resources. Android's
// adaptive foreground is a matching, safe-zone-inset vector mirror in
// res/drawable and should be updated alongside the SVG if the mark's geometry
// changes. App icons are
// exported as opaque RGB PNGs so transparent pixels cannot become black on a
// launcher background (and iOS App Store validation does not see an alpha
// channel).

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let sourceRelativePath = "assets/branding/muse_reader_icon.svg"

// Android uses a little more breathing room than iOS around the foreground
// mark. Keep this value in sync with ic_launcher_foreground.xml so adaptive
// and pre-adaptive Android launchers present the same logo size.
private let androidMarkScale = 0.82
private let markGroupToken = "<g id=\"mark\">"

// Used only as a defensive underlay if a future source edit leaves a pixel
// transparent. The current SVG intentionally has a full-bleed gradient.
private let fallbackBackgroundColor = CGColor(
    red: 33.0 / 255.0,
    green: 123.0 / 255.0,
    blue: 183.0 / 255.0,
    alpha: 1.0
)

private let iconSizes: [(String, Int)] = [
    // Android legacy launcher icons (mdpi through xxxhdpi).
    ("android/app/src/main/res/mipmap-mdpi/ic_launcher.png", 48),
    ("android/app/src/main/res/mipmap-hdpi/ic_launcher.png", 72),
    ("android/app/src/main/res/mipmap-xhdpi/ic_launcher.png", 96),
    ("android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png", 144),
    ("android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png", 192),
    ("android/app/src/main/res/mipmap-mdpi/ic_launcher_round.png", 48),
    ("android/app/src/main/res/mipmap-hdpi/ic_launcher_round.png", 72),
    ("android/app/src/main/res/mipmap-xhdpi/ic_launcher_round.png", 96),
    ("android/app/src/main/res/mipmap-xxhdpi/ic_launcher_round.png", 144),
    ("android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_round.png", 192),
    // iOS AppIcon catalog. Values are physical pixels, not point sizes.
    ("ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@1x.png", 20),
    ("ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@2x.png", 40),
    ("ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@3x.png", 60),
    ("ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@1x.png", 29),
    ("ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@2x.png", 58),
    ("ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@3x.png", 87),
    ("ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@1x.png", 40),
    ("ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@2x.png", 80),
    ("ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@3x.png", 120),
    ("ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@2x.png", 120),
    ("ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@3x.png", 180),
    ("ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@1x.png", 76),
    ("ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@2x.png", 152),
    ("ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-83.5x83.5@2x.png", 167),
    ("ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png", 1024),
]

private enum IconError: LocalizedError {
    case missingSource(String)
    case invalidSource
    case contextCreation(Int)
    case imageCreation
    case destinationCreation(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case let .missingSource(path):
            return "Icon source not found: \(path)"
        case .invalidSource:
            return "Unable to rasterize the MuseScore SVG icon"
        case let .contextCreation(size):
            return "Unable to create a \(size)x\(size) bitmap context"
        case .imageCreation:
            return "Unable to create a resized icon image"
        case let .destinationCreation(path):
            return "Unable to create PNG destination: \(path)"
        case let .writeFailed(path):
            return "Unable to finalize PNG: \(path)"
        }
    }
}

private func loadSourceImage(root: String, markScale: Double? = nil) throws -> CGImage {
    let path = URL(fileURLWithPath: root)
        .appendingPathComponent(sourceRelativePath)
        .path
    guard FileManager.default.fileExists(atPath: path) else {
        throw IconError.missingSource(path)
    }

    let image: NSImage
    if let markScale {
        // Keep one canonical SVG and derive the Android-safe variant in memory
        // rather than maintaining a second copy of the long MuseScore paths.
        guard let source = try? String(contentsOfFile: path, encoding: .utf8),
              source.contains(markGroupToken) else {
            throw IconError.invalidSource
        }

        let offset = (1.0 - markScale) * 512.0
        let replacement = String(
            format: "  <g id=\"mark\" transform=\"translate(%.2f %.2f) scale(%.2f)\">",
            locale: Locale(identifier: "en_US_POSIX"),
            offset,
            offset,
            markScale
        )
        let androidSVG = source.replacingOccurrences(
            of: markGroupToken,
            with: replacement
        )
        guard let data = androidSVG.data(using: .utf8),
              let loadedImage = NSImage(data: data) else {
            throw IconError.invalidSource
        }
        image = loadedImage
    } else {
        guard let loadedImage = NSImage(contentsOfFile: path) else {
            throw IconError.invalidSource
        }
        image = loadedImage
    }

    var proposedRect = NSRect(origin: .zero, size: image.size)
    guard let cgImage = image.cgImage(
        forProposedRect: &proposedRect,
        context: nil,
        hints: nil
    ) else {
        throw IconError.invalidSource
    }
    return cgImage
}

private func resizedImage(_ source: CGImage, size: Int) throws -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        throw IconError.contextCreation(size)
    }

    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    context.setFillColor(fallbackBackgroundColor)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    context.draw(
        source,
        in: CGRect(x: 0, y: 0, width: size, height: size)
    )
    guard let image = context.makeImage() else {
        throw IconError.imageCreation
    }
    return image
}

private func writePNG(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw IconError.destinationCreation(path)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw IconError.writeFailed(path)
    }
}

let root = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

do {
    let source = try loadSourceImage(root: root)
    let androidSource = try loadSourceImage(root: root, markScale: androidMarkScale)
    for (relativePath, size) in iconSizes {
        let output = URL(fileURLWithPath: root)
            .appendingPathComponent(relativePath)
            .path
        let variant = relativePath.hasPrefix("android/") ? androidSource : source
        try writePNG(try resizedImage(variant, size: size), to: output)
    }
    print("Generated MuseScore app icons in \(root)")
} catch {
    fputs("MuseScore icon generation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
