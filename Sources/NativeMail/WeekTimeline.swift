import SwiftUI

struct WeekTimeline: View {
    struct Panel: Identifiable {
        let id: String
        let title: String
        let color: Color
        let events: [AgendaEvent]
    }

    let week: DateInterval
    let selectedDay: Date
    let panels: [Panel]
    let selectDay: (Date) -> Void
    let selectEvent: (AgendaEvent) -> Void

    private let calendar = Calendar.current
    private let hourHeight: CGFloat = 52
    private let rulerWidth: CGFloat = 48
    private let panelSpacing: CGFloat = 12

    private var days: [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week.start) }
    }

    var body: some View {
        let dates = days
        let data = panels.map { panel in
            dates.map { DaySchedule(day: $0, events: panel.events, calendar: calendar) }
        }
        let allDayRows = min(3, max(1, data.flatMap { $0 }.map { $0.allDay.count }.max() ?? 0))
        GeometryReader { geometry in
            let gaps = CGFloat(max(0, panels.count - 1)) * panelSpacing
            let width = max(panels.count > 1 ? 425 : 508, (geometry.size.width - gaps) / CGFloat(max(1, panels.count)))
            let contentWidth = width * CGFloat(panels.count) + gaps
            ScrollView(.horizontal) {
                ScrollViewReader { scroll in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            Section {
                                HStack(alignment: .top, spacing: panelSpacing) {
                                    ForEach(panels.indices, id: \.self) { index in
                                        timeGrid(schedules: data[index], width: width, anchors: index == 0)
                                    }
                                }
                            } header: {
                                VStack(alignment: .leading, spacing: 0) {
                                    HStack(alignment: .top, spacing: panelSpacing) {
                                        ForEach(panels.indices, id: \.self) { index in
                                            panelHeader(panels[index], schedules: data[index],
                                                        allDayRows: allDayRows, width: width)
                                        }
                                    }
                                    Divider()
                                }
                                .background(Color(nsColor: .windowBackgroundColor))
                            }
                        }
                        .frame(width: contentWidth, alignment: .leading)
                    }
                    .contentMargins(.horizontal, 0, for: .scrollContent)
                    .scrollIndicators(.hidden, axes: .vertical)
                    .onAppear {
                        let hour = week.contains(.now) ? max(0, calendar.component(.hour, from: .now) - 2) : 8
                        scroll.scrollTo(hour, anchor: .top)
                    }
                }
                .frame(width: contentWidth, height: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func panelHeader(_ panel: Panel, schedules: [DaySchedule], allDayRows: Int, width: CGFloat) -> some View {
        let dayWidth = (width - rulerWidth) / CGFloat(max(1, schedules.count))
        return VStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(panel.color).frame(width: 7, height: 7)
                Text(panel.title).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(height: 28)
            .background(panel.color.opacity(0.08))
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(TimeZone.current.abbreviation() ?? "")
                        .frame(height: 47, alignment: .center)
                    Text("全天")
                        .frame(height: CGFloat(allDayRows * 22 + 6), alignment: .top)
                }
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.trailing, 5)
                .frame(width: rulerWidth, alignment: .trailing)
                ForEach(schedules) { schedule in
                    VStack(spacing: 0) {
                        dayHeading(schedule.day)
                        allDayItems(schedule.allDay, rows: allDayRows)
                    }
                    .frame(width: dayWidth)
                    .background(dayBackground(schedule.day))
                    .overlay(alignment: .leading) { Divider() }
                }
            }
        }
        .frame(width: width)
    }

    private func dayHeading(_ day: Date) -> some View {
        let selected = calendar.isDate(day, inSameDayAs: selectedDay)
        return Button { selectDay(day) } label: {
            VStack(spacing: 1) {
                Text(day.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.caption).foregroundStyle(.secondary)
                Text(day.formatted(.dateTime.day()))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(selected || calendar.isDateInToday(day) ? Color.accentColor : .primary)
            }
            .frame(maxWidth: .infinity).frame(height: 47)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.09) : .clear)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func allDayItems(_ events: [AgendaEvent], rows: Int) -> some View {
        let overflowing = events.count > rows
        let shown = overflowing ? rows - 1 : rows
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(events.prefix(shown)) { event in
                eventButton(event, expanded: false)
                    .frame(height: 20)
            }
            if overflowing {
                Menu {
                    ForEach(events.dropFirst(shown)) { event in
                        Button(event.title) { selectEvent(event) }
                    }
                } label: {
                    Text("另有 \(events.count - shown) 项")
                        .font(.caption2)
                }
                .menuStyle(.borderlessButton)
                .frame(height: 20)
            }
        }
        .padding(.horizontal, 3).padding(.top, 3)
        .frame(maxWidth: .infinity)
        .frame(height: CGFloat(rows * 22 + 6), alignment: .top)
    }

    private func timeGrid(schedules: [DaySchedule], width: CGFloat, anchors: Bool) -> some View {
        let dayWidth = (width - rulerWidth) / CGFloat(max(1, schedules.count))
        return HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(0..<24) { hour in
                    Text(String(format: "%02d:00", hour))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .padding(.trailing, 5)
                        .frame(width: rulerWidth, height: hourHeight, alignment: .topTrailing)
                        .id(anchors ? hour : hour + 24)
                }
            }
            HStack(spacing: 0) {
                ForEach(schedules) { schedule in
                    ZStack(alignment: .topLeading) {
                        Color.clear
                        ForEach(schedule.timed) { item in
                            let laneWidth = dayWidth / CGFloat(item.laneCount)
                            let height = max(16, CGFloat(item.end - item.start) * hourHeight / 60 - 2)
                            eventButton(item.event, expanded: height >= 38)
                                .frame(width: max(1, laneWidth - 4), height: height)
                                .offset(x: CGFloat(item.lane) * laneWidth + 2,
                                        y: CGFloat(item.start) * hourHeight / 60 + 1)
                        }
                    }
                    .frame(width: dayWidth, height: 24 * hourHeight)
                    .clipped()
                }
            }
            .background {
                ZStack {
                    Color(nsColor: .textBackgroundColor)
                    HStack(spacing: 0) {
                        ForEach(schedules) { schedule in
                            dayBackground(schedule.day).frame(width: dayWidth)
                        }
                    }
                    gridLines(columns: schedules.count)
                }
                .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                if let today = schedules.firstIndex(where: { calendar.isDateInToday($0.day) }) {
                    TimelineView(.periodic(from: .now, by: 60)) { tick in
                        if calendar.isDate(tick.date, inSameDayAs: schedules[today].day) {
                            let minute = calendar.component(.hour, from: tick.date) * 60 +
                                calendar.component(.minute, from: tick.date)
                            Rectangle().fill(Color.accentColor)
                                .frame(width: dayWidth, height: 1)
                                .overlay(alignment: .leading) { Circle().fill(Color.accentColor).frame(width: 5, height: 5) }
                                .offset(x: CGFloat(today) * dayWidth, y: CGFloat(minute) * hourHeight / 60)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(width: width, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func dayBackground(_ day: Date) -> Color {
        if calendar.isDateInToday(day) { return Color.accentColor.opacity(0.045) }
        if calendar.isDateInWeekend(day) { return Color.secondary.opacity(0.065) }
        return Color(nsColor: .textBackgroundColor)
    }

    private func gridLines(columns: Int) -> some View {
        Canvas { context, size in
            var path = Path()
            for hour in 0...24 {
                let y = CGFloat(hour) * hourHeight
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            for column in 0...columns {
                let x = CGFloat(column) * size.width / CGFloat(max(1, columns))
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(path, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
            var halfHours = Path()
            for hour in 0..<24 {
                let y = (CGFloat(hour) + 0.5) * hourHeight
                halfHours.move(to: CGPoint(x: 0, y: y))
                halfHours.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(halfHours, with: .color(.secondary.opacity(0.12)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        }
    }

    private func eventButton(_ event: AgendaEvent, expanded: Bool) -> some View {
        let colors: [Color] = [.teal, .indigo, .purple, .blue, .orange, .pink, .green]
        let index = event.calendar.unicodeScalars.reduce(UInt32(0)) { $0 &* 31 &+ $1.value }
        let color = colors[Int(index % UInt32(colors.count))]
        return Button { selectEvent(event) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.caption.weight(.semibold)).lineLimit(expanded ? 2 : 1)
                if expanded {
                    Text(event.start.formatted(date: .omitted, time: .shortened))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(color.opacity(0.19), in: .rect(cornerRadius: 4))
            .overlay(alignment: .leading) {
                Capsule().fill(color).frame(width: 3).padding(.vertical, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(event.title + (event.location.isEmpty ? "" : "\n" + event.location))
    }
}

struct DaySchedule: Identifiable {
    var id: Date { day }
    let day: Date
    let allDay: [AgendaEvent]
    let timed: [Item]

    struct Item: Identifiable {
        var id: String { event.id + "|" + event.calendar }
        let event: AgendaEvent
        let start: Int
        let end: Int
        let lane: Int
        var laneCount: Int = 1
    }

    init(day: Date, events: [AgendaEvent], calendar: Calendar) {
        self.day = day
        let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        let matching = events.filter { $0.start < next && $0.end > day }
        allDay = matching.filter(\.allDay)
        func minute(_ date: Date) -> Int {
            if date <= day { return 0 }
            if date >= next { return 1440 }
            return calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        }

        var results: [Item] = []
        var group: [Item] = []
        var laneEnds: [Int] = []
        func flush() {
            results += group.map { item in
                var item = item
                item.laneCount = laneEnds.count
                return item
            }
            group.removeAll(keepingCapacity: true)
            laneEnds.removeAll(keepingCapacity: true)
        }
        for event in matching.filter({ !$0.allDay }).sorted(by: { $0.start < $1.start }) {
            let start = minute(event.start)
            let end = max(start + 1, minute(event.end))
            if laneEnds.allSatisfy({ $0 <= start }) { flush() }
            let lane = laneEnds.firstIndex { $0 <= start } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(end) } else { laneEnds[lane] = end }
            group.append(Item(event: event, start: start, end: end, lane: lane))
        }
        flush()
        timed = results
    }
}
