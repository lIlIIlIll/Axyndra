package agent_product


// An explicit, deterministic transport-boundary fault used by controlled
// mechanism experiments. It changes the environment seen by ModelPort, never
// model-visible input or AgentCore recovery decisions.
public class ModelStreamFaultProfile {
    public let id: String
    public let triggerAttemptOrdinal: Int64
    public let maxInjectedAttempts: Int64
    public let partialText: String
    public let faultDelayMillis: Int64

    public init(
        id: String,
        triggerAttemptOrdinal!: Int64 = 1,
        maxInjectedAttempts!: Int64 = 1,
        partialText!: String = "controlled incomplete stream",
        faultDelayMillis!: Int64 = 50
    ) {
        if (id.trimAscii() == "" || triggerAttemptOrdinal < 1 ||
            maxInjectedAttempts < 1 || partialText == "" ||
            faultDelayMillis < 1) {
            throw IllegalArgumentException("model stream fault profile is invalid")
        }
        this.id = id.trimAscii()
        this.triggerAttemptOrdinal = triggerAttemptOrdinal
        this.maxInjectedAttempts = maxInjectedAttempts
        this.partialText = partialText
        this.faultDelayMillis = faultDelayMillis
    }
}

