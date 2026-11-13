import AudioEngine
import Foundation
import ZoroCore

// On-device recognition, the backend turn, and sentence-by-sentence system speech.
extension VoiceSession {
    // MARK: - Recognition

    /// Authorises speech recognition and checks a locale is usable. Returns the error, if any.
    func prepareOnDeviceRecognition() async -> VoiceError? {
        var auth = await deps.recognizer.authorization()
        if auth == .notDetermined { auth = await deps.recognizer.requestAuthorization() }
        guard auth == .authorized else { return .speechRecognitionDenied }
        localeAvailability.removeAll()
        if await pickLocale() == nil {
            return .recognitionUnavailable(locales: candidateLocales, onDeviceRequired: privacy == .strictPrivate)
        }
        return nil
    }

    var candidateLocales: [String] {
        LocaleSelector.recognitionLocales(setting: settings.language, hint: options.languageHint, last: lastLanguage)
    }

    /// First candidate locale the recogniser supports; strict private mode requires on-device recognition.
    func pickLocale() async -> String? {
        for locale in candidateLocales {
            let availability: RecognizerAvailability
            if let cached = localeAvailability[locale] {
                availability = cached
            } else {
                availability = await deps.recognizer.availability(locale: locale)
                localeAvailability[locale] = availability
            }
            switch availability {
            case .onDevice: return locale
            case .serverOnly where privacy != .strictPrivate: return locale
            default: continue
            }
        }
        return nil
    }

    func beginListening(withPreRoll: Bool) async {
        guard sessionActive, phase == .listening, engine == .onDevice else { return }
        if recognizing { await deps.recognizer.cancel() }
        recognitionTask?.cancel()
        utteranceGen += 1
        let gen = utteranceGen
        heardSpeech = withPreRoll
        lastPartial = ""
        bargeInSpeech = 0
        guard let locale = await pickLocale() else {
            await fail(.recognitionUnavailable(locales: candidateLocales, onDeviceRequired: privacy == .strictPrivate))
            return
        }
        let stream: AsyncThrowingStream<TranscriptUpdate, Error>
        do {
            stream = try await deps.recognizer.startUtterance(locale: locale, onDeviceOnly: privacy == .strictPrivate)
        } catch {
            await fail(VoiceError.from(error))
            return
        }
        guard gen == utteranceGen, phase == .listening else { return }
        recognizing = true
        emit(.listeningLocale(locale))
        if withPreRoll {
            for chunk in preRoll { await deps.recognizer.append(chunk) }
        }
        preRoll.removeAll()
        recognitionTask = Task {
            do {
                for try await update in stream { await self.handleTranscript(update, gen: gen) }
                await self.recognitionEnded(gen: gen, error: nil)
            } catch {
                await self.recognitionEnded(gen: gen, error: error)
            }
        }
        scheduleListenTimeout(gen: gen)
    }

    func scheduleListenTimeout(gen: Int) {
        listenTimeoutTask?.cancel()
        let wait = inFollowUp ? config.followUpWindow : config.listenTimeout
        listenTimeoutTask = Task { [clock = deps.clock] in
            try? await clock.sleep(seconds: wait)
            guard !Task.isCancelled else { return }
            await self.listenTimedOut(gen: gen)
        }
    }

    func listenTimedOut(gen: Int) async {
        guard gen == utteranceGen, phase == .listening, engine == .onDevice, lastPartial.isEmpty else { return }
        await deps.recognizer.cancel()
        recognizing = false
        await releaseAudio()
        transition(.stop)
        if quietRest == .privateOffline { transitionToPrivateRest() }
    }

    /// idle → privateOffline when the session closes quietly in strict private mode.
    func transitionToPrivateRest() {
        guard phase == .idle else { return }
        phase = .privateOffline
        stateBroadcaster.yield(phase.sessionState)
        emit(.phase(phase))
    }

    func handleTranscript(_ update: TranscriptUpdate, gen: Int) async {
        guard gen == utteranceGen, phase == .listening else { return }
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, text != lastPartial {
            latency.markPartial(deps.clock.now())
            lastPartial = text
            listenTimeoutTask?.cancel()
            emit(.partialTranscript(text))
        }
        if update.isFinal {
            recognizing = false
            await submitUtterance(text.isEmpty ? lastPartial : text)
        }
    }

    func recognitionEnded(gen: Int, error: Error?) async {
        guard gen == utteranceGen, phase == .listening, sessionActive else { return }
        recognizing = false
        if !lastPartial.isEmpty {
            await submitUtterance(lastPartial)
            return
        }
        if error != nil {
            recognitionFailures += 1
            if recognitionFailures >= config.maxRecognitionFailures {
                recognitionFailures = 0
                await fail(.recognitionUnavailable(locales: candidateLocales, onDeviceRequired: privacy == .strictPrivate))
                return
            }
        }
        // Nothing was said: keep listening until the timeout closes the orb.
        await beginListening(withPreRoll: false)
    }

