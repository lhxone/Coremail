import Foundation

struct ServerCalendar: Identifiable, Hashable {
    let url: URL
    let name: String
    let canCreate: Bool

    var id: URL { url }
}

struct CalDAV {
    private let http: ServerHTTP
    private let dav = "DAV:"
    private let caldav = "urn:ietf:params:xml:ns:caldav"

    init(account: Account, password: String) throws {
        http = try ServerHTTP(account: account, password: password)
    }

    func calendars() async throws -> [ServerCalendar] {
        let wellKnown = try http.resolve("/.well-known/caldav")
        let (initial, discovered) = try await properties(wellKnown, depth: 0, fields: """
            <d:current-user-principal/><c:calendar-home-set/>
            """, followRedirects: true)
        let homes: [URL]
        let listed = Self.references(initial, name: "calendar-home-set", namespace: caldav)
        if !listed.isEmpty {
            homes = try listed.map { try http.resolve($0, relativeTo: discovered) }
        } else {
            guard let principalPath = Self.references(initial, name: "current-user-principal", namespace: dav).first else {
                throw MailError("服务器没有返回这个账号的日历地址。")
            }
            let principal = try http.resolve(principalPath, relativeTo: discovered)
            let (result, endpoint) = try await properties(principal, depth: 0, fields: "<c:calendar-home-set/>",
                                                          followRedirects: true)
            homes = try Self.references(result, name: "calendar-home-set", namespace: caldav)
                .map { try http.resolve($0, relativeTo: endpoint) }
        }
        guard !homes.isEmpty else { throw MailError("服务器没有提供日历集合。") }
        var calendars: [ServerCalendar] = []
        var seen = Set<URL>()
        for home in Array(Set(homes)).prefix(15) {
            let (result, endpoint) = try await properties(home, depth: 1, fields: """
                <d:resourcetype/><d:displayname/><d:current-user-privilege-set/><c:supported-calendar-component-set/>
                """, followRedirects: true)
            for response in result.children(named: "response", namespace: dav) {
                let fields = Self.successfulProperties(response)
                guard fields.first(where: { $0.isNamed("resourcetype", dav) })?.child("calendar", caldav) != nil,
                      let resource = response.child("href", dav)?.text,
                      let url = try? http.resolve(resource, relativeTo: endpoint), seen.insert(url).inserted else { continue }
                if let types = fields.first(where: { $0.isNamed("supported-calendar-component-set", caldav) }),
                   !types.children.contains(where: { $0.isNamed("comp", caldav) && $0.attributes["name"] == "VEVENT" }) {
                    continue
                }
                let title = fields.first(where: { $0.isNamed("displayname", dav) })?.text ?? ""
                let privileges = fields.first(where: { $0.isNamed("current-user-privilege-set", dav) })
                let canCreate = privileges?.children(named: "privilege", namespace: dav).contains { privilege in
                    privilege.children.contains { $0.namespace == dav && ["all", "write", "bind"].contains($0.name) }
                } ?? true
                calendars.append(ServerCalendar(url: url, name: title.isEmpty ? url.lastPathComponent : title,
                                                canCreate: canCreate))
            }
        }
        return calendars.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func events(in calendar: ServerCalendar, from start: Date, to end: Date) async throws -> [AgendaEvent] {
        let first = CalendarFile.timestamp(start)
        let last = CalendarFile.timestamp(end)
        let report = """
            <?xml version="1.0" encoding="utf-8"?>
            <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
              <d:prop><c:calendar-data><c:expand start="\(first)" end="\(last)"/></c:calendar-data></d:prop>
              <c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">
                <c:time-range start="\(first)" end="\(last)"/>
              </c:comp-filter></c:comp-filter></c:filter>
            </c:calendar-query>
            """
        let (response, _) = try await multistatus("REPORT", to: calendar.url, depth: 1, body: report,
                                                   followRedirects: true)
        return response.children(named: "response", namespace: dav).flatMap { item in
            let fields = Self.successfulProperties(item)
            guard let ics = fields.first(where: { $0.isNamed("calendar-data", caldav) })?.text else {
                return [AgendaEvent]()
            }
            return CalendarFile.events(ics, calendar: calendar, from: start, to: end)
        }.sorted { $0.start < $1.start }
    }

    func create(in calendar: ServerCalendar, title: String, location: String, start: Date, end: Date) async throws {
        guard calendar.canCreate else { throw MailError("这个服务器日历为只读。") }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, start < end else {
            throw MailError("请填写标题和有效的起止时间。")
        }
        let id = UUID().uuidString.lowercased()
        let url = calendar.url.appendingPathComponent(id + ".ics", isDirectory: false)
        let event = CalendarFile.event(uid: id, title: title, location: location, start: start, end: end)
        let (_, response) = try await http.request("PUT", to: url, headers: [
            "Content-Type": "text/calendar; charset=utf-8",
            "If-None-Match": "*"
        ], body: event)
        guard (200...299).contains(response.statusCode) else { throw failure(response.statusCode) }
    }

    /// Asks the server's scheduling outbox (RFC 6638) when `attendee` is busy.
    func freeBusy(attendee: String, organizer: String, from start: Date, to end: Date) async throws -> [DateInterval] {
        guard MailAddress.isValid(attendee), MailAddress.isValid(organizer) else { throw MailError("邮箱地址无效。") }
        let outbox = try await scheduleOutbox()
        let stamp = CalendarFile.timestamp(Date())
        let lines = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Coremail for macOS//CN", "METHOD:REQUEST",
            "BEGIN:VFREEBUSY", "UID:\(UUID().uuidString)", "DTSTAMP:\(stamp)",
            "DTSTART:\(CalendarFile.timestamp(start))", "DTEND:\(CalendarFile.timestamp(end))",
            "ORGANIZER:mailto:\(organizer)", "ATTENDEE:mailto:\(attendee)",
            "END:VFREEBUSY", "END:VCALENDAR", ""
        ]
        let (data, response) = try await http.request("POST", to: outbox, headers: [
            "Content-Type": "text/calendar; charset=utf-8",
            "Originator": "mailto:\(organizer)",
            "Recipient": "mailto:\(attendee)"
        ], body: Data(lines.joined(separator: "\r\n").utf8), followRedirects: true)
        switch response.statusCode {
        case 200...299: break
        case 401, 403: throw MailError("邮箱服务器未允许查询他人的忙闲时间。")
        case 404, 405, 501: throw MailError("邮箱服务器拒绝了忙闲查询（HTTP \(response.statusCode)）。")
        default: throw failure(response.statusCode)
        }
        return try Self.busyPeriods(in: data, from: start, to: end)
    }

