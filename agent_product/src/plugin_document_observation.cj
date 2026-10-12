package agent_product

import yjson.*
import yjson_support.*

import agent_domain.*
import agent_runtime.*
import agent_store.*
import persistence_runtime.*

// The existing accounting implementation is reused, including snapshot decode
// errors. Missing data is not replaced by a successful zero-usage observation.
class ProductDocumentReadObserver <: PluginDocumentReadObserver {
    private let runs: SqliteRunRepository
    init(runs: SqliteRunRepository) { this.runs = runs }
    public func observe(value: PluginDocumentReadProof): Result<AgentValue> {
        let proof = match (value as SqlitePluginDocumentReadProof) {
            case Some(actual) => actual
            case None => return pluginProcessError("plugin.document_observation_source", "actual Store read proof required") }
        let plan = proof.plan()
        let binding = plan.canonicalArguments.field("binding") ?? nullValue()
        if (!pluginDocumentReadAuthority(plan) || httpIntentText(binding, "thread_id") != proof.threadId.value ||
            httpIntentText(binding, "run_id") != proof.runId.value || httpIntentText(binding, "lane_id") != proof.laneId.value) {
            return pluginProcessError("plugin.document_observation_source", "observation does not match the canonical read") }
        proof.withTransaction({ transaction =>
            let stats = match (runs.statsInTransaction(transaction, SessionId(proof.threadId.value))) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            let value = objectValue([ValueField("schema", textValue("axyndra.document-observation/v1")),
                ValueField("thread_id", textValue(proof.threadId.value)), ValueField("run_id", textValue(proof.runId.value)),
                ValueField("observed_at_millis", integerValue(agentUtcMillis())),
                ValueField("input_tokens", integerValue(stats.inputTokens)), ValueField("output_tokens", integerValue(stats.outputTokens))])
            if (!pluginDocumentObservationValid(value, plan.canonicalArguments)) {
                return pluginProcessError("plugin.document_observation_invalid", "canonical usage is outside the representable range") }
            Result.Ok(value)
        })
    }
}
