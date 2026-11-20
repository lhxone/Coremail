import SwiftUI

struct ConnectionCheck: View {
    let account: Account
    let password: (Account) throws -> String

    @Environment(\.dismiss) private var dismiss
    @State private var results: [Service: Result] = [:]

    private enum Service: String, CaseIterable {
        case mailbox = "邮箱（Coremail）"
        case calendar = "邮箱日历（CalDAV）"
        case directory = "企业通讯录（Coremail）"
    }

    private struct Result {
        let text: String
        var passed = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("检查服务器连接").font(.title2.weight(.semibold))
            Text("使用已保存账户检查登录和读取权限。检查不会发送邮件或创建日程。")
                .font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                ForEach(Service.allCases, id: \.self) { service in
                    GridRow(alignment: .top) {
                        Text(service.rawValue)
                        if let result = results[service] {
                            Label(result.text, systemImage: result.passed ? "checkmark.circle" : "exclamationmark.circle")
                                .foregroundStyle(result.passed ? Color.green : Color.secondary)
                                .textSelection(.enabled)
                        } else { ProgressView().controlSize(.small) }
                    }
                }
            }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 580)
        .task { await check() }
    }

    private func check() async {
        let secret: String
        let client: CoremailMailbox
        do {
            secret = try password(account)
            client = try CoremailMailbox(account: account, password: secret)
        }
        catch {
            for service in Service.allCases { results[service] = Result(text: error.localizedDescription) }
            return
        }
        let account = account
        let checked = await withTaskGroup(of: (Service, Result).self) { group in
            for service in Service.allCases {
                group.addTask {
                    do {
                        let detail: String
                        switch service {
                        case .mailbox:
                            let folders = try await client.folders()
                            detail = "已读取 \(folders.count) 个邮件文件夹"
                        case .calendar:
                            let calendars = try await CalDAV(account: account, password: secret).calendars()
                            if let calendar = calendars.first {
                                let now = Date()
                                _ = try await CalDAV(account: account, password: secret).events(in: calendar, from: now,
                                                                                                to: now.addingTimeInterval(86400))
                                detail = "已读取邮箱日历"
                            } else {
                                detail = "认证通过，服务器未返回日历"
                            }
                        case .directory:
                            try await client.checkDirectory()
                            detail = "目录查询已响应"
                        }
                        return (service, Result(text: detail, passed: true))
                    } catch { return (service, Result(text: error.localizedDescription)) }
                }
            }
            var checked: [(Service, Result)] = []
            for await item in group { checked.append(item) }
            return checked
        }
        // Applied after the group, on the view's actor.
        guard !Task.isCancelled else { return }
        for (service, result) in checked { results[service] = result }
    }
}
