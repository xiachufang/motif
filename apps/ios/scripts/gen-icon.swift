#!/usr/bin/env swift
// Generates Motif's 1024x1024 AppIcon.
// Design: dark indigo gradient backdrop + a stylized white "M" built from
// two angular peaks (one tall, one short — slightly offset so the silhouette
// reads as a motif/rhythmic pattern rather than a literal letter).
// Run: swift scripts/gen-icon.swift
// Output: Motif/Assets.xcassets/AppIcon.appiconset/icon-1024.png

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024
let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let outDir = scriptDir
    .deletingLastPathComponent()
    .appendingPathComponent("Motif/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let outURL = outDir.appendingPathComponent("icon-1024.png")

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: Int(size), height: Int(size),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("ctx") }

// Background gradient: deep indigo → near-black, top-left → bottom-right.
let bgColors = [
    CGColor(red: 0.16, green: 0.13, blue: 0.30, alpha: 1.0),
    CGColor(red: 0.05, green: 0.05, blue: 0.10, alpha: 1.0),
] as CFArray
let bgGradient = CGGradient(
    colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    bgGradient,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: size, y: 0),
    options: []
)

// Subtle radial light from upper-left to break up the flat fill.
let glowColors = [
    CGColor(red: 0.45, green: 0.50, blue: 0.85, alpha: 0.18),
    CGColor(red: 0.45, green: 0.50, blue: 0.85, alpha: 0.00),
] as CFArray
let glow = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0])!
ctx.drawRadialGradient(
    glow,
    startCenter: CGPoint(x: size * 0.30, y: size * 0.78),
    startRadius: 0,
    endCenter: CGPoint(x: size * 0.30, y: size * 0.78),
    endRadius: size * 0.55,
    options: []
)

// Stylized M: two angular peaks. Geometry is laid out in a centered safe
// box (icon safe area ≈ 80% of the canvas) and drawn as filled triangles
// with a small notch between them where they meet at the baseline.
let safe = size * 0.62
let cx = size / 2
let cy = size / 2
let baseline = cy - safe * 0.30
let peakTallY = cy + safe * 0.32
let peakShortY = cy + safe * 0.14

let leftBase  = cx - safe * 0.48
let midGap1   = cx - safe * 0.04
let midGap2   = cx + safe * 0.04
let rightBase = cx + safe * 0.48

let tallPeakX = cx - safe * 0.24
let shortPeakX = cx + safe * 0.26

// Tall peak (left half)
let tall = CGMutablePath()
tall.move(to: CGPoint(x: leftBase, y: baseline))
tall.addLine(to: CGPoint(x: tallPeakX, y: peakTallY))
tall.addLine(to: CGPoint(x: midGap1, y: baseline))
tall.closeSubpath()

// Short peak (right half) — offset down slightly so the silhouette reads
// as a rhythm rather than a perfectly symmetric letter.
let short = CGMutablePath()
short.move(to: CGPoint(x: midGap2, y: baseline))
short.addLine(to: CGPoint(x: shortPeakX, y: peakShortY))
short.addLine(to: CGPoint(x: rightBase, y: baseline))
short.closeSubpath()

// Peaks: fill with a soft drop shadow, then stroke (no shadow) with
// rounded line joins so the sharp tips pick up a small radius.
// Shadow is on the fill only; if we let the stroke cast its own shadow
// it bleeds inward and darkens the interior.
let peakColor = CGColor(red: 0.97, green: 0.98, blue: 1.00, alpha: 1.0)
let cornerRadius = size * 0.022 // ≈ 22pt at 1024 — just enough to soften the tip

ctx.saveGState()
ctx.setShadow(
    offset: CGSize(width: 0, height: -size * 0.022),
    blur: size * 0.05,
    color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55)
)
ctx.setFillColor(peakColor)
ctx.addPath(tall)
ctx.fillPath()
ctx.addPath(short)
ctx.fillPath()
ctx.restoreGState()

ctx.setStrokeColor(peakColor)
ctx.setLineWidth(cornerRadius * 2)
ctx.setLineJoin(.round)
ctx.setLineCap(.round)
ctx.addPath(tall)
ctx.strokePath()
ctx.addPath(short)
ctx.strokePath()

// Accent: a thin teal underline anchoring the baseline.
let accentColor = CGColor(red: 0.30, green: 0.85, blue: 0.78, alpha: 1.0)
ctx.setFillColor(accentColor)
let bar = CGRect(
    x: leftBase,
    y: baseline - size * 0.018,
    width: rightBase - leftBase,
    height: size * 0.018
)
let barPath = CGPath(roundedRect: bar, cornerWidth: bar.height / 2, cornerHeight: bar.height / 2, transform: nil)
ctx.addPath(barPath)
ctx.fillPath()

guard let image = ctx.makeImage() else { fatalError("image") }

guard let dest = CGImageDestinationCreateWithURL(
    outURL as CFURL, UTType.png.identifier as CFString, 1, nil
) else { fatalError("dest") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("finalize") }

print("wrote \(outURL.path)")
