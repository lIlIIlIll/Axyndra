package agent_product

import yjson.*
import yjson_support.*

import agent_domain.*
import agent_store.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class PluginCommandResolutionTests {
    @TestCase
    func actualDeferredReadAndFinalMutationCancellationNeverMintAllowance(): Unit {
        for (stage in ["read", "mutation"]) {
            let f = WorkflowCommandFixture()
            try {
                @Expect(f.command("goal", "set A cancelled deferred objective").isOk())
                let first = f.session.approval().getOrThrow()
                @Expect(first.preview.field("host_user_control").isNone())
                if (stage == "mutation") {
                    @Expect(f.session.decide(first.operationId.value, ApprovalDecision.Approve).isOk())
                    @Expect(httpIntentText(f.session.approval().getOrThrow().preview.field("host_user_control").getOrThrow(), "action"), "create")
                }
                @Expect(f.session.cancel().isOk())
                @Expect(f.session.approval().isNone()); @Expect(f.facts().isNone())
                @Expect(f.document("goal").revision, 0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 2)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"), 0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_control_document_v1'"), 0)
            } finally { f.close() }
        }
    }

    @TestCase
    func actualDocumentChangeAfterReadCannotReplaceTheReviewedControlOrConsumeFacts(): Unit {
        let f = WorkflowCommandFixture()
        try {
            @Expect(f.command("goal", "set A frozen objective").isOk())
            let read = f.session.approval().getOrThrow()
            @Expect(f.session.decide(read.operationId.value, ApprovalDecision.Approve).isOk())
            let mutation = f.session.approval().getOrThrow()
            let frozen = canonicalAgentValue(mutation.preview.field("host_user_control").getOrThrow())
            // A trusted test writer performs an actual versioned CAS. The
            // command may not reread/reselect its control to conceal this race.
            let changed = SqlitePluginDocumentRepository(f.database).compareExchange(f.document("goal"), nullValue(),
                { _ => Result<Unit>.Ok(()) })
            @Expect(changed.isOk()); @Expect(changed.value().getOrThrow().revision, 1)
            @Expect(canonicalAgentValue(f.session.approval().getOrThrow().preview.field("host_user_control").getOrThrow()), frozen)
            @Expect(f.session.decide(mutation.operationId.value, ApprovalDecision.Approve).isError())
            @Expect(f.facts().isNone()); @Expect(f.document("goal").revision, 1)
            @Expect(f.document("goal").encoded, "null")
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_control_document_v1'"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
        } finally { f.close() }
    }

    @TestCase
    func actualReceiptTriggerChangingParentPlanRollsBackDocumentReceiptAndAllowance(): Unit {
        let f = WorkflowCommandFixture()
        try {
            @Expect(f.command("goal", "set Preserve the exact reviewed parent").isOk())
            let read = f.session.approval().getOrThrow()
            @Expect(f.session.decide(read.operationId.value, ApprovalDecision.Approve).isOk())
            let mutation = f.session.approval().getOrThrow()
            let before = f.database.query("SELECT normalized_plan FROM operation_effect_records WHERE operation_id=?",
                [SqlParameter.Text(mutation.operationId.value)])[0].required(0)
            // Fault after actual child admission/validation but before the
            // host participant consumes its same-Tx proof. No fake Run/source.
            f.database.execute("CREATE TRIGGER change_command_parent BEFORE INSERT ON operation_receipts " +
                "WHEN NEW.outcome='completed' AND EXISTS(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=NEW.operation_id) " +
                "BEGIN UPDATE operation_effect_records SET normalized_plan='not-a-plan' WHERE operation_id=" +
                "(SELECT parent_operation_id FROM derived_operation_admissions WHERE operation_id=NEW.operation_id); END")
            @Expect(f.session.decide(mutation.operationId.value, ApprovalDecision.Approve).isError())
            @Expect(f.facts().isNone()); @Expect(f.document("goal").revision, 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_control_document_v1'"), 0)
            @Expect(f.database.query("SELECT normalized_plan FROM operation_effect_records WHERE operation_id=?",
                [SqlParameter.Text(mutation.operationId.value)])[0].required(0), before)
        } finally { f.close() }
    }
}
