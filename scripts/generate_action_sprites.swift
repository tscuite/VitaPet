#!/usr/bin/env swift
import AppKit
import Foundation

struct Pack {
    let directory: String
    let prefix: String
}

struct ActionSpec {
    let name: String
    let count: Int
    let frameInterval: Double
    let loop: Bool

    init(_ name: String, count: Int, frameInterval: Double, loop: Bool = false) {
        self.name = name
        self.count = count
        self.frameInterval = frameInterval
        self.loop = loop
    }
}

let packs = [
    Pack(directory: "Modules/RenderEngine/Resources", prefix: "pet"),
    Pack(directory: "Modules/RenderEngine/Resources/SpritePacks/PixelCat", prefix: "cat"),
    Pack(directory: "Modules/RenderEngine/Resources/SpritePacks/PixelDog", prefix: "dog"),
    Pack(directory: "Modules/RenderEngine/Resources/SpritePacks/PixelFox", prefix: "fox")
]

let canvas = NSSize(width: 64, height: 64)

func image(_ pack: Pack, _ state: String) -> NSImage {
    let url = URL(fileURLWithPath: pack.directory).appendingPathComponent("\(pack.prefix)_\(state)_0.png")
    if let image = NSImage(contentsOf: url) {
        return image
    }
    let idleURL = URL(fileURLWithPath: pack.directory).appendingPathComponent("\(pack.prefix)_idle_0.png")
    guard let idle = NSImage(contentsOf: idleURL) else {
        fatalError("Missing idle image at \(idleURL.path)")
    }
    return idle
}

func draw(_ base: NSImage, x: CGFloat = 0, y: CGFloat = 0, w: CGFloat = 64, h: CGFloat = 64, alpha: CGFloat = 1) {
    base.draw(in: NSRect(x: x, y: y, width: w, height: h), from: .zero, operation: .sourceOver, fraction: alpha)
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
}

func fillRect(_ rect: NSRect, _ c: NSColor) {
    c.setFill()
    NSBezierPath(rect: rect).fill()
}

func fillOval(_ rect: NSRect, _ c: NSColor) {
    c.setFill()
    NSBezierPath(ovalIn: rect).fill()
}

func strokeLine(_ points: [NSPoint], _ c: NSColor, width: CGFloat = 2) {
    guard let first = points.first else { return }
    let path = NSBezierPath()
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.lineWidth = width
    path.move(to: first)
    for point in points.dropFirst() {
        path.line(to: point)
    }
    c.setStroke()
    path.stroke()
}

func star(cx: CGFloat, cy: CGFloat, radius: CGFloat, c: NSColor) {
    strokeLine([NSPoint(x: cx - radius, y: cy), NSPoint(x: cx + radius, y: cy)], c, width: 1.5)
    strokeLine([NSPoint(x: cx, y: cy - radius), NSPoint(x: cx, y: cy + radius)], c, width: 1.5)
}

func note(x: CGFloat, y: CGFloat, c: NSColor) {
    fillOval(NSRect(x: x, y: y, width: 4, height: 4), c)
    strokeLine([NSPoint(x: x + 4, y: y + 2), NSPoint(x: x + 4, y: y + 12)], c, width: 1.5)
    strokeLine([NSPoint(x: x + 4, y: y + 12), NSPoint(x: x + 10, y: y + 9)], c, width: 1.5)
}

func strokeOval(_ rect: NSRect, _ c: NSColor, width: CGFloat = 1.5) {
    c.setStroke()
    let path = NSBezierPath(ovalIn: rect)
    path.lineWidth = width
    path.stroke()
}

func phase(index: Int, count: Int) -> CGFloat {
    guard count > 1 else { return 0 }
    return CGFloat(index) / CGFloat(count - 1)
}

func cycle(index: Int, count: Int) -> CGFloat {
    guard count > 0 else { return 0 }
    return CGFloat(sin((Double(index) / Double(count)) * Double.pi * 2))
}

func arc(index: Int, count: Int) -> CGFloat {
    CGFloat(sin(Double(phase(index: index, count: count)) * Double.pi))
}

