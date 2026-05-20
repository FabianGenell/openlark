@preconcurrency import AVFoundation
import CoreMedia
import Foundation

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

    private var loggedFormat = false
    private var sourceSampleRate: Double = 0
    private var levelLinear: Float = 0
    var currentLevel: Float { levelLinear }

    func start() throws {
        teardown()
        samples.removeAll(keepingCapacity: true)
        levelLinear = 0
        loggedFormat = false

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

        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw RecorderError.noDevice
        }
        AppLogger.log("using default audio device: \(device.localizedName) uid=\(device.uniqueID)")

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
        session.stopRunning()
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
            AppLogger.log("⚠ near-silent capture (peak \(String(format: "%.1f", peakDb)) dBFS) — try the built-in mic in System Settings → Sound → Input, or reconnect your Bluetooth headset")
        }

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
        levelLinear = 0
    }

    private func teardown() {
        guard let session else { return }
        if session.isRunning { session.stopRunning() }
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        self.session = nil
        self.sourceSampleRate = 0
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

        if !loggedFormat {
            loggedFormat = true
            sourceSampleRate = sampleRate
            AppLogger.log("incoming asbd: sr=\(sampleRate) ch=\(channels) bits=\(bits) float=\(isFloat) signedInt=\(isSignedInt) interleaved=\(interleaved) bytesPerFrame=\(asbd.mBytesPerFrame)")
        } else if sampleRate != sourceSampleRate {
            // Format renegotiated mid-stream — record the new rate; resample at stop time.
            AppLogger.log("⚠ format changed mid-stream: sr \(sourceSampleRate) → \(sampleRate)")
            sourceSampleRate = sampleRate
        }

        // Extract the raw data block.
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let totalBytes = CMBlockBufferGetDataLength(blockBuffer)
        guard totalBytes > 0 else { return }
        var dataPointer: UnsafeMutablePointer<CChar>?
        var lengthAtOffset = 0
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: nil,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer else { return }

        // Walk the block as the source format and emit Int16 mono samples.
        let frameCount = totalBytes / Int(asbd.mBytesPerFrame)
        var newSamples = [Int16]()
        newSamples.reserveCapacity(frameCount)

        if isFloat && bits == 32 {
            let floats = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float32.self)
            for frame in 0..<frameCount {
                // For multi-channel input, take channel 0 (or average — let's downmix).
                var acc: Float = 0
                for c in 0..<channels {
                    acc += floats[frame * channels + c]
                }
                let v = acc / Float(channels)
                let clipped = max(-1.0, min(1.0, v))
                newSamples.append(Int16(clipped * 32767.0))
            }
        } else if isSignedInt && bits == 16 {
            let int16s = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Int16.self)
            for frame in 0..<frameCount {
                if channels == 1 {
                    newSamples.append(int16s[frame])
                } else {
                    var acc: Int32 = 0
                    for c in 0..<channels {
                        acc += Int32(int16s[frame * channels + c])
                    }
                    newSamples.append(Int16(acc / Int32(channels)))
                }
            }
        } else if isSignedInt && bits == 32 {
            let int32s = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Int32.self)
            for frame in 0..<frameCount {
                var acc: Int64 = 0
                for c in 0..<channels {
                    acc += Int64(int32s[frame * channels + c]) >> 16
                }
                newSamples.append(Int16(acc / Int64(channels)))
            }
        } else {
            // First time we hit an unknown format, log and bail; samples stay 0.
            AppLogger.log("unsupported sample format — float=\(isFloat) signedInt=\(isSignedInt) bits=\(bits)")
            return
        }

        guard !newSamples.isEmpty else { return }

        // Update level meter.
        var rmsAcc: Float = 0
        for v in newSamples {
            let f = Float(v) / 32768.0
            rmsAcc += f * f
        }
        let rms = sqrt(rmsAcc / Float(newSamples.count))
        levelLinear = max(rms, levelLinear * 0.85)

        samplesQueue.sync {
            samples.append(contentsOf: newSamples)
        }
    }
}
