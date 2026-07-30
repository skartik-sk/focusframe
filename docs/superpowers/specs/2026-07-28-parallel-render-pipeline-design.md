# Parallel Render Pipeline — Design

**Date:** 2026-07-28
**Status:** Approved (autonomous execution)
**Goal:** Make FocusFrame exports use all CPU/GPU cores instead of one, closing the perf gap vs DaVinci/OBS.

## Root cause (why exports are slow)

`ExportVM.exportVideo` / `exportGIF` render frames in a **strictly serial loop**: per frame — decode (`AVAssetImageGenerator.copyCGImage`), composite (`VideoRenderer.renderFrame` → `ciContext.render`), append to writer — then the next frame begins. One core does everything; the rest idle. A `Task.sleep(10ms)` spin-wait gates the encoder. `createSampleBuffer` is dead code.

## Approach

**Chunked, barrier-ordered parallel render** — the robust, low-risk form of the "full parallel pipeline":

- N persistent **render workers** (N = physical core count), each owning its own `VideoRenderer`, `CIContext`, and source+webcam `AVAssetImageGenerator` (per-instance decode parallelizes; same config/tolerance preserves output).
- Frames processed in **chunks of size N**. Within a chunk, each frame is assigned to a distinct worker and rendered concurrently (no two tasks touch the same worker → no races on renderer/filter mutable state).
- After the chunk's `TaskGroup` completes (**barrier**), the chunk's buffers are appended to the writer **in index order** (encoder requires presentation-time order). Next chunk.
- **Output is bit-identical** to the serial path: per-frame pixels are a pure function of `(inputs, config)`; ordering is enforced by chunk barriers + sequential append.

Why chunked-barrier over a full producer/consumer mailbox: dramatically simpler, no NSCondition/ordered-store, memory bounded by N, near-linear speedup, and the dominant cost (composite) parallelizes fully. Encoder-overlap (render next chunk while appending current) is a documented future micro-opt.

`AVAssetReader` hardware decode was the originally-named decoder swap. It is deferred: random-access frame needs (cuts / speed-changes) make per-segment readers complex, and per-worker `AVAssetImageGenerator` already saturates cores for the composite-bound workload. Tracked as a future lever for 4K/HEVC decode-bound cases, along with relaxing `requestedTimeTolerance`.

## Components

- `ParallelFramePipeline` — generic, tested. Drives `count` frames through N workers, invoking a `sink` in strict ascending order. Owns worker lifecycle + chunk barriers. Reusable for video and GIF.
- `RenderWorker` (`@unchecked Sendable`) — holds per-worker `VideoRenderer` + `CIContext` + source/webcam image generators. Safety invariant: **at most one task uses a worker at a time** (distinct offsets within a chunk; barrier between chunks).
- `FrameRenderContext` (`Sendable` struct) — all read-only data the per-frame input builder needs (project, transforms, smoothed cursor, key events, captions, timeline, source size, profile). Lets worker tasks avoid capturing non-Sendable `self`.
- Telemetry — atomic-ish frame counter updated per chunk → `renderedFPS`, `estimatedTimeRemaining`, `coresInUse` on `ExportVM` (additive `@Published`; current UI keeps working until the UI phase consumes them).
- `ExportVM.exportVideo` / `exportGIF` — refactored to build context + workers, run the pipeline, append via existing adaptor/destination. Public API unchanged.

## Invariants & testing

- **Ordering:** sink receives frames `0..<count` strictly ascending, even when workers finish out of order.
- **Determinism:** parallel output == serial baseline (frame-hash compare on a fixed fake project; verified with an injected deterministic fake renderer so no AVFoundation needed).
- **Cancellation:** mid-render cancel drains cleanly, no partial output file (existing defer-cleanups retained).
- **Memory bound:** in-flight buffers ≤ N (one per worker).
- Existing `ExportRuntimeTests` / suite must stay green; public `export(project:profile:)` signature unchanged.

## Sequencing

1. Extract per-frame render into a pure, injectable unit; build + unit-test `ParallelFramePipeline` (ordering/determinism with fakes).
2. Wire into `exportVideo` (video), then `exportGIF`.
3. Add telemetry fields.
4. `swift build` + `swift test` green; verify worker count = cores.

UI polish (export progress, home, recording overlay) is a separate, independent workstream — dedicated brainstorm after this lands.