func sparkle(x: CGFloat, y: CGFloat, radius: CGFloat, c: NSColor, alpha: CGFloat = 1) {
    let color = c.withAlphaComponent(alpha)
    star(cx: x, cy: y, radius: radius, c: color)
    fillOval(NSRect(x: x - 1, y: y - 1, width: 2, height: 2), color)
}

func heart(x: CGFloat, y: CGFloat, scale: CGFloat, c: NSColor) {
    fillOval(NSRect(x: x, y: y + scale * 0.5, width: scale, height: scale), c)
    fillOval(NSRect(x: x + scale * 0.72, y: y + scale * 0.5, width: scale, height: scale), c)
    strokeLine(
        [
            NSPoint(x: x + scale * 0.08, y: y + scale * 0.92),
            NSPoint(x: x + scale * 0.88, y: y),
            NSPoint(x: x + scale * 1.65, y: y + scale * 0.92)
        ],
        c,
        width: max(1.2, scale * 0.45)
    )
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvas.width),
        pixelsHigh: Int(canvas.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "VitaPet.SpriteGen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }

    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "VitaPet.SpriteGen", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create bitmap context"])
    }

    NSGraphicsContext.current = context
    NSColor.clear.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: canvas)).fill()
    image.draw(in: NSRect(origin: .zero, size: canvas), from: .zero, operation: .sourceOver, fraction: 1)

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "VitaPet.SpriteGen", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }

    try data.write(to: url, options: .atomic)
}

func render(base: NSImage, body: () -> Void) -> NSImage {
    let output = NSImage(size: canvas)
    output.lockFocus()
    NSColor.clear.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: canvas)).fill()
    fillOval(NSRect(x: 18, y: 6, width: 30, height: 6), color(0, 0, 0, 0.12))
    draw(base)
    body()
    output.unlockFocus()
    return output
}

func renderBlank(body: () -> Void) -> NSImage {
    let output = NSImage(size: canvas)
    output.lockFocus()
    NSColor.clear.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: canvas)).fill()
    fillOval(NSRect(x: 18, y: 6, width: 30, height: 6), color(0, 0, 0, 0.10))
    body()
    output.unlockFocus()
    return output
}

