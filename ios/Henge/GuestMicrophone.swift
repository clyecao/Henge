import AVFoundation
import SwiftUI

/// Shares audio only while this session is in front and macOS has started its input stream.
@MainActor
final class GuestMicrophone: ObservableObject {
    @Published var enabled = false {
        didSet {
            if enabled && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                    DispatchQueue.main.async { self?.checkPermission() }
                }
            }
            checkPermission()
        }
    }
    @Published private(set) var status = "Off"

    private var foreground = false
    private var allowed = false
    private var interrupted = false
    private var engine: AVAudioEngine?
    private var generation: UInt64 = 0
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
            self.interrupted = AVAudioSession.InterruptionType(rawValue: raw) == .began
            if self.interrupted { self.stopCapture() } else { self.recoverOutput() }
            self.checkPermission()
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            // Switching into or out of recording can invalidate the player too.
            if reason == .categoryChange {
                if self.foreground && !self.interrupted { henge_vm_audio_kick() }
                return
            }
            self.stopCapture()
            if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable || reason == .override {
                self.recoverOutput()
            }
            self.checkPermission()
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.interrupted = false
            self?.stopCapture()
            self?.recoverOutput()
            self?.checkPermission()
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func checkPermission() {
        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        allowed = enabled && permission == .authorized
        if !allowed { stopCapture() }
        if !enabled { status = "Off" }
        else if permission == .notDetermined { status = "Waiting for permission" }
        else if !allowed { status = "Allow microphone access for Henge in Settings." }
        else if interrupted { status = "Interrupted" }
        else { status = engine == nil ? "Ready" : "In use by Mac" }
    }

    func setForeground(_ active: Bool) {
        guard foreground != active else { return }
        foreground = active
        if active { recoverOutput() } else { stopCapture() }
        checkPermission()
    }

    private func recoverOutput() {
        guard foreground && !interrupted else { return }
        // Capture owns the play-and-record category. Reactivating output must preserve it.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(true)
            let ports = session.currentRoute.outputs.map(\.portName).joined(separator: ", ")
            HengeLog.log("audio", "output active: \(ports), \(Int(session.sampleRate)) Hz")
        } catch {
            HengeLog.log("audio", "output activation failed: \(error.localizedDescription)")
        }
        henge_vm_audio_kick()
    }

    func followGuest() async {
        while !Task.isCancelled && enabled {
            if foreground && allowed && !interrupted {
                let current = henge_vm_generation()
                if engine != nil && current != generation { stopCapture() }
                if henge_vm_microphone_requested() != 0 {
                    if engine == nil { startCapture(for: current) }
                } else if engine != nil {
                    stopCapture()
                    status = "Ready"
                }
            }
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
        }
    }

    private func startCapture(for generation: UInt64) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try? session.setPreferredSampleRate(48_000)
            try? session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
            let engine = AVAudioEngine()
            try Self.installTap(on: engine.inputNode, generation: generation)
            engine.prepare()
            do { try engine.start() } catch {
                engine.inputNode.removeTap(onBus: 0)
                throw error
            }
            self.engine = engine
            self.generation = generation
            henge_vm_microphone_enable(1)
            status = "In use by Mac"
            HengeLog.log("audio", "microphone capture started")
        } catch {
            try? session.setCategory(.playback, options: [.mixWithOthers])
            allowed = false // Retry when the user changes the switch or the audio route.
            status = error.localizedDescription
            HengeLog.log("audio", "microphone unavailable: \(error.localizedDescription)")
        }
    }

    private func stopCapture() {
        guard let engine else { return }
        henge_vm_microphone_enable(0)
        self.engine = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
    }

    /// The tap runs on Core Audio's thread. Reuse the converter and its output buffer across callbacks.
    private nonisolated static func installTap(on input: AVAudioInputNode, generation: UInt64) throws {
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.channelCount > 0, hardware.sampleRate > 0 else {
            throw NSError(domain: "HengeAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone is available on this audio route."])
        }
        if hardware.sampleRate == 48_000 && hardware.channelCount == 1 && hardware.commonFormat == .pcmFormatFloat32 {
            input.installTap(onBus: 0, bufferSize: 512, format: hardware) { buffer, _ in
                if let samples = buffer.floatChannelData?[0] { henge_vm_microphone(generation, samples, buffer.frameLength) }
            }
            return
        }
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: hardware, to: mono) else {
            throw NSError(domain: "HengeAudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "This microphone's audio format could not be converted."])
        }
        var output: AVAudioPCMBuffer?
        input.installTap(onBus: 0, bufferSize: 512, format: hardware) { buffer, _ in
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 48_000 / hardware.sampleRate)) + 32
            if capacity > (output?.frameCapacity ?? 0) { output = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: capacity) }
            guard let output else { return }
            output.frameLength = 0
            var supplied = false
            let result = converter.convert(to: output, error: nil) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            if result != .error, let samples = output.floatChannelData?[0] {
                henge_vm_microphone(generation, samples, output.frameLength)
            }
        }
    }
}
