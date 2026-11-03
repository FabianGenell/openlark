@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import os

/// Records mic input via AVCaptureSession.
///
/// We bypass AVAudioConverter and read raw bytes out of the CMSampleBuffer's
/// CMBlockBuffer directly, converting them to Int16 at 16 kHz in-place. This
/// avoids the AVAudioConverter pointer-aliasing trap where the converter is
/// handed an AVAudioPCMBuffer whose mData has been overwritten with the
/// CMBlockBuffer's pointer and silently emits zero-frame output.
final class AudioRecorder: NSObject {
    enum RecorderError: Error {
        case permissionDenied
        case noDevice
        case configureFailed
        case unsupportedFormat
    }

    private var session: AVCaptureSession?
    private var samples: [Int16] = []
    private let samplesQueue = DispatchQueue(label: "openlark.recorder.samples")
    private let captureQueue = DispatchQueue(label: "openlark.recorder.capture", qos: .userInteractive)

    /// Written on captureQueue, read on main. Kept behind one lock so the
    /// level meter and the stop-time resample never see a torn value.
    private struct CaptureState {
        var loggedFormat = false
        var sourceSampleRate: Double = 0
        var levelLinear: Float = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: CaptureState())
    var currentLevel: Float { state.withLock { $0.levelLinear } }

    func start() throws {
        teardown()
        samples.removeAll(keepingCapacity: true)
        state.withLock { $0 = CaptureState() }

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        AppLogger.log("mic authorizationStatus: \(micStatus.rawValue) (0=notDetermined 1=restricted 2=denied 3=authorized)")
        if micStatus == .denied || micStatus == .restricted {
            throw RecorderError.permissionDenied
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        for d in discovery.devices {
            AppLogger.log("available audio device: '\(d.localizedName)' uid=\(d.uniqueID) type=\(d.deviceType.rawValue)")
        }

        let device: AVCaptureDevice
        if let preferredID = AudioInputs.selectedDeviceID,
           let preferred = AVCaptureDevice(uniqueID: preferredID) {
            device = preferred
            AppLogger.log("using user-selected audio device: \(device.localizedName) uid=\(device.uniqueID)")
        } else if let fallback = AVCaptureDevice.default(for: .audio) {
            device = fallback
            AppLogger.log("using default audio device: \(device.localizedName) uid=\(device.uniqueID)")
        } else {
            throw RecorderError.noDevice
        }

        let session = AVCaptureSession()
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            AppLogger.log("AVCaptureDeviceInput failed: \(error)")
            throw RecorderError.configureFailed
        }
        guard session.canAddInput(input) else { throw RecorderError.configureFailed }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else { throw RecorderError.configureFailed }
        session.addOutput(output)

        self.session = session
        captureQueue.async {
            session.startRunning()
            AppLogger.log("capture session startRunning: isRunning=\(session.isRunning)")
        }
    }

