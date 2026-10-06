import AppKit
import FloCore
import FloKit

/// Welcome screen (no workspace): opening actions and persistent recent files/folders.
final class WelcomeView: FlippedView {
    let model: ShellModel   // strong: AppKit can still lay a view out after its window controller (the other owner) is gone
    let folders: WelcomeRecentsView
    let files: WelcomeRecentsView
    var onAddFolder: (() -> Void)?
    var onOpenFile: (() -> Void)?
    var onStartFromScratch: (() -> Void)?
    init(model: ShellModel) {
        self.model = model
        folders = WelcomeRecentsView(model: model, isDirectory: true)
        files = WelcomeRecentsView(model: model, isDirectory: false)
        super.init(frame: .zero)
        addSubview(folders)
        addSubview(files)
        reloadRecents()
    }
    required init?(coder: NSCoder) { fatalError() }

    var hasRecentItems: Bool { !folders.rows.isEmpty || !files.rows.isEmpty }

    func reloadRecents() {
        folders.reload(model.recentFolderPaths)
        files.reload(model.recentFiles.map(\.path))
        needsLayout = true
        needsDisplay = true
    }

    private var buttonTop: CGFloat {
        hasRecentItems ? 64 + CGFloat(messageLines.count) * 21.125 + 28 : bounds.height / 2 + 4
    }

    static let titles = ["Open Folder", "Open File", "Start from Scratch"]
    /// Localized titles and their button rects: one centred row, or a centred
    /// column of equal-width buttons when the row doesn't fit (long languages, narrow windows).
    var buttons: [(String, CGRect)] {
        let f = UIFonts.ui(model.values, weight: .medium)
        let titles = Self.titles.map { L($0) }
        let widths = titles.map { TextStyle(font: f, color: .black).width($0) + 32 }
        let total = widths.reduce(0, +) + 12 * CGFloat(widths.count - 1)
        let y = buttonTop
        if total > bounds.width - 32 {
            let w = min(widths.max() ?? 0, max(0, bounds.width - 32))
            return titles.enumerated().map { i, t in (t, CGRect(x: (bounds.width - w) / 2, y: y + CGFloat(i) * (35.5 + 8), width: w, height: 35.5)) }
        }
        var x = (bounds.width - total) / 2
        let row = zip(titles, widths).map { t, w in defer { x += w + 12 }; return (t, CGRect(x: x, y: y, width: w, height: 35.5)) }
        guard userInterfaceLayoutDirection == .rightToLeft else { return row }
        // right-to-left UI (Arabic, Urdu): the primary button leads on the right
        return row.map { t, r in (t, CGRect(x: bounds.width - r.maxX, y: r.minY, width: r.width, height: r.height)) }
    }

    /// The prompt above the buttons, wrapped to 252pt (wider for long languages).
    var messageLines: [String] {
        let width = hasRecentItems ? min(460, max(1, bounds.width - 48)) : 252
        return TextWrap.lines(L("Open a folder of notes or a single file, or start from scratch."), font: UIFonts.ui(model.values), width: width)
    }

