#!/usr/bin/env swift

import AppKit
import Foundation

// Motif App Store artwork generator. The composition and Apple device-bezel
// treatment follow the Castly screenshot tooling, with Motif-specific colors,
// typography, and copy.

struct Scene {
    let sourceStem: String
    let outputStem: String
    let firstLine: String
    let secondLine: String
    let backgroundTop: NSColor
    let backgroundBottom: NSColor
    let decoration: NSColor
}

struct Device {
    let directory: String
    let canvasSize: NSSize
    let bezelPath: String
    let bezelSize: NSSize
    let screenRect: NSRect
    let screenRadius: CGFloat
    let artworkWidthFraction: CGFloat
    let artworkTop: CGFloat
    let titleFontSize: CGFloat
    let titleLeft: CGFloat
    let titleTop: CGFloat
}

enum GeneratorError: Error, CustomStringConvertible {
    case missingImage(String)
    case cannotCreateBitmap(String)
    case cannotEncode(String)

    var description: String {
        switch self {
        case .missingImage(let path): return "Missing or unreadable image: \(path)"
        case .cannotCreateBitmap(let path): return "Could not create bitmap for: \(path)"
        case .cannotEncode(let path): return "Could not encode PNG: \(path)"
        }
    }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let rawRoot = root.appendingPathComponent("artifacts/appstore/raw/en-US")
let outputRoot = root.appendingPathComponent("artifacts/appstore/marketing/en-US")

let castlyRoot = "/Users/feichao/AllSunday/Castly/artifacts/appstore/mockups/apple-bezels"
let devices = [
    Device(
        directory: "iphone69",
        canvasSize: NSSize(width: 1320, height: 2868),
        bezelPath: "\(castlyRoot)/iphone-16-pro-max-black-titanium-portrait.png",
        bezelSize: NSSize(width: 1470, height: 3000),
        screenRect: NSRect(x: 75, y: 66, width: 1320, height: 2868),
        screenRadius: 170,
        artworkWidthFraction: 0.70,
        artworkTop: 800,
        titleFontSize: 102,
        titleLeft: 92,
        titleTop: 185
    ),
    Device(
        directory: "ipad129",
        canvasSize: NSSize(width: 2064, height: 2752),
        bezelPath: "\(castlyRoot)/ipad-pro-m5-13-space-black-portrait.png",
        bezelSize: NSSize(width: 2300, height: 3000),
        screenRect: NSRect(x: 118, y: 124, width: 2064, height: 2752),
        screenRadius: 92,
        artworkWidthFraction: 0.86,
        artworkTop: 600,
        titleFontSize: 116,
        titleLeft: 138,
        titleTop: 135
    ),
]

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

let scenes = [
    Scene(
        sourceStem: "01-workspaces",
        outputStem: "01-workspaces",
        firstLine: "All your workspaces.",
        secondLine: "One secure connection.",
        backgroundTop: color(0xEEF5FF),
        backgroundBottom: color(0xDCEBFA),
        decoration: color(0x4A87C7)
    ),
    Scene(
        sourceStem: "06-codex",
        outputStem: "02-codex",
        firstLine: "Codex, on the go.",
        secondLine: "Review. Plan. Build.",
        backgroundTop: color(0xEEF6FF),
        backgroundBottom: color(0xDBEAF9),
        decoration: color(0x3474B6)
    ),
    Scene(
        sourceStem: "02-terminal",
        outputStem: "03-terminal",
        firstLine: "A real terminal.",
        secondLine: "Ship from anywhere.",
        backgroundTop: color(0xECFAF8),
        backgroundBottom: color(0xD6EFEC),
        decoration: color(0x239A91)
    ),
    Scene(
        sourceStem: "07-codex-threads",
        outputStem: "04-codex-threads",
        firstLine: "Every Codex thread.",
        secondLine: "Always within reach.",
        backgroundTop: color(0xF2F6FC),
        backgroundBottom: color(0xE2EBF6),
        decoration: color(0x5277A3)
    ),
    Scene(
        sourceStem: "08-sidechat",
        outputStem: "05-sidechat",
        firstLine: "Explore in Side Chat.",
        secondLine: "Keep work focused.",
        backgroundTop: color(0xF3F8F7),
        backgroundBottom: color(0xE1EFEC),
        decoration: color(0x4D887E)
    ),
    Scene(
        sourceStem: "09-sidechat-list",
        outputStem: "06-sidechat-list",
        firstLine: "Parallel ideas.",
        secondLine: "One shared context.",
        backgroundTop: color(0xF4F3FA),
        backgroundBottom: color(0xE7E4F2),
        decoration: color(0x746B9D)
    ),
    Scene(
        sourceStem: "03-files",
        outputStem: "07-files",
        firstLine: "Every project file.",
        secondLine: "At your fingertips.",
        backgroundTop: color(0xF1F7FF),
        backgroundBottom: color(0xDDEBFA),
        decoration: color(0x3674B7)
    ),
    Scene(
        sourceStem: "04-code",
        outputStem: "08-code",
        firstLine: "Read and edit code.",
        secondLine: "From anywhere.",
        backgroundTop: color(0xEFFAF5),
        backgroundBottom: color(0xDAF0E7),
        decoration: color(0x2F9A77)
    ),
    Scene(
        sourceStem: "05-git",
        outputStem: "09-git",
        firstLine: "Review every change.",
        secondLine: "Before you ship.",
        backgroundTop: color(0xF4F1FF),
        backgroundBottom: color(0xE4DFF7),
        decoration: color(0x725AB8)
    ),
]

func image(at path: String) throws -> NSImage {
    guard let value = NSImage(contentsOfFile: path) else {
        throw GeneratorError.missingImage(path)
    }
    return value
}

func drawAspectFill(_ source: NSImage, in rect: NSRect) {
    let sourceSize = source.size
    let scale = max(rect.width / sourceSize.width, rect.height / sourceSize.height)
    let size = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    let drawRect = NSRect(
        x: rect.midX - size.width / 2,
        y: rect.midY - size.height / 2,
        width: size.width,
        height: size.height
    )
    source.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
}

func makeDeviceArtwork(
    lightRaw: NSImage,
    device: Device
) throws -> NSImage {
    let bezel = try image(at: device.bezelPath)
    let size = device.bezelSize
    let artwork = NSImage(size: size)
    artwork.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high

    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(
        roundedRect: device.screenRect,
        xRadius: device.screenRadius,
        yRadius: device.screenRadius
    ).addClip()
    drawAspectFill(lightRaw, in: device.screenRect)
    NSGraphicsContext.restoreGraphicsState()

    bezel.draw(in: NSRect(origin: .zero, size: size))
    artwork.unlockFocus()
    return artwork
}

func drawBackground(scene: Scene, size: NSSize) {
    let bounds = NSRect(origin: .zero, size: size)
    NSGradient(starting: scene.backgroundBottom, ending: scene.backgroundTop)?.draw(
        in: bounds,
        angle: 90
    )

    let bubble = scene.decoration.withAlphaComponent(0.12)
    bubble.setFill()
    NSBezierPath(
        ovalIn: NSRect(
            x: size.width * 0.67,
            y: size.height * 0.69,
            width: size.width * 0.54,
            height: size.width * 0.54
        )
    ).fill()

    scene.decoration.withAlphaComponent(0.08).setFill()
    NSBezierPath(
        roundedRect: NSRect(
            x: -size.width * 0.18,
            y: size.height * 0.49,
            width: size.width * 0.58,
            height: size.height * 0.13
        ),
        xRadius: size.width * 0.08,
        yRadius: size.width * 0.08
    ).fill()
}

func drawTitle(scene: Scene, device: Device) {
    let firstFont = NSFont.systemFont(ofSize: device.titleFontSize, weight: .bold)
    let secondFont = NSFont.systemFont(ofSize: device.titleFontSize, weight: .bold)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .left
    paragraph.lineBreakMode = .byClipping

    let firstAttributes: [NSAttributedString.Key: Any] = [
        .font: firstFont,
        .foregroundColor: color(0x13243A),
        .paragraphStyle: paragraph,
    ]
    let secondAttributes: [NSAttributedString.Key: Any] = [
        .font: secondFont,
        .foregroundColor: scene.decoration,
        .paragraphStyle: paragraph,
    ]

    let firstY = device.canvasSize.height - device.titleTop - device.titleFontSize * 1.08
    let secondY = firstY - device.titleFontSize * 1.10
    let width = device.canvasSize.width - device.titleLeft * 2
    (scene.firstLine as NSString).draw(
        in: NSRect(x: device.titleLeft, y: firstY, width: width, height: device.titleFontSize * 1.2),
        withAttributes: firstAttributes
    )
    (scene.secondLine as NSString).draw(
        in: NSRect(x: device.titleLeft, y: secondY, width: width, height: device.titleFontSize * 1.2),
        withAttributes: secondAttributes
    )
}

func render(
    scene: Scene,
    device: Device,
    lightRawPath: String,
    outputPath: String
) throws {
    let lightRaw = try image(at: lightRawPath)
    let artwork = try makeDeviceArtwork(
        lightRaw: lightRaw,
        device: device
    )
    let width = Int(device.canvasSize.width)
    let height = Int(device.canvasSize.height)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw GeneratorError.cannotCreateBitmap(outputPath)
    }
    bitmap.size = device.canvasSize

    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw GeneratorError.cannotCreateBitmap(outputPath)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    drawBackground(scene: scene, size: device.canvasSize)
    drawTitle(scene: scene, device: device)

    let artworkWidth = device.canvasSize.width * device.artworkWidthFraction
    let artworkHeight = artworkWidth * artwork.size.height / artwork.size.width
    let destination = NSRect(
        x: (device.canvasSize.width - artworkWidth) / 2,
        y: device.canvasSize.height - device.artworkTop - artworkHeight,
        width: artworkWidth,
        height: artworkHeight
    )

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
    shadow.shadowBlurRadius = device.directory == "iphone69" ? 34 : 26
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    artwork.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw GeneratorError.cannotEncode(outputPath)
    }
    try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
}

do {
    for device in devices {
        let inputDirectory = rawRoot.appendingPathComponent(device.directory)
        let outputDirectory = outputRoot.appendingPathComponent(device.directory)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        for existing in try FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil
        ) where existing.pathExtension.lowercased() == "png" {
            try FileManager.default.removeItem(at: existing)
        }
        for scene in scenes {
            let lightInput = inputDirectory
                .appendingPathComponent("\(scene.sourceStem)-light.png").path
            let output = outputDirectory
                .appendingPathComponent("\(scene.outputStem).png").path
            try render(
                scene: scene,
                device: device,
                lightRawPath: lightInput,
                outputPath: output
            )
            print("Generated \(output)")
        }
    }
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
