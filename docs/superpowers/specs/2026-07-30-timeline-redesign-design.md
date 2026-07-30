# Timeline Redesign — Screen Studio–caliber editing surface

**Date:** 2026-07-30
**Branch:** `perf/parallel-render-pipeline`
**Scope:** `Sources/FocusFrame/Views/Editor/` timeline layer. EditorVM contract is **frozen** — views only.

## Goal

Elevate the editor timeline from a functional multi-track strip into a polished,
precise, filmstrip-forward editing surface that matches Screen Studio's polish bar —
while preserving every existing feature and every `EditorVM` method/property the
timeline uses today.

Target aesthetic reference: **Screen Studio** (minimal, filmstrip-first, big crisp
clips, one playhead, effortless). Adapted to FocusFrame's richer track set.

## Problems with the current timeline (motivation)

1. **No persistent track headers.** Lane labels and "+" add buttons live *inside* the
   horizontal scroll area, so they slide away. No fixed left gutter with track
   identity / add affordances.
2. **No snapping.** Dragging a clip or its edge never magnetizes to the playhead, to
   other clip edges, or to the ruler grid. Timelines feel imprecise without it.
3. **Fragmented playhead & selection.** A red playhead on the ruler vs. ~7 separate
   per-track blue playheads; a red drag-selection band that visually collides with red
   "cut" blocks. No single, crisp, draggable playhead.
4. **Flat visual hierarchy.** Uniform grey tracks, no grouping (video vs. edits vs.
   audio), thin hard-to-grab resize handles, and **no filmstrip** of the actual frames —
   only waveforms and abstract color blocks.
5. **Heavy duplication.** ~7 near-identical clip implementations each re-copied the
   move/resize/delete gesture code, so behavior drifts between track types.

## Target experience

- **One filmstrip track** of real video frames as the hero lane; zoom/title/overlay/
  camera/effect clips float on it as elegant, shadowed, rounded chips with edge grips.
- **A single crisp playhead** (one thin line + a draggable head on the ruler) spanning
  every lane. The ~7 per-track playheads are removed.
- **A fixed left gutter** (pinned horizontally, scrolls vertically with content) with
  group labels, lane icons/names, and per-lane add buttons.
- **Magnetic snapping** while dragging or resizing — to the playhead, to other clip
   edges in the same group, and to the ruler grid. A brief snap guide line appears.
- **Lane grouping:** Video · Edits · Audio, with clear visual separation.
- **Unified clip system:** one generic `TimelineClip` primitive + one gesture engine
  replace all duplicated block views.

## Architecture

### Layout (new `TimelineView` body)

```
VStack {
  resize divider (non-compact)
  ScrollView(.vertical) {                       // both gutter + body move together
    HStack(spacing: 0) {
      GutterColumn       // fixed width, pinned horizontally, NOT horizontally scrolled
      ScrollView(.horizontal) {
        BodyContent      // ruler + lanes in a VStack; single global playhead overlay
                         //   .frame(width: contentWidth)
      }
    }
  }
  controls bar (zoom −/+, %, status)  (non-compact)
}
```

- `contentWidth = viewportWidth * timelineZoomScale` (zoom 1×–8×, unchanged).
- The playhead lives inside `BodyContent` as a ZStack overlay so it scrolls with content
  and spans all lanes. Keep the existing center-on-playhead-on-zchange behavior.

### Components (new files under `Views/Editor/`)

- **`TimelineSnapping.swift`** — `Snapper`. `snap(_:candidates:threshold:) -> SnapResult`.
  Candidates = playhead time + all clip edges (start/end) across the active group +
  ruler grid lines. Threshold is pixel-based, converted to seconds. Returns the snapped
  time and whether a snap fired (to draw a guide line).
- **`TimelineClip.swift`** —
  - `struct TimelineClipIdentity`: id, kind (color/icon/label), startTime, endTime,
    isSelected, supportsExtend.
  - `struct TimelineClipView`: the rendered clip (rounded fill, 1px colored border,
    label, two edge grips, optional delete button, soft shadow). Binds a single generic
    move/resize gesture that consults a `Snapper` and reports
    `onSelect / onBeginEdit / onUpdate(start,end) / onEndEdit / onRemove`.
  - Replaces: `EditableZoomSegmentBlock`, `EditableEditActionBlock`,
    `EffectSegmentTimelineBlock`, `TitleCardTimelineBlock`, `CameraLayoutBlock`,
    `OverlayTimelineBlock`.
