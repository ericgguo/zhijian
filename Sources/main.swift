import AppKit
import UniformTypeIdentifiers

struct Piece: Codable {
    var id: UUID
    var title: String
    var body: String
    var modified: Date
    var richText: Data? = nil
    var label: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名" : title }
}

enum Palette {
    static func color(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
    static let ink = color("ink", light: NSColor(calibratedRed: 0.22, green: 0.235, blue: 0.22, alpha: 1), dark: NSColor(calibratedRed: 0.85, green: 0.835, blue: 0.79, alpha: 1))
    static let desk = color("desk", light: NSColor(calibratedRed: 0.88, green: 0.865, blue: 0.83, alpha: 1), dark: NSColor(calibratedRed: 0.095, green: 0.105, blue: 0.105, alpha: 1))
    static let paper = color("paper", light: NSColor(calibratedRed: 0.961, green: 0.942, blue: 0.90, alpha: 1), dark: NSColor(calibratedRed: 0.145, green: 0.155, blue: 0.15, alpha: 1))
}

func bodyParagraph(size: CGFloat) -> NSParagraphStyle {
    let p = NSMutableParagraphStyle()
    p.lineSpacing = size * 0.4
    p.paragraphSpacing = size * 0.85
    p.firstLineHeadIndent = size * 2
    p.headIndent = 0
    return p
}

func paragraphAttributes(heading: Bool, scale: CGFloat = 1, printing: Bool = false) -> [NSAttributedString.Key: Any] {
    let size: CGFloat = (heading ? 24 : 20) * scale
    var font = NSFont(name: "Songti SC", size: size) ?? NSFont.systemFont(ofSize: size)
    let p = (bodyParagraph(size: 20 * scale).mutableCopy() as! NSMutableParagraphStyle)
    if heading {
        font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        p.firstLineHeadIndent = 0; p.paragraphSpacingBefore = 16 * scale; p.paragraphSpacing = 12 * scale
    }
    return [.font: font, .paragraphStyle: p, .foregroundColor: printing ? NSColor.black : Palette.ink]
}

final class WritingView: NSTextView {
    var paragraphChanged: (() -> Void)?
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
    override func insertNewline(_ sender: Any?) {
        let composing = hasMarkedText()
        // Force the new paragraph to inherit body style, not the previous heading.
        let body = paragraphAttributes(heading: false)
        typingAttributes = body
        super.insertNewline(sender)
        guard !composing else { return }
        let range = (string as NSString).paragraphRange(for: selectedRange())
        if range.length > 0 { textStorage?.setAttributes(body, range: range) }
        typingAttributes = body
        paragraphChanged?()
    }
}

final class Paper: NSView {
    // A fixed, seamless grain tile: no external assets or per-keystroke noise generation.
    private static let grain: NSColor = {
        let side = 256
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32)!
        var seed: UInt32 = 42791
        let data = bitmap.bitmapData!
        for i in 0..<(side * side) {
            seed = seed &* 1664525 &+ 1013904223
            let light = (seed >> 23) & 1 == 0
            let alpha = UInt8(10 + ((seed >> 25) % 17))
            let value: UInt8 = light ? alpha : 0
            data[i*4] = value; data[i*4+1] = value; data[i*4+2] = value
            data[i*4+3] = alpha
        }
        let image = NSImage(size: NSSize(width: side, height: side)); image.addRepresentation(bitmap)
        return NSColor(patternImage: image)
    }()
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        window?.backgroundColor = Palette.desk
    }
    override func draw(_ dirtyRect: NSRect) {
        let region = dirtyRect.intersection(bounds)
        Palette.paper.setFill(); region.fill()
        Self.grain.setFill(); region.fill(using: .sourceOver)
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSColor(calibratedWhite: dark ? 1 : 0, alpha: dark ? 0.018 : 0.023).setStroke()
        let fibers = NSBezierPath(); fibers.lineWidth = 0.5
        for y in stride(from: 3, to: Int(bounds.height), by: 4) {
            fibers.move(to: NSPoint(x: 0, y: y)); fibers.line(to: NSPoint(x: bounds.width, y: CGFloat(y)))
        }
        fibers.stroke()
        NSColor(calibratedWhite: dark ? 1 : 0, alpha: 0.13).setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}

