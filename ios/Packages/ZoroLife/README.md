# ZoroLife

Fitness, photos and music for the iPhone and Mac apps. Targets: `FitnessFeature`, `PhotosFeature`, `MusicFeature`, plus `LifeSupport` (screen phases, error sentences, number and time formatting).

Public views: `FitnessHomeView()`, `PhotoSearchView()`, `MusicHomeView()`; card views `FitnessSummaryCardView(card:)`, `PhotoQueryCardView(card:)`, `MusicCardView(card:)`.
Environment hooks the app sets: `\.zoroServices`, `\.photoThumbnailProvider` (`PhotoKitThumbnailProvider()`), `\.limitedLibraryPresenter` (`PhotoKitLimitedLibraryPresenter()` on iPhone).

Status: working and tested on the macOS host (184 tests). Not compiled here: `Sources/PhotosFeature/iOS/LimitedLibraryPresenter+iOS.swift` (UIKit). The PhotoKit thumbnail provider and MusicKit authoriser compile on macOS but were never run (they touch real system services).
Fixtures: `cd backend && PYTHONPATH=. uv run --no-sync python ../ios/Packages/ZoroLife/scripts/generate_fixtures.py`.