    /// Reads the busy periods from a CalDAV schedule-response, or from a bare VFREEBUSY reply.
    static func busyPeriods(in data: Data, from start: Date, to end: Date) throws -> [DateInterval] {
        var calendars: [String] = []
        if let root = try? DAVElement.read(data), root.isNamed("schedule-response", "urn:ietf:params:xml:ns:caldav") {
            for item in root.children(named: "response", namespace: "urn:ietf:params:xml:ns:caldav") {
                let status = item.child("request-status", "urn:ietf:params:xml:ns:caldav")?.text ?? "2.0"
                guard status.hasPrefix("2.") else {
                    if status.hasPrefix("3.7") { throw MailError("服务器找不到这位联系人的日历。") }
                    throw MailError("服务器没有返回这位联系人的忙闲时间（\(status.prefix(40))）。")
                }
                if let ics = item.child("calendar-data", "urn:ietf:params:xml:ns:caldav")?.text { calendars.append(ics) }
            }
        } else if let text = String(data: data, encoding: .utf8), text.contains("BEGIN:VFREEBUSY") {
            calendars.append(text)
        }
        guard !calendars.isEmpty else { throw MailError("服务器没有返回忙闲数据。") }
        let window = DateInterval(start: start, end: max(start, end))
        var busy: [DateInterval] = []
        for ics in calendars {
            let unfolded = ics.replacingOccurrences(of: "\r\n ", with: "").replacingOccurrences(of: "\n ", with: "")
            for line in unfolded.components(separatedBy: .newlines) where line.uppercased().hasPrefix("FREEBUSY") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let parameters = line[..<colon].uppercased()
                if parameters.contains("FBTYPE=FREE") { continue }
                for period in line[line.index(after: colon)...].split(separator: ",") {
                    let parts = period.split(separator: "/", maxSplits: 1).map(String.init)
                    guard parts.count == 2, let begin = utc(parts[0]) else { continue }
                    let finish = parts[1].hasPrefix("P") || parts[1].hasPrefix("+P")
                        ? CalendarFile.duration(parts[1], from: begin) : utc(parts[1])
                    guard let finish, finish > begin,
                          let clipped = DateInterval(start: begin, end: finish).intersection(with: window),
                          clipped.duration > 0 else { continue }
                    busy.append(clipped)
                }
            }
        }
        // Merge overlapping periods.
        var merged: [DateInterval] = []
        for item in busy.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, item.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, item.end))
            } else {
                merged.append(item)
            }
        }
        return merged
    }

    private static func utc(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.date(from: value.trimmingCharacters(in: .whitespaces).uppercased())
    }

    private func scheduleOutbox() async throws -> URL {
        let wellKnown = try http.resolve("/.well-known/caldav")
        let (initial, discovered) = try await properties(wellKnown, depth: 0, fields: """
            <d:current-user-principal/><c:schedule-outbox-URL/>
            """, followRedirects: true)
        if let path = Self.references(initial, name: "schedule-outbox-URL", namespace: caldav).first {
            return try http.resolve(path, relativeTo: discovered)
        }
        guard let principalPath = Self.references(initial, name: "current-user-principal", namespace: dav).first else {
            throw MailError("邮箱服务器没有开放日历服务。")
        }
        let principal = try http.resolve(principalPath, relativeTo: discovered)
        let (result, endpoint) = try await properties(principal, depth: 0, fields: "<c:schedule-outbox-URL/>",
                                                      followRedirects: true)
        guard let path = Self.references(result, name: "schedule-outbox-URL", namespace: caldav).first else {
            throw MailError("邮箱服务器的日历未开放忙闲查询（CalDAV 没有提供日程调度地址）。")
        }
        return try http.resolve(path, relativeTo: endpoint)
    }

    private func properties(_ url: URL, depth: Int, fields: String,
                            followRedirects: Bool) async throws -> (DAVElement, URL) {
        let request = """
            <?xml version="1.0" encoding="utf-8"?>
            <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
              <d:prop>\(fields)</d:prop>
            </d:propfind>
            """
        return try await multistatus("PROPFIND", to: url, depth: depth, body: request, followRedirects: followRedirects)
    }

    private func multistatus(_ method: String, to url: URL, depth: Int, body: String,
                             followRedirects: Bool) async throws -> (DAVElement, URL) {
        let (data, response) = try await http.request(method, to: url,
                                                     headers: ["Depth": String(depth),
                                                               "Content-Type": "application/xml; charset=utf-8"],
                                                     body: Data(body.utf8), followRedirects: followRedirects)
        guard response.statusCode == 207 else { throw failure(response.statusCode) }
        let root = try DAVElement.read(data)
        guard root.isNamed("multistatus", dav) else { throw MailError("服务器返回了无法读取的日历数据。") }
        return (root, response.url ?? url)
    }

    private func failure(_ status: Int) -> MailError {
        switch status {
        case 401, 403: return MailError("服务器日历拒绝访问。请检查账号的 CalDAV 权限（HTTP \(status)）。")
        default: return MailError("服务器日历请求失败（HTTP \(status)）。")
        }
    }

    private static func successfulProperties(_ response: DAVElement) -> [DAVElement] {
        response.children(named: "propstat", namespace: "DAV:").flatMap { entry -> [DAVElement] in
            guard let status = entry.child("status", "DAV:")?.text.split(whereSeparator: \.isWhitespace),
                  status.count > 1, let number = Int(status[1]), (200...299).contains(number),
                  let prop = entry.child("prop", "DAV:") else { return [] }
            return prop.children
        }
    }

    private static func references(_ response: DAVElement, name: String, namespace: String) -> [String] {
        response.children(named: "response", namespace: "DAV:")
            .flatMap(successfulProperties)
            .filter { $0.isNamed(name, namespace) }
            .flatMap { $0.children(named: "href", namespace: "DAV:").map(\.text) }
    }
}

