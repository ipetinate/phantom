import SwiftUI
import UniformTypeIdentifiers

/// Theme management: a curated set of well-known themes split into dark
/// and light sections, import of external theme files, and an inline
/// theme creator at the bottom of the screen.
struct AppearanceSettingsView: View {
    let ghostty: Ghostty.App
    @ObservedObject var store: GuiConfigStore

    @StateObject private var catalog: ThemeCatalog

    @State private var search = ""
    @State private var expandedSections: Set<String> = []

    /// Famous themes shown by default; searching looks through the whole
    /// catalog. Names match the bundled theme files exactly.
    private static let curated: Set<String> = [
        "Dracula", "Dracula+",
        "TokyoNight", "TokyoNight Storm", "TokyoNight Moon", "TokyoNight Day",
        "Catppuccin Mocha", "Catppuccin Macchiato", "Catppuccin Frappe", "Catppuccin Latte",
        "Gruvbox Dark", "Gruvbox Dark Hard", "Gruvbox Light",
        "Nord", "Nord Light",
        "One Half Dark", "One Half Light",
        "Monokai Pro", "Monokai Remastered", "Monokai Pro Light",
        "GitHub Dark Default", "GitHub Light Default",
        "Solarized Dark Higher Contrast", "iTerm2 Solarized Light",
        "Ayu", "Ayu Mirage", "Ayu Light",
        "Night Owl", "Night Owlish Light",
        "Rose Pine", "Rose Pine Moon", "Rose Pine Dawn",
        "Kanagawa Dragon", "Kanagawa Lotus",
        "Everforest Dark Hard", "Everforest Light Med",
        "Snazzy", "Material Ocean", "Cobalt2", "Synthwave Everything",
    ]

    init(ghostty: Ghostty.App, store: GuiConfigStore) {
        self.ghostty = ghostty
        self.store = store
        _catalog = StateObject(wrappedValue: ThemeCatalog(userThemesDir: store.themesDirURL))
    }

    private var currentTheme: String {
        store.currentThemeName ?? ""
    }

    private struct ThemeGroups {
        var user: [TerminalTheme] = []
        var dark: [TerminalTheme] = []
        var light: [TerminalTheme] = []
    }

