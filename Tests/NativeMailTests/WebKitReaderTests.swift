import WebKit
import XCTest
@testable import NativeMail

final class WebKitReaderTests: XCTestCase {
    @MainActor
    func testLargeTableSurvivesRefreshAndThemeChangesWithoutReloading() async throws {
        let row = "<tr><td>邮件内容</td><td>一段重复的正文</td></tr>"
        let html = "<table>" + String(repeating: row, count: 5000) + "</table>"
        let page = MailHTML(html: html, images: [])
        let coordinator = SafeHTML.Coordinator()
        let web = coordinator.makeWebView()
        web.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let start = ContinuousClock.now
        coordinator.load(page, into: web, allowRemote: false)
        var loaded = false
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            loaded = (try? await web.evaluateJavaScript(
                "document.querySelectorAll('tr').length === 5000 && document.body.offsetHeight > 0",
                in: nil, contentWorld: .defaultClient) as? Bool) == true
            if loaded { break }
        }
        XCTAssertTrue(loaded)
        print("5000-row reader layout including polling: ", start.duration(to: .now))
        _ = try await web.evaluateJavaScript("document.body.dataset.marker = 'retained'",
                                             in: nil, contentWorld: .defaultClient)
        let updateStart = ContinuousClock.now
        for index in 0..<200 {
            coordinator.load(page, into: web, allowRemote: false, dark: index >= 100)
        }
        print("200 reader updates including appearance switch: ", updateStart.duration(to: .now))
        try await Task.sleep(for: .milliseconds(250))
        let marker = try await web.evaluateJavaScript("document.body.dataset.marker || ''",
                                                      in: nil, contentWorld: .defaultClient)
        XCTAssertEqual(marker as? String, "retained")
    }

    @MainActor
    func testAppearanceSwitchUpdatesColorsInFormattedMail() async throws {
        let coordinator = SafeHTML.Coordinator()
        let view = coordinator.makeWebView()
        let page = MailHTML(html: """
            <table bgcolor="white"><tr><td><span id="sample" style="color:black">正文</span></td></tr></table>
            """, images: [])
        for (dark, expected) in [(true, "rgb(232, 234, 237)"), (false, "rgb(0, 0, 0)")] {
            coordinator.load(page, into: view, allowRemote: false, dark: dark)
            var color: String?
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(50))
                color = try? await view.evaluateJavaScript(
                    "getComputedStyle(document.getElementById('sample')).color",
                    in: nil, contentWorld: .defaultClient) as? String
                if color == expected { break }
            }
            XCTAssertEqual(color, expected)
        }
    }

    @MainActor
    func testSignatureLogoWithoutImageDimensionsFitsItsAuthoredCellWidth() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 800,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let resource = InlineImage(contentID: "logo@example.com", location: nil, mediaType: "image/png", name: nil,
            bytes: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
        var page = MailHTML(html: "<style>td.logo {width:45.4px}</style><table><tr><td class='logo'><img src='cid:logo@example.com'></td></tr></table>", images: [resource])
        // Optional local fixture lets us validate a reported email without checking
        // any private correspondence into the repository.
        if let path = ProcessInfo.processInfo.environment["COREMAIL_LOGO_REGRESSION_EML"] {
            let mail = MIME.message(try Data(contentsOf: URL(fileURLWithPath: path)))
            page = MailHTML(html: try XCTUnwrap(mail.html), images: mail.inlineImages)
        }
        let coordinator = SafeHTML.Coordinator()
        let view = coordinator.makeWebView()
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        coordinator.load(page, into: view, allowRemote: false)
        var width = 0.0
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            width = (try? await view.evaluateJavaScript("Array.from(document.images).find(i => i.naturalWidth === 800)?.getBoundingClientRect().width || 0", in: nil, contentWorld: .defaultClient)) as? Double ?? 0
            if width > 40 { break }
        }
        XCTAssertEqual(width, 45.4, accuracy: 0.1)
    }

    @MainActor
    func testWebKitActuallyDisplaysTheRelatedImage() async throws {
        let image = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9foAAAAASUVORK5CYII="))
        let resource = InlineImage(contentID: "test@example.com", location: nil, mediaType: "image/png",
                                   name: nil, bytes: image)
        let page = MailHTML(html: #"<img src="cid:test@example.com" id="inline">"#, images: [resource])
        let coordinator = SafeHTML.Coordinator()
        let view = coordinator.makeWebView()
        coordinator.load(page, into: view, allowRemote: false)

        var width: Int?
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            let value = try? await view.evaluateJavaScript("document.getElementById('inline')?.naturalWidth || 0",
                                                            in: nil, contentWorld: .defaultClient)
            width = value as? Int
            if width == 1 { break }
        }
        XCTAssertEqual(width, 1, "WebKit should decode the image from the controlled local URL.")
    }

    @MainActor
    func testWideImagesWithInlineSizeKeepTheirAspectRatio() async throws {
        // A 4x2 PNG declared at 1600x800 by inline style must scale down proportionally in a narrow reader.
        let image = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAEUlEQVR42mP8z8DwnwEJMAIALgIEAEO1yCsAAAAASUVORK5CYII="))
        let resource = InlineImage(contentID: "wide@example.com", location: nil, mediaType: "image/png",
                                   name: nil, bytes: image)
        let page = MailHTML(html: #"<img src="cid:wide@example.com" id="wide" width="1600" height="800" style="width:1600px;height:800px">"#,
                            images: [resource])
        let coordinator = SafeHTML.Coordinator()
        let view = coordinator.makeWebView()
        view.frame = NSRect(x: 0, y: 0, width: 448, height: 600)
        coordinator.load(page, into: view, allowRemote: false)

        var size: [Double] = []
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            let value = try? await view.evaluateJavaScript(
                "(() => { const r = document.getElementById('wide')?.getBoundingClientRect(); return r && r.width > 0 ? [r.width, r.height] : [] })()",
                in: nil, contentWorld: .defaultClient)
            size = (value as? [Double]) ?? (value as? [NSNumber])?.map(\.doubleValue) ?? []
            if size.count == 2 { break }
        }
        XCTAssertEqual(size.count, 2)
        guard size.count == 2 else { return }
        XCTAssertLessThan(size[0], 448, "Image should shrink to the reader width.")
        XCTAssertEqual(size[0] / size[1], 2, accuracy: 0.05, "Image must not be squashed.")
    }
}
