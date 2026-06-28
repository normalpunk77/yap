import AVFoundation
import XCTest
@testable import YapApp

final class MicrophoneCaptureTests: XCTestCase {
    func testRmsLevelUsesBufferSamplesDirectly() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16_000,
                                   channels: 1,
                                   interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        buffer.frameLength = 4
        let samples: [Float] = [0, 0.05, -0.05, 0.1]
        samples.withUnsafeBufferPointer { ptr in
            buffer.floatChannelData![0].update(from: ptr.baseAddress!, count: samples.count)
        }

        let rms = MicrophoneCapture.rmsLevel(buffer)
        XCTAssertNotNil(rms)
        XCTAssertEqual(rms!, 0.48989795, accuracy: 0.0001)
    }
}
