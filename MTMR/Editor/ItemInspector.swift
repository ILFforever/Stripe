//
//  ItemInspector.swift
//  Stripe
//
//  The right-hand pane: every setting of the selected item, in collapsible
//  sections. Section open/closed state is remembered across items.
//

import Combine
import SwiftUI

struct ItemInspector: View {
    @ObservedObject var item: EditorItem
    let isTopLevel: Bool
    /// For the Items section to open a child. A plain reference, not a Binding:
    /// SwiftUI can't tell a Binding is unchanged, so it would rebuild this whole
    /// form every time the window redraws (e.g. on each reorder during a drag).
    let session: EditorSession

    /// The tab shown; stays as you move between items.
    @AppStorage("inspector.tab") private var tab = Tab.item.rawValue

    enum Tab: String, CaseIterable {
        case item, style, behavior, advanced

        var title: String {
            switch self {
            case .item: return "Item"
            case .style: return "Style"
            case .behavior: return "Behavior"
            case .advanced: return "Advanced"
            }
        }
    }

    /// Items that aren't drawn (swipe gestures) have no Style.
    private var tabs: [Tab] {
        item.info.isVisibleOnBar ? Tab.allCases : [.item, .behavior, .advanced]
    }

    private var shownTab: Tab {
        let chosen = Tab(rawValue: tab) ?? .item
        return tabs.contains(chosen) ? chosen : .item
    }

    /// Which way the last tab change went, so the content slides in from that side.
    private let forwardState = State(initialValue: true)

    private func select(_ new: Tab) {
        guard new != shownTab else { return }
        forwardState.wrappedValue = (tabs.firstIndex(of: new) ?? 0) > (tabs.firstIndex(of: shownTab) ?? 0)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { tab = new.rawValue }
    }

