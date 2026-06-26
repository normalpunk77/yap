import XCTest
@testable import YapCore

final class ParakeetDownloadEventTests: XCTestCase {
    // Real lines captured from `parakeet download --progress json`.
    func testParsesFileProgress() {
        let line = #"{"downloaded":115365378,"file":"encoder-model.int8.onnx","index":0,"total":652183999,"type":"fileProgress"}"#
        let ev = ParakeetDownloadEvent.parse(line)
        XCTAssertEqual(ev?.type, "fileProgress")
        XCTAssertEqual(ev?.file, "encoder-model.int8.onnx")
        XCTAssertEqual(ev?.downloaded, 115365378)
        XCTAssertEqual(ev?.total, 652183999)
    }

    func testProgressFractionAndLabel() {
        let line = #"{"downloaded":750,"file":"encoder-model.int8.onnx","index":0,"total":1000,"totalFiles":4,"type":"fileProgress"}"#
        let prog = ParakeetDownloadProgress.from(ParakeetDownloadEvent.parse(line)!)!
        XCTAssertEqual(prog.fileFraction, 0.75, accuracy: 0.001)
        XCTAssertEqual(prog.fileIndex, 0)
        XCTAssertEqual(prog.totalFiles, 4)
        XCTAssertEqual(prog.label, "file 1 of 4 · 75%")
    }

    func testNonProgressEventsYieldNoSnapshot() {
        let start = #"{"modelDir":"/x","totalFiles":4,"type":"start","variant":"INT8 quantized"}"#
        let complete = #"{"modelDir":"/x","type":"complete"}"#
        XCTAssertNil(ParakeetDownloadProgress.from(ParakeetDownloadEvent.parse(start)!))
        XCTAssertNil(ParakeetDownloadProgress.from(ParakeetDownloadEvent.parse(complete)!))
    }

    func testIgnoresNonJsonLines() {
        XCTAssertNil(ParakeetDownloadEvent.parse(""))
        XCTAssertNil(ParakeetDownloadEvent.parse("Downloading…"))
    }
}
