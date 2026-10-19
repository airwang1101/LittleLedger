import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Currency: String, Codable, CaseIterable, Identifiable {
    case cny = "CNY", usd = "USD", hkd = "HKD", eur = "EUR", twd = "TWD"
    var id: String { rawValue }
    var symbol: String { switch self { case .cny: return "¥"; case .usd: return "$"; case .hkd: return "HK$"; case .eur: return "€"; case .twd: return "NT$" } }
    var name: String { switch self { case .cny: return "人民币"; case .usd: return "美元"; case .hkd: return "港币"; case .eur: return "欧元"; case .twd: return "新台币" } }
    static func shortcut(_ key: String) -> Currency? { ["c": .cny, "u": .usd, "h": .hkd, "o": .eur, "t": .twd][key.lowercased()] }
}

struct Preferences: Codable, Equatable {
    var showTotalAssets = true
    var totalCurrency = Currency.cny
    var selectedCurrency = Currency.cny
    var automaticRates = true
    var ratesUSD: [String: Decimal] = ["USD": 1]
    var manualRatesUSD: [String: Decimal] = ["USD": 1]
    var ratesDate: Date? = nil
    var fetchedAt: Date? = nil
}
struct Draft: Codable { var amount: String; var note: String; var mode: Int; var category: String? = nil }
struct FullBackup: Codable { var version = 2; var entries: [Entry]; var preferences: Preferences }
struct RateResponse: Decodable {
    var result: String
    var base_code: String
    var time_last_update_unix: Int64
    var rates: [String: Decimal]
    func validatedRates() throws -> [String: Decimal] {
        guard result == "success", base_code == "USD", time_last_update_unix > 0 else { throw LedgerError.invalid }
        var selected: [String: Decimal] = [:]
        for unit in Currency.allCases {
            guard let value = rates[unit.rawValue], value > 0, value < 100_000_000 else { throw LedgerError.invalid }
            selected[unit.rawValue] = value
        }
        guard selected["USD"] == 1 else { throw LedgerError.invalid }
        return selected
    }
}
enum Conversion {
    static func total(_ entries: [Entry], to target: Currency, rates: [String: Decimal]) -> Int64? {
        var balances: [Currency: Int64] = [:]
        for entry in entries { balances[entry.resolvedCurrency, default: 0] += entry.cents }
        var sum: Decimal = 0
        for (source, cents) in balances where cents != 0 {
            if source == target { sum += Decimal(cents); continue }
            guard let from = rates[source.rawValue], let to = rates[target.rawValue], from > 0, to > 0 else { return nil }
            sum += Decimal(cents) * to / from
        }
        guard !sum.isNaN, sum >= -9_000_000_000_000_000, sum <= 9_000_000_000_000_000 else { return nil }
        var rounded: Decimal = 0
        NSDecimalRound(&rounded, &sum, 0, .plain)
        return NSDecimalNumber(decimal: rounded).int64Value
    }
}

