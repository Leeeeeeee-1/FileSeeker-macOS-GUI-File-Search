import AppKit
import ServiceManagement
import SQLite3
import Foundation

// MARK: - 数据模型

struct FileRecord {
    let path: String
    let name: String
    let ext: String
    let kind: String
    let size: Int64
    let birth: Double
    let mtime: Double
}

struct Filters {
    var name: String = ""
    var kind: String = "全部"
    var exts: [String] = []
    var minSize: Int64 = 0
    var birthFrom: Double? = nil
    var birthTo: Double? = nil
    var mtimeFrom: Double? = nil
    var mtimeTo: Double? = nil
    var sortColumn: String = "birth"
    var ascending: Bool = false
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func cstr(_ s: String) -> UnsafePointer<CChar>? { (s as NSString).utf8String }

private func colS(_ st: OpaquePointer?, _ i: Int32) -> String {
    guard let p = sqlite3_column_text(st, i) else { return "" }
    return String(cString: UnsafeRawPointer(p).assumingMemoryBound(to: CChar.self))
}

private let kindMap: [String: String] = {
    var m: [String: String] = [:]
    func add(_ kind: String, _ list: String) {
        list.split(separator: " ").forEach { m[String($0)] = kind }
    }
    add("文档", "doc docx wps pdf rtf txt md pages xls xlsx csv numbers et ppt pptx dps key epub mobi odt ods odp")
    add("图片", "jpg jpeg png gif bmp tiff tif heic webp svg psd ai ico avif")
    add("视频", "mp4 mov mkv avi wmv flv webm m4v mpg mpeg ts rmvb")
    add("音频", "mp3 wav aac flac m4a ogg aiff wma opus")
    add("压缩包", "zip rar 7z tar gz bz2 xz dmg iso tgz")
    add("代码", "swift py js ts java c cpp h hpp go rb php html htm css json xml sh rs kt sql yaml yml toml vue jsx tsx ipynb")
    add("字体", "ttf otf woff woff2 ttc")
    return m
}()

// MARK: - 索引引擎

final class IndexEngine {
    let dbPath: String
    private var db: OpaquePointer?
    private let lock = NSLock()
    private(set) var isScanning = false

