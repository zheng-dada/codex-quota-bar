import AppKit
import SwiftUI

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

let screensAndAnchors: [(NSRect, NSRect)] = [
    (NSRect(x: 0, y: 25, width: 1512, height: 919), NSRect(x: 1300, y: 944, width: 150, height: 38)),
    (NSRect(x: 0, y: 0, width: 1280, height: 700), NSRect(x: 5, y: 700, width: 140, height: 24)),
    (NSRect(x: -1920, y: 0, width: 1920, height: 1055), NSRect(x: -150, y: 1055, width: 150, height: 25)),
    (NSRect(x: 1920, y: 1080, width: 1440, height: 875), NSRect(x: 3240, y: 1955, width: 120, height: 25)),
    (NSRect(x: 0, y: 0, width: 1024, height: 300), NSRect(x: 800, y: 300, width: 140, height: 24))
]
for (visible, anchor) in screensAndAnchors {
    for height: CGFloat in [380, 580, 1200] {
        let frame = QuotaPanelLayout.frame(contentSize: NSSize(width: 340, height: height), anchor: anchor, visibleFrame: visible)
        check(frame.maxY <= anchor.minY - 8, "panel stays below menu bar")
        check(frame.minY >= visible.minY + 8, "panel stays above dock / visible bottom")
        check(frame.minX >= visible.minX + 8 && frame.maxX <= visible.maxX - 8, "panel stays on status item's display")
    }
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    let bucket = RateLimitBucket(limitId: "codex", primary: LimitWindow(usedPercent: 49, windowDurationMins: 300, resetsAt: Date().addingTimeInterval(7200).timeIntervalSince1970), secondary: LimitWindow(usedPercent: 15, windowDurationMins: 10080, resetsAt: Date().addingTimeInterval(300000).timeIntervalSince1970), planType: "plus")
    let store = QuotaStore(snapshot: QuotaSnapshot(bucket: bucket, fetchedAt: Date(), executable: URL(fileURLWithPath: "/test/codex")))
    let view = NSHostingView(rootView: QuotaPopover(store: store))
    view.layoutSubtreeIfNeeded()
    let size = view.fittingSize
    print("Measured content: \(size.width) × \(size.height)")
    check(size.width == 340, "panel preserves designed width")
    check(size.height > 320 && size.height < 650, "SwiftUI reports full intrinsic content height")

    let statusText = StatusTextView()
    statusText.update(fiveHour: store.snapshot?.fiveHour, weekly: store.snapshot?.weekly, showUsed: store.showUsed)
    check(statusText.intrinsicContentSize.width > 60 && statusText.intrinsicContentSize.width < 220, "compact status text fits both percentages")
    check(statusText.hitTest(.zero) == nil, "status text leaves click handling to status button")

    statusText.update(fiveHour: store.snapshot?.fiveHour, weekly: store.snapshot?.weekly, showUsed: false, activity: RunActivity(activeCount: 1, currentRate: 38))
    check(statusText.displayedLabels == ["51%", "38t/s"], "running speed replaces weekly cell and preserves five-hour quota")
    check(statusText.intrinsicContentSize.width < 160, "running speed fits a compact two-cell menu bar")
    statusText.update(fiveHour: store.snapshot?.fiveHour, weekly: store.snapshot?.weekly, showUsed: false, activity: RunActivity(activeCount: 1))
    check(statusText.displayedLabels == ["51%", "…"], "running without a sample shows ellipsis")
    statusText.update(fiveHour: store.snapshot?.fiveHour, weekly: store.snapshot?.weekly, showUsed: false)
    check(statusText.displayedLabels == ["51%", "85%"], "completion restores weekly percentage")
    statusText.update(fiveHour: store.snapshot?.fiveHour, weekly: store.snapshot?.weekly, showUsed: true, needsSync: true, activity: RunActivity(activeCount: 2, currentRate: 0.05))
    check(statusText.displayedLabels == ["49%", "<0.1t/s"], "used mode and sync marker do not change the rate meaning")

    func luminance(_ color: NSColor) -> Double {
        let rgb = color.usingColorSpace(.sRGB)!
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return linear(rgb.redComponent) * 0.2126 + linear(rgb.greenComponent) * 0.7152 + linear(rgb.blueComponent) * 0.0722
    }
    for dark in [false, true] {
        let text = luminance(dark ? .white : .black)
        for state in RunStatus.allCases {
            statusText.update(fiveHour: store.snapshot?.fiveHour, weekly: store.snapshot?.weekly, showUsed: false,
                              activity: RunActivity(activeCount: state == .running ? 1 : 0, currentRate: 38, status: state))
            check(statusText.displayedStatus == state, "all six states reach the menu renderer")
            let fill = luminance(MenuStatusPalette.fill(state, dark: dark) ?? MenuStatusPalette.background(dark: dark))
            check((max(text, fill) + 0.05) / (min(text, fill) + 0.05) >= 4.5, "text remains legible against each state fill")
        }
        check(MenuStatusPalette.fill(.idle, dark: dark) == nil, "idle restores the original transparent appearance")
    }

    let surface = RoundedPanelView(frame: NSRect(x: 0, y: 0, width: 340, height: 419))
    for height: CGFloat in [419, 580, 260] {
        surface.setFrameSize(NSSize(width: 340, height: height))
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        guard let image = surface.material.maskImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            check(false, "panel blur must have a rounded mask")
            return
        }
        let width = bitmap.pixelsWide
        let bitmapHeight = bitmap.pixelsHigh
        check(bitmap.colorAt(x: 0, y: 0)!.alphaComponent < 0.01 && bitmap.colorAt(x: width - 1, y: 0)!.alphaComponent < 0.01, "top corners remain transparent")
        check(bitmap.colorAt(x: 0, y: bitmapHeight - 1)!.alphaComponent < 0.01 && bitmap.colorAt(x: width - 1, y: bitmapHeight - 1)!.alphaComponent < 0.01, "bottom corners remain transparent after resize")
        check(bitmap.colorAt(x: width / 2, y: bitmapHeight / 2)!.alphaComponent > 0.99, "rounded mask keeps the panel center visible")
    }

    if CommandLine.arguments.count > 1 {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let samples: [(String, LimitWindow?, LimitWindow?)] = [
            ("normal", store.snapshot?.fiveHour, store.snapshot?.weekly),
            ("warning", LimitWindow(usedPercent: 85, windowDurationMins: 300, resetsAt: nil), LimitWindow(usedPercent: 95, windowDurationMins: 10080, resetsAt: nil)),
            ("boundary", LimitWindow(usedPercent: 90, windowDurationMins: 300, resetsAt: nil), LimitWindow(usedPercent: 80, windowDurationMins: 10080, resetsAt: nil))
        ]
        for (sample, fiveHour, weekly) in samples {
            statusText.update(fiveHour: fiveHour, weekly: weekly, showUsed: false)
            for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let appearance = NSAppearance(named: appearanceName)!
                statusText.appearance = appearance
                statusText.frame = NSRect(x: 0, y: 0, width: 1, height: NSStatusBar.system.thickness)
                statusText.setFrameSize(statusText.intrinsicContentSize)
                let image = NSImage(size: statusText.bounds.size)
                image.lockFocus()
                appearance.performAsCurrentDrawingAppearance {
                    (name == "light" ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.14, alpha: 1)).setFill()
                    statusText.bounds.fill()
                    statusText.draw(statusText.bounds)
                }
                image.unlockFocus()
                let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
                try! bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("status-text-\(sample)-\(name).png"))
            }
        }
        let renderer = ImageRenderer(content: QuotaPopover(store: store).background(Color(NSColor.windowBackgroundColor)))
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
            try! png.write(to: directory.appendingPathComponent("panel-content.png"))
        }
    }
}
print("PASS: \(checks) layout checks (menu bar clearance, screen edges, short displays, multiple displays, intrinsic sizing)")
