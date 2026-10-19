package agent_domain

// An OS resource identity is not an execution grant. The ModelAttempt variant
// never denotes an Operation and cannot be reconstructed into Tool authority.
public enum ProcessResourceOwner {
    Operation(OperationId) | ModelAttempt(ModelAttemptId, String)

    public prop key: String { get() {
        match (this) {
            case Operation(id) => "operation:" + id.value.size.toString() + ":" + id.value
            case ModelAttempt(id, resource) => "model-attempt:" + id.value.size.toString() + ":" + id.value +
                ":" + resource.size.toString() + ":" + resource
        }
    } }
    public prop operation: ?OperationId { get() {
        match (this) { case Operation(id) => Some(id); case ModelAttempt(_, _) => None }
    } }
    public func requireOperation(): OperationId {
        match (this) { case Operation(id) => id
            case ModelAttempt(_, _) => throw IllegalStateException("model Attempt is not an Operation") }
    }
    public func validate(): Unit {
        match (this) {
            case Operation(_) => ()
            case ModelAttempt(_, resource) =>
                if (resource == "" || resource.size > 256 || resource.trimAscii() != resource ||
                    resource.contains("\u{0}") || resource.contains("\n") || resource.contains("\r")) {
                    throw IllegalArgumentException("model process resource identity is invalid")
                }
        }
    }
}
