import AppKit
import SwiftUI

enum QuickBookKeys {
    static let all = ["Q", "W", "E", "R"]
    static func key(for code: UInt16) -> String? { [12: "Q", 13: "W", 14: "E", 15: "R"][code] }
}
struct BookGuidePreferences: Codable {
    var completed = false
    var bindings: [String: String] = [:]
}
struct BookRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var currency: Currency
    var original: Bool
}
struct BookManifest: Codable {
    var version = 1
    var books: [BookRecord]
    var selected: UUID
}
struct BookMovement {
    let current: Int64?
    let previous: Int64?
    let points: [Int64]?
    var difference: Int64? {
        guard let current, let previous else { return nil }
        return current - previous
    }
    var percent: Double? {
        guard let previous, previous != 0, let difference else { return nil }
        return Double(difference) / abs(Double(previous)) * 100
    }
    @MainActor static func calculate(_ ledger: Ledger, now: Date = Date(), calendar: Calendar = .current) -> BookMovement {
        let start = calendar.startOfDay(for: now)
        let currency = ledger.preferences.totalCurrency
        let rates = ledger.activeRates
        // Revalue every point with the same rates to measure bookkeeping balance changes.
        let valid = ledger.entries.filter { $0.date <= now }
        let current = Conversion.total(valid, to: currency, rates: rates)
        let previous = Conversion.total(valid.filter { $0.date < start }, to: currency, rates: rates)
        let points = (0..<7).map { index -> Int64? in
            let cutoff = index == 6 ? now : calendar.date(byAdding: .day, value: index - 5, to: start)!.addingTimeInterval(-0.001)
            return Conversion.total(valid.filter { $0.date <= cutoff }, to: currency, rates: rates)
        }
        return BookMovement(current: current, previous: previous, points: points.allSatisfy { $0 != nil } ? points.compactMap { $0 } : nil)
    }
}

