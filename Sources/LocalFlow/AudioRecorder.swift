import AVFoundation

/// Captures microphone audio and accumulates it as 16 kHz mono Float32 —
/// the input format Whisper models expect.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()

    /// Live input level (0…1), delivered on the main queue — drives the
    /// listening overlay's waveform.
    var onLevel: ((Float) -> Void)?

    static let targetSampleRate = 16_000.0

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: false
    )!

    func start() throws {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "LocalFlow", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No audio input device available."
            ])
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops the engine and returns everything captured since `start()`.
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = Self.targetSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: out, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }

        let frameCount = Int(out.frameLength)
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: frameCount))
        lock.unlock()

        if let onLevel {
            // RMS → rough 0…1 loudness for the waveform overlay.
            var sumOfSquares: Float = 0
            for i in 0..<frameCount {
                sumOfSquares += channel[i] * channel[i]
            }
            let rms = (sumOfSquares / Float(frameCount)).squareRoot()
            let level = min(1, rms * 12)
            DispatchQueue.main.async { onLevel(level) }
        }
    }
}
