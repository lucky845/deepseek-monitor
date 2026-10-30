import WidgetKit
import SwiftUI

let appGroupID = "group.com.deepseekmonitor.deepseekMonitor"

struct WidgetSnapshot: Decodable {
    let connected: Bool
    let balance: Double?
    let granted: Double?
    let todayCost: Double?
    let monthCost: Double?
    let requests: Int?
    let cacheHitRate: Double?
    let dailyAvg: Double?
    let daysLeft: Double?
    let trend: [TrendPoint]
    let updatedAt: Int?
    
    struct TrendPoint: Decodable {
        let c: Double
        let r: Int?
        let t: Int
    }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date(), snapshot: nil)
    }
    
    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) {
        completion(SimpleEntry(date: Date(), snapshot: loadSnapshot()))
    }
    
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let entry = SimpleEntry(date: Date(), snapshot: loadSnapshot())
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
    
    func loadSnapshot() -> WidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return nil }
        guard let jsonString = defaults.string(forKey: "widget_snapshot") else { return nil }
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct DeepSeekWidgetEntryView: View {
    var entry: Provider.Entry
    @Environment(\.widgetFamily) var family
    
    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        case .systemMedium:
            MediumWidgetView(entry: entry)
        case .systemLarge:
            LargeWidgetView(entry: entry)
        default:
            SmallWidgetView(entry: entry)
        }
    }
}

struct SmallWidgetView: View {
    let entry: SimpleEntry
    
    var body: some View {
        ZStack {
            Color(red: 0.075, green: 0.102, blue: 0.18).opacity(0.933)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("DeepSeek")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(red: 0.541, green: 0.576, blue: 0.659))
                    Spacer()
                    Text(entry.snapshot?.connected == true ? "● 已连接" : "● 示例")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(entry.snapshot?.connected == true ? Color(red: 0.063, green: 0.725, blue: 0.506) : Color(red: 0.851, green: 0.627, blue: 0.212))
                }
                Spacer()
                Text(balanceText)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Color(red: 0.902, green: 0.918, blue: 0.949))
                    .minimumScaleFactor(0.6)
                Text("余额")
                    .font(.system(size: 9))
                    .foregroundColor(Color(red: 0.541, green: 0.576, blue: 0.659))
                Spacer()
                Text(todayText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(todayColor)
            }
            .padding(12)
        }
    }
    
    var balanceText: String {
        guard let snapshot = entry.snapshot, snapshot.connected else { return "—" }
        guard let balance = snapshot.balance else { return "—" }
        return String(format: "¥%.2f", balance)
    }
    
    var todayText: String {
        guard let snapshot = entry.snapshot, snapshot.connected else { return "打开应用连接" }
        guard let today = snapshot.todayCost else { return "打开应用看看" }
        if today <= 0 { return "今天还没花钱" }
        return String(format: "今日 ¥%.2f", today)
    }
    
    var todayColor: Color {
        guard let snapshot = entry.snapshot,
              snapshot.connected,
              let today = snapshot.todayCost,
              let daily = snapshot.dailyAvg,
              daily > 0,
              today >= daily * 1.5 else {
            return Color(red: 0.486, green: 0.541, blue: 0.655)
        }
        return Color(red: 0.851, green: 0.627, blue: 0.212)
    }
}

struct MediumWidgetView: View {
    let entry: SimpleEntry
    
    var body: some View {
        ZStack {
            Color(red: 0.075, green: 0.102, blue: 0.18).opacity(0.933)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("DeepSeek 用量")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(red: 0.902, green: 0.918, blue: 0.949))
                    Spacer()
                    Text(entry.snapshot?.connected == true ? "● 已连接" : "● 示例")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(entry.snapshot?.connected == true ? Color(red: 0.063, green: 0.725, blue: 0.506) : Color(red: 0.851, green: 0.627, blue: 0.212))
                }
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(balanceText)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(Color(red: 0.902, green: 0.918, blue: 0.949))
                        Text("余额")
                            .font(.system(size: 8))
                            .foregroundColor(Color(red: 0.541, green: 0.576, blue: 0.659))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(todayText)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(todayColor)
                        Text("今日")
                            .font(.system(size: 8))
                            .foregroundColor(Color(red: 0.541, green: 0.576, blue: 0.659))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(requestsText)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(red: 0.902, green: 0.918, blue: 0.949))
                        Text("本月请求")
                            .font(.system(size: 8))
                            .foregroundColor(Color(red: 0.541, green: 0.576, blue: 0.659))
                    }
                }
                Spacer()
                if let updated = updatedLabel {
                    Text(updated)
                        .font(.system(size: 8))
                        .foregroundColor(Color(red: 0.333, green: 0.380, blue: 0.478))
                }
            }
            .padding(12)
        }
    }
    
    var balanceText: String {
        guard let snapshot = entry.snapshot, snapshot.connected else { return "—" }
        guard let balance = snapshot.balance else { return "—" }
        return String(format: "¥%.2f", balance)
    }
    
    var todayText: String {
        guard let snapshot = entry.snapshot, snapshot.connected else { return "—" }
        guard let today = snapshot.todayCost else { return "—" }
        if today <= 0 { return "¥0.00" }
        return String(format: "¥%.2f", today)
    }
    
    var requestsText: String {
        guard let snapshot = entry.snapshot, snapshot.connected else { return "—" }
        guard let req = snapshot.requests else { return "—" }
        if req >= 1000000 { return String(format: "%.1fM", Double(req) / 1000000.0) }
        if req >= 1000 { return String(format: "%.1fK", Double(req) / 1000.0) }
        return "\(req)"
    }
    
    var todayColor: Color {
        guard let snapshot = entry.snapshot,
              snapshot.connected,
              let today = snapshot.todayCost,
              let daily = snapshot.dailyAvg,
              daily > 0,
              today >= daily * 1.5 else {
            return Color(red: 0.914, green: 0.933, blue: 0.973)
        }
        return Color(red: 0.851, green: 0.627, blue: 0.212)
    }
    
    var updatedLabel: String? {
        guard let snapshot = entry.snapshot, let updatedAt = snapshot.updatedAt, updatedAt > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(updatedAt) / 1000.0)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "zh_CN")
        return "更新于 " + formatter.string(from: date)
    }
}

