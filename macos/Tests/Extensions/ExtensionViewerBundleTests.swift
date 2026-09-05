import Foundation
@testable import Ghostty
import Testing

struct ExtensionViewerBundleTests {
    @Test func theViewerShipsInsideTheApp() throws {
        let html = try #require(ExtensionViewerBundle.url)
        #expect(html.lastPathComponent == "viewer.html")
        #expect(html.deletingLastPathComponent().lastPathComponent == "extension-viewer")

        let directory = try #require(ExtensionViewerBundle.directory)
        for name in ExtensionViewerBundle.fileNames {
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path), "\(name)")
        }
    }

    @Test func theViewerSaysWhichVersionItIs() throws {
        let version = try #require(ExtensionViewerBundle.version)
        #expect(SemanticVersion.isValid(version))
    }

    @Test func theViewerPageLoadsOnlyItsOwnScriptAndStylesheet() throws {
        let html = try String(contentsOf: try #require(ExtensionViewerBundle.url), encoding: .utf8)
        #expect(html.contains("Content-Security-Policy"))
        #expect(html.contains("src=\"viewer.js\""))
        #expect(html.contains("href=\"viewer.css\""))
        #expect(!html.contains("http://"))
        #expect(!html.contains("https://"))
    }
}
