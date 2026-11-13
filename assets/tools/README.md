# Asset tools

Everything ZORO ships as an asset is rebuilt from these commands. Run them from the repository root.

| What | Command | Output |
|---|---|---|
| App icon sets and the small-size review sheet | `scripts/swiftpm.sh ZoroDesign run ZoroDesignSnapshots --icons "$PWD/assets/AppIcon" "$PWD/docs/design/snapshots"` | `assets/AppIcon/{ios,macos}/AppIcon.appiconset`, `docs/design/snapshots/app-icon-review.png` |
| Artwork (crop, tone, encode) | `scripts/swiftpm.sh ZoroDesign run ZoroDesignSnapshots --artwork <sources-dir> "$PWD/ios/Packages/ZoroDesign/Sources/ZoroDesign/Resources/Artwork"` | five JPEGs, at most 380 KB each, no metadata |
| Earcons | `python3 -I assets/tools/earcons.py ios/Packages/ZoroDesign/Sources/ZoroDesign/Resources/Sounds` | four WAVs, under 60 KB each |
| Snapshots | `scripts/swiftpm.sh ZoroDesign run ZoroDesignSnapshots "$PWD/docs/design/snapshots"` | gallery PNGs, including Devanagari, welcome and artwork |

The artwork originals are not kept in the repository (disk budget). To rebuild artwork, download each
original from the source URL in `assets/LICENSES.md` into an empty folder, name it
`<fileName>-source.jpg` (for example `zoro-art-peacock-eye-source.jpg`), and run the artwork command.
Crops and toning live in `ios/Packages/ZoroDesign/Sources/ZoroDesignSnapshots/ArtworkPipeline.swift`.
For the Wikimedia Commons files, use the original file or the largest thumbnail Commons offers
(the shipped files were made from the original for the two peacock photographs, and from Commons'
3840 px thumbnail for the two marigolds; the indigo cloth from Poly Haven's 2K diffuse JPG).