struct LargeWidgetView: View {
    let entry: SimpleEntry
    
    var body: some View {
        ZStack {
            Color(red: 0.075, green: 0.102, blue: 0.18).opacity(0.933)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("DeepSeek 用量监控")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(red: 0.902, green: 0.918, blue: 0.949))
                    Spacer()
                    Text(entry.snapshot?.connected == true ? "● 已连接" : "● 示例")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(entry.snapshot?.connected == true ? Color(red: 0.063, green: 0.725, blue: 0.506) : Color(red: 0.851, green: 0.627, blue: 0.212))
                }
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(balanceText)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(Color(red: 0.902, green: 0.918, blue: 0.949))
                            .minimumScaleFactor(0.5)
                        Text("余额")
                            .font(.system(size: 9))
                            .foregroundColor(Color(red: 0.541, green: 0.576, blue: 0.659))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(todayText)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(todayColor)
                        Text("今日消费")
                            .font(.system(size: 9))
                            .foregroundColor(Color(red: 0.541, green: 0.576, blue: 0.659))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(monthText)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(Color(red: 0.902, green: 0.918, blue: 0.949))
                        Text("本月消费")
                            .font(.system(size: 9))
                            .foregroundColor(Color(red: 0.541, green: 0.576, blue: 0.659))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(requestsText)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(Color(red: 0.902, green: 0.918, blue: 0.949))
                        Text("本月请求")
                            .font(.system(size: 9))
                            .foregroundColor(Color(red: 0.541, green: 0.576, blue: 0.659))
                    }
                }
                Spacer()
                if let updated = updatedLabel {
                    Text(updated)
                        .font(.system(size: 9))
                        .foregroundColor(Color(red: 0.333, green: 0.380, blue: 0.478))
                }
            }
            .padding(14)
        }
    }
    
    var balanceText: String {
        guard let snapshot = entry.snapshot, snapshot.connected else { return "—" }
        guard let balance = snapshot.balance else { return "—" }
        return String(format: "¥%.2f", balance)
    }
    
    var todayText: String {
        guard let snapshot = entry.snapshot, snapshot.connected else { return "—" }
        guard let today = snapshot.todayCost else { return "—" }
        if today <= 0 { return "¥0.00" }
        return String(format: "¥%.2f", today)
    }
    
    var monthText: String {
        guard let snapshot = entry.snapshot, snapshot.connected else { return "—" }
        guard let month = snapshot.monthCost else { return "—" }
        return String(format: "¥%.2f", month)
    }
    
    var requestsText: String {
        guard let snapshot = entry.snapshot, snapshot.connected else { return "—" }
        guard let req = snapshot.requests else { return "—" }
        if req >= 1000000 { return String(format: "%.1fM", Double(req) / 1000000.0) }
        if req >= 1000 { return String(format: "%.1fK", Double(req) / 1000.0) }
        return "\(req)"
    }
    
    var todayColor: Color {
        guard let snapshot = entry.snapshot,
              snapshot.connected,
              let today = snapshot.todayCost,
              let daily = snapshot.dailyAvg,
              daily > 0,
              today >= daily * 1.5 else {
            return Color(red: 0.914, green: 0.933, blue: 0.973)
        }
        return Color(red: 0.851, green: 0.627, blue: 0.212)
    }
    
    var updatedLabel: String? {
        guard let snapshot = entry.snapshot, let updatedAt = snapshot.updatedAt, updatedAt > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(updatedAt) / 1000.0)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "zh_CN")
        return "更新于 " + formatter.string(from: date)
    }
}

@main
struct DeepSeekWidget: Widget {
    let kind: String = "DeepSeekWidget"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            DeepSeekWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("DeepSeek 用量")
        .description("查看 DeepSeek 余额、今日消费和用量统计")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
