import Foundation
import Testing
@testable import WhisperCpp

struct CoreMLEncoderURLTests {
    private let directory = URL(fileURLWithPath: "/models/whisper")

    @Test func replacesExtensionWithEncoderSuffix() {
        let model = directory.appendingPathComponent("chickenrice-v0.2-f16.bin")
        #expect(WhisperModel.coreMLEncoderURL(forModelAt: model).lastPathComponent
            == "chickenrice-v0.2-f16-encoder.mlmodelc")
    }

    @Test func sharesOneEncoderAcrossQuantizations() {
        let model = directory.appendingPathComponent("chickenrice-v0.2-q8_0.bin")
        #expect(WhisperModel.coreMLEncoderURL(forModelAt: model).lastPathComponent
            == "chickenrice-v0.2-encoder.mlmodelc")
    }

    @Test func keepsTheModelDirectory() {
        let model = directory.appendingPathComponent("ja-1.5b-q5_0.bin")
        #expect(WhisperModel.coreMLEncoderURL(forModelAt: model).deletingLastPathComponent().path == directory.path)
    }
}
