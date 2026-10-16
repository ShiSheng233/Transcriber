/// Recognizes lines made only of hesitation fillers ("えーと、あの…"), which
/// carry nothing to read. Short replies such as "うん" and "はい" are not
/// fillers: in ASMR and drama they answer someone.
public enum FillerLineFilter {
    /// Longest first, so "えーっと" is not read as "え" and leftovers.
    private static let fillers = [
        "えーっと", "えっと", "ええと", "えーと", "あのー", "あの", "うーん", "んー", "えー", "まあ", "その", "え", "ん",
        "那个", "嗯", "呃", "额",
    ].sorted { $0.count > $1.count }

    public static func isFillerOnly(_ text: String) -> Bool {
        var remaining = Substring(text.filter { $0.isLetter || $0 == "ー" })
        guard !remaining.isEmpty else {
            return false
        }
        while !remaining.isEmpty {
            guard let filler = fillers.first(where: { remaining.hasPrefix($0) }) else {
                return false
            }
            remaining = remaining.dropFirst(filler.count)
        }
        return true
    }
}
