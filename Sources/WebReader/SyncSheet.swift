import Cocoa
import ReaderKit
import ReaderWebKit

/// The Sync sheet: off, or a folder that WebReader exchanges its settings and recents
/// through. No server address, no username, no password — the folder's own sync client
/// (Nextcloud, iCloud Drive, Syncthing) does the moving, so there is nothing here to get
/// wrong.
///
/// A native sheet rather than one of the generated pages: it owns a file picker, and it has
/// to work when the folder has gone missing — a moment the page chrome shouldn't have to
/// have an opinion about.
///
/// Main-thread only, like the rest of the AppKit host — see `ReaderSyncController` on why
/// this isn't spelled `@MainActor`.
final class SyncSheet: NSObject {
    private let controller: ReaderSyncController
    private let panel: NSPanel
    private let offButton = NSButton()
    private let folderButton = NSButton()
    private let pathLabel = NSTextField(labelWithString: "")
    private let chooseButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")

    init(controller: ReaderSyncController) {
        self.controller = controller
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 208),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = "Sync"
        build()
    }

    func present(in window: NSWindow) {
        refresh()
        window.beginSheet(panel)
    }

    // MARK: - Layout

    private func build() {
        let content = NSView(frame: panel.contentLayoutRect)

        let heading = NSTextField(labelWithString: "Keep appearance and recents in step")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let explainer = NSTextField(wrappingLabelWithString:
            "Pick a folder that already syncs between your devices — in your Nextcloud "
            + "folder, or in iCloud Drive. Each device keeps its own file there; page zoom "
            + "stays local.")
        explainer.font = .systemFont(ofSize: 11)
        explainer.textColor = .secondaryLabelColor

        offButton.setButtonType(.radio)
        offButton.title = "Off"
        offButton.target = self
        offButton.action = #selector(turnOff)

        folderButton.setButtonType(.radio)
        folderButton.title = "Sync through a folder"
        folderButton.target = self
        folderButton.action = #selector(chooseFolder)

        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle

        chooseButton.title = "Choose…"
        chooseButton.bezelStyle = .rounded
        chooseButton.target = self
        chooseButton.action = #selector(chooseFolder)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2

        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"

        let folderRow = NSStackView(views: [pathLabel, chooseButton])
        folderRow.orientation = .horizontal
        folderRow.spacing = 8
        folderRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let buttons = NSStackView(views: [NSView(), done])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [heading, explainer, offButton, folderButton, folderRow,
                                        statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            explainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            folderRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        panel.contentView = content
    }

    // MARK: - State

    /// Redrawn by the host whenever sync's state changes, so an open sheet stays current.
    func refresh() {
        offButton.state = controller.isOn ? .off : .on
        folderButton.state = controller.isOn ? .on : .off
        pathLabel.stringValue = controller.folderDisplayPath ?? "No folder chosen"
        // The error wins over a stale success time, which would read as if things were fine.
        statusLabel.stringValue = controller.summary
        statusLabel.textColor = controller.hasError ? .systemRed : .secondaryLabelColor
    }

    // MARK: - Actions

    @objc private func chooseFolder() {
        let open = NSOpenPanel()
        open.canChooseFiles = false
        open.canChooseDirectories = true
        open.canCreateDirectories = true
        open.allowsMultipleSelection = false
        open.prompt = "Use Folder"
        open.message = "Choose a folder that syncs between your devices."
        open.beginSheetModal(for: panel) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = open.url else {
                // A cancelled picker must not leave the radio on a folder that was never
                // chosen.
                self.refresh()
                return
            }
            self.controller.choose(url)
            self.refresh()
        }
    }

    @objc private func turnOff() {
        controller.turnOff()
        refresh()
    }

    @objc private func close() {
        panel.sheetParent?.endSheet(panel)
    }
}