    private var groups: ThemeGroups {
        var result = ThemeGroups()

        let visible: [TerminalTheme]
        if search.isEmpty {
            visible = catalog.themes.filter {
                $0.source == .user || Self.curated.contains($0.name)
            }
        } else {
            visible = catalog.themes.filter {
                $0.name.localizedCaseInsensitiveContains(search)
            }
        }

        for theme in visible {
            if theme.source == .user {
                result.user.append(theme)
            } else if theme.background?.isLightColor == true {
                result.light.append(theme)
            } else {
                result.dark.append(theme)
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            if catalog.isLoading && catalog.themes.isEmpty {
                Spacer()
                ProgressView("Loading themes…")
                Spacer()
            } else {
                /// Themes loose on the page, the controls under them in a
                /// grouped `Form`, both in one scroll.
                ///
                /// Making each theme group a `Section` of that form gave every
                /// row of cards a card of its own — four stacked backgrounds
                /// for what is one thing to browse, and a grid is not a list of
                /// settings. The cards go back to sitting on the window itself;
                /// the controls keep the grouped rows, footers and metrics the
                /// other panes have.
                ///
                /// The form is asked for its intrinsic height with its own
                /// scrolling off, so it lays out as a block of this page rather
                /// than as a second scroller inside the first — and a wheel over
                /// it, having nothing there to scroll, reaches the page.
                /// The search field stays above all of it, pinned, because it
                /// filters the grid that scrolls beneath it.
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        themeGrids
                            .padding(14)

                        Form {
                            AppearanceStylePanel(ghostty: ghostty, store: store)
                        }
                        .formStyle(.grouped)
                        .scrollDisabled(true)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .navigationTitle("Appearance")
        .onAppear {
            catalog.loadIfNeeded()
            applyDefaultThemeIfNeeded()
        }
    }

    /// Dracula is the out-of-the-box theme until the user picks another.
    private func applyDefaultThemeIfNeeded() {
        guard currentTheme.isEmpty else { return }
        store.set("theme", "Dracula")
        store.apply(ghostty: ghostty)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("", text: $search, prompt: Text(verbatim: "Search all \(catalog.themes.count) themes"))
                .textFieldStyle(.plain)

            Button("Browse All…") {
                AllThemesWindowController.shared.show(ghostty: ghostty, store: store)
            }

            Button("Create…") {
                ThemeCreatorWindowController.shared.show(ghostty: ghostty, store: store)
            }

            Button("Import…") { importThemes() }
        }
        .padding(10)
    }

    /// Everything there is to browse: the theme in use and the user's own on
    /// the first row, then the curated dark and light sets.
    private var themeGrids: some View {
        let groups = groups

        return VStack(alignment: .leading, spacing: 18) {
            currentAndCustomThemes

            if !groups.dark.isEmpty {
                themeSection("Dark", groups.dark)
            }
            if !groups.light.isEmpty {
                themeSection("Light", groups.light)
            }
        }
    }

    /// The theme in use gets its own card, so what is active is visible
    /// without hunting for the checkmark in a grid. The user's own themes
    /// sit beside it and take the rest of the row.
    @ViewBuilder
    private var currentAndCustomThemes: some View {
        let groups = groups

        HStack(alignment: .top, spacing: 18) {
            if let current = catalog.themes.first(where: { $0.name == currentTheme }) {
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("Current Theme")
                    ThemeCard(theme: current, isSelected: true) {}
                        .frame(width: 150)
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            if !groups.user.isEmpty {
                themeSection("Custom Themes", groups.user)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    /// Sections collapse to their first row; searching expands results.
    private func themeSection(_ title: String, _ themes: [TerminalTheme]) -> some View {
        let isExpanded = expandedSections.contains(title) || !search.isEmpty
        let visible = isExpanded ? themes : Array(themes.prefix(3))

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle(title)

                Spacer()

                if themes.count > 3 && search.isEmpty {
                    Button {
                        if isExpanded {
                            expandedSections.remove(title)
                        } else {
                            expandedSections.insert(title)
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(verbatim: isExpanded ? "Show Less" : "Show All (\(themes.count))")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.link)
                }
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 10)],
                spacing: 10
            ) {
                ForEach(visible) { theme in
                    ThemeCard(theme: theme, isSelected: theme.name == currentTheme) {
                        store.setTheme(theme)
                        store.apply(ghostty: ghostty)
                    }
                    .contextMenu {
                        if theme.source == .user {
                            Button("Delete", role: .destructive) { deleteTheme(theme) }
                        }
                    }
                }
            }
        }
    }

    private func deleteTheme(_ theme: TerminalTheme) {
        guard theme.source == .user else { return }
        try? FileManager.default.removeItem(at: theme.url)
        if currentTheme == theme.name {
            store.set("theme", "Dracula")
            store.apply(ghostty: ghostty)
        }
        catalog.reload()
    }

    private func importThemes() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"

        guard panel.runModal() == .OK else { return }

        let fm = FileManager.default
        try? fm.createDirectory(at: store.themesDirURL, withIntermediateDirectories: true)

        for url in panel.urls {
            let destination = store.themesDirURL.appendingPathComponent(url.lastPathComponent)
            try? fm.removeItem(at: destination)
            try? fm.copyItem(at: url, to: destination)
        }
        catalog.reload()
    }
}

/// Every style control in one place, sectioned by area — the specific
/// settings tabs keep only behavior.
///
/// Emits bare `Section`s rather than wrapping them, so they belong to the
/// Appearance form and take its metrics instead of being a second, differently
/// spaced surface drawn inside the first.
private struct AppearanceStylePanel: View {
    let ghostty: Ghostty.App
    @ObservedObject var store: GuiConfigStore

    @State private var fontFamily: String = ""
    @State private var fontSize: Double = 13
    @State private var interfaceFontFamily: String = ""
    @State private var cursorStyle: String = ""
    @State private var backgroundOpacity: Double = 1
    @State private var blurMode: String = "off"
    @State private var blurRadius: Double = 20
    @State private var sidebarWidth: Double = 240
    @State private var dividerMode: String = AppearanceCoordinator.defaultDividerModeRaw
    @State private var dividerColor: Color = .gray

    /// The theme's own colours, offered as one-tap swatches beside the
    /// custom divider's picker. Observed so a theme switch made while this
    /// pane is open redraws the row with the new palette.
    @ObservedObject private var themePalette: ThemePalette = .shared

    /// The width the divider was last dragged to, or nil while nothing has
    /// been dragged. Held in state rather than read inline so the reset row
    /// can appear and disappear with it.
    @State private var draggedSidebarWidth: Double?

    @AppStorage("SidebarTabDensity") private var tabDensity = "default"

    private static let cursorStyles: [(value: String, label: String)] = [
        ("", "Default"),
        ("block", "Block"),
        ("bar", "Bar"),
        ("underline", "Underline"),
        ("block_hollow", "Hollow"),
    ]

    /// Draws the cursor as it appears in the terminal — the shape sitting in
    /// a character cell. SF Symbols has no glyph that reads as a terminal
    /// cursor, and the near-matches (a filled rectangle, a dash) look like
    /// what they are rather than like the setting they stand for.
    private static func cursorIcon(for style: String) -> NSImage? {
        guard !style.isEmpty else { return nil }

        let image = NSImage(
            size: NSSize(width: 12, height: 13),
            flipped: false
        ) { _ in
            let cell = NSRect(x: 1, y: 1, width: 10, height: 11)
            NSColor.black.setFill()
            NSColor.black.setStroke()

            switch style {
            case "block":
                cell.fill()
            case "block_hollow":
                let outline = NSBezierPath(rect: cell.insetBy(dx: 0.75, dy: 0.75))
                outline.lineWidth = 1.5
                outline.stroke()
            case "bar":
                NSRect(x: cell.minX, y: cell.minY, width: 2, height: cell.height).fill()
            case "underline":
                NSRect(x: cell.minX, y: cell.minY, width: cell.width, height: 2).fill()
            default:
                break
            }
            return true
        }

        // Template so the control tints it for selected and disabled states.
        image.isTemplate = true
        return image
    }

    var body: some View {
        Group {
            appSection
            terminalSection
            sidebarSection
        }
    }

    /// Phantom's own chrome, which is a different question from what the
    /// terminal is drawn in — and the reason this is its own section rather
    /// than the first row of the next one.
    private var appSection: some View {
        Section {
            LabeledContent("App Font") {
                Button(interfaceFontFamily.isEmpty ? "System Default" : interfaceFontFamily) {
                    FontPickerWindowController.shared.show(
                        title: "Interface Font",
                        currentFamily: interfaceFontFamily.isEmpty ? nil : interfaceFontFamily,
                        preview: .interface
                    ) { picked in
                        interfaceFontFamily = picked ?? ""
                        UserDefaults.standard.set(interfaceFontFamily, forKey: AppFont.interfaceFamilyKey)
                    }
                }
            }
            /// Hung off a row rather than the panel, because the panel is three
            /// sections and a modifier written across it is attached to each
            /// of them — three `populate()` calls on a single appearance.
            .onAppear { populate() }
        } header: {
            Text("App")
        } footer: {
            Text("The font Phantom's own interface is set in — the sidebar, this window, its menus. The terminal and the editor keep their own, below and in Editor.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var terminalSection: some View {
        Section {
            LabeledContent("Font Family") {
                Button(fontFamily.isEmpty ? "System Default" : fontFamily) {
                    FontPickerWindowController.shared.show(
                        title: "Terminal Font",
                        currentFamily: fontFamily.isEmpty ? nil : fontFamily,
                        preview: .terminal
                    ) { picked in
                        fontFamily = picked ?? ""
                        apply("font-family", fontFamily)
                    }
                }
            }

            LabeledContent("Font Size") {
                HStack {
                    Slider(value: $fontSize, in: 8...32, step: 1) { editing in
                        if !editing { apply("font-size", String(Int(fontSize))) }
                    }
                    Text(verbatim: "\(Int(fontSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }

            /// A pop-up rather than five icon segments.
            ///
            /// A segmented control stops carrying a choice somewhere around
            /// four items, and this one has five — of which four are small
            /// abstract marks that need their label to be read. A `.menu`
            /// `Picker` keeps both the drawing and the word, arrows through
            /// the options from the keyboard, and reads itself out to
            /// VoiceOver, none of which a hand-built track does for free.
            Picker("Cursor Style", selection: $cursorStyle) {
                ForEach(Self.cursorStyles, id: \.value) { style in
                    Label {
                        Text(style.label)
                    } icon: {
                        if let image = Self.cursorIcon(for: style.value) {
                            Image(nsImage: image)
                        }
                    }
                    .tag(style.value)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: cursorStyle) { value in
                apply("cursor-style", value)
            }

            LabeledContent("Background") {
                /// "Glass" is the blurred background. The system glass
                /// material used to be a fourth option, but it cannot hold a
                /// seam-free surface across the two panes — each pane gets
                /// its own material and they never match.
                Picker("", selection: $blurMode) {
                    Text("Solid").tag("solid")
                    Text("Clear").tag("off")
                    Text("Glass").tag("radius")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)
                .onChange(of: blurMode) { _ in applyEffectChange() }
            }

            if blurMode == "radius" {
                LabeledContent("Blur Intensity") {
                    HStack {
                        Slider(value: $blurRadius, in: 1...80, step: 1) { editing in
                            if !editing { applyBlur() }
                        }
                        Text(verbatim: "\(Int(blurRadius))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            if blurMode != "off" {
                LabeledContent("Opacity") {
                    HStack {
                        Slider(value: $backgroundOpacity, in: 0...1) { editing in
                            if !editing {
                                apply("background-opacity", String(format: "%.2f", backgroundOpacity))
                            }
                        }
                        Text(verbatim: String(format: "%.2f", backgroundOpacity))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        } header: {
            Text("Terminal")
        } footer: {
            Text("A font or size reaches new terminals right away; tabs already open take it when they are reopened. Clear pins the background fully transparent, which is why it offers no opacity of its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Named for the style rather than for the surface, because there is a
    /// whole pane called Sidebar and it answers a different question: that one
    /// is what the sidebar shows, this one is what it looks like.
    private var sidebarSection: some View {
        Section {
            LabeledContent("Starting Width") {
                HStack {
                    Slider(value: $sidebarWidth, in: 180...480, step: 10) { editing in
                        if !editing {
                            store.set("sidebar-width", String(Int(sidebarWidth)))
                            store.apply(ghostty: ghostty)
                        }
                    }
                    Text(verbatim: "\(Int(sidebarWidth)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }
            /// Watches the defaults so the row below appears the moment a
            /// divider is dragged in another window, and disappears with the
            /// reset — the setting is app-wide, so this window is never the
            /// only thing writing it.
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                let width = SidebarWidthOverride.width()
                if width != draggedSidebarWidth { draggedSidebarWidth = width }
            }

            /// Only offered once there is something to undo. Dragging a
            /// divider writes an app-wide width that every window then opens
            /// at, ahead of the slider above — which left the slider looking
            /// broken, with nothing anywhere to put it back in charge.
            if let dragged = draggedSidebarWidth {
                LabeledContent("Dragged Width") {
                    HStack(spacing: 8) {
                        Text(verbatim: "\(Int(dragged)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)

                        Button("Reset") {
                            SidebarWidthOverride.clear()
                            draggedSidebarWidth = nil
                        }
                    }
                }
            }

            LabeledContent("Divider") {
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 8) {
                        Picker("", selection: $dividerMode) {
                            Text("Default").tag("default")
                            Text("Hidden").tag("hidden")
                            Text("Custom").tag("custom")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        .onChange(of: dividerMode) { _ in saveDivider() }

                        if dividerMode == "custom" {
                            ColorPicker("", selection: $dividerColor, supportsOpacity: false)
                                .labelsHidden()
                                .onChange(of: dividerColor) { _ in saveDivider() }
                        }
                    }

                    if dividerMode == "custom" {
                        dividerThemeSwatches
                    }
                }
            }

            LabeledContent("Tab Items") {
                Picker("", selection: $tabDensity) {
                    Text("Default").tag("default")
                    Text("Compact").tag("compact")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 200)
            }
        } header: {
            Text("Sidebar Style")
        } footer: {
            Text("Starting Width is what a window with no dragging behind it opens at. Dragging a divider replaces it for every window and keeps it across launches; Reset drops that, and each window takes the slider's width back as you switch to it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The current theme's palette as one-tap divider colours. The picker
    /// stays for arbitrary colours; these are the colours the divider most
    /// often wants — the theme's own — one click away instead of behind an
    /// eyedropper.
    private var dividerThemeSwatches: some View {
        HStack(spacing: 5) {
            ForEach(Array(themePalette.colors.enumerated()), id: \.offset) { index, swatch in
                Button {
                    dividerColor = Color(nsColor: swatch)
                    saveDivider()
                } label: {
                    Circle()
                        .fill(Color(nsColor: swatch))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(ThemePalette.ansiNames.indices.contains(index)
                      ? ThemePalette.ansiNames[index] : "")
            }
        }
    }

    private func populate() {
        fontFamily = store.string("font-family") ?? ""
        fontSize = store.double("font-size", default: 13)
        interfaceFontFamily = UserDefaults.standard.string(forKey: AppFont.interfaceFamilyKey) ?? ""
        backgroundOpacity = store.double("background-opacity", default: 1)
        cursorStyle = store.string("cursor-style") ?? ""
        sidebarWidth = store.double("sidebar-width", default: 240)
        draggedSidebarWidth = SidebarWidthOverride.width()

        switch store.string("background-blur") ?? "false" {
        case "false":
            // "false" covers both Solid and Clear — opacity tells them
            // apart, since Clear is pinned near zero and Solid isn't.
            blurMode = backgroundOpacity <= 0.05 ? "off" : "solid"
        case "true":
            blurMode = "radius"
            blurRadius = 20
        case "macos-glass-regular", "macos-glass-clear":
            // A config left over from when the system glass material was an
            // option: read it as the blurred background it now maps to.
            blurMode = "radius"
            blurRadius = 20
        case let raw:
            if let value = Double(raw), value > 0 {
                blurMode = "radius"
                blurRadius = value
            } else {
                blurMode = backgroundOpacity <= 0.05 ? "off" : "solid"
            }
        }

        let defaults = UserDefaults.standard
        dividerMode = defaults.string(forKey: AppearanceCoordinator.dividerModeKey)
            ?? AppearanceCoordinator.defaultDividerModeRaw
        if let hex = defaults.string(forKey: AppearanceCoordinator.dividerColorKey),
           let color = NSColor(hex: hex) {
            dividerColor = Color(nsColor: color)
        }
    }

    private func saveDivider() {
        let defaults = UserDefaults.standard
        defaults.set(dividerMode, forKey: AppearanceCoordinator.dividerModeKey)
        defaults.set(
            NSColor(dividerColor).hexString ?? "#808080",
            forKey: AppearanceCoordinator.dividerColorKey)
        NotificationCenter.default.post(
            name: TerminalController.sidebarTintDidChange,
            object: nil
        )
    }

    private func apply(_ key: String, _ value: String) {
        store.set(key, value.isEmpty ? nil : value)
        store.apply(ghostty: ghostty)
    }

    private func applyBlur() {
        let value: String
        switch blurMode {
        case "radius": value = String(Int(blurRadius))
        default: value = "false"
        }
        apply("background-blur", value)
    }

    /// Effect selection drives opacity: Solid snaps to fully opaque
    /// (still adjustable afterward), Clear pins full transparency with
    /// no adjustment, and Glass nudges away from either extreme — at 0%
    /// or 100% the blur wouldn't be visible — unless the user already set
    /// a deliberate in-between value, which is left alone.
    private func applyEffectChange() {
        switch blurMode {
        case "solid":
            backgroundOpacity = 1.0
            store.set("background-opacity", "1.00")
        case "off":
            backgroundOpacity = 0.0
            store.set("background-opacity", "0.00")
        case "radius":
            if backgroundOpacity <= 0.02 || backgroundOpacity >= 0.98 {
                backgroundOpacity = 0.5
                store.set("background-opacity", "0.50")
            }
        default:
            break
        }
        applyBlur()
    }

}

/// The sidebar width the user last dragged to.
///
/// Dragging a divider writes one app-wide width (`TerminalController`'s
/// `sidebarWidthDefaultsKey`) that every window then opens at, ahead of the
/// configured `sidebar-width`. Nothing ever cleared it, so the slider in
/// Appearance stopped having any visible effect the first time a divider
/// moved, and the only way back was `defaults delete`.
///
/// Reading and clearing live here, next to the control that offers the reset,
/// and take the store as a parameter so a test can use its own.
enum SidebarWidthOverride {
    /// The dragged width, or nil when there is none. Zero counts as none —
    /// the same reading `TerminalController.sharedSidebarWidth` does, since
    /// `UserDefaults.double(forKey:)` cannot tell an absent key from a 0.
    static func width(in defaults: UserDefaults = .standard) -> Double? {
        let saved = defaults.double(forKey: TerminalController.sidebarWidthDefaultsKey)
        return saved > 0 ? saved : nil
    }

    /// Drops it, putting the configured width back in charge. Open windows
    /// take it as each becomes key, which is where they re-read this.
    static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: TerminalController.sidebarWidthDefaultsKey)
    }
}

/// One theme in the grid: a miniature Phantom window — sidebar strip,
/// prompt line and text skeleton, all in the theme's real colors — with
/// the name centered underneath.
private struct ThemeCard: View {
    let theme: TerminalTheme
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var background: Color { Color(nsColor: theme.background ?? .black) }
    private var foreground: Color { Color(nsColor: theme.foreground ?? .white) }
    private var prompt: Color {
        Color(nsColor: theme.palette[2] ?? theme.foreground ?? .green)
    }
    private var accent: Color {
        Color(nsColor: theme.palette[4] ?? theme.foreground ?? .blue)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                miniWindow

                HStack(spacing: 4) {
                    Text(theme.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)

                    if theme.source == .user {
                        Image(systemName: "person.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(accent)
                            .padding(.trailing, 2)
                    }
                }
            }
            .padding(7)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovered ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected ? accent : .clear,
                        lineWidth: 2
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var miniWindow: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                skeletonBar(accent.opacity(0.85), width: 22)
                skeletonBar(foreground.opacity(0.25), width: 16)
                skeletonBar(foreground.opacity(0.18), width: 19)
                Spacer(minLength: 0)
            }
            .padding(7)
            .frame(width: 38, alignment: .topLeading)
            .background(foreground.opacity(0.05))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 3) {
                    Circle()
                        .fill(prompt)
                        .frame(width: 5, height: 5)
                    skeletonBar(foreground.opacity(0.75), width: 42)
                }
                skeletonBar(foreground.opacity(0.35), width: 64)
                skeletonBar(foreground.opacity(0.2), width: 50)

                Spacer(minLength: 0)

                HStack(spacing: 3) {
                    ForEach(Array(theme.previewColors.prefix(7).enumerated()), id: \.offset) { _, color in
                        Circle()
                            .fill(Color(nsColor: color))
                            .frame(width: 5, height: 5)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(height: 86)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private func skeletonBar(_ color: Color, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: width, height: 4)
    }
}

/// A labeled compact color well used by the theme creator grids.
private struct NamedColorWell: View {
    let label: String
    var help: String?
    @Binding var color: Color

    var body: some View {
        VStack(spacing: 3) {
            ColorPicker("", selection: $color, supportsOpacity: false)
                .labelsHidden()

            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .help(help ?? label)
    }
}

/// The theme editor: every color labeled with what it applies to, grouped
/// by terminal element. Presented in its own window, from "Create…" on the
/// Appearance screen.
private struct ThemeCreatorView: View {
    let ghostty: Ghostty.App
    @ObservedObject var store: GuiConfigStore
    @ObservedObject var catalog: ThemeCatalog
    let seed: TerminalTheme?

    /// Called once the theme is written and applied. The editor is a window,
    /// so finishing has to mean the window goes away — it used to stay open
    /// under a line of text saying what had just happened, which is a receipt
    /// for something the screen behind it already shows.
    let onSaved: () -> Void

    @State private var name = ""
    @State private var background = Color(nsColor: NSColor(hex: "#282a36")!)
    @State private var foreground = Color(nsColor: NSColor(hex: "#f8f8f2")!)
    @State private var cursor = Color(nsColor: NSColor(hex: "#f8f8f2")!)
    @State private var selectionBackground = Color(nsColor: NSColor(hex: "#44475a")!)
    @State private var palette: [Color] = Self.draculaPalette.map { Color(nsColor: $0) }
    @State private var isPickingSeed = false
    @State private var startedFrom: String?

    private static let draculaPalette: [NSColor] = [
        "#21222c", "#ff5555", "#50fa7b", "#f1fa8c",
        "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
        "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5",
        "#d6acff", "#ff92df", "#a4ffff", "#ffffff",
    ].map { NSColor(hex: $0)! }

    /// Each ANSI slot labeled by what programs actually colour with it, so
    /// the choice reads as a decision about the terminal rather than a
    /// number. The ANSI name stays in the tooltip, since it is what themes
    /// and documentation call it.
    private static let ansiRoles: [(role: String, ansi: String)] = [
        ("Dim", "Black"),
        ("Errors", "Red"),
        ("Success", "Green"),
        ("Warnings", "Yellow"),
        ("Folders", "Blue"),
        ("Keywords", "Magenta"),
        ("Paths", "Cyan"),
        ("Text", "White"),
    ]

    private let ansiColumns = Array(
        repeating: GridItem(.flexible(), spacing: 6),
        count: 8
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Create Theme")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer()

                Button(startedFrom.map { "Started from \($0)" } ?? "Start from…") {
                    isPickingSeed = true
                }
                .font(.caption)
            }

            TextField("", text: $name, prompt: Text("Theme name"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)

            livePreview

            colorGroup("Terminal") {
                HStack(spacing: 14) {
                    labeledWell("Background", $background)
                    labeledWell("Text", $foreground)
                    labeledWell("Cursor", $cursor)
                    labeledWell("Selection", $selectionBackground)
                    Spacer()
                }
            }

            colorGroup("Output") {
                LazyVGrid(columns: ansiColumns, spacing: 6) {
                    ForEach(0..<8, id: \.self) { index in
                        NamedColorWell(
                            label: Self.ansiRoles[index].role,
                            help: "ANSI \(index) — \(Self.ansiRoles[index].ansi)",
                            color: $palette[index]
                        )
                    }
                }
            }

            colorGroup("Bold and Bright Output") {
                LazyVGrid(columns: ansiColumns, spacing: 6) {
                    ForEach(8..<16, id: \.self) { index in
                        NamedColorWell(
                            label: Self.ansiRoles[index - 8].role,
                            help: "ANSI \(index) — Bright \(Self.ansiRoles[index - 8].ansi)",
                            color: $palette[index]
                        )
                    }
                }
            }

            HStack {
                Spacer()

                Button("Save & Apply") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        // Opens on the theme in use, which is the one most likely wanted as
        // a starting point, but any theme can be picked instead. Seeding
        // also watches for the seed arriving: the catalog loads a beat after
        // this view first appears, so on that pass there is nothing to seed
        // from yet.
        .onAppear { seedIfNeeded() }
        .onChange(of: seed?.name) { _ in seedIfNeeded() }
        .sheet(isPresented: $isPickingSeed) {
            ThemeSeedPicker(
                catalog: catalog,
                currentName: store.currentThemeName ?? ""
            ) { picked in
                populate(from: picked)
            }
        }
    }

    /// Shows each role doing its job, so a swatch can be judged by what it
    /// does to real output instead of in isolation.
    private var livePreview: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("❯").foregroundStyle(palette[2])
                Text("ls").foregroundStyle(foreground)
            }
            HStack(spacing: 8) {
                Text("src").foregroundStyle(palette[4])
                Text("readme.md").foregroundStyle(foreground)
                Text("link → ../lib").foregroundStyle(palette[6])
            }
            Text("warning: 2 unused imports").foregroundStyle(palette[3])
            Text("error: build failed").foregroundStyle(palette[1])
            HStack(spacing: 4) {
                Text("❯").foregroundStyle(palette[2])
                Text("git commit").foregroundStyle(foreground)
                Rectangle()
                    .fill(cursor)
                    .frame(width: 5, height: 11)
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private func colorGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
    }

    private func labeledWell(_ label: String, _ binding: Binding<Color>) -> some View {
        HStack(spacing: 6) {
            ColorPicker("", selection: binding, supportsOpacity: false)
                .labelsHidden()
            Text(label)
                .font(.system(size: 11))
        }
    }

    /// Fills the editor from the seed once, leaving edits alone afterwards.
    private func seedIfNeeded() {
        guard startedFrom == nil, let seed else { return }
        populate(from: seed)
    }

    private func populate(from theme: TerminalTheme) {
        startedFrom = theme.name
        name = theme.source == .user ? theme.name : "\(theme.name) Custom"
        if let value = theme.background { background = Color(nsColor: value) }
        if let value = theme.foreground { foreground = Color(nsColor: value) }
        if let value = theme.cursorColor { cursor = Color(nsColor: value) }
        if let value = theme.selectionBackground { selectionBackground = Color(nsColor: value) }
        for index in 0..<16 {
            if let value = theme.palette[index] { palette[index] = Color(nsColor: value) }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        var content = ""
        content += "background = \(hex(background))\n"
        content += "foreground = \(hex(foreground))\n"
        content += "cursor-color = \(hex(cursor))\n"
        content += "selection-background = \(hex(selectionBackground))\n"
        for index in 0..<16 {
            content += "palette = \(index)=\(hex(palette[index]))\n"
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: store.themesDirURL, withIntermediateDirectories: true)
        let url = store.themesDirURL.appendingPathComponent(trimmedName)
        try? content.write(to: url, atomically: true, encoding: .utf8)

        store.set("theme", url.path)
        store.apply(ghostty: ghostty)
        catalog.reload()
        onSaved()
    }

    private func hex(_ color: Color) -> String {
        NSColor(color).hexString ?? "#000000"
    }
}

/// Picks the theme the editor starts from. The same cards as the browser,
/// but choosing one fills the fields in instead of applying it.
private struct ThemeSeedPicker: View {
    @ObservedObject var catalog: ThemeCatalog
    let currentName: String
    let onPick: (TerminalTheme) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [TerminalTheme] {
        guard !search.isEmpty else { return catalog.themes }
        return catalog.themes.filter {
            $0.name.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("", text: $search, prompt: Text(verbatim: "Search \(catalog.themes.count) themes"))
                    .textFieldStyle(.plain)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150), spacing: 10)],
                        spacing: 10
                    ) {
                        ForEach(filtered) { theme in
                            ThemeCard(theme: theme, isSelected: theme.name == currentName) {
                                onPick(theme)
                                dismiss()
                            }
                            .id(theme.name)
                        }
                    }
                    .padding(12)
                }
                .onAppear {
                    guard !currentName.isEmpty else { return }
                    proxy.scrollTo(currentName, anchor: .center)
                }
            }
        }
        .frame(width: 640, height: 520)
    }
}

/// A window for building a theme, so the editor isn't a tail on the
/// Appearance screen competing with the settings above it.
@MainActor
final class ThemeCreatorWindowController: NSWindowController {
    static let shared = ThemeCreatorWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = "Create Theme"
        window.isReleasedWhenClosed = false

        /// The floor lives here rather than in a SwiftUI frame, because the
        /// height above it is now measured from the content — a minimum
        /// written into the view would be a second answer, and the taller of
        /// the two would win whether or not it was the true one.
        window.contentMinSize = NSSize(width: 640, height: 360)
        window.center()
        window.setFrameAutosaveName("PhantomThemeCreator")
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(ghostty: Ghostty.App, store: GuiConfigStore) {
        let host = NSHostingView(
            rootView: ThemeCreatorWindowView(ghostty: ghostty, store: store) { [weak self] in
                self?.close()
            }
            .themedChrome()
        )
        window?.contentView = host
        fitToContent(host)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Takes the window's height from the editor instead of from the number it
    /// was created with, which left a band of empty window under the last row.
    ///
    /// A hosting view's fitting height is its content's own even with a scroll
    /// view in between, so the scroll can stay for the case this doesn't fit:
    /// a display shorter than the editor, which the visible frame is the
    /// measure of.
    ///
    /// The floor is applied here too. `contentMinSize` governs what a drag can
    /// do to the window and not what this assigns it, so a measurement that
    /// came back small would otherwise open a window smaller than the one the
    /// user is allowed to make.
    private func fitToContent(_ host: NSView) {
        guard let window else { return }

        host.layoutSubtreeIfNeeded()
        let wanted = host.fittingSize.height
        guard wanted > 0 else { return }

        let screen = window.screen ?? NSScreen.main
        let chrome = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let ceiling = (screen?.visibleFrame.height ?? wanted + chrome) - chrome

        var size = window.contentRect(forFrameRect: window.frame).size
        size.height = min(max(wanted, window.contentMinSize.height), ceiling)
        window.setContentSize(size)
    }
}

private struct ThemeCreatorWindowView: View {
    let ghostty: Ghostty.App
    @ObservedObject var store: GuiConfigStore
    let onSaved: () -> Void

    @StateObject private var catalog: ThemeCatalog

    init(ghostty: Ghostty.App, store: GuiConfigStore, onSaved: @escaping () -> Void) {
        self.ghostty = ghostty
        self.store = store
        self.onSaved = onSaved
        _catalog = StateObject(wrappedValue: ThemeCatalog(userThemesDir: store.themesDirURL))
    }

    var body: some View {
        ScrollView {
            ThemeCreatorView(
                ghostty: ghostty,
                store: store,
                catalog: catalog,
                seed: catalog.themes.first { $0.name == store.currentThemeName },
                onSaved: onSaved
            )
            .padding(16)
        }
        .frame(minWidth: 640)
        .onAppear { catalog.loadIfNeeded() }
    }
}

/// A dedicated window listing every theme in the catalog — curated or
/// not — with the same live preview cards. Click applies; right-click
/// offers the theme's source.
@MainActor
final class AllThemesWindowController: NSWindowController {
    static let shared = AllThemesWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = "All Themes"
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("PhantomAllThemes")
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(ghostty: Ghostty.App, store: GuiConfigStore) {
        window?.contentView = NSHostingView(
            rootView: AllThemesView(ghostty: ghostty, store: store).themedChrome()
        )
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct AllThemesView: View {
    let ghostty: Ghostty.App
    @ObservedObject var store: GuiConfigStore

    @StateObject private var catalog: ThemeCatalog

    @State private var search = ""
    @State private var sourceTheme: TerminalTheme?

    init(ghostty: Ghostty.App, store: GuiConfigStore) {
        self.ghostty = ghostty
        self.store = store
        _catalog = StateObject(wrappedValue: ThemeCatalog(userThemesDir: store.themesDirURL))
    }

    private var currentTheme: String {
        store.currentThemeName ?? ""
    }

    private var filtered: [TerminalTheme] {
        guard !search.isEmpty else { return catalog.themes }
        return catalog.themes.filter {
            $0.name.localizedCaseInsensitiveContains(search)
        }
    }

    private var sections: [(title: String, themes: [TerminalTheme])] {
        var user: [TerminalTheme] = []
        var dark: [TerminalTheme] = []
        var light: [TerminalTheme] = []

        for theme in filtered {
            if theme.source == .user {
                user.append(theme)
            } else if theme.background?.isLightColor == true {
                light.append(theme)
            } else {
                dark.append(theme)
            }
        }

        return [
            ("Custom Themes", user),
            ("Dark", dark),
            ("Light", light),
        ].filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    "",
                    text: $search,
                    prompt: Text(verbatim: "Filter \(catalog.themes.count) themes")
                )
                .textFieldStyle(.plain)
            }
            .padding(10)

            Divider()

            if catalog.isLoading && catalog.themes.isEmpty {
                Spacer()
                ProgressView("Loading themes…")
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(sections, id: \.title) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(verbatim: "\(section.title) (\(section.themes.count))")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 150), spacing: 10)],
                                    spacing: 10
                                ) {
                                    ForEach(section.themes) { theme in
                                        ThemeCard(
                                            theme: theme,
                                            isSelected: theme.name == currentTheme
                                        ) {
                                            store.setTheme(theme)
                                            store.apply(ghostty: ghostty)
                                        }
                                        .contextMenu {
                                            Button("View Source…") {
                                                sourceTheme = theme
                                            }
                                            Button("Reveal in Finder") {
                                                NSWorkspace.shared.activateFileViewerSelecting([theme.url])
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(14)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(minWidth: 700, minHeight: 480)
        .onAppear { catalog.loadIfNeeded() }
        .sheet(item: $sourceTheme) { theme in
            ThemeSourceView(theme: theme)
        }
    }
}

/// Read-only view of a theme file's definition.
private struct ThemeSourceView: View {
    let theme: TerminalTheme

    @Environment(\.dismiss) private var dismiss

    private var contents: String {
        (try? String(contentsOf: theme.url, encoding: .utf8))
            ?? "Could not read \(theme.url.path)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(theme.name)
                    .font(.headline)
                Text(theme.url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(12)

            Divider()

            ScrollView {
                Text(contents)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }

            Divider()

            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([theme.url])
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 500, height: 560)
    }
}
