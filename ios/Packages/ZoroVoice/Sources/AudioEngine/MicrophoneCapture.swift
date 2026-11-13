import Foundation

/// Microphone capture: hardware buffers in, 16 kHz mono PCM chunks with level and VAD out.
/// Both internal queues are bounded (newest kept), so a stalled consumer never grows memory.
public actor MicrophoneCapture: AudioCapturing {
    private let hardware: any AudioInputHardware
    private let vadConfiguration: VADConfiguration
    private var processingTask: Task<Void, Never>?
    private var output: AsyncStream<CapturedChunk>.Continuation?
    private var running = false

    public init(hardware: any AudioInputHardware, vad: VADConfiguration = VADConfiguration()) {
        self.hardware = hardware
        self.vadConfiguration = vad
    }

    public func start() async throws -> AsyncStream<CapturedChunk> {
        await stop()
        let (raw, rawContinuation) = AsyncStream<RawAudioBuffer>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let (chunks, chunkContinuation) = AsyncStream<CapturedChunk>.makeStream(bufferingPolicy: .bufferingNewest(64))
        do {
            try await hardware.startInput { buffer in rawContinuation.yield(buffer) }
        } catch {
            rawContinuation.finish()
            chunkContinuation.finish()
            throw error
        }
        running = true
        output = chunkContinuation
        let config = vadConfiguration
        processingTask = Task.detached(priority: .userInitiated) {
            var processor = CaptureProcessor(vad: config)
            for await buffer in raw {
                if Task.isCancelled { break }
                chunkContinuation.yield(processor.process(buffer))
            }
            chunkContinuation.finish()
        }
        let task = processingTask
        rawContinuation.onTermination = { _ in task?.cancel() }
        chunkContinuation.onTermination = { _ in rawContinuation.finish() }
        return chunks
    }

    public func stop() async {
        guard running else { return }
        running = false
        await hardware.stopInput()
        processingTask?.cancel()
        processingTask = nil
        output?.finish()
        output = nil
    }
}
