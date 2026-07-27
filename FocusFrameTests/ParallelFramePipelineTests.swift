import XCTest
import CoreVideo
@testable import FocusFrame

/// Lock-protected mutable holder for observing pipeline behavior from `@Sendable`
/// closures. `@unchecked Sendable`: all access is serialized through `lock`.
final class LockBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&value); lock.unlock() }
    func get() -> T { lock.lock(); let v = value; lock.unlock(); return v }
}

private func makeBuffer() -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &pb
    )
    XCTAssertEqual(status, kCVReturnSuccess)
    return pb!
}

final class ParallelFramePipelineTests: XCTestCase {

    /// A pipeline whose `render` finishes out of natural order: later indices sleep
    /// less, so completion order is the reverse of index order. The sink must still
    /// observe frames in ascending index order.
    private func reversedCompletionPipeline(
        frameCount: Int,
        workerCount: Int
    ) -> (ParallelFramePipeline<Int>, seen: LockBox<[Int]>) {
        let seen = LockBox<[Int]>([])

        let pipeline = ParallelFramePipeline<Int>(
            workerCount: workerCount,
            makeWorker: { 0 },
            render: { _, index in
                // Larger index -> shorter sleep -> finishes first.
                let delay = UInt64(max(0, frameCount - index)) * 2_000_000
                if delay > 0 { Thread.sleep(forTimeInterval: TimeInterval(delay) / 1_000_000_000) }
                return makeBuffer()
            },
            sink: { index, _ in
                seen.mutate { $0.append(index) }
            }
        )

        return (pipeline, seen)
    }

    func testSinkReceivesFramesInAscendingOrder() async throws {
        let frameCount = 24
        let (pipeline, seen) = reversedCompletionPipeline(frameCount: frameCount, workerCount: 6)

        try await pipeline.run(
            frameCount: frameCount,
            isCancelled: { },
            onProgress: { _ in }
        )

        XCTAssertEqual(seen.get(), Array(0..<frameCount), "Sink must observe frames in strict ascending order")
    }

    func testEveryFrameRenderedExactlyOnce() async throws {
        let frameCount = 18
        let rendered = LockBox<Set<Int>>([])

        let pipeline = ParallelFramePipeline<Int>(
            workerCount: 4,
            makeWorker: { 0 },
            render: { _, index in
                rendered.mutate { $0.insert(index) }
                return makeBuffer()
            },
            sink: { _, _ in }
        )

        try await pipeline.run(
            frameCount: frameCount,
            isCancelled: { },
            onProgress: { _ in }
        )

        XCTAssertEqual(rendered.get(), Set(0..<frameCount))
    }

    func testZeroFrameCountIsNoOp() async throws {
        let sinkCount = LockBox<Int>(0)

        let pipeline = ParallelFramePipeline<Int>(
            workerCount: 4,
            makeWorker: { 0 },
            render: { _, _ in makeBuffer() },
            sink: { _, _ in sinkCount.mutate { $0 += 1 } }
        )

        try await pipeline.run(
            frameCount: 0,
            isCancelled: { },
            onProgress: { _ in }
        )

        XCTAssertEqual(sinkCount.get(), 0)
    }

    func testProgressReportsCumulativeFrames() async throws {
        let frameCount = 16
        let total = LockBox<Int>(0)
        let reports = LockBox<Int>(0)

        let pipeline = ParallelFramePipeline<Int>(
            workerCount: 4,
            makeWorker: { 0 },
            render: { _, _ in makeBuffer() },
            sink: { _, _ in }
        )

        try await pipeline.run(
            frameCount: frameCount,
            isCancelled: { },
            onProgress: { frames in
                total.mutate { $0 += frames }
                reports.mutate { $0 += 1 }
            }
        )

        XCTAssertEqual(total.get(), frameCount)
        XCTAssertGreaterThan(reports.get(), 0)
    }

