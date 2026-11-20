import AppKit
import Contacts
import SwiftUI

struct ContactEntry: Identifiable, Hashable {
    enum Source: String { case recent = "最近往来", system = "系统通讯录", directory = "企业通讯录" }

    var id: String { email.lowercased() }
    var name: String
    var email: String
    var organization = ""
    var sources: Set<Source>
    var count = 0
    var lastSeen: Date?

    var address: MailAddress { MailAddress(name: name, email: email) }
    var display: String { name.isEmpty ? email : name }
}

@MainActor
final class ContactsModel: ObservableObject {
    @Published var query = ""
    @Published var selection: String?
    @Published private(set) var directory: [ContactChoice] = []
    @Published private(set) var directoryError: String?
    @Published private(set) var searchingDirectory = false
    @Published private(set) var system: [ContactEntry] = []
    @Published private(set) var systemAccess = CNContactStore.authorizationStatus(for: .contacts)
    /// People opened from a mail header who are not in any other source yet.
    @Published private(set) var extra: [ContactEntry] = []

    func focus(_ address: MailAddress) {
        query = ""
        if !extra.contains(where: { $0.id == address.email.lowercased() }) {
            extra.append(ContactEntry(name: address.name, email: address.email, sources: []))
        }
        selection = address.email.lowercased()
    }

    func entries(recent: [RecentContact]) -> [ContactEntry] {
        var merged: [String: ContactEntry] = [:]
        func add(_ entry: ContactEntry) {
            if var known = merged[entry.id] {
                if known.name.isEmpty { known.name = entry.name }
                if known.organization.isEmpty { known.organization = entry.organization }
                known.sources.formUnion(entry.sources)
                known.count = max(known.count, entry.count)
                known.lastSeen = known.lastSeen ?? entry.lastSeen
                merged[entry.id] = known
            } else {
                merged[entry.id] = entry
            }
        }
        for item in recent {
            add(ContactEntry(name: item.name, email: item.email, sources: [.recent], count: item.count, lastSeen: item.lastSeen))
        }
        system.forEach(add)
        extra.forEach(add)
        for item in directory { add(ContactEntry(name: item.name, email: item.email, sources: [.directory])) }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = merged.values.filter { entry in
            term.isEmpty || entry.name.localizedStandardContains(term) || entry.email.localizedStandardContains(term)
                || entry.organization.localizedStandardContains(term)
        }
        return all.sorted { left, right in
            if left.count != right.count { return left.count > right.count }
            return left.display.localizedStandardCompare(right.display) == .orderedAscending
        }
    }

    func searchDirectory(using store: MailStore) async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        directory = []
        directoryError = nil
        guard !term.isEmpty, store.account != nil else { return }
        do {
            try await Task.sleep(for: .milliseconds(400))
            searchingDirectory = true
            defer { searchingDirectory = false }
            let found = try await store.directorySearch(term)
            try Task.checkCancellation()
            directory = found
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { directoryError = error.localizedDescription }
        }
    }

    func loadSystemContacts() async {
        systemAccess = CNContactStore.authorizationStatus(for: .contacts)
        guard systemAccess == .authorized else { return }
        let found = await Task.detached(priority: .userInitiated) { () -> [ContactEntry] in
            let store = CNContactStore()
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
                        CNContactEmailAddressesKey] as [CNKeyDescriptor]
            var output: [ContactEntry] = []
            try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, stop in
                let family = contact.familyName, given = contact.givenName
                let isCJK = (family + given).unicodeScalars.contains { $0.value >= 0x2E80 }
                let name = (isCJK ? family + given : [given, family].filter { !$0.isEmpty }.joined(separator: " "))
                for email in contact.emailAddresses {
                    let value = String(email.value)
                    guard MailAddress.isValid(value) else { continue }
                    output.append(ContactEntry(name: name, email: value, organization: contact.organizationName, sources: [.system]))
                }
                if output.count > 20_000 { stop.pointee = true }
            }
            return output
        }.value
        system = found
    }

    func requestSystemAccess() async {
        _ = try? await CNContactStore().requestAccess(for: .contacts)
        await loadSystemContacts()
    }
}

/// Middle column of the contacts section.
struct ContactsPane: View {
    @ObservedObject var store: MailStore
    @ObservedObject var model: ContactsModel

