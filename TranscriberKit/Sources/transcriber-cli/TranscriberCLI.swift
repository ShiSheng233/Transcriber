import ArgumentParser

@main
struct TranscriberCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcriber-cli",
        abstract: "Developer tool for the Transcriber pipeline.",
        subcommands: [RuntimeInfoCommand.self, InspectModelCommand.self, DecodeAudioCommand.self, DecodeWindowCommand.self]
    )
}
