import SwiftUI
import WidgetKit
import WidgetShared

struct InboxEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct InboxProvider: TimelineProvider {
    func placeholder(in context: Context) -> InboxEntry {
        InboxEntry(date: Date(), snapshot: WidgetSnapshot(unread: 8, state: "ready"))
    }
    func getSnapshot(in context: Context, completion: @escaping (InboxEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : InboxEntry(date: Date(), snapshot: .load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<InboxEntry>) -> Void) {
        let now = Date()
        completion(Timeline(entries: [InboxEntry(date: now, snapshot: .load())],
                            policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

struct InboxWidgetView: View {
    let entry: InboxEntry
    @Environment(\.widgetFamily) private var family

    private var status: String {
        switch entry.snapshot?.state {
        case "locked": "邮箱已锁定"
        case "signedOut": "请先登录邮箱"
        case "ready": "封未读邮件"
        default: "打开 Coremail 同步"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Coremail", systemImage: "envelope.fill")
                .font(.headline).foregroundStyle(.tint)
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.snapshot?.unread.map { String($0) } ?? "—")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.5).lineLimit(1).privacySensitive()
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                if family == .systemMedium {
                    Spacer()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("收件箱").font(.headline)
                        Text("点击查看邮件").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if let snapshot = entry.snapshot {
                HStack(spacing: 3) {
                    Text("更新于")
                    Text(snapshot.updatedAt, style: .time)
                }.font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(WidgetSnapshot.inboxURL)
    }
}

@main
struct CoremailInboxWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.kind, provider: InboxProvider()) { entry in
            InboxWidgetView(entry: entry)
        }
        .configurationDisplayName("收件箱")
        .description("查看 Coremail 收件箱未读数量，点击打开邮箱。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
