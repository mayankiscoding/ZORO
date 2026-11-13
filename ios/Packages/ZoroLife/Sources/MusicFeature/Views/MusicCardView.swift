import LifeSupport
import SwiftUI
import ZoroCore
import ZoroDesign

/// The `music` card in a conversation: songs from a search, or the song that is now playing, and which service answered.
public struct MusicCardView: View {
    let card: UICard

    public init(card: UICard) { self.card = card }

    public var body: some View {
        ZoroCard {
            if card.kind != "music" {
                ZoroStateView(.error, message: "This music card could not be shown. Ask ZORO again.")
            } else if let payload = try? card.decodePayload(MusicCardPayload.self) {
                content(payload)
            } else {
                ZoroStateView(.error, message: "This music card could not be shown. Ask ZORO again.")
            }
        }
    }

    private func providerName(_ raw: String) -> String? {
        MusicProvider(rawValue: raw)?.title
    }

    private func content(_ p: MusicCardPayload) -> some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            Text(card.title ?? "Music").zoroText(.heading).accessibilityAddTraits(.isHeader)
            if let track = p.nowPlaying {
                trackRow(track)
            }
            ForEach(p.tracks) { trackRow($0) }
            if p.nowPlaying == nil && p.tracks.isEmpty {
                Text("There are no songs to show. Ask ZORO to search again.").zoroText(.detail).foregroundStyle(.secondary)
            }
            if let name = providerName(p.provider) {
                Text("From \(name)").zoroText(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func trackRow(_ t: MusicTrackInfo) -> some View {
        VStack(alignment: .leading, spacing: ZoroSpace.hair.value) {
            Text(t.title).zoroText(.body)
            let line = [t.artistLine, t.album].compactMap { $0 }.joined(separator: ", ")
            if !line.isEmpty { Text(line).zoroText(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }
}
