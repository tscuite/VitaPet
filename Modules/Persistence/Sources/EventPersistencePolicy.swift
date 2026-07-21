public enum EventPersistenceStrategy: Sendable, Equatable {
    case transient
    case bufferedFileChange
    case immediate
}

public enum EventPersistencePolicy {
    public static func strategy(forSource source: String) -> EventPersistenceStrategy {
        switch source {
        case "hotkeyPressed":
            return .transient
        case "fileChanged":
            return .bufferedFileChange
        default:
            return .immediate
        }
    }
}
