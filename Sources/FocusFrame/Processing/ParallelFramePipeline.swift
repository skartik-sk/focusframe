import Foundation
import CoreVideo
import CoreImage

/// Drives frame rendering across N workers, feeding results to a sink in strict
/// ascending frame order.
///
/// Two phases per chunk:
///  1. **Serial decode** — `decode(index)` is called once per frame, in ascending
///     order, before the chunk's composite. This is where the (necessarily serial)
///     `AVAssetReader` runs; it is ~34× faster than per-frame `copyCGImage` seeks, so
///     keeping it serial costs little while removing the old decode bottleneck.
///  2. **Parallel composite** — each frame in the chunk is handed to a *distinct*
///     worker and composited concurrently. No two concurrent tasks share a worker, so
///     a worker's mutable Core Image state is never accessed concurrently.
///
/// The chunk's task group is a barrier; once it completes the finished buffers go to
/// `sink` in ascending index order. Output is therefore identical to a serial render,
/// and memory is bounded by `workerCount`.
///
/// Concurrency note: `CIImage` (decoded source) and `CVPixelBuffer` (finished frame)
/// are both non-`Sendable`, so they never cross a task boundary as values. The decoded
/// source is handed to the worker through a locked `SlotStore` (`@unchecked Sendable`);
/// the finished buffer the same way. Inside a task they are plain locals.
struct ParallelFramePipeline<Worker: Sendable> {
    let workerCount: Int
    let makeWorker: @Sendable () -> Worker
    /// Serial, in-order source decode. Called once per frame before its chunk's
    /// parallel composite.
    let decode: @Sendable (Int) throws -> CIImage
    /// Composites one frame (parallel). `source` is the pre-decoded frame for `index`.
    let render: @Sendable (Worker, Int, CIImage) throws -> CVPixelBuffer
    /// Receives each finished buffer in strict ascending `index` order.
    let sink: @Sendable (Int, CVPixelBuffer) async throws -> Void

    /// Renders frames `0..<frameCount`.
    /// - `isCancelled`: throws to request cancellation (checked between and within chunks).
    /// - `onProgress`: invoked after each chunk with the number of frames just completed.
    func run(
        frameCount: Int,
        isCancelled: @Sendable () throws -> Void,
        onProgress: @Sendable (Int) -> Void
    ) async throws {
        guard frameCount > 0 else { return }

        let count = max(1, workerCount)
        let workers: [Worker] = (0..<count).map { _ in makeWorker() }

        var index = 0
        while index < frameCount {
            try isCancelled()

            let chunkEnd = min(index + count, frameCount)
            let chunkSize = chunkEnd - index

            // Serial decode of the chunk's source frames, in order.
            let sources = SlotStore<CIImage>(count: chunkSize)
            for offset in 0..<chunkSize {
                sources.set(offset, try decode(index + offset))
            }

            // Parallel composite. Each task reads its pre-decoded source from the store,
            // composites, and deposits the finished buffer.
            let buffers = SlotStore<CVPixelBuffer>(count: chunkSize)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for offset in 0..<chunkSize {
                    let frameIndex = index + offset
                    let worker = workers[offset]
                    group.addTask {
                        guard let source = sources.take(offset) else {
                            throw PipelineError.missingFrame(frameIndex)
                        }
                        let buffer = try render(worker, frameIndex, source)
                        buffers.set(offset, buffer)
                    }
                }
                try await group.waitForAll()
            }

            try isCancelled()

            for offset in 0..<chunkSize {
                guard let buffer = buffers.take(offset) else {
                    throw PipelineError.missingFrame(index + offset)
                }
                try await sink(index + offset, buffer)
            }

            onProgress(chunkSize)
            index = chunkEnd
        }
    }
}

enum PipelineError: Error {
    /// A frame could not be decoded or composited within its chunk.
    case missingFrame(Int)
}

/// Lock-protected, fixed-size slot store. `@unchecked Sendable`: access is serialized
/// through `lock`, so it is safe to share across the tasks of a single chunk. Used for
/// both the non-`Sendable` decoded source (`CIImage`) and finished frame
/// (`CVPixelBuffer`), letting those values cross task boundaries safely.
final class SlotStore<T>: @unchecked Sendable {
    private var slots: [T?]
    private let lock = NSLock()

    init(count: Int) {
        slots = Array(repeating: nil, count: count)
    }

    func set(_ offset: Int, _ value: T) {
        lock.lock()
        slots[offset] = value
        lock.unlock()
    }

    func take(_ offset: Int) -> T? {
        lock.lock()
        let value = slots[offset]
        slots[offset] = nil
        lock.unlock()
        return value
    }
}
