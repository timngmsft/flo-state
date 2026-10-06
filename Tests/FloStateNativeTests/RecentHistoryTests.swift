import AppKit
import XCTest
@testable import FloCore
@testable import FloStateNative

@MainActor
final class RecentHistoryTests: XCTestCase {
    private func welcomeApp(_ f: ShellFixture) -> AppDelegate {
        f.model.setSetting("window.restore-workspace", .bool(false))
        let app = AppDelegate(dataDir: f.model.dataDir, launchPaths: [], offscreen: true)
        app.startup()
        return app
    }

    func testWelcomeLoadsPersistedHistoryInMostRecentOrder() throws {
        let f = ShellFixture(files: ["one/note.md": "# One", "two/note.md": "# Two"])
        try f.model.recentWorkspacesStore.record(f.root)
        try f.model.recentWorkspacesStore.record(f.p("one"))
        try f.model.recentFilesStore.record(f.p("one/note.md"))
        try f.model.recentFilesStore.record(f.p("two/note.md"))
        try f.model.recentFilesStore.record(f.p("one/note.md"))
        let app = welcomeApp(f)
        defer { for c in app.windows { c.window?.close() } }
        let welcome = try XCTUnwrap(app.windows.first?.root.welcome)
        XCTAssertTrue(welcome.hasRecentItems)
        XCTAssertEqual(welcome.folders.rows.map(\.path), [f.p("one"), f.root])
        XCTAssertEqual(welcome.files.rows.map(\.path), [f.p("one/note.md"), f.p("two/note.md")])
        XCTAssertEqual(welcome.files.rows.map(\.title), ["note.md", "note.md"])
        XCTAssertEqual(welcome.files.rows.map(\.toolTip), [f.p("one/note.md"), f.p("two/note.md")])
        XCTAssertTrue(welcome.files.rows.allSatisfy(\.acceptsFirstResponder))
    }

    func testClickRecentFileOpensOnlyTheFile() async throws {
        let f = ShellFixture(files: ["note.md": "# Note", "other.md": "other", "sub/deep.md": "deep"])
        try f.model.recentFilesStore.record(f.p("note.md"))
        let app = welcomeApp(f)
        defer { for c in app.windows { c.window?.close() } }
        let row = try XCTUnwrap(app.windows.first?.root.welcome.files.rows.first)
        row.performClick(nil)
        await app.waitForPendingOpens()

        XCTAssertEqual(app.windows.count, 1, "the welcome window is replaced, not left behind")
        let model = try XCTUnwrap(app.windows.first?.model)
        XCTAssertNil(model.root)
        XCTAssertNil(model.index, "a recent file must not scan its parent folder")
        XCTAssertEqual(model.editor.activeFilePath, f.p("note.md"))
        XCTAssertEqual(model.recentWorkspacesStore.load(), [])
        XCTAssertEqual(model.recentFilesStore.load().map(\.path), [f.p("note.md")])
    }

    func testClickRecentFolderReusesWelcomeAndRestoresTabs() async throws {
        let f = ShellFixture(files: ["a.md": "# A", "b.md": "# B"])
        try f.model.recentWorkspacesStore.record(f.root)
        let tabs = [ShellFixture.fileTab(f.p("a.md")), ShellFixture.fileTab(f.p("b.md"))]
        try f.model.sessionStore.save(root: f.root, tabs: tabs, activeIndex: 1)
        let app = welcomeApp(f)
        defer { for c in app.windows { c.window?.close() } }
        let controller = try XCTUnwrap(app.windows.first)
        controller.model.watcherEnabled = false
        try XCTUnwrap(controller.root.welcome.folders.rows.first).performClick(nil)
        await app.waitForPendingOpens()

        XCTAssertEqual(app.windows.count, 1)
        XCTAssertTrue(app.windows.first === controller)
        XCTAssertEqual(controller.model.root, f.root)
        XCTAssertEqual(controller.model.editor.tabs.map(\.location), [.file(f.p("a.md")), .file(f.p("b.md"))])
        XCTAssertEqual(controller.model.editor.activeFilePath, f.p("b.md"))
        XCTAssertEqual(controller.model.recentWorkspacesStore.load(), [f.root])
    }

    func testClickAlreadyOpenFolderDoesNotDuplicateWorkspace() async throws {
        let f = ShellFixture(files: ["a.md": "a", "other/b.md": "b"])
        let app = welcomeApp(f)
        defer { for c in app.windows { c.window?.close() } }
        app.windows[0].model.watcherEnabled = false
        app.openWorkspaceWindow(f.root, file: nil, keepSession: true)
        await app.waitForPendingOpens()
        let workspace = try XCTUnwrap(app.windows.first)
        workspace.model.recordRecentWorkspace(f.p("other"))
        app.openWelcomeWindow()
        let welcome = try XCTUnwrap(app.windows.last?.root.welcome)
        try XCTUnwrap(welcome.folders.rows.first { $0.path == f.root }).performClick(nil)
        await app.waitForPendingOpens()

        XCTAssertEqual(app.windows.filter { $0.model.root == f.root }.count, 1)
        XCTAssertTrue(app.windows.first === workspace)
        XCTAssertEqual(workspace.model.recentWorkspacesStore.load(), [f.root, f.p("other")])
    }

