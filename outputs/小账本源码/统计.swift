import AppKit
import SwiftUI
import Charts

enum StatisticsScope: String, CaseIterable, Identifiable {
    case all = "总览", income = "入账", expense = "出账"
    var id: String { rawValue }
    func includes(_ entry: Entry) -> Bool { self == .all || (self == .income ? entry.cents > 0 : entry.cents < 0) }
}
enum StatisticsPeriod: String, CaseIterable, Identifiable {
    case month = "近 30 天", quarter = "近 90 天", year = "今年", all = "全部"
    var id: String { rawValue }
}
enum StatisticsGrain: String, CaseIterable, Identifiable {
    case auto = "自动", day = "按日", week = "按周", month = "按月"
    var id: String { rawValue }
    var component: Calendar.Component { self == .month ? .month : (self == .week ? .weekOfYear : .day) }
}
enum StatisticsChart: String, CaseIterable, Identifiable {
    case line = "折线图", bar = "柱状图", area = "面积图"
    var id: String { rawValue }
}
enum StatisticsPie: String, CaseIterable, Identifiable {
    case donut = "环形图", pie = "饼图"
    var id: String { rawValue }
}
@MainActor final class StatisticsState: ObservableObject {
    @Published var scope = StatisticsScope.all
    @Published var period = StatisticsPeriod.month
    @Published var grain = StatisticsGrain.auto
    @Published var chart = StatisticsChart.line
    @Published var balanceChart = StatisticsChart.area
    @Published var pie = StatisticsPie.donut
    @Published var heatYear = Calendar.current.component(.year, from: Date())
    @Published private(set) var report: StatisticsReport? = nil
    @Published private(set) var computing = false
    private var lastRequest: StatisticsRequest?
    private var generation = 0
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "LittleLedger.statistics", qos: .userInitiated)
    private(set) var buildCount = 0
    private(set) var scheduledBuildCount = 0
    private(set) var lastBuildMilliseconds = 0.0
    func refresh(_ model: Ledger) {
        let request = StatisticsRequest(entries: model.entries, target: model.preferences.totalCurrency, rates: model.activeRates, scope: scope, period: period, grain: grain, heatYear: heatYear, day: Analytics.calendar.startOfDay(for: Date()))
        guard request != lastRequest else { return }
        lastRequest = request; generation += 1; scheduledBuildCount += 1
        let token = generation
        pending?.cancel(); computing = true
        let item = DispatchWorkItem { [weak self] in
            let started = ProcessInfo.processInfo.systemUptime
            let result = request.makeReport()
            let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.buildCount += 1; self.lastBuildMilliseconds = elapsed
                self.report = result; self.computing = false
            }
        }
        pending = item
        queue.asyncAfter(deadline: .now() + 0.035, execute: item)
    }
}
struct StatisticsRequest: Equatable {
    var entries: [Entry]
    var target: Currency
    var rates: [String: Decimal]
    var scope: StatisticsScope
    var period: StatisticsPeriod
    var grain: StatisticsGrain
    var heatYear: Int
    var day: Date
    func makeReport() -> StatisticsReport { Analytics.build(entries: entries, target: target, rates: rates, scope: scope, period: period, grain: grain, heatYear: heatYear, now: day) }
}
struct StatisticsCategory: Identifiable {
    var name: String
    var cents: Decimal
    var count: Int
    var id: String { name }
}
struct StatisticsPoint: Identifiable {
    var date: Date
    var income: Decimal
    var expense: Decimal
    var balance: Decimal?
    var id: Date { date }
}
struct StatisticsHeatDay: Identifiable, Equatable {
    var index: Int
    var date: Date?
    var count: Int
    var income: Decimal?
    var expense: Decimal?
    var future = false
    var id: Int { index }
}
struct StatisticsReport {
    var start: Date
    var end: Date
    var scope: StatisticsScope
    var currency: Currency
    var grain: StatisticsGrain
    var entries: [Entry]
    var income: Decimal?
    var expense: Decimal?
    var closingBalance: Decimal?
    var points: [StatisticsPoint]
    var incomeCategories: [StatisticsCategory]
    var expenseCategories: [StatisticsCategory]
    var currencyFlows: [StatisticsCategory]
    var missingCurrencies: [String]
    var heatDays: [StatisticsHeatDay]
    var heatYear: Int
    var activeDays: Int
    var heatCount: Int
    var net: Decimal? { guard let income, let expense else { return nil }; return income - expense }
    var amountReady: Bool { income != nil && expense != nil }
}
enum Analytics {
    static var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.firstWeekday = 2; return value }
    static func convert(_ cents: Int64, source: Currency, target: Currency, rates: [String: Decimal]) -> Decimal? {
        if cents == 0 { return 0 }
        if source == target { return Decimal(cents) }
        guard let from = rates[source.rawValue], let to = rates[target.rawValue], !from.isNaN, !to.isNaN, from > 0, to > 0 else { return nil }
        let value = Decimal(cents) * to / from
        return value.isNaN ? nil : value
    }
    static func money(_ value: Decimal?) -> String {
        guard var value, !value.isNaN else { return "等待汇率" }
        let limit = Decimal(9_000_000_000_000_000 as Int64)
        guard value >= -limit && value <= limit else { return "金额超出显示范围" }
        var rounded: Decimal = 0; NSDecimalRound(&rounded, &value, 0, .plain)
        return Amounts.format(NSDecimalNumber(decimal: rounded).int64Value)
    }
    static func chartValue(_ cents: Decimal) -> Double { NSDecimalNumber(decimal: cents / 100).doubleValue }
    static func bounds(entries: [Entry], period: StatisticsPeriod, now: Date, calendar: Calendar) -> (Date, Date) {
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: today)!
        switch period {
        case .month: return (calendar.date(byAdding: .day, value: -30, to: end)!, end)
        case .quarter: return (calendar.date(byAdding: .day, value: -90, to: end)!, end)
        case .year: return (calendar.date(from: DateComponents(year: calendar.component(.year, from: now), month: 1, day: 1))!, end)
        case .all: return (min(today, calendar.startOfDay(for: entries.map(\.date).min() ?? today)), end)
        }
    }
    static func sum(_ entries: [Entry], target: Currency, rates: [String: Decimal], absolute: Bool = false) -> Decimal? {
        var value: Decimal = 0
        for entry in entries {
            guard let converted = convert(entry.cents, source: entry.resolvedCurrency, target: target, rates: rates) else { return nil }
            value += absolute && converted < 0 ? -converted : converted
        }
        return value
    }
    static func categories(_ entries: [Entry], target: Currency, rates: [String: Decimal], byCurrency: Bool = false) -> [StatisticsCategory] {
        var groups: [String: StatisticsCategory] = [:]
        for entry in entries {
            guard let converted = convert(abs(entry.cents), source: entry.resolvedCurrency, target: target, rates: rates) else { return [] }
            let name = byCurrency ? entry.resolvedCurrency.rawValue : entry.resolvedCategory
            var group = groups[name] ?? StatisticsCategory(name: name, cents: 0, count: 0)
            group.cents += converted; group.count += 1; groups[name] = group
        }
        return groups.values.sorted { $0.cents == $1.cents ? $0.name < $1.name : $0.cents > $1.cents }
    }
    static func slices(_ groups: [StatisticsCategory], limit: Int = 5) -> [StatisticsCategory] {
        guard groups.count > limit else { return groups }
        let tail = groups.dropFirst(limit - 1)
        return Array(groups.prefix(limit - 1)) + [StatisticsCategory(name: "其余分类（\(tail.count)项）", cents: tail.reduce(0) { $0 + $1.cents }, count: tail.reduce(0) { $0 + $1.count })]
    }
    static func build(entries: [Entry], target: Currency, rates: [String: Decimal], scope: StatisticsScope, period: StatisticsPeriod, grain requestedGrain: StatisticsGrain, heatYear: Int, now: Date = Date(), calendar: Calendar = Analytics.calendar) -> StatisticsReport {
        let (start, end) = bounds(entries: entries, period: period, now: now, calendar: calendar)
        let allPeriod = entries.filter { $0.date >= start && $0.date < end }
        let selected = allPeriod.filter(scope.includes)
        let incoming = selected.filter { $0.cents > 0 }, outgoing = selected.filter { $0.cents < 0 }
        let income = sum(incoming, target: target, rates: rates)
        let expense = sum(outgoing, target: target, rates: rates, absolute: true)
        let opening = sum(entries.filter { $0.date < start }, target: target, rates: rates)
        let closing = sum(entries.filter { $0.date < end }, target: target, rates: rates)
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 1
        let grain: StatisticsGrain = requestedGrain == .auto ? (days > 730 ? .month : (days > 93 ? .week : .day)) : requestedGrain
        func bucket(_ date: Date) -> Date { calendar.dateInterval(of: grain.component, for: date)!.start }
        var flowGroups: [Date: (Decimal, Decimal)] = [:]
        for entry in selected {
            if let value = convert(entry.cents, source: entry.resolvedCurrency, target: target, rates: rates) {
                let key = bucket(entry.date); var flow = flowGroups[key] ?? (0, 0)
                if value > 0 { flow.0 += value } else { flow.1 -= value }; flowGroups[key] = flow
            }
        }
        var balanceGroups: [Date: Decimal] = [:]
        for entry in allPeriod {
            if let value = convert(entry.cents, source: entry.resolvedCurrency, target: target, rates: rates) { balanceGroups[bucket(entry.date), default: 0] += value }
        }
        var points: [StatisticsPoint] = [], running = opening
        var date = bucket(start)
        while date < end {
            if let current = running { running = current + (balanceGroups[date] ?? 0) }
            let flow = flowGroups[date] ?? (0, 0)
            points.append(StatisticsPoint(date: date, income: flow.0, expense: flow.1, balance: closing == nil ? nil : running))
            guard let next = calendar.date(byAdding: grain.component, value: 1, to: date), next > date else { break }
            date = next
        }
        let missing = Set(selected.filter { convert($0.cents, source: $0.resolvedCurrency, target: target, rates: rates) == nil }.map { $0.resolvedCurrency.rawValue }).sorted()
        let first = calendar.date(from: DateComponents(year: heatYear, month: 1, day: 1))!
        let nextYear = calendar.date(byAdding: .year, value: 1, to: first)!
        let prefix = (calendar.component(.weekday, from: first) + 5) % 7
        let totalDays = calendar.dateComponents([.day], from: first, to: nextYear).day!
        let yearEntries = entries.filter { $0.date >= first && $0.date < nextYear && $0.date < end && scope.includes($0) }
        let dayGroups = Dictionary(grouping: yearEntries) { calendar.startOfDay(for: $0.date) }
        var heatDays: [StatisticsHeatDay] = []
        let cellCount = ((prefix + totalDays + 6) / 7) * 7
        for index in 0..<cellCount {
            let offset = index - prefix
            guard offset >= 0 && offset < totalDays else { heatDays.append(StatisticsHeatDay(index: index, date: nil, count: 0)); continue }
            let day = calendar.date(byAdding: .day, value: offset, to: first)!
            let records = dayGroups[day] ?? []
            heatDays.append(StatisticsHeatDay(index: index, date: day, count: records.count, income: sum(records.filter { $0.cents > 0 }, target: target, rates: rates), expense: sum(records.filter { $0.cents < 0 }, target: target, rates: rates, absolute: true), future: day >= end))
        }
        return StatisticsReport(start: start, end: end, scope: scope, currency: target, grain: grain, entries: selected.sorted { $0.date > $1.date }, income: income, expense: expense, closingBalance: closing, points: points, incomeCategories: categories(incoming, target: target, rates: rates), expenseCategories: categories(outgoing, target: target, rates: rates), currencyFlows: categories(selected, target: target, rates: rates, byCurrency: true), missingCurrencies: missing, heatDays: heatDays, heatYear: heatYear, activeDays: dayGroups.count, heatCount: yearEntries.count)
    }
}