    init() {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FileSeeker", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("index.db").path
        sqlite3_open(dbPath, &db)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;", nil, nil, nil)
        sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS files(
          path TEXT PRIMARY KEY, name TEXT, ext TEXT, kind TEXT,
          size INTEGER, birth REAL, mtime REAL, isdir INTEGER, name_lc TEXT);
        CREATE INDEX IF NOT EXISTS idx_name  ON files(name);
        CREATE INDEX IF NOT EXISTS idx_ext   ON files(ext);
        CREATE INDEX IF NOT EXISTS idx_kind  ON files(kind);
        CREATE INDEX IF NOT EXISTS idx_birth ON files(birth);
        CREATE INDEX IF NOT EXISTS idx_mtime ON files(mtime);
        CREATE INDEX IF NOT EXISTS idx_size  ON files(size);
        """, nil, nil, nil)
        // 兼容旧库：补 name_lc 小写冗余列。
        // 直接对 name 做 COLLATE NOCASE LIKE 会在 95 万行上逐字符折叠，单次 600~1500ms；
        // 预存小写后用 BINARY LIKE 只需 ~60ms。
        var hasNameLC = false
        var info: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(files);", -1, &info, nil) == SQLITE_OK {
            while sqlite3_step(info) == SQLITE_ROW {
                if let p = sqlite3_column_text(info, 1), String(cString: p) == "name_lc" {
                    hasNameLC = true
                }
            }
            sqlite3_finalize(info)
        }
        if !hasNameLC {
            sqlite3_exec(db, "ALTER TABLE files ADD COLUMN name_lc TEXT;", nil, nil, nil)
        }
        sqlite3_exec(db, "UPDATE files SET name_lc = lower(name) WHERE name_lc IS NULL;", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_nlc ON files(name_lc);", nil, nil, nil)
    }

    func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM files;", -1, &st, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : 0
    }

    private func shouldSkip(_ path: String) -> Bool {
        let prefixes = ["/System/", "/private/", "/dev/", "/usr/", "/bin/", "/sbin/", "/Volumes/", "/opt/", "/.Volumes/"]
        return prefixes.contains { path.hasPrefix($0) }
    }

    func scan(root: URL, progress: @escaping (Int) -> Void,
              done: @escaping (Int, String?) -> Void) {
        guard !isScanning else { done(0, "正在扫描中"); return }
        isScanning = true

        DispatchQueue.global(qos: .userInitiated).async {
            guard let db = self.db else {
                DispatchQueue.main.async { self.isScanning = false; done(0, "数据库未打开") }
                return
            }
            self.lock.lock()
            sqlite3_exec(db, "DELETE FROM files; BEGIN TRANSACTION;", nil, nil, nil)
            var stmt: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO files(path,name,ext,kind,size,birth,mtime,isdir,name_lc) VALUES(?,?,?,?,?,?,?,?,?)"
            let prepOK = sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK
            self.lock.unlock()

            guard prepOK else {
                DispatchQueue.main.async { self.isScanning = false; done(0, "索引准备失败") }
                return
            }

            let keys: [URLResourceKey] = [
                .nameKey, .creationDateKey, .contentModificationDateKey,
                .fileSizeKey, .isDirectoryKey, .isRegularFileKey
            ]
            let fm = FileManager.default
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                         options: [.skipsPackageDescendants],
                                         errorHandler: { _, _ in true }) else {
                sqlite3_finalize(stmt)
                DispatchQueue.main.async { self.isScanning = false; done(0, "无法访问该目录") }
                return
            }

            typealias Row = (String, String, String, String, Int64, Double, Double, Int32)
            var batch: [Row] = []
            var total = 0

            func flush() {
                guard !batch.isEmpty else { return }
                self.lock.lock()
                for r in batch {
                    sqlite3_bind_text(stmt, 1, cstr(r.0), -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 2, cstr(r.1), -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 3, cstr(r.2), -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 4, cstr(r.3), -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int64(stmt, 5, r.4)
                    sqlite3_bind_double(stmt, 6, r.5)
                    sqlite3_bind_double(stmt, 7, r.6)
                    sqlite3_bind_int(stmt, 8, r.7)
                    sqlite3_bind_text(stmt, 9, cstr(r.1.lowercased()), -1, SQLITE_TRANSIENT)
                    sqlite3_step(stmt)
                    sqlite3_reset(stmt)
                }
                sqlite3_exec(db, "COMMIT; BEGIN TRANSACTION;", nil, nil, nil)
                self.lock.unlock()
                batch.removeAll(keepingCapacity: true)
            }

            for case let url as URL in en {
                let path = url.path
                if self.shouldSkip(path) { en.skipDescendants(); continue }
                guard let rv = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                let isDir = rv.isDirectory ?? false
                let isFile = rv.isRegularFile ?? false
                guard isDir || isFile else { continue }

                let name = rv.name ?? url.lastPathComponent
                let ext = url.pathExtension.lowercased()
                let kind = isDir ? "文件夹" : (kindMap[ext] ?? "其他")
                let size = Int64(rv.fileSize ?? 0)
                // macOS 上 creationDate == APFS birth time（真实落盘时间）
                let birth = (rv.creationDate ?? rv.contentModificationDate ?? Date()).timeIntervalSince1970
                let mtime = (rv.contentModificationDate ?? Date()).timeIntervalSince1970

                batch.append((path, name, ext, kind, size, birth, mtime, isDir ? 1 : 0))
                total += 1
                if batch.count >= 1000 {
                    flush()
                    let n = total
                    DispatchQueue.main.async { progress(n) }
                }
            }
            flush()
            self.lock.lock()
            sqlite3_exec(db, "COMMIT;", nil, nil, nil)
            sqlite3_finalize(stmt)
            self.lock.unlock()

            DispatchQueue.main.async {
                self.isScanning = false
                done(total, nil)
            }
        }
    }

    func query(_ f: Filters) -> ([FileRecord], Bool) {
        lock.lock(); defer { lock.unlock() }
        var clauses: [String] = []
        var binds: [String] = []

        if !f.name.isEmpty {
            // 用预存的小写列做 BINARY 匹配，避免 COLLATE NOCASE 逐字符折叠。
            // 参数同样转小写；中文不受影响，英文大小写不敏感。
            clauses.append("name_lc LIKE ?")
            binds.append("%\(f.name.lowercased())%")
        }
        if f.kind != "全部" && !f.kind.isEmpty {
            clauses.append("kind = ?")
            binds.append(f.kind)
        }
        if !f.exts.isEmpty {
            clauses.append("ext IN (\(f.exts.map { _ in "?" }.joined(separator: ",")))")
            binds.append(contentsOf: f.exts)
        }
        if f.minSize > 0 {
            clauses.append("size >= ?")
            binds.append(String(f.minSize))
        }
        if let v = f.birthFrom { clauses.append("birth >= ?"); binds.append(String(v)) }
        if let v = f.birthTo   { clauses.append("birth <= ?"); binds.append(String(v)) }
        if let v = f.mtimeFrom { clauses.append("mtime >= ?"); binds.append(String(v)) }
        if let v = f.mtimeTo   { clauses.append("mtime <= ?"); binds.append(String(v)) }

        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let allowed = ["name", "kind", "size", "birth", "mtime", "path"]
        let col = allowed.contains(f.sortColumn) ? f.sortColumn : "birth"
        let dir = f.ascending ? "ASC" : "DESC"

        // 有文件名关键字时 LIKE 必须全表扫描；若再带 ORDER BY，优化器会误用 idx_birth
        // 逐行回表，实测 600~1500ms。用 NOT INDEXED 顺序扫 + Swift 内存排序降至 ~120ms。
        // 无关键字时可安全走 idx_birth 索引，直接 LIMIT 取最新 20000 条（~30ms）。
        let memSort = !f.name.isEmpty
        let indexHint = memSort ? "NOT INDEXED" : ""
        let orderSQL = memSort ? "" : "ORDER BY \(col) \(dir) LIMIT 20001"
        let sql = "SELECT path,name,ext,kind,size,birth,mtime FROM files \(indexHint) \(whereSQL) \(orderSQL)"

        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return ([], false) }
        defer { sqlite3_finalize(st) }
        for (i, b) in binds.enumerated() {
            sqlite3_bind_text(st, Int32(i + 1), cstr(b), -1, SQLITE_TRANSIENT)
        }

        var rows: [FileRecord] = []
        while sqlite3_step(st) == SQLITE_ROW {
            rows.append(FileRecord(
                path: colS(st, 0), name: colS(st, 1), ext: colS(st, 2), kind: colS(st, 3),
                size: sqlite3_column_int64(st, 4),
                birth: sqlite3_column_double(st, 5),
                mtime: sqlite3_column_double(st, 6)
            ))
        }
        if memSort {
            rows.sort { a, b in
                switch col {
                case "name":  return f.ascending ? a.name < b.name : a.name > b.name
                case "kind":  return f.ascending ? a.kind < b.kind : a.kind > b.kind
                case "size":  return f.ascending ? a.size < b.size : a.size > b.size
                case "mtime": return f.ascending ? a.mtime < b.mtime : a.mtime > b.mtime
                case "path":  return f.ascending ? a.path < b.path : a.path > b.path
                default:      return f.ascending ? a.birth < b.birth : a.birth > b.birth
                }
            }
        }
        let truncated = rows.count > 20000
        if truncated { rows = Array(rows.prefix(20000)) }
        return (rows, truncated)
    }
}

// MARK: - 日期筛选控件

final class DateFilterGroup {
    let popup: NSPopUpButton
    let fromPicker: NSDatePicker
    let toPicker: NSDatePicker
    let label: String

    init(label: String) {
        self.label = label
        popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ["不限", "今天", "昨天", "最近 7 天", "最近 30 天", "最近 90 天", "今年", "自定义区间"])
        popup.selectItem(at: 0)

        fromPicker = NSDatePicker(frame: .zero)
        toPicker = NSDatePicker(frame: .zero)
        for p in [fromPicker, toPicker] {
            p.datePickerStyle = .textField
            p.datePickerElements = [.yearMonthDay]
            p.dateValue = Date()
            p.translatesAutoresizingMaskIntoConstraints = false
        }
        fromPicker.dateValue = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        popup.translatesAutoresizingMaskIntoConstraints = false
    }

    func range() -> (Double?, Double?)? {
        let title = popup.titleOfSelectedItem ?? "不限"
        let cal = Calendar.current
        let now = Date()
        switch title {
        case "不限": return nil
        case "自定义区间":
            let f = fromPicker.dateValue.timeIntervalSince1970
            let next = cal.date(byAdding: .day, value: 1, to: toPicker.dateValue) ?? toPicker.dateValue
            return (f, next.timeIntervalSince1970)
        default:
            let fromDate: Date?
            switch title {
            case "今天": fromDate = cal.startOfDay(for: now)
            case "昨天": fromDate = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))
            case "最近 7 天": fromDate = cal.date(byAdding: .day, value: -7, to: now)
            case "最近 30 天": fromDate = cal.date(byAdding: .day, value: -30, to: now)
            case "最近 90 天": fromDate = cal.date(byAdding: .day, value: -90, to: now)
            case "今年": fromDate = cal.date(from: DateComponents(year: cal.component(.year, from: now), month: 1, day: 1))
            default: fromDate = nil
            }
            guard let d = fromDate else { return nil }
            return (d.timeIntervalSince1970, nil)
        }
    }
}

// MARK: - 扩展名勾选面板

// 常用扩展名，按日常办公用途分组。文档类置顶，Word 组含 doc/docx/wps。
// 生僻格式可通过面板里的"手动补充"框自行填写。
private let extGroups: [(String, [String])] = [
    ("Word 文档", ["doc", "docx", "wps"]),
    ("表格", ["xls", "xlsx", "et", "csv"]),
    ("演示文稿", ["ppt", "pptx", "dps"]),
    ("PDF / 文本", ["pdf", "txt", "md", "rtf"]),
    ("图片", ["jpg", "png", "gif", "heic", "webp"]),
    ("视频", ["mp4", "mov", "mkv", "avi"]),
    ("音频", ["mp3", "wav", "m4a", "flac"]),
    ("压缩包", ["zip", "rar", "7z", "dmg"]),
    ("代码", ["py", "js", "html", "json"])
]

final class ExtPickerController: NSViewController {
    private var checkButtons: [NSButton] = []
    private var groupButtons: [(NSButton, [String])] = []
    private var selected: Set<String>
    private var customField: NSTextField!
    var onDone: ((Set<String>) -> Void)?

    init(selected: Set<String>) {
        self.selected = selected
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView()
        root.frame = NSRect(x: 0, y: 0, width: 460, height: 620)

        let title = NSTextField(labelWithString: "常用扩展名（可多选，点组名整组勾选）；其他格式可在下方补充")
        title.font = NSFont.boldSystemFont(ofSize: 12)
        title.frame = NSRect(x: 16, y: 586, width: 428, height: 22)
        root.addSubview(title)

        let scroll = NSScrollView(frame: NSRect(x: 16, y: 72, width: 428, height: 502))
        scroll.hasVerticalScroller = true
        scroll.borderType = .grooveBorder
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 410, height: 100))
        scroll.documentView = doc
        root.addSubview(scroll)

        let colW: CGFloat = 78
        let rowH: CGFloat = 24
        var y: CGFloat = 8
        for (gi, (groupName, exts)) in extGroups.enumerated() {
            // 组名本身做成按钮：点一下整组勾选/取消，不用逐个点
            let h = NSButton(title: groupName + "  ▸", target: self, action: #selector(toggleGroup(_:)))
            h.bezelStyle = .inline
            h.isBordered = false
            h.font = NSFont.boldSystemFont(ofSize: 11)
            h.contentTintColor = .labelColor
            h.alignment = .left
            h.identifier = NSUserInterfaceItemIdentifier("group:\(gi)")
            h.frame = NSRect(x: 6, y: y, width: 390, height: 20)
            doc.addSubview(h)
            groupButtons.append((h, exts))
            y += 21
            for (i, e) in exts.enumerated() {
                let b = NSButton(checkboxWithTitle: e, target: self, action: #selector(toggleExt(_:)))
                b.state = selected.contains(e) ? .on : .off
                b.font = NSFont.systemFont(ofSize: 11)
                b.identifier = NSUserInterfaceItemIdentifier(e)
                b.frame = NSRect(x: 8 + CGFloat(i % 5) * colW,
                                 y: y + CGFloat(i / 5) * rowH,
                                 width: colW - 4, height: rowH)
                doc.addSubview(b)
                checkButtons.append(b)
            }
            y += CGFloat((exts.count + 4) / 5) * rowH + 9
        }
        doc.frame = NSRect(x: 0, y: 0, width: 410, height: y + 8)

        customField = NSTextField(frame: NSRect(x: 16, y: 36, width: 250, height: 24))
        customField.placeholderString = "手动补充：pdf,docx（可选）"
        customField.font = NSFont.systemFont(ofSize: 11)
        root.addSubview(customField)

        let clearBtn = NSButton(title: "清空", target: self, action: #selector(clearAll))
        clearBtn.frame = NSRect(x: 274, y: 34, width: 66, height: 26)
        clearBtn.bezelStyle = .rounded
        root.addSubview(clearBtn)

        let doneBtn = NSButton(title: "完成", target: self, action: #selector(done))
        doneBtn.frame = NSRect(x: 348, y: 34, width: 96, height: 26)
        doneBtn.bezelStyle = .rounded
        doneBtn.keyEquivalent = "\r"
        root.addSubview(doneBtn)

        view = root
    }

    @objc private func toggleGroup(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, id.hasPrefix("group:"),
              let gi = Int(id.dropFirst("group:".count)), gi < extGroups.count else { return }
        let exts = extGroups[gi].1
        let allOn = exts.allSatisfy { selected.contains($0) }
        for e in exts {
            if allOn { selected.remove(e) } else { selected.insert(e) }
        }
        syncChecks()
    }

    private func syncChecks() {
        for b in checkButtons {
            let e = b.identifier?.rawValue ?? ""
            b.state = selected.contains(e) ? .on : .off
        }
    }

    @objc private func toggleExt(_ sender: NSButton) {
        let e = sender.identifier?.rawValue ?? ""
        if sender.state == .on { selected.insert(e) } else { selected.remove(e) }
    }

    @objc private func clearAll() {
        selected.removeAll()
        for b in checkButtons { b.state = .off }
        customField.stringValue = ""
    }

    @objc private func done() {
        var result = selected
        for part in customField.stringValue.split(separator: ",") {
            let t = String(part).trimmingCharacters(in: .whitespaces).lowercased()
            if !t.isEmpty { result.insert(t) }
        }
        // 只回调结果，不在此处关闭窗口/释放 self。
        // 窗口与 vc 由 AppDelegate 长期持有，只在需要时隐藏，
        // 避免 AppKit 在 autorelease pool 排空时释放控件 target 造成 use-after-free。
        onDone?(result)
    }

    // 下次打开时用当前选择刷新各复选框状态（复用 vc，不新建）
    func reset(to set: Set<String>) {
        selected = set
        syncChecks()
        customField.stringValue = ""
    }

    // 自检入口：直接走内部逻辑，不依赖屏幕坐标/辅助功能权限
    func toggleGroupForTest(_ gi: Int) {
        guard gi < extGroups.count else { return }
        let exts = extGroups[gi].1
        let allOn = exts.allSatisfy { selected.contains($0) }
        for e in exts { if allOn { selected.remove(e) } else { selected.insert(e) } }
        syncChecks()
    }
    func doneForTest() { onDone?(selected) }
}

// MARK: - 主界面

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    private let engine = IndexEngine()
    private var records: [FileRecord] = []
    private var truncated = false
    private var currentSort = NSSortDescriptor(key: "birth", ascending: false)

    private var searchField: NSSearchField!
    private var scopePopup: NSPopUpButton!
    private var kindPopup: NSPopUpButton!
    private var extButton: NSButton!
    private var extPanel: NSWindow?
    private var extPickerVC: ExtPickerController?
    private var selectedExts: Set<String> = []
    private var sizePopup: NSPopUpButton!
    private var minSizeField: NSTextField!
    private var maxSizeField: NSTextField!
    private var birthGroup: DateFilterGroup!
    private var mtimeGroup: DateFilterGroup!
    private var statusLabel: NSTextField!
    private var fontSlider: NSSlider!
    private var progressLabel: NSTextField!
    private var tableView: NSTableView!
    private var contextMenu: NSMenu!
    private var mainWindow: NSWindow!
    private var searchSeq = 0     // 搜索序号，防止后台旧结果覆盖新结果
    private var statusItem: NSStatusItem!
    private var windowVisible = true

    private var fontSize: CGFloat {
        get { UserDefaults.standard.object(forKey: "fontSize") as? CGFloat ?? 13 }
        set { UserDefaults.standard.set(newValue, forKey: "fontSize") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusBar()
        buildUI()
        DispatchQueue.global(qos: .utility).async {
            let c = self.engine.count()
            DispatchQueue.main.async {
                self.statusLabel.stringValue = "索引 \(c) 项"
                if c == 0 { self.rescan() }
                else { self.doSearch() }
            }
        }
    }

    // 必须建立主菜单，否则 Cmd+V / Cmd+C / Cmd+A 等标准快捷键不生效
    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 FileSeeker",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "隐藏 FileSeeker",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 FileSeeker",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        editItem.submenu = edit
        let S = NSSelectorFromString
        edit.addItem(withTitle: "撤销", action: S("undo:"), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: S("redo:"), keyEquivalent: "Z")
        edit.addItem(NSMenuItem.separator())
        edit.addItem(withTitle: "剪切", action: S("cut:"), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: S("copy:"), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: S("paste:"), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: S("selectAll:"), keyEquivalent: "a")
        edit.addItem(withTitle: "删除", action: S("delete:"), keyEquivalent: "")
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "视图")
        viewItem.submenu = view
        view.addItem(withTitle: "放大字号", action: #selector(increaseFont), keyEquivalent: "+")
        view.addItem(withTitle: "缩小字号", action: #selector(decreaseFont), keyEquivalent: "-")
        main.addItem(viewItem)

        NSApp.mainMenu = main
    }

    // 菜单栏图标：借 Lokii 的坑位修法——
    // 1) 用 leftMouseDown + rightMouseUp 分流，不用 leftMouseUp（避免高亮卡住）
    // 2) 初始化时绝不设 statusItem.menu（设了会吃掉左键 action）
    // 3) 右键时动态挂菜单，menuDidClose 里清空并取消高亮
    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            if let img = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "文件搜索") {
                img.isTemplate = true
                btn.image = img
            } else {
                btn.title = "🔍"
            }
            btn.target = self
            btn.action = #selector(statusItemClicked)
            btn.sendAction(on: [.leftMouseDown, .rightMouseUp])
            btn.toolTip = "文件搜索 — 左键显示/隐藏，右键菜单"
        }
    }

    @objc private func statusItemClicked() {
        guard let ev = NSApp.currentEvent else { toggleWindowFromStatusBar(); return }
        if ev.type == .rightMouseUp {
            let menu = NSMenu()
            let showItem = NSMenuItem(title: "显示 / 隐藏 文件搜索",
                                      action: #selector(toggleWindowFromStatusBar), keyEquivalent: "")
            showItem.target = self
            menu.addItem(showItem)
            let loginItem = NSMenuItem(title: "开机自启动",
                                       action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            loginItem.target = self
            loginItem.state = launchAtLoginEnabled ? .on : .off
            menu.addItem(loginItem)
            menu.addItem(NSMenuItem.separator())
            let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)
            menu.delegate = self
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
        } else {
            toggleWindowFromStatusBar()
        }
    }

    @objc private func toggleWindowFromStatusBar() {
        guard let w = mainWindow else { return }
        // 用 isVisible + occlusionState 判定，而不是 NSApp.isActive：
        // 点菜单栏图标不会激活 app，失焦后 isActive 会误判为该显示。
        let actuallyVisible = w.isVisible && w.occlusionState.contains(.visible)
        if actuallyVisible {
            w.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.accessory)
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        }
    }

    // 开机自启：用系统原生登录项（SMAppService），无需 LaunchAgent / launchctl。
    // 实测 ad-hoc 签名下 mainApp.status 可正常返回（notFound/enabled）。
    private var launchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled {
                try svc.unregister()
            } else {
                try svc.register()
            }
        } catch {
            NSLog("FileSeeker 开机自启设置失败: \(error.localizedDescription)")
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // 关闭窗口只隐藏，不退出进程（保持菜单栏常驻）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let w = mainWindow { w.makeKeyAndOrderFront(nil) }
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        windowVisible = false
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    // MARK: UI 构建

    private func label(_ text: String) -> NSTextField {
        let t = NSTextField(labelWithString: text)
        t.font = NSFont.systemFont(ofSize: 12)
        t.textColor = .secondaryLabelColor
        t.translatesAutoresizingMaskIntoConstraints = false
        return t
    }

    private func field(_ placeholder: String, width: CGFloat) -> NSTextField {
        let f = NSTextField(frame: .zero)
        f.placeholderString = placeholder
        f.font = NSFont.systemFont(ofSize: 12)
        f.bezelStyle = .roundedBezel
        return f
    }

    private func popup(_ items: [String], width: CGFloat) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: items)
        p.font = NSFont.systemFont(ofSize: 12)
        p.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([p.widthAnchor.constraint(equalToConstant: width)])
        return p
    }

    private func button(_ title: String, action: Selector, width: CGFloat) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.font = NSFont.systemFont(ofSize: 12)
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: width)])
        return b
    }

    private func dateRow(_ group: DateFilterGroup) -> NSStackView {
        let note = label(group.label)
        let dash = label("至")
        let s = NSStackView(views: [note, group.popup, label("从"), group.fromPicker, dash, group.toPicker])
        s.orientation = .horizontal
        s.spacing = 5
        s.alignment = .centerY
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    private func buildUI() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        mainWindow = window
        window.delegate = self
        window.title = "文件搜索 — 图形化筛选与排序"
        window.minSize = NSSize(width: 760, height: 460)
        window.center()

        let root = NSView()
        root.frame = NSRect(x: 0, y: 0, width: 1060, height: 632)
        window.contentView = root

        let topMask: NSView.AutoresizingMask = [.maxYMargin]
        func place(_ v: NSView, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                   mask: NSView.AutoresizingMask = topMask) {
            v.frame = NSRect(x: x, y: y, width: w, height: h)
            v.autoresizingMask = mask
            root.addSubview(v)
        }

        // ---- 第 1 行：文件名 + 范围 ----
        place(label("文件名"), 14, 590, 50, 22)
        searchField = NSSearchField(frame: .zero)
        searchField.placeholderString = "输入文件名关键字，回车搜索"
        searchField.font = NSFont.systemFont(ofSize: 13)
        searchField.target = self
        searchField.action = #selector(doSearch)
        place(searchField, 66, 588, 700, 26, mask: [.maxYMargin, .width])

        scopePopup = popup(["用户目录", "启动磁盘（全部文件）"], width: 180)
        place(scopePopup, 776, 588, 180, 26, mask: [.maxYMargin, .minXMargin])

        // ---- 第 2 行：类型 / 扩展名 / 大小 ----
        place(label("类型"), 14, 552, 34, 22)
        kindPopup = popup(["全部", "文档", "图片", "视频", "音频", "压缩包", "代码", "字体", "其他", "文件夹"], width: 90)
        kindPopup.target = self; kindPopup.action = #selector(doSearch)
        place(kindPopup, 50, 550, 90, 26)

        place(label("扩展名"), 150, 552, 48, 22)
        extButton = NSButton(title: "选择扩展名…", target: self, action: #selector(showExtPicker))
        extButton.bezelStyle = .rounded
        extButton.font = NSFont.systemFont(ofSize: 11)
        place(extButton, 200, 550, 150, 26)

        place(label("大小"), 344, 552, 34, 22)
        sizePopup = popup(["不限大小", "> 1 MB", "> 10 MB", "> 100 MB", "> 1 GB"], width: 110)
        place(sizePopup, 380, 550, 110, 26)

        place(label("区间"), 502, 552, 32, 22)
        minSizeField = field("最小 MB", width: 72)
        place(minSizeField, 536, 550, 72, 26)
        place(label("—"), 612, 552, 14, 22)
        maxSizeField = field("最大 MB", width: 72)
        place(maxSizeField, 630, 550, 72, 26)

        // ---- 第 3 行：落盘时间 / 修改时间 ----
        birthGroup = DateFilterGroup(label: "落盘时间")
        mtimeGroup = DateFilterGroup(label: "修改时间")
        func placeDate(_ g: DateFilterGroup, _ x0: CGFloat) {
            for v in [g.popup, g.fromPicker, g.toPicker] {
                v.translatesAutoresizingMaskIntoConstraints = true
            }
            place(label(g.label), x0, 512, 66, 22)
            place(g.popup, x0 + 68, 510, 105, 26)
            place(label("从"), x0 + 178, 512, 20, 22)
            place(g.fromPicker, x0 + 200, 510, 110, 26)
            place(label("至"), x0 + 314, 512, 18, 22)
            place(g.toPicker, x0 + 334, 510, 110, 26)
        }
        placeDate(birthGroup, 14)
        placeDate(mtimeGroup, 522)

        // ---- 第 4 行：按钮 / 状态 / 字号 ----
        let searchBtn = button("搜索", action: #selector(doSearch), width: 70)
        place(searchBtn, 14, 468, 70, 28)
        let rescanBtn = button("重建索引", action: #selector(rescan), width: 88)
        place(rescanBtn, 92, 468, 88, 28)
        let clearBtn = button("清除条件", action: #selector(clearFilters), width: 82)
        place(clearBtn, 188, 468, 82, 28)

        statusLabel = label("就绪")
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        place(statusLabel, 282, 470, 380, 24, mask: [.maxYMargin, .width])

        progressLabel = label("")
        progressLabel.textColor = .systemBlue
        place(progressLabel, 664, 470, 100, 24, mask: [.maxYMargin, .minXMargin])

        place(label("字号"), 770, 470, 34, 22, mask: [.maxYMargin, .minXMargin])
        fontSlider = NSSlider(frame: .zero)
        fontSlider.minValue = 10
        fontSlider.maxValue = 22
        fontSlider.doubleValue = Double(fontSize)
        fontSlider.target = self
        fontSlider.action = #selector(fontChanged)
        place(fontSlider, 806, 471, 110, 22, mask: [.maxYMargin, .minXMargin])

        // ---- 结果表格 ----
        tableView = NSTableView(frame: .zero)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .inset
        tableView.rowHeight = fontSize + 11
        tableView.intercellSpacing = NSSize(width: 10, height: 3)
        tableView.allowsMultipleSelection = true
        tableView.target = self
        tableView.doubleAction = #selector(openSelected)

        let cols: [(String, String, CGFloat)] = [
            ("name", "名称", 230), ("kind", "类型", 72), ("size", "大小", 88),
            ("birth", "落盘时间", 145), ("mtime", "修改时间", 145), ("path", "路径", 330)
        ]
        for (id, title, w) in cols {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = w
            c.minWidth = 50
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id != "birth")
            tableView.addTableColumn(c)
        }
        tableView.sortDescriptors = [currentSort]

        contextMenu = NSMenu()
        contextMenu.addItem(withTitle: "打开", action: #selector(openSelected), keyEquivalent: "")
        contextMenu.addItem(withTitle: "在 Finder 中显示", action: #selector(revealSelected), keyEquivalent: "")
        contextMenu.addItem(withTitle: "复制完整路径", action: #selector(copyPath), keyEquivalent: "")
        contextMenu.addItem(NSMenuItem.separator())
        contextMenu.addItem(withTitle: "快速查看（选中后按空格）", action: #selector(quickLook), keyEquivalent: "")
        for item in contextMenu.items { item.target = self }
        tableView.menu = contextMenu

        let scroll = NSScrollView(frame: NSRect(x: 14, y: 14, width: 1032, height: 440))
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .grooveBorder
        scroll.autoresizingMask = [.width, .height]
        root.addSubview(scroll)
        tableView.frame = scroll.contentView.bounds

        // accessory = 只在菜单栏显示，不进 Dock、不参与 Cmd+Tab
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        windowVisible = true
    }

    // MARK: 操作

    @objc private func doSearch() {
        searchSeq += 1
        let seq = searchSeq
        var f = Filters()
        f.name = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        f.kind = kindPopup.titleOfSelectedItem ?? "全部"

        f.exts = selectedExts.sorted()

        let presets: [Int64] = [0, 1024 * 1024, 10 * 1024 * 1024, 100 * 1024 * 1024, 1024 * 1024 * 1024]
        var pidx = sizePopup.indexOfSelectedItem
        if pidx < 0 || pidx >= presets.count { pidx = 0 }
        var minBytes = presets[pidx]
        let customMin = Double(minSizeField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        if customMin > 0 { minBytes = Int64(customMin * 1024 * 1024) }
        f.minSize = minBytes

        if let r = birthGroup.range() { f.birthFrom = r.0; f.birthTo = r.1 }
        if let r = mtimeGroup.range() { f.mtimeFrom = r.0; f.mtimeTo = r.1 }

        if let sd = tableView.sortDescriptors.first {
            f.sortColumn = sd.key ?? "birth"
            f.ascending = sd.ascending
            currentSort = sd
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.engine.query(f)
            DispatchQueue.main.async {
                guard seq == self.searchSeq else { return }   // 丢弃过期结果
                self.records = result.0
                self.truncated = result.1
                self.tableView.reloadData()
                let suffix = self.truncated ? "（仅显示前 20000 条，请细化条件）" : ""
                self.statusLabel.stringValue = "找到 \(self.records.count) 项\(suffix)"
            }
        }
    }

    @objc private func rescan() {
        progressLabel.stringValue = "正在扫描…"
        let sidx = scopePopup.indexOfSelectedItem
        let rootPath = (sidx == 0 || sidx < 0) ? NSHomeDirectory() : "/"
        engine.scan(root: URL(fileURLWithPath: rootPath),
                    progress: { [weak self] n in
                        self?.progressLabel.stringValue = "已扫描 \(n) 项…"
                    },
                    done: { [weak self] n, err in
                        guard let self = self else { return }
                        if let e = err {
                            self.statusLabel.stringValue = "索引失败：\(e)"
                            self.progressLabel.stringValue = ""
                        } else {
                            self.statusLabel.stringValue = "索引完成，共 \(n) 项"
                            self.progressLabel.stringValue = ""
                            self.doSearch()
                        }
                    })
    }

    @objc private func clearFilters() {
        searchField.stringValue = ""
        kindPopup.selectItem(at: 0)
        selectedExts.removeAll()
        updateExtButtonTitle()
        sizePopup.selectItem(at: 0)
        minSizeField.stringValue = ""
        maxSizeField.stringValue = ""
        birthGroup.popup.selectItem(at: 0)
        mtimeGroup.popup.selectItem(at: 0)
        doSearch()
    }

    @objc private func increaseFont() {
        fontSlider.doubleValue = min(fontSlider.maxValue, fontSlider.doubleValue + 1)
        fontChanged()
    }

    @objc private func decreaseFont() {
        fontSlider.doubleValue = max(fontSlider.minValue, fontSlider.doubleValue - 1)
        fontChanged()
    }

    @objc private func showExtPicker() {
        // 面板与 vc 只创建一次并长期持有，避免反复创建/释放引发的过度释放竞态
        if extPanel == nil {
            let vc = ExtPickerController(selected: selectedExts)
            vc.onDone = { [weak self] set in
                guard let self = self else { return }
                self.selectedExts = set
                self.updateExtButtonTitle()
                // 只隐藏窗口，不 close、不置 nil；vc/panel 保持存活
                self.extPanel?.orderOut(nil)
                self.doSearch()
            }
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            panel.title = "选择扩展名"
            panel.contentViewController = vc
            panel.center()
            panel.level = .floating
            extPanel = panel
            extPickerVC = vc
        } else {
            extPickerVC?.reset(to: selectedExts)
        }
        NSApp.activate(ignoringOtherApps: true)
        extPanel?.makeKeyAndOrderFront(nil)
    }

    private func updateExtButtonTitle() {
        if selectedExts.isEmpty {
            extButton.title = "选择扩展名…"
        } else if selectedExts.count <= 2 {
            extButton.title = selectedExts.sorted().joined(separator: ",")
        } else {
            extButton.title = "已选 \(selectedExts.count) 种格式"
        }
    }

    @objc private func fontChanged() {
        fontSize = CGFloat(fontSlider.doubleValue)
        tableView.rowHeight = fontSize + 11
        tableView.reloadData()
    }

    private func selectedRecords() -> [FileRecord] {
        tableView.selectedRowIndexes.compactMap { index in
            index < records.count ? records[index] : nil
        }
    }

    @objc private func openSelected() {
        for r in selectedRecords() {
            NSWorkspace.shared.open(URL(fileURLWithPath: r.path))
        }
    }

    @objc private func revealSelected() {
        let urls = selectedRecords().map { URL(fileURLWithPath: $0.path) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    @objc private func copyPath() {
        let text = selectedRecords().map { $0.path }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func quickLook() {
        // 空格键触发系统 Quick Look 由 NSTableView 负责，此处仅占位
    }

    // MARK: 表格数据源

    func numberOfRows(in tableView: NSTableView) -> Int { records.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < records.count else { return nil }
        let r = records[row]
        let id = tableColumn?.identifier.rawValue ?? ""
        let text: String
        switch id {
        case "name": text = r.name
        case "kind": text = r.kind
        case "size": text = formatSize(r.size)
        case "birth": text = formatDate(r.birth)
        case "mtime": text = formatDate(r.mtime)
        case "path": text = (r.path as NSString).deletingLastPathComponent
        default: text = ""
        }

        // 用标准复用队列，避免每次 reloadData 创建上万个 autorelease view
        //（高频创建/释放是 autorelease pool 排空期野指针的常见来源）
        let ident = NSUserInterfaceItemIdentifier("cell.\(id)")
        let cell: NSTextField
        if let reused = tableView.makeView(withIdentifier: ident, owner: self) as? NSTextField {
            cell = reused
        } else {
            let fresh = NSTextField(frame: .zero)
            fresh.identifier = ident
            fresh.isBezeled = false
            fresh.drawsBackground = false
            fresh.isEditable = false
            fresh.isSelectable = false
            fresh.lineBreakMode = .byTruncatingTail
            fresh.cell?.wraps = false
            cell = fresh
        }
        cell.stringValue = text
        cell.font = NSFont.systemFont(ofSize: fontSize)
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        doSearch()
    }

    func menu(for column: NSTableColumn?, row: Int) -> NSMenu? { contextMenu }

    private func formatSize(_ b: Int64) -> String {
        if b >= 1_073_741_824 { return String(format: "%.2f GB", Double(b) / 1_073_741_824) }
        if b >= 1_048_576 { return String(format: "%.1f MB", Double(b) / 1_048_576) }
        if b >= 1024 { return String(format: "%.0f KB", Double(b) / 1024) }
        return "\(b) B"
    }

    private func formatDate(_ t: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}

// MARK: - NSMenuDelegate：右键菜单关闭后清空 menu，恢复左键点击能力并取消高亮
extension AppDelegate: NSMenuDelegate {
    func menuDidClose(_ menu: NSMenu) {
        statusItem?.menu = nil
        statusItem?.button?.highlight(false)
    }
}

// MARK: - 启动

// 自检模式：不进入 GUI 事件循环，直接在进程内验证面板构建、分组勾选与查询逻辑。
// 用 --selftest 触发，仅用于自动化验证，不改变正常启动路径。
if CommandLine.arguments.contains("--selftest") {
    let e = IndexEngine()
    let n = e.count()
    print("SELFTEST index rows=\(n)")
    var f = Filters(); f.name = "产品"
    let (r1, _) = e.query(f)
    print("SELFTEST query '产品'=\(r1.count)")
    f.exts = ["doc","docx","wps"]
    let (r2, _) = e.query(f)
    print("SELFTEST query Word组=\(r2.count)")
    // 面板构建 + 整组勾选 + 完成回调，循环 20 轮，验证无过度释放/崩溃
    for i in 0..<20 {
        let vc = ExtPickerController(selected: [])
        _ = vc.view                       // 触发 loadView，真实构建所有 NSButton
        vc.toggleGroupForTest(0)          // 勾选 Word 组
        vc.doneForTest()                  // 触发完成回调路径
        if i == 19 { print("SELFTEST panel rounds=20 OK") }
    }
    exit(0)
}

let app = NSApplication.shared
// 静态强引用保证 AppDelegate 在整个进程生命周期内存活；
// 顶层 let 在某些优化级别可能被 ARC 提前释放，导致 run loop 期的野指针。
private var sharedDelegate: AppDelegate? = nil
let delegate = AppDelegate()
sharedDelegate = delegate
app.delegate = delegate
withExtendedLifetime(delegate) {
    app.run()
}
