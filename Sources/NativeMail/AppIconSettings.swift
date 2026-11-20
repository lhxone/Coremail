import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum CustomAppIcon {
    private static var url: URL { MailStorage.directory.appendingPathComponent("AppIcon.png") }

    static func load() -> NSImage? { NSImage(contentsOf: url) }

    static func save(from source: URL) throws -> NSImage {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let maximumBytes = 20 * 1024 * 1024
        guard let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximumBytes else {
            throw MailError("请选择 20 MB 以内的图片。")
        }
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(input, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024
              ] as CFDictionary) else {
            throw MailError("无法读取这张图片。")
        }
        let png = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            throw MailError("无法生成应用图标。")
        }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output), let icon = NSImage(data: png as Data) else {
            throw MailError("无法生成应用图标。")
        }
        try FileManager.default.createDirectory(at: MailStorage.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try (png as Data).write(to: url, options: .atomic)
        return icon
    }

    static func remove() throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
    }
}

struct AppIconSettings: View {
    @State private var icon = CustomAppIcon.load()
    @State private var choosing = false
    @State private var error: String?

    var body: some View {
        Section("应用图标") {
            HStack(spacing: 12) {
                if let preview = icon ?? NSApp.applicationIconImage {
                    Image(nsImage: preview)
                        .resizable().scaledToFit()
                        .frame(width: 48, height: 48)
                        .accessibilityLabel("应用图标预览")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(icon == nil ? "默认图标" : "自定义图标")
                    Text("应用运行时在 Dock 中显示。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("选择图片…") { choosing = true }
                Button("恢复默认") { restore() }.disabled(icon == nil)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.image]) { result in
            do {
                let selected = try CustomAppIcon.save(from: result.get())
                icon = selected
                NSApp.applicationIconImage = selected
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    private func restore() {
        do {
            try CustomAppIcon.remove()
            icon = nil
            NSApp.applicationIconImage = nil
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
