import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct SignatureSettings: View {
    @ObservedObject var store: MailStore
    @State private var editing: MailSignature?
    @State private var removing: MailSignature?
    @State private var error: String?

    var body: some View {
        Form {
            Section("邮件签名") {
                if store.account == nil {
                    Text("添加邮箱账户后即可管理签名。")
                } else if let error = store.signatureLoadError {
                    Text(error).foregroundStyle(.secondary)
                } else {
                    Picker("默认签名", selection: Binding(get: { store.signatures.defaultID }, set: { id in
                        var library = store.signatures
                        library.defaultID = id
                        save(library)
                    })) {
                        Text("无签名").tag(nil as UUID?)
                        ForEach(store.signatures.entries) { entry in Text(entry.name).tag(Optional(entry.id)) }
                    }
                    ForEach(store.signatures.entries) { entry in
                        HStack {
                            Text(entry.name).lineLimit(1)
                            Spacer()
                            Button("编辑") { editing = entry }.buttonStyle(.borderless)
                            Button("删除", role: .destructive) { removing = entry }.buttonStyle(.borderless)
                        }
                    }
                    Button("添加签名", systemImage: "plus") {
                        editing = MailSignature(name: "", plain: "")
                    }
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { entry in
            SignatureEditor(entry: entry) { updated in
                var library = store.signatures
                if let index = library.entries.firstIndex(where: { $0.id == updated.id }) {
                    library.entries[index] = updated
                } else {
                    library.entries.append(updated)
                }
                try store.saveSignatures(library)
                error = nil
            }
        }
        .confirmationDialog("删除签名？", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible, presenting: removing) { entry in
            Button("删除「\(entry.name)」", role: .destructive) {
                var library = store.signatures
                library.entries.removeAll { $0.id == entry.id }
                if library.defaultID == entry.id { library.defaultID = nil }
                save(library)
                removing = nil
            }
        }
    }

    private func save(_ library: MailSignatureLibrary) {
        do {
            try store.saveSignatures(library)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct SignatureEditor: View {
    let id: UUID
    let save: (MailSignature) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var text: String
    @State private var rich: NSAttributedString?
    @State private var command: RichEdit?
    @State private var showImages = false
    @State private var showColors = false
    @State private var error: String?

    init(entry: MailSignature, save: @escaping (MailSignature) throws -> Void) {
        id = entry.id
        self.save = save
        let document = entry.document()
        _name = State(initialValue: entry.name)
        _text = State(initialValue: document.string)
        _rich = State(initialValue: document)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("签名名称", text: $name)
            HStack(spacing: 10) {
                ForEach(RichStyle.allCases) { style in
                    Button(style.title, systemImage: style.rawValue) { command = RichEdit(style: style) }
                        .labelStyle(.iconOnly)
                        .help(style.title)
                }
                Button("字体与字号", systemImage: "textformat.size") {
                    NSFontManager.shared.orderFrontFontPanel(nil)
                }
                .labelStyle(.iconOnly)
                .help("字体与字号")
                Button("文字颜色", systemImage: "character") { showColors.toggle() }
                    .labelStyle(.iconOnly)
                    .help("文字颜色")
                    .popover(isPresented: $showColors, arrowEdge: .bottom) {
                        ComposeColorPalette(title: "文字颜色", reset: "自动") { color in
                            command = RichEdit(.color(color, background: false))
                            showColors = false
                        }
                    }
                Button("插入图片…", systemImage: "photo") { showImages = true }
                Spacer()
            }
            .buttonStyle(.borderless)
            RichEditor(text: $text, richText: $rich, command: command, initiallyFocused: false, isEditable: true)
                .frame(minHeight: 180)
                .clipShape(.rect(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
            if let error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存签名") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500, height: 340)
        .fileImporter(isPresented: $showImages, allowedContentTypes: [.png, .jpeg, .gif]) { result in
            do {
                let url = try result.get()
                let acquired = url.startAccessingSecurityScopedResource()
                defer { if acquired { url.stopAccessingSecurityScopedResource() } }
                let limit = 5 * 1024 * 1024
                guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit else {
                    throw MailError("单张签名图片不能超过 5 MB。")
                }
                let bytes = try Data(contentsOf: url)
                guard bytes.count <= limit, let image = CGImageSourceCreateWithData(bytes as CFData, nil),
                      let type = CGImageSourceGetType(image), let mediaType = UTType(type as String)?.preferredMIMEType,
                      ["image/png", "image/jpeg", "image/gif"].contains(mediaType),
                      CGImageSourceGetCount(image) > 0 else {
                    throw MailError("请选择有效的 PNG、JPEG 或 GIF 图片。")
                }
                command = RichEdit(.image(InlineImage(contentID: nil, location: nil, mediaType: mediaType,
                                                      name: url.lastPathComponent, bytes: bytes)))
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    private func commit() {
        do {
            let entry = try MailSignature(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                          document: rich ?? NSAttributedString(string: text))
            try save(entry)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