func makeFrame(pack: Pack, action: String, index: Int, count: Int) -> NSImage {
    let idle = image(pack, "idle")
    let sit = image(pack, "sit")
    let sleep = image(pack, "sleep")
    let walk = image(pack, "walk")
    let run = image(pack, "run")
    let react = image(pack, "react")
    let love = image(pack, "love")
    let sad = image(pack, "sad")
    let alert = image(pack, "alert")
    let chat = image(pack, "chat")
    let eat = image(pack, "eat")
    let wave = image(pack, "wave")
    let cheer = image(pack, "cheer")
    let shy = image(pack, "shy")

    let dark = color(0.08, 0.06, 0.05)
    let pink = color(1.0, 0.38, 0.52)
    let yellow = color(1.0, 0.82, 0.20)
    let blue = color(0.25, 0.70, 1.0)
    let purple = color(0.72, 0.50, 1.0)
    let cream = color(1.0, 0.92, 0.65)
    let progress = phase(index: index, count: count)
    let wobble = cycle(index: index, count: count)
    let lift = arc(index: index, count: count)

    switch action {
    case "blink":
        return render(base: idle) {
            let lid = max(1.2, 2.4 - abs(progress - 0.5) * 2.4)
            strokeLine([NSPoint(x: 25, y: 39), NSPoint(x: 32, y: 39)], dark, width: lid)
            strokeLine([NSPoint(x: 39, y: 39), NSPoint(x: 46, y: 39)], dark, width: lid)
            fillOval(NSRect(x: 31, y: 30, width: 3, height: 2), pink.withAlphaComponent(0.25 + lift * 0.25))
            fillOval(NSRect(x: 42, y: 30, width: 3, height: 2), pink.withAlphaComponent(0.25 + lift * 0.25))
        }
    case "sniff":
        return render(base: idle) {
            draw(idle, x: wobble * 1.5, y: 0, alpha: 0.15)
            fillOval(NSRect(x: 44 + progress * 8, y: 38 + wobble, width: 3, height: 3), blue.withAlphaComponent(0.7))
            fillOval(NSRect(x: 50 + progress * 6, y: 43 + lift * 3, width: 2.5, height: 2.5), blue.withAlphaComponent(0.48))
            fillOval(NSRect(x: 56 + progress * 3, y: 35 + lift * 6, width: 2, height: 2), blue.withAlphaComponent(0.34))
            strokeLine(
                [NSPoint(x: 43, y: 36), NSPoint(x: 47 + progress * 3, y: 37 + lift * 2)],
                dark.withAlphaComponent(0.25),
                width: 1.2
            )
        }
    case "tailWag":
        return render(base: idle) {
            let tailTip = 8 + wobble * 8
            let tailAccent = color(0.20, 0.14, 0.10, 0.34)
            strokeLine([
                NSPoint(x: 10, y: 40),
                NSPoint(x: tailTip, y: 45 + lift * 2),
                NSPoint(x: tailTip + wobble * 2, y: 51)
            ], tailAccent, width: 1.3)
            strokeLine([
                NSPoint(x: 10, y: 39),
                NSPoint(x: 8 - wobble * 5, y: 43)
            ], dark.withAlphaComponent(0.14), width: 1)
        }
    case "pawTap":
        return render(base: sit) {
            let tapX = 38 + progress * 7
            let tapY = 12 + lift * 3
            fillOval(NSRect(x: tapX, y: tapY, width: 8, height: 4), dark.withAlphaComponent(0.45))
            strokeLine([NSPoint(x: tapX + 3, y: 9), NSPoint(x: tapX + 7, y: 7)], dark.withAlphaComponent(0.35), width: 1.5)
            if index == count - 1 {
                sparkle(x: tapX + 9, y: tapY + 5, radius: 3, c: yellow, alpha: 0.75)
            }
        }
    case "pounce":
        return renderBlank {
            draw(run, x: -4 + progress * 12, y: 2 + lift * 9, w: 66, h: 58 - lift * 6)
            strokeLine([NSPoint(x: 5, y: 18), NSPoint(x: 18 + progress * 4, y: 20)], cream.withAlphaComponent(0.75), width: 2)
            strokeLine([NSPoint(x: 3, y: 25), NSPoint(x: 17 + progress * 5, y: 28)], cream.withAlphaComponent(0.55), width: 1.5)
            sparkle(x: 15 + progress * 10, y: 14 + lift * 4, radius: 2.5, c: yellow, alpha: 0.5)
        }
    case "crouch":
        return renderBlank {
            draw(sit, x: 1, y: 3 - lift * 2, w: 64, h: 48 - lift * 8)
            fillOval(NSRect(x: 18, y: 5, width: 32, height: 5), dark.withAlphaComponent(0.22 + lift * 0.12))
            strokeLine([NSPoint(x: 22, y: 25), NSPoint(x: 45, y: 25)], dark.withAlphaComponent(0.20), width: 1.4)
        }
    case "crawl":
        return renderBlank {
            draw(walk, x: progress * 9, y: 4 + wobble, w: 64, h: 42)
            fillOval(NSRect(x: 16 + progress * 4, y: 4, width: 32, height: 4), dark.withAlphaComponent(0.22))
            strokeLine([NSPoint(x: 7, y: 17), NSPoint(x: 17 + progress * 5, y: 18)], cream.withAlphaComponent(0.45), width: 1.4)
        }
    case "nap":
        return render(base: sleep) {
            fillRect(NSRect(x: 16, y: 9, width: 34, height: 8 + lift * 2), color(0.28, 0.55, 0.95, 0.75))
            fillRect(NSRect(x: 16, y: 16 + lift * 2, width: 34, height: 2), color(0.95, 0.96, 1.0, 0.85))
            strokeLine(
                [NSPoint(x: 45, y: 44 + lift * 2), NSPoint(x: 54, y: 44 + lift * 2), NSPoint(x: 46, y: 51 + lift * 2), NSPoint(x: 54, y: 51 + lift * 2)],
                blue,
                width: 1.5
            )
        }
    case "dream":
        return render(base: sleep) {
            fillOval(NSRect(x: 42 + progress * 2, y: 44 + lift * 2, width: 7, height: 5), color(1, 1, 1, 0.82))
            fillOval(NSRect(x: 48 + progress * 3, y: 48 + lift * 3, width: 9, height: 7), color(1, 1, 1, 0.82))
            sparkle(x: 52 + progress * 3, y: 53 + lift * 3, radius: 3 + lift * 3, c: yellow, alpha: 0.9)
            heart(x: 46, y: 47 + lift * 4, scale: 2.2, c: pink.withAlphaComponent(0.55))
        }
    case "beg":
        return render(base: sit) {
            fillOval(NSRect(x: 23, y: 27 + lift * 2, width: 7, height: 5), pink.withAlphaComponent(0.65 + lift * 0.25))
            fillOval(NSRect(x: 40, y: 27 + lift * 2, width: 7, height: 5), pink.withAlphaComponent(0.65 + lift * 0.25))
            strokeLine([NSPoint(x: 31, y: 21), NSPoint(x: 31 + wobble, y: 28 + lift * 3)], dark, width: 2)
            strokeLine([NSPoint(x: 39, y: 21), NSPoint(x: 39 - wobble, y: 28 + lift * 3)], dark, width: 2)
            heart(x: 47, y: 39 + lift * 4, scale: 2.4, c: pink.withAlphaComponent(0.55))
        }
    case "nuzzle":
        return renderBlank {
            draw(love, x: -3 + progress * 6, y: lift * 2)
            heart(x: 43 + progress * 4, y: 38 + lift * 4, scale: 3.2, c: pink.withAlphaComponent(0.75))
            heart(x: 50, y: 44 + lift * 3, scale: 2.0, c: pink.withAlphaComponent(0.55))
        }
    case "surprised":
        return render(base: react) {
            fillRect(NSRect(x: 50, y: 48 + lift * 2, width: 3, height: 10), yellow)
            fillRect(NSRect(x: 50, y: 43 + lift * 2, width: 3, height: 3), yellow)
            fillOval(NSRect(x: 32, y: 31, width: 5 + lift * 3, height: 5 + lift * 3), dark)
            sparkle(x: 17, y: 49, radius: 3 + lift * 2, c: yellow, alpha: 0.8)
        }
    case "blush":
        return render(base: shy) {
            let cheekAlpha = 0.45 + lift * 0.45
            fillOval(NSRect(x: 21, y: 31, width: 9, height: 5), pink.withAlphaComponent(cheekAlpha))
            fillOval(NSRect(x: 42, y: 31, width: 9, height: 5), pink.withAlphaComponent(cheekAlpha))
            strokeLine([NSPoint(x: 26, y: 29), NSPoint(x: 29, y: 31)], pink.withAlphaComponent(0.55), width: 1)
            strokeLine([NSPoint(x: 45, y: 29), NSPoint(x: 48, y: 31)], pink.withAlphaComponent(0.55), width: 1)
        }
    case "proud":
        return render(base: idle) {
            fillRect(NSRect(x: 25, y: 51 + lift * 2, width: 20, height: 4), yellow)
            fillRect(NSRect(x: 27, y: 55 + lift * 2, width: 4, height: 5), yellow)
            fillRect(NSRect(x: 34, y: 55 + lift * 2, width: 4, height: 7), yellow)
            fillRect(NSRect(x: 41, y: 55 + lift * 2, width: 4, height: 5), yellow)
            sparkle(x: 52, y: 48 + lift * 3, radius: 4 + lift * 2, c: yellow)
            sparkle(x: 18, y: 44, radius: 2.5, c: cream, alpha: 0.8)
        }
    case "melt":
        return renderBlank {
            draw(sad, x: 2, y: 2, w: 62, h: 44 - progress * 10)
            fillOval(NSRect(x: 17, y: 5, width: 32, height: 6 + progress * 2), color(0.35, 0.45, 0.95, 0.42 + progress * 0.12))
            fillOval(NSRect(x: 46, y: 15 - progress * 4, width: 3, height: 5), blue.withAlphaComponent(0.45))
        }
    case "sing":
        return render(base: chat) {
            note(x: 45 + wobble * 2, y: 43 + lift * 5, c: purple)
            note(x: 54 - wobble * 2, y: 36 + progress * 4, c: blue)
            sparkle(x: 18, y: 48 + lift * 2, radius: 2.5, c: cream, alpha: 0.7)
        }
    case "meditate":
        return renderBlank {
            draw(sit, x: 0, y: 2 + lift * 4)
            strokeLine([NSPoint(x: 18, y: 28), NSPoint(x: 31, y: 35 + lift * 2), NSPoint(x: 46, y: 28)], purple.withAlphaComponent(0.55), width: 1.5)
            strokeOval(NSRect(x: 22 - lift * 2, y: 49 - lift, width: 22 + lift * 4, height: 8 + lift * 2), purple.withAlphaComponent(0.35), width: 1)
            fillOval(NSRect(x: 30, y: 52 + lift * 2, width: 5, height: 5), purple.withAlphaComponent(0.7))
        }
    case "coffee":
        return render(base: sit) {
            fillRect(NSRect(x: 45, y: 20, width: 9, height: 9), color(0.9, 0.92, 0.95))
            fillRect(NSRect(x: 47, y: 22, width: 5, height: 4), color(0.45, 0.26, 0.12))
            strokeLine([NSPoint(x: 48, y: 33), NSPoint(x: 47 - wobble, y: 39 + lift * 4)], color(0.8, 0.8, 0.8, 0.65), width: 1.2)
            strokeLine([NSPoint(x: 52, y: 33), NSPoint(x: 53 + wobble, y: 39 + lift * 5)], color(0.8, 0.8, 0.8, 0.65), width: 1.2)
            fillOval(NSRect(x: 54, y: 23, width: 4, height: 4), color(0.9, 0.92, 0.95, 0.85))
        }
    case "snack":
        return render(base: eat) {
            fillOval(NSRect(x: 45 - progress * 4, y: 21 + lift * 2, width: 10, height: 10), color(0.76, 0.49, 0.24))
            fillOval(NSRect(x: 48 - progress * 4, y: 24 + lift * 2, width: 2, height: 2), dark.withAlphaComponent(0.6))
            fillOval(NSRect(x: 52 - progress * 4, y: 26 + lift * 2, width: 2, height: 2), dark.withAlphaComponent(0.6))
            fillOval(NSRect(x: 56, y: 18, width: 2, height: 2), color(0.76, 0.49, 0.24, 0.55))
        }
    case "stargaze":
        return render(base: sit) {
            sparkle(x: 43 + progress * 3, y: 51 + lift * 2, radius: 4 + lift * 3, c: yellow)
            sparkle(x: 54 - progress * 2, y: 44 + lift * 2, radius: 3 + lift, c: blue)
            sparkle(x: 19, y: 53, radius: 2.5, c: cream, alpha: 0.8)
            strokeLine([NSPoint(x: 25, y: 42), NSPoint(x: 35, y: 48)], dark.withAlphaComponent(0.35), width: 1.5)
        }
    case "sparkle":
        return render(base: cheer) {
            sparkle(x: 15 + wobble * 2, y: 46 + lift * 3, radius: 4 + lift * 3, c: yellow)
            sparkle(x: 50 - wobble * 2, y: 48 + progress * 2, radius: 5 + lift, c: blue)
            sparkle(x: 44, y: 18 + lift * 4, radius: 3 + lift * 2, c: purple)
            sparkle(x: 25, y: 54, radius: 2.5, c: cream, alpha: 0.7)
        }
    case "slide":
        return renderBlank {
            draw(walk, x: progress * 15, y: -lift, w: 66, h: 58)
            strokeLine([NSPoint(x: 8, y: 16), NSPoint(x: 24 + progress * 4, y: 14)], cream.withAlphaComponent(0.8), width: 2)
            strokeLine([NSPoint(x: 5, y: 22), NSPoint(x: 20 + progress * 5, y: 20)], cream.withAlphaComponent(0.6), width: 1.5)
            strokeLine([NSPoint(x: 2, y: 28), NSPoint(x: 15 + progress * 4, y: 26)], cream.withAlphaComponent(0.35), width: 1.2)
        }
    case "pawReach":
        return render(base: wave) {
            let reachY = 38 + lift * 8
            strokeLine([NSPoint(x: 44, y: 33), NSPoint(x: 56, y: reachY)], dark, width: 2)
            fillOval(NSRect(x: 55, y: reachY - 2, width: 5, height: 5), pink.withAlphaComponent(0.85))
            sparkle(x: 59, y: reachY + 4, radius: 2.5, c: yellow, alpha: 0.65)
        }
    case "guard":
        return render(base: alert) {
            fillRect(NSRect(x: 47, y: 20, width: 10, height: 14), color(0.2, 0.35, 0.85, 0.65))
            strokeLine([NSPoint(x: 47, y: 34), NSPoint(x: 52, y: 38), NSPoint(x: 57, y: 34)], color(0.2, 0.35, 0.85, 0.75), width: 2)
            fillRect(NSRect(x: 52, y: 48 + lift * 2, width: 2, height: 8), yellow)
            fillRect(NSRect(x: 52, y: 44 + lift * 2, width: 2, height: 2), yellow)
            strokeOval(NSRect(x: 46 - lift, y: 18 - lift, width: 13 + lift * 2, height: 18 + lift * 2), blue.withAlphaComponent(0.25), width: 1.2)
        }
    case "somersault":
        return renderBlank {
            draw(alert, x: 0, y: 4 + lift * 5, w: 64, h: 56 - lift * 4)
            strokeOval(NSRect(x: 17, y: 13, width: 31, height: 31), blue.withAlphaComponent(0.32 + lift * 0.22), width: 2)
            strokeLine(
                [
                    NSPoint(x: 13 + progress * 8, y: 20 + lift * 7),
                    NSPoint(x: 23 + progress * 8, y: 33 + lift * 8),
                    NSPoint(x: 36 + progress * 6, y: 40 - lift * 4)
                ],
                cream.withAlphaComponent(0.78),
                width: 2
            )
            sparkle(x: 50 - progress * 7, y: 46 + lift * 3, radius: 3 + lift, c: yellow, alpha: 0.85)
        }
    default:
        return idle
    }
}

