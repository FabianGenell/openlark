import Foundation

enum WAVEncoder {
    static func encode(samples: [Int16], sampleRate: Int) -> Data {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample
        var data = Data(capacity: 44 + dataSize)

        func writeLE32(_ v: UInt32) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
        }
        func writeLE16(_ v: UInt16) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: "RIFF".utf8)
        writeLE32(UInt32(36 + dataSize))
        data.append(contentsOf: "WAVE".utf8)

        data.append(contentsOf: "fmt ".utf8)
        writeLE32(16) // PCM chunk size
        writeLE16(1)  // PCM format
        writeLE16(1)  // channels
        writeLE32(UInt32(sampleRate))
        writeLE32(UInt32(sampleRate * bytesPerSample)) // byte rate
        writeLE16(UInt16(bytesPerSample)) // block align
        writeLE16(16) // bits per sample

        data.append(contentsOf: "data".utf8)
        writeLE32(UInt32(dataSize))
        samples.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: dataSize) { raw in
                data.append(raw, count: dataSize)
            }
        }
        return data
    }
}
