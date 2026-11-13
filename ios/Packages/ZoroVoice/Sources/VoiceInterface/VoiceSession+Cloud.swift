import AudioEngine
import Foundation
import ZoroCore

// The cloud engine: realtime voice model over a WebSocket, with automatic fallback to on-device.
extension VoiceSession {
    /// Fetches a grant and opens the socket. False when either fails (the caller falls back).
    func connectCloud(resumptionHandle handle: String?) async -> Bool {
        do {
            let grant = try await deps.backend.liveSessionGrant()
            let stream = try await deps.liveTransport.connect(grant: grant, resumptionHandle: handle)
            liveGen += 1
            let gen = liveGen
            cloudConnected = true
            liveTask?.cancel()
            liveTask = Task {
                do {
                    for try await event in stream { await self.handleLive(event, gen: gen) }
                    await self.liveEnded(gen: gen, error: nil)
                } catch {
                    await self.liveEnded(gen: gen, error: error)
                }
            }
            return true
        } catch {
            cloudConnected = false
            return false
        }
    }

    func liveEnded(gen: Int, error: Error?) async {
        guard gen == liveGen, sessionActive, engine == .cloud else { return }
        cloudConnected = false
        liveTask = nil
        if let handle = resumptionHandle, reconnectAttempts < 1 {
            reconnectAttempts += 1
            if await connectCloud(resumptionHandle: handle) { return }
        }
        await fallbackToOnDevice(.socketFailed)
    }

    /// GoAway: open a new connection with the resumption handle before the server closes this one.
    func reconnectForGoAway() async {
        guard sessionActive, engine == .cloud else { return }
        liveGen += 1
        liveTask?.cancel()
        liveTask = nil
        cloudConnected = false
        if await connectCloud(resumptionHandle: resumptionHandle) { return }
        await fallbackToOnDevice(.socketFailed)
    }

    func fallbackToOnDevice(_ reason: EngineFallbackReason) async {
        liveGen += 1
        liveTask?.cancel()
        liveTask = nil
        cloudConnected = false
        await deps.liveTransport.close()
        let wasBusy = phase.isBusy
        if wasBusy { await cancelReplyWork(notifyBackend: true) }
        engine = .onDevice
        emit(.engine(.onDevice, fallback: reason))
        if let error = await prepareOnDeviceRecognition() {
            await fail(error)
            return
        }
        if wasBusy { transition(.bargeIn) }
        if phase == .listening { await beginListening(withPreRoll: false) }
    }

    func handleLive(_ event: LiveServerEvent, gen: Int) async {
        guard gen == liveGen, sessionActive, engine == .cloud else { return }
        switch event {
        case .setupComplete, .generationComplete:
            break
        case .inputTranscript(let text):
            guard phase == .listening else { return }
            if inputTranscript.isEmpty { latency.markSpeechStart(deps.clock.now()) }
            cloudAudioMuted = false
            inputTranscript += text
            latency.markPartial(deps.clock.now())
            emit(.partialTranscript(inputTranscript.trimmingCharacters(in: .whitespaces)))
        case .audio(let data):
            guard !cloudAudioMuted else { return }
            if phase != .speaking {
                guard transition(.replyAudioStarted) else { return }
                emitCloudUtterance()
                latency.markFirstAudio(deps.clock.now())
            }
            do {
                try await deps.player.enqueue(data)
            } catch {
                await fail(.audio(error.localizedDescription))
            }
        case .outputTranscript(let text):
            emit(.replyText(text))
        case .interrupted:
            // Server-side barge-in: drop queued audio now.
            if phase.isBusy {
                await bargeIn()
            } else {
                await deps.player.flush()
            }
            cloudAudioMuted = false
        case .turnComplete:
            reconnectAttempts = 0
            cloudAudioMuted = false
            inputTranscript = ""
            await cloudTurnComplete()
        case .toolCall(let calls):
            for call in calls { await handleToolCall(call) }
        case .toolCallCancellation(let ids):
            if let call = askCall, ids.contains(call.id) {
                askCall = nil
                await cancelReplyWork(notifyBackend: true)
                if phase.isBusy { transition(.bargeIn) }
            }
        case .goAway:
            await reconnectForGoAway()
        case .resumptionUpdate(let handle, let resumable):
            if resumable, let handle { resumptionHandle = handle }
        }
    }

    func emitCloudUtterance() {
        let text = inputTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let language = LanguageIdentifier.identify(text)
        lastLanguage = language
        emit(.finalTranscript(text, language: language))
        inputTranscript = ""
    }

    func cloudTurnComplete() async {
        switch phase {
        case .speaking where speechTask == nil:
            let gen = turnGen
            let player = deps.player
            Task {
                let played = await player.finish()
                await self.cloudPlaybackDrained(gen: gen, played: played)
            }
        case .processing, .delegating, .toolExecution:
            // The model finished without speaking after ZORO's answer.
            if turnFinished, askCall == nil, speechTask == nil { await replyDone() }
        default:
            break
        }
    }

    func cloudPlaybackDrained(gen: Int, played: Bool) async {
        guard played, gen == turnGen, phase == .speaking, speechTask == nil else { return }
        await replyDone()
    }

    /// `ask_zoro`: run a normal backend turn so policy, approvals and privacy stay on the server.
    func handleToolCall(_ call: LiveFunctionCall) async {
        guard call.name == LiveMessageCodec.toolName,
            let request = call.args["request"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !request.isEmpty
        else {
            try? await deps.liveTransport.sendToolResponse(
                callId: call.id, name: call.name, response: ["error": .string("Unknown function or empty request.")])
            return
        }
        latency.markUtteranceEnd(deps.clock.now())
        if inputTranscript.isEmpty { inputTranscript = request }
        emitCloudUtterance()
        let language = LanguageIdentifier.identify(request)
        transition(.utteranceSubmitted)
        startTurn(text: request, language: language, askCall: call)
    }
}