let actions: [ActionSpec] = [
    ActionSpec("blink", count: 4, frameInterval: 0.09),
    ActionSpec("sniff", count: 4, frameInterval: 0.14),
    ActionSpec("tailWag", count: 5, frameInterval: 0.10, loop: true),
    ActionSpec("pawTap", count: 4, frameInterval: 0.10),
    ActionSpec("pounce", count: 4, frameInterval: 0.10),
    ActionSpec("crouch", count: 3, frameInterval: 0.14),
    ActionSpec("crawl", count: 4, frameInterval: 0.12),
    ActionSpec("nap", count: 4, frameInterval: 0.55, loop: true),
    ActionSpec("dream", count: 4, frameInterval: 0.32),
    ActionSpec("beg", count: 4, frameInterval: 0.14),
    ActionSpec("nuzzle", count: 4, frameInterval: 0.14),
    ActionSpec("surprised", count: 3, frameInterval: 0.12),
    ActionSpec("blush", count: 4, frameInterval: 0.18),
    ActionSpec("proud", count: 4, frameInterval: 0.16),
    ActionSpec("melt", count: 4, frameInterval: 0.18),
    ActionSpec("sing", count: 5, frameInterval: 0.13),
    ActionSpec("meditate", count: 4, frameInterval: 0.42, loop: true),
    ActionSpec("coffee", count: 4, frameInterval: 0.22),
    ActionSpec("snack", count: 4, frameInterval: 0.15),
    ActionSpec("stargaze", count: 4, frameInterval: 0.28),
    ActionSpec("sparkle", count: 5, frameInterval: 0.10),
    ActionSpec("slide", count: 4, frameInterval: 0.09),
    ActionSpec("pawReach", count: 4, frameInterval: 0.12),
    ActionSpec("guard", count: 4, frameInterval: 0.22, loop: true),
    ActionSpec("somersault", count: 4, frameInterval: 0.09)
]