    private var slide: AnyTransition {
        let forward = forwardState.wrappedValue
        return .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                           removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header
                TabSwitcher(selection: shownTab, options: tabs.map { ($0, $0.title) }, select: select)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)
            Divider()
            ScrollView {
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 18) {
                        switch shownTab {
                        case .item: itemTab
                        case .style: styleTab
                        case .behavior: behaviorTab
                        case .advanced: advancedTab
                        }
                    }
                    .padding(20)
                    .id(shownTab)
                    .transition(slide)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .clipped()
        }
    }

    // MARK: Tabs

    /// What a tap on Now Playing does for each "tapOpens" choice.
    private static let nowPlayingTaps: [(id: String, name: String, does: String, help: String)] = [
        ("none", "Play/Pause", "Plays or pauses", "A tap plays or pauses whatever is playing."),
        ("side", "Side", "Slides out controls", "A tap slides previous, play/pause and next out beside the key; they slide back after a few seconds, or on another tap."),
        ("full", "Full", "Opens the controls", "A tap opens the controls across the bar: the track, how far in it is, and previous, play/pause and next, with a back arrow at the end."),
    ]

    /// What the double tap and press and hold can be set to, and what each does by default.
    private static let nowPlayingGestures: [(id: String, title: String)] = MusicBarItem.Gesture.allCases.map { ($0.rawValue, $0.title) }

    /// A gesture's setting, with previous and next as the unset defaults.
    private func nowPlayingGesture(_ key: String, fallback: String) -> String {
        item[string: key] ?? fallback
    }

    /// Now Playing's Controls: what each gesture does with the current settings.
    @ViewBuilder
    private var nowPlayingControls: some View {
        let tap = item[string: "tapOpens"] ?? "none"
        let titles = Dictionary(uniqueKeysWithValues: ItemInspector.nowPlayingGestures.map { ($0.id, $0.title) })
        FieldRow(label: "Tap") {
            Text(ItemInspector.nowPlayingTaps.first { $0.id == tap }?.does ?? "").foregroundColor(.secondary)
        }
        FieldRow(label: "Double tap") {
            Text(titles[nowPlayingGesture("doubleTapDoes", fallback: "previous")] ?? "").foregroundColor(.secondary)
        }
        FieldRow(label: "Press and hold") {
            Text(titles[nowPlayingGesture("holdDoes", fallback: "next")] ?? "").foregroundColor(.secondary)
        }
        Text("Change them under Click controls. The Mini player design has keys of its own for previous, play/pause and next.")
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.vertical, 8)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Now Playing's Click controls: what a tap, a double tap and a press and hold do.
    @ViewBuilder
    private var nowPlayingClickControls: some View {
        let taps = ItemInspector.nowPlayingTaps
        let chosen = item[string: "tapOpens"] ?? "none"
        FieldRow(label: "Tap", help: taps.first { $0.id == chosen }?.help) {
            Picker("", selection: Binding(get: { chosen }, set: { item[string: "tapOpens"] = $0 == "none" ? nil : $0 })) {
                ForEach(taps, id: \.id) { choice in
                    Text(choice.name).tag(choice.id)
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        gestureRow("Double tap", key: "doubleTapDoes", fallback: "previous")
        gestureRow("Press and hold", key: "holdDoes", fallback: "next")
    }

    /// One gesture's menu: it keeps its default when unset.
    private func gestureRow(_ label: String, key: String, fallback: String) -> some View {
        FieldRow(label: label) {
            Picker("", selection: Binding(get: { nowPlayingGesture(key, fallback: fallback) },
                                          set: { item[string: key] = $0 == fallback ? nil : $0 })) {
                ForEach(ItemInspector.nowPlayingGestures, id: \.id) { choice in
                    Text(choice.title).tag(choice.id)
                }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
        }
    }

    /// What the item is: its own settings, the Battery Overview, a container's items.
    @ViewBuilder
    private var itemTab: some View {
        if item.type == "music" {
            InspectorGroup(title: "Controls", symbol: "playpause") {
                nowPlayingControls
            }
            InspectorGroup(title: "Click controls", symbol: "hand.tap") {
                nowPlayingClickControls
            }
        }
        if !item.info.fields.isEmpty {
            InspectorGroup(title: item.info.name, symbol: item.info.symbol) {
                ForEach(item.info.fields) { field in
                    fieldView(field)
                }
            }
        }
        if item.type == "battery" {
            InspectorGroup(title: "Battery Overview", symbol: "rectangle.split.3x1") {
                BatteryPanelSection(item: item, preview: BatteryPanelPreviewModel.shared)
            }
        }
        if let page = item.info.performancePage {
            InspectorGroup(title: page == .gpu ? "GPU Page" : page == .cpu ? "CPU Page" : "Performance Page",
                           symbol: "rectangle.split.3x1") {
                PerformancePanelSection(item: item, kind: page, preview: PerformancePanelPreviewModel.shared)
            }
        }
        if item.info.isContainer {
            InspectorGroup(title: "Items", symbol: "square.stack") {
                ContainerItemsEditor(container: item, session: session)
            }
        }
        if item.info.fields.isEmpty && item.type != "battery" && item.info.performancePage == nil && !item.info.isContainer {
            Text("\(item.info.name) has no settings of its own. How it looks is under Style, and what it does under Behavior.")
                .foregroundColor(.secondary)
        }
    }

    /// How it looks: only the styles it sets (plus the essentials), and a menu to add others.
    @ViewBuilder
    private var styleTab: some View {
        if item.info.designs != nil || item.info.performancePage != nil {
            InspectorGroup(title: "Design", symbol: "sparkles") {
                if let designs = item.info.designs {
                    // A widget with its own designs and an MTMR look offers that look as
                    // one more design, stored as "theme": "mtmr" rather than a design.
                    let classic = designs.key == "design" ? item.info.mtmrLook : nil
                    let options = designs.options + (classic.map { [("mtmr", "MTMR classic", $0)] } ?? [])
                    let chosen = classic != nil && item[string: "theme"] == "mtmr" ? "mtmr" : (item[string: designs.key] ?? designs.fallback)
                    FieldRow(label: "Design", help: options.first { $0.0 == chosen }?.2) {
                        let picker = Picker("", selection: Binding(get: { chosen }, set: { choice in
                            if choice == "mtmr" {
                                item[string: "theme"] = "mtmr"
                                item[string: designs.key] = nil
                            } else {
                                if classic != nil { item[string: "theme"] = nil }
                                item[string: designs.key] = choice == designs.fallback ? nil : choice
                            }
                        })) {
                            ForEach(options, id: \.0) { option in
                                Text(option.1).tag(option.0)
                            }
                        }
                        // Segments for a few designs; a menu once they'd crowd the inspector.
                        if options.count > 4 {
                            picker.pickerStyle(.menu).labelsHidden().fixedSize()
                        } else {
                            picker.pickerStyle(.segmented).labelsHidden().fixedSize()
                        }
                    }
                }
                if item.info.performancePage != nil {
                    FieldRow(label: "Colors", help: item.type == "performance" ? "Here and on its page" : "On its page") {
                        Picker("", selection: Binding(get: { item[string: "colors"] ?? PerformancePalette.standard.id },
                                                      set: { item[string: "colors"] = $0 == PerformancePalette.standard.id ? nil : $0 })) {
                            ForEach(PerformancePalette.all, id: \.id) { palette in
                                Text(palette.name).tag(palette.id)
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                }
            }
        }
        if item.info.supportsIcon || item.info.supportsBackground {
            StyleEditor(item: item, whileOn: false).id(item.id)
        } else if item.info.designs == nil {
            Text("\(item.info.name) doesn't take styling. Its width is under Advanced.")
                .foregroundColor(.secondary)
        }
        if item.info.supportsButtonStyling {
            if hasOnState {
                StyleEditor(item: item, whileOn: true).id(item.id)
            } else {
                Text("To give it a different look while it's on, add an On when condition under Behavior.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    /// What it does, and when it shows or is on.
    @ViewBuilder
    private var behaviorTab: some View {
        if item.info.supportsActions {
            InspectorGroup(title: "Actions", symbol: "hand.tap") {
                ActionsEditor(item: item).id(item.id)
            }
        }
        InspectorGroup(title: "Shows when", symbol: "eye") {
            ConditionsEditor(item: item, base: "when", verb: "shows",
                             empty: "Always shows. Add a condition to show it only sometimes.").id(item.id)
        }
        if item.info.supportsButtonStyling {
            InspectorGroup(title: "On when", symbol: "power") {
                if let state = item.info.builtInActiveState {
                    Text("Built in: on while \(state). A condition here decides it instead.")
                        .font(.caption).foregroundColor(.secondary)
                        .padding(.vertical, 8)
                }
                ConditionsEditor(item: item, base: "activeWhen", verb: "is on",
                                 empty: item.info.builtInActiveState == nil
                                     ? "Never on. Add a condition to give it an on state, with its own look under Style."
                                     : "").id(item.id)
            }
        }
        if item.info.supportsButtonStyling {
            InspectorGroup(title: "Haptics", symbol: "waveform") {
                HapticsEditor(item: item)
            }
            if item.info.repeatsWhileHeld {
                InspectorGroup(title: "Hold", symbol: "repeat") {
                    HoldRepeatEditor(item: item)
                }
            }
        } else if item.info.isSlider {
            InspectorGroup(title: "Haptics", symbol: "waveform") {
                SliderHapticsEditor(item: item)
            }
        }
    }

    @ViewBuilder
    private var advancedTab: some View {
        if item.info.isVisibleOnBar {
            InspectorGroup(title: "Size", symbol: "arrow.left.and.right") {
                NumberFieldRow(label: "Width", placeholder: "Automatic", help: "In points; the bar is about 1000 wide",
                               value: number("width"))
            }
        }
        InspectorGroup(title: "JSON", symbol: "curlybraces") {
            RawJSONEditor(item: item)
        }
    }

    /// Toggles, and items with an "On when" condition.
    private var hasOnState: Bool {
        item.info.builtInActiveState != nil || item.fields["activeWhen"] != nil
    }

    private var header: some View {
        HStack(spacing: 12) {
            // Drawn like a key on the bar.
            Image(systemName: item.displaySymbol)
                .font(.system(size: 20))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: EditorStyle.boxRadius).fill(Color(white: 0.16)))
                .overlay(RoundedRectangle(cornerRadius: EditorStyle.boxRadius).stroke(Color.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                title
                Text(subtitle).foregroundColor(.secondary)
            }
            Spacer()
            // Where it sits on the bar; also set by dragging it there.
            if isTopLevel && item.info.isVisibleOnBar {
                Picker("Position", selection: Binding(get: { item.align }, set: { item.align = $0 })) {
                    Text("Left").tag("left")
                    Text("Center").tag("center")
                    Text("Right").tag("right")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Position on the bar. You can also drag the item there.")
            }
            itemMenu
        }
    }

    /// Save to My Items, duplicate or remove the item shown (inside a folder or group too).
    private var itemMenu: some View {
        Menu {
            Button("Save to My Items…") { SavedItems.promptSave(item) }
            Button("Duplicate") { item.document?.duplicate(item) }
            Divider()
            Button("Remove") {
                session.selection = nil
                withAnimation { item.document?.remove(item) }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Save to My Items, duplicate or remove")
    }

    /// The item's name, after the containers it's inside ("Folder / Hold to sleep");
    /// click a container's name to go back to it.
    private var title: some View {
        let ancestors = item.document?.ancestors(of: item) ?? []
        return HStack(spacing: 6) {
            ForEach(ancestors, id: \.id) { parent in
                Button(action: { session.selection = parent.id }) {
                    Text(parent.displayName).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .help("Back to \(parent.displayName)")
                Text("/").foregroundColor(Color.secondary.opacity(0.6))
            }
            Text(item.displayName)
        }
        .font(.title2.weight(.semibold))
        .lineLimit(1)
    }

    /// e.g. "Status · Network Speed", without repeating a name the title already shows.
    private var subtitle: String {
        var parts = [item.info.category]
        if item.displayName != item.info.name { parts.append(item.info.name) }
        if let count = item.children?.count { parts.append(count == 1 ? "1 item" : "\(count) items") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func fieldView(_ field: FieldSpec) -> some View {
        switch field.kind {
        case let .text(placeholder):
            TextFieldRow(label: field.label, placeholder: placeholder, text: string(field.path))
        case .multiline:
            MultilineRow(label: field.label, text: string(field.path))
        case let .number(placeholder):
            NumberFieldRow(label: field.label, placeholder: placeholder, value: number(field.path))
        case let .toggle(defaultValue):
            ToggleRow(label: field.label, defaultValue: defaultValue, value: bool(field.path))
        case let .choice(options):
            ChoiceRow(label: field.label, options: options, value: string(field.path))
        }
    }

    // Bindings into the item's JSON; empty values remove the key.

    private func string(_ path: String) -> Binding<String> {
        Binding(get: { item[string: path] ?? "" }, set: { item[string: path] = $0 })
    }

    private func number(_ path: String) -> Binding<Double?> {
        Binding(get: { item[number: path] }, set: { item[number: path] = $0 })
    }

    private func bool(_ path: String) -> Binding<Bool?> {
        Binding(get: { item[bool: path] }, set: { item[bool: path] = $0 })
    }
}

// MARK: - Style

/// The Style tab's rows: the essentials (icon, background) always, every other
/// style only once the item sets it, and an "Add Style" menu for the rest.
/// With `whileOn`, the same for how the item looks while it's on.
struct StyleEditor: View {
    @ObservedObject var item: EditorItem
    let whileOn: Bool
    /// Rows added from the menu but not set yet; they stay until the item changes.
    private let revealedState = State(initialValue: Set<Row>())
    private var revealed: Set<Row> {
        get { revealedState.wrappedValue }
        nonmutating set { revealedState.wrappedValue = newValue }
    }

    enum Row: String, CaseIterable {
        case title, icon, iconColor, background, fontSize, fontWeight, textColor, digits, pressed
        case onBackground, onIcon, onIconColor, onTextColor, onTitle

        var name: String {
            switch self {
            case .title, .onTitle: return "Title"
            case .icon, .onIcon: return "Icon"
            case .iconColor, .onIconColor: return "Icon color"
            case .background, .onBackground: return "Background"
            case .fontSize: return "Font size"
            case .fontWeight: return "Font weight"
            case .textColor, .onTextColor: return "Text color"
            case .digits: return "Fixed-width digits"
            case .pressed: return "Pressed color"
            }
        }

        /// The preset keys a row sets; it shows once any of them is set.
        var keys: [String] {
            switch self {
            case .title: return ["title"]
            case .icon: return ["symbol"]
            case .iconColor: return ["iconColor"]
            case .background: return ["background", "bordered", "style", "cornerRadius"]
            case .fontSize: return ["fontSize"]
            case .fontWeight: return ["fontWeight"]
            case .textColor: return ["textColor"]
            case .digits: return ["monospacedDigits"]
            case .pressed: return ["pressedBackground"]
            case .onBackground: return ["activeBackground"]
            case .onIcon: return ["activeSymbol"]
            case .onIconColor: return ["activeIconColor"]
            case .onTextColor: return ["activeTextColor"]
            case .onTitle: return ["activeTitle"]
            }
        }
    }

    /// The rows this item can have, in order, and which are always shown.
    private var available: [(row: Row, essential: Bool)] {
        let info = item.info
        if whileOn {
            return [(.onBackground, false), (.onIcon, false), (.onIconColor, false), (.onTextColor, false), (.onTitle, false)]
        }
        var rows: [(Row, Bool)] = []
        let hasTitleField = info.fields.contains { $0.path == "title" }
        if info.supportsIcon && !hasTitleField { rows.append((.title, false)) }
        if info.supportsIcon { rows.append((.icon, true)) }
        if info.supportsButtonStyling { rows.append((.iconColor, false)) }
        if info.supportsBackground { rows.append((.background, true)) }
        if info.supportsButtonStyling {
            rows += [(.fontSize, false), (.fontWeight, false), (.textColor, false), (.digits, false), (.pressed, false)]
        }
        return rows
    }

    private func isSet(_ row: Row) -> Bool {
        row.keys.contains { item.fields[path: $0] != nil }
    }

    private var shown: [(row: Row, essential: Bool)] {
        available.filter { $0.essential || isSet($0.row) || revealed.contains($0.row) }
    }

    private var addable: [Row] {
        available.filter { !$0.essential && !isSet($0.row) && !revealed.contains($0.row) }.map { $0.row }
    }

    var body: some View {
        InspectorGroup(title: whileOn ? "While on" : "Look", symbol: whileOn ? "power" : "paintpalette", accessory: { addMenu }) {
            if shown.isEmpty {
                Text(whileOn ? "Looks the same as when it's off. Add what should change while it's on."
                             : "Nothing set yet.")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.vertical, 10)
            }
            ForEach(shown, id: \.row) { entry in
                if entry.essential {
                    rowView(entry.row)
                } else {
                    RemovableRow(remove: { remove(entry.row) }) { rowView(entry.row) }
                }
            }
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(addable, id: \.self) { row in
                Button(row.name) { revealed.insert(row) }
            }
            if !addable.isEmpty {
                Divider()
                Button("Show All") { revealed.formUnion(addable) }
            }
        } label: {
            Label(whileOn ? "Add On Look" : "Add Style", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(addable.isEmpty)
    }

    private func remove(_ row: Row) {
        for key in row.keys { item.setRaw(key, nil) }
        revealed.remove(row)
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row {
        case .title: TextFieldRow(label: "Title", placeholder: "None", text: string("title"))
        case .icon: SymbolRow(label: "Icon", value: string("symbol"))
        case .iconColor: ColorRow(label: "Icon color", value: string("iconColor"), suggested: "#FFFFFF")
        case .background:
            BackgroundRow(item: item)
            if BackgroundRow.mode(of: item) != "none" { ShapeRow(item: item) }
        case .fontSize: NumberFieldRow(label: "Font size", placeholder: "15", value: number("fontSize"))
        case .fontWeight:
            ChoiceRow(label: "Font weight",
                      options: ["ultralight", "thin", "light", "regular", "medium", "semibold", "bold", "heavy", "black"],
                      value: string("fontWeight"))
        case .textColor: ColorRow(label: "Text color", value: string("textColor"), suggested: "#FFFFFF")
        case .digits:
            ToggleRow(label: "Fixed-width digits", help: "Keeps changing numbers from shifting",
                      defaultValue: false, value: Binding(get: { item[bool: "monospacedDigits"] }, set: { item[bool: "monospacedDigits"] = $0 }))
        case .pressed: ColorRow(label: "Pressed color", value: string("pressedBackground"), suggested: "#636366")
        case .onBackground: ColorRow(label: "Background", value: string("activeBackground"), suggested: "#30D158")
        case .onIcon: SymbolRow(label: "Icon", value: string("activeSymbol"))
        case .onIconColor: ColorRow(label: "Icon color", value: string("activeIconColor"), suggested: "#FFFFFF")
        case .onTextColor: ColorRow(label: "Text color", value: string("activeTextColor"), suggested: "#FFFFFF")
        case .onTitle: TextFieldRow(label: "Title", placeholder: "Same as off", text: string("activeTitle"))
        }
    }

    private func string(_ path: String) -> Binding<String> {
        Binding(get: { item[string: path] ?? "" }, set: { item[string: path] = $0 })
    }

    private func number(_ path: String) -> Binding<Double?> {
        Binding(get: { item[number: path] }, set: { item[number: path] = $0 })
    }
}

// MARK: - Conditions

/// "Shows when" / "On when": only the conditions the item has, each removable,
/// and a menu to add the others. All of them must hold.
struct ConditionsEditor: View {
    @ObservedObject var item: EditorItem
    /// "when" or "activeWhen".
    let base: String
    /// "shows" or "is on", for the help text.
    let verb: String
    let empty: String
    private let revealedState = State(initialValue: Set<String>())
    private var revealed: Set<String> {
        get { revealedState.wrappedValue }
        nonmutating set { revealedState.wrappedValue = newValue }
    }

    static let kinds = [("app", "App is"), ("notApp", "App is not"), ("time", "Time is"), ("script", "Command succeeds")]

    private func path(_ kind: String) -> String { "\(base).\(kind)" }

    private var shown: [(String, String)] {
        ConditionsEditor.kinds.filter { item[string: path($0.0)] != nil || revealed.contains($0.0) }
    }

    private var addable: [(String, String)] {
        ConditionsEditor.kinds.filter { item[string: path($0.0)] == nil && !revealed.contains($0.0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if shown.isEmpty && !empty.isEmpty {
                Text(empty).font(.caption).foregroundColor(.secondary).padding(.vertical, 10)
            } else if shown.count > 1 {
                Text("It \(verb) while all of these are true.").font(.caption).foregroundColor(.secondary).padding(.top, 8)
            }
            ForEach(shown, id: \.0) { kind, label in
                RemovableRow(remove: { remove(kind) }) { conditionRow(kind, label) }
            }
            Menu {
                ForEach(addable, id: \.0) { kind, label in
                    Button(label) { revealed.insert(kind) }
                }
            } label: {
                Label("Add Condition", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(addable.isEmpty)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func conditionRow(_ kind: String, _ label: String) -> some View {
        switch kind {
        case "app", "notApp":
            AppRuleRow(label: label, placeholder: "Safari", text: string(path(kind)))
        case "time":
            TextFieldRow(label: label, placeholder: "09:00-18:00", text: string(path(kind)))
        default:
            FieldRow(label: label, help: "Holds while it exits with 0") {
                HStack(spacing: 6) {
                    TextField("pgrep -q Zoom", text: string(path(kind)))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 220)
                    Text("every").foregroundColor(.secondary)
                    TextField("10", value: Binding(get: { item[number: "\(base).every"] },
                                                  set: { item[number: "\(base).every"] = $0 }),
                              formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 44)
                    Text("s").foregroundColor(.secondary)
                }
            }
        }
    }

    private func remove(_ kind: String) {
        item[string: path(kind)] = nil
        if kind == "script" { item[number: "\(base).every"] = nil }
        revealed.remove(kind)
    }

    private func string(_ path: String) -> Binding<String> {
        Binding(get: { item[string: path] ?? "" }, set: { item[string: path] = $0 })
    }
}

// MARK: - Actions

struct ActionsEditor: View {
    @ObservedObject var item: EditorItem

    static let triggers = [("singleTap", "Tap"), ("doubleTap", "Double tap"), ("tripleTap", "Triple tap"), ("longTap", "Press and hold")]
    static let kinds = [("shellScript", "Run shell command"), ("appleScript", "Run AppleScript"), ("openUrl", "Open URL"),
                        ("keyPress", "Press key"), ("hidKey", "Media / system key")]
    static let hidKeys: [(Int, String)] = [(0, "Volume up"), (1, "Volume down"), (7, "Mute"), (2, "Brightness up"),
                                           (3, "Brightness down"), (16, "Play / pause"), (17, "Next"), (18, "Previous"),
                                           (21, "Keyboard light up"), (22, "Keyboard light down")]

    private var actions: [[String: JSONValue]] {
        item.fields["actions"]?.array?.compactMap { $0.object } ?? []
    }

    private var hasLegacyActions: Bool {
        item.fields["action"] != nil || item.fields["longAction"] != nil
    }

    /// The action open for editing; the others show as one readable line each.
    private let expandedState = State<Int?>(initialValue: nil)
    private var expanded: Int? {
        get { expandedState.wrappedValue }
        nonmutating set { expandedState.wrappedValue = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasLegacyActions {
                Label("This item also uses older \"action\"/\"longAction\" keys. Edit those under Advanced › JSON.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.vertical, 8)
            }
            if actions.isEmpty {
                Text(hasBuiltInAction ? "Uses its built-in action. An action here replaces it for the same trigger." : "No actions yet.")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.vertical, 10)
            }
            ForEach(actions.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 8) {
                    summaryLine(index)
                    if expanded == index {
                        actionCard(index)
                    }
                }
                .padding(.vertical, 6)
                Divider().opacity(0.5)
            }
            Button(action: addAction) {
                Label("Add Action", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Tap → Run open -a Safari": click to open or close its editor.
    private func summaryLine(_ index: Int) -> some View {
        let action = actions[index]
        let trigger = ActionsEditor.triggers.first { $0.0 == action["trigger"]?.string }?.1 ?? "Tap"
        let (verb, detail) = describe(action)
        return HStack(spacing: 8) {
            Button(action: { expanded = expanded == index ? nil : index }) {
                HStack(spacing: 8) {
                    Text(trigger).fontWeight(.semibold).frame(width: 100, alignment: .leading)
                    Image(systemName: "arrow.right").font(.caption).foregroundColor(.secondary)
                    Text(verb).foregroundColor(.secondary)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                    }
                    Spacer()
                    Image(systemName: expanded == index ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: { removeAction(index) }) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Remove action")
        }
    }

    /// What an action does, in words and its key detail: ("Run", "open -a Safari").
    private func describe(_ action: [String: JSONValue]) -> (String, String) {
        switch action["action"]?.string ?? "shellScript" {
        case "appleScript":
            let first = action["actionAppleScript"]?.object?["inline"]?.string?.split(separator: "\n").first.map(String.init) ?? ""
            return ("Run AppleScript", first)
        case "openUrl":
            return ("Open", action["url"]?.string ?? "")
        case "keyPress":
            return ("Press key code", action["keycode"]?.number.map { String(Int($0)) } ?? "")
        case "hidKey":
            let code = Int(action["keycode"]?.number ?? -1)
            return ("Press", ActionsEditor.hidKeys.first { $0.0 == code }?.1 ?? "a system key")
        default:
            if isShellCommandForm(action) {
                return ("Run", action["shellArguments"]?.array?.last?.string ?? "")
            }
            let exe = action["executablePath"]?.string ?? ""
            let args = action["shellArguments"]?.array?.compactMap { $0.string }.joined(separator: " ") ?? ""
            return ("Run", [exe, args].filter { !$0.isEmpty }.joined(separator: " "))
        }
    }

    private var hasBuiltInAction: Bool {
        ["escape", "delete", "volumeUp", "volumeDown", "mute", "play", "next", "previous", "brightnessUp",
         "brightnessDown", "sleep", "displaySleep", "cpu", "dnd", "nightShift", "darkMode", "close", "battery", "music",
         "pomodoro", "inputsource", "illuminationUp", "illuminationDown", "exitTouchbar"].contains(item.type)
    }

    private func actionCard(_ index: Int) -> some View {
        let action = actions[index]
        let kind = action["action"]?.string ?? "shellScript"
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: binding(index, "trigger", default: "singleTap")) {
                    ForEach(ActionsEditor.triggers, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden().frame(width: 140)
                Picker("", selection: binding(index, "action", default: "shellScript")) {
                    ForEach(ActionsEditor.kinds, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden().frame(width: 190)
                Spacer()
            }
            switch kind {
            case "shellScript":
                if isShellCommandForm(action) {
                    TextField("Command, e.g. open -a Safari", text: shellCommand(index))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                } else {
                    TextField("Executable", text: binding(index, "executablePath", default: ""))
                        .textFieldStyle(.roundedBorder)
                    TextField("Arguments, separated by commas", text: arguments(index))
                        .textFieldStyle(.roundedBorder)
                }
            case "appleScript":
                TextEditor(text: nestedBinding(index, "actionAppleScript", "inline"))
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
            case "openUrl":
                TextField("https://…", text: binding(index, "url", default: ""))
                    .textFieldStyle(.roundedBorder)
            case "hidKey":
                Picker("Key", selection: keycode(index)) {
                    ForEach(ActionsEditor.hidKeys, id: \.0) { Text($0.1).tag($0.0) }
                }
                .frame(maxWidth: 260)
            default: // keyPress
                HStack {
                    Text("Key code")
                    TextField("53 = Esc", value: keycode(index), formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                    Text("macOS virtual key code").font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    // MARK: Editing

    private func update(_ index: Int, _ change: (inout [String: JSONValue]) -> Void) {
        var list = actions
        guard list.indices.contains(index) else { return }
        change(&list[index])
        item.setRaw("actions", .array(list.map { .object($0) }))
    }

    private func addAction() {
        var list = actions
        let trigger = list.contains { $0["trigger"]?.string == "singleTap" } ? "longTap" : "singleTap"
        list.append(["trigger": .string(trigger), "action": .string("shellScript"),
                     "executablePath": .string("/bin/sh"), "shellArguments": .array([.string("-c"), .string("")])])
        item.setRaw("actions", .array(list.map { .object($0) }))
        expanded = list.count - 1 // open the new one for editing
    }

    private func removeAction(_ index: Int) {
        if expanded == index { expanded = nil } else if let open = expanded, open > index { expanded = open - 1 }
        var list = actions
        list.remove(at: index)
        item.setRaw("actions", list.isEmpty ? nil : .array(list.map { .object($0) }))
    }

    private func binding(_ index: Int, _ key: String, default fallback: String) -> Binding<String> {
        Binding(get: { actions.indices.contains(index) ? actions[index][key]?.string ?? fallback : fallback },
                set: { value in update(index) { $0[key] = .string(value) } })
    }

    private func nestedBinding(_ index: Int, _ key: String, _ subkey: String) -> Binding<String> {
        Binding(get: { actions.indices.contains(index) ? actions[index][key]?.object?[subkey]?.string ?? "" : "" },
                set: { value in update(index) { $0[key] = .object([subkey: .string(value)]) } })
    }

    private func keycode(_ index: Int) -> Binding<Int> {
        Binding(get: { Int(actions.indices.contains(index) ? actions[index]["keycode"]?.number ?? 0 : 0) },
                set: { value in update(index) { $0["keycode"] = .number(Double(value)) } })
    }

    /// Commands are stored as /bin/sh -c "<command>", shown as one field.
    private func isShellCommandForm(_ action: [String: JSONValue]) -> Bool {
        let exe = action["executablePath"]?.string ?? "/bin/sh"
        let args = action["shellArguments"]?.array?.compactMap { $0.string } ?? ["-c", ""]
        return exe == "/bin/sh" && args.count == 2 && args[0] == "-c"
    }

    private func shellCommand(_ index: Int) -> Binding<String> {
        Binding(get: { actions.indices.contains(index) ? actions[index]["shellArguments"]?.array?.last?.string ?? "" : "" },
                set: { value in update(index) {
                    $0["executablePath"] = .string("/bin/sh")
                    $0["shellArguments"] = .array([.string("-c"), .string(value)])
                } })
    }

    private func arguments(_ index: Int) -> Binding<String> {
        Binding(get: {
            guard actions.indices.contains(index) else { return "" }
            return actions[index]["shellArguments"]?.array?.compactMap { $0.string }.joined(separator: ", ") ?? ""
        }, set: { value in update(index) {
            let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            $0["shellArguments"] = .array(parts.map { .string($0) })
        } })
    }
}

// MARK: - Raw JSON

struct RawJSONEditor: View {
    @ObservedObject var item: EditorItem
    private let textState = State(initialValue: "")
    private let errorState = State<String?>(initialValue: nil)
    private var error: String? {
        get { errorState.wrappedValue }
        nonmutating set { errorState.wrappedValue = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: textState.projectedValue)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
            if let error = error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundColor(.red).font(.caption)
            }
            HStack {
                Button("Apply", action: apply).keyboardShortcut(.return, modifiers: .command)
                Button("Revert") { reload() }
                Spacer()
                Text("Every key is supported here, including ones without a control above.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
        .onAppear(perform: reload)
        .onChange(of: item.id) { _ in reload() }
    }

    private func reload() {
        textState.wrappedValue = item.json.pretty()
        error = nil
    }

    private func apply() {
        do {
            guard let object = try JSONValue.parse(textState.wrappedValue).object else {
                error = "An item must be a JSON object: { … }"
                return
            }
            guard object["type"]?.string != nil else {
                error = "The item needs a \"type\"."
                return
            }
            item.replaceAll(with: object)
            error = nil
        } catch {
            self.error = "Invalid JSON: \(error.localizedDescription)"
        }
    }
}

// MARK: - Background and shape

/// One choice instead of separate "border", "background" and "pill" switches
/// that could contradict each other.
/// Tints glass with a color, or leaves it clear: a switch, and a color well once on.
struct GlassTintRow: View {
    var label = "Tint"
    let help: String
    @Binding var value: String?

    var body: some View {
        FieldRow(label: label, help: help) {
            HStack(spacing: 8) {
                if value != nil {
                    ColorPicker("", selection: Binding(
                        get: { Color(nsColor: value?.namedOrHexColor ?? .systemBlue) },
                        set: { value = NSColor($0).hexString }
                    ), supportsOpacity: false)
                        .labelsHidden()
                }
                Toggle("", isOn: Binding(get: { value != nil }, set: { value = $0 ? "#0A84FF" : nil }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }
}

struct BackgroundRow: View {
    @ObservedObject var item: EditorItem

    private var mode: String { BackgroundRow.mode(of: item) }

    /// Whether the bar's Theme makes keys glass (they follow it unless they choose).
    private static func themeGlass(_ item: EditorItem) -> Bool {
        item.document?.bar["glassKeys"]?.bool == true
    }

    static func mode(of item: EditorItem) -> String {
        if item[string: "background"] != nil { return "color" }
        let bordered = item[bool: "bordered"] ?? !item.borderlessByDefault
        guard bordered else { return "none" }
        return (item[bool: "glass"] ?? themeGlass(item)) ? "glass" : "standard"
    }

    /// "bordered" only where it differs from what the item does by default.
    private func setBordered(_ bordered: Bool) {
        item[bool: "bordered"] = bordered == !item.borderlessByDefault ? nil : bordered
    }

    /// "glass" only where it differs from the Theme.
    private func setGlass(_ glass: Bool) {
        item[bool: "glass"] = glass == BackgroundRow.themeGlass(item) ? nil : glass
    }

    private var help: String? {
        switch mode {
        case "standard": return "The standard gray key"
        case "glass": return item[bool: "glass"] == nil ? "Glass, from the bar's Theme" : "Translucent: the bar's background shows through"
        default: return nil
        }
    }

    var body: some View {
        FieldRow(label: "Background", help: help) {
            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { mode }, set: setMode)) {
                    Text("Standard").tag("standard")
                    Text("Glass").tag("glass")
                    Text("None").tag("none")
                    Text("Color").tag("color")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 270)
                if mode == "color" {
                    ColorPicker("", selection: Binding(
                        get: { Color(nsColor: item[string: "background"]?.namedOrHexColor ?? .clear) },
                        set: { item[string: "background"] = NSColor($0).hexString }
                    ), supportsOpacity: false)
                        .labelsHidden()
                }
            }
        }
        if mode == "glass" {
            GlassTintRow(help: "Glass washed with a color; the background still shows through",
                         value: Binding(get: { item[string: "glassTint"] }, set: { item[string: "glassTint"] = $0 }))
        }
    }

    private func setMode(_ mode: String) {
        switch mode {
        case "color":
            item[string: "background"] = item[string: "background"] ?? "#444444"
            item[bool: "bordered"] = nil
            item[bool: "glass"] = nil
            item[string: "glassTint"] = nil
        case "none":
            item[string: "background"] = nil
            item[bool: "glass"] = nil
            item[string: "glassTint"] = nil
            setBordered(false)
            item[string: "style"] = nil
            item[number: "cornerRadius"] = nil
        default:
            // Standard or glass. The shape stays: both keys take one.
            item[string: "background"] = nil
            setBordered(true)
            setGlass(mode == "glass")
            if mode != "glass" { item[string: "glassTint"] = nil }
        }
    }
}

/// Corner shape for a colored background.
struct ShapeRow: View {
    @ObservedObject var item: EditorItem

    /// The standard key's rounding, where the system draws the key itself.
    static let standard: Double = 6
    /// Half the bar's height: fully round ends.
    static let pill = Double(ItemStyle.barHeight / 2)

    private var radius: Double { item.cornerRadius }

    private var summary: String {
        switch radius {
        case 0: return "Square"
        case ShapeRow.standard: return "Standard"
        case ShapeRow.pill: return "Pill"
        default: return "\(Int(radius)) pt"
        }
    }

    var body: some View {
        FieldRow(label: "Corners", help: summary) {
            VStack(spacing: 2) {
                Slider(value: Binding(get: { radius }, set: { setRadius($0.rounded()) }), in: 0...ShapeRow.pill)
                GeometryReader { geometry in
                    mark("Square", at: 0, in: geometry.size.width)
                    mark("Standard", at: ShapeRow.standard, in: geometry.size.width)
                    mark("Pill", at: ShapeRow.pill, in: geometry.size.width)
                }
                .frame(height: 12)
            }
            .frame(width: 210)
        }
    }

    /// A label under the slider that jumps to its value.
    private func mark(_ title: String, at value: Double, in width: CGFloat) -> some View {
        // The slider's knob travels between its ends, inset by about half the knob.
        let inset: CGFloat = 8
        let x = inset + (width - 2 * inset) * CGFloat(value / ShapeRow.pill)
        return Button(title) { setRadius(value) }
            .buttonStyle(.plain)
            .font(.system(size: 9))
            .foregroundColor(radius == value ? .accentColor : .secondary)
            .fixedSize()
            .position(x: min(max(x, 14), width - 10), y: 6)
    }

    /// The item's own rounding is stored as nothing, so a standard key stays the
    /// system's and a Stripe pill follows the theme.
    private func setRadius(_ value: Double) {
        item[string: "style"] = nil
        item[number: "cornerRadius"] = value == item.defaultCornerRadius ? nil : value
    }
}

// MARK: - Visibility helpers

/// An app-name rule with a menu of running apps; choosing one adds it
/// ("Safari", then "Safari|Mail"), so no regex needs to be typed.
struct AppRuleRow: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        FieldRow(label: label, help: "App names or bundle IDs, separated by |") {
            HStack(spacing: 6) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: EditorStyle.fieldWidth)
                Menu {
                    ForEach(PresetLibrary.runningApps(), id: \.bundleId) { app in
                        Button(app.name) { add(app.name) }
                    }
                } label: {
                    Image(systemName: "plus.app")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a running app")
            }
        }
    }

    private func add(_ name: String) {
        let names = text.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !names.contains(name) else { return }
        text = (names + [name]).joined(separator: "|")
    }
}

// MARK: - Container contents

/// The items inside a group or popover: open one to edit it, reorder, remove, or add.
struct ContainerItemsEditor: View {
    @ObservedObject var container: EditorItem
    let session: EditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let children = container.children ?? []
            if ["popover", "group", "cluster"].contains(container.type), !children.isEmpty {
                OpenedBarPreview(container: container)
                Divider().opacity(0.5)
            }
            if children.isEmpty {
                Text(emptyMessage)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                ChildRow(child: child,
                         canMoveUp: index > 0,
                         canMoveDown: index < children.count - 1,
                         open: { session.selection = child.id },
                         move: { offset in move(index, by: offset) },
                         remove: { remove(child) })
                Divider().opacity(0.5)
            }
            Menu {
                ForEach(ItemCatalog.categories, id: \.self) { category in
                    Menu(category) {
                        ForEach(ItemCatalog.all.filter { $0.category == category && !$0.isContainer }, id: \.type) { info in
                            Button(action: { add(info.type) }) { Label(info.name, systemImage: info.symbol) }
                        }
                    }
                }
            } label: {
                Label("Add Item", systemImage: "plus")
            }
            .fixedSize()
            .padding(.vertical, 8)
        }
    }

    private var emptyMessage: String {
        switch container.type {
        case "popover": return "Empty. Add what it should expand into, such as a Volume Slider."
        case "cluster": return "Empty. Add the items to show together, such as Previous, Play / Pause and Next."
        default: return "Empty. Add the items it should open."
        }
    }

    private func move(_ index: Int, by offset: Int) {
        guard let document = container.document else { return }
        document.move(in: container, from: IndexSet(integer: index), to: offset > 0 ? index + 2 : index - 1)
    }

    private func remove(_ child: EditorItem) {
        container.document?.remove(child)
    }

    private func add(_ type: String) {
        guard let document = container.document else { return }
        let item = ItemCatalog.newItem(type, align: "center", document: document)
        document.add(item, to: container)
    }
}

/// What a folder or popover opens into: a picture of that bar at its real size,
/// scaled to fit, taken from copies of its items built off the bar.
private struct OpenedBarPreview: View {
    @ObservedObject var container: EditorItem
    @StateObject private var model = ContainerPreviewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(caption)
                .foregroundColor(.secondary)
            openedBar
        }
        .padding(.vertical, 8)
        .onAppear { model.build(container) }
        // Rebuilt after edits (including to its items), once they settle.
        .onReceive(documentChanges) { _ in model.build(container) }
        .onDisappear { model.stop() }
    }

    private var caption: String {
        switch container.type {
        case "popover": return "What it expands into"
        case "cluster": return "How it looks on the bar"
        default: return "What it opens"
        }
    }

    private var openedBar: some View {
            Group {
                if let image = model.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    // Holds the bar's shape while the first picture is taken.
                    Color.black.aspectRatio(1004 / ItemStyle.barHeight, contentMode: .fit)
                }
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: EditorStyle.barRadius).fill(Color.black))
            .help(container.type == "cluster" ? "The group where it sits on the bar, scaled to fit"
                                               : "The bar it opens, scaled to fit")
    }

    private var documentChanges: AnyPublisher<Void, Never> {
        guard let document = container.document else { return Empty().eraseToAnyPublisher() }
        return document.objectWillChange
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}

private struct ChildRow: View {
    @ObservedObject var child: EditorItem
    let canMoveUp: Bool
    let canMoveDown: Bool
    let open: () -> Void
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 8) {
                    Image(systemName: child.displaySymbol).foregroundColor(.accentColor).frame(width: 18)
                    Text(child.displayName)
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit this item")
            Button(action: { move(-1) }) { Image(systemName: "arrow.up") }
                .buttonStyle(.borderless).disabled(!canMoveUp).help("Move up")
            Button(action: { move(1) }) { Image(systemName: "arrow.down") }
                .buttonStyle(.borderless).disabled(!canMoveDown).help("Move down")
            Button(action: remove) { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Remove")
        }
        .padding(.vertical, 7)
    }
}

// MARK: - Hold to repeat

/// Brightness and volume keys: whether holding one keeps stepping, and by how much.
struct HoldRepeatEditor: View {
    @ObservedObject var item: EditorItem

    private var on: Bool { item[bool: "holdRepeat"] != false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToggleRow(label: "Repeat while held", help: "Holding up buzzes stronger as it goes, holding down lighter",
                      defaultValue: true,
                      value: Binding(get: { item[bool: "holdRepeat"] },
                                     set: { item[bool: "holdRepeat"] = $0 == false ? false : nil }))
            FieldRow(label: "Step") {
                Picker("", selection: Binding(get: { Int(item[number: "holdStep"] ?? 5) },
                                              set: { item[number: "holdStep"] = $0 == 5 ? nil : Double($0) })) {
                    Text("1%").tag(1)
                    Text("2%").tag(2)
                    Text("5%").tag(5)
                    Text("10%").tag(10)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            .disabled(!on)
            .opacity(on ? 1 : 0.45)
        }
    }
}

// MARK: - Haptics

/// When and how an item buzzes under a finger, with a button to feel it on the
/// trackpad (the Touch Bar's haptics come from the same actuator).
struct HapticsEditor: View {
    @ObservedObject var item: EditorItem

    private var when: String { item[string: "haptic"] ?? "both" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldRow(label: "Buzz on", help: when == "both" ? "A buzz on press, a soft tick on release" : nil) {
                Picker("", selection: Binding(get: { when }, set: { item[string: "haptic"] = $0 == "both" ? nil : $0 })) {
                    Text("Press and release").tag("both")
                    Text("Press").tag("press")
                    Text("Release").tag("release")
                    Text("Off").tag("off")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Group {
                FieldRow(label: "Strength") {
                    Picker("", selection: Binding(get: { item[string: "hapticStrength"] ?? "medium" },
                                                  set: { item[string: "hapticStrength"] = $0 == "medium" ? nil : $0 })) {
                        Text("Light").tag("light")
                        Text("Medium").tag("medium")
                        Text("Strong").tag("strong")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                FieldRow(label: "Pattern") {
                    Picker("", selection: Binding(get: { item[string: "hapticPattern"] ?? "single" },
                                                  set: { item[string: "hapticPattern"] = $0 == "single" ? nil : $0 })) {
                        Text("Single").tag("single")
                        Text("Double").tag("double")
                        Text("Triple").tag("triple")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                FieldRow(label: "Try it", help: "Plays on the trackpad") {
                    Button(action: test) { Label("Press and release", systemImage: "hand.tap") }
                }
                if hasOnOffState {
                    ToggleRow(label: "Toggle feel", help: "A tap's release buzzes by whether it turned the item on or off",
                              defaultValue: true,
                              value: Binding(get: { item[bool: "hapticToggle"] },
                                             set: { item[bool: "hapticToggle"] = $0 == false ? false : nil }))
                    if item[bool: "hapticToggle"] != false {
                        feelRows(title: "When turned on", strengthKey: "hapticOnStrength", patternKey: "hapticOnPattern",
                                 defaultStrength: "strong", on: true)
                        feelRows(title: "When turned off", strengthKey: "hapticOffStrength", patternKey: "hapticOffPattern",
                                 defaultStrength: "light", on: false)
                    }
                }
            }
            .disabled(when == "off")
            .opacity(when == "off" ? 0.45 : 1)
            if !AppSettings.hapticFeedbackState {
                Text("Haptic feedback is off for all items in Stripe's menu-bar menu.")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }

    /// Toggles and items with an "Active when" rule buzz by what a tap did.
    private var hasOnOffState: Bool {
        item.info.builtInActiveState != nil || item.fields["activeWhen"] != nil
    }

    private var style: HapticStyle {
        HapticStyle(when: item[string: "haptic"], strength: item[string: "hapticStrength"],
                    pattern: item[string: "hapticPattern"],
                    onStrength: item[string: "hapticOnStrength"], onPattern: item[string: "hapticOnPattern"],
                    offStrength: item[string: "hapticOffStrength"], offPattern: item[string: "hapticOffPattern"])
    }

    /// Strength and pattern for turning on (or off), with a button to feel that tap.
    @ViewBuilder
    private func feelRows(title: String, strengthKey: String, patternKey: String, defaultStrength: String, on: Bool) -> some View {
        FieldRow(label: title) {
            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { item[string: strengthKey] ?? defaultStrength },
                                              set: { item[string: strengthKey] = $0 == defaultStrength ? nil : $0 })) {
                    Text("Light").tag("light")
                    Text("Medium").tag("medium")
                    Text("Strong").tag("strong")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Picker("", selection: Binding(get: { item[string: patternKey] ?? "single" },
                                              set: { item[string: patternKey] = $0 == "single" ? nil : $0 })) {
                    Text("Single").tag("single")
                    Text("Double").tag("double")
                    Text("Triple").tag("triple")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Button(action: { play(toggle: on) }) { Image(systemName: "hand.tap") }
                    .help("Feel it on the trackpad")
            }
        }
    }

    private func test() {
        let style = self.style
        HapticFeedback.instance.play(style, .press)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { HapticFeedback.instance.play(style, .release) }
    }

    /// A tap that turns the toggle on or off: the press, then the on/off feel.
    private func play(toggle on: Bool) {
        let style = self.style
        HapticFeedback.instance.play(style, .press)
        HapticFeedback.instance.play(style.toggleFeel(turnedOn: on), after: 0.35)
    }
}

/// Detents for the volume and brightness sliders: a tick at evenly spaced
/// marks as they're dragged, and a firmer one at either end.
struct SliderHapticsEditor: View {
    @ObservedObject var item: EditorItem

    private var on: Bool { item[string: "haptic"] != "off" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToggleRow(label: "Detents", help: "A tick as the slider passes each mark, firmer at either end",
                      defaultValue: true,
                      value: Binding(get: { on }, set: { item[string: "haptic"] = $0 == false ? "off" : nil }))
            Group {
                FieldRow(label: "Every") {
                    Picker("", selection: Binding(get: { Int(item[number: "hapticStep"] ?? 10) },
                                                  set: { item[number: "hapticStep"] = $0 == 10 ? nil : Double($0) })) {
                        Text("5%").tag(5)
                        Text("10%").tag(10)
                        Text("25%").tag(25)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                FieldRow(label: "Strength") {
                    Picker("", selection: Binding(get: { item[string: "hapticStrength"] ?? "light" },
                                                  set: { item[string: "hapticStrength"] = $0 == "light" ? nil : $0 })) {
                        Text("Light").tag("light")
                        Text("Medium").tag("medium")
                        Text("Strong").tag("strong")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                FieldRow(label: "Try it", help: "A drag from 0 to 50%, on the trackpad") {
                    Button(action: test) { Label("Drag", systemImage: "slider.horizontal.3") }
                }
            }
            .disabled(!on)
            .opacity(on ? 1 : 0.45)
        }
    }

    private func test() {
        let style = HapticStyle(when: item[string: "haptic"], strength: item[string: "hapticStrength"], pattern: nil,
                                step: item[number: "hapticStep"])
        let detents = SliderDetents()
        detents.style = style
        // Half the range in small steps, like a finger sliding.
        let steps = 50
        for index in 0 ... steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02 * Double(index)) {
                detents.update(Double(index) / Double(steps) * 0.5)
            }
        }
    }
}
