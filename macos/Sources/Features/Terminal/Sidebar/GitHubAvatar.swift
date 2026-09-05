import AppKit
import Combine
import SwiftUI

/// The picture beside a pull request, fetched once per login and kept in
/// memory.
///
/// Derived from the login rather than asked for: `gh pr list --json author`
/// carries no avatar URL, and `https://github.com/<login>.png` is the
/// endpoint GitHub publishes for exactly this. One request per author per
/// launch — a few authors wide is all a group's list ever is, which is why
/// there is no file on disk to go stale.
@MainActor
final class GitHubAvatarStore: ObservableObject {
    static let shared = GitHubAvatarStore()

    @Published private(set) var images: [String: NSImage] = [:]

    /// Logins with no picture to have: a deleted account, a bot GitHub draws
    /// no face for, a machine with no network. Remembered so the list does
    /// not ask again on every scroll.
    private var missing: Set<String> = []
    private var inflight: Set<String> = []

    /// Twice the drawn size, for a retina screen. Asking for the full-size
    /// original would be a 460KB download to fill 28 points.
    private static let pixels = 64

    private init() {}

    func image(for login: String?) -> NSImage? {
        login.flatMap { images[$0] }
    }

    /// Cheap no-op once a login has an answer, success or failure.
    func request(login: String) {
        guard Self.isPlausible(login) else { return }
        guard images[login] == nil, !missing.contains(login), !inflight.contains(login)
        else { return }
        guard let url = URL(string: "https://github.com/\(login).png?size=\(Self.pixels)")
        else { return }

        inflight.insert(login)
        Task { [weak self] in
            let image = await Self.load(url)
            guard let self else { return }
            self.inflight.remove(login)
            if let image {
                self.images[login] = image
            } else {
                self.missing.insert(login)
            }
        }
    }

    /// What GitHub allows in a login: letters, digits and single hyphens, up
    /// to 39 characters.
    ///
    /// Checked before the string reaches a URL, which is the point. `gh`
    /// answers with `app/dependabot` for some bots, and a login carrying a
    /// slash — or anything else — would build a request for a path this code
    /// never meant to fetch.
    nonisolated static func isPlausible(_ login: String) -> Bool {
        guard !login.isEmpty, login.count <= 39 else { return false }
        return login.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    nonisolated private static func load(_ url: URL) async -> NSImage? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"

        guard let (data, response) = try? await URLSession.shared.data(for: request)
        else { return nil }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return NSImage(data: data)
    }
}

/// A pull request author's picture, or their initial until there is one.
///
/// The monogram is not a placeholder to be replaced by the real thing later
/// so much as the answer for a bot, an offline machine or a deleted account.
/// It has to look deliberate, because for some rows it is what stays.
struct GitHubAvatarView: View {
    let login: String?
    var size: CGFloat = 28

    @ObservedObject private var store: GitHubAvatarStore = .shared
    @ObservedObject private var palette: ThemePalette = .shared

    var body: some View {
        ZStack {
            if let image = store.image(for: login) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill((palette.accent ?? .accentColor).opacity(0.22))
                Text(monogram)
                    .font(palette.font(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
        /// Asked for from here rather than from the row's body: the store
        /// publishes when a picture lands, and publishing from inside a view
        /// update is the one thing SwiftUI will not have.
        .task(id: login) {
            guard let login, !login.isEmpty else { return }
            store.request(login: login)
        }
    }

    private var monogram: String {
        guard let first = login?.first(where: { $0.isLetter || $0.isNumber }) else { return "?" }
        return String(first).uppercased()
    }
}