struct Entry: Identifiable, Codable, Equatable {
    var id = UUID()
    var cents: Int64
    var note: String
    var date = Date()
    var currency: Currency? = nil
    var category: String? = nil
    var resolvedCurrency: Currency { currency ?? .cny }
    var resolvedCategory: String { let text = category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""; return text.isEmpty ? "未分类" : text }
}
enum LedgerError: LocalizedError {
    case invalid, zero, limit
    var errorDescription: String? {
        switch self {
        case .invalid: return "请输入金额，最多两位小数。也可输入 +100-20+50。"
        case .zero: return "金额需要大于 0。"
        case .limit: return "金额超出范围，请拆分记录或先导出账目。"
        }
    }
}
enum Amounts {
    static func acceptsInput(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789.+-＋−－,，").union(.whitespacesAndNewlines)
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
    static func parse(_ raw: String, mode: Int) throws -> [Int64] {
        let s = raw.replacingOccurrences(of: "[\\s,，]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "＋", with: "+").replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "－", with: "-")
        let number = "(?:[0-9]+(?:\\.[0-9]{1,2})?|\\.[0-9]{1,2})"
        guard s.range(of: "^[+-]?" + number + "(?:[+-]" + number + ")*$", options: .regularExpression) != nil else { throw LedgerError.invalid }
        let regex = try NSRegularExpression(pattern: "[+-]?" + number)
        return try regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).enumerated().map { index, match in
            let part = String(s[Range(match.range, in: s)!])
            let negative = part.hasPrefix("-") || (index == 0 && !part.hasPrefix("+") && !part.hasPrefix("-") && mode < 0)
            let digits = part.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
            let bits = digits.split(separator: ".", omittingEmptySubsequences: false)
            guard let whole = Int64(bits[0].isEmpty ? "0" : String(bits[0])), whole <= 1_000_000_000_000 else { throw LedgerError.limit }
            let fraction = bits.count > 1 ? String(bits[1]) : ""
            let cents = whole * 100 + (Int64(fraction.padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0)
            guard cents <= 100_000_000_000_000 else { throw LedgerError.limit }
            guard cents > 0 else { throw LedgerError.zero }
            return negative ? -cents : cents
        }
    }
    static func validate(_ entries: [Entry]) throws {
        var sum: Int64 = 0
        for item in entries {
            guard item.cents != 0, item.cents >= -100_000_000_000_000, item.cents <= 100_000_000_000_000 else { throw LedgerError.limit }
            let (next, overflow) = sum.addingReportingOverflow(abs(item.cents))
            guard !overflow, next <= 9_000_000_000_000_000 else { throw LedgerError.limit }
            sum = next
        }
        guard Set(entries.map(\.id)).count == entries.count else { throw LedgerError.invalid }
    }
    static func format(_ cents: Int64) -> String {
        let n = abs(cents)
        let whole = NumberFormatter.localizedString(from: NSNumber(value: n / 100), number: .decimal)
        return (cents < 0 ? "−" : "") + whole + String(format: ".%02lld", n % 100)
    }
}

@MainActor final class Ledger: ObservableObject {
    @Published var entries: [Entry] = [] { didSet { rebuildBookkeepingCache() } }
    @Published var amount = ""
    @Published var note = ""
    @Published var category = "未分类"
    @Published var mode = 1
    @Published var currency = Currency.cny { didSet { preferences.selectedCurrency = currency } }
    @Published var preferences = Preferences() { didSet { persistPreferences() } }
    @Published var fetchingRates = false
    @Published var rateStatus = ""
    @Published var rateInputs: [String: String] = [:]
    @Published var message = ""
    @Published var failed = false
    @Published var focus = 0
    @Published var history: [[Entry]] = []
    private var currencyTotals: [Currency: (income: Int64, expense: Int64)] = [:]
    private var assetCache: (target: Currency, rates: [String: Decimal], value: Int64?)? = nil
    private(set) var categoryNames: [String] = Ledger.categories.sorted()
    let file: URL
    var settingsFile: URL { file.deletingLastPathComponent().appendingPathComponent("settings.json") }
    var draftFile: URL { file.deletingLastPathComponent().appendingPathComponent("draft.json") }
    var activeRates: [String: Decimal] { preferences.automaticRates ? preferences.ratesUSD : preferences.manualRatesUSD }
    var totalAssets: Int64? {
        let target = preferences.totalCurrency, rates = activeRates
        if let assetCache, assetCache.target == target && assetCache.rates == rates { return assetCache.value }
        let value = Conversion.total(entries, to: target, rates: rates)
        assetCache = (target, rates, value)
        return value
    }
    var displayedCurrency: Currency { preferences.showTotalAssets ? preferences.totalCurrency : currency }
    var displayedBalance: Int64? { preferences.showTotalAssets ? totalAssets : income - expense }
    var rateCaption: String {
        if !preferences.automaticRates { return "按手动汇率折算" }
        guard let date = preferences.ratesDate else { return fetchingRates ? "正在获取最新汇率…" : "尚未获取汇率" }
        let cached = preferences.fetchedAt.map { Date().timeIntervalSince($0) > 86400 } ?? true
        return "汇率更新：" + date.formatted(date: .numeric, time: .shortened) + (cached ? "（缓存）" : "")
    }
    var income: Int64 { currencyTotals[currency]?.income ?? 0 }
    var expense: Int64 { currencyTotals[currency]?.expense ?? 0 }
    private func rebuildBookkeepingCache() {
        var totals: [Currency: (income: Int64, expense: Int64)] = [:]
        for entry in entries {
            var total = totals[entry.resolvedCurrency] ?? (0, 0)
            if entry.cents > 0 { total.income += entry.cents } else { total.expense -= entry.cents }
            totals[entry.resolvedCurrency] = total
        }
        currencyTotals = totals; assetCache = nil
        categoryNames = Array(Set(Self.categories + entries.map(\.resolvedCategory))).sorted()
    }
    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LittleLedger/ledger.json")
        do {
            if FileManager.default.fileExists(atPath: self.file.path) {
                entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: self.file))
                try Amounts.validate(entries)
            }
        } catch { entries = []; failed = true; message = "账目读取失败，原文件已保留：\(error.localizedDescription)" }
        if let data = try? Data(contentsOf: settingsFile) {
            do { preferences = try JSONDecoder().decode(Preferences.self, from: data); currency = preferences.selectedCurrency }
            catch { message = "设置读取失败，账目已保留。" }
        }
        if let data = try? Data(contentsOf: draftFile), let draft = try? JSONDecoder().decode(Draft.self, from: data), Amounts.acceptsInput(draft.amount) {
            amount = draft.amount; note = draft.note; mode = draft.mode == -1 ? -1 : 1; category = draft.category ?? "未分类"
        }
        rebuildBookkeepingCache()
    }
    func persistPreferences() {
        do {
            try FileManager.default.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(preferences).write(to: settingsFile, options: .atomic)
        } catch { message = "设置保存失败：\(error.localizedDescription)" }
    }
    func persistDraft() {
        do {
            try FileManager.default.createDirectory(at: draftFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Draft(amount: amount, note: note, mode: mode, category: category)).write(to: draftFile, options: .atomic)
        } catch { message = "草稿保存失败：\(error.localizedDescription)" }
    }
    func refreshRates(force: Bool = false) async {
        guard !fetchingRates, preferences.automaticRates else { return }
        if !force, let fetchedAt = preferences.fetchedAt, Date().timeIntervalSince(fetchedAt) < 43200,
           Currency.allCases.allSatisfy({ (preferences.ratesUSD[$0.rawValue] ?? 0) > 0 }) { return }
        fetchingRates = true; rateStatus = ""
        defer { fetchingRates = false }
        do {
            var request = URLRequest(url: URL(string: "https://open.er-api.com/v6/latest/USD")!)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw LedgerError.invalid }
            let quote = try JSONDecoder().decode(RateResponse.self, from: data)
            let rates = try quote.validatedRates()
            guard Date(timeIntervalSince1970: Double(quote.time_last_update_unix)) <= Date().addingTimeInterval(86400) else { throw LedgerError.invalid }
            var next = preferences
            next.ratesUSD = rates; next.ratesDate = Date(timeIntervalSince1970: Double(quote.time_last_update_unix)); next.fetchedAt = Date()
            preferences = next; rateStatus = "汇率已更新"
        } catch { rateStatus = preferences.ratesDate == nil ? "获取汇率失败，请重试。" : "更新失败，继续使用上次汇率。" }
    }
    func setManualRate(_ text: String, for unit: Currency) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { preferences.manualRatesUSD.removeValue(forKey: unit.rawValue); return }
        guard value.range(of: "^[0-9]+(?:\\.[0-9]{0,8})?$", options: .regularExpression) != nil,
              let rate = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), rate > 0, rate < 100_000_000 else { return }
        preferences.manualRatesUSD[unit.rawValue] = rate
    }
    func changeMode(_ value: Int) { mode = value; focus += 1 }
    func changeCurrency(_ value: Currency) { currency = value; message = "本笔币种：\(value.name)（\(value.rawValue)）"; focus += 1 }
    func handleSign() {
        guard let first = amount.first else { return }
        if "+＋-−－".contains(first) {
            mode = "+＋".contains(first) ? 1 : -1
            amount.removeFirst()
        }
    }
    @discardableResult func save(_ next: [Entry], remember: Bool = true) -> Bool {
        guard !failed else { return false }
        do {
            try Amounts.validate(next)
            let data = try JSONEncoder().encode(next)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) {
                try Data(contentsOf: file).write(to: file.appendingPathExtension("backup"), options: .atomic)
            }
            try data.write(to: file, options: .atomic)
            if remember { history.append(entries) }
            entries = next
            return true
        } catch { message = "保存失败：\(error.localizedDescription)"; return false }
    }
    func add() {
        do {
            let values = try Amounts.parse(amount, mode: mode)
            let batch = values.map { Entry(cents: $0, note: note.trimmingCharacters(in: .whitespacesAndNewlines), currency: currency, category: category) }
            if save(entries + batch) { amount = ""; note = ""; message = "已记 \(batch.count) 笔"; focus += 1 }
        } catch { message = error.localizedDescription; focus += 1 }
    }
    func remove(_ entry: Entry) { if save(entries.filter { $0.id != entry.id }) { message = "已删除，可撤销恢复" } }
    static let categories = ["未分类", "工资", "项目收入", "投资收益", "餐饮", "购物", "交通", "居住", "娱乐", "转账", "其他"]
    func setCategory(_ value: String, for entry: Entry) {
        var next = entries
        guard let index = next.firstIndex(where: { $0.id == entry.id }) else { return }
        next[index].category = value
        if save(next) { message = "分类已更新，可撤销恢复" }
    }
    func customCategory(for entry: Entry? = nil) {
        let alert = NSAlert(); alert.messageText = "自定义分类"; alert.informativeText = "输入分类名称，最多 40 个字。"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        input.stringValue = entry?.resolvedCategory ?? (category == "未分类" ? "" : category)
        alert.accessoryView = input; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = String(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !value.isEmpty else { return }
        if let entry { setCategory(value, for: entry) } else { category = value }
    }
    func undo() { if let previous = history.last, save(previous, remember: false) { history.removeLast(); message = "已撤销"; focus += 1 } }
    func export(backup: Bool = false) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = backup ? [.json] : [.commaSeparatedText]
        panel.nameFieldStringValue = "小账本-" + Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)) + (backup ? ".json" : ".csv")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if backup { try JSONEncoder().encode(FullBackup(entries: entries, preferences: preferences)).write(to: url, options: .atomic) }
            else {
                func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                var balances: [Currency: Int64] = [:]
                var lines = [["时间", "类型", "金额", "备注", "余额", "币种", "分类"]]
                for item in entries {
                    let unit = item.resolvedCurrency
                    balances[unit, default: 0] += item.cents
                    let balance = balances[unit, default: 0]
                    var memo = item.note
                    if let first = memo.first, "=+@-\t\r\n".contains(first) { memo = "'" + memo }
                    let signed = (item.cents < 0 ? "-" : "") + String(abs(item.cents) / 100) + String(format: ".%02lld", abs(item.cents) % 100)
                    let running = (balance < 0 ? "-" : "") + String(abs(balance) / 100) + String(format: ".%02lld", abs(balance) % 100)
                    let category = item.resolvedCategory
                    let safeCategory = category.first.map { "=+@-\t\r\n".contains($0) } == true ? "'" + category : category
                    lines.append([item.date.formatted(date: .numeric, time: .standard), item.cents > 0 ? "入账" : "出账", signed, memo, running, unit.rawValue, safeCategory])
                }
                let csv = "\u{feff}" + lines.map { $0.map(quote).joined(separator: ",") }.joined(separator: "\r\n")
                try csv.write(to: url, atomically: true, encoding: .utf8)
            }
            message = "已导出 \(entries.count) 笔"
        } catch { message = "导出失败：\(error.localizedDescription)" }
    }
    func importBackup() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let incoming: [Entry]
            var importedPreferences: Preferences? = nil
            if let complete = try? JSONDecoder().decode(FullBackup.self, from: data) { incoming = complete.entries; importedPreferences = complete.preferences }
            else { incoming = try JSONDecoder().decode([Entry].self, from: data) }
            try Amounts.validate(incoming)
            let ids = Set(entries.map(\.id)); let fresh = incoming.filter { !ids.contains($0.id) }
            if save(entries + fresh) {
                if let importedPreferences { preferences = importedPreferences; currency = importedPreferences.selectedCurrency }
                message = "已导入 \(fresh.count) 笔"
            }
        } catch { message = "导入失败：\(error.localizedDescription)" }
    }
}