private let statisticsBlue = Color(red: 0.28, green: 0.43, blue: 0.60)
private let statisticsPalette = [Color(red: 0.28, green: 0.43, blue: 0.60), accent, Color(red: 0.48, green: 0.55, blue: 0.34), Color(red: 0.72, green: 0.57, blue: 0.28), Color(red: 0.57, green: 0.48, blue: 0.61)]
private func categoryColor(_ name: String) -> Color { statisticsPalette[name.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % statisticsPalette.count }] }

struct StatisticsView: View {
    @ObservedObject var model: Ledger
    @ObservedObject var state: StatisticsState
    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                if let report = state.report {
                LazyVStack(alignment: .leading, spacing: 20) {
                    Text(report.start.formatted(date: .numeric, time: .omitted) + " 至 " + report.end.addingTimeInterval(-1).formatted(date: .numeric, time: .omitted) + " · \(report.entries.count) 笔 · 金额统一折算为 " + report.currency.rawValue).font(.system(size: 11)).foregroundStyle(muted)
                    if !report.missingCurrencies.isEmpty {
                        Label("缺少 " + report.missingCurrencies.joined(separator: "、") + " 的折算汇率，请在设置中更新。金额图表暂不显示，笔数统计仍可使用。", systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(accent)
                    }
                    metrics(report)
                    StatisticsHeatmap(report: report, state: state, years: heatYears)
                    StatisticsTrend(report: report, state: state, balance: false)
                    HStack(alignment: .top, spacing: 20) {
                        if state.scope != .expense { StatisticsComposition(title: "入账分类占比", groups: report.incomeCategories, currency: report.currency, kind: state.pie, ready: report.income != nil) }
                        if state.scope != .income { StatisticsComposition(title: "出账分类占比", groups: report.expenseCategories, currency: report.currency, kind: state.pie, ready: report.expense != nil) }
                        if state.scope != .all { StatisticsComposition(title: "记账币种占比", groups: report.currencyFlows, currency: report.currency, kind: state.pie, ready: report.amountReady) }
                    }
                    StatisticsTrend(report: report, state: state, balance: true)
                    HStack(alignment: .top, spacing: 20) {
                        StatisticsRanking(title: state.scope == .income ? "入账分类金额" : (state.scope == .expense ? "出账分类金额" : "出账分类金额"), groups: state.scope == .income ? report.incomeCategories : report.expenseCategories, currency: report.currency, ready: state.scope == .income ? report.income != nil : report.expense != nil)
                        if state.scope == .all { StatisticsComposition(title: "记账币种占比", groups: report.currencyFlows, currency: report.currency, kind: state.pie, ready: report.amountReady) }
                        else { currencyAccounts(report) }
                    }
                    if state.scope == .all { currencyAccounts(report) }
                    details(report)
                    Text("来源：本机账目。金额图表按当前参考汇率折算，历史余额曲线也使用同一组汇率。热力图按所选整年统计笔数，不受上方日期范围影响。").font(.system(size: 10)).foregroundStyle(muted)
                    if model.preferences.automaticRates { Link("参考汇率：ExchangeRate-API", destination: URL(string: "https://www.exchangerate-api.com/docs/free")!).font(.system(size: 10)).foregroundStyle(accent) }
                }.padding(30).opacity(state.computing ? 0.55 : 1)
                } else { HStack { ProgressView().controlSize(.small); Text("正在汇总账目…").font(.system(size: 13)) }.padding(45).frame(maxWidth: .infinity) }
            }
        }.frame(minWidth: 900, minHeight: 620).background(paper).foregroundStyle(ink).preferredColorScheme(.light)
        .onAppear { state.refresh(model) }
        .onChange(of: model.entries) { _ in state.refresh(model) }
        .onChange(of: model.preferences) { _ in state.refresh(model) }
        .onChange(of: state.scope) { _ in state.refresh(model) }
        .onChange(of: state.period) { _ in state.refresh(model) }
        .onChange(of: state.grain) { _ in state.refresh(model) }
        .onChange(of: state.heatYear) { _ in state.refresh(model) }
    }
    var heatYears: [Int] {
        let current = Analytics.calendar.component(.year, from: Date())
        return Array(Set(model.entries.map { Analytics.calendar.component(.year, from: $0.date) } + [current, state.heatYear])).sorted(by: >)
    }
    var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                LedgerPageTitle(title: "账户统计", subtitle: "ACCOUNT STATISTICS")
                Spacer()
                if state.computing { ProgressView().controlSize(.mini) }
                Text(model.rateCaption).font(.system(size: 10)).foregroundStyle(muted)
                Button(model.fetchingRates ? "更新中…" : "更新汇率") { Task { await model.refreshRates(force: true) } }.font(.system(size: 11)).disabled(model.fetchingRates || !model.preferences.automaticRates)
            }
            HStack(spacing: 18) {
                HStack(spacing: 20) {
                    ForEach(StatisticsScope.allCases) { scope in
                        Button { state.scope = scope } label: {
                            Text(scope.rawValue).font(.system(size: 13, weight: scope == state.scope ? .semibold : .regular)).foregroundStyle(scope == state.scope ? ink : muted).padding(.vertical, 9).overlay(alignment: .bottom) { Rectangle().fill(scope == state.scope ? accent : .clear).frame(height: 2) }
                        }.buttonStyle(.plain).accessibilityLabel("统计范围 " + scope.rawValue)
                    }
                }.frame(width: 200, alignment: .leading)
                Picker("日期", selection: $state.period) { ForEach(StatisticsPeriod.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 155)
                Picker("粒度", selection: $state.grain) { ForEach(StatisticsGrain.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 132)
                Spacer(minLength: 0)
                Picker("显示币种", selection: $model.preferences.totalCurrency) { ForEach(Currency.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 145)
                Picker("占比图", selection: $state.pie) { ForEach(StatisticsPie.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 100).accessibilityLabel("占比图类型")
            }.font(.system(size: 11))
        }.padding(.horizontal, 30).padding(.top, 25).padding(.bottom, 14).background(paper).overlay(alignment: .bottom) { Rectangle().fill(ink.opacity(0.25)).frame(height: 1) }
    }
    func metrics(_ report: StatisticsReport) -> some View {
        HStack(spacing: 16) {
            metric("本期入账", value: report.income, detail: "\(report.entries.filter { $0.cents > 0 }.count) 笔", color: statisticsBlue)
            metric("本期出账", value: report.expense, detail: "\(report.entries.filter { $0.cents < 0 }.count) 笔", color: accent)
            metric("本期净额", value: report.net, detail: "入账 − 出账", color: ink)
            metric("期末账户总余额", value: report.closingBalance, detail: "截至期末的全部收支", color: ink)
        }
    }
    func metric(_ title: String, value: Decimal?, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
            Text(Analytics.money(value)).font(.custom("AnthropicSerifDisplay-Regular", size: 30)).foregroundStyle(color).monospacedDigit().lineLimit(1).minimumScaleFactor(0.4)
            Text(model.preferences.totalCurrency.rawValue + " · " + detail).font(.system(size: 10)).foregroundStyle(muted)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20).padding(.horizontal, 15).statisticsCard()
    }
    func currencyAccounts(_ report: StatisticsReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("各币种账户余额").font(.system(size: 14, weight: .semibold))
            Text("截至期末，保留原币金额；包含全部入账和出账。").font(.system(size: 10)).foregroundStyle(muted)
            ForEach(Currency.allCases) { unit in
                let records = model.entries.filter { $0.resolvedCurrency == unit && $0.date < report.end }
                let value = records.reduce(Int64(0)) { $0 + $1.cents }
                HStack { Text(unit.name + " " + unit.rawValue); Spacer(); Text(Amounts.format(value)).monospacedDigit(); Text("\(records.count) 笔").foregroundStyle(muted).frame(width: 45, alignment: .trailing) }.font(.system(size: 12))
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).statisticsCard()
    }
    func details(_ report: StatisticsReport) -> some View {
        DisclosureGroup("统计明细 · \(report.entries.count) 笔") {
            if report.entries.isEmpty { Text("所选范围没有账目。").foregroundStyle(muted).padding(15) }
            ForEach(report.entries) { entry in
                HStack(spacing: 14) {
                    Text(entry.date.formatted(date: .numeric, time: .shortened)).frame(width: 145, alignment: .leading)
                    Text(entry.resolvedCategory).frame(width: 80, alignment: .leading)
                    Text(entry.note.isEmpty ? (entry.cents > 0 ? "入账" : "出账") : entry.note).lineLimit(2)
                    Spacer()
                    Text(entry.resolvedCurrency.rawValue + " " + Amounts.format(entry.cents)).monospacedDigit()
                    Text("≈ " + Analytics.money(Analytics.convert(entry.cents, source: entry.resolvedCurrency, target: report.currency, rates: model.activeRates)) + " " + report.currency.rawValue).foregroundStyle(muted).monospacedDigit().frame(width: 180, alignment: .trailing)
                }.font(.system(size: 11)).textSelection(.enabled).padding(.vertical, 9)
                Divider()
            }
        }.font(.system(size: 13)).padding(20).statisticsCard()
    }
}