    func testCancellationStopsPipeline() async throws {
        let frameCount = 1000
        let budget = LockBox<Int>(8)
        let sinkCount = LockBox<Int>(0)

        let pipeline = ParallelFramePipeline<Int>(
            workerCount: 4,
            makeWorker: { 0 },
            render: { _, _ in makeBuffer() },
            sink: { _, _ in sinkCount.mutate { $0 += 1 } }
        )

        do {
            try await pipeline.run(
                frameCount: frameCount,
                isCancelled: {
                    let stop = budget.mutateAndReturn { current -> (Int, Bool) in
                        let next = current - 1
                        return (next, next <= 0)
                    }
                    if stop { throw CancellationError() }
                },
                onProgress: { _ in }
            )
            XCTFail("Expected cancellation to throw")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertLessThan(sinkCount.get(), frameCount)
    }

    func testWorkerCountClampsToOne() async throws {
        // workerCount of 0 must still process every frame via a single worker.
        let frameCount = 5
        let seen = LockBox<[Int]>([])

        let pipeline = ParallelFramePipeline<Int>(
            workerCount: 0,
            makeWorker: { 0 },
            render: { _, _ in makeBuffer() },
            sink: { index, _ in seen.mutate { $0.append(index) } }
        )

        try await pipeline.run(
            frameCount: frameCount,
            isCancelled: { },
            onProgress: { _ in }
        )

        XCTAssertEqual(seen.get(), Array(0..<frameCount))
    }

    /// Proves the engine actually renders frames concurrently (i.e. uses more than one
    /// core) rather than serializing them. The render closure tracks the high-water
    /// mark of simultaneously in-flight renders; with N>1 workers it must exceed 1.
    func testFramesRenderConcurrently() async throws {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        try XCTSkipUnless(cores >= 2, "Concurrency test needs ≥2 cores")

        let frameCount = max(cores * 4, 8)
        let inFlight = LockBox<Int>(0)
        let maxConcurrency = LockBox<Int>(0)
        let done = LockBox<Bool>(false)

        let pipeline = ParallelFramePipeline<Int>(
            workerCount: cores,
            makeWorker: { 0 },
            render: { _, _ in
                let current = inFlight.mutateAndReturn { c -> (Int, Int) in (c + 1, c + 1) }
                _ = maxConcurrency.mutateAndReturn { m -> (Int, Int) in (max(m, current), max(m, current)) }
                // Hold the slot briefly so workers overlap.
                Thread.sleep(forTimeInterval: 0.01)
                _ = inFlight.mutate { $0 -= 1 }
                return makeBuffer()
            },
            sink: { _, _ in }
        )

        try await pipeline.run(
            frameCount: frameCount,
            isCancelled: { },
            onProgress: { _ in }
        )
        done.mutate { $0 = true }

        XCTAssertGreaterThan(maxConcurrency.get(), 1, "Workers must render frames concurrently")
    }

    /// Proves real CPU work completes faster across all cores than on one. Each frame
    /// does a fixed amount of deterministic computation; with N>1 workers the wall-clock
    /// should be materially below the single-worker time.
    func testParallelCpuWorkIsFasterThanSerial() async throws {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        try XCTSkipUnless(cores >= 2, "Speedup test needs ≥2 cores")

        let frameCount = cores * 6
        // Enough work per frame to dwarf scheduling overhead.
        @Sendable func heavyRender(_: Int, _ index: Int) -> CVPixelBuffer {
            var acc: Double = Double(index)
            for i in 0..<2_000_000 { acc += Double(i) * 0.000_000_1 }
            blackHole = acc
            return makeBuffer()
        }

        func time(_ workers: Int) async throws -> TimeInterval {
            let pipeline = ParallelFramePipeline<Int>(
                workerCount: workers,
                makeWorker: { 0 },
                render: heavyRender,
                sink: { _, _ in }
            )
            let start = Date()
            try await pipeline.run(frameCount: frameCount, isCancelled: { }, onProgress: { _ in })
            return Date().timeIntervalSince(start)
        }

        let serial = try await time(1)
        let parallel = try await time(cores)
        let speedup = serial / parallel

        print("[ParallelFramePipeline] cores=\(cores) frames=\(frameCount)  serial(1)=\(String(format: "%.3f", serial))s  parallel(\(cores))=\(String(format: "%.3f", parallel))s  speedup=\(String(format: "%.2f", speedup))x")

        XCTAssertGreaterThan(speedup, 1.3, "Parallel render across \(cores) cores should beat single-core by >1.3x")
    }
}

/// Sink to keep the optimizer from eliminating the synthetic busy work.
nonisolated(unsafe) private var blackHole: Double = 0

private extension LockBox {
    /// Map-and-return-under-lock helper for the cancellation test.
    func mutateAndReturn<U>(_ f: (T) -> (T, U)) -> U {
        lock.lock()
        let (next, result) = f(value)
        value = next
        lock.unlock()
        return result
    }
}