    func testStaleRecentFileDoesNotCloseWelcome() throws {
        let f = ShellFixture(files: ["a.md": "a"])
        try f.model.recentFilesStore.record(f.p("a.md"))
        let app = welcomeApp(f)
        defer { for c in app.windows { c.window?.close() } }
        let controller = try XCTUnwrap(app.windows.first)
        var alerts: [String] = []
        controller.model.alert = { alerts.append($0) }
        let row = try XCTUnwrap(controller.root.welcome.files.rows.first)
        try FileManager.default.removeItem(atPath: f.p("a.md"))
        row.performClick(nil)
        controller.flush()

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertTrue(app.windows.first === controller)
        XCTAssertFalse(controller.root.welcome.hasRecentItems)
        XCTAssertEqual(controller.model.recentFilesStore.load().map(\.path), [f.p("a.md")], "temporarily unavailable entries remain on disk")
    }

    func testWelcomeHidesMissingAndWrongKindPaths() throws {
        let f = ShellFixture(files: ["a.md": "a"])
        try f.model.recentWorkspacesStore.record(f.p("missing-folder"))
        try f.model.recentWorkspacesStore.record(f.p("a.md"))
        TFS.write(f.model.dataDir.recentFilesURL.path, "[\"\(f.root)\", \"\(f.p("missing.md"))\"]")
        let app = welcomeApp(f)
        defer { for c in app.windows { c.window?.close() } }
        let controller = try XCTUnwrap(app.windows.first)
        XCTAssertFalse(controller.root.welcome.hasRecentItems)
        var alerts: [String] = []
        controller.model.alert = { alerts.append($0) }
        controller.model.openRecentItem(f.p("a.md"), isDirectory: true)
        controller.model.openRecentItem(f.root, isDirectory: false)
        XCTAssertEqual(alerts.count, 2)
        XCTAssertNil(controller.model.root)
        XCTAssertTrue(controller.model.editor.tabs.isEmpty)
    }

    func testHistoryIncludesTextFilesRegisteredWithFinder() async {
        let f = ShellFixture(files: ["note.txt": "text", "notes.log": "log", "legacy.mdown": "# Markdown"])
        for path in ["note.txt", "notes.log", "legacy.mdown"] { await f.model.editor.openCompactFile(f.p(path)) }
        XCTAssertEqual(f.model.recentFiles.map(\.name), ["legacy.mdown", "notes.log", "note.txt"])
        let welcome = WelcomeView(model: f.model)
        XCTAssertEqual(welcome.files.rows.map(\.path), ["legacy.mdown", "notes.log", "note.txt"].map(f.p))
        let header = CompactHeaderView(model: f.model)
        XCTAssertEqual(header.pickerMenu().items.map(\.title), ["Recents", "notes", "note"])
        f.model.palette = PaletteState(intent: .search, query: "note")
        XCTAssertEqual(f.model.paletteView()?.items.filter { if case .file = $0.kind { return true }; return false }.count, 2)
    }