    func submitUtterance(_ raw: String) async {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if inFollowUp, activation == .wakeWordInSession {
            guard let request = config.wakePhrase.strip(text), !request.isEmpty else {
                // Not addressed to ZORO: ignore it and keep the follow-up window open.
                await beginListening(withPreRoll: false)
                return
            }
            text = request
        }
        guard !text.isEmpty else {
            await beginListening(withPreRoll: false)
            return
        }
        recognitionFailures = 0
        listenTimeoutTask?.cancel()
        latency.markUtteranceEnd(deps.clock.now())
        let language = LanguageIdentifier.identify(text)
        lastLanguage = language
        emit(.finalTranscript(text, language: language))
        transition(.utteranceSubmitted)
        startTurn(text: text, language: language, askCall: nil)
    }

    // MARK: - Turn

    func startTurn(text: String, language: SpokenLanguage, askCall call: LiveFunctionCall?) {
        turnGen += 1
        let gen = turnGen
        turnTask?.cancel()
        activeAgents = []
        turnFinished = false
        chunker.reset()
        pendingSentences = []
        replyBuffer = ""
        currentTurnId = nil
        askCall = call
        let request = TurnRequest(
            conversationId: conversationId,
            input: TurnInput(text: text, modality: .voice, languageHint: language.rawValue),
            // A client may only ask for a stricter mode than the server's; otherwise the server decides.
            client: config.client, privacyMode: privacy == .strictPrivate ? .strictPrivate : nil)
        turnTask = Task { await self.runTurn(request, gen: gen, attempt: 0) }
    }

    func runTurn(_ request: TurnRequest, gen: Int, attempt: Int) async {
        var received = false
        do {
            for try await event in deps.backend.startTurn(request) {
                guard gen == turnGen, !Task.isCancelled else { return }
                received = true
                await handleTurnEvent(event, gen: gen)
                if event.isTerminal { return }
            }
            guard gen == turnGen, !Task.isCancelled else { return }
            if !turnFinished { await finishTurn(cloudVoiceAllowed: false, gen: gen) }
        } catch {
            guard gen == turnGen, !Task.isCancelled else { return }
            let voiceError = VoiceError.from(error)
            if !received, attempt == 0, voiceError.isRetryable {
                // One quick retry for a dropped connection before anything was shown.
                try? await deps.clock.sleep(seconds: 0.5)
                guard gen == turnGen, !Task.isCancelled else { return }
                await runTurn(request, gen: gen, attempt: 1)
                return
            }
            await failTurn(voiceError)
        }
    }

    func failTurn(_ error: VoiceError) async {
        if let call = askCall {
            askCall = nil
            try? await deps.liveTransport.sendToolResponse(
                callId: call.id, name: call.name, response: ["error": .string("ZORO could not complete this request.")])
        }
        await fail(error)
    }

    func handleTurnEvent(_ event: TurnEvent, gen: Int) async {
        latency.markFeedback(deps.clock.now())
        emit(.turn(event))
        switch event {
        case .turnStarted(let e):
            currentTurnId = e.turnId
            conversationId = e.conversationId
        case .route(let e):
            activeAgents.formUnion(e.agents)
            if !e.agents.isEmpty { transition(.agentsWorking) }
        case .agentStarted(let e):
            activeAgents.insert(e.agent)
            transition(.agentsWorking)
        case .agentFinished(let e):
            activeAgents.remove(e.agent)
        case .toolStarted:
            transition(.toolStarted)
        case .toolFinished:
            transition(.toolFinished(agentsStillWorking: !activeAgents.isEmpty))
        case .textDelta(let delta):
            emit(.replyText(delta.text))
            if askCall == nil {
                enqueueSpeech(chunker.append(delta.text))
            } else {
                replyBuffer += delta.text
            }
        case .turnCompleted(let e):
            if let reply = SpokenLanguage(code: e.language) { lastLanguage = reply }
            await finishTurn(cloudVoiceAllowed: e.cloudVoiceAllowed, gen: gen)
        case .turnSuspended:
            // Approval or device action: the app shows it; speak what was said so far on device.
            await finishTurn(cloudVoiceAllowed: false, gen: gen)
        case .error(let e):
            await failTurn(.turnFailed(e))
        case .card, .approvalRequired, .deviceAction, .unknown:
            break
        }
    }

