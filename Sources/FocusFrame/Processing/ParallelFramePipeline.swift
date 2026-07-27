import Foundation
import CoreVideo

/// Drives frame rendering across N workers, feeding results to a sink in strict
/// ascending frame order.
///
/// The previous export path rendered every frame serially on a single thread:
/// decode → composite → append, one frame at a time, leaving the remaining cores
/// idle. This pipeline parallelizes the per-frame work (decode + composite) across
/// a pool of `workerCount` workers while preserving the encoder's hard requirement
/// that frames arrive in presentation-time order.
///
/// Strategy — ordered chunks:
///  1. Frames are processed in chunks of size `workerCount`.
///  2. Within a chunk every frame is handed to a *distinct* worker and rendered
///     concurrently. Because no two concurrent tasks share a worker, a worker's
///     mutable state (Core Image filters, caches) is never accessed concurrently.
///  3. The chunk's task group acts as a barrier. Once it completes, the finished
///     buffers are handed to `sink` in ascending index order, then the next chunk
///     begins.
///
/// Output is therefore identical to a serial render: each frame's pixels are a pure
/// function of its inputs, and ordering is enforced by the chunk barriers plus the
/// sequential sink. Memory is bounded by `workerCount` (one buffer per worker).
///
/// Note on concurrency: `CVPixelBuffer` is a shared, mutable CoreVideo buffer and is
/// explicitly non-`Sendable`, so it may not cross a task boundary as a return value.
/// Workers therefore deposit their finished buffer into a locked, `@unchecked
/// Sendable` slot store instead; the buffer never leaves the task that produced it
/// until the barrier, after which it is consumed single-threaded.
struct ParallelFramePipeline<Worker: Sendable> {
    let workerCount: Int
    let makeWorker: @Sendable () -> Worker
    /// Renders frame `index` and returns its pixel buffer. Called concurrently,
    /// at most once per worker at a time.
    let render: @Sendable (Worker, Int) throws -> CVPixelBuffer
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
            let store = FrameSlotStore(count: chunkSize)

            try await withThrowingTaskGroup(of: Void.self) { group in
                for offset in 0..<chunkSize {
                    let frameIndex = index + offset
                    let worker = workers[offset]
                    group.addTask {
                        let buffer = try render(worker, frameIndex)
                        store.set(offset, buffer)
                    }
                }
                try await group.waitForAll()
            }

            try isCancelled()

            for offset in 0..<chunkSize {
                guard let buffer = store.take(offset) else {
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
    /// A worker finished without producing a buffer for a frame in its chunk.
    case missingFrame(Int)
}

/// Lock-protected, fixed-size slot store for finished pixel buffers. `@unchecked
/// Sendable`: access is serialized through `lock`, so it is safe to share across
/// the worker tasks of a single chunk.
final class FrameSlotStore: @unchecked Sendable {
    private var slots: [CVPixelBuffer?]
    private let lock = NSLock()

    init(count: Int) {
        slots = Array(repeating: nil, count: count)
    }

    func set(_ offset: Int, _ buffer: CVPixelBuffer) {
        lock.lock()
        slots[offset] = buffer
        lock.unlock()
    }

    func take(_ offset: Int) -> CVPixelBuffer? {
        lock.lock()
        let buffer = slots[offset]
        slots[offset] = nil
        lock.unlock()
        return buffer
    }
}