@MainActor final class BookLibrary: ObservableObject {
    @Published var records: [BookRecord]
    @Published var active: Ledger
    @Published var selected: UUID
    @Published var showChooser = true
    @Published var error = ""
    @Published var revision = 0
    @Published var showGuide = false
    @Published var guide = BookGuidePreferences()
    private var models: [UUID: Ledger] = [:]
    private(set) var writable = true
    let root: URL
    var manifestFile: URL { root.appendingPathComponent("books.json") }
    var activeName: String { records.first { $0.id == selected }?.name ?? "小账本" }
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LittleLedger")
        let initial = BookRecord(id: UUID(), name: "日常账本", currency: .cny, original: true)
        var manifest = BookManifest(books: [initial], selected: initial.id)
        if FileManager.default.fileExists(atPath: self.root.appendingPathComponent("books.json").path) {
            do {
                let saved = try JSONDecoder().decode(BookManifest.self, from: Data(contentsOf: self.root.appendingPathComponent("books.json")))
                guard saved.version == 1, !saved.books.isEmpty, Set(saved.books.map(\.id)).count == saved.books.count,
                      saved.books.filter(\.original).count == 1, saved.books.contains(where: { $0.id == saved.selected }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                manifest = saved
            } catch {
                writable = false
                self.error = "账本目录读取失败，已保留原文件。请先恢复 books.json。"
            }
        }
        records = manifest.books; selected = manifest.selected
        let record = manifest.books.first { $0.id == manifest.selected }!
        let file = record.original ? self.root.appendingPathComponent("ledger.json") : self.root.appendingPathComponent("books/\(record.id.uuidString)/ledger.json")
        active = Ledger(file: file)
        models[record.id] = active
        if let data = try? Data(contentsOf: self.root.appendingPathComponent("quick-books.json")),
           let saved = try? JSONDecoder().decode(BookGuidePreferences.self, from: data) { guide = saved }
        showGuide = !guide.completed
    }
    func quickBook(_ key: String) -> BookRecord? {
        if let saved = guide.bindings[key] { return records.first { $0.id.uuidString == saved } }
        guard let index = QuickBookKeys.all.firstIndex(of: key), records.indices.contains(index) else { return nil }
        return records[index]
    }
    func keys(for book: BookRecord) -> String {
        QuickBookKeys.all.filter { quickBook($0)?.id == book.id }.joined(separator: "/")
    }
    var shortcutHint: String {
        QuickBookKeys.all.map { $0 + " " + (quickBook($0)?.name ?? "未绑定") }.joined(separator: " · ")
    }
    func saveGuide() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(guide).write(to: root.appendingPathComponent("quick-books.json"), options: .atomic)
        } catch { self.error = "教程设置保存失败：\(error.localizedDescription)" }
    }
    func bind(_ key: String, to id: String) {
        guard QuickBookKeys.all.contains(key), id.isEmpty || records.contains(where: { $0.id.uuidString == id }) else { return }
        guide.bindings[key] = id; saveGuide()
    }
    func completeGuide() { guide.completed = true; saveGuide(); showGuide = false }
    func switchQuickly(_ key: String) {
        guard let book = quickBook(key) else {
            active.message = "\(key) 尚未绑定账本，请在新手教程中设置。"; active.focus += 1; return
        }
        if selected != book.id { choose(book) }
        if selected == book.id {
            active.message = "已切换到\(book.name)（\(key)），回车记入当前账本。"; active.focus += 1
        } else { active.message = error; active.focus += 1 }
    }
    func ledger(for record: BookRecord) -> Ledger {
        if let model = models[record.id] { return model }
        let file = record.original ? root.appendingPathComponent("ledger.json") : root.appendingPathComponent("books/\(record.id.uuidString)/ledger.json")
        let model = Ledger(file: file); models[record.id] = model; return model
    }
    private func save(_ books: [BookRecord], selected: UUID) throws {
        guard writable else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(BookManifest(books: books, selected: selected)).write(to: manifestFile, options: .atomic)
    }
    @discardableResult func create(name: String, currency: Currency) -> Bool {
        guard writable else { error = "账本目录读取失败，请先恢复 books.json。"; return false }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 24 else { error = "请填写 1 至 24 个字的账本名称。"; return false }
        guard !records.contains(where: { $0.name.compare(name, options: [.caseInsensitive]) == .orderedSame }) else { error = "这个账本名称已存在。"; return false }
        let book = BookRecord(id: UUID(), name: name, currency: currency, original: false)
        let folder = root.appendingPathComponent("books/\(book.id.uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode([Entry]()).write(to: folder.appendingPathComponent("ledger.json"), options: .atomic)
            var preferences = active.preferences
            preferences.totalCurrency = currency; preferences.selectedCurrency = currency
            try JSONEncoder().encode(preferences).write(to: folder.appendingPathComponent("settings.json"), options: .atomic)
            try save(records + [book], selected: selected)
            records.append(book); error = ""; return true
        } catch { self.error = "新建失败：\(error.localizedDescription)"; return false }
    }
    func choose(_ record: BookRecord) {
        let target = ledger(for: record)
        guard !target.failed else { error = target.message; return }
        do {
            try save(records, selected: record.id)
            active.persistDraft(); active.persistPreferences()
            active = target; selected = record.id; error = ""; showChooser = false
            Task { await target.refreshRates() }
        } catch { self.error = "切换失败：\(error.localizedDescription)" }
    }
    func openChooser() {
        active.persistDraft(); active.persistPreferences(); revision += 1; showChooser = true
    }
    func refresh() async {
        for book in records {
            await ledger(for: book).refreshRates()
        }
        revision += 1
    }
}