- **`TimelineFilmstrip.swift`** — `FilmstripView`. Owns an `AVAssetImageGenerator`
  keyed by `project.videoFileURL`; samples N thumbnails (count ≈ width / 96, height
  ~96px) on a detached utility task, caches by (url, duration, count), cancels on
  disappear/url/zoom change. Renders the strip with a subtle divider between frames and
  a low-opacity waveform band at the bottom. Mirrors `AudioWaveformView`'s async +
  cancellation pattern.
- **`TimelineLane.swift`** — lane + group descriptors and the gutter header renderer.
- Refined `TimelineRuler` (single draggable playhead head, nicer ticks) — kept in
  `TimelineView.swift` or extracted.
- `AudioWaveformView.swift` and `TimelineTickPlanner` / `TimelineEventSampler` /
  `TimelinePreferences` are **kept as-is**.

### Lane layout (top → bottom), grouped

**Video group**
1. *Filmstrip* (hero) — real frames; floating clips for Zoom, Title card, Overlay,
   Effect, Camera layout (each rendered via `TimelineClipView`). Tap on empty filmstrip
   → `addZoomSegment(at:)` + select `.zoom` tool (preserves current ZoomTrackView
   behavior).

**Edits group**
2. *Cuts & Speed* — `EditAction` clips (cut=red, speed=blue, hideCursor=orange) via
   `TimelineClipView`, plus the drag-selection band.
3. *Keys* — `KeyPressEvent` point-events as compact pills (not ranged clips).

**Audio group**
4–6. *System* / *Mic* / *Music* — existing `AudioWaveformView` lanes (kept).

Lanes that have no content and no active tool are hidden (same visibility rules as the
current `timelineHeight` computation), so the surface stays minimal — Screen Studio-like.

## Interactions (preserved + improved)

- Drag clip body → move (Shift = extend/trim from one edge; preserves today's behavior).
- Drag grip → resize leading/trailing edge.
- All drags now **snap** (playhead / edges / grid); holding **⌃ Control disables snap**.
- Tap clip → select + seek to its start; right-click → type/style menu + Remove.
- Option held → delete buttons appear on clips (current behavior preserved).
- Ruler drag → scrub + range selection (current behavior preserved); the selection band
  recolored to accent so it no longer collides with red cut blocks.
- Keyboard unchanged (arrows nudge, Shift+arrows trim, Delete removes, Esc clears).
- Undo/redo unchanged (interactive edits already coalesce via
  `beginInteractiveEdit`/`endInteractiveEdit`).

## Visual language

- Backgrounds: semantic NSColors (adapt to light/dark). Filmstrip lane always dark.
- Clips: fill `kindColor.opacity(0.16)`, border `kindColor.opacity(0.6)` (2px when
  selected), corner radius 7, soft shadow, 1px edge grips that widen on hover.
- Per-kind colors kept: zoom=blue, title=orange, cut=red, speed=blue, effect=indigo,
  overlay=teal, camera=purple, keys=accent.
- Selection band recolored accent; playhead = accent (single, crisp, with head).
- Generous spacing, rounded lane separators, group labels in muted small-caps.

## Constraints / non-goals

- **Frozen VM contract:** only call existing `EditorVM` methods; never write
  `playheadTime` directly (use `seek(to:)`); keep the
  `beginInteractiveEdit → updateX → endInteractiveEdit` drag pattern (the
  `isTimelineItemInteractionActive` flag is load-bearing).
- Keep all seven `TimelineSelection` cases working; `removeSelectedTimelineItem()` must
  keep dispatching.
- Keep `TimelinePreferences`, `TimelineEventSampler`, `WaveformTimelineMapper` and their
  tests green.
- No new tools, no inspector changes, no export changes.
- Public init `TimelineView(editorVM:compact:)` is unchanged so `EditorView` is untouched.

## File plan

New:
- `Views/Editor/TimelineSnapping.swift`
- `Views/Editor/TimelineClip.swift`
- `Views/Editor/TimelineFilmstrip.swift`
- `Views/Editor/TimelineLane.swift`

Rewritten:
- `Views/Editor/TimelineView.swift`

Likely removable (logic absorbed into the generic clip): pieces of
`ZoomTrackView.swift` (the block; the tap-to-add-zoom behavior is preserved on the
filmstrip).

## Build / verify

```bash
swift build                 # compile
swift test --filter Timeline   # timeline logic tests stay green
./run.sh --build-only        # full app bundle builds
```

Manual: open a project with zoom segments + cuts + audio; confirm filmstrip renders,
single playhead spans lanes, gutter stays put while scrolling, snapping works, and every
clip type still drags/resizes/deletes/undoes.