    func finishTurn(cloudVoiceAllowed: Bool, gen: Int) async {
        guard gen == turnGen, !turnFinished else { return }
        turnFinished = true
        if let call = askCall {
            askCall = nil
            if cloudVoiceAllowed {
                // The realtime model speaks the backend's reply in its own voice.
                try? await deps.liveTransport.sendToolResponse(callId: call.id, name: call.name, response: ["result": .string(replyBuffer)])
                if replyBuffer.isEmpty { await replyDone() }
                return
            }
            // The reply may not go to the cloud voice: it is spoken on device, and the model only
            // learns that the answer was delivered.
            try? await deps.liveTransport.sendToolResponse(
                callId: call.id, name: call.name,
                response: ["result": "", "delivered_on_device": true, "instruction": "The answer was already shown and spoken to the owner. Do not repeat or add to it."])
            cloudAudioMuted = true
            enqueueSpeech(chunker.append(replyBuffer))
        }
        if let tail = chunker.flush() { enqueueSpeech([tail]) }
        if speechTask == nil, pendingSentences.isEmpty { await replyDone() }
    }

    // MARK: - Speech

    func enqueueSpeech(_ sentences: [String]) {
        guard !sentences.isEmpty else { return }
        pendingSentences.append(contentsOf: sentences)
        guard speechTask == nil else { return }
        let gen = turnGen
        speechTask = Task { await self.speechLoop(gen: gen) }
    }

    func speechLoop(gen: Int) async {
        while gen == turnGen, !Task.isCancelled, !pendingSentences.isEmpty {
            let sentence = pendingSentences.removeFirst()
            let request = await utteranceRequest(for: sentence)
            let events = await deps.synthesizer.speak(request)
            for await event in events { handleSynthesis(event, gen: gen) }
        }
        guard gen == turnGen, !Task.isCancelled else { return }
        speechTask = nil
        if turnFinished, pendingSentences.isEmpty { await replyDone() }
    }

    func utteranceRequest(for sentence: String) async -> SpeechUtteranceRequest {
        if voices == nil { voices = await deps.synthesizer.availableVoices() }
        let language = LocaleSelector.synthesisLanguage(for: sentence)
        let voice = VoiceSelector.select(from: voices ?? [], language: language, gender: settings.voiceGender, preferredId: settings.voiceId)
        return SpeechUtteranceRequest(
            text: sentence, language: language, voiceId: voice?.id,
            rate: SpeechStyle.rate(speakingRate: settings.speakingRate), pitch: SpeechStyle.pitch(settings.personality))
    }

    func handleSynthesis(_ event: SynthesisEvent, gen: Int) {
        guard gen == turnGen else { return }
        switch event {
        case .started:
            if phase != .speaking {
                latency.markFirstAudio(deps.clock.now())
                transition(.replyAudioStarted)
            }
            levelBroadcaster.yield(0.5)
        case .word:
            // System speech exposes no samples; word boundaries drive a gentle pulse.
            wordPulse.toggle()
            if phase == .speaking { levelBroadcaster.yield(wordPulse ? 0.8 : 0.45) }
        case .finished, .cancelled:
            if phase == .speaking { levelBroadcaster.yield(0.2) }
        }
    }

    /// The reply ended: record latency, settle, and keep listening in a continuing session.
    func replyDone() async {
        guard phase.isBusy else { return }
        if latency.hasUtterance {
            let sample = latency.complete(at: deps.clock.now(), engine: engine)
            latencies.append(sample)
            if latencies.count > config.maxRecordedLatencies { latencies.removeFirst(latencies.count - config.maxRecordedLatencies) }
            emit(.latency(sample))
        }
        latency.reset()
        currentTurnId = nil
        transition(.replyFinished)
        if phase == .listening {
            inFollowUp = true
            latency.markListening(deps.clock.now())
            if engine == .onDevice { await beginListening(withPreRoll: false) }
        } else {
            await releaseAudio()
        }
    }

    // MARK: - Barge-in and cancellation

    /// Stops speech at once, cancels the running turn on the server, and listens again.
    func bargeIn() async {
        guard phase.isBusy else { return }
        await cancelReplyWork(notifyBackend: true)
        if engine == .cloud { cloudAudioMuted = true }
        latency.reset()
        transition(.bargeIn)
        latency.markListening(deps.clock.now())
        latency.markSpeechStart(deps.clock.now())
        if engine == .onDevice { await beginListening(withPreRoll: true) }
    }

    func cancelReplyWork(notifyBackend: Bool) async {
        turnGen += 1
        turnTask?.cancel()
        turnTask = nil
        speechTask?.cancel()
        speechTask = nil
        pendingSentences.removeAll()
        chunker.reset()
        replyBuffer = ""
        bargeInSpeech = 0
        if let call = askCall {
            askCall = nil
            try? await deps.liveTransport.sendToolResponse(callId: call.id, name: call.name, response: ["error": .string("Cancelled by the owner.")])
        }
        await deps.synthesizer.stop()
        await deps.player.flush()
        if notifyBackend, let id = currentTurnId {
            currentTurnId = nil
            let backend = deps.backend
            Task { try? await backend.cancelTurn(id: id) }
        }
    }
}