    func stopAndExportWAV() -> Data? {
        defer { teardown() }
        guard let session else { return nil }
        AppLogger.log("recorder.stop: session.isRunning=\(session.isRunning)")
        stopSessionRunning(session)
        let buffer: [Int16] = samplesQueue.sync { samples }
        AppLogger.log("recorder.stop: \(buffer.count) samples (\(Double(buffer.count) / 16000.0)s)")
        if buffer.isEmpty { return nil }

        var peak: UInt16 = 0
        var sumSq: Double = 0
        var nonZero = 0
        for s in buffer {
            let a = UInt16(s == Int16.min ? 32768 : UInt16(abs(Int32(s))))
            if a > peak { peak = a }
            let f = Double(s) / 32768.0
            sumSq += f * f
            if s != 0 { nonZero += 1 }
        }
        let rms = sqrt(sumSq / Double(buffer.count))
        let peakDb = peak == 0 ? -.infinity : 20.0 * log10(Double(peak) / 32768.0)
        let rmsDb = rms <= 0 ? -.infinity : 20.0 * log10(rms)
        let nonZeroPct = Double(nonZero) / Double(buffer.count) * 100
        AppLogger.log(String(format: "audio stats: peak=%d (%.1f dBFS) rms=%.4f (%.1f dBFS) nonZero=%.1f%%",
                             peak, peakDb, rms, rmsDb, nonZeroPct))
        // Flag silent capture loudly. Real speech is normally peak > -25 dBFS.
        // Anything quieter usually means another app left the BT headset's HFP
        // route in a half-broken state, or the user spoke too softly.
        if peakDb < -45 {
            AppLogger.log("⚠ near-silent capture (peak \(String(format: "%.1f", peakDb)) dBFS), try the built-in mic in System Settings → Sound → Input, or reconnect your Bluetooth headset")
        }

        let sourceSampleRate = state.withLock { $0.sourceSampleRate }
        let outSamples: [Int16]
        if abs(sourceSampleRate - 16_000) < 1 || sourceSampleRate == 0 {
            outSamples = buffer
        } else {
            outSamples = resampleLinear(buffer, from: sourceSampleRate, to: 16_000)
            AppLogger.log("resampled \(buffer.count) → \(outSamples.count) samples")
        }
        let wav = WAVEncoder.encode(samples: outSamples, sampleRate: 16_000)
        #if DEBUG
        try? wav.write(to: URL(fileURLWithPath: "/tmp/openlark-last.wav"))
        AppLogger.log("debug WAV written to /tmp/openlark-last.wav (\(wav.count) bytes)")
        #endif
        return wav
    }

    func cancel() {
        teardown()
        samplesQueue.sync { samples.removeAll(keepingCapacity: false) }
        state.withLock { $0.levelLinear = 0 }
    }

    private func teardown() {
        guard let session else { return }
        stopSessionRunning(session)
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        self.session = nil
        state.withLock { $0.sourceSampleRate = 0 }
    }

    /// Stop the session off the main thread with a bounded wait. `stopRunning()`
    /// blocks until the session halts; a wedged/removed audio device can make
    /// that take a long time, which - called directly on the main thread -
    /// froze the whole app on stop. We run it on a background thread and wait at
    /// most 3s. In the normal case it returns in milliseconds (so captured
    /// samples are fully flushed before we read them); in the pathological case
    /// the UI is freed and we proceed with whatever was captured.
    private func stopSessionRunning(_ session: AVCaptureSession) {
        guard session.isRunning else { return }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            session.stopRunning()
            done.signal()
        }
        if done.wait(timeout: .now() + 3) == .timedOut {
            AppLogger.log("⚠ session.stopRunning() exceeded 3s - wedged audio device; continuing")
        }
    }

    private func resampleLinear(_ input: [Int16], from src: Double, to dst: Double) -> [Int16] {
        guard !input.isEmpty else { return [] }
        let ratio = dst / src
        let outCount = Int(Double(input.count) * ratio)
        guard outCount > 0 else { return [] }
        var out = [Int16](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let srcPos = Double(i) / ratio
            let i0 = Int(srcPos)
            let frac = srcPos - Double(i0)
            let s0 = Double(input[min(i0, input.count - 1)])
            let s1 = Double(input[min(i0 + 1, input.count - 1)])
            out[i] = Int16(max(-32768.0, min(32767.0, s0 + (s1 - s0) * frac)))
        }
        return out
    }
}

extension AudioRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        else { return }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let interleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let bits = Int(asbd.mBitsPerChannel)
        let channels = Int(asbd.mChannelsPerFrame)
        let sampleRate = asbd.mSampleRate

        let (firstBuffer, previousRate) = state.withLock { s -> (Bool, Double) in
            let first = !s.loggedFormat
            let prev = s.sourceSampleRate
            s.loggedFormat = true
            s.sourceSampleRate = sampleRate
            return (first, prev)
        }
        if firstBuffer {
            AppLogger.log("incoming asbd: sr=\(sampleRate) ch=\(channels) bits=\(bits) float=\(isFloat) signedInt=\(isSignedInt) interleaved=\(interleaved) bytesPerFrame=\(asbd.mBytesPerFrame)")
        } else if sampleRate != previousRate {
            // Format renegotiated mid-stream; the new rate is already stored
            // and the resample at stop time uses it.
            AppLogger.log("⚠ format changed mid-stream: sr \(previousRate) → \(sampleRate)")
        }

        guard let newSamples = Self.monoInt16(from: sampleBuffer, asbd: asbd) else { return }

        guard !newSamples.isEmpty else { return }

        // Update level meter.
        var rmsAcc: Float = 0
        for v in newSamples {
            let f = Float(v) / 32768.0
            rmsAcc += f * f
        }
        let rms = sqrt(rmsAcc / Float(newSamples.count))
        state.withLock { $0.levelLinear = max(rms, $0.levelLinear * 0.85) }

        samplesQueue.sync {
            samples.append(contentsOf: newSamples)
        }
    }
}

