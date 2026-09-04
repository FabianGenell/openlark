import AppKit
import SwiftUI

/// One row in a hand-popped menu.
struct PopupMenuItem {
    var title: String
    var subtitle: String? = nil
    var isOn: Bool = false
    var isSeparator: Bool = false
    var action: (() -> Void)? = nil

    static let separator = PopupMenuItem(title: "", isSeparator: true)
}

/// Pops a real NSMenu at the pointer.
///
/// SwiftUI's `Menu` is unusable anywhere the surrounding design matters on
/// macOS: every menu style draws its own chrome, `.borderlessButton` puts a
/// system disclosure triangle to the *left* of the label and ignores
/// `.menuIndicator(.hidden)`, and the label's own background is swallowed.
/// Popping the menu by hand leaves the trigger a plain button we can style, and
/// gives real AppKit menu behaviour (checkmarks, keyboard, dismissal) for free.
enum PopupMenu {
    /// - Parameter over: a window to drop below the menu level for the duration.
    ///   Menus live at `.popUpMenu` (101). The recording overlay deliberately
    ///   sits at `.screenSaver` (1000) so it clears fullscreen apps, which means
    ///   any menu popped from it renders *behind* it. `popUp` runs modally, so
    ///   lowering the window around the call is enough and it is back above
    ///   everything by the time the menu closes.
    static func show(_ items: [PopupMenuItem], over host: NSWindow? = nil) {
        let menu = NSMenu()
        menu.appearance = NSAppearance(named: .darkAqua)

        for item in items {
            guard !item.isSeparator else {
                menu.addItem(.separator())
                continue
            }
            let menuItem = NSMenuItem(
                title: item.title,
                action: item.action == nil ? nil : #selector(MenuActionTarget.fire),
                keyEquivalent: ""
            )
            if let subtitle = item.subtitle {
                // The size or state belongs with the name but not at the same
                // weight, and an attributed title is the only way a plain
                // NSMenuItem can carry two.
                let title = NSMutableAttributedString(
                    string: item.title,
                    attributes: [.font: NSFont.menuFont(ofSize: 0)]
                )
                title.append(NSAttributedString(
                    string: "   " + subtitle,
                    attributes: [
                        .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]
                ))
                menuItem.attributedTitle = title
            }
            if let action = item.action {
                let target = MenuActionTarget(action)
                menuItem.target = target
                // The menu runs modally and only borrows the target for that
                // time, so hang onto it rather than letting ARC take it mid-run.
                menuItem.representedObject = target
            }
            menuItem.state = item.isOn ? .on : .off
            menu.addItem(menuItem)
        }

        let restoreLevel = host?.level
        host?.level = .floating
        defer {
            if let host, let restoreLevel { host.level = restoreLevel }
        }

        // A nil view means the point is in screen coordinates, which is what
        // NSEvent.mouseLocation gives us. Callers may be inside a borderless
        // panel with no view worth anchoring to.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

private final class MenuActionTarget: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
        super.init()
    }

    @objc func fire() { action() }
}

/// A dropdown that looks like the text fields it sits beside: same inset
/// surface, same hairline, a chevron on the trailing edge. Pass a `note` for
/// state the value alone doesn't convey, such as a model that isn't on disk.
struct ThemeDropdown: View {
    let value: String
    var detail: String? = nil
    var note: String? = nil
    let items: () -> [PopupMenuItem]

    @State private var hovered = false

    var body: some View {
        Button {
            PopupMenu.show(items())
        } label: {
            HStack(spacing: 8) {
                Text(value)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)

                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }

                if let note {
                    ThemeChip(systemImage: "arrow.down.circle", text: note, tint: Theme.Meta.size)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hovered ? Theme.textSecondary : Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous)
                    .fill(Color.white.opacity(hovered ? 0.08 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous)
                    .strokeBorder(hovered ? Theme.strokeStrong : Theme.stroke, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}
