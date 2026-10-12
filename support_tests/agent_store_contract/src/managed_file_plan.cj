package agent_store_contract

import agent_domain.*
import agent_runtime.*
import agent_store.*
import yjson.*
import yjson_support.*

func managedFilePlanChild(fixture: ChannelIntentStoreFixture, mode: String): NormalizedOperationPlan {
    let binding = channelContractClone(fixture.rootPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow())
    let arguments = objectValue([ValueField("plugin", textValue("axyndra:channel-contract")),
        ValueField("generation", textValue("1")), ValueField("package_digest", textValue("sha256:" + CHANNEL_CONTRACT_DIGEST)),
        ValueField("proposal", objectValue([ValueField("schema", textValue("axyndra.file-change-proposal/v1")),
            ValueField("operations", listValue([objectValue([ValueField("kind", textValue("replace")), ValueField("path", textValue("a.txt")),
                ValueField("expected_content", textValue("before")), ValueField("content", textValue("after"))])]))]))])
    if (mode != "missing-binding") { arguments.put("managed_binding", binding) }
    if (mode == "foreign-endpoint") { binding.put("endpoint_identity", textValue(modelPolicySha256Text("another-endpoint"))) }
    if (mode == "foreign-package") { arguments.put("package_digest", textValue("sha256:" + modelPolicySha256Text("another-package"))) }
    if (mode == "forged-source") { arguments.put("source", textValue("host-approved")) }
    NormalizedOperationPlan("host.file.plan.propose", arguments,
        [Capability(if (mode == "write-capability") { CapabilityKind.WorkspaceWrite } else { CapabilityKind.WorkspaceRead })],
        OperationEffectClass.ReadOnly, OperationRetryDisposition.Safe, modelPolicySha256Text(canonicalAgentValue(arguments)),
        implementationFingerprint: "host-file-plan-v2", toolVersion: "host-file-plan-v2",
        networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied)))
}
func managedFilePlanContract(): Unit {
    var scenarios: Int64 = 0
    for (committed in [false, true]) {
        for (mode in ["valid", "missing-binding", "foreign-endpoint", "foreign-package", "forged-source", "write-capability",
            "startup-admit", "startup-execute", "startup-handoff", "startup-settle",
            "wrong-run", "wrong-epoch", "pending-parent", "no-parent-handoff"]) {
            let fixture = ChannelIntentStoreFixture(committed)
            try {
                if (mode != "pending-parent") { fixture.activateParent(handoff: mode != "no-parent-handoff") }
                if (mode == "wrong-epoch") { fixture.database.execute("UPDATE runs SET epoch=epoch+1 WHERE id='channel-target-run'") }
                let child = OperationId("file-plan-child")
                let plan = managedFilePlanChild(fixture, mode)
                let key = "javascript-service:" + fixture.call.callId + ":proposal"
                let detail = fixture.database.query("SELECT detail FROM operation_receipts WHERE operation_id='channel-startup-operation'")[0].required(0)
                if (mode == "startup-admit") { channelContractCorruptStartup(fixture.database) }
                let admitted = fixture.store.prepareDerivedOperation(child, fixture.parent,
                    if (mode == "wrong-run") { RunId("unrelated-run") } else { fixture.run }, fixture.source, key, plan)
                if (["missing-binding", "foreign-endpoint", "foreign-package", "forged-source", "write-capability", "startup-admit",
                    "wrong-run", "wrong-epoch", "pending-parent", "no-parent-handoff"].contains(mode)) {
                    expect(admitted.isError(), "unbound or unauthorized managed proposal rejects before Operation insertion: " + mode)
                    expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE id='file-plan-child'") == 0,
                        "invalid proposal admission is atomic")
                } else {
                    httpContractRequire(admitted, "read-only managed file child admitted")
                    if (mode == "startup-execute") {
                        channelContractCorruptStartup(fixture.database)
                        expect(fixture.store.markExecuting(child, fixture.run, plan, 34, false).isError(), "executing rechecks startup proof")
                        channelContractRestoreStartup(fixture.database, detail)
                    }
                    httpContractRequire(fixture.store.markExecuting(child, fixture.run, plan, 34, false), "proposal executing")
                    if (mode == "startup-handoff") {
                        channelContractCorruptStartup(fixture.database)
                        expect(fixture.store.markExecutionHandoff(child, fixture.run, fixture.thread, 35).isError(), "handoff rechecks startup proof")
                        channelContractRestoreStartup(fixture.database, detail)
                    }
                    httpContractRequire(fixture.store.markExecutionHandoff(child, fixture.run, fixture.thread, 35), "proposal handoff")
                    let receipt = VNextOperationReceipt("receipt-file-plan-child", child, OperationOutcome.Completed,
                        objectValue([ValueField("tool", textValue("host.file.plan.propose")), ValueField("output", objectValue([]))]),
                        objectValue([ValueField("parent_operation_id", textValue(fixture.parent.value)), ValueField("service", textValue("file.plan.propose"))]), 36)
                    if (mode == "startup-settle") {
                        channelContractCorruptStartup(fixture.database)
                        expect(fixture.store.settleDerivedOperation(fixture.run, fixture.parent, receipt).isError(), "settlement rechecks startup proof")
                        expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='file-plan-child'") == 0,
                            "invalid settlement cannot retain a false completed receipt")
                        channelContractRestoreStartup(fixture.database, detail)
                    }
                    httpContractRequire(fixture.store.settleDerivedOperation(fixture.run, fixture.parent, receipt), "proposal single completed receipt")
                    expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='file-plan-child'") == 1 &&
                        fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE operation_id='file-plan-child' AND kind='operation_parent_intent_authorized'") == 0,
                        "proposal preserves one read-only receipt without inventing frozen ParentIntent approval")
                }
                expect(fixture.database.query("PRAGMA foreign_key_check").isEmpty(), "proposal durable references remain valid")
                scenarios += 1
            } finally { fixture.close() }
        }
    }
    expect(scenarios == 28, "exact managed file-plan Store scenario inventory")
    println("Managed file-plan Store contract passed: 28 actual SQLite scenarios")
}
