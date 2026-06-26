import Foundation

public enum PCM16 {
    public static func fromFloat(_ samples: [Float]) -> Data {
        // Hot path: runs ~16k times/sec while recording. Write the whole buffer in one
        // pass into preallocated storage instead of a per-sample closure + append.
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for i in samples.indices {
                let clamped = max(-1.0, min(1.0, samples[i]))
                let scaled = clamped < 0 ? clamped * 32768.0 : clamped * 32767.0
                out[i] = Int16(scaled.rounded()).littleEndian
            }
        }
        return data
    }
}
