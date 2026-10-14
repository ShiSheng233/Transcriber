import ArgumentParser
import WhisperCpp

struct RuntimeInfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runtime-info",
        abstract: "Print the linked whisper.cpp version and enabled backends."
    )

    func run() {
        print("whisper.cpp \(WhisperRuntime.version)")
        print(WhisperRuntime.systemInfo)
    }
}