private extension View {
    func statisticsCard() -> some View { background(Color.white.opacity(0.48)).overlay(alignment: .top) { Rectangle().fill(ink.opacity(0.18)).frame(height: 1) } }
}

struct StatisticsTrend: View {
    var report: StatisticsReport
    @ObservedObject var state: StatisticsState
    var balance: Bool
    var kind: StatisticsChart { balance ? state.balanceChart : state.chart }
    var seriesNames: [String] { balance ? ["总余额"] : (report.scope == .all ? ["入账", "出账"] : [report.scope.rawValue]) }
    var seriesColors: [Color] { seriesNames.map { $0 == "入账" ? statisticsBlue : ($0 == "出账" ? accent : ink) } }
    var tickDates: [Date] {
        guard !report.points.isEmpty else { return [] }
        let last = report.points.count - 1
        return Array(Set((0...4).map { report.points[Int((Double(last) * Double($0) / 4).rounded())].date })).sorted()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(balance ? "账户总余额走势" : "收支走势").font(.system(size: 14, weight: .semibold))
                Text(report.currency.rawValue + " · " + report.grain.rawValue).font(.system(size: 10)).foregroundStyle(muted)
                Spacer()
                Picker("图表类型", selection: balance ? $state.balanceChart : $state.chart) { ForEach(StatisticsChart.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 110).accessibilityLabel(balance ? "余额图类型" : "收支图类型")
            }
            if !balance && report.entries.isEmpty { StatisticsEmpty(height: 235) }
            else if balance ? report.closingBalance != nil : report.amountReady {
                Chart {
                    ForEach(report.points) { point in
                        if balance { if let value = point.balance { marks(point.date, value, "总余额") } }
                        else {
                            if report.scope != .expense { marks(point.date, point.income, "入账") }
                            if report.scope != .income { marks(point.date, point.expense, "出账") }
                        }
                    }
                    RuleMark(y: .value("零", 0)).foregroundStyle(ink.opacity(0.15))
                }
                .chartForegroundStyleScale(domain: seriesNames, range: seriesColors)
                .chartYScale(domain: .automatic(includesZero: true))
                .chartXScale(domain: (report.points.first?.date ?? report.start)...report.end)
                .chartLegend(position: .top, alignment: .leading)
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
                .chartXAxis { AxisMarks(values: tickDates) { _ in AxisGridLine(); AxisTick(); AxisValueLabel(format: report.grain == .month ? .dateTime.year().month() : .dateTime.month().day()) } }
                .chartOverlay { proxy in StatisticsHoverOverlay(proxy: proxy, report: report, balance: balance) }.frame(height: 205)
                Text(balance ? "包含期初余额及全部收支；悬停查看金额。" : "无记账的日期显示为 0；悬停查看金额。").font(.system(size: 10)).foregroundStyle(muted).frame(height: 16, alignment: .leading)
            } else { StatisticsEmpty(text: "缺少折算汇率，请在设置中更新。", height: 235) }
        }.padding(20).statisticsCard()
    }
    @ChartContentBuilder func marks(_ date: Date, _ cents: Decimal, _ series: String) -> some ChartContent {
        let value = Analytics.chartValue(cents)
        switch kind {
        case .bar:
            BarMark(x: .value("日期", date), y: .value("金额", value)).foregroundStyle(by: .value("类型", series)).position(by: .value("类型", series))
        case .area:
            AreaMark(x: .value("日期", date), yStart: .value("零", 0.0), yEnd: .value("金额", value)).foregroundStyle(by: .value("类型", series)).opacity(0.16)
            LineMark(x: .value("日期", date), y: .value("金额", value)).foregroundStyle(by: .value("类型", series)).lineStyle(StrokeStyle(lineWidth: 2))
            PointMark(x: .value("日期", date), y: .value("金额", value)).foregroundStyle(by: .value("类型", series)).symbolSize(12)
        case .line:
            LineMark(x: .value("日期", date), y: .value("金额", value)).foregroundStyle(by: .value("类型", series)).lineStyle(StrokeStyle(lineWidth: 2, dash: series == "出账" ? [5, 3] : []))
            PointMark(x: .value("日期", date), y: .value("金额", value)).foregroundStyle(by: .value("类型", series)).symbolSize(12)
        }
    }
}

