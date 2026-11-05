import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `Volumist --render-demo <gif> [<frames-folder>]`: animates the real interface with sample data
/// for the README. It doesn't touch audio: what it shows is scripted, not a recording.
enum DemoRenderer {
    private static let fps = 15.0
    private static let duration = 30.0
    private static let zoom: CGFloat = 2
    private static let canvas = CGSize(width: 720, height: 700)
    private static var viewport: CGFloat { canvas.height / zoom }

    private static func eased(_ time: Double, from start: Double, to end: Double) -> Double {
        let x = min(max((time - start) / (end - start), 0), 1)
        return x * x * (3 - 2 * x)
    }

    private static func caption(at time: Double) -> String {
        switch time {
        case ..<5.5: "Set the volume of each app"
        case ..<8.5: "Mute any of them"
        case ..<13: "A call starts: the others fade down"
        case ..<17: "The call ends: they come back"
        case ..<23: "Even out loud and quiet parts"
        default: "Shape the sound of each app"
        }
    }

    /// Where the camera looks, in points from the top of the window.
    private static func focus(at time: Double) -> CGFloat {
        switch time {
        case ..<8.5: 165
        case ..<17: 315
        default: 300
        }
    }

    /// The pointer's path: time, x, y, in window points.
    private static let pointerPath: [(time: Double, x: CGFloat, y: CGFloat)] = [
        (0, 300, 60), (1.2, 225, 175), (2, 225, 175), (4, 156, 175), (5, 156, 175),
        (6.3, 334, 97), (8, 334, 97), (9.5, 200, 330), (15.5, 200, 330),
        (17.8, 334, 190), (19.5, 334, 190), (20.8, 38, 255), (23, 38, 255),
        (24.3, 300, 279), (26.8, 300, 279), (27.8, 201, 220), (28, 201, 220), (29, 159, 220), (30, 159, 220),
    ]

    private static func pointer(at time: Double) -> CGPoint {
        for (start, end) in zip(pointerPath, pointerPath.dropFirst()) where time <= end.time {
            let t = eased(time, from: start.time, to: end.time)
            return CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        }
        return CGPoint(x: 159, y: 220)
    }

    private static let clicks = [6.9, 18.5, 21.6, 25]

    private static func icon(_ path: String) -> NSImage {
        let file = Bundle(path: path)?.object(forInfoDictionaryKey: "CFBundleIconFile") as? String
        let bundled = file.flatMap {
            NSImage(contentsOfFile: "\(path)/Contents/Resources/\(($0 as NSString).deletingPathExtension).icns")
        }
        return bundled ?? NSWorkspace.shared.icon(forFile: path)
    }