    var body: some View {
        let entries = model.entries(recent: store.recentContacts)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("联系人").font(.title3.weight(.semibold))
                    Spacer()
                    if model.searchingDirectory { ProgressView().controlSize(.small) }
                }
                TextField("搜索姓名、邮箱或单位", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                Text(caption(entries.count)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
            Divider()
            List(selection: $model.selection) {
                if model.systemAccess == .notDetermined {
                    Button {
                        Task { await model.requestSystemAccess() }
                    } label: {
                        Label("显示 macOS 通讯录中的联系人…", systemImage: "person.crop.circle.badge.plus")
                    }
                    .buttonStyle(.link)
                    .selectionDisabled()
                }
                ForEach(entries) { entry in
                    HStack(spacing: 10) {
                        Avatar(address: entry.address, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.display).font(.body.weight(.medium)).lineLimit(1)
                            Text(entry.name.isEmpty ? (entry.organization.isEmpty ? " " : entry.organization) : entry.email)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if entry.sources.contains(.directory) {
                            Image(systemName: "building.2").font(.caption).foregroundStyle(.secondary).help("企业通讯录")
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(entry.id)
                    .contextMenu {
                        Button("写信", systemImage: "square.and.pencil") { store.compose(to: entry.address) }
                        Button("拷贝邮箱地址", systemImage: "doc.on.doc") { copy(entry.email) }
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if entries.isEmpty {
                    if model.query.isEmpty {
                        ContentUnavailableView("暂无联系人", systemImage: "person.2",
                                               description: Text("收发邮件后，往来联系人会出现在这里。也可以搜索企业通讯录。"))
                    } else if !model.searchingDirectory {
                        ContentUnavailableView.search(text: model.query)
                    }
                }
            }
        }
        .task { await model.loadSystemContacts() }
        .task(id: model.query) {
            await model.searchDirectory(using: store)
        }
    }

    private func caption(_ count: Int) -> String {
        if let error = model.directoryError, !model.query.isEmpty { return "企业通讯录：" + error }
        return model.query.isEmpty ? "\(count) 位联系人 · 按往来频率排序" : "找到 \(count) 位联系人"
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Detail column of the contacts section.
struct ContactCard: View {
    @ObservedObject var store: MailStore
    @ObservedObject var model: ContactsModel
    @State private var avatar: NSImage?

    var body: some View {
        if let id = model.selection, let entry = model.entries(recent: store.recentContacts).first(where: { $0.id == id }) {
            ScrollView {
                VStack(spacing: 18) {
                    Group {
                        if let avatar {
                            Image(nsImage: avatar).resizable().scaledToFill()
                                .frame(width: 84, height: 84).clipShape(Circle())
                                .accessibilityHidden(true)
                        } else {
                            Avatar(address: entry.address, size: 84)
                        }
                    }
                    .padding(.top, 36)
                    .task(id: entry.id) {
                        avatar = nil
                        guard entry.sources.contains(.directory) else { return }
                        let image = await store.directoryAvatar(entry.email)
                        if !Task.isCancelled { avatar = image }
                    }
                    VStack(spacing: 4) {
                        Text(entry.display).font(.title.weight(.semibold)).textSelection(.enabled)
                        if !entry.organization.isEmpty {
                            Text(entry.organization).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 10) {
                        Button { store.compose(to: entry.address) } label: {
                            Label("写信", systemImage: "square.and.pencil").frame(minWidth: 76)
                        }
                        .buttonStyle(.borderedProminent)
                        Button { store.showMail(with: entry.email) } label: {
                            Label("往来邮件", systemImage: "tray.full").frame(minWidth: 76)
                        }
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.address.full, forType: .string)
                        } label: {
                            Label("拷贝", systemImage: "doc.on.doc").frame(minWidth: 60)
                        }
                    }
                    .controlSize(.large)
                    VStack(spacing: 0) {
                        row("邮箱", entry.email)
                        Divider().padding(.leading, 90)
                        row("来源", entry.sources.map(\.rawValue).sorted().joined(separator: "、"))
                        if let last = entry.lastSeen, last > .distantPast {
                            Divider().padding(.leading, 90)
                            row("最近往来", last.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
                    .frame(maxWidth: 460)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
            }
        } else {
            ContentUnavailableView("选择一位联系人", systemImage: "person.crop.circle")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}
