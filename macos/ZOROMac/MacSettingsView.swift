import AppKit
import NativeActionBroker
import SwiftUI
import ZoroComposition
import ZoroCore
import ZoroDesign

/// Mac-only settings: the folders ZORO may search, notifications, and the paired server. Everything
/// else (privacy mode, voice, language) is in the main window's Settings and Security sections.
struct MacSettingsView: View {
    let app: ZoroApplication
    let notifier: MacNotifier
    @State private var model: FolderSettingsModel

    init(app: ZoroApplication, notifier: MacNotifier) {
        self.app = app
        self.notifier = notifier
        _model = State(initialValue: FolderSettingsModel(store: app.folders))
    }

    var body: some View {
        Form {
            Section {
                switch model.phase {
                case .loading:
                    ZoroStateView(.loading, message: "Reading the folders you approved.")
                case .failed(let message):
                    ZoroStateView(.error, message: message, action: ZoroStateAction("Try again") { Task { await model.load() } })
                case .loaded where model.folders.isEmpty:
                    ZoroStateView(.empty, message: "No folders yet. Add one so ZORO can find files in it when you ask.")
                case .loaded:
                    ForEach(model.folders, id: \.ref) { folder in
                        HStack {
                            Label(folder.name, systemImage: "folder").zoroText(.body)
                            Spacer()
                            Button("Remove") { Task { await model.remove(folder.ref) } }
                                .accessibilityLabel("Remove \(folder.name)")
                        }
                    }
                }
                Button("Add a folder…") { Task { await model.pickFolder() } }
            } header: {
                Text("Folders ZORO can search")
            } footer: {
                Text("ZORO searches only these folders, on this Mac. Files are opened, never sent anywhere.")
                    .zoroText(.caption).foregroundStyle(.secondary)
            }

            Section("Notifications") {
                if !notifier.isAvailable {
                    Text("Notifications work in the installed app.").zoroText(.detail).foregroundStyle(.secondary)
                } else if notifier.status == .denied {
                    Text("Notifications are off. Turn them on in System Settings > Notifications > ZORO.")
                        .zoroText(.detail)
                } else if notifier.status == .notDetermined {
                    Button("Tell me when an approval is waiting") { Task { await notifier.requestPermission() } }
                } else {
                    Text("ZORO tells you when an approval is waiting.").zoroText(.detail)
                }
            }

            Section("Server") {
                Text(app.api.endpoint.current?.absoluteString ?? "Not connected. Pair this Mac from the main window.")
                    .zoroText(.detail).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .task {
            await model.load()
            await notifier.refreshStatus()
        }
    }
}

/// Lists, adds and removes the approved folders (security-scoped bookmarks).
@MainActor
@Observable
final class FolderSettingsModel {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    private(set) var folders: [ApprovedFolder] = []
    private(set) var phase: Phase = .loading
    @ObservationIgnored private let store: SecurityScopedFolderStore

    init(store: SecurityScopedFolderStore) { self.store = store }

    func load() async {
        folders = await store.approvedFolders()
        phase = .loaded
    }

    func add(_ url: URL) async {
        do {
            try await store.add(url)
            await load()
        } catch {
            phase = .failed("That folder couldn't be added. Choose it again, or pick a folder you own.")
        }
    }

    func remove(_ ref: String) async {
        await store.remove(ref: ref)
        await load()
    }

    func pickFolder() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Allow ZORO to search"
        panel.message = "Choose a folder ZORO may search when you ask for a file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await add(url)
    }
}