    func testRecordingAndClearingHistoryRefreshEveryWelcomeWindow() async throws {
        let f = ShellFixture(files: ["a.md": "# A"])
        let app = welcomeApp(f)
        app.openWelcomeWindow()
        app.adopt(model: f.model)
        defer { for c in app.windows { c.window?.close() } }
        XCTAssertTrue(app.windows.allSatisfy { !$0.root.welcome.hasRecentItems })
        await f.open(file: "a.md")
        f.model.sessionAutosaver.flush()
        let session = f.model.sessionStore.load(root: f.root)
        for c in app.windows {
            c.flush()
            XCTAssertEqual(c.root.welcome.files.rows.map(\.path), [f.p("a.md")])
            XCTAssertEqual(c.root.welcome.folders.rows.map(\.path), [f.root])
        }

        let backend = SettingsBackend(dataDir: f.model.dataDir)
        backend.onRecentsChange = { app.recentsChanged(from: nil) }
        let settings = SettingsWindowController(backend: backend)
        settings.window?.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        defer { settings.window?.close() }
        settings.select("general")
        settings.selectedPane.clearRecentHistoryButton.performClick(nil)

        for c in app.windows {
            c.flush()
            XCTAssertFalse(c.root.welcome.hasRecentItems)
        }
        XCTAssertFalse(settings.selectedPane.clearRecentHistoryButton.isEnabled)
        XCTAssertEqual(app.applicationDockMenu(NSApplication.shared)?.items.count, 0)
        XCTAssertFalse(ShellMenus.workspaceMenu(model: f.model).items.contains { $0.title == f.model.workspaceName })
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("a.md"), "clearing history does not close documents")
        XCTAssertEqual(f.model.sessionStore.load(root: f.root), session)
        XCTAssertEqual(TFS.read(f.p("a.md")), "# A")
    }

    func testClearedHistoryStaysEmptyUntilAnotherOpenAndSurvivesRestart() async throws {
        let f = ShellFixture(files: ["a.md": "# A", "b.md": "# B"])
        await f.open(file: "a.md")
        f.model.sessionAutosaver.flush()
        SettingsBackend(dataDir: f.model.dataDir).clearRecentHistory()
        f.model.editor.updateCursorPos(f.p("a.md"), 1)
        f.model.editor.updateFrontmatter(f.p("a.md"), "title: Changed")
        f.model.settingsDidChange()
        XCTAssertEqual(f.model.recentFilesStore.load(), [])
        XCTAssertEqual(f.model.recentWorkspacesStore.load(), [])

        let app = AppDelegate(dataDir: f.model.dataDir, launchPaths: [], offscreen: true)
        app.startup()
        await app.waitForPendingOpens()
        defer { for c in app.windows { c.window?.close() } }
        let welcome = try XCTUnwrap(app.windows.first)
        XCTAssertNil(welcome.model.root, "cleared folders are not restored at launch")
        XCTAssertFalse(welcome.root.welcome.hasRecentItems)
        XCTAssertNotNil(f.model.sessionStore.load(root: f.root))
        try await f.model.editor.openFileInTabOrFocus(f.p("b.md"))
        XCTAssertEqual(f.model.recentFilesStore.load().map(\.path), [f.p("b.md")])
    }

    func testExplicitlyReopeningActiveFileRecordsItAfterClear() async throws {
        let f = ShellFixture(files: ["a.md": "# A"])
        let app = welcomeApp(f)
        defer { for c in app.windows { c.window?.close() } }
        app.windows[0].model.watcherEnabled = false
        app.openWorkspaceWindow(f.root, file: f.p("a.md"), keepSession: false)
        await app.waitForPendingOpens()
        SettingsBackend(dataDir: f.model.dataDir).clearRecentHistory()
        app.open(paths: [f.p("a.md")])
        await app.waitForPendingOpens()
        XCTAssertEqual(f.model.recentFilesStore.load().map(\.path), [f.p("a.md")])
        XCTAssertEqual(f.model.recentWorkspacesStore.load(), [f.root])
        XCTAssertEqual(app.windows.count, 1)
    }

    func testHistoryWriteFailureDoesNotPreventOpening() async throws {
        let f = ShellFixture(files: ["a.md": "# A"])
        try FileManager.default.createDirectory(at: f.model.dataDir.recentFilesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: f.model.dataDir.recentWorkspacesURL, withIntermediateDirectories: true)
        await f.open(file: "a.md")
        XCTAssertEqual(f.model.root, f.root)
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("a.md"))
        XCTAssertEqual(f.alerts.count, 2)
        XCTAssertTrue(f.alerts.allSatisfy { $0.hasPrefix("Failed to save recent history:") })
    }

    func testReadOnlyModelsDoNotRecordHistory() async {
        let f = ShellFixture(files: ["a.md": "# A"])
        f.model.readOnly = true
        await f.open(file: "a.md")
        XCTAssertEqual(f.model.recentFilesStore.load(), [])
        XCTAssertEqual(f.model.recentWorkspacesStore.load(), [])
    }

    func testLongRecentListsScrollAndFitNarrowWindows() throws {
        let f = ShellFixture()
        for i in 0..<35 {
            let path = f.p("folder-\(i)/note.md")
            TFS.write(path, "note")
            try f.model.recentFilesStore.record(path)
            try f.model.recentWorkspacesStore.record(f.p("folder-\(i)"))
        }
        for size in [NSSize(width: 1200, height: 800), NSSize(width: 400, height: 500)] {
            let c = ShellWindowController(model: f.model, frame: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size), offscreen: true)
            defer { c.window?.close() }
            c.flush()
            c.root.layoutSubtreeIfNeeded()
            let v = c.root.welcome
            XCTAssertEqual(v.folders.rows.count, 10)
            XCTAssertEqual(v.files.rows.count, 30)
            XCTAssertFalse(v.folders.frame.intersects(v.files.frame))
            for section in [v.folders, v.files] {
                XCTAssertTrue(v.bounds.contains(section.frame))
                XCTAssertGreaterThan(section.frame.minY, v.buttons.map { $0.1.maxY }.max()!)
                XCTAssertGreaterThan(section.scroll.contentSize.height, 0)
                XCTAssertGreaterThan(section.document.frame.height, section.scroll.contentSize.height)
                XCTAssertTrue(section.rows.allSatisfy { $0.frame.width <= section.scroll.contentSize.width },
                              "rows \(section.rows.map { $0.frame.width }) must fit viewport \(section.scroll.contentSize) at \(size)")
                let last = try XCTUnwrap(section.rows.last)
                XCTAssertTrue(c.window?.makeFirstResponder(last) == true)
                XCTAssertTrue(section.document.visibleRect.intersects(last.frame), "keyboard focus scrolls the selected recent item into view")
            }
        }
    }
}
