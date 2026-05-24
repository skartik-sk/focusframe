# FocusFrame

FocusFrame is a native macOS screen recorder for creating polished product demos, tutorials, course videos, and short social clips. It is built with Swift, SwiftUI, ScreenCaptureKit, AVFoundation, Core Image, and AppKit where native macOS behavior is needed.

The app is local-first: recording, editing, styling, transcription, and export run on the Mac. Optional cloud upload can be enabled by providing your own upload endpoint.

## Core Features

- Screen and window recording through ScreenCaptureKit.
- Microphone, system audio, and webcam capture.
- Automatic zoom generation from cursor clicks and action points.
- Smooth cursor rendering, cursor scaling, idle cursor hiding, and click emphasis.
- Timeline editing with trims, cuts, speed changes, zoom segments, captions, chapters, title cards, and overlays.
- Styled output with backgrounds, padding, rounded corners, shadows, keyboard badges, webcam layouts, and presets.
- MP4, MOV, GIF, local share page, clipboard file reference, and optional cloud-link export.
- On-device speech recognition for transcript and subtitle workflows.
- Release app bundle and zip packaging through `./run.sh`.

## Requirements

- macOS 13 Ventura or newer.
- Swift 6.2 toolchain or newer.
- Xcode command line tools.
- Screen Recording, Microphone, Camera, Speech Recognition, Input Monitoring, and Accessibility permissions depending on enabled recording features.

## Quick Start

```bash
git clone git@github.com:skartik-sk/focusframe.git
cd focusframe
swift test
./run.sh
```

Use `./run.sh` instead of raw `swift run` when testing the desktop app. The script creates a `.app` bundle with the correct name, icon, permissions metadata, and resources before launching it.

## Build Commands

```bash
# Debug build and app bundle, no launch
./run.sh --build-only

# Release app bundle
./run.sh --release

# Release app bundle plus zip package
./run.sh --package

# Run the full test suite
swift test

# Run export smoke tests that use generated fixture media
swift test --filter ExportRuntimeTests

# Optional: run local-recording export tests against recordings saved on this Mac
FOCUSFRAME_RUN_LOCAL_EXPORT_TESTS=1 swift test --filter ExportRuntimeTests
```

Generated artifacts:

- Debug app: `.build/debug-app-bundle/FocusFrame.app`
- Release app: `.build/release-app-bundle/FocusFrame.app`
- Release zip: `.build/dist/FocusFrame-1.0-macOS.zip`

## Optional Cloud Upload

FocusFrame works without any backend. To enable the optional cloud-link destination, provide an HTTP upload endpoint that accepts multipart file uploads and returns either a plain URL or JSON with `url`, `shareURL`, or `link`. If the endpoint requires authorization, provide that value through your local launch environment.

```bash
export FOCUSFRAME_UPLOAD_ENDPOINT="https://example.com/upload"
./run.sh
```

## Project Layout

```text
focusframe/
├── Package.swift
├── Info.plist
├── run.sh
├── Sources/
│   └── FocusFrame/
│       ├── App/
│       ├── Models/
│       ├── Services/
│       ├── Processing/
│       ├── Utilities/
│       ├── Views/
│       └── Resources/
└── FocusFrameTests/
```

## Architecture

FocusFrame uses a SwiftPM-first macOS app structure with one executable target, `FocusFrame`, and one test target, `FocusFrameTests`.

Recording is coordinated by `RecordingVM`, which drives the capture services for screen, cursor, keyboard, microphone, system audio, and webcam inputs. Each source is persisted as project media or metadata.

Editing is coordinated by `EditorVM`. Cursor events feed `AutoZoomCalculator`, cursor paths feed `CursorSmoother`, zoom segments feed `ZoomTransformer`, and the preview/export surfaces share the same rendering logic so edited output matches the final file.

Export is coordinated by `ExportVM`. It renders video frames through `VideoRenderer`, mixes audio through `AudioProcessor`, and writes final files with AVFoundation.

## Repository Notes

- The visible product, package, module, app bundle, source folder, and test folder are named `FocusFrame`.
- `.build/`, local SwiftPM state, Xcode user data, `.DS_Store`, and local agent files are ignored.

## License

MIT. See `LICENSE`.
