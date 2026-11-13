import SwiftUI
import ZoroCore
import ZoroDesign

/// The Mac menu-bar popover: a compact orb, push-to-talk, and ZORO's last reply. The app target puts
/// it in a `MenuBarExtra` with `.menuBarExtraStyle(.window)`.
public struct MenuBarContentView: View {
    let model: HomeViewModel
    let openMainWindow: () -> Void

    public init(model: HomeViewModel, openMainWindow: @escaping () -> Void) {
        self.model = model
        self.openMainWindow = openMainWindow
    }

    public var body: some View {
        let p = model.presentation
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            HStack(spacing: ZoroSpace.m.value) {
                OrbControl(state: p.orbState, level: model.level, satellites: p.satellites, hint: OrbControl.hint(for: p.orbState)) {
                    Task { await model.handle(.tap) }
                }
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ZORO").zoroText(.heading)
                    Text(p.stateLabel).zoroText(.caption).foregroundStyle(.secondary)
                }
            }
            if let issue = p.issue {
                Text(issue.message).zoroText(.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            RekhaStage {
                if let reply = model.lastReply {
                    Text(reply).zoroText(.zoroBody).lineLimit(6).fixedSize(horizontal: false, vertical: true)
                }
            } owner: {
                if let owner = p.ownerText {
                    Text(owner).zoroText(.detail).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Button {
                Task { await model.handle(.tap) }
            } label: {
                Text(model.voiceState == .listening ? "Finish speaking" : "Push to talk").frame(maxWidth: .infinity)
            }
            .buttonStyle(.zoroPrimary)
            .keyboardShortcut(.space, modifiers: [.option])
            HStack {
                Button("Open ZORO", action: openMainWindow).buttonStyle(.zoroLink)
                Spacer()
                if p.isBusy {
                    Button("Stop") { Task { await model.interrupt() } }.buttonStyle(ZoroLinkButtonStyle(role: .critical))
                }
            }
        }
        .padding(ZoroSpace.l.value)
        .frame(width: 320)
    }
}