    override func layout() {
        super.layout()
        folders.isHidden = folders.rows.isEmpty
        files.isHidden = files.rows.isEmpty
        let sections = [folders, files].filter { !$0.isHidden }
        guard !sections.isEmpty else { return }
        let width = min(800, max(0, bounds.width - 48))
        let top = (buttons.map { $0.1.maxY }.max() ?? buttonTop) + 32
        let available = max(0, bounds.height - top - 24)
        if sections.count == 2, width >= 600 {
            let columnWidth = (width - 32) / 2
            let height = min(available, sections.map(\.preferredHeight).max() ?? 0)
            for (i, section) in sections.enumerated() {
                section.frame = CGRect(x: (bounds.width - width) / 2 + CGFloat(i) * (columnWidth + 32),
                                       y: top, width: columnWidth, height: height)
            }
        } else {
            let columnWidth = min(480, width)
            let height = max(0, (available - CGFloat(sections.count - 1) * 20) / CGFloat(sections.count))
            var y = top
            for section in sections {
                let h = min(height, section.preferredHeight)
                section.frame = CGRect(x: (bounds.width - columnWidth) / 2, y: y, width: columnWidth, height: h)
                y += h + 20
            }
        }
        sections.forEach { $0.needsLayout = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = model.palette_
        p.bg.setFill(); bounds.fill(using: .sourceOver)
        let style = TextStyle(font: UIFonts.ui(model.values), color: p.textMuted)
        let lines = messageLines
        var y = buttonTop - 28 - CGFloat(lines.count) * 21.125
        for l in lines { style.draw(l, x: (bounds.width - style.width(l)) / 2, lineTop: y, lineHeight: 21.125, in: ctx); y += 21.125 }
        let bf = UIFonts.ui(model.values, weight: .medium)
        for (i, (t, r)) in buttons.enumerated() {
            if i == 0 {
                p.textPrimary.setFill(); roundedPath(r, 8).fill()
                let ts = TextStyle(font: bf, color: p.bgBaseOpaque)
                ts.draw(t, x: r.minX + max(16, (r.width - ts.width(t)) / 2), lineTop: r.minY + 8, lineHeight: 19.5, maxWidth: r.width - 32, in: ctx)
            } else {
                let path = roundedPath(r.insetBy(dx: 0.5, dy: 0.5), 7.5)
                p.lineSubtle.setStroke(); path.lineWidth = 1; path.stroke()
                let ts = TextStyle(font: bf, color: p.textSecondary)
                ts.draw(t, x: r.minX + max(16, (r.width - ts.width(t)) / 2), lineTop: r.minY + 8, lineHeight: 19.5, maxWidth: r.width - 32, in: ctx)
            }
        }
    }

    final class WelcomeRecentsView: FlippedView {
        let model: ShellModel
        let isDirectory: Bool
        let scroll = NSScrollView()
        let document = FlippedView()
        private(set) var rows: [RecentItemButton] = []
        static let rowHeight: CGFloat = 48

        init(model: ShellModel, isDirectory: Bool) {
            self.model = model
            self.isDirectory = isDirectory
            super.init(frame: .zero)
            scroll.drawsBackground = false
            scroll.contentView.drawsBackground = false
            scroll.automaticallyAdjustsContentInsets = false
            scroll.hasVerticalScroller = !ShellSnapshot.active
            scroll.autohidesScrollers = true
            document.autoresizingMask = [.width]
            scroll.documentView = document
            scroll.setAccessibilityLabel(heading)
            addSubview(scroll)
        }
        required init?(coder: NSCoder) { fatalError() }

        var heading: String { isDirectory ? L("Recent folders") : L("Recent files") }
        var preferredHeight: CGFloat { 28 + min(240, CGFloat(rows.count) * Self.rowHeight) }

        func reload(_ paths: [String]) {
            if paths != rows.map(\.path) {
                rows.forEach { $0.removeFromSuperview() }
                rows = paths.map { RecentItemButton(model: model, path: $0, isDirectory: isDirectory) }
                rows.forEach(document.addSubview)
                scroll.contentView.scroll(to: .zero)
            }
            rows.forEach { $0.needsDisplay = true }
            needsLayout = true
            needsDisplay = true
        }

        override func layout() {
            super.layout()
            scroll.frame = CGRect(x: 0, y: 28, width: bounds.width, height: max(0, bounds.height - 28))
            document.frame = CGRect(x: 0, y: 0, width: scroll.contentSize.width,
                                    height: max(scroll.contentSize.height, CGFloat(rows.count) * Self.rowHeight))
            scroll.tile()
            document.setFrameSize(NSSize(width: scroll.contentSize.width, height: document.frame.height))
            for (i, row) in rows.enumerated() {
                row.frame = CGRect(x: 0, y: CGFloat(i) * Self.rowHeight, width: document.bounds.width, height: Self.rowHeight)
            }
            scroll.suppressScrollPocket()
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            TextStyle(font: UIFonts.ui(model.values, weight: .medium), color: model.palette_.textSecondary)
                .draw(heading, x: 10, lineTop: 0, lineHeight: 20, maxWidth: bounds.width - 20, in: ctx)
        }
    }

    /// Native button behavior (keyboard and accessibility), drawn like the rest of the shell.
    final class RecentItemButton: NSButton {
        let model: ShellModel
        let path: String
        let isDirectory: Bool
        private var hovering = false { didSet { needsDisplay = true } }

        init(model: ShellModel, path: String, isDirectory: Bool) {
            self.model = model
            self.path = path
            self.isDirectory = isDirectory
            super.init(frame: .zero)
            let name = (path as NSString).lastPathComponent
            title = name.isEmpty ? path : name
            toolTip = path
            setAccessibilityLabel(title)
            setAccessibilityHelp(path)
            isBordered = false
            setButtonType(.momentaryPushIn)
            target = self
            action = #selector(open)
            focusRingType = .exterior
            autoresizingMask = [.width]
        }
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 2, dy: 2) }
        override func drawFocusRingMask() { roundedPath(focusRingMaskBounds, 6).fill() }

