import LifeSupport
import SwiftUI
import ZoroCore
import ZoroDesign

#if canImport(MusicKit)
private let defaultMusicAuthorizer: any MusicAuthorizing = MusicKitAuthorizer()
#else
private let defaultMusicAuthorizer: any MusicAuthorizing = UnavailableMusicAuthorizer()
#endif

/// The Music space: what is playing, play, pause and skip, search, moving playback between your devices, Spotify and Apple Music
/// connection state, playlists, and plain notes on what each service can and cannot do.
public struct MusicHomeView: View {
    @Environment(\.zoroServices) private var services
    @State private var model: MusicViewModel?

    public init() {}

    public var body: some View {
        Group {
            if let model {
                MusicHomeContent(model: model)
            } else {
                ZoroStateView(.loading, message: "Getting your music ready.")
            }
        }
        .task {
            if model == nil {
                #if os(macOS)
                let platform = DevicePlatform.macos
                #else
                let platform = DevicePlatform.ios
                #endif
                model = MusicViewModel(services: services, authorizer: defaultMusicAuthorizer, platform: platform)
            }
            await model?.load()
            await model?.monitorNowPlaying()
        }
    }
}

struct MusicHomeContent: View {
    @Bindable var model: MusicViewModel
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZoroSpace.xl.value) {
                VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
                    Text("Music").zoroText(.title).accessibilityAddTraits(.isHeader)
                    Text("Play music from Spotify or Apple Music, and move it between your iPhone and Mac.")
                        .zoroText(.body).foregroundStyle(.secondary)
                }
                if model.screen == .idle || model.screen == .loading {
                    ZoroStateView(.loading, message: "Checking Spotify, Apple Music and what is playing.")
                } else {
                    if let message = model.transportMessage {
                        ZoroStateView(.error, message: message)
                    }
                    AdaptiveMusicColumns {
                        nowPlayingCard
                        servicesCard
                        searchCard
                        devicesCard
                        playlistCard
                        limitsCard
                    }
                }
            }
            .padding(ZoroSpace.l.value)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ZoroNeutral.background)
        .navigationTitle("Music")
        .refreshable { await model.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.screen == .loaded { Task { await model.loadServer() } }
        }
    }

    // MARK: Now playing

    private var nowPlayingCard: some View {
        section("Now playing") {
            if let p = model.nowPlayingPresentation {
                VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                    Text(p.title).zoroText(.heading)
                    if let subtitle = p.subtitle { Text(subtitle).zoroText(.body).foregroundStyle(.secondary) }
                    if let progress = p.progress {
                        ProgressView(value: progress).accessibilityLabel("Position").accessibilityValue(p.positionText ?? "")
                    }
                    Text([p.provider, p.device.map { "on \($0)" }, p.positionText].compactMap { $0 }.joined(separator: ", "))
                        .zoroText(.caption).foregroundStyle(.secondary)
                    Text(p.observedLine).zoroText(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(p.accessibilityLabel)
            } else if model.canControl {
                ZoroStateView(.empty, message: "Nothing is playing. Search for a song below, or start music in \(model.activeProvider?.title ?? "your music app").")
            } else {
                ZoroStateView(.empty, message: "Connect Spotify or allow Apple Music below to see and control what is playing.")
            }
            transportControls
        }
    }

    private var transportControls: some View {
        HStack(spacing: ZoroSpace.l.value) {
            Button { Task { await model.skipPrevious() } } label: { Image(systemName: "backward.fill").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel("Previous song")
            Button { Task { await model.togglePlayPause() } } label: {
                Image(systemName: model.nowPlaying?.isPlaying == true ? "pause.fill" : "play.fill").font(.title2).frame(minWidth: 56, minHeight: 44)
            }
            .accessibilityLabel(model.nowPlaying?.isPlaying == true ? "Pause" : "Play")
            Button { Task { await model.skipNext() } } label: { Image(systemName: "forward.fill").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel("Next song")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.neel)
        .disabled(!model.canControl || model.isTransportBusy)
    }

    // MARK: Services

    private var servicesCard: some View {
        section("Services") {
            VStack(alignment: .leading, spacing: ZoroSpace.l.value) {
                if let failure = model.serverFailure {
                    Label(failure.message, systemImage: "bolt.horizontal.circle").zoroText(.detail)
                        .foregroundStyle(ZoroRole.attention.hue.color(scheme: scheme, contrast: .increased))
                }
                ForEach(MusicProvider.allCases) { provider in
                    providerRow(model.choice.state(for: provider))
                }
                Text(model.choice.reason).zoroText(.caption).foregroundStyle(.secondary)
                if model.choice.spotify.isReady && model.choice.appleMusic.isReady {
                    HStack(spacing: ZoroSpace.s.value) {
                        ForEach(MusicProvider.allCases) { provider in
                            ZoroChip(provider.title, isSelected: model.activeProvider == provider) {
                                Task { await model.selectProvider(provider) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func providerRow(_ state: ProviderState) -> some View {
        VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
            HStack(alignment: .firstTextBaseline) {
                Text(state.provider.title).zoroText(.heading)
                Spacer(minLength: ZoroSpace.s.value)
                ZoroCapsuleLabel(
                    text: state.isReady ? "Ready" : (state.readiness == .unavailable ? "Not available" : "Needs set up"),
                    role: state.isReady ? .positive : (state.readiness == .unavailable ? nil : .attention))
            }
            Text(state.sentence).zoroText(.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if case .needsSetup(let action) = state.readiness {
                Button(action.title) {
                    Task { if let url = await model.perform(action) { openURL(url) } }
                }
                .buttonStyle(ZoroSecondaryButtonStyle()).frame(maxWidth: 300)
            }
            if state.provider == .spotify, state.isReady {
                Button("Disconnect Spotify") { Task { await model.disconnectSpotify() } }.buttonStyle(.zoroLink)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Search

    private var searchCard: some View {
        section("Search") {
            VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
                HStack(spacing: ZoroSpace.s.value) {
                    TextField("Song, album or playlist", text: $model.searchText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await model.search() } }
                        .accessibilityLabel("Search music")
                    Button("Search") { Task { await model.search() } }
                        .buttonStyle(ZoroPrimaryButtonStyle()).frame(maxWidth: 130).disabled(!model.canSearch)
                }
                switch model.searchPhase {
                case .idle:
                    ZoroStateView(
                        .empty,
                        message: model.canControl
                            ? "Search \(model.activeProvider?.title ?? "music") for a song, album or playlist, then tap Play."
                            : "Connect Spotify or allow Apple Music first, then search here.")
                case .searching: ZoroStateView(.loading, message: "Searching.")
                case .noResults: ZoroStateView(.empty, message: "Nothing found. Try the song name and the artist.")
                case .failed(let failure):
                    ZoroStateView(
                        failure.kind == .disconnected ? .disconnected : .error, message: failure.message,
                        action: failure.retryable ? ZoroStateAction("Try again") { Task { await model.search() } } : nil)
                case .results:
                    VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                        ForEach(model.results) { item in
                            MusicItemRow(item: item, play: { Task { await model.play(item) } }, playNext: { Task { await model.queueNext(item) } })
                        }
                    }
                }
            }
        }
    }

    // MARK: Devices

    private var devicesCard: some View {
        section("Move playback") {
            let choice = model.deviceChoice
            VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
                if let failure = model.devicesFailure {
                    ZoroStateView(.error, message: failure, action: ZoroStateAction("Try again") { Task { await model.refreshDevices() } })
                }
                ForEach(choice.rows) { row in
                    HStack {
                        Label(row.name, systemImage: row.isActive ? "speaker.wave.2.fill" : "speaker")
                        Spacer(minLength: ZoroSpace.s.value)
                        if row.isActive {
                            Text("Playing here").zoroText(.caption).foregroundStyle(.secondary)
                        } else if choice.canMove {
                            Button("Move here") { Task { await model.move(to: row) } }.buttonStyle(.zoroLink)
                                .disabled(model.isTransportBusy)
                        }
                    }
                    .zoroText(.body)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(row.accessibilityLabel)
                }
                Text(choice.note).zoroText(.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Refresh devices") { Task { await model.refreshDevices() } }.buttonStyle(.zoroLink)
            }
        }
    }

    // MARK: Playlist

    private var playlistCard: some View {
        section("Playlists") {
            VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
                if model.choice.spotify.isReady {
                    TextField("Playlist name", text: $model.playlistName).textFieldStyle(.roundedBorder).accessibilityLabel("Playlist name")
                    Button("Create playlist") { Task { await model.createPlaylist() } }
                        .buttonStyle(ZoroSecondaryButtonStyle()).frame(maxWidth: 300).disabled(!model.canCreatePlaylist)
                    Text("ZORO makes a private Spotify playlist and asks you to approve it first. It starts empty; ask ZORO to add songs.")
                        .zoroText(.caption).foregroundStyle(.secondary)
                } else {
                    ZoroStateView(.empty, message: "Playlists are made in your Spotify account. Connect Spotify under Services first.")
                }
                switch model.playlist {
                case .creating: ZoroStateView(.loading, message: "Asking ZORO to create the playlist.")
                case .done(let message): Label(message, systemImage: "checkmark.circle").zoroText(.detail)
                case .failed(let message): ZoroStateView(.error, message: message)
                case .idle: EmptyView()
                }
            }
        }
    }

    // MARK: Limits

    private var limitsCard: some View {
        section("What each service can do") {
            VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                Text("Spotify: ZORO can search, play, pause, skip and move playback. This needs Spotify Premium, and your Spotify account must be allowed on the ZORO server's Spotify app.")
                Text("Apple Music: ZORO plays on this device. Apps cannot move Apple Music to another device or read what your other devices play.")
                if let note = model.serverStatus?.recommendations { Text(note) }
            }
            .zoroText(.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
            ZoroSectionHeader(title)
            ZoroCard { VStack(alignment: .leading, spacing: ZoroSpace.m.value) { content() } }
        }
    }
}

struct MusicItemRow: View {
    let item: MusicItem
    let play: () -> Void
    let playNext: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: ZoroSpace.m.value) {
            VStack(alignment: .leading, spacing: ZoroSpace.hair.value) {
                Text(item.title).zoroText(.body)
                Text([item.kind.rawValue.capitalized, item.subtitle].compactMap { $0 }.joined(separator: ", "))
                    .zoroText(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: ZoroSpace.s.value)
            Button("Play", action: play).buttonStyle(.zoroLink)
            if item.kind == .song { Button("Play next", action: playNext).buttonStyle(.zoroLink) }
        }
    }
}

struct AdaptiveMusicColumns<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 340), spacing: ZoroSpace.l.value, alignment: .top)], alignment: .leading,
            spacing: ZoroSpace.l.value
        ) { content }
    }
}