final class App: NSObject, NSApplicationDelegate, NSTextViewDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    var window: NSWindow!
    let titleField = NSTextField()
    let editor = WritingView(frame: NSRect(x: 0, y: 0, width: 660, height: 420))
    let table = NSTableView()
    let sidebar = NSView()
    let status = NSTextField(labelWithString: "")
    let formatChoice = NSPopUpButton(frame: .zero, pullsDown: false)
    let readButton = NSButton(title: "阅读", target: nil, action: nil)
    let content = NSView()
    var sidebarWidth: NSLayoutConstraint!
    var pieces: [Piece] = []
    var active = UUID()
    var loading = false
    var reading = false
    var dirty = false
    var saveTimer: Timer?
    var storageReady = true
    let ink = Palette.ink
    var appearanceItems: [NSMenuItem] = []
    let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Zhijian", isDirectory: true)
    var currentIndex: Int? { pieces.firstIndex { $0.id == active } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadPieces()
        buildMenu()
        buildWindow()
        if pieces.isEmpty { pieces = [Piece(id: UUID(), title: "", body: "", modified: Date())] }
        active = pieces.first!.id
        if let saved = UserDefaults.standard.string(forKey: "lastPiece"), let id = UUID(uuidString: saved), pieces.contains(where: {$0.id == id}) { active = id }
        showCurrent()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(editor)
        if !storageReady { alert("无法读取存储文件夹", "暂时无法自动保存。请先导出文字，检查本机存储权限后重新打开。") }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { save() ? .terminateNow : .terminateCancel }
    func windowShouldClose(_ sender: NSWindow) -> Bool { save() }

    func loadPieces() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter {$0.pathExtension == "json"}
            var failed = 0
            for file in files {
                do { pieces.append(try JSONDecoder().decode(Piece.self, from: Data(contentsOf: file))) }
                catch { failed += 1 }
            }
            pieces.sort {$0.modified > $1.modified}
            if failed > 0 { DispatchQueue.main.async { self.alert("有 \(failed) 篇文章暂时无法读取", "原文件仍保留在存储文件夹中，没有被修改。可从“文件”菜单打开存储文件夹。") } }
        } catch { storageReady = false }
    }
    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于纸间", action: #selector(about), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出纸间", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenuItem(); main.addItem(file); file.submenu = NSMenu(title: "文件")
        addMenu(file.submenu!, "新建短文", #selector(newPiece), "n")
        addMenu(file.submenu!, "保存", #selector(saveAction), "s")
        addMenu(file.submenu!, "导出纯文本…", #selector(exportText), "e", [.command, .shift])
        addMenu(file.submenu!, "导出 PDF…", #selector(exportPDF), "p", [.command, .shift])
        addMenu(file.submenu!, "打开存储文件夹", #selector(revealStorage), "")
        let edit = NSMenuItem(); main.addItem(edit); edit.submenu = NSMenu(title: "编辑")
        for (name, selector, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "Z"), ("剪切", "cut:", "x"), ("拷贝", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.submenu!.addItem(withTitle: name, action: Selector(selector), keyEquivalent: key)
        }
        let view = NSMenuItem(); main.addItem(view); view.submenu = NSMenu(title: "显示")
        addMenu(view.submenu!, "显示／收起文章", #selector(toggleLibrary), "l", [.command, .shift])
        addMenu(view.submenu!, "阅读／编辑", #selector(toggleReading), "r", [.command, .shift])
        view.submenu!.addItem(.separator())
        for (index, name) in ["跟随系统", "浅色纸张", "深色纸张"].enumerated() {
            let item = NSMenuItem(title: name, action: #selector(changeAppearance(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; appearanceItems.append(item); view.submenu!.addItem(item)
        }
        addMenu(view.submenu!, "设为小标题", #selector(makeHeading), "2", [.command, .option])
        addMenu(view.submenu!, "设为正文", #selector(makeBody), "0", [.command, .option])
        NSApp.mainMenu = main
    }
    @objc func changeAppearance(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "paperAppearance")
        applyAppearance(sender.tag)
    }
    func applyAppearance(_ mode: Int) {
        window.appearance = mode == 1 ? NSAppearance(named: .aqua) : mode == 2 ? NSAppearance(named: .darkAqua) : nil
        window.backgroundColor = Palette.desk
        appearanceItems.forEach { $0.state = $0.tag == mode ? .on : .off }
        window.contentView?.needsDisplay = true
    }
    func styleBody() {
        guard !editor.hasMarkedText(), let storage = editor.textStorage else { return }
        let typing = editor.typingAttributes
        var runs: [(NSRange, Bool)] = []
        storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            runs.append((range, (value as? NSFont)?.pointSize ?? 20 >= 23))
        }
        storage.beginEditing()
        for (range, heading) in runs { storage.setAttributes(paragraphAttributes(heading: heading), range: range) }
        storage.endEditing()
        editor.defaultParagraphStyle = bodyParagraph(size: 20)
        editor.typingAttributes = paragraphAttributes(heading: (typing[.font] as? NSFont)?.pointSize ?? 20 >= 23)
        updateFormatChoice()
    }
    func updateFormatChoice() {
        let size = (editor.typingAttributes[.font] as? NSFont)?.pointSize ?? 20
        formatChoice.selectItem(at: size >= 23 ? 1 : 0)
    }
    func textViewDidChangeSelection(_ notification: Notification) { if !loading { updateFormatChoice() } }
    @objc func makeHeading() { setParagraphStyle(heading: true) }
    @objc func makeBody() { setParagraphStyle(heading: false) }
    @objc func chooseFormat() { setParagraphStyle(heading: formatChoice.indexOfSelectedItem == 1) }
    func replaceStyle(_ range: NSRange, with value: NSAttributedString) {
        guard let storage = editor.textStorage, NSMaxRange(range) <= storage.length else { return }
        let previous = storage.attributedSubstring(from: range)
        editor.undoManager?.registerUndo(withTarget: self) { $0.replaceStyle(range, with: previous) }
        storage.replaceCharacters(in: range, with: value)
        editor.typingAttributes = range.length > 0 ? value.attributes(at: 0, effectiveRange: nil) : paragraphAttributes(heading: false)
        changed(); updateFormatChoice()
    }
    func setParagraphStyle(heading: Bool) {
        guard !reading else { return }
        window.makeFirstResponder(editor)
        editor.unmarkText()
        let selection = editor.selectedRange()
        let range = (editor.string as NSString).paragraphRange(for: selection)
        let attrs = paragraphAttributes(heading: heading)
        if range.length > 0, let storage = editor.textStorage {
            let text = NSAttributedString(string: (editor.string as NSString).substring(with: range), attributes: attrs)
            _ = storage
            replaceStyle(range, with: text)
            editor.setSelectedRange(selection)
        }
        editor.typingAttributes = attrs
        updateFormatChoice()
    }
    func addMenu(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ flags: NSEvent.ModifierFlags = [.command]) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self; item.keyEquivalentModifierMask = flags
    }
    func button(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .inline; b.isBordered = false; b.font = .systemFont(ofSize: 13)
        b.contentTintColor = ink
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        b.imagePosition = .imageLeading
        return b
    }
    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 990, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "纸间"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.backgroundColor = Palette.desk
        window.minSize = NSSize(width: 620, height: 460); window.center(); window.delegate = self
        window.setFrameAutosaveName("ZhijianWindow")
        applyAppearance(UserDefaults.standard.integer(forKey: "paperAppearance"))
        let root = window.contentView!
        let toolbar = NSView(); toolbar.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(toolbar)
        let left = NSStackView(views: [button("文章", "sidebar.left", #selector(toggleLibrary)), button("新写", "square.and.pencil", #selector(newPiece))])
        left.spacing = 23; left.translatesAutoresizingMaskIntoConstraints = false; toolbar.addSubview(left)
        let mark = NSTextField(labelWithString: "纸 间"); mark.font = .systemFont(ofSize: 13, weight: .medium); mark.textColor = ink.withAlphaComponent(0.6)
        mark.translatesAutoresizingMaskIntoConstraints = false; toolbar.addSubview(mark)
        readButton.target = self; readButton.action = #selector(toggleReading); readButton.bezelStyle = .inline; readButton.isBordered = false; readButton.font = .systemFont(ofSize: 13); readButton.contentTintColor = ink
        formatChoice.addItems(withTitles: ["正文", "小标题"])
        formatChoice.isBordered = false; formatChoice.font = .systemFont(ofSize: 13)
        formatChoice.target = self; formatChoice.action = #selector(chooseFormat)
        formatChoice.toolTip = "设置当前段落：正文或小标题"
        let right = NSStackView(views: [formatChoice, readButton, button("导出", "square.and.arrow.up", #selector(exportMenu(_:)))])
        right.spacing = 23; right.translatesAutoresizingMaskIntoConstraints = false; toolbar.addSubview(right)
        content.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(content)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 34), toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28), toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28), toolbar.heightAnchor.constraint(equalToConstant: 45),
            left.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor), left.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor), right.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor), right.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor), mark.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor), mark.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            content.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10), content.bottomAnchor.constraint(equalTo: root.bottomAnchor), content.leadingAnchor.constraint(equalTo: root.leadingAnchor), content.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ])
        sidebar.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(sidebar)
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: 0)
        sidebar.isHidden = true
        let listScroll = NSScrollView(); listScroll.translatesAutoresizingMaskIntoConstraints = false; listScroll.drawsBackground = false; listScroll.hasVerticalScroller = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("piece")); column.width = 194; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 64; table.backgroundColor = .clear; table.style = .plain; table.selectionHighlightStyle = .regular; table.delegate = self; table.dataSource = self
        listScroll.documentView = table; sidebar.addSubview(listScroll)
        let delete = button("移到废纸篓", "trash", #selector(deletePiece)); delete.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(delete)
        let paper = Paper(); paper.wantsLayer = true; paper.layer?.masksToBounds = true; paper.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(paper)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor), sidebar.topAnchor.constraint(equalTo: content.topAnchor), sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor), sidebarWidth,
            listScroll.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 12), listScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14), listScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10), listScroll.bottomAnchor.constraint(equalTo: delete.topAnchor, constant: -15),
            delete.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 22), delete.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -24),
            paper.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 20), paper.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), paper.topAnchor.constraint(equalTo: content.topAnchor), paper.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
        let writing = NSView(); writing.translatesAutoresizingMaskIntoConstraints = false; paper.addSubview(writing)
        let maxWidth = writing.widthAnchor.constraint(equalToConstant: 660); maxWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([writing.centerXAnchor.constraint(equalTo: paper.centerXAnchor), writing.widthAnchor.constraint(lessThanOrEqualTo: paper.widthAnchor, constant: -72), maxWidth, writing.topAnchor.constraint(equalTo: paper.topAnchor, constant: 42), writing.bottomAnchor.constraint(equalTo: paper.bottomAnchor, constant: -18)])
        titleField.alignment = .center; titleField.placeholderString = "标题"; titleField.font = NSFont(name: "Songti SC", size: 29) ?? .systemFont(ofSize: 29); titleField.textColor = ink
        titleField.isBordered = false; titleField.drawsBackground = false; titleField.focusRingType = .none; titleField.delegate = self
        titleField.translatesAutoresizingMaskIntoConstraints = false; writing.addSubview(titleField)
        let scroll = NSScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        editor.isRichText = true; editor.importsGraphics = false; editor.allowsUndo = true; editor.isAutomaticQuoteSubstitutionEnabled = true; editor.isAutomaticDashSubstitutionEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.drawsBackground = false; editor.textColor = ink; editor.insertionPointColor = ink
        editor.font = NSFont(name: "Songti SC", size: 20) ?? .systemFont(ofSize: 20)
        styleBody()
        editor.textContainerInset = NSSize(width: 0, height: 5)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false; editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: 420); editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true; editor.textContainer?.lineFragmentPadding = 2
        editor.paragraphChanged = { [weak self] in self?.changed(); self?.updateFormatChoice() }
        editor.delegate = self; scroll.documentView = editor; writing.addSubview(scroll)
        status.font = .systemFont(ofSize: 12); status.textColor = ink.withAlphaComponent(0.55); status.translatesAutoresizingMaskIntoConstraints = false; writing.addSubview(status)
        NSLayoutConstraint.activate([
            titleField.topAnchor.constraint(equalTo: writing.topAnchor), titleField.leadingAnchor.constraint(equalTo: writing.leadingAnchor), titleField.trailingAnchor.constraint(equalTo: writing.trailingAnchor), titleField.heightAnchor.constraint(equalToConstant: 42),
            scroll.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 25), scroll.leadingAnchor.constraint(equalTo: writing.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: writing.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -18),
            status.leadingAnchor.constraint(equalTo: writing.leadingAnchor), status.bottomAnchor.constraint(equalTo: writing.bottomAnchor)
        ])
    }
    func numberOfRows(in tableView: NSTableView) -> Int { pieces.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSView()
        let title = NSTextField(labelWithString: pieces[row].label); title.font = .systemFont(ofSize: 14); title.lineBreakMode = .byTruncatingTail
        let date = NSTextField(labelWithString: pieces[row].modified.formatted(.dateTime.month().day())); date.font = .systemFont(ofSize: 11); date.textColor = .secondaryLabelColor
        for v in [title, date] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
        NSLayoutConstraint.activate([title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 9), title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 11), date.leadingAnchor.constraint(equalTo: title.leadingAnchor), date.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !loading, table.selectedRow >= 0, table.selectedRow < pieces.count else { return }
        let next = pieces[table.selectedRow].id
        guard next != active else { return }
        if save() { active = next; showCurrent() } else { selectRow() }
    }
    func selectRow() {
        loading = true
        if let index = currentIndex { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        loading = false
    }
    func showCurrent() {
        guard let index = currentIndex else { return }
        loading = true; titleField.stringValue = pieces[index].title; editor.string = pieces[index].body
        if let data = pieces[index].richText, let restored = NSAttributedString(rtf: data, documentAttributes: nil), restored.string == pieces[index].body { editor.textStorage?.setAttributedString(restored) }
        else { editor.textStorage?.setAttributes(paragraphAttributes(heading: false), range: NSRange(location: 0, length: (editor.string as NSString).length)) }
        editor.typingAttributes = paragraphAttributes(heading: false)
        styleBody(); editor.undoManager?.removeAllActions(); editor.scrollToBeginningOfDocument(nil)
        dirty = false; table.reloadData(); loading = false; selectRow(); updateStatus()
        UserDefaults.standard.set(active.uuidString, forKey: "lastPiece")
        window.title = pieces[index].label + " — 纸间"
    }
    func textDidChange(_ notification: Notification) { styleBody(); changed() }
    func controlTextDidChange(_ obj: Notification) { changed() }
    func changed() {
        guard !loading, let index = currentIndex else { return }
        pieces[index].title = titleField.stringValue; pieces[index].body = editor.string; pieces[index].richText = editor.rtf(from: NSRange(location: 0, length: (editor.string as NSString).length)); pieces[index].modified = Date()
        dirty = true; updateStatus(); saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in _ = self?.save() }
    }
    func updateStatus(_ failure: Bool = false) {
        let count = editor.string.filter { !$0.isWhitespace }.count
        status.stringValue = "\(count) 字   ·   " + (failure ? "保存失败，请导出备份" : dirty ? "保存中…" : "已保存在本机")
    }
    @discardableResult func save() -> Bool {
        saveTimer?.invalidate()
        guard dirty, let index = currentIndex else { return true }
        do {
            guard storageReady else { throw NSError(domain: "Zhijian", code: 1, userInfo: [NSLocalizedDescriptionKey: "存储文件夹不可用"]) }
            let data = try JSONEncoder().encode(pieces[index])
            try data.write(to: folder.appendingPathComponent(active.uuidString + ".json"), options: .atomic)
            dirty = false; updateStatus(); table.reloadData(); selectRow()
            return true
        } catch {
            updateStatus(true)
            alert("文字还在窗口中，但未能保存", "请导出一份纯文本备份。\n\n" + error.localizedDescription)
            return false
        }
    }
    @objc func saveAction() { _ = save() }
    @objc func newPiece() {
        guard save() else { return }
        if let i = currentIndex, pieces[i].title.isEmpty, pieces[i].body.isEmpty { window.makeFirstResponder(editor); return }
        let piece = Piece(id: UUID(), title: "", body: "", modified: Date()); pieces.insert(piece, at: 0); active = piece.id
        showCurrent(); if reading { toggleReading() }; window.makeFirstResponder(editor)
    }
    @objc func toggleLibrary() { sidebar.isHidden.toggle(); sidebarWidth.constant = sidebar.isHidden ? 0 : 220 }
    @objc func toggleReading() {
        reading.toggle(); formatChoice.isHidden = reading; editor.isEditable = !reading; titleField.isEditable = !reading
        readButton.title = reading ? "继续写" : "阅读"
        if reading { _ = save(); window.makeFirstResponder(nil) } else { window.makeFirstResponder(editor) }
    }
    @objc func deletePiece() {
        guard let index = currentIndex else { return }
        let confirm = NSAlert(); confirm.messageText = "将“\(pieces[index].label)”移到废纸篓？"; confirm.informativeText = "文件可从 Mac 废纸篓中找回。"; confirm.addButton(withTitle: "取消"); confirm.addButton(withTitle: "移到废纸篓")
        guard confirm.runModal() == .alertSecondButtonReturn, save() else { return }
        do {
            let file = folder.appendingPathComponent(active.uuidString + ".json")
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.trashItem(at: file, resultingItemURL: nil) }
            pieces.remove(at: index)
            if pieces.isEmpty { pieces.append(Piece(id: UUID(), title: "", body: "", modified: Date())) }
            active = pieces[min(index, pieces.count - 1)].id; showCurrent()
        } catch { alert("未能移到废纸篓", error.localizedDescription) }
    }
    @objc func exportMenu(_ sender: NSButton) {
        let menu = NSMenu(); addMenu(menu, "纯文本 (.txt)", #selector(exportText), ""); addMenu(menu, "PDF (.pdf)", #selector(exportPDF), "")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY - 5), in: sender)
    }
    func filename() -> String { (currentIndex.map { pieces[$0].label } ?? "未命名").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") }
    func exportContent() -> String { titleField.stringValue.isEmpty ? editor.string : titleField.stringValue + "\n\n" + editor.string }
    @objc func exportText() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = filename() + ".txt"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try self.exportContent().write(to: url, atomically: true, encoding: .utf8) } catch { self.alert("导出失败", error.localizedDescription) }
        }
    }
    func printDocument() -> NSAttributedString {
        let body = NSMutableAttributedString(attributedString: editor.attributedString())
        var runs: [(NSRange, Bool)] = []
        body.enumerateAttribute(.font, in: NSRange(location: 0, length: body.length)) { value, range, _ in
            runs.append((range, (value as? NSFont)?.pointSize ?? 20 >= 23))
        }
        for (range, heading) in runs { body.setAttributes(paragraphAttributes(heading: heading, scale: 0.65, printing: true), range: range) }
        let document = NSMutableAttributedString(string: "")
        if !titleField.stringValue.isEmpty {
            let titleStyle = NSMutableParagraphStyle(); titleStyle.alignment = .center; titleStyle.paragraphSpacing = 20
            document.append(NSAttributedString(string: titleField.stringValue + "\n\n", attributes: [.font: NSFont(name: "Songti SC", size: 22) ?? NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black, .paragraphStyle: titleStyle]))
        }
        document.append(body)
        return document
    }
    @objc func exportPDF() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = filename() + ".pdf"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let printInfo = NSPrintInfo()
            printInfo.paperSize = NSSize(width: 595.28, height: 841.89)
            printInfo.topMargin = 56; printInfo.bottomMargin = 56; printInfo.leftMargin = 56; printInfo.rightMargin = 56
            printInfo.isHorizontallyCentered = false; printInfo.isVerticallyCentered = false
            printInfo.jobDisposition = .save
            printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 483.28, height: 729.89))
            text.isRichText = true; text.textContainerInset = .zero; text.textContainer?.lineFragmentPadding = 0
            let document = self.printDocument()
            text.textStorage?.setAttributedString(document)
            text.isVerticallyResizable = true; text.maxSize = NSSize(width: 483.28, height: .greatestFiniteMagnitude)
            text.textContainer?.containerSize = NSSize(width: 483.28, height: .greatestFiniteMagnitude)
            text.layoutManager?.ensureLayout(for: text.textContainer!)
            let height = text.layoutManager!.usedRect(for: text.textContainer!).height
            text.setFrameSize(NSSize(width: 483.28, height: max(729.89, height + 20)))
            let operation = NSPrintOperation(view: text, printInfo: printInfo); operation.showsPrintPanel = false; operation.showsProgressPanel = false
            if !operation.run() { self.alert("PDF 导出未完成", "请重新选择保存位置再试一次。") }
        }
    }
    @objc func revealStorage() { NSWorkspace.shared.open(folder) }
    @objc func about() { alert("纸间", "一张纸，一些文字。\n\n文章自动保存在本机。") }
    func alert(_ title: String, _ detail: String) { let a = NSAlert(); a.messageText = title; a.informativeText = detail; a.addButton(withTitle: "好"); a.runModal() }
}
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = App()
application.delegate = delegate
application.run()