extension AudioRecorder {
    /// Downmix one capture buffer to mono Int16 at the source rate.
    ///
    /// Goes through the AudioBufferList rather than the raw block pointer, so
    /// both layouts come out right: interleaved audio is one buffer holding
    /// every channel, non-interleaved (planar) audio is one buffer per channel.
    /// Each buffer's own mDataByteSize bounds the reads, so nothing walks past
    /// the memory CoreMedia handed over.
    static func monoInt16(from sampleBuffer: CMSampleBuffer, asbd: AudioStreamBasicDescription) -> [Int16]? {
        var sizeNeeded = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard status == noErr, sizeNeeded > 0 else {
            AppLogger.log("⚠ dropping sample buffer: buffer list size query failed (\(status))")
            return nil
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: sizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let listPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBlock: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPtr,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retainedBlock
        )
        guard status == noErr else {
            AppLogger.log("⚠ dropping sample buffer: buffer list fetch failed (\(status))")
            return nil
        }
        // retainedBlock keeps the memory the buffer list points at alive until
        // this function returns.
        return withExtendedLifetime(retainedBlock) {
            downmix(UnsafeMutableAudioBufferListPointer(listPtr), asbd: asbd)
        }
    }

    /// Pure conversion from an AudioBufferList in `asbd`'s sample format to
    /// mono Int16. Separate from the CoreMedia plumbing so it can be exercised
    /// with synthetic planar and interleaved buffers.
    static func downmix(_ buffers: UnsafeMutableAudioBufferListPointer, asbd: AudioStreamBasicDescription) -> [Int16]? {
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let bits = Int(asbd.mBitsPerChannel)
        let bytesPerSample: Int
        switch (isFloat, isSignedInt, bits) {
        case (true, _, 32), (false, true, 32): bytesPerSample = 4
        case (false, true, 16): bytesPerSample = 2
        default:
            AppLogger.log("unsupported sample format: float=\(isFloat) signedInt=\(isSignedInt) bits=\(bits)")
            return nil
        }

        // Each buffer carries mNumberChannels interleaved channels (1 for a
        // planar plane). Frames = the shortest buffer, so a short plane can
        // never be over-read.
        var planes: [(data: UnsafeRawPointer, channels: Int)] = []
        var frameCount = Int.max
        for buf in buffers {
            let ch = Int(buf.mNumberChannels)
            guard ch > 0, let data = buf.mData else { continue }
            planes.append((UnsafeRawPointer(data), ch))
            frameCount = min(frameCount, Int(buf.mDataByteSize) / (bytesPerSample * ch))
        }
        let totalChannels = planes.reduce(0) { $0 + $1.channels }
        guard totalChannels > 0, frameCount != Int.max, frameCount > 0 else { return nil }

        func sample(_ plane: UnsafeRawPointer, _ index: Int) -> Float {
            if isFloat {
                return plane.load(fromByteOffset: index * 4, as: Float32.self)
            } else if bits == 16 {
                return Float(plane.load(fromByteOffset: index * 2, as: Int16.self)) / 32768.0
            } else {
                return Float(plane.load(fromByteOffset: index * 4, as: Int32.self)) / 2147483648.0
            }
        }

        var out = [Int16]()
        out.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            var acc: Float = 0
            for plane in planes {
                for c in 0..<plane.channels {
                    acc += sample(plane.data, frame * plane.channels + c)
                }
            }
            let v = max(-1.0, min(1.0, acc / Float(totalChannels)))
            out.append(Int16(v * 32767.0))
        }
        return out
    }
}