let paper = Color(red: 0.969, green: 0.961, blue: 0.941)
let ink = Color(red: 0.20, green: 0.19, blue: 0.17)
let muted = Color(red: 0.52, green: 0.50, blue: 0.46)
let accent = Color(red: 0.75, green: 0.39, blue: 0.26)

struct LedgerPageTitle: View {
    var title: String
    var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) { Rectangle().fill(accent).frame(width: 6, height: 25); Text(title).font(.system(size: 28, weight: .bold)).tracking(-0.6) }
            Text(subtitle).font(.system(size: 9, weight: .medium)).tracking(2.1).foregroundStyle(muted)
        }
    }
}
struct LedgerRule: View {
    var opacity = 0.18
    var body: some View { Rectangle().fill(ink.opacity(opacity)).frame(height: 1) }
}

final class AmountEditor: NSTextView {
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let replacementString else { return super.shouldChangeText(in: affectedCharRange, replacementString: nil) }
        guard Amounts.acceptsInput(replacementString) else { NSSound.beep(); return false }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let text = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
        guard Amounts.acceptsInput(text) else { NSSound.beep(); return }
        super.insertText(insertString, replacementRange: replacementRange)
    }
}

final class AmountInputFormatter: Formatter {
    override func string(for obj: Any?) -> String? { obj as? String }
    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String, errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        guard Amounts.acceptsInput(string) else { return false }
        obj?.pointee = string as NSString
        return true
    }
    override func isPartialStringValid(_ partialString: String, newEditingString newString: AutoreleasingUnsafeMutablePointer<NSString?>?, errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        Amounts.acceptsInput(partialString)
    }
}

