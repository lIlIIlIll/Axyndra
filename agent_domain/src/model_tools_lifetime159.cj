package agent_domain

// DATA only: these contracts cannot mint Tool, Source or execution authority.
// Borrow before an input-consuming helper/callback/Future is constructed.
// Return only after that actual consumer's complete frames and aliases retire.
public interface ModelInputToolsLifetime159 {
    func borrowModelTools159(): ModelInputToolsBorrow159
}
public interface ModelInputToolsBorrow159 {
    func returnModelToolsFrame159(): Unit
}
