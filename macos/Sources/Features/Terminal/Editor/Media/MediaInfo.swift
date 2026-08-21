import Foundation

/// The line in the bottom corner: what this file is, how big, and how much of
/// its true size is on screen.
///
/// Assembled here rather than in the view so the wording is one thing and can
/// be checked without a window — including the parts that are absent, which is
/// most of the work: a file whose size cannot be read draws one separator
/// fewer, not an empty gap.
enum MediaInfo {
    static func parts(
        format: String,
        pixels: CGSize?,
        bytes: Int?,
        pages: Int?,
        scale: CGFloat?
    ) -> [String] {
        var parts: [String] = []

        let name = format.uppercased()
        if !name.isEmpty { parts.append(name) }

        if let pixels, pixels.width >= 1, pixels.height >= 1 {
            parts.append("\(Int(pixels.width.rounded())) × \(Int(pixels.height.rounded()))")
        }

        if let pages, pages > 0 {
            parts.append(pages == 1 ? "1 page" : "\(pages) pages")
        }

        if let bytes, bytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }

        if let scale, scale > 0 {
            parts.append(percentage(scale))
        }

        return parts
    }

    static func line(
        format: String,
        pixels: CGSize? = nil,
        bytes: Int? = nil,
        pages: Int? = nil,
        scale: CGFloat? = nil
    ) -> String {
        parts(format: format, pixels: pixels, bytes: bytes, pages: pages, scale: scale)
            .joined(separator: "  ·  ")
    }

    /// Rounded to whole percent, except below ten where a large image fitted
    /// into a small pane lands and where "0%" would be the answer.
    private static func percentage(_ scale: CGFloat) -> String {
        let percent = scale * 100
        if percent < 9.95 {
            return String(format: "%.1f%%", percent)
        }
        return "\(Int(percent.rounded()))%"
    }
}