struct StatisticsEmpty: View {
    var text = "所选范围没有账目。"
    var height: CGFloat = 210
    var body: some View { VStack(spacing: 10) { Image(systemName: "chart.bar").font(.system(size: 23, weight: .light)); Text(text).font(.system(size: 12)) }.foregroundStyle(muted).frame(maxWidth: .infinity).frame(height: height) }
}

@MainActor final class StatisticsHover: ObservableObject {
    @Published var date: Date? = nil
    func select(_ date: Date?) { if self.date != date { self.date = date } }
}
struct StatisticsHoverOverlay: View {
    let proxy: ChartProxy
    let report: StatisticsReport
    let balance: Bool
    @StateObject private var hover = StatisticsHover()
    var body: some View {
        GeometryReader { geometry in
            let rect = geometry[proxy.plotAreaFrame]
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.clear).contentShape(Rectangle()).onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard rect.contains(location), let date = proxy.value(atX: location.x - rect.origin.x, as: Date.self) else { hover.select(nil); return }
                        let point = report.points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                        hover.select(point?.date)
                    case .ended: hover.select(nil)
                    }
                }
                if let date = hover.date, let point = report.points.first(where: { $0.date == date }), let x = proxy.position(forX: date) {
                    Path { path in path.move(to: CGPoint(x: rect.minX + x, y: rect.minY)); path.addLine(to: CGPoint(x: rect.minX + x, y: rect.maxY)) }.stroke(muted.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3])).allowsHitTesting(false)
                    Text(label(point)).font(.system(size: 10)).foregroundStyle(ink).padding(7).background(paper).offset(x: rect.minX + 7, y: rect.minY + 3).allowsHitTesting(false)
                }
            }
        }.onChange(of: report.start) { _ in hover.select(nil) }.onChange(of: report.scope) { _ in hover.select(nil) }
    }
    func label(_ point: StatisticsPoint) -> String {
        let date = point.date.formatted(date: .numeric, time: .omitted)
        let value = balance ? "总余额 " + Analytics.money(point.balance) : "入账 " + Analytics.money(point.income) + " · 出账 " + Analytics.money(point.expense)
        return date + " · " + value + " " + report.currency.rawValue
    }
}