func frames(for action: ActionSpec, pack: Pack) -> [String] {
    (0..<action.count).map { "\(pack.prefix)_\(action.name)_\($0)" }
}

func comboFrames(name: String, pack: Pack) -> [String] {
    switch name {
    case "danceCombo":
        return [
            "\(pack.prefix)_dance_0",
            "\(pack.prefix)_slide_0",
            "\(pack.prefix)_slide_1",
            "\(pack.prefix)_spin_0",
            "\(pack.prefix)_tailWag_0",
            "\(pack.prefix)_tailWag_2",
            "\(pack.prefix)_sparkle_0",
            "\(pack.prefix)_sparkle_3",
            "\(pack.prefix)_proud_0"
        ]
    case "joySpinCombo":
        return [
            "\(pack.prefix)_celebrate_0",
            "\(pack.prefix)_spin_0",
            "\(pack.prefix)_sparkle_0",
            "\(pack.prefix)_sparkle_2",
            "\(pack.prefix)_tailWag_0",
            "\(pack.prefix)_tailWag_3",
            "\(pack.prefix)_proud_0"
        ]
    case "somersaultCombo":
        return [
            "\(pack.prefix)_crouch_0",
            "\(pack.prefix)_somersault_0",
            "\(pack.prefix)_somersault_1",
            "\(pack.prefix)_somersault_2",
            "\(pack.prefix)_somersault_3",
            "\(pack.prefix)_pawReach_0",
            "\(pack.prefix)_sparkle_0",
            "\(pack.prefix)_sparkle_3"
        ]
    case "boxingCombo":
        return [
            "\(pack.prefix)_guard_0",
            "\(pack.prefix)_guard_2",
            "\(pack.prefix)_pawTap_0",
            "\(pack.prefix)_pawReach_0",
            "\(pack.prefix)_angry_0",
            "\(pack.prefix)_pawReach_2",
            "\(pack.prefix)_proud_0"
        ]
    case "parkourCombo":
        return [
            "\(pack.prefix)_pounce_0",
            "\(pack.prefix)_pounce_2",
            "\(pack.prefix)_slide_0",
            "\(pack.prefix)_slide_2",
            "\(pack.prefix)_roll_0",
            "\(pack.prefix)_spin_0",
            "\(pack.prefix)_land_0",
            "\(pack.prefix)_cheer_0"
        ]
    case "partyCombo":
        return [
            "\(pack.prefix)_sing_0",
            "\(pack.prefix)_sing_3",
            "\(pack.prefix)_dance_0",
            "\(pack.prefix)_sparkle_0",
            "\(pack.prefix)_sparkle_3",
            "\(pack.prefix)_cheer_0",
            "\(pack.prefix)_tailWag_0",
            "\(pack.prefix)_tailWag_3",
            "\(pack.prefix)_blush_0"
        ]
    case "trainingCombo":
        return [
            "\(pack.prefix)_guard_0",
            "\(pack.prefix)_guard_2",
            "\(pack.prefix)_crouch_0",
            "\(pack.prefix)_pounce_0",
            "\(pack.prefix)_pawTap_0",
            "\(pack.prefix)_pawReach_0",
            "\(pack.prefix)_angry_0",
            "\(pack.prefix)_proud_0"
        ]
    default:
        return []
    }
}

