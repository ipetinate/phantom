import Foundation

/// Turns GitHub's `:shortcode:` into the emoji it stands for.
///
/// A pull request title or body written on GitHub carries these unrendered,
/// which is how `:chart_with_downwards_trend:` ends up on a card taking the
/// width of six words to say what one character says.
///
/// **Two layers, and the order matters.** GitHub publishes around eighteen
/// hundred of these and most are the Unicode character's own name with
/// underscores — `chart_with_downwards_trend` is literally
/// `CHART WITH DOWNWARDS TREND` — so the system's name lookup answers the bulk
/// of them for free. The table below is only the ones GitHub named for itself:
/// `:+1:`, `:tada:`, `:warning:`, and the handful with no Unicode name at all.
///
/// Embedding all eighteen hundred was the alternative. It would be a thousand
/// lines that go stale every time GitHub adds one, to replace a lookup the
/// operating system already ships.
enum GitHubEmoji {
    /// The shortcodes whose name is not the character's own.
    ///
    /// Kept to what turns up in a commit message or a pull request body —
    /// releases, fixes, warnings, approvals. A shortcode that is not here and
    /// has no Unicode name is left exactly as written, which is the only safe
    /// answer: eating text nobody asked to lose is worse than showing a
    /// shortcode.
    static let named: [String: String] = [
        "+1": "\u{1F44D}", "-1": "\u{1F44E}",
        "tada": "\u{1F389}", "rocket": "\u{1F680}", "fire": "\u{1F525}",
        "warning": "\u{26A0}\u{FE0F}", "bulb": "\u{1F4A1}", "boom": "\u{1F4A5}",
        "white_check_mark": "\u{2705}", "heavy_check_mark": "\u{2714}\u{FE0F}",
        "x": "\u{274C}", "no_entry": "\u{26D4}", "no_entry_sign": "\u{1F6AB}",
        "recycle": "\u{267B}\u{FE0F}", "sparkles": "\u{2728}", "zap": "\u{26A1}",
        "art": "\u{1F3A8}", "lipstick": "\u{1F484}", "wrench": "\u{1F527}",
        "hammer": "\u{1F528}", "bug": "\u{1F41B}", "ambulance": "\u{1F691}",
        "lock": "\u{1F512}", "closed_lock_with_key": "\u{1F510}",
        "rotating_light": "\u{1F6A8}", "construction": "\u{1F6A7}",
        "green_heart": "\u{1F49A}", "heart": "\u{2764}\u{FE0F}",
        "arrow_up": "\u{2B06}\u{FE0F}", "arrow_down": "\u{2B07}\u{FE0F}",
        "pushpin": "\u{1F4CC}", "memo": "\u{1F4DD}", "pencil": "\u{270F}\u{FE0F}",
        "books": "\u{1F4DA}", "book": "\u{1F4D6}", "bookmark": "\u{1F516}",
        "package": "\u{1F4E6}", "truck": "\u{1F69B}", "wastebasket": "\u{1F5D1}\u{FE0F}",
        "mag": "\u{1F50D}", "eyes": "\u{1F440}", "brain": "\u{1F9E0}",
        "seedling": "\u{1F331}", "alien": "\u{1F47D}", "poop": "\u{1F4A9}",
        "shipit": "\u{1F696}", "ok_hand": "\u{1F44C}", "pray": "\u{1F64F}",
        "clap": "\u{1F44F}", "muscle": "\u{1F4AA}", "thinking": "\u{1F914}",
        "smile": "\u{1F604}", "sweat_smile": "\u{1F605}", "joy": "\u{1F602}",
        "confused": "\u{1F615}", "cry": "\u{1F622}", "scream": "\u{1F631}",
        "beers": "\u{1F37B}", "coffee": "\u{2615}", "clock": "\u{1F55B}",
        "hourglass": "\u{231B}", "stopwatch": "\u{23F1}\u{FE0F}",
        "chart_with_upwards_trend": "\u{1F4C8}",
        "chart_with_downwards_trend": "\u{1F4C9}",
        "bar_chart": "\u{1F4CA}", "clipboard": "\u{1F4CB}", "label": "\u{1F3F7}\u{FE0F}",
        "link": "\u{1F517}", "paperclip": "\u{1F4CE}", "gear": "\u{2699}\u{FE0F}",
        "test_tube": "\u{1F9EA}", "microscope": "\u{1F52C}",
        "globe_with_meridians": "\u{1F310}", "iphone": "\u{1F4F1}",
        "computer": "\u{1F4BB}", "robot": "\u{1F916}", "sparkle": "\u{2747}\u{FE0F}",
    ]