struct StatisticsComposition: View {
    var title: String
    var groups: [StatisticsCategory]
    var currency: Currency
    var kind: StatisticsPie
    var ready: Bool
    var slices: [StatisticsCategory] { Analytics.slices(groups) }
    var total: Decimal { groups.reduce(0) { $0 + $1.cents } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 14, weight: .semibold))
            if ready && !groups.isEmpty && total > 0 {
                HStack(alignment: .center, spacing: 20) {
                    ZStack {
                        ForEach(Array(slices.enumerated()), id: \.element.id) { index, item in
                            let before = slices.prefix(index).reduce(Decimal(0)) { $0 + $1.cents }
                            PieWedge(start: NSDecimalNumber(decimal: before / total).doubleValue, end: NSDecimalNumber(decimal: (before + item.cents) / total).doubleValue, ring: kind == .donut)
                                .fill(categoryColor(item.name)).help(item.name + " · " + Analytics.money(item.cents) + " " + currency.rawValue + " · \(item.count) 笔").accessibilityLabel(item.name + " " + Analytics.money(item.cents) + " " + currency.rawValue)
                        }
                        if kind == .donut {
                            VStack(spacing: 5) { Text("合计").font(.system(size: 10)).foregroundStyle(muted); Text(Analytics.money(total)).font(.system(size: 17, weight: .medium, design: .rounded)).monospacedDigit().minimumScaleFactor(0.3).lineLimit(1); Text(currency.rawValue).font(.system(size: 9)).foregroundStyle(muted) }.padding(25)
                        }
                    }.frame(width: 155, height: 155)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(slices) { item in
                            let percent = NSDecimalNumber(decimal: item.cents / total * 100).doubleValue
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) { Circle().fill(categoryColor(item.name)).frame(width: 7, height: 7); Text(item.name).lineLimit(1); Spacer(minLength: 2); Text(String(format: "%.1f%%", percent)).monospacedDigit() }
                                Text(Analytics.money(item.cents) + " " + currency.rawValue).foregroundStyle(muted).monospacedDigit()
                            }.font(.system(size: 10)).help(item.name + " · \(item.count) 笔")
                        }
                    }.frame(maxWidth: .infinity)
                }.frame(height: 175)
                Text("按折算后的流水金额占比；\(groups.reduce(0) { $0 + $1.count }) 笔。").font(.system(size: 10)).foregroundStyle(muted)
                if groups.count > 5 {
                    DisclosureGroup("查看全部 \(groups.count) 个分类") { ForEach(groups) { item in HStack { Text(item.name); Spacer(); Text(Analytics.money(item.cents) + " " + currency.rawValue) }.font(.system(size: 10)).padding(.vertical, 4) } }.font(.system(size: 10)).foregroundStyle(muted)
                }
            } else { StatisticsEmpty(text: ready ? "所选范围没有这类账目。" : "等待完整汇率。", height: 201) }
        }.padding(20).frame(maxWidth: .infinity, alignment: .topLeading).statisticsCard()
    }
}

