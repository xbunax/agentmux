import Foundation

@main
struct MicroLayoutProbe {
    static func main() {
        precondition(MicroLayout.decode(MicroLayout.defaultValue) == MicroLayout.defaults)
        precondition(MicroLayout.decode("invalid JSON") == MicroLayout.defaults)
        precondition(MicroLayout.decode("[]").isEmpty, "Hiding every button must persist")
        precondition(MicroLayout.decode("[\"Enter\",\"unknown\",\"Enter\",\"Escape\"]") == [.enter, .escape])

        let customized: [MicroAction] = [.dictation, .interrupt, .pageUp, .enter]
        let suiteName = "AgentMux.MicroLayoutProbe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(MicroLayout.encode(customized), forKey: MicroLayout.storageKey)
        let reopened = UserDefaults(suiteName: suiteName)!
        precondition(MicroLayout.decode(reopened.string(forKey: MicroLayout.storageKey)!) == customized,
                     "Button selection and order must survive reopening preferences")
        precondition(MicroAction.dictation.key == nil, "Dictation is local and must not send a terminal key")
        print("Micro layout: defaults, invalid data, hidden buttons, ordering, and saved preferences passed")
    }
}