    /// The shortcode's shape.
    ///
    /// Lowercase letters, digits, `_`, `+` and `-`, between two colons and
    /// nothing else. Deliberately narrow, because a body is full of colons
    /// that are not shortcodes: `10:30:15`, a Ruby symbol, a YAML key, a URL's
    /// `https://`. All of those either fail this shape or fail to resolve, and
    /// both outcomes leave the text untouched.
    private static let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_+-")

    /// The emoji a shortcode means, or nil to leave it as written.
    static func emoji(for shortcode: String) -> String? {
        guard !shortcode.isEmpty,
              shortcode.count <= 40,
              shortcode.allSatisfy({ allowed.contains($0) })
        else { return nil }

        if let known = named[shortcode] { return known }
        return byUnicodeName(shortcode)
    }

    /// The character whose Unicode name this is.
    ///
    /// `CFStringTransform` in reverse turns `\N{NAME}` back into the character,
    /// which is how most of GitHub's list resolves without being written down.
    /// A name it does not know comes back unchanged, still wrapped in `\N{}` —
    /// that is what the guard checks for, and it is why the result has to be
    /// inspected rather than trusted.
    static func byUnicodeName(_ shortcode: String) -> String? {
        let name = shortcode.replacingOccurrences(of: "_", with: " ").uppercased()
        let wrapped = NSMutableString(string: "\\N{\(name)}")

        guard CFStringTransform(wrapped, nil, kCFStringTransformToUnicodeName, true),
              !wrapped.contains("\\N{"),
              wrapped.length > 0
        else { return nil }

        let resolved = wrapped as String

        /// Exactly one character, and it has to be an emoji.
        ///
        /// The transform resolves any Unicode name, so `heavy_plus_sign` would
        /// answer with a symbol and `space` with a blank — and a body that
        /// happened to contain `:a:` would otherwise turn into a letter. One
        /// scalar carrying emoji presentation is the shape a shortcode stands
        /// for.
        guard resolved.count == 1,
              let scalar = resolved.unicodeScalars.first,
              scalar.properties.isEmojiPresentation || scalar.properties.isEmoji
        else { return nil }

        return resolved
    }

    /// Every shortcode in a string, replaced.
    ///
    /// One pass, and anything unresolved is left byte for byte as it was. A
    /// preview that dropped an unknown shortcode would be quietly editing
    /// somebody's description.
    static func render(_ text: String) -> String {
        guard text.contains(":") else { return text }

        var result = ""
        var pending: String?

        for character in text {
            if character == ":" {
                if let open = pending {
                    /// A closing colon: resolve, or put both back.
                    if let emoji = emoji(for: open) {
                        result += emoji
                        pending = nil
                    } else {
                        /// Not a shortcode. The colon that opened it belongs to
                        /// the text, and this one may open the next — which is
                        /// what makes `10:30:15` come out unharmed.
                        result += ":" + open
                        pending = ""
                    }
                } else {
                    pending = ""
                }
                continue
            }

            if pending != nil {
                pending?.append(character)
            } else {
                result.append(character)
            }
        }

        if let leftover = pending { result += ":" + leftover }
        return result
    }
}
