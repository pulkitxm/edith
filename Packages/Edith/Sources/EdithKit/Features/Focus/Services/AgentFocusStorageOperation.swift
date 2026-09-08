public enum AgentFocusStorageOperation {
    public static let load = "focus.document.load"
    public static let save = "focus.document.save"
    public static let session = "focus.session.load"
    public static let saveSession = "focus.session.save"
    public static let history = "focus.history.load"
    public static let append = "focus.history.append"
    public static let internalOperations = [load, save, session, saveSession, history, append]
}