        override func becomeFirstResponder() -> Bool {
            guard super.becomeFirstResponder() else { return false }
            scrollToVisible(bounds)
            return true
        }

        @objc func open() { model.openRecentItem(path, isDirectory: isDirectory) }

        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        override func mouseEntered(with event: NSEvent) { hovering = true }
        override func mouseExited(with event: NSEvent) { hovering = false }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let p = model.palette_
            if hovering || isHighlighted { p.surfaceSubtle.setFill(); roundedPath(bounds.insetBy(dx: 2, dy: 2), 6).fill() }
            (isDirectory ? Icon.folderClosed : Icon.file)
                .draw(in: CGRect(x: 10, y: 15, width: 18, height: 18), color: p.textIconMuted, ctx: ctx)
            TextStyle(font: UIFonts.ui(model.values, weight: .medium), color: p.textPrimary)
                .draw(title, x: 38, lineTop: 5, lineHeight: 19.5, maxWidth: bounds.width - 48, in: ctx)
            let parent = ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
            TextStyle(font: UIFonts.ui(model.values, size: 11), color: p.textMuted)
                .draw(parent, x: 38, lineTop: 26, lineHeight: 16, maxWidth: bounds.width - 48, in: ctx)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let b = buttons
        if b[0].1.contains(pt) { onAddFolder?() } else if b[1].1.contains(pt) { onOpenFile?() } else if b[2].1.contains(pt) { onStartFromScratch?() }
    }
}

