import AppKit
import SwiftUI

/// Lays out children left to right and wraps them onto new rows, keeping each child's natural size.
struct WrapLayout: Layout {
    var spacing: CGFloat = 0
    var lineSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (index, size) in zip(row.indices, row.sizes) {
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width && !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            row.sizes.append(size)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// A name in the reader header. Clicking it shows the person card.
struct PersonChip: View {
    @ObservedObject var store: MailStore
    let address: MailAddress
    var prominent = false
    var separator = ""
    @State private var showCard = false
    @State private var hovering = false

    var body: some View {
        let address = store.displayingAccountName(for: self.address)
        HStack(spacing: 0) {
            Button { showCard = true } label: {
                Text(address.display)
                    .font(prominent ? .headline : .callout)
                    .foregroundStyle(Color.primary)
                    .underline(hovering, color: .secondary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(address.full)
            .popover(isPresented: $showCard, arrowEdge: .bottom) {
                PersonCard(store: store, address: address) { showCard = false }
            }
            .contextMenu {
                Button("发信", systemImage: "square.and.pencil") { store.compose(to: address) }
                Button("拷贝邮箱地址", systemImage: "doc.on.doc") { copy(address.email) }
                Button("拷贝姓名和地址") { copy(address.full) }
            }
            if !separator.isEmpty {
                Text(separator).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct PersonCard: View {
    @ObservedObject var store: MailStore
    let address: MailAddress
    let close: () -> Void

    private var known: RecentContact? {
        store.recentContacts.first { $0.email.caseInsensitiveCompare(address.email) == .orderedSame }
    }

    @State private var showMore = false

    private var isSelf: Bool {
        store.account?.email.caseInsensitiveCompare(address.email) == .orderedSame
    }

    var body: some View {
        let address = store.displayingAccountName(for: self.address)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                Avatar(address: address, size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(address.name.isEmpty ? (known?.name.isEmpty == false ? known!.name : address.email) : address.name)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    Text(address.email).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                cardButton("往来邮件") { close(); store.showMail(with: address.email) }
                cardButton("详情") { close(); store.showContact(address) }
                cardButton("发信") { close(); store.compose(to: address) }
                cardButton("更多") { showMore = true }
                    .popover(isPresented: $showMore, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            moreItem("拷贝邮箱地址", "doc.on.doc") { copy(address.email) }
                            moreItem("拷贝姓名和地址", "person.text.rectangle") { copy(address.full) }
                        }
                        .padding(6)
                        .frame(width: 180)
                    }
            }
            .controlSize(.large)
            if !isSelf {
                FreeBusyView(store: store, address: address)
            }
        }
        .padding(18)
        .frame(width: 400)
    }

    private var subtitle: String {
        if isSelf { return "我自己" }
        return known == nil ? "（未分组联系人）" : "往来联系人"
    }

    private func moreItem(_ title: String, _ icon: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button {
            showMore = false
            action()
        } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func cardButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity) }
            .frame(maxWidth: .infinity)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Upcoming busy times of a contact, read from the mail server's CalDAV scheduling service.
struct FreeBusyView: View {
    @ObservedObject var store: MailStore
    let address: MailAddress
    @State private var state: Phase = .loading

    enum Phase { case loading, loaded([DateInterval]), failed(String) }

    private static var cache: [String: (date: Date, phase: Phase)] = [:]
    static let dayStartHour = 8, dayEndHour = 20

    /// The next five working days, starting today.
    static func days(from now: Date = Date(), calendar: Calendar = .current) -> [Date] {
        var output: [Date] = []
        var day = calendar.startOfDay(for: now)
        while output.count < 5 {
            if !calendar.isDateInWeekend(day) { output.append(day) }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        }
        return output
    }

    /// First free slot of at least 30 minutes between 9:00 and 18:00 after `now`.
    static func firstFree(busy: [DateInterval], days: [Date], now: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
        for day in days {
            guard var cursor = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day),
                  let close = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day) else { continue }
            if cursor < now {
                // Round up to the next half hour.
                let minutes = calendar.component(.minute, from: now)
                let base = calendar.date(bySetting: .second, value: 0, of: now) ?? now
                cursor = calendar.date(byAdding: .minute, value: minutes % 30 == 0 ? 0 : 30 - minutes % 30, to: base) ?? now
            }
            for period in busy.sorted(by: { $0.start < $1.start }) where period.end > cursor && period.start < close {
                if period.start.timeIntervalSince(cursor) >= 1800 { return DateInterval(start: cursor, end: period.start) }
                cursor = max(cursor, period.end)
            }
            if close.timeIntervalSince(cursor) >= 1800 { return DateInterval(start: cursor, end: close) }
        }
        return nil
    }

    /// Shown only when the server returns free/busy data; otherwise the card stays compact.
    var body: some View {
        Group {
            if case .loaded(let busy) = state {
                let days = Self.days()
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    HStack(alignment: .firstTextBaseline) {
                        if let free = Self.firstFree(busy: busy, days: days) {
                            Text("最近空闲：" + Self.describe(free)).font(.callout)
                        } else {
                            Text("未来 5 个工作日没有 30 分钟以上的空闲").font(.callout)
                        }
                        Spacer()
                        HStack(spacing: 10) {
                            legend(Color.red.opacity(0.75), "忙碌")
                            legend(Color.green.opacity(0.35), "空闲")
                        }
                    }
                    VStack(spacing: 4) {
                        ForEach(days, id: \.self) { day in dayRow(day, busy: busy) }
                        hourScale
                    }
                }
            }
        }
        .task(id: address.email.lowercased()) { await load() }
    }

    private func legend(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 8)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func dayRow(_ day: Date, busy: [DateInterval]) -> some View {
        let calendar = Calendar.current
        let open = calendar.date(bySettingHour: Self.dayStartHour, minute: 0, second: 0, of: day) ?? day
        let close = calendar.date(bySettingHour: Self.dayEndHour, minute: 0, second: 0, of: day) ?? day
        let span = close.timeIntervalSince(open)
        let segments = busy.compactMap { $0.intersection(with: DateInterval(start: open, end: close)) }
        let past = calendar.isDateInToday(day) ? min(max(0, Date().timeIntervalSince(open)), span) : 0
        return HStack(spacing: 8) {
            Text(calendar.isDateInToday(day) ? "今天" : calendar.isDateInTomorrow(day) ? "明天" : day.formatted(.dateTime.weekday(.abbreviated)))
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.green.opacity(0.22))
                    if past > 0 {
                        Rectangle().fill(Color.secondary.opacity(0.18)).frame(width: width * past / span)
                    }
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        Rectangle().fill(Color.red.opacity(0.75))
                            .frame(width: max(2, width * segment.duration / span))
                            .offset(x: width * segment.start.timeIntervalSince(open) / span)
                            .help(Self.describe(segment))
                    }
                }
                .clipShape(.rect(cornerRadius: 3))
            }
            .frame(height: 12)
        }
    }

    private var hourScale: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 34, height: 1)
            GeometryReader { proxy in
                let hours = Array(stride(from: Self.dayStartHour, through: Self.dayEndHour, by: 4))
                ForEach(hours, id: \.self) { hour in
                    Text("\(hour)")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: proxy.size.width * Double(hour - Self.dayStartHour) / Double(Self.dayEndHour - Self.dayStartHour),
                                  y: 6)
                }
            }
            .frame(height: 12)
        }
    }

    static func describe(_ interval: DateInterval, calendar: Calendar = .current) -> String {
        let day = calendar.isDateInToday(interval.start) ? "今天"
            : calendar.isDateInTomorrow(interval.start) ? "明天"
            : interval.start.formatted(.dateTime.month().day().weekday(.abbreviated))
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        return "\(day) \(interval.start.formatted(time))–\(interval.end.formatted(time))"
    }

    private func load() async {
        let key = address.email.lowercased()
        if let cached = Self.cache[key], Date().timeIntervalSince(cached.date) < 300 {
            state = cached.phase
            return
        }
        state = .loading
        guard let account = store.account else { state = .failed("请先添加邮箱账户。"); return }
        let days = Self.days()
        let calendar = Calendar.current
        let start = max(Date(), calendar.date(bySettingHour: Self.dayStartHour, minute: 0, second: 0, of: days[0]) ?? Date())
        let end = calendar.date(bySettingHour: Self.dayEndHour, minute: 0, second: 0, of: days[days.count - 1]) ?? start
        let phase: Phase
        do {
            let client = try CalDAV(account: account, password: store.password(for: account))
            phase = .loaded(try await client.freeBusy(attendee: address.email, organizer: account.email, from: start, to: end))
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
        Self.cache[key] = (Date(), phase)
        state = phase
    }
}