struct NativeAmountField: NSViewRepresentable {
    @ObservedObject var model: Ledger
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.identifier = NSUserInterfaceItemIdentifier("amount")
        field.placeholderString = "输入金额"
        field.setAccessibilityLabel("金额或加减算式")
        field.font = NSFont.systemFont(ofSize: 31, weight: .regular)
        field.textColor = NSColor(red: 0.20, green: 0.19, blue: 0.17, alpha: 1)
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.cell?.isScrollable = true
        field.formatter = AmountInputFormatter()
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != model.amount { field.stringValue = model.amount }
        if context.coordinator.focus != model.focus {
            context.coordinator.focus = model.focus
            DispatchQueue.main.async { if field.window?.firstResponder !== field.currentEditor() || field.currentEditor() == nil { field.window?.makeFirstResponder(field) } }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: Ledger
        var focus = -1
        init(_ model: Ledger) { self.model = model }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            guard Amounts.acceptsInput(field.stringValue) else { field.stringValue = model.amount; return }
            model.amount = field.stringValue
            model.handleSign()
            if field.stringValue != model.amount { field.stringValue = model.amount }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) { model.add(); return true }
            return false
        }
    }
}

struct LedgerView: View {
    @ObservedObject var model: Ledger
    var onSettings: () -> Void
    var onStatistics: () -> Void
    var onBooks: () -> Void = {}
    var bookName: String = "小账本"
    var shortcutHint: String = ""
    var onGuide: () -> Void = {}
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                LedgerPageTitle(title: bookName, subtitle: "PERSONAL LEDGER")
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    HStack(spacing: 16) {
                        Button(action: onGuide) { Image(systemName: "questionmark.circle").font(.system(size: 13)).foregroundStyle(muted) }.buttonStyle(.plain).accessibilityLabel("新手教程")
                        Button(action: onBooks) { Label("账本", systemImage: "books.vertical").font(.system(size: 12, weight: .medium)).foregroundStyle(accent) }.buttonStyle(.plain).accessibilityLabel("选择账本")
                        Button(action: onStatistics) { Label("统计", systemImage: "chart.bar.xaxis").font(.system(size: 12, weight: .medium)).foregroundStyle(accent) }.buttonStyle(.plain).accessibilityLabel("打开统计")
                        Button(action: onSettings) { Image(systemName: "gearshape").font(.system(size: 14)).foregroundStyle(ink) }.buttonStyle(.plain).help("设置").accessibilityLabel("设置")
                    }.padding(.top, 4)
                    Label(model.failed ? "读取失败" : "自动保存在本机", systemImage: model.failed ? "exclamationmark.circle" : "checkmark.circle").font(.system(size: 10)).foregroundStyle(muted)
                }
            }.padding(.bottom, 22)
            if !shortcutHint.isEmpty { Text(shortcutHint).font(.system(size: 10)).foregroundStyle(muted).lineLimit(2).padding(.bottom, 12) }
            LedgerRule(opacity: 0.25)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text((model.preferences.showTotalAssets ? "总资产 · " : "当前余额 · ") + model.displayedCurrency.rawValue).font(.system(size: 12, weight: .medium)).foregroundStyle(muted)
                    Spacer()
                    Menu("显示币种：" + model.displayedCurrency.rawValue) {
                        ForEach(Currency.allCases) { unit in
                            Button(unit.name + " " + unit.rawValue) {
                                if model.preferences.showTotalAssets { model.preferences.totalCurrency = unit }
                                else { model.changeCurrency(unit) }
                            }
                        }
                    }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 12)).foregroundStyle(muted)
                }
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(model.displayedCurrency.symbol).font(.system(size: 26, weight: .light)).foregroundStyle(muted)
                    Text(model.displayedBalance.map(Amounts.format) ?? "等待汇率").font(.custom("AnthropicSerifDisplay-Regular", size: 58, relativeTo: .largeTitle)).monospacedDigit().minimumScaleFactor(0.3).lineLimit(1).accessibilityIdentifier("balance")
                }
                if model.preferences.showTotalAssets {
                    HStack(spacing: 8) {
                        Text(model.totalAssets == nil ? "汇率不完整，请在设置中更新。" : model.rateCaption)
                        if model.fetchingRates { ProgressView().controlSize(.mini) }
                        if !model.rateStatus.isEmpty { Text(model.rateStatus) }
                    }.font(.system(size: 10)).foregroundStyle(muted).lineLimit(2)
                }
                HStack(spacing: 24) {
                    stat("本币余额 · " + model.currency.rawValue, value: model.income - model.expense, sign: "")
                    Rectangle().fill(ink.opacity(0.13)).frame(width: 1, height: 25)
                    stat("累计入账 · " + model.currency.rawValue, value: model.income, sign: "+")
                    Rectangle().fill(ink.opacity(0.13)).frame(width: 1, height: 25)
                    stat("累计出账 · " + model.currency.rawValue, value: model.expense, sign: "−")
                    Spacer()
                }.padding(.top, 8)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 24).padding(.bottom, 24)
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 5) {
                    modeButton("+ 入账", value: 1)
                    modeButton("− 出账", value: -1)
                    Spacer()
                    Menu("本笔币种：" + model.currency.rawValue) {
                        ForEach(Currency.allCases) { unit in Button(unit.name + " " + unit.rawValue) { model.changeCurrency(unit) } }
                    }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 12)).foregroundStyle(muted).accessibilityLabel("本笔入账或出账币种")
                }
                HStack(spacing: 12) {
                    Text(model.mode > 0 ? "+" : "−").font(.system(size: 30, weight: .light)).foregroundStyle(model.mode > 0 ? Color(red: 0.29, green: 0.43, blue: 0.34) : accent).frame(width: 24)
                    NativeAmountField(model: model).frame(height: 42)
                    Button(action: model.add) { HStack(spacing: 12) { Text("记一笔"); Image(systemName: "return") }.font(.system(size: 13, weight: .medium)).foregroundStyle(.white).padding(.horizontal, 20).frame(height: 43).background(accent, in: RoundedRectangle(cornerRadius: 2)) }.buttonStyle(.plain).disabled(model.failed)
                }.padding(.vertical, 8)
                Rectangle().fill(ink.opacity(0.10)).frame(height: 1)
                HStack {
                    TextField("备注，选填", text: $model.note).textFieldStyle(.plain).font(.system(size: 13)).onSubmit { model.add() }.accessibilityLabel("备注")
                    Menu("分类：" + model.category) {
                        ForEach(model.categoryNames, id: \.self) { value in Button(value) { model.category = value } }
                        Divider(); Button("自定义分类…") { model.customCategory() }
                    }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 11)).foregroundStyle(muted)
                }
            }.padding(18).background(Color.white.opacity(0.52)).overlay(alignment: .top) { LedgerRule() }.overlay(alignment: .bottom) { LedgerRule() }
            HStack {
                Text(model.message.isEmpty ? "c 人民币 · u 美元 · h 港币 · o 欧元 · t 新台币；支持连续加减，回车保存。" : model.message)
                Spacer()
            }.font(.system(size: 11)).foregroundStyle(muted).frame(height: 32).lineLimit(2).accessibilityIdentifier("message")
            HStack {
                Text("账目记录").font(.system(size: 13, weight: .semibold))
                Text("\(model.entries.count) 笔").font(.system(size: 11)).foregroundStyle(muted)
                Spacer()
                Button("撤销上一笔", action: model.undo).disabled(model.history.isEmpty)
                Menu("导出") {
                    Button("导出表格（CSV）") { model.export() }.disabled(model.entries.isEmpty)
                    Button("导出完整备份（JSON）") { model.export(backup: true) }.disabled(model.entries.isEmpty)
                    Button("导入备份…", action: model.importBackup)
                }.menuStyle(.borderlessButton).fixedSize()
            }.buttonStyle(.plain).font(.system(size: 11)).padding(.top, 9).padding(.bottom, 12)
            Rectangle().fill(ink.opacity(0.12)).frame(height: 1)
            if model.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.book.closed").font(.system(size: 25, weight: .ultraLight)).foregroundStyle(muted.opacity(0.6))
                    Text("输入第一笔，开始算总账。").font(.system(size: 12)).foregroundStyle(muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.entries.reversed()) { entry in
                            HStack(spacing: 12) {
                                Text(entry.cents > 0 ? "+" : "−").font(.system(size: 21, weight: .light)).foregroundStyle(entry.cents > 0 ? Color(red: 0.29, green: 0.43, blue: 0.34) : accent).frame(width: 24)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(entry.note.isEmpty ? (entry.cents > 0 ? "入账" : "出账") : entry.note).font(.system(size: 13)).textSelection(.enabled)
                                    Text(entry.date.formatted(.dateTime.month().day().hour().minute()) + " · " + entry.resolvedCurrency.rawValue + " · " + entry.resolvedCategory).font(.system(size: 10)).foregroundStyle(muted)
                                }
                                Spacer()
                                Text((entry.cents > 0 ? "+" : "−") + entry.resolvedCurrency.symbol + Amounts.format(abs(entry.cents))).font(.system(size: 16, weight: .medium, design: .monospaced)).monospacedDigit()
                                Button { model.remove(entry) } label: { Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(muted).padding(7) }.buttonStyle(.plain).help("删除这笔，可撤销").accessibilityLabel("删除这笔 \(entry.cents)")
                            }.padding(.vertical, 15).contextMenu {
                                Menu("设置分类") {
                                    ForEach(model.categoryNames, id: \.self) { value in Button(value) { model.setCategory(value, for: entry) } }
                                    Divider(); Button("自定义分类…") { model.customCategory(for: entry) }
                                }
                            }
                            Rectangle().fill(ink.opacity(0.07)).frame(height: 1)
                        }
                    }
                }.frame(maxHeight: .infinity)
            }
            HStack { Circle().fill(accent.opacity(0.5)).frame(width: 4, height: 4); Text("账目只存本机 · 随时导出"); if model.preferences.automaticRates && model.preferences.showTotalAssets { Link("Rates by ExchangeRate-API", destination: URL(string: "https://www.exchangerate-api.com")!).foregroundStyle(muted) } }.font(.system(size: 10)).foregroundStyle(muted).padding(.top, 13)
        }.padding(.horizontal, 30).padding(.top, 26).padding(.bottom, 18).frame(minWidth: 530, minHeight: 700).background(paper).foregroundStyle(ink).preferredColorScheme(.light)
    }
    func modeButton(_ title: String, value: Int) -> some View {
        Button { model.changeMode(value) } label: { Text(title).font(.system(size: 12, weight: model.mode == value ? .semibold : .regular)).padding(.horizontal, 8).padding(.vertical, 9).foregroundStyle(model.mode == value ? ink : muted).overlay(alignment: .bottom) { Rectangle().fill(model.mode == value ? accent : .clear).frame(height: 2) } }.buttonStyle(.plain)
    }
    func stat(_ label: String, value: Int64, sign: String) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(label).font(.system(size: 11)).foregroundStyle(muted); Text(sign + " " + Amounts.format(value)).font(.system(size: 16, design: .rounded)).monospacedDigit() }
    }
}

