package agent_product

import agent_domain.*
import agent_core.*
import agent_runtime.*
import sandbox4cj.*
import model_provider_runtime.*
import tool_runtime.*

// Authenticated operator frontend inputs, frozen before request preparation.
// These contain no workspace, store, owner, Source, or runtime replacement.
public class ProductOperatorOptions180 {
    public let approvalMode: ApprovalMode
    public let approvalRoutingModeOverride: ?ApprovalRoutingMode
    public let shellNetworkModeOverride: ?ShellNetworkMode
    public let wallTimeoutMillis: Int64
    public let modelAttemptRecovery: ModelAttemptRecoveryPolicy
    public let modelStreamFaultProfile: ?ModelStreamFaultProfile
    public let modelOverride: String
    public let modelFaultCounters180: ?ModelStreamFaultCounters180
    public init(approvalMode!: ApprovalMode = ApprovalMode.AlwaysAsk,
        approvalRoutingModeOverride!: ?ApprovalRoutingMode = None,
        shellNetworkModeOverride!: ?ShellNetworkMode = None,
        wallTimeoutMillis!: Int64 = 0,
        modelAttemptRecovery!: ModelAttemptRecoveryPolicy = ModelAttemptRecoveryPolicy(),
        modelStreamFaultProfile!: ?ModelStreamFaultProfile = None,
        modelOverride!: String = "",
        modelFaultCounters180!: ?ModelStreamFaultCounters180 = None<ModelStreamFaultCounters180>) {
        this.approvalMode = approvalMode
        this.approvalRoutingModeOverride = approvalRoutingModeOverride
        this.shellNetworkModeOverride = shellNetworkModeOverride
        this.wallTimeoutMillis = wallTimeoutMillis
        this.modelAttemptRecovery = modelAttemptRecovery
        this.modelStreamFaultProfile = modelStreamFaultProfile
        this.modelOverride = modelOverride
        this.modelFaultCounters180 = modelFaultCounters180
        if (wallTimeoutMillis < 0) { throw IllegalArgumentException("wall timeout must not be negative") }
    }
    func executionSettingsValue180(): AgentValue {
        let recovery = modelAttemptRecovery
        objectValue([ValueField("schema", textValue("axyndra.operator-request-settings/v1")),
            ValueField("shell_network_mode", match (shellNetworkModeOverride) { case Some(mode) => textValue(shellNetworkModeName(mode)); case None => nullValue() }),
            ValueField("approval_routing_mode", match (approvalRoutingModeOverride) {
                case Some(ApprovalRoutingMode.Manual) => textValue("manual")
                case Some(ApprovalRoutingMode.Ai) => textValue("ai")
                case Some(ApprovalRoutingMode.Trusted) => textValue("trusted")
                case Some(ApprovalRoutingMode.Never) => textValue("never")
                case None => nullValue() }),
            ValueField("model_attempt_recovery", objectValue([
                ValueField("mode", textValue(if (recovery.enabled()) { "recovery_v1" } else { "disabled" })),
                ValueField("attempt_timeout_ms", integerValue(recovery.attemptTimeoutMillis)),
                ValueField("max_recovery_retries", integerValue(recovery.maxRecoveryRetries)),
                ValueField("hard_timeout_ms", integerValue(recovery.hardTimeoutMillis)),
                ValueField("stream_idle_ms", integerValue(recovery.streamIdleMillis)),
                ValueField("recent_progress_ms", integerValue(recovery.recentProgressMillis))])),
            ValueField("model_stream_fault", match (modelStreamFaultProfile) { case None => nullValue(); case Some(profile) => objectValue([
                ValueField("id", textValue(profile.id)), ValueField("trigger_attempt_ordinal", integerValue(profile.triggerAttemptOrdinal)),
                ValueField("max_injected_attempts", integerValue(profile.maxInjectedAttempts)), ValueField("partial_text", textValue(profile.partialText)),
                ValueField("fault_delay_ms", integerValue(profile.faultDelayMillis))]) })])
    }
}
