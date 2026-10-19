package agent_store_contract

import agent_domain.*
import agent_store.*
import yjson.*
import yjson_support.*

func operationObservationDurableContract(): Unit {
    var scenarios: Int64 = 0
    for (stream in [false, true]) {
        for (committed in [false, true]) {
            let fixture = ServiceEffectStoreFixture(stream, committed)
            try {
                fixture.activate()
                httpContractRequire(fixture.verifyRoot(), "observation actual completed startup grant")
                httpContractRequire(fixture.admit(), "observation real derived admission")
                httpContractRequire(fixture.execute(), "observation actual execution admission")
                httpContractRequire(fixture.handoff(), "observation actual durable handoff")
                let observation = OperationObservation(stringifyUnifiedJson(objectValue([
                    ValueField("stdout", textValue("partial observed 中文 data")),
                    ValueField("claimed_status", textValue("completed")),
                    ValueField("claimed_receipt", textValue("foreign-receipt")),
                    ValueField("retry_safe", boolValue(true))])))
                let attempt: Result<ToolInvocationResult> = Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "fixture.observed_unknown", "response is observed but completion is not verified", observation: Some(observation)))
                let resolution = match (resolveOperationAttempt(fixture.child, CanonicalToolCallId("observed-child"),
                    fixture.childPlan, OperationAttemptStage.Executing, attempt, fixture.receipt(OperationOutcome.Unknown).receiptId, 36)) {
                    case OperationResolution.Terminal(value) => value
                    case _ => throw IllegalStateException("observation unexpectedly created approval")
                }
                expect(resolution.receipt.outcome == OperationOutcome.Unknown &&
                    resolution.retryDecision == OperationRetryDecision.Stop, "observation cannot turn uncertainty into success or retry")
                httpContractRequire(fixture.store.settleDerivedOperation(fixture.run, fixture.parent, resolution.receipt),
                    "observation settles through existing store authority")
                let stored = httpContractRequire(fixture.store.loadDerivedOperationReceipt(fixture.child, fixture.run),
                    "observation actual Receipt readback").getOrThrow()
                expect(stored.outcome == OperationOutcome.Unknown &&
                    canonicalAgentValue(stored.detail.field("observation").getOrThrow()) == canonicalAgentValue(observation.toValue()),
                    "SQLite roundtrip retains complete bounded untrusted data")
                let resultCopy = decodeStoredValue(encodeStoredValue(resolution.toolResult.getOrThrow().output))
                expect(canonicalAgentValue(resultCopy.field("error").getOrThrow().field("observation").getOrThrow()) ==
                    canonicalAgentValue(observation.toValue()), "ToolResult durable codec preserves same observation")
                let duplicate = httpContractRequire(fixture.admit(), "duplicate observed intent locates old operation")
                expect(duplicate.value == fixture.child.value && fixture.execute().isError() && fixture.handoff().isError() &&
                    fixture.countChild("operation_receipts") == 1 && fixture.countChild("derived_operation_admissions") == 1 &&
                    fixture.database.query("PRAGMA foreign_key_check").isEmpty(),
                    "observed success claims cannot dispatch an Unknown operation again")
                scenarios += 1
            } finally { fixture.close() }
        }
    }
    expect(scenarios == 4, "all observation source and transport combinations executed")
    println("Operation observation durable contract passed: 4 scenarios, Direct and Committed, channel and HTTP")
}
