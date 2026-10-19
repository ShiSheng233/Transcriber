import Foundation
import TranscriberCore

/// The language a job's subtitles are written in, as a language code, so
/// the spell checker uses the right dictionary; nil when it is unknown and
/// the checker detects it.
enum SpellingLanguage {
    /// ChickenRice-style models: the translate task fine-tuned to write
    /// Chinese, which the language model step polishes as Chinese.
    private static let polishedLanguage = "zh"

    /// - Parameter targetLanguage: Settings › LLM's language for translations,
    ///   as the user wrote it.
    static func of(_ job: Job, targetLanguage: String) -> String? {
        let wentThroughLanguageModel = !job.linesBeforeLanguageModel.isEmpty
        switch job.kind {
        case .transcription(let model):
            return ofTranscript(
                task: model.decoding.task, languageCode: model.decoding.languageCode, llmMode: model.llmMode,
                translatedInto: wentThroughLanguageModel ? targetLanguage : nil
            )
        case .subtitleTranslation:
            return wentThroughLanguageModel ? code(forLanguageName: targetLanguage) : nil
        case .subtitleEditing:
            return nil
        }
    }

    /// What a speech model wrote, after its language model step if one ran.
    /// - Parameter translatedInto: the target language when the language model ran.
    static func ofTranscript(
        task: TranscriptionTask, languageCode: String, llmMode: RecognitionModel.LLMMode, translatedInto targetLanguage: String?
    ) -> String? {
        if llmMode == .translate, let targetLanguage {
            return code(forLanguageName: targetLanguage)
        }
        switch task {
        case .transcribe: return languageCode
        case .translate: return llmMode == .polish ? polishedLanguage : nil
        }
    }

    /// The code for a language written as a code ("en", "pt-BR") or as its
    /// name in English, Chinese, Japanese or itself ("简体中文", "Français").
    /// A name that contains a language's name counts as that language.
    static func code(forLanguageName name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isLanguageIdentifier(trimmed) {
            return trimmed.replacingOccurrences(of: "_", with: "-")
        }
        let lowercased = trimmed.lowercased()
        if let exact = namedLanguages.first(where: { $0.name == lowercased }) {
            return exact.code
        }
        return namedLanguages
            .filter { lowercased.contains($0.name) }
            .max { $0.name.count < $1.name.count }?
            .code
    }

    /// Two-letter codes: the languages people name in a setting.
    private static let languageCodes = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier).filter { $0.count == 2 })
    /// The locales whose names for languages are looked up, besides each language's own.
    private static let namingLocales = ["en", "zh-Hans", "zh-Hant", "ja"].map(Locale.init(identifier:))
    /// One-letter names would match inside any word.
    private static let shortestMatchedName = 2

    private static func isLanguageIdentifier(_ text: String) -> Bool {
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              let code = Locale.Language(identifier: text).languageCode?.identifier else {
            return false
        }
        let firstPart = text.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased()
        return languageCodes.contains(code) && firstPart == code
    }

    /// Every language's lowercased names, built once (a few milliseconds).
    private static let namedLanguages: [(name: String, code: String)] = languageCodes.sorted().flatMap { code in
        ([Locale(identifier: code)] + namingLocales)
            .compactMap { $0.localizedString(forLanguageCode: code)?.lowercased() }
            .filter { $0.count >= shortestMatchedName }
            .map { (name: $0, code: code) }
    }
}
