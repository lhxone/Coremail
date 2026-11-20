import EventKit
import SwiftUI

/// Middle column of the calendar section: month picker and calendar source.
struct CalendarPane: View {
    @ObservedObject var agenda: Agenda
    let hasAccount: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CalendarMonthPicker(day: $agenda.day)
            if hasAccount {
                VStack(alignment: .leading, spacing: 6) {
                    Text("日历来源").font(.caption).foregroundStyle(.secondary)
                    Picker("日历来源", selection: $agenda.source) {
                        Text("全部").tag(Agenda.Source.both)
                        Text("系统").tag(Agenda.Source.system)
                        Text("邮箱").tag(Agenda.Source.server)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

private struct CalendarMonthPicker: View {
    @Binding var day: Date
    @State private var displayedMonth = Date()
    private let calendar = Calendar.current

    var body: some View {
        let month = calendar.dateInterval(of: .month, for: displayedMonth)?.start ?? displayedMonth
        let first = calendar.dateInterval(of: .weekOfYear, for: month)?.start ?? month
        let focus = calendar.dateInterval(of: .weekOfYear, for: day)?.start
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        VStack(spacing: 7) {
            HStack {
                Button("上个月", systemImage: "chevron.left") { step(-1, from: month) }
                    .labelStyle(.iconOnly)
                Spacer()
                Text(month.formatted(.dateTime.year().month(.wide))).font(.subheadline.weight(.semibold))
                Spacer()
                Button("下个月", systemImage: "chevron.right") { step(1, from: month) }
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            HStack(spacing: 0) {
                ForEach(0..<7) { index in
                    Text(symbols[(calendar.firstWeekday - 1 + index) % symbols.count])
                        .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(0..<6) { row in
                let beginning = calendar.date(byAdding: .day, value: row * 7, to: first)
                HStack(spacing: 0) {
                    ForEach(0..<7) { column in
                        if let date = calendar.date(byAdding: .day, value: row * 7 + column, to: first) {
                            dateButton(date, in: month)
                        }
                    }
                }
                .background {
                    if beginning == focus { Capsule().fill(Color.accentColor.opacity(0.15)) }
                }
            }
        }
        .onAppear { displayedMonth = day }
        .onChange(of: day) { _, date in displayedMonth = date }
    }

    private func dateButton(_ date: Date, in month: Date) -> some View {
        let selected = calendar.isDate(date, inSameDayAs: day)
        let inMonth = calendar.isDate(date, equalTo: month, toGranularity: .month)
        return Button { day = date } label: {
            Text(calendar.component(.day, from: date), format: .number).font(.caption.monospacedDigit())
                .foregroundStyle(selected ? .white : inMonth ? .primary : .secondary)
                .frame(width: 23, height: 23)
                .background { if selected { Circle().fill(Color.accentColor) } }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func step(_ months: Int, from month: Date) {
        displayedMonth = calendar.date(byAdding: .month, value: months, to: month) ?? month
    }
}

struct AgendaView: View {
    let account: Account?
    let password: (Account) throws -> String
    @ObservedObject var agenda: Agenda
    let relatedMail: (AgendaEvent) async -> [RelatedMail]
    let openRelatedMail: (RelatedMail) async -> Void
    @State private var entry: Entry?
    @State private var selectedEvent: AgendaEvent?
    @State private var remoteCalendars: [ServerCalendar] = []
    @State private var remoteEvents: [AgendaEvent] = []
    @State private var remoteCalendar: ServerCalendar?
    @State private var loading = false
    @State private var problem: String?
    @State private var reloadID = UUID()
    @AppStorage("calendarWeekLayout") private var layout: WeekLayout = .merged

    private enum WeekLayout: String, CaseIterable {
        case merged, split
        var title: String { self == .merged ? "合并" : "分栏" }
    }

    private var showSystem: Bool { agenda.source != .server || account == nil }
    private var showServer: Bool { agenda.source != .system && account != nil }
    private var serverName: String { remoteCalendar?.name ?? "邮箱日历" }

    private var panels: [WeekTimeline.Panel] {
        var panels: [WeekTimeline.Panel] = []
        if showSystem {
            panels.append(.init(id: "system", title: "系统日历", color: .indigo, events: agenda.events))
        }
        if showServer {
            panels.append(.init(id: "server", title: serverName, color: .teal, events: remoteEvents))
        }
        if layout == .split && panels.count > 1 { return panels }
        return [.init(id: "merged", title: panels.map(\.title).joined(separator: " · "),
                      color: .accentColor, events: panels.flatMap(\.events))]
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if showSystem && !agenda.hasAccess {
                HStack {
                    Label("系统日历尚未授权", systemImage: "calendar.badge.exclamationmark")
                    Spacer()
                    Button("允许访问…") { Task { await agenda.askAccess() } }
                }
                .font(.callout)
                .padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
            }
            if let error = (showServer ? problem : nil) ?? (showSystem ? agenda.error : nil) {
                Text(error).foregroundStyle(.orange).font(.caption).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            WeekTimeline(week: agenda.week, selectedDay: agenda.day, panels: panels,
                         selectDay: { agenda.day = $0 }, selectEvent: { selectedEvent = $0 })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if showSystem { agenda.reload() } }
        .onChange(of: agenda.week.start) { _, _ in
            if showSystem { agenda.reload() }
            remoteEvents = []
            reloadID = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            if showSystem { agenda.reload() }
        }
        .onChange(of: agenda.source) { _, _ in
            if showSystem { agenda.reload() }
            reloadID = UUID()
        }
        .onChange(of: remoteCalendar) { old, _ in
            if old != nil { remoteEvents = []; reloadID = UUID() }
        }
        .task(id: reloadID) { if showServer { await refreshServer() } }
        .sheet(item: $entry) { entry in
            EventEditor(entry: entry) { entry in
                if entry.source == .system {
                    try agenda.create(title: entry.title, location: entry.location, start: entry.start, end: entry.end)
                } else if let remoteCalendar {
                    try await dav().create(in: remoteCalendar, title: entry.title, location: entry.location,
                                           start: entry.start, end: entry.end)
                    reloadID = UUID()
                } else { throw MailError("请选择一个可写的日历。") }
            }
        }
        .sheet(item: $selectedEvent) { event in
            AgendaEventDetail(event: event, loadMail: relatedMail) { result in
                selectedEvent = nil
                Task { await openRelatedMail(result) }
            }
        }
    }

    private var controls: some View {
        let calendar = Calendar.current
        let last = calendar.date(byAdding: .day, value: -1, to: agenda.week.end) ?? agenda.day
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("今天") { agenda.day = calendar.startOfDay(for: .now) }
                Button("前一周", systemImage: "chevron.left") { moveWeek(-7) }.labelStyle(.iconOnly)
                Button("下一周", systemImage: "chevron.right") { moveWeek(7) }.labelStyle(.iconOnly)
                Text(agenda.week.start.formatted(.dateTime.year().month().day()) + " – " +
                     last.formatted(.dateTime.month().day()))
                    .font(.headline).lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Picker("布局", selection: $layout) {
                    ForEach(WeekLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityLabel("日历布局")
                Menu {
                    if showSystem && agenda.hasAccess {
                        Button("系统日历") { entry = Entry(day: agenda.day, source: .system) }
                    }
                    if showServer && remoteCalendar?.canCreate == true {
                        Button(serverName) { entry = Entry(day: agenda.day, source: .server) }
                    }
                } label: {
                    Label("新建日程", systemImage: "plus").labelStyle(.iconOnly)
                }
                .fixedSize()
                .disabled(!(showSystem && agenda.hasAccess) && !(showServer && remoteCalendar?.canCreate == true))
                .help("新建日程")
            }
            if showServer {
                HStack(spacing: 8) {
                    if !remoteCalendars.isEmpty {
                        Picker("邮箱日历", selection: $remoteCalendar) {
                            ForEach(remoteCalendars) { Text($0.name).tag(Optional($0)) }
                        }
                        .fixedSize()
                    } else if !loading && problem == nil {
                        Text("没有可用的邮箱日历").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("刷新邮箱日历", systemImage: "arrow.clockwise") { reloadID = UUID() }
                        .labelStyle(.iconOnly).disabled(loading)
                    if loading { ProgressView().controlSize(.small).accessibilityLabel("正在读取邮箱日历") }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func moveWeek(_ days: Int) {
        agenda.day = Calendar.current.date(byAdding: .day, value: days, to: agenda.day) ?? agenda.day
    }

    private func dav() throws -> CalDAV {
        guard let account else { throw MailError("请先添加邮箱账户。") }
        return try CalDAV(account: account, password: password(account))
    }

    private func refreshServer() async {
        loading = true
        problem = nil
        defer { if !Task.isCancelled { loading = false } }
        do {
            let client = try dav()
            if remoteCalendars.isEmpty {
                let calendars = try await client.calendars()
                guard !Task.isCancelled else { return }
                remoteCalendars = calendars
                remoteCalendar = calendars.first
            }
            guard let calendar = remoteCalendar else { return }
            let week = agenda.week
            let events = try await client.events(in: calendar, from: week.start, to: week.end)
            if !Task.isCancelled { remoteEvents = events }
        } catch {
            if !Task.isCancelled { problem = error.localizedDescription }
        }
    }

    struct Entry: Identifiable {
        let id = UUID()
        var title = ""
        var location = ""
        var start: Date
        var end: Date
        let source: Agenda.Source

        init(day: Date, source: Agenda.Source) {
            self.source = source
            start = Calendar.current.isDateInToday(day) ? Date() :
                Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
            end = start.addingTimeInterval(3600)
        }
    }
}

private struct AgendaEventDetail: View {
    @Environment(\.dismiss) private var dismiss
    let event: AgendaEvent
    let loadMail: (AgendaEvent) async -> [RelatedMail]
    let openMail: (RelatedMail) -> Void
    @State private var related: [RelatedMail]?

    var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(event.title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Label(event.calendar, systemImage: "calendar")
                    if event.allDay {
                        Label("全天 · " + event.start.formatted(date: .abbreviated, time: .omitted), systemImage: "clock")
                    } else {
                        Label("\(event.start.formatted(date: .abbreviated, time: .shortened)) – \(event.end.formatted(date: .abbreviated, time: .shortened))",
                              systemImage: "clock")
                    }
                    if !event.location.isEmpty { Label(event.location, systemImage: "mappin") }
                    Divider()
                    Text("关联邮件").font(.headline)
                    if let related {
                        if related.isEmpty {
                            Text("未找到关联邮件").foregroundStyle(.secondary)
                        } else {
                            ForEach(related) { result in
                                Button {
                                    openMail(result)
                                } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "envelope")
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(result.row.subject)
                                                .lineLimit(2)
                                                .fixedSize(horizontal: false, vertical: true)
                                            Text(result.exact ? "原始邮件 · " + result.row.from : result.row.from)
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.up.right").font(.caption)
                                    }
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else {
                        ProgressView("正在查找关联邮件…").controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 470)
        .task(id: event.id) {
            let matches = await loadMail(event)
            if !Task.isCancelled { related = matches }
        }
    }
}

private struct EventEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var entry: AgendaView.Entry
    let save: (AgendaView.Entry) async throws -> Void
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建日程").font(.title2.weight(.semibold))
            Form {
                TextField("标题", text: $entry.title)
                TextField("地点", text: $entry.location)
                DatePicker("开始", selection: $entry.start)
                DatePicker("结束", selection: $entry.end)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("添加到日历") {
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try await save(entry); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430)
        .disabled(saving)
        .interactiveDismissDisabled(saving)
    }
}
