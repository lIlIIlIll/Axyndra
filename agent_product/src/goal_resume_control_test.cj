package agent_product

import agent_domain.*
import agent_store.*
import persistence_runtime.*
import tool_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func goalResumeApproveCurrentReadAndMutation(session: ApplicationSession): Unit {
    let read = session.approval().getOrThrow()
    @Expect(read.toolName, HOST_CONTEXT_READ_TOOL)
    @Expect(session.decide(read.operationId.value, ApprovalDecision.Approve).isOk())
    let mutation = session.approval().getOrThrow()
    @Expect(mutation.operationId.value != read.operationId.value)
    @Expect(session.decide(mutation.operationId.value, ApprovalDecision.Approve).isOk())
    @Expect(session.approval().isNone())
}

@Test
class GoalResumeControlTests {
    @TestCase
    func exactImportedElevenFieldsRequireExplicitCurrentResumeWithTheCanonicalBudget(): Unit {
        for (bounded in [true, false]) {
            let f = WorkflowDocumentFixture(provider: "prepare_document", payload: true)
            try {
                goalFrontendConfigure(f)
                let thread = if (bounded) { "resume-cold-bounded" } else { "resume-cold-unbounded" }
                let session = f.product.applicationSession(sessionId: Some(SessionId(thread)))
                let history = goalFrontendLegacy()
                if (!bounded) { history.put("tokenBudget", nullValue()) }
                let raw = " \n" + stringifyUnifiedJson(history) + "\n "
                goalFrontendSeedCold(f, thread, raw)
                @Expect(session.handle("/goal migrate").isOk())
                @Expect(workflowDocumentTestAllowance(f, thread).isNone())
                @Expect(canonicalAgentValue(lifecycleTestRequire(f.snapshot(thread, key: "goal").decode())), canonicalAgentValue(history))
                @Expect(session.handle("/goal resume").isOk())
                let actual = workflowDocumentTestAllowance(f, thread).getOrThrow()
                @Expect(actual.enabled); @Expect(!actual.closed); @Expect(actual.tokensUsed, 0)
                if (bounded) { @Expect(actual.tokenBudget.getOrThrow(), 1000) } else { @Expect(actual.tokenBudget.isNone()) }
                let document = lifecycleTestRequire(f.snapshot(thread, key: "goal").decode())
                @Expect(document.field("tokensUsed").getOrThrow().asNumberText(), "123")
                @Expect(document.field("timeUsedSeconds").getOrThrow().asNumberText(), "8")
                @Expect(goalFrontendCold(f, thread), raw)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_control_document_v1'"), 1)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            } finally { f.close() }
        }
    }
    @TestCase
    func existingPausedAllowanceKeepsItsIdentityUsageAndBudgetOnExplicitResume(): Unit {
        let f = WorkflowDocumentFixture(provider: "prepare_document", payload: true)
        try {
            goalFrontendConfigure(f)
            let thread = "resume-existing-allowance"
            let session = f.product.applicationSession(sessionId: Some(SessionId(thread)))
            for (command in ["/goal set keep identity", "/goal budget 1000", "/goal pause"]) {
                @Expect(session.handle(command).isOk()) }
            let paused = workflowDocumentTestAllowance(f, thread).getOrThrow()
            @Expect(!paused.enabled)
            @Expect(session.handle("/goal resume").isOk())
            let resumed = workflowDocumentTestAllowance(f, thread).getOrThrow()
            @Expect(resumed.enabled); @Expect(resumed.allowanceId, paused.allowanceId)
            @Expect(resumed.tokensUsed, paused.tokensUsed); @Expect(resumed.tokenBudget.getOrThrow(), 1000)
            @Expect(resumed.generation, paused.generation + 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
        } finally { f.close() }
    }
    @TestCase
    func closedActualAllowanceCannotBeReopenedByDescriptiveGoalData(): Unit {
        let f = WorkflowDocumentFixture(provider: "prepare_document", payload: true)
        try {
            goalFrontendConfigure(f)
            let thread = "resume-closed-allowance"
            let session = f.product.applicationSession(sessionId: Some(SessionId(thread)))
            @Expect(session.handle("/goal set close original authority").isOk())
            @Expect(session.handle("/goal drop").isOk())
            let closed = workflowDocumentTestAllowance(f, thread).getOrThrow()
            @Expect(closed.closed)
            let description = f.call(thread, objectValue([ValueField("op", textValue("create")),
                ValueField("objective", textValue("descriptive data does not replace closed authority"))]), localName: "goal")
            @Expect(!description.isError)
            let before = f.snapshot(thread, key: "goal")
            @Expect(session.handle("/goal resume").isError())
            @Expect(workflowDocumentTestAllowance(f, thread).getOrThrow().eventId, closed.eventId)
            @Expect(f.snapshot(thread, key: "goal").encoded, before.encoded)
            @Expect(f.snapshot(thread, key: "goal").revision, before.revision)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
        } finally { f.close() }
    }
    @TestCase
    func readApprovalDoesNotCreateAllowanceAndMutationRejectOrCancelCannotConsumeIt(): Unit {
        for (decision in ["reject", "cancel"]) {
            let f = WorkflowDocumentFixture(mode: ApprovalMode.AlwaysAsk, provider: "prepare_document", payload: true)
            try {
                goalFrontendConfigure(f)
                let thread = "resume-cold-approval-" + decision
                let session = f.product.applicationSession(sessionId: Some(SessionId(thread)))
                goalFrontendSeedCold(f, thread, stringifyUnifiedJson(goalFrontendLegacy()))
                @Expect(session.handle("/goal migrate").isOk()); goalResumeApproveCurrentReadAndMutation(session)
                let before = f.snapshot(thread, key: "goal")
                @Expect(session.handle("/goal resume").isOk())
                let read = session.approval().getOrThrow()
                @Expect(read.toolName, HOST_CONTEXT_READ_TOOL)
                @Expect(read.preview.field("host_user_control").isNone())
                @Expect(workflowDocumentTestAllowance(f, thread).isNone())
                @Expect(session.decide(read.operationId.value, ApprovalDecision.Approve).isOk())
                let mutation = session.approval().getOrThrow()
                let control = mutation.preview.field("host_user_control").getOrThrow()
                @Expect(httpIntentText(control, "action"), "resume_or_create")
                @Expect(control.field("token_budget").getOrThrow().asNumberText(), "1000")
                @Expect(workflowDocumentTestAllowance(f, thread).isNone())
                if (decision == "reject") { @Expect(session.decide(mutation.operationId.value, ApprovalDecision.Reject).isError()) }
                else { @Expect(session.cancel().isOk()) }
                @Expect(workflowDocumentTestAllowance(f, thread).isNone())
                @Expect(f.snapshot(thread, key: "goal").encoded, before.encoded)
                @Expect(f.snapshot(thread, key: "goal").revision, before.revision)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_control_document_v1'"), 0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            } finally { f.close() }
        }
    }
    @TestCase
    func actualSourceOrSelectedConfigurationChangeCannotCreateTheFrozenAbsentAllowance(): Unit {
        for (change in ["configuration", "source"]) {
            let f = WorkflowDocumentFixture(mode: ApprovalMode.AlwaysAsk, provider: "prepare_document", payload: true)
            try {
                goalFrontendConfigure(f)
                let thread = "resume-cold-current-" + change
                let session = f.product.applicationSession(sessionId: Some(SessionId(thread)))
                goalFrontendSeedCold(f, thread, stringifyUnifiedJson(goalFrontendLegacy()))
                @Expect(session.handle("/goal migrate").isOk()); goalResumeApproveCurrentReadAndMutation(session)
                let before = f.snapshot(thread, key: "goal")
                @Expect(session.handle("/goal resume").isOk())
                let read = session.approval().getOrThrow()
                @Expect(session.decide(read.operationId.value, ApprovalDecision.Approve).isOk())
                let mutation = session.approval().getOrThrow()
                if (change == "configuration") {
                    let path = f.root + "/settings/plugins/goal-tools.json"
                    File.writeTo(path, (String.fromUtf8(File.readFrom(path)) + " ").toArray())
                } else {
                    // Existing actual commit-proof negative: mutate this real
                    // parent's frozen plan within the child receipt transaction.
                    f.database.execute("CREATE TRIGGER change_resume_parent BEFORE INSERT ON operation_receipts " +
                        "WHEN NEW.outcome='completed' AND EXISTS(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=NEW.operation_id) " +
                        "BEGIN UPDATE operation_effect_records SET normalized_plan='not-a-plan' WHERE operation_id=" +
                        "(SELECT parent_operation_id FROM derived_operation_admissions WHERE operation_id=NEW.operation_id); END")
                }
                @Expect(session.decide(mutation.operationId.value, ApprovalDecision.Approve).isError())
                @Expect(workflowDocumentTestAllowance(f, thread).isNone())
                @Expect(f.snapshot(thread, key: "goal").encoded, before.encoded)
                @Expect(f.snapshot(thread, key: "goal").revision, before.revision)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='host_continuation_control_document_v1'"), 0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            } finally { f.close() }
        }
    }
    @TestCase
    func newTypedActionRequiresBothExactPromptAndBudgetFields(): Unit {
        let control = objectValue([ValueField("kind", textValue("continuation")), ValueField("document_key", textValue("goal")),
            ValueField("action", textValue("resume_or_create")), ValueField("next_prompt", textValue("current explicit objective")),
            ValueField("token_budget", integerValue(1000))])
        @Expect(validateCommandContinuationControl(control).isOk())
        for (field in ["next_prompt", "token_budget"]) {
            let missing = objectValue(control.fields.toArray().filter { value => value.name != field }.map { value => ValueField(value.name, value.value) })
            @Expect(validateCommandContinuationControl(missing).isError())
        }
        for (budget in [integerValue(0), integerValue(-1), textValue("1000"), boolValue(true)]) {
            let changed = objectValue(control.fields.toArray().map { value => ValueField(value.name,
                if (value.name == "token_budget") { budget } else { value.value }) })
            @Expect(validateCommandContinuationControl(changed).isError())
        }
        control.put("token_budget", nullValue())
        @Expect(validateCommandContinuationControl(control).isOk())
    }
}