struct PieWedge: Shape {
    var start: Double
    var end: Double
    var ring: Bool
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY), radius = min(rect.width, rect.height) / 2
        let a = start * 360 - 90, b = end * 360 - 90
        var path = Path()
        if ring {
            path.addArc(center: center, radius: radius, startAngle: .degrees(a), endAngle: .degrees(b), clockwise: false)
            path.addArc(center: center, radius: radius * 0.68, startAngle: .degrees(b), endAngle: .degrees(a), clockwise: true)
        } else {
            path.move(to: center)
            path.addArc(center: center, radius: radius, startAngle: .degrees(a), endAngle: .degrees(b), clockwise: false)
        }
        path.closeSubpath(); return path
    }
}

struct StatisticsRanking: View {
    var title: String
    var groups: [StatisticsCategory]
    var currency: Currency
    var ready: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(title).font(.system(size: 14, weight: .semibold)); Spacer(); Text(currency.rawValue).font(.system(size: 10)).foregroundStyle(muted) }
            if ready && !groups.isEmpty {
                let visible = Analytics.slices(groups, limit: 8)
                Chart(visible) { item in
                    BarMark(x: .value("金额", Analytics.chartValue(item.cents)), y: .value("分类", item.name)).foregroundStyle(statisticsBlue)
                        .annotation(position: .trailing) { Text(Analytics.money(item.cents)).font(.system(size: 9)).foregroundStyle(muted) }
                }.chartXScale(domain: 0...max(1, (visible.map { Analytics.chartValue($0.cents) }.max() ?? 1) * 1.30)).frame(height: max(190, CGFloat(visible.count * 28)))
                if groups.count > 8 { Text("图中合并长尾分类；完整分类可在占比图中展开。").font(.system(size: 10)).foregroundStyle(muted) }
            } else { StatisticsEmpty(text: ready ? "所选范围没有这类账目。" : "等待完整汇率。", height: 190) }
        }.padding(20).frame(maxWidth: .infinity, alignment: .topLeading).statisticsCard()
    }
}

struct StatisticsHeatmap: View {
    var report: StatisticsReport
    @ObservedObject var state: StatisticsState
    var years: [Int]
    private let greens = [Color(red: 0.91, green: 0.92, blue: 0.91), Color(red: 0.61, green: 0.91, blue: 0.66), Color(red: 0.25, green: 0.77, blue: 0.39), Color(red: 0.19, green: 0.63, blue: 0.31), Color(red: 0.13, green: 0.43, blue: 0.22)]
    var columns: Int { report.heatDays.count / 7 }
    var maximum: Int { report.heatDays.map(\.count).max() ?? 0 }
    func level(_ count: Int) -> Int { count == 0 ? 0 : max(1, min(4, Int(ceil(Double(count) * 4 / Double(max(1, maximum)))))) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("记账热力图").font(.system(size: 14, weight: .semibold))
                Text(report.scope.rawValue + " · 每日笔数").font(.system(size: 10)).foregroundStyle(muted)
                Spacer()
                Picker("年份", selection: $state.heatYear) { ForEach(years, id: \.self) { Text(String($0)).tag($0) } }.labelsHidden().frame(width: 90).accessibilityLabel("热力图年份")
            }
            NativeStatisticsHeatmap(days: report.heatDays, currency: report.currency, year: report.heatYear).frame(height: 140)
            HStack {
                Text(String(report.heatYear) + " 年 · \(report.activeDays) 天有记录 · \(report.heatCount) 笔；悬停查看每日金额。")
                Spacer()
                Text("少")
                ForEach(0..<5, id: \.self) { index in RoundedRectangle(cornerRadius: 2).fill(greens[index]).frame(width: 10, height: 10) }
                Text("多")
            }.font(.system(size: 10)).foregroundStyle(muted)
        }.padding(20).statisticsCard()
    }
}

