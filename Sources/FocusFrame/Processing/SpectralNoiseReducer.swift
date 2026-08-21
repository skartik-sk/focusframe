import Accelerate

/// Stationary-noise reducer using STFT spectral subtraction.
///
/// Two-pass design: pass 1 computes the magnitude spectrum of every analysis frame and
/// takes a per-bin low percentile as the noise profile (robust even when speech occupies
/// most of the timeline, because it only needs the quietest ~10% of frames). Pass 2
/// applies a Wiener-style gain per bin with temporal smoothing, then overlap-adds back.
///
/// This removes broadband hiss/fan/air-conditioner noise that a simple gate cannot touch,
/// without the musical-noise artifacts of naive subtraction (floor gain + smoothing).
final class SpectralNoiseReducer {
    private let fftSize = 1024
    private let hopSize = 256
    private var window: [Float] = []
    private var fftSetup: FFTSetup?
    private var log2n: vDSP_Length

    /// Suppression floor: never fully zero a bin (avoids underwater/musical artifacts).
    private let gainFloor: Float = 0.03
    /// Over-subtraction factor on the estimated noise magnitude.
    private let overSubtraction: Float = 2.2
    /// Temporal gain smoothing (higher = steadier, less flutter).
    private let gainSmoothing: Float = 0.55

    init() {
        log2n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    func reduceNoise(samples: inout [Float], sampleRate: Float) {
        guard samples.count >= fftSize * 2, let fftSetup else { return }
        _ = sampleRate // reserved for future frequency-dependent weighting

        let frameCount = max(1, (samples.count - fftSize) / hopSize + 1)
        let binCount = fftSize / 2
        var magnitudes = [Float](repeating: 0, count: binCount)

        // Pass 1: collect per-frame magnitude spectra to estimate the noise profile.
        // Bound memory on long recordings: the profile only needs a representative
        // sample of frames (~50k spectra ≈ 100MB worst case), so skip frames beyond that.
        let analysisStride = max(1, frameCount / 50_000)
        let analyzedFrameCount = (frameCount + analysisStride - 1) / analysisStride
        var allMagnitudes = [[Float]]()
        allMagnitudes.reserveCapacity(analyzedFrameCount)

        for frame in stride(from: 0, to: frameCount, by: analysisStride) {
            let start = frame * hopSize
            var windowed = [Float](repeating: 0, count: fftSize)
            samples.withUnsafeBufferPointer { buffer in
                for index in 0..<fftSize {
                    windowed[index] = buffer[start + index] * window[index]
                }
            }

            var frameReal = [Float](repeating: 0, count: binCount)
            var frameImag = [Float](repeating: 0, count: binCount)
            windowed.withUnsafeBufferPointer { windowedBuffer in
                for index in 0..<binCount {
                    frameReal[index] = windowedBuffer[index]
                    frameImag[index] = windowedBuffer[binCount + index]
                }
            }
            frameReal.withUnsafeMutableBufferPointer { realBuffer in
                frameImag.withUnsafeMutableBufferPointer { imagBuffer in
                    var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(binCount))
                }
            }
            allMagnitudes.append(magnitudes)
        }

        // Noise profile: per-bin 10th percentile of magnitude^2 across analyzed frames.
        var noiseProfile = [Float](repeating: 0, count: binCount)
        var column = [Float](repeating: 0, count: analyzedFrameCount)
        for bin in 0..<binCount {
            for slot in 0..<analyzedFrameCount {
                column[slot] = allMagnitudes[slot][bin]
            }
            column.sort()
            let index = min(analyzedFrameCount - 1, max(0, Int(Float(analyzedFrameCount - 1) * 0.1)))
            noiseProfile[bin] = column[index]
        }

        // Pass 2: Wiener-style suppression with temporal smoothing + overlap-add.
        var output = [Float](repeating: 0, count: samples.count)
        var windowSquaredSum = [Float](repeating: 0, count: samples.count)
        var previousGains = [Float](repeating: 1, count: binCount)
        var frameReal = [Float](repeating: 0, count: fftSize)
        var frameImag = [Float](repeating: 0, count: fftSize / 2)

        for frame in 0..<frameCount {
            let start = frame * hopSize
            for index in 0..<fftSize {
                frameReal[index] = samples[start + index] * window[index]
            }
            for index in 0..<binCount {
                frameImag[index] = frameReal[binCount + index]
                frameReal[binCount + index] = 0
            }

            frameReal.withUnsafeMutableBufferPointer { realBuffer in
                frameImag.withUnsafeMutableBufferPointer { imagBuffer in
                    var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                    for bin in 1..<binCount {
                        let power = split.realp[bin] * split.realp[bin] + split.imagp[bin] * split.imagp[bin]
                        let snr = power / max(noiseProfile[bin] * overSubtraction * overSubtraction, 1e-12)
                        var gain = (snr - 1) / snr
                        gain = max(gainFloor, min(1, gain))
                        gain = gainSmoothing * previousGains[bin] + (1 - gainSmoothing) * gain
                        previousGains[bin] = gain
                        split.realp[bin] *= gain
                        split.imagp[bin] *= gain
                    }
                    if binCount > 0 {
                        split.realp[0] *= gainFloor
                    }

                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                    let scale = Float(1.0 / Double(2 * fftSize))
                    for index in 0..<fftSize {
                        let value = (index < binCount ? split.realp[index] : split.imagp[index - binCount]) * scale
                        output[start + index] += value * window[index]
                        windowSquaredSum[start + index] += window[index] * window[index]
                    }
                }
            }
        }

        // Normalize overlap-add by the summed squared window.
        for index in 0..<samples.count where windowSquaredSum[index] > 1e-6 {
            samples[index] = output[index] / windowSquaredSum[index]
        }
    }
}