struct LedgerSettingsView: View {
    @ObservedObject var model: Ledger
    var onClose: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                LedgerPageTitle(title: "设置", subtitle: "LEDGER PREFERENCES")
                Spacer()
                Button("完成", action: onClose).buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(accent).padding(.top, 7).keyboardShortcut(.cancelAction)
            }.padding(30)
            LedgerRule(opacity: 0.25)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("总资产").font(.system(size: 14, weight: .semibold))
                        Toggle("显示总资产", isOn: $model.preferences.showTotalAssets).toggleStyle(.switch).font(.system(size: 12))
                        HStack {
                            Text("总资产显示币种").font(.system(size: 12))
                            Spacer()
                            Picker("总资产显示币种", selection: $model.preferences.totalCurrency) {
                                ForEach(Currency.allCases) { unit in Text(unit.name + " " + unit.rawValue).tag(unit) }
                            }.labelsHidden().frame(width: 190).accessibilityLabel("总资产显示币种")
                        }
                        Text("每笔入账、出账可单独选择币种。总资产按这里选择的币种折算，原始金额保持不变。").font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    }
                    LedgerRule()
                    VStack(alignment: .leading, spacing: 13) {
                        HStack {
                            Text("汇率").font(.system(size: 14, weight: .semibold))
                            Spacer()
                            HStack(spacing: 20) {
                                rateMode("自动获取", automatic: true)
                                rateMode("手动填写", automatic: false)
                            }
                        }
                        if model.preferences.automaticRates {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(model.rateCaption).font(.system(size: 12))
                                    Text("参考汇率每日更新。离线时使用上次获取的汇率。").font(.system(size: 10)).foregroundStyle(muted)
                                }
                                Spacer()
                                Button(model.fetchingRates ? "更新中…" : "更新汇率") { Task { await model.refreshRates(force: true) } }.font(.system(size: 11)).disabled(model.fetchingRates)
                            }.padding(.vertical, 6)
                            VStack(spacing: 0) {
                                ForEach(Currency.allCases.filter { $0 != .usd }) { unit in
                                    HStack {
                                        Text("1 USD").foregroundStyle(muted)
                                        Text("=").foregroundStyle(muted).padding(.leading, 12)
                                        Spacer()
                                        Text(model.preferences.ratesUSD[unit.rawValue].map { NSDecimalNumber(decimal: $0).stringValue } ?? "待获取").monospacedDigit()
                                        Text(unit.rawValue).foregroundStyle(muted).frame(width: 42, alignment: .trailing)
                                    }.font(.system(size: 12, design: .monospaced)).padding(.vertical, 10)
                                    LedgerRule(opacity: 0.08)
                                }
                            }
                            if !model.rateStatus.isEmpty { Text(model.rateStatus).font(.system(size: 11)).foregroundStyle(muted) }
                            Link("汇率来源：ExchangeRate-API", destination: URL(string: "https://www.exchangerate-api.com/docs/free")!).font(.system(size: 10)).foregroundStyle(accent)
                        } else {
                            Text("填写每 1 美元可兑换的金额。更换总资产显示币种时，会自动计算交叉汇率。").font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                            ForEach(Currency.allCases.filter { $0 != .usd }) { unit in
                                HStack(spacing: 14) {
                                    Text("1 USD =").font(.system(size: 12, design: .monospaced)).foregroundStyle(muted)
                                    TextField("填写汇率", text: Binding(get: { model.rateInputs[unit.rawValue] ?? "" }, set: { model.rateInputs[unit.rawValue] = $0; model.setManualRate($0, for: unit) }))
                                        .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced)).padding(.horizontal, 9).padding(.vertical, 8).background(Color.white.opacity(0.7)).overlay(alignment: .bottom) { LedgerRule() }.accessibilityLabel("USD 兑换 " + unit.rawValue)
                                    Text(unit.rawValue).font(.system(size: 12)).foregroundStyle(muted).frame(width: 42, alignment: .trailing)
                                }
                            }
                        }
                    }
                    LedgerRule()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("键盘操作").font(.system(size: 12, weight: .semibold))
                        Text("c 人民币 · u 美元 · h 港币 · o 欧元 · t 新台币").font(.system(size: 11)).foregroundStyle(muted)
                        Text("+ 入账，- 出账，回车保存。软件会记住当前币种。").font(.system(size: 11)).foregroundStyle(muted)
                    }
                }.padding(30)
            }
        }.frame(width: 560, height: 740).background(paper).foregroundStyle(ink).preferredColorScheme(.light)
        .onAppear { for (key, value) in model.preferences.manualRatesUSD { model.rateInputs[key] = NSDecimalNumber(decimal: value).stringValue } }
        .onChange(of: model.preferences.automaticRates) { value in if value { Task { await model.refreshRates() } } }
    }
    func rateMode(_ title: String, automatic: Bool) -> some View {
        Button { model.preferences.automaticRates = automatic } label: {
            Text(title).font(.system(size: 11, weight: model.preferences.automaticRates == automatic ? .semibold : .regular)).foregroundStyle(model.preferences.automaticRates == automatic ? ink : muted).padding(.vertical, 8).overlay(alignment: .bottom) { Rectangle().fill(model.preferences.automaticRates == automatic ? accent : .clear).frame(height: 2) }
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let library = BookLibrary()
    var model: Ledger { library.active }
    var keyMonitor: Any?
    var settingsWindow: NSWindow?
    var statisticsWindow: NSWindow?
    let statistics = StatisticsState()
    lazy var amountEditor: AmountEditor = { let editor = AmountEditor(); editor.isFieldEditor = true; return editor }()
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard let field = client as? NSTextField, field.identifier?.rawValue == "amount" else { return nil }
        return amountEditor
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于小账本", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "新手教程…", action: #selector(showGuide), keyEquivalent: "").target = self
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "退出小账本", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenuItem(); edit.title = "编辑"; menu.addItem(edit); let editMenu = NSMenu(title: "编辑"); edit.submenu = editMenu
        editMenu.addItem(withTitle: "撤销上一笔", action: #selector(undoEntry), keyEquivalent: "z").target = self
        for (title, selector, key) in [("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] { editMenu.addItem(withTitle: title, action: selector, keyEquivalent: key) }
        let file = NSMenuItem(); file.title = "账目"; menu.addItem(file); let fileMenu = NSMenu(title: "账目"); file.submenu = fileMenu
        fileMenu.addItem(withTitle: "导出表格…", action: #selector(exportEntries), keyEquivalent: "e").target = self
        fileMenu.addItem(withTitle: "导出完整备份…", action: #selector(exportBackup), keyEquivalent: "").target = self
        fileMenu.addItem(withTitle: "导入备份…", action: #selector(importEntries), keyEquivalent: "o").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "统计…", action: #selector(showStatistics), keyEquivalent: "1").target = self
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 830), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "小账本"; window.titlebarAppearsTransparent = true; window.delegate = self
        window.backgroundColor = NSColor(red: 0.969, green: 0.961, blue: 0.941, alpha: 1)
        window.contentView = NSHostingView(rootView: BookRootView(library: library, onSettings: { [weak self] in self?.showSettings() }, onStatistics: { [weak self] in self?.showStatistics() }, onSwitch: { [weak self] in
            self?.settingsWindow?.close(); self?.settingsWindow = nil
            self?.statisticsWindow?.close(); self?.statisticsWindow = nil
        }))
        window.minSize = NSSize(width: 530, height: 730); window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.library.showChooser, NSApp.keyWindow === self.window,
                  self.window.attachedSheet == nil,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let editor = self.window.firstResponder as? NSTextView,
                  let field = editor.delegate as? NSTextField, field.identifier?.rawValue == "amount" else { return event }
            if let key = QuickBookKeys.key(for: event.keyCode) {
                self.settingsWindow?.close(); self.settingsWindow = nil
                self.statisticsWindow?.close(); self.statisticsWindow = nil
                self.library.switchQuickly(key)
                return nil
            }
            guard let key = event.charactersIgnoringModifiers, let unit = Currency.shortcut(key) else { return event }
            self.model.changeCurrency(unit)
            return nil
        }
        Task { await model.refreshRates() }
    }
    @objc func showGuide() { library.showGuide = true }
    @objc func showSettings() {
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 740), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "小账本设置"; panel.isReleasedWhenClosed = false; panel.titlebarAppearsTransparent = true
        panel.contentView = NSHostingView(rootView: LedgerSettingsView(model: model, onClose: { [weak self] in self?.settingsWindow?.close() }))
        panel.center(); panel.makeKeyAndOrderFront(nil); settingsWindow = panel
    }
    @objc func showStatistics() {
        if let statisticsWindow { statisticsWindow.makeKeyAndOrderFront(nil); return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 880), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        panel.title = "小账本统计"; panel.isReleasedWhenClosed = false; panel.titlebarAppearsTransparent = true
        panel.minSize = NSSize(width: 920, height: 650)
        panel.contentView = NSHostingView(rootView: StatisticsView(model: model, state: statistics))
        panel.center(); panel.makeKeyAndOrderFront(nil); statisticsWindow = panel
    }
    func applicationWillTerminate(_ notification: Notification) { model.persistPreferences(); model.persistDraft() }
    @objc func undoEntry() { model.undo() }
    @objc func exportEntries() { model.export() }
    @objc func exportBackup() { model.export(backup: true) }
    @objc func importEntries() { model.importBackup() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return true }
}

MainActor.assumeIsolated {
if CommandLine.arguments.contains("--books-self-test") {
    booksSelfTest()
} else if CommandLine.arguments.contains("--statistics-benchmark") {
    statisticsBenchmark()
} else if CommandLine.arguments.contains("--self-test") {
    func expect(_ result: Bool, _ name: String) { if !result { fatalError(name) } }
    do {
        try statisticsTests()
        expect(try Amounts.parse("+100-20+50", mode: -1) == [10000, -2000, 5000], "expression")
        expect(try Amounts.parse("100.10", mode: 1) == [10010], "income")
        expect(try Amounts.parse("20.05", mode: -1) == [-2005], "expense")
        expect(try Amounts.parse(".09", mode: -1) == [-9], "fraction")
        expect(Amounts.acceptsInput("+100.20-50+3"), "valid input")
        for text in ["abc", "人民币", "1e3", "100元", "12/3", "1🙂2"] { expect(!Amounts.acceptsInput(text), "reject text: \(text)") }
        let formatter = AmountInputFormatter()
        expect(!formatter.isPartialStringValid("100abc", newEditingString: nil, errorDescription: nil), "formatter rejects mixed paste")
        expect(formatter.isPartialStringValid("100-", newEditingString: nil, errorDescription: nil), "formatter allows partial expression")
        expect(Currency.shortcut("c") == .cny && Currency.shortcut("u") == .usd && Currency.shortcut("h") == .hkd && Currency.shortcut("o") == .eur && Currency.shortcut("t") == .twd, "currency shortcuts")
        for bad in ["", "0", "1.001", "1+", "--1", "1e4", "1000000000001", "1/2"] {
            do { _ = try Amounts.parse(bad, mode: 1); fatalError("Accepted invalid: \(bad)") } catch { }
        }
        let url = URL(fileURLWithPath: CommandLine.arguments.last!).appendingPathComponent("test-ledger.json")
        let ledger = Ledger(file: url)
        ledger.amount = "100.10"; ledger.add(); ledger.mode = -1; ledger.amount = "20.05"; ledger.add()
        expect(ledger.income - ledger.expense == 8005, "balance")
        let loaded = Ledger(file: url); expect(loaded.entries.count == 2 && loaded.income - loaded.expense == 8005, "persistence")
        ledger.remove(ledger.entries[0]); ledger.undo(); expect(ledger.entries.count == 2, "delete undo")
        ledger.undo(); expect(ledger.entries.count == 1, "undo")
        ledger.amount = "+"; ledger.handleSign(); expect(ledger.mode == 1 && ledger.amount.isEmpty, "plus switch")
        ledger.amount = "-"; ledger.handleSign(); expect(ledger.mode == -1 && ledger.amount.isEmpty, "minus switch")
        let cnyIncome = ledger.income
        ledger.changeCurrency(.usd); ledger.mode = 1; ledger.amount = "5.25"; ledger.add()
        expect(ledger.income == 525 && ledger.expense == 0, "independent USD balance")
        ledger.changeCurrency(.cny); expect(ledger.income == cnyIncome, "CNY balance preserved")
        ledger.changeCurrency(.hkd); expect(ledger.income == 0, "HKD balance")
        ledger.changeCurrency(.eur); expect(ledger.income == 0, "EUR balance")
        let reread = Ledger(file: url); reread.changeCurrency(.usd); expect(reread.income == 525, "currency persistence")
        let legacy = Entry(cents: 1234, note: "旧记录")
        let legacyData = try JSONEncoder().encode([legacy])
        let restored = try JSONDecoder().decode([Entry].self, from: legacyData)
        expect(restored[0].resolvedCurrency == .cny, "legacy records default to CNY")
        let rates: [String: Decimal] = ["USD": 1, "CNY": 7, "HKD": Decimal(string: "7.8")!, "EUR": Decimal(string: "0.9")!, "TWD": 32]
        let portfolio = [Entry(cents: 10000, note: "", currency: .cny), Entry(cents: 1000, note: "", currency: .usd), Entry(cents: 7800, note: "", currency: .hkd), Entry(cents: 500, note: "", currency: .eur), Entry(cents: 32000, note: "", currency: .twd)]
        expect(Conversion.total(portfolio, to: .cny, rates: rates) == 34889, "five currencies to CNY")
        expect(Conversion.total(portfolio, to: .usd, rates: rates) == 4984, "five currencies to USD")
        expect(Conversion.total(portfolio, to: .twd, rates: rates) == 159492, "five currencies to TWD")
        expect(Conversion.total(portfolio + [Entry(cents: -1000, note: "", currency: .usd)], to: .cny, rates: rates) == 27889, "converted expense")
        expect(Conversion.total(portfolio, to: .cny, rates: ["CNY": 7, "USD": 1]) == nil, "missing rates never show partial total")
        expect(Conversion.total([Entry(cents: 1234, note: "")], to: .cny, rates: [:]) == 1234, "same-currency total needs no rates")
        let tiny = [Entry(cents: 1, note: "", currency: .usd), Entry(cents: 1, note: "", currency: .usd)]
        expect(Conversion.total(tiny, to: .cny, rates: ["USD": 1, "CNY": Decimal(string: "0.4")!]) == 1, "round once after sum")
        ledger.preferences.totalCurrency = .usd; ledger.preferences.showTotalAssets = false
        ledger.changeCurrency(.twd); ledger.amount = "32"; ledger.mode = 1; ledger.add()
        ledger.amount = "123.45"; ledger.note = "未提交草稿"; ledger.persistDraft()
        let configured = Ledger(file: url)
        expect(configured.currency == .twd && configured.preferences.totalCurrency == .usd && !configured.preferences.showTotalAssets, "settings and selected currency persisted")
        expect(configured.amount == "123.45" && configured.note == "未提交草稿", "draft retained")
        expect(configured.income == 3200, "TWD entries persisted")
        ledger.preferences.ratesUSD = rates
        expect(ledger.totalAssets != nil, "configured portfolio conversion")
        let full = try JSONEncoder().encode(FullBackup(entries: ledger.entries, preferences: ledger.preferences))
        let decoded = try JSONDecoder().decode(FullBackup.self, from: full)
        expect(decoded.entries == ledger.entries && decoded.preferences.totalCurrency == .usd, "backup includes settings")
        let multi = Ledger(file: url.deletingLastPathComponent().appendingPathComponent("multi/ledger.json"))
        multi.preferences.totalCurrency = .eur
        for unit in Currency.allCases {
            multi.changeCurrency(unit); multi.mode = 1; multi.amount = "10"; multi.add()
            multi.mode = -1; multi.amount = "3"; multi.add()
            expect(multi.income == 1000 && multi.expense == 300, "income and expense in " + unit.rawValue)
            expect(multi.entries.suffix(2).allSatisfy { $0.resolvedCurrency == unit }, "original entry currency")
            expect(multi.preferences.totalCurrency == .eur, "entry currency independent of total currency")
        }
        multi.preferences.ratesUSD = rates
        expect(multi.totalAssets == Conversion.total(multi.entries, to: .eur, rates: rates), "total freely selected as EUR")
        let beforeCategory = multi.entries
        multi.setCategory("测试分类", for: multi.entries[0])
        expect(multi.entries[0].resolvedCategory == "测试分类" && multi.categoryNames.contains("测试分类"), "edit existing entry category and refresh menu cache")
        multi.undo(); expect(multi.entries == beforeCategory, "category undo preserves all entry fields")
        let cachedAssets = multi.totalAssets
        multi.amount = "123+456"
        expect(multi.totalAssets == cachedAssets && multi.income == 1000 && multi.expense == 300, "typing preserves cached balances")
        multi.preferences.totalCurrency = .usd
        expect(multi.totalAssets == Conversion.total(multi.entries, to: .usd, rates: multi.activeRates), "asset cache follows display currency")
        multi.preferences.ratesUSD["CNY"] = 6
        expect(multi.totalAssets == Conversion.total(multi.entries, to: .usd, rates: multi.activeRates), "asset cache follows rates")
        multi.changeCurrency(.cny); multi.mode = 1; multi.amount = "1"; multi.add()
        expect(multi.income == 1100 && multi.expense == 300 && multi.totalAssets == Conversion.total(multi.entries, to: .usd, rates: multi.activeRates), "balance caches follow saved entries")
        let cachedStatistics = StatisticsState()
        for _ in 0..<1000 { cachedStatistics.refresh(multi) }
        expect(cachedStatistics.scheduledBuildCount == 1, "1000 unchanged refresh requests schedule a single build")
        cachedStatistics.chart = .bar; cachedStatistics.pie = .pie; cachedStatistics.refresh(multi)
        expect(cachedStatistics.scheduledBuildCount == 1, "chart styling does not recompute data")
        cachedStatistics.scope = .expense; cachedStatistics.refresh(multi)
        expect(cachedStatistics.scheduledBuildCount == 2, "scope change computes a new report")
        if let index = CommandLine.arguments.firstIndex(of: "--rates-fixture"), index + 1 < CommandLine.arguments.count {
            let fixture = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            let response = try JSONDecoder().decode(RateResponse.self, from: fixture)
            let validated = try response.validatedRates()
            expect(validated.count == 5 && validated["TWD"]! > 0, "live provider response and all five currencies")
        }
        print("PASS: existing ledger functions, input filtering, five currency shortcuts, Decimal conversion, missing-rate handling, rounding, settings, drafts, old records, full backup, rate response")
    } catch { fatalError(error.localizedDescription) }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
}