struct NativeStatisticsHeatmap: NSViewRepresentable {
    var days: [StatisticsHeatDay]
    var currency: Currency
    var year: Int
    func makeNSView(context: Context) -> StatisticsHeatmapDrawing { StatisticsHeatmapDrawing() }
    func updateNSView(_ view: StatisticsHeatmapDrawing, context: Context) { view.configure(days: days, currency: currency, year: year) }
}
final class StatisticsHeatmapDrawing: NSView {
    private var days: [StatisticsHeatDay] = []
    private var currency = Currency.cny
    private var year = 0
    private var labels: [String] = []
    private var levels: [Int] = []
    private var months: [(Int, String)] = []
    private var selected: Int? = nil
    private var tracking: NSTrackingArea?
    private let colors = [NSColor(calibratedRed: 0.91, green: 0.92, blue: 0.91, alpha: 1), NSColor(calibratedRed: 0.61, green: 0.91, blue: 0.66, alpha: 1), NSColor(calibratedRed: 0.25, green: 0.77, blue: 0.39, alpha: 1), NSColor(calibratedRed: 0.19, green: 0.63, blue: 0.31, alpha: 1), NSColor(calibratedRed: 0.13, green: 0.43, blue: 0.22, alpha: 1)]
    override var isFlipped: Bool { true }
    private var pitch: CGFloat { min(16, max(10, (bounds.width - 30) / CGFloat(max(1, days.count / 7)))) }
    func configure(days: [StatisticsHeatDay], currency: Currency, year: Int) {
        guard self.days != days || self.currency != currency || self.year != year else { return }
        self.days = days; self.currency = currency; self.year = year; selected = nil
        let maximum = max(1, days.map(\.count).max() ?? 1)
        levels = days.map { $0.count == 0 ? 0 : min(4, max(1, Int(ceil(Double($0.count) * 4 / Double(maximum))))) }
        months = days.compactMap { day in
            guard let date = day.date, Analytics.calendar.component(.day, from: date) == 1 else { return nil }
            return (day.index / 7, String(Analytics.calendar.component(.month, from: date)) + "月")
        }
        labels = days.map { day in
            guard let date = day.date else { return "" }
            let title = date.formatted(date: .numeric, time: .omitted)
            if day.future { return title + " · 尚未到来" }
            return title + " · \(day.count) 笔\n入账 \(Analytics.money(day.income)) · 出账 \(Analytics.money(day.expense)) \(currency.rawValue)"
        }
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel(String(year) + " 年记账热力图，\(days.filter { $0.count > 0 }.count) 个活跃日，\(days.reduce(0) { $0 + $1.count }) 笔")
        setAccessibilityValue(days.filter { $0.count > 0 }.map { labels[$0.index] }.joined(separator: "；"))
        needsDisplay = true
    }
    private func cellRect(_ index: Int) -> NSRect { NSRect(x: 24 + CGFloat(index / 7) * pitch, y: 22 + CGFloat(index % 7) * pitch, width: pitch - 3, height: pitch - 3) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]
        for (column, month) in months { (month as NSString).draw(at: NSPoint(x: 24 + CGFloat(column) * pitch, y: 1), withAttributes: attributes) }
        for (row, title) in [(0, "一"), (2, "三"), (4, "五")] { (title as NSString).draw(at: NSPoint(x: 1, y: 22 + CGFloat(row) * pitch), withAttributes: attributes) }
        for day in days where day.date != nil {
            let rect = cellRect(day.index)
            guard rect.intersects(dirtyRect) else { continue }
            colors[levels[day.index]].withAlphaComponent(day.future ? 0.3 : 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
            if selected == day.index { NSColor.labelColor.withAlphaComponent(0.5).setStroke(); let line = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5)); line.lineWidth = 1; line.stroke() }
        }
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let column = Int(floor((point.x - 24) / pitch)), row = Int(floor((point.y - 22) / pitch))
        let index = column * 7 + row
        let next = column >= 0 && row >= 0 && row < 7 && index >= 0 && index < days.count && days[index].date != nil ? index : nil
        guard next != selected else { return }
        selected = next; toolTip = next.map { labels[$0] }; needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { selected = nil; toolTip = nil; needsDisplay = true }
}