final class DAVElement {
    let name: String
    let namespace: String
    let attributes: [String: String]
    var content = ""
    var children: [DAVElement] = []
    var text: String { content.trimmingCharacters(in: .whitespacesAndNewlines) }

    init(name: String, namespace: String, attributes: [String: String]) {
        self.name = name
        self.namespace = namespace
        self.attributes = attributes
    }

    func isNamed(_ name: String, _ namespace: String) -> Bool { self.name == name && self.namespace == namespace }
    func child(_ name: String, _ namespace: String) -> DAVElement? {
        children.first { $0.isNamed(name, namespace) }
    }

    func children(named name: String, namespace: String) -> [DAVElement] {
        children.filter { $0.isNamed(name, namespace) }
    }

    static func read(_ data: Data) throws -> DAVElement {
        let parser = XMLParser(data: data)
        let reader = Reader()
        parser.delegate = reader
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = reader.root else { throw MailError("服务器返回了无效的 DAV 文档。") }
        return root
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var root: DAVElement?
        var stack: [DAVElement] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            guard stack.count < 32 else { parser.abortParsing(); return }
            let element = DAVElement(name: elementName, namespace: namespaceURI ?? "", attributes: attributeDict)
            if let parent = stack.last { parent.children.append(element) }
            else { root = element }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.content += string }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.content += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            _ = stack.popLast()
        }
    }
}

enum CalendarFile {
    static func timestamp(_ date: Date) -> String {
        formatter("yyyyMMdd'T'HHmmss'Z'", zone: TimeZone(secondsFromGMT: 0)!).string(from: date)
    }