struct BookRootView: View {
    @ObservedObject var library: BookLibrary
    var onSettings: () -> Void
    var onStatistics: () -> Void
    var onSwitch: () -> Void
    var body: some View {
        Group {
            if library.showChooser {
                BookChooserView(library: library, onChoose: { book in onSwitch(); library.choose(book) })
            } else {
                LedgerView(model: library.active, onSettings: onSettings, onStatistics: onStatistics,
                           onBooks: { onSwitch(); library.openChooser() }, bookName: library.activeName,
                           shortcutHint: library.shortcutHint, onGuide: { library.showGuide = true }).id(library.selected)
            }
        }
        .sheet(isPresented: $library.showGuide) { BookGuideView(library: library) }
    }
}
struct BookChooserView: View {
    @ObservedObject var library: BookLibrary
    var onChoose: (BookRecord) -> Void
    @SwiftUI.State private var creating = false
    @SwiftUI.State private var search = ""
    @SwiftUI.State private var sortByGrowth = false
    var visible: [BookRecord] {
        let books = library.records.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        return sortByGrowth ? books.sorted {
            (BookMovement.calculate(library.ledger(for: $0)).percent ?? -Double.infinity) > (BookMovement.calculate(library.ledger(for: $1)).percent ?? -Double.infinity)
        } : books
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                LedgerPageTitle(title: "我的账本", subtitle: "PERSONAL LEDGERS")
                Spacer()
                Button { library.showGuide = true } label: { Label("新手教程", systemImage: "questionmark.circle").font(.system(size: 11)).foregroundStyle(accent) }.buttonStyle(.plain)
                Button { library.error = ""; creating = true } label: { Label("新建账本", systemImage: "plus").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 10).foregroundStyle(.white).background(accent).cornerRadius(3) }.buttonStyle(.plain).disabled(!library.writable)
            }.padding(.bottom, 24)
            LedgerRule(opacity: 0.25)
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("余额一览").font(.system(size: 21, weight: .semibold))
                    Text("今日涨跌 · 对比昨日结束余额").font(.system(size: 11)).foregroundStyle(muted)
                }
                Spacer()
                Text("\(library.records.count) 个账本").font(.system(size: 11)).foregroundStyle(muted)
            }.padding(.vertical, 22)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(muted)
                TextField("搜索账本", text: $search).textFieldStyle(.plain).font(.system(size: 12))
                Spacer()
                Button { sortByGrowth.toggle() } label: { Label(sortByGrowth ? "涨幅排序" : "默认排序", systemImage: "arrow.up.arrow.down").font(.system(size: 11)).foregroundStyle(accent) }.buttonStyle(.plain)
            }.padding(12).background(Color.white.opacity(0.6)).padding(.bottom, 18)
            HStack {
                Text("账本 / 币种"); Spacer(); Text("近 7 天").frame(width: 80); Text("余额").frame(width: 130, alignment: .trailing); Text("今日涨跌").frame(width: 95, alignment: .trailing)
            }.font(.system(size: 10)).foregroundStyle(muted).padding(.bottom, 12)
            LedgerRule()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { book in
                        BookMarketRow(book: book, model: library.ledger(for: book), selected: library.selected == book.id, shortcut: library.keys(for: book)) { onChoose(book) }
                        LedgerRule(opacity: 0.09)
                    }
                    if visible.isEmpty { Text("没有匹配的账本").font(.system(size: 12)).foregroundStyle(muted).padding(30) }
                }
            }
            if !library.error.isEmpty { Text(library.error).font(.system(size: 11)).foregroundStyle(.red).padding(.vertical, 8).textSelection(.enabled) }
            LedgerRule()
            Text("涨跌包含入账与出账。多币种余额按各账本当前汇率折算。")
                .font(.system(size: 10)).foregroundStyle(muted).padding(.top, 14)
            Text("昨日余额为零时显示“暂无基准”。账目保存在本机。")
                .font(.system(size: 10)).foregroundStyle(muted).padding(.top, 6)
        }.padding(30).frame(minWidth: 530, minHeight: 650).background(paper).foregroundStyle(ink).preferredColorScheme(.light)
        .sheet(isPresented: $creating) { NewBookView(library: library, onDone: { creating = false }) }
        .task { await library.refresh() }
    }
}
struct BookMarketRow: View {
    let book: BookRecord
    @ObservedObject var model: Ledger
    let selected: Bool
    var shortcut: String = ""
    var action: () -> Void
    var body: some View {
        let move = BookMovement.calculate(model)
        let currency = model.preferences.totalCurrency
        let color = (move.difference ?? 0) < 0 ? Color(red: 0.77, green: 0.28, blue: 0.27) : Color(red: 0.21, green: 0.52, blue: 0.39)
        Button(action: action) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 5) {
                        Text(book.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        if selected { Circle().fill(accent).frame(width: 5, height: 5) }
                        if !shortcut.isEmpty { Text(shortcut).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(accent).padding(.horizontal, 4).padding(.vertical, 2).background(accent.opacity(0.08)).cornerRadius(2) }
                    }
                    Text(currency.rawValue + " · " + (model.failed ? "读取失败" : "\(model.entries.count) 笔记录")).font(.system(size: 10)).foregroundStyle(model.failed ? .red : muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if let points = move.points, !model.entries.isEmpty { BookSparkline(points: points).stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round)).frame(width: 65, height: 28) }
                    else { Text("暂无走势").font(.system(size: 9)).foregroundStyle(muted) }
                }.frame(width: 80)
                VStack(alignment: .trailing, spacing: 7) {
                    Text(model.failed ? "读取失败" : move.current.map { currency.symbol + Amounts.format($0) } ?? "汇率不完整").font(.system(size: 14, weight: .medium, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.65)
                    Text("\(currency.rawValue) 余额").font(.system(size: 9)).foregroundStyle(muted)
                }.frame(width: 130, alignment: .trailing)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(model.failed ? "不可用" : move.percent.map { String(format: "%+.2f%%", $0) } ?? "暂无基准")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(model.failed || move.percent == nil ? muted : color)
                        .padding(.horizontal, 8).padding(.vertical, 8).background((move.percent == nil ? muted : color).opacity(0.09)).cornerRadius(3)
                    Text(model.failed ? "请恢复数据" : move.difference.map { ($0 >= 0 ? "+" : "−") + Amounts.format(abs($0)) } ?? "暂无数据").font(.system(size: 9, design: .monospaced)).foregroundStyle(muted)
                }.frame(width: 95, alignment: .trailing)
            }.padding(.vertical, 20).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("打开账本 \(book.name)")
    }
}
struct BookSparkline: Shape {
    let points: [Int64]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        let low = Double(points.min()!), high = Double(points.max()!), span = high - low
        for (index, amount) in points.enumerated() {
            let x = rect.minX + Double(index) / Double(points.count - 1) * rect.width
            let y = span == 0 ? rect.midY : rect.maxY - (Double(amount) - low) / span * rect.height
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}
struct NewBookView: View {
    @ObservedObject var library: BookLibrary
    var onDone: () -> Void
    @SwiftUI.State private var name = ""
    @SwiftUI.State private var currency = Currency.cny
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            LedgerPageTitle(title: "新建账本", subtitle: "NEW LEDGER")
            TextField("账本名称，例如旅行、生活", text: $name).textFieldStyle(.roundedBorder).onSubmit(create)
            Picker("余额显示币种", selection: $currency) { ForEach(Currency.allCases) { Text($0.name + " " + $0.rawValue).tag($0) } }
            Text("新账本从零开始，单独保存记录、草稿和设置。每笔记录仍可选择币种。")
                .font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            if !library.error.isEmpty { Text(library.error).font(.system(size: 11)).foregroundStyle(.red) }
            HStack { Spacer(); Button("取消", action: onDone).keyboardShortcut(.cancelAction); Button("创建账本", action: create).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(28).frame(width: 390).background(paper)
    }
    func create() { if library.create(name: name, currency: currency) { onDone() } }
}

@MainActor func booksSelfTest() {
    func expect(_ value: Bool, _ label: String) { if !value { fatalError(label) } }
    do {
        let root = URL(fileURLWithPath: CommandLine.arguments.last!).appendingPathComponent("book-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let calendar = Calendar.current, now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        let original = [Entry(cents: 10000, note: "原始账目", date: yesterday, currency: .cny), Entry(cents: -2500, note: "今日支出", date: now, currency: .cny)]
        let bytes = try JSONEncoder().encode(original)
        try bytes.write(to: root.appendingPathComponent("ledger.json"))
        let library = BookLibrary(root: root)
        expect(library.records.count == 1 && library.active.entries == original, "legacy entries are adopted")
        let move = BookMovement.calculate(library.active, now: now)
        expect(move.current == 7500 && move.previous == 10000 && move.percent == -25 && move.points?.count == 7, "daily growth and seven points")
        expect(library.create(name: "旅行", currency: .usd), "create USD ledger")
        expect(!library.create(name: "旅行", currency: .cny), "reject duplicate")
        expect(!library.create(name: "  ", currency: .cny), "reject blank")
        expect(QuickBookKeys.all.allSatisfy { Currency.shortcut($0) == nil }, "QWER do not conflict with currencies")
        expect([UInt16(12), 13, 14, 15].compactMap { QuickBookKeys.key(for: $0) } == QuickBookKeys.all && QuickBookKeys.key(for: 0) == nil, "physical QWER mapping")
        expect(library.quickBook("Q")?.id == library.records[0].id && library.quickBook("W")?.id == library.records[1].id && library.quickBook("R") == nil, "stable default shortcut order")
        let book = library.records.last!
        library.choose(book)
        expect(library.active.entries.isEmpty && library.active.preferences.totalCurrency == .usd, "new book is empty with chosen currency")
        expect(BookMovement.calculate(library.active).percent == nil, "zero baseline has no percentage")
        library.active.amount = "25"; library.active.mode = 1; library.active.add()
        library.active.note = "独立草稿"; library.active.persistDraft()
        expect(library.active.entries.count == 1, "record in new book")
        library.active.amount = "17"; library.active.note = "独立草稿"
        library.switchQuickly("Q")
        library.switchQuickly("W")
        expect(library.active.amount == "17" && library.active.note == "独立草稿", "quick switching preserves draft")
        library.bind("R", to: book.id.uuidString)
        library.completeGuide()
        library.choose(library.records.first!)
        expect(library.active.entries == original && library.active.note != "独立草稿", "book and draft isolation")
        expect(try Data(contentsOf: root.appendingPathComponent("ledger.json")) == bytes, "legacy bytes untouched")
        let reloaded = BookLibrary(root: root)
        expect(reloaded.records.count == 2, "manifest persists")
        expect(!reloaded.showGuide && reloaded.quickBook("R")?.id == book.id, "guide completion and custom bindings persist")
        reloaded.bind("E", to: "")
        reloaded.switchQuickly("E")
        expect(reloaded.selected == library.records.first!.id, "unbound key does not switch or save entries")
        reloaded.choose(book)
        expect(reloaded.active.entries.count == 1 && reloaded.active.note == "独立草稿", "new book records and draft survive restart")
        reloaded.active.entries = [Entry(cents: -10000, note: "", date: yesterday), Entry(cents: 5000, note: "", date: now)]
        reloaded.active.preferences.totalCurrency = .cny
        expect(BookMovement.calculate(reloaded.active, now: now).percent == 50, "negative baseline improvement")
        reloaded.active.entries = original + [Entry(cents: 100, note: "", date: now, currency: .eur)]
        reloaded.active.preferences.ratesUSD = ["USD": 1]
        expect(BookMovement.calculate(reloaded.active, now: now).current == nil, "missing rates do not become partial balances")
        expect(reloaded.create(name: "公司", currency: .cny) && reloaded.create(name: "其他品类", currency: .cny), "four ledgers available")
        for (key, target) in zip(QuickBookKeys.all, reloaded.records) {
            reloaded.bind(key, to: target.id.uuidString)
            reloaded.switchQuickly(key)
            expect(reloaded.selected == target.id && !reloaded.showChooser, "each QWER slot selects its target")
        }
        try Data("invalid".utf8).write(to: root.appendingPathComponent("books.json"))
        let corrupt = BookLibrary(root: root)
        expect(!corrupt.writable && !corrupt.create(name: "不可覆盖", currency: .cny), "corrupt manifest preserved")
        expect(try String(contentsOf: root.appendingPathComponent("books.json"), encoding: .utf8) == "invalid", "no destructive manifest replacement")
        print("PASS: migration, isolated ledgers, independent drafts/settings, persistence, daily growth, negative/zero baseline, missing FX, corrupt manifest protection")
    } catch { fatalError(error.localizedDescription) }
}

struct BookGuideView: View {
    @ObservedObject var library: BookLibrary
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LedgerPageTitle(title: "新手入门", subtitle: "QUICK START")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    step("1", "先按用途建账本", "在“我的账本”中点“新建账本”。可以建立“公司”“日常支出”“其他品类”和“备用”，每个账本单独保存记录。")
                    LedgerRule()
                    step("2", "设置 Q / W / E / R", "默认按创建顺序对应前 4 个账本。你可以在下方修改，每个按键都能选择已有账本。列表排序不会改变快捷键。")
                    ForEach(QuickBookKeys.all, id: \.self) { key in
                        Picker(key + " 切换到", selection: Binding(get: { library.quickBook(key)?.id.uuidString ?? "" }, set: { library.bind(key, to: $0) })) {
                            Text("未绑定").tag("")
                            ForEach(library.records) { book in Text(book.name).tag(book.id.uuidString) }
                        }.font(.system(size: 12))
                    }
                    LedgerRule()
                    step("3", "在金额框中快速记账", "打开一个账本，点击金额框，直接按 Q、W、E 或 R 切换。确认顶部账本名称后输入金额，按回车保存。输入 +100 记入账，输入 -20 记出账，也支持 +100-20 连续加减。")
                    Text("切换时，各账本分别保留金额、备注等未提交草稿。备注和搜索框可以正常输入字母，快捷键只在金额框中生效。无需按住 Command。").font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    Text("币种快捷键保持原有设置：C 人民币、U 美元、H 港币、O 欧元、T 新台币。余额涨幅会随入账和出账变化。").font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    if !library.error.isEmpty { Text(library.error).font(.system(size: 11)).foregroundStyle(.red) }
                }.padding(.trailing, 8)
            }
            HStack {
                Text("随时点“新手教程”重新查看和改绑。").font(.system(size: 10)).foregroundStyle(muted)
                Spacer()
                Button("开始记账") { library.completeGuide() }.keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 480, height: 640).background(paper).foregroundStyle(ink).preferredColorScheme(.light)
    }
    func step(_ number: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundStyle(accent).frame(width: 24, height: 24).background(accent.opacity(0.09)).cornerRadius(3)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