func statisticsTests() throws {
    func expect(_ value: Bool, _ name: String) { if !value { fatalError("Statistics: " + name) } }
    var calendar = Calendar(identifier: .gregorian); calendar.firstWeekday = 2; calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    func date(_ year: Int, _ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))! }
    let now = date(2024, 3, 2)
    let rates: [String: Decimal] = ["USD": 1, "CNY": 7, "HKD": Decimal(string: "7.8")!, "EUR": Decimal(string: "0.9")!, "TWD": 32]
    let entries = [
        Entry(cents: 500, note: "", date: date(2023, 12, 31), currency: .cny),
        Entry(cents: 10000, note: "", date: date(2024, 1, 1), currency: .cny, category: "工资"),
        Entry(cents: 1000, note: "", date: date(2024, 2, 1), currency: .usd, category: "项目收入"),
        Entry(cents: -2000, note: "", date: date(2024, 2, 20), currency: .cny, category: "餐饮"),
        Entry(cents: 7800, note: "", date: date(2024, 3, 1), currency: .hkd, category: "项目收入"),
        Entry(cents: -3200, note: "", date: date(2024, 3, 2), currency: .twd, category: "交通"),
        Entry(cents: 999, note: "未来", date: date(2024, 3, 3), currency: .cny)
    ]
    func report(_ scope: StatisticsScope = .all, period: StatisticsPeriod = .month, grain: StatisticsGrain = .auto, rates custom: [String: Decimal]? = nil, year: Int = 2024) -> StatisticsReport {
        Analytics.build(entries: entries, target: .cny, rates: custom ?? rates, scope: scope, period: period, grain: grain, heatYear: year, now: now, calendar: calendar)
    }
    let all = report()
    expect(all.entries.count == 3 && all.points.count == 30, "30-day bounds and zero-filled buckets")
    expect(all.income == 7000 && all.expense == 2700 && all.net == 4300, "converted income expense net")
    expect(all.closingBalance == 21800 && all.points.first?.balance == 17500 && all.points.last?.balance == 21800, "opening and closing balance")
    expect(all.heatCount == 5 && all.activeDays == 5, "annual heatmap independent of period")
    expect(all.heatDays.compactMap(\.date).count == 366, "leap year includes all dates")
    expect(all.heatDays.contains { $0.date.map { calendar.component(.month, from: $0) == 2 && calendar.component(.day, from: $0) == 29 } == true }, "February 29")
    expect(all.heatDays.contains { $0.count == 1 }, "activity cells")
    expect(all.expenseCategories.reduce(0) { $0 + $1.cents } == all.expense, "expense categories reconcile")
    expect(all.incomeCategories.first?.name == "项目收入" && all.incomeCategories.first?.cents == 7000, "income category")
    expect(all.currencyFlows.reduce(0) { $0 + $1.cents } == 9700, "currency pie uses positive gross amounts")
    let outgoing = report(.expense)
    expect(outgoing.entries.count == 2 && outgoing.income == 0 && outgoing.expense == 2700, "expense filtering")
    expect(outgoing.closingBalance == 21800 && outgoing.heatCount == 2, "account balance independent of scope, heatmap follows scope")
    let incoming = report(.income)
    expect(incoming.entries.count == 1 && incoming.expense == 0 && incoming.heatCount == 3, "income filtering")
    let missing = report(rates: ["USD": 1, "CNY": 7])
    expect(!missing.amountReady && missing.closingBalance == nil && missing.missingCurrencies == ["HKD", "TWD"], "missing-rate guard")
    expect(missing.heatCount == 5, "counts work without rates")
    expect(report(period: .year).entries.count == 5, "year boundary excludes previous and future year dates")
    let weekly = report(grain: .week)
    expect(weekly.points.last?.balance == 21800 && weekly.points.reduce(0) { $0 + $1.income } == 7000, "weekly aggregation")
    let monthly = report(period: .year, grain: .month)
    expect(monthly.points.count == 3 && monthly.points.last?.balance == 21800, "monthly aggregation")
    expect(report(year: 2012).heatDays.count == 378 && report(year: 2012).heatDays.compactMap(\.date).count == 366, "54-week layout")
    expect(Entry(cents: 1, note: "").resolvedCategory == "未分类", "legacy category")
    let categories = (1...12).map { StatisticsCategory(name: "分类\($0)", cents: Decimal($0), count: 1) }.sorted { $0.cents > $1.cents }
    let slices = Analytics.slices(categories)
    expect(slices.count == 5 && slices.reduce(0) { $0 + $1.cents } == 78 && slices.reduce(0) { $0 + $1.count } == 12, "pie tail grouping preserves totals")
    let empty = Analytics.build(entries: [], target: .usd, rates: [:], scope: .all, period: .month, grain: .auto, heatYear: 2024, now: now, calendar: calendar)
    expect(empty.entries.isEmpty && empty.income == 0 && empty.expense == 0 && empty.heatCount == 0, "empty journal")
    let encoded = try JSONEncoder().encode(entries)
    let decoded = try JSONDecoder().decode([Entry].self, from: encoded)
    expect(decoded == entries && decoded[1].resolvedCategory == "工资", "category round trip")
    print("PASS: statistics filters, currencies, opening balance, categories, time buckets, year boundaries, leap day, 54-week heatmap, empty states, missing rates")
}

func statisticsBenchmark() {
    let now = Date(), calendar = Analytics.calendar
    let rates: [String: Decimal] = ["USD": 1, "CNY": 7, "HKD": Decimal(string: "7.8")!, "EUR": Decimal(string: "0.9")!, "TWD": 32]
    for count in [1, 10000] {
        let entries = (0..<count).map { index in
            Entry(cents: Int64((index % 500 + 1) * (index % 3 == 0 ? -100 : 100)), note: "性能测试", date: calendar.date(byAdding: .day, value: -(index % 365), to: now)!, currency: Currency.allCases[index % 5], category: "分类\(index % 8)")
        }
        var timings: [Double] = []
        for _ in 0..<5 {
            let start = ProcessInfo.processInfo.systemUptime
            let report = Analytics.build(entries: entries, target: .cny, rates: rates, scope: .all, period: .all, grain: .auto, heatYear: calendar.component(.year, from: now), now: now)
            timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            precondition(report.entries.count == count && report.closingBalance != nil)
        }
        print("Synthetic benchmark: \(count) entries, average \(String(format: "%.2f", timings.reduce(0, +) / Double(timings.count))) ms, maximum \(String(format: "%.2f", timings.max()!)) ms; report calculation runs on background queue in app.")
    }
}
