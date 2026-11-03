package agent_store_contract

import agent_domain.*
import agent_runtime.*
import agent_store.*
import yjson.*
import yjson_support.*

func contextReadParentPlan(links: Array<ContextReadFactLink>): NormalizedOperationPlan {
    NormalizedOperationPlan("plugin.context.pending", objectValue([ValueField("prepared_content", textValue("observed data"))]),
        [Capability(CapabilityKind.WorkspaceWrite)], OperationEffectClass.WorkspaceMutation,
        OperationRetryDisposition.Never, "parent-plan-with-observed-data", contextReadFacts: links)
}

func contextReadFactConsumptionStoreContract(): Unit {
    var count: Int64 = 0
    for (mode in ["committed", "direct-parent"]) {
        for (scenario in ["complete", "forged-reference", "wrong-parent", "different-run", "immutable-links",
            "audit-before-prepare", "audit-before-execute", "audit-before-handoff", "result-before-execute",
            "projection-before-handoff", "epoch-before-execute", "cancel-before-handoff"]) {
            let fixture = ContextReadStoreFixture(mode: mode)
            try {
                let fact = fixture.completeRead()
                let original = fact.link()
                let link = if (scenario == "forged-reference" || scenario == "different-run" || scenario == "wrong-parent") {
                    let origin = original.origin
                    let replaced = if (scenario == "wrong-parent") {
                        ContextReadOrigin(origin.ownerNamespace, origin.packageDigest, origin.configurationDigest,
                            origin.projectionDigest, origin.readPlanDigest, origin.requestId, "another-parent",
                            parentDecisionId: origin.parentDecisionId, parentScopedCallId: origin.parentScopedCallId,
                            parentKind: origin.parentKind, parentOperationId: origin.parentOperationId)
                    } else { origin }
                    ContextReadFactLink(original.operationId,
                        if (scenario == "different-run") { RunId("another-run") } else { original.runId },
                        original.sourceItemId, original.resultItemId, original.receiptId, replaced,
                        if (scenario == "forged-reference") { "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" }
                        else { original.outputDigest }, original.outputBytes)
                } else { original }
                let inputLinks = [link]
                let plan = contextReadParentPlan(inputLinks)
                if (scenario == "immutable-links") {
                    let forged = ContextReadFactLink(original.operationId, original.runId, original.sourceItemId,
                        original.resultItemId, original.receiptId, original.origin,
                        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", original.outputBytes)
                    inputLinks[0] = forged
                    let exposed = plan.contextReadFacts; exposed[0] = forged
                    expect(plan.contextReadFacts[0].outputDigest == original.outputDigest,
                        "input arrays and public getters cannot rewrite the frozen plan facts")
                }
                if (scenario == "audit-before-prepare") {
                    fixture.database.execute("DELETE FROM audit_events WHERE kind='context_read_admitted'")
                }
                let admission = fixture.prepareParent(plan)
                if (["forged-reference", "wrong-parent", "different-run", "audit-before-prepare"].contains(scenario)) {
                    expect(admission.isError() && fixture.database.scalarInt("SELECT COUNT(*) FROM operations") == 1,
                        mode + ": " + scenario + " cannot use DTO data to fabricate a completed read before parent admission")
                    count++; continue
                }
                admission.value().getOrThrow()
                let operation = fixture.parentOperation()
                let loaded = fixture.store.loadPlan(operation, fixture.run).value().getOrThrow()
                expect(canonicalAgentValue(contextReadFactLinksValue(loaded.contextReadFacts)) ==
                    canonicalAgentValue(contextReadFactLinksValue(plan.contextReadFacts)), "full fact binding survives durable plan codec")
                if (scenario == "audit-before-execute") { fixture.database.execute("DELETE FROM audit_events WHERE kind='context_read_admitted'") }
                if (scenario == "result-before-execute") {
                    fixture.database.execute("UPDATE items SET payload='invalid' WHERE id='result-context-read-operation'")
                }
                if (scenario == "epoch-before-execute") { fixture.database.execute("UPDATE runs SET epoch=epoch+1") }
                let executing = fixture.store.markExecutingWithSource(fixture.parentSource, operation, fixture.run, loaded, 20, false)
                if (["audit-before-execute", "result-before-execute", "epoch-before-execute"].contains(scenario)) {
                    expect(executing.isError() && fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 1,
                        mode + ": " + scenario + " is rechecked before execution without touching the prior read Receipt")
                    count++; continue
                }
                executing.value().getOrThrow()
                if (scenario == "audit-before-handoff") { fixture.database.execute("DELETE FROM audit_events WHERE kind='context_read_admitted'") }
                if (scenario == "projection-before-handoff") { fixture.database.execute("UPDATE runs SET skill_snapshot='changed'") }
                if (scenario == "cancel-before-handoff") { let _ = fixture.runtime.cancel(1000) }
                let handed = fixture.store.markExecutionHandoffWithSource(fixture.parentSource, operation, fixture.run, fixture.thread, 21)
                if (["audit-before-handoff", "projection-before-handoff", "cancel-before-handoff"].contains(scenario)) {
                    expect(handed.isError() && fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 1 &&
                        fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 1,
                        mode + ": " + scenario + " prevents new effects while retaining the completed read evidence")
                    count++; continue
                }
                handed.value().getOrThrow()
                expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations") == 2 &&
                    fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 2 &&
                    fixture.database.scalarInt("SELECT COUNT(*) FROM runs") == 1,
                    "real parent uses verified completed read on the same Run through the normal Operation handoff")
                count++
            } finally { fixture.close() }
        }
    }
    expect(count == 24, "all context read consumption scenarios executed")
    println("Context read plan consumption contract passed: 24 scenarios")
}
