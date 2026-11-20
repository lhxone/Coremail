import AppKit
import EventKit
import Foundation

struct ContactChoice: Identifiable, Hashable {
    var id: String { email.lowercased() }
    let name: String
    let email: String
}

struct AgendaEvent: Identifiable {
    let id: String
    let title: String
    let location: String
    let calendar: String
    let start: Date
    let end: Date
    let allDay: Bool
    var sourceURL: URL?
    var sourceMessageID: String? {
        guard let sourceURL, sourceURL.scheme?.lowercased() == "message" else { return nil }
        return MailHTML.canonicalContentID(String(sourceURL.absoluteString.dropFirst("message:".count))
            .replacingOccurrences(of: #"^//"#, with: "", options: .regularExpression))
    }
}

@MainActor
final class Agenda: ObservableObject {
    private let store = EKEventStore()
    @Published private(set) var events: [AgendaEvent] = []
    @Published private(set) var hasAccess = false
    @Published var error: String?
    @Published var day = Calendar.current.startOfDay(for: Date())
    @Published var source: Source = .both

    enum Source: Hashable { case system, server, both }

    var week: DateInterval {
        Calendar.current.dateInterval(of: .weekOfYear, for: day)
            ?? DateInterval(start: day, duration: 7 * 24 * 60 * 60)
    }

    func askAccess() async {
        do {
            hasAccess = try await store.requestFullAccessToEvents()
            if hasAccess { reload() }
            else { error = "请在系统设置的「隐私与安全性 → 日历」中授权。" }
        } catch { self.error = error.localizedDescription }
    }

    func reload() {
        hasAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard hasAccess else { events = []; return }
        let interval = week
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }.map { event in
            AgendaEvent(id: "\(event.eventIdentifier ?? "")/\(event.startDate.timeIntervalSince1970)",
                        title: event.title ?? "未命名日程", location: event.location ?? "",
                        calendar: event.calendar.title, start: event.startDate,
                        end: event.endDate, allDay: event.isAllDay, sourceURL: event.url)
        }
    }

    func create(title: String, location: String, start: Date, end: Date) throws {
        guard let calendar = store.defaultCalendarForNewEvents, start < end,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MailError("请填写标题、有效的开始和结束时间，并确认系统日历可写。")
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.location = location
        event.startDate = start
        event.endDate = end
        event.calendar = calendar
        try store.save(event, span: .thisEvent)
        reload()
    }
}
