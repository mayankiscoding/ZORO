#if DEBUG
import SwiftUI

/// Welcome, as the artwork is meant to be used: the feather's eye in a quiet band, then the orb it
/// inspired, then one sentence and one button. The photograph never sits behind text.
public struct GalleryWelcome: View {
    public init() {}
    public var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.xl.value) {
            ZoroArtworkView(.peacockEye, emphasis: .quiet)
                .frame(height: 132)
                .frame(maxWidth: .infinity)
                .clipShape(ZoroRadius.card.shape)
            OrbCanvas(state: .idle, time: 7.3).frame(height: 180).frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                Text("ZORO").zoroText(.title)
                ZoroVoiceText("Your assistant, running on your own server.", style: .zoroBody)
                    .foregroundStyle(.secondary)
            }
            Button("Get started") {}.buttonStyle(.zoroPrimary)
        }
    }
}

/// Every artwork with its name and where it may be used.
public struct GalleryArtwork: View {
    public init() {}
    public var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: ZoroSpace.m.value), GridItem(.flexible())], spacing: ZoroSpace.m.value) {
                ForEach(ZoroArtwork.allCases, id: \.self) { art in
                    VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
                        ZoroArtworkView(art).frame(height: 104).clipShape(ZoroRadius.control.shape)
                        Text(art.title).zoroText(.detail)
                        Text(art.uses.contains(.welcome) ? "Welcome, empty states" : "Empty states")
                            .zoroText(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ZoroCard {
                ZoroIllustratedEmptyState(.marigoldBloom, message: "No baskets yet. Ask ZORO to start one, like “add milk and eggs”.")
                    .padding(ZoroSpace.s.value)
            }
        }
    }
}

/// ZORO's Hindi in the bundled Devanagari serif beside New York, and the owner's Hindi in the
/// system face, so the two voices stay apart in both scripts.
public struct GalleryDevanagari: View {
    public init() {}
    public var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            ZoroVoiceText("आपका किराने का खर्च पिछले महीने से कम है।")
            ZoroVoiceText("Your grocery spend is lower than last month.")
            ZoroVoiceText("कल सुबह 7 बजे Ma को call करने की याद दिला दूँगा।", style: .zoroBody)
            RekhaWaveform(userLevels: [], assistantLevels: []).frame(height: 12)
            Text("माँ को सात बजे फ़ोन करना याद दिलाना").zoroText(.ownerVoice).foregroundStyle(.secondary)
            Text(ZoroFonts.register().isRegistered ? "Tiro Devanagari Hindi, registered" : "Tiro Devanagari Hindi unavailable, system fallback")
                .zoroText(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