func updateManifest(for pack: Pack, actions: [ActionSpec]) throws {
    let manifestURL = URL(fileURLWithPath: pack.directory).appendingPathComponent("manifest.json")
    let data = try Data(contentsOf: manifestURL)
    guard var manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(domain: "VitaPet.SpriteGen", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid manifest"])
    }

    var states = manifest["states"] as? [String: Any] ?? [:]
    for action in actions {
        states[action.name] = [
            "frames": frames(for: action, pack: pack),
            "frameInterval": action.frameInterval,
            "loop": action.loop
        ]
    }

    for comboName in [
        "danceCombo",
        "somersaultCombo",
        "boxingCombo",
        "parkourCombo",
        "partyCombo",
        "trainingCombo",
        "joySpinCombo"
    ] {
        states[comboName] = [
            "frames": comboFrames(name: comboName, pack: pack),
            "frameInterval": 0.10,
            "loop": false
        ]
    }

    manifest["states"] = states
    let output = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try output.write(to: manifestURL, options: .atomic)
}

var written = 0
for pack in packs {
    for action in actions {
        for index in 0..<action.count {
            let frame = makeFrame(pack: pack, action: action.name, index: index, count: action.count)
            let url = URL(fileURLWithPath: pack.directory).appendingPathComponent("\(pack.prefix)_\(action.name)_\(index).png")
            try writePNG(frame, to: url)
            written += 1
        }
    }
    try updateManifest(for: pack, actions: actions)
}

print("Wrote \(written) action sprite frames")