    @MainActor
    static func render(to path: String, keyFrames: String?) {
        _ = NSApplication.shared
        let icons = ["Music": icon("/System/Applications/Music.app"), "Spotify": icon("/Applications/Spotify.app"),
                     "VLC": icon("/Applications/VLC.app"), "Zoom": icon("/Applications/zoom.us.app")]
        func app(_ name: String, _ volume: Double, playing: Bool, muted: Bool = false, output: String? = nil,
                 lowered: Bool = false, balance: Double = 0, equalizer: [Double] = Equalizer.flat,
                 leveling: Bool = false) -> AudioApp {
            AudioApp(id: name, name: name, icon: icons[name], isPlaying: playing, volume: volume, isMuted: muted,
                     outputUID: output, outputName: output, outputMissing: false, isLowered: lowered,
                     balance: balance, equalizer: equalizer, levelsVolume: leveling)
        }

        let engine = AudioEngine(preview: [], output: "Headphones", call: nil, expanded: nil, previewLevels: [:])
        let view = NSHostingView(rootView: MixerView(engine: engine)
            .background(Color(nsColor: .windowBackgroundColor)))
        view.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = view

        let frames = Int(duration * fps)
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                                UTType.gif.identifier as CFString, frames, nil) else {
            exit(1)
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary

        var lowering = 1.0
        var camera = focus(at: 0)
        for frame in 0..<frames {
            let time = Double(frame) / fps
            let inCall = time >= 8.5 && time < 13
            lowering += ((inCall ? 0.25 : 1) - lowering) * 0.08
            camera += (focus(at: time) - camera) * 0.07

            let volume = 1 - 0.45 * eased(time, from: 2, to: 4)
            let boost = eased(time, from: 25.2, to: 26.5)
            let equalizer = Equalizer.presets[1].gains.map { $0 * boost }
            let balance = -0.35 * eased(time, from: 28, to: 29)
            let leveling = time >= 21.6
            let musicMuted = time >= 6.9
            let spotifyLevel = (0.5 + 0.25 * sin(time * 9) * sin(time * 2.3)) * volume * volume * lowering
            let podcast = (0.35 + 0.2 * abs(sin(time * 6.1))) * (musicMuted ? 0 : 1)
            let video = (0.3 + 0.15 * abs(sin(time * 5.3))) * lowering
            let voice = inCall ? 0.35 + 0.3 * abs(sin(time * 3.1)) * abs(sin(time * 7.7)) : 0

            engine.setPreview(apps: [
                app("Music", 0.8, playing: !musicMuted, muted: musicMuted, lowered: false),
                app("Spotify", volume, playing: true,
                    output: "External Speakers", lowered: inCall, balance: balance,
                    equalizer: equalizer, leveling: leveling),
                app("VLC", 0.6, playing: true, lowered: inCall),
                app("Zoom", 1, playing: inCall),
            ], call: inCall ? "Zoom" : nil, expanded: time >= 18.5 ? "Spotify" : nil)
            engine.levels.levels = ["Music": Float(podcast), "Spotify": Float(spotifyLevel),
                                    "VLC": Float(video), "Zoom": Float(voice)]

            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            view.setFrameSize(view.fittingSize)
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
                  let image = compose(panel: bitmap, view: view, camera: camera, time: time) else { exit(1) }
            CGImageDestinationAddImage(destination, image, frameProperties)
            if let keyFrames, frame % 75 == 40 {
                let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                try? data?.write(to: URL(fileURLWithPath: "\(keyFrames)/frame-\(frame).png"))
            }
        }
        exit(CGImageDestinationFinalize(destination) ? 0 : 1)
    }

    @MainActor
    private static func compose(panel bitmap: NSBitmapImageRep, view: NSView, camera: CGFloat, time: Double) -> CGImage? {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let context = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let panel = bitmap.cgImage else { return nil }

        let size = view.bounds.size
        let top = min(max(camera - viewport / 2, 0), max(size.height - viewport, 0))
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x * zoom, y: canvas.height - (y - top) * zoom)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSColor(white: 0.93, alpha: 1).setFill()
        NSRect(origin: .zero, size: canvas).fill()
        context.interpolationQuality = .high
        context.draw(panel, in: CGRect(x: 0, y: canvas.height - (size.height - top) * zoom,
                                       width: size.width * zoom, height: size.height * zoom))

        for click in clicks where time >= click && time < click + 0.5 {
            let progress = (time - click) / 0.5
            let center = point(pointer(at: time).x, pointer(at: time).y)
            let radius = 10 + 34 * progress
            NSColor.systemBlue.withAlphaComponent(0.55 * (1 - progress)).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                   width: radius * 2, height: radius * 2))
            ring.lineWidth = 5
            ring.stroke()
        }

        let tip = point(pointer(at: time).x, pointer(at: time).y)
        let arrow = NSBezierPath()
        for (index, offset) in [(0.0, 0.0), (0, -38), (9, -30), (16, -45), (23, -42), (16, -27), (28, -27)].enumerated() {
            let vertex = NSPoint(x: tip.x + offset.0, y: tip.y + offset.1)
            if index == 0 { arrow.move(to: vertex) } else { arrow.line(to: vertex) }
        }
        arrow.close()
        NSColor.black.setFill()
        NSColor.white.setStroke()
        arrow.lineWidth = 3
        arrow.stroke()
        arrow.fill()

        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30, weight: .semibold),
                                                         .foregroundColor: NSColor.white]
        let text = caption(at: time) as NSString
        let textSize = text.size(withAttributes: attributes)
        let pill = NSRect(x: (canvas.width - textSize.width) / 2 - 26, y: 20,
                          width: textSize.width + 52, height: textSize.height + 22)
        NSColor(red: 0.3, green: 0.3, blue: 0.85, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        text.draw(at: NSPoint(x: pill.minX + 26, y: pill.minY + 11), withAttributes: attributes)

        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
