import AppKit
import Observation
import SwiftUI

// This standalone harness hosts the production SwiftUI view with synthetic homes.
// Windows stay outside every display and the process cannot activate. Mouse events
// go directly to that window, never to the system event queue or another app.
@main
struct HomeSelectionLayoutTests {
    @MainActor @Observable
    fileprivate final class Selection {
        var id = "home-1"
        var continuations: [String] = []
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        for count in [1, 2, 3, 7, 20] {
            try verify(count: count, size: CGSize(width: 700, height: 600), output: output)
        }
        try verify(count: 7, size: CGSize(width: 466, height: 600), output: output)
        try verify(count: 7, size: CGSize(width: 700, height: 400), output: output)
        try verify(count: 20, size: CGSize(width: 466, height: 400), output: output)
        print("PASS all 8 home-selection layout scenarios")
    }

    @MainActor
    private static func verify(count: Int, size: CGSize, output: URL) throws {
        let selection = Selection()
        let homes = (1...count).map {
            HomeSelectionView.HomeInfo(
                id: "home-\($0)", name: "Home \($0)", accessoryCount: $0 * 10, roomCount: $0
            )
        }
        let root = HomeSelectionView(
            homes: homes,
            selectedHomeID: Binding(get: { selection.id }, set: { selection.id = $0 }),
            onContinue: { selection.continuations.append(selection.id) }
        )
        .background(Color.white)
        .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        settle(host)
        try require(!window.isKeyWindow && !NSApplication.shared.isActive, "Fixture stole focus")
        try require(!NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "Fixture is onscreen")
        let name = "homes-\(count)-\(Int(size.width))x\(Int(size.height))"
        try capture(host, to: output.appendingPathComponent("\(name)-top.png"))

        guard let scroll = scrollView(in: host), let document = scroll.documentView else {
            throw Failure(description: "\(count) homes: no scroll view")
        }
        let viewport = scroll.convert(scroll.contentView.frame, to: host)
        let overflow = document.bounds.height - scroll.contentView.bounds.height
        try require(viewport.minY >= 0 && viewport.maxY < size.height - 60, "No space reserved for Continue")
        if count >= 7 {
            try require(overflow > 0, "\(count) homes should overflow the viewport")
        } else {
            try require(overflow <= 1, "\(count) homes should fit without scrolling")
        }

        // Clicking the visible footer must advance before the user scrolls.
        let footer = CGPoint(x: size.width / 2, y: size.height - 54)
        click(footer, in: host, window: window)
        settle(host)
        try require(selection.continuations == ["home-1"], "Continue is not visible/clickable initially")

        if count >= 7 {
            scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, overflow)))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle(host)
            try require(scroll.contentView.bounds.minY > 0, "Scroll position did not change")
        }

        // The last row is directly above the content's bottom padding. Exercise
        // its real SwiftUI Button action, including with smaller home counts.
        let lastRow = document.convert(
            CGPoint(x: document.bounds.midX, y: document.bounds.maxY - 55), to: host
        )
        click(lastRow, in: host, window: window)
        settle(host)
        try require(selection.id == "home-\(count)", "Last home could not be selected")

        let expectedID = selection.id
        click(footer, in: host, window: window)
        settle(host)
        try require(selection.continuations == ["home-1", expectedID], "Continue moved or lost selection after scrolling")
        try capture(host, to: output.appendingPathComponent("\(name)-selected.png"))

        selection.id = ""
        settle(host)
        click(footer, in: host, window: window)
        settle(host)
        try require(selection.continuations.count == 2, "Continue must be disabled without a selection")
        try require(!window.isKeyWindow && !NSApplication.shared.isActive, "Interaction stole focus")
        print("PASS \(name): overflow=\(Int(overflow)), selection=\(expectedID), Continue before/after scroll, disabled without selection")
    }

    @MainActor
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    @MainActor
    private static func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        host.layoutSubtreeIfNeeded()
    }

    @MainActor
    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    @MainActor
    private static func click(_ point: CGPoint, in host: NSView, window: NSWindow) {
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type, location: host.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            )!
            window.sendEvent(event)
        }
    }

    @MainActor
    private static func capture(_ host: NSView, to url: URL) throws {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw Failure(description: "Could not allocate layout image")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure(description: "Could not encode layout image")
        }
        try png.write(to: url)
    }
}
