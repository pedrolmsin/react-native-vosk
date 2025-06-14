import Foundation
import AVFoundation
import React

struct VoskResult: Codable {
    var partial: String?
    var text: String?
}

struct VoskStartOptions {
    var grammar: [String]?
    var timeout: Int?
}
extension VoskStartOptions: Codable {
    init(dictionary: [String: Any]) throws {
        self = try JSONDecoder().decode(VoskStartOptions.self, from: JSONSerialization.data(withJSONObject: dictionary))
    }
    private enum CodingKeys: String, CodingKey {
        case grammar, timeout
    }
}

@objc(Vosk)
class Vosk: RCTEventEmitter {
    var currentModel: VoskModel?
    var recognizer: OpaquePointer?
    let audioEngine = AVAudioEngine()
    var inputNode: AVAudioInputNode!
    var formatInput: AVAudioFormat!
    var processingQueue: DispatchQueue!
    var lastRecognizedResult: VoskResult?
    var timeoutTimer: Timer?
    var grammar: [String]?
    var hasListener: Bool = false
    var isCleaningUp: Bool = false

    override init() {
        super.init()
        processingQueue = DispatchQueue(label: "recognizerQueue")
        inputNode = audioEngine.inputNode
        formatInput = inputNode.inputFormat(forBus: 0)
    }

    deinit {
        if recognizer != nil {
            vosk_recognizer_free(recognizer)
        }
    }

    override func startObserving() {
        hasListener = true
    }

    override func stopObserving() {
        hasListener = false
    }

    @objc override func supportedEvents() -> [String]! {
        return ["onError", "onResult", "onFinalResult", "onPartialResult", "onTimeout"]
    }

    @objc(loadModel:withResolver:withRejecter:)
    func loadModel(name: String, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) -> Void {
        if currentModel != nil {
            currentModel = nil
        }

        do {
            try currentModel = VoskModel(name: name)
            resolve(true)
        } catch {
            reject("load_model", "Failed to load model", error)
        }
    }

    @objc(start:withResolver:withRejecter:)
    func start(rawOptions: [String: Any]?, resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) -> Void {
        guard let model = currentModel else {
            reject("start", "No model loaded", nil)
            return
        }

        let audioSession = AVAudioSession.sharedInstance()
        var options: VoskStartOptions? = nil
        do {
            if let rawOptions = rawOptions {
                options = try VoskStartOptions(dictionary: rawOptions)
            }
        } catch {
            print("Failed to parse options: \(error)")
        }

        let grammar = options?.grammar
        let timeout = options?.timeout

        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try audioSession.setActive(true)

            formatInput = inputNode.inputFormat(forBus: 0)
            let sampleRate = formatInput.sampleRate.isFinite && formatInput.sampleRate > 0 ? formatInput.sampleRate : 16000
            let channelCount = formatInput.channelCount > 0 ? formatInput.channelCount : 1

            guard let formatPcm = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                sampleRate: sampleRate,
                                                channels: UInt32(channelCount),
                                                interleaved: true) else {
                reject("start", "Unable to create audio format", nil)
                return
            }

            if let grammar = grammar, !grammar.isEmpty {
                let jsonGrammar = try JSONEncoder().encode(grammar)
                recognizer = vosk_recognizer_new_grm(model.model, Float(sampleRate), String(data: jsonGrammar, encoding: .utf8))
            } else {
                recognizer = vosk_recognizer_new(model.model, Float(sampleRate))
            }

            inputNode.installTap(onBus: 0, bufferSize: UInt32(sampleRate / 10), format: formatPcm) { buffer, _ in
                guard !self.isCleaningUp else {
                    print("Tap received audio while cleaning up.")
                    return
                }

                self.processingQueue.async {
                    let res = self.recognizeData(buffer: buffer)
                    DispatchQueue.main.async {
                        guard let result = res.result else { return }

                        do {
                            let parsedResult = try JSONDecoder().decode(VoskResult.self, from: result.data(using: .utf8)!)
                            if res.completed && self.hasListener, let text = parsedResult.text, !text.isEmpty {
                                self.sendEvent(withName: "onResult", body: text)
                            } else if !res.completed && self.hasListener, let partial = parsedResult.partial, !partial.isEmpty {
                                if self.lastRecognizedResult?.partial != partial {
                                    self.sendEvent(withName: "onPartialResult", body: partial)
                                }
                            }
                            self.lastRecognizedResult = parsedResult
                        } catch {
                            print("Failed to decode result: \(error)")
                        }
                    }
                }
            }

            audioEngine.prepare()

            audioSession.requestRecordPermission { [weak self] success in
                guard success, let self = self else { return }
                try? self.audioEngine.start()
            }

            if let timeout = timeout {
                DispatchQueue.main.async {
                    self.timeoutTimer = Timer.scheduledTimer(withTimeInterval: Double(timeout) / 1000, repeats: false) { _ in
                        self.processingQueue.async {
                            self.stopInternal(withoutEvents: true)
                            self.sendEvent(withName: "onTimeout", body: "")
                        }
                    }
                }
            }

            resolve("Recognizer successfully started")
        } catch {
            if hasListener {
                sendEvent(withName: "onError", body: "Unable to start AVAudioEngine: \(error.localizedDescription)")
            }
            if recognizer != nil {
                vosk_recognizer_free(recognizer)
                recognizer = nil
            }
            reject("start", error.localizedDescription, error)
        }
    }

    @objc(unload)
    func unload() {
        isCleaningUp = true
        stopInternal(withoutEvents: false)
        isCleaningUp = false
        currentModel = nil
    }

    @objc(stop)
    func stop() {
        isCleaningUp = true
        stopInternal(withoutEvents: false)
        isCleaningUp = false
    }

    func stopInternal(withoutEvents: Bool) {
        inputNode.removeTap(onBus: 0)

        if audioEngine.isRunning {
            audioEngine.stop()
            if hasListener && !withoutEvents {
                if let partial = lastRecognizedResult?.partial, !partial.isEmpty {
                    sendEvent(withName: "onFinalResult", body: partial)
                }
            }
        }

        lastRecognizedResult = nil

        timeoutTimer?.invalidate()
        timeoutTimer = nil

        // Delay to ensure that the tap has been removed before releasing the recognizer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if self.recognizer != nil {
                vosk_recognizer_free(self.recognizer)
                self.recognizer = nil
            }
        }

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setActive(false)
        } catch {
            print("Error restoring AVAudioSession: \(error)")
        }
    }

    func recognizeData(buffer: AVAudioPCMBuffer) -> (result: String?, completed: Bool) {
        if isCleaningUp {
            print("Skipping recognition because isCleaningUp is true.")
            return (nil, false)
        }

        guard let recognizer = self.recognizer else {
            print("Recognizer is nil")
            return (nil, false)
        }

        guard let channelData = buffer.int16ChannelData else {
            print("int16ChannelData is nil")
            return (nil, false)
        }

        let dataLen = Int(buffer.frameLength * 2)
        let channels = UnsafeBufferPointer(start: channelData, count: 1)

        let endOfSpeech = channels[0].withMemoryRebound(to: Int8.self, capacity: dataLen) {
            vosk_recognizer_accept_waveform(recognizer, $0, Int32(dataLen))
        }

        guard let cStringResult = endOfSpeech == 1
                ? vosk_recognizer_result(recognizer)
                : vosk_recognizer_partial_result(recognizer),
              let stringResult = String(validatingUTF8: cStringResult) else {
            print("Failed to convert result to String")
            return (nil, false)
        }

        return (stringResult, endOfSpeech == 1)
    }
}