    static func events(_ text: String, calendar: ServerCalendar, from start: Date, to end: Date) -> [AgendaEvent] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"\n[ \t]"#, with: "", options: .regularExpression)
            .split(separator: "\n")
        var fields: [String: (parameters: [Substring], value: String)] = [:]
        var nesting = 0
        var output: [AgendaEvent] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let descriptor = line[..<colon].split(separator: ";")
            guard let kind = descriptor.first?.uppercased() else { continue }
            let parameters = Array(descriptor.dropFirst())
            let value = String(line[line.index(after: colon)...])
            if kind == "BEGIN" {
                if nesting > 0 { nesting += 1 }
                else if value.uppercased() == "VEVENT" {
                    nesting = 1
                    fields.removeAll(keepingCapacity: true)
                }
            } else if kind == "END" && nesting > 0 {
                nesting -= 1
                if nesting == 0, value.uppercased() == "VEVENT",
                   let time = fields["DTSTART"], let begin = parseDate(time.value, parameters: time.parameters),
                   fields["STATUS"]?.value.uppercased() != "CANCELLED" {
                    let allDay = time.value.count == 8
                    let finish = fields["DTEND"].flatMap { parseDate($0.value, parameters: $0.parameters) }
                        ?? fields["DURATION"].flatMap { duration($0.value, from: begin) }
                        ?? (allDay ? Calendar.current.date(byAdding: .day, value: 1, to: begin) : begin) ?? begin
                    if begin < end && (finish > start || (finish == begin && begin >= start)) {
                        let id = fields["UID"]?.value ?? UUID().uuidString
                        let title = fields["SUMMARY"].map { unescape($0.value) } ?? "未命名日程"
                        let location = fields["LOCATION"].map { unescape($0.value) } ?? ""
                        output.append(AgendaEvent(id: "\(calendar.url.absoluteString)/\(id)/\(begin.timeIntervalSince1970)",
                                                  title: title, location: location, calendar: calendar.name,
                                                  start: begin, end: finish, allDay: allDay,
                                                  sourceURL: fields["URL"].flatMap { URL(string: $0.value) }))
                    }
                }
            } else if nesting == 1 {
                fields[kind] = (parameters, value)
            }
        }
        return output
    }

    static func event(uid: String, title: String, location: String, start: Date, end: Date) -> Data {
        let fields = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Native Mail//Calendar//EN", "BEGIN:VEVENT",
            "UID:\(uid)", "DTSTAMP:\(timestamp(Date()))", "DTSTART:\(timestamp(start))", "DTEND:\(timestamp(end))",
            "SUMMARY:\(escape(title))", "LOCATION:\(escape(location))", "END:VEVENT", "END:VCALENDAR"
        ]
        return Data((fields.map(fold).joined(separator: "\r\n") + "\r\n").utf8)
    }

    private static func parseDate(_ value: String, parameters: [Substring]) -> Date? {
        if value.hasSuffix("Z") {
            return formatter("yyyyMMdd'T'HHmmss'Z'", zone: TimeZone(secondsFromGMT: 0)!).date(from: value)
        }
        let timezone = parameters.first(where: { $0.uppercased().hasPrefix("TZID=") }).map {
            String($0.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        let zone = timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        return formatter(value.count == 8 ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss", zone: zone).date(from: value)
    }

    private static func formatter(_ format: String, zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = format
        return formatter
    }

    static func duration(_ raw: String, from start: Date) -> Date? {
        let pattern = #"^P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) else { return nil }
        let values = (1...5).map { index -> Int in
            guard let range = Range(match.range(at: index), in: raw) else { return 0 }
            return min(100_000, Int(raw[range]) ?? 0)
        }
        let days = values[0] * 7 + values[1]
        let seconds = values[2] * 3600 + values[3] * 60 + values[4]
        return Calendar.current.date(byAdding: .day, value: days, to: start)?.addingTimeInterval(Double(seconds))
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: ";", with: "\\;")
    }

    private static func unescape(_ value: String) -> String {
        var output = ""
        var escaped = false
        for character in value {
            if escaped {
                output.append(character == "n" || character == "N" ? "\n" : character)
                escaped = false
            } else if character == "\\" { escaped = true }
            else { output.append(character) }
        }
        if escaped { output.append("\\") }
        return output
    }

    private static func fold(_ line: String) -> String {
        var result = ""
        var length = 0
        for scalar in line.unicodeScalars {
            let count = String(scalar).utf8.count
            if length + count > 75 {
                result += "\r\n "
                length = 1
            }
            result.unicodeScalars.append(scalar)
            length += count
        }
        return result
    }
}