/// `--shell-snapshot <workspace | -> --data-dir D [--width W --height H] [--out png]
/// [--dump json] [--expand dir]... [--open file] [--action newtab|palette[:q]|create:name]`
///
/// Builds the real window content offscreen (x=-10000, never ordered front,
/// never activates, no Dock icon) and writes a PNG + a frame dump.
@MainActor
enum ShellSnapshot {
    static var active = false
    /// `--settings-snapshot --data-dir D [--pane id] [--dark] [--out png] [--dump json]`:
    /// the Settings window rendered offscreen (frame incl. toolbar).
    static func runSettings(_ args: [String]) {
        func opt(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        active = true
        let data = opt("--data-dir") ?? NSTemporaryDirectory()
        let backend = SettingsBackend(dataDir: AppDataDirectory(baseURL: URL(fileURLWithPath: data)))
        let wc = SettingsWindowController(backend: backend)
        let w = wc.window!
        w.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
        wc.select(opt("--pane") ?? "general")
        pump(ms: 400)
        w.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        let frameView = w.contentView!.superview!
        frameView.layoutSubtreeIfNeeded()
        frameView.display()
        if let out = opt("--out") {
            let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)!
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
        if let d = opt("--dump") {
            let dump: [String: Any] = ["title": w.title, "frame": [w.frame.width, w.frame.height],
                                       "language": L10n.current, "rtl": NSApp.userInterfaceLayoutDirection == .rightToLeft,
                                       "resizable": w.styleMask.contains(.resizable),
                                       "toolbar": w.toolbar?.items.map { $0.label } ?? [],
                                       "keys": wc.selectedPane.controls.map { $0.def.key },
                                       "preferred": [wc.selectedPane.preferredContentSize.width, wc.selectedPane.preferredContentSize.height],
                                       "content": [w.contentView!.frame.width, w.contentView!.frame.height]]
            try? JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: d))
        }
    }

    static func run(_ args: [String]) {
        func opt(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        func all(_ n: String) -> [String] { args.indices.filter { args[$0] == n && $0 + 1 < args.count }.map { args[$0 + 1] } }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        // Legacy NSScrollers break offscreen cacheDisplay; the oracle hides scrollbars too.
        active = true
        guard let ws = opt("--shell-snapshot"), let data = opt("--data-dir") else {
            FileHandle.standardError.write(Data("usage: --shell-snapshot <workspace> --data-dir <dir>\n".utf8)); exit(2)
        }
        let w = CGFloat(Double(opt("--width") ?? "1200") ?? 1200), h = CGFloat(Double(opt("--height") ?? "800") ?? 800)
        let model = ShellModel(dataDir: AppDataDirectory(baseURL: URL(fileURLWithPath: data)), importLegacy: false)
        model.readOnly = true
        model.systemIsDark = { false }
        let wc = ShellWindowController(model: model, frame: NSRect(x: -10000, y: -10000, width: w, height: h), offscreen: true)
        wc.root.opaqueBase = true
        wc.root.wantsLayer = true
        wc.window?.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        // "-": no workspace (welcome screen); --open <file>: open that note too
        if ws != "-" { pump { await model.openWorkspace(ws, openFile: opt("--open")) } }
        wc.flush()
        for d in all("--expand") { model.toggleDirectory(d) }
        wc.flush()
        wc.root.layoutSubtreeIfNeeded()
        wc.didActivate()
        if let a = opt("--action") {
            if a == "newtab" { model.editor.openNewTab() }
            else if a.hasPrefix("palette") {
                model.perform(.openFileSearch)
                if let q = a.split(separator: ":", maxSplits: 1).dropFirst().first { model.setPaletteQuery(String(q)) }
            } else if a.hasPrefix("create:") {
                model.perform(.newNote)
                model.setPaletteQuery(String(a.dropFirst("create:".count)))
            }
        }
        pump(ms: 150)
        wc.flush()
        wc.root.needsLayout = true
        wc.root.layoutSubtreeIfNeeded()
        wc.root.area.updateRail()
        wc.root.display()
        if let out = opt("--out") {
            let rep = wc.root.bitmapImageRepForCachingDisplay(in: wc.root.bounds)!
            wc.root.cacheDisplay(in: wc.root.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
        if ProcessInfo.processInfo.environment["SHELL_DEBUG"] != nil {
            func walk(_ v: NSView, _ depth: Int) {
                print(String(repeating: "  ", count: depth) + "\(type(of: v)) \(v.frame) b=\(v.bounds.origin) hidden=\(v.isHidden)")
                if depth < 7 { v.subviews.forEach { walk($0, depth + 1) } }
            }
            walk(wc.root, 0)
        }
        if let dbg = ProcessInfo.processInfo.environment["SHELL_DEBUG_DIR"] {
            for (name, v) in [("sidebar", wc.root.sidebar as NSView), ("area", wc.root.area), ("tabs", wc.root.tabs)] {
                let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dbg + "/" + name + ".png"))
            }
        }
        if let d = opt("--dump") {
            let json = try! JSONSerialization.data(withJSONObject: wc.root.dump(), options: [.prettyPrinted, .sortedKeys])
            try? json.write(to: URL(fileURLWithPath: d))
        }
    }

    /// Run an async job to completion while servicing the main run loop.
    static func pump(_ job: @escaping @MainActor () async -> Void) {
        var done = false
        Task { @MainActor in await job(); done = true }
        let deadline = Date().addingTimeInterval(30)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }

    static func pump(ms: Double) {
        let end = Date().addingTimeInterval(ms / 1000)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }
}
