package agent_product

import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func channelTestInput(hex: String, mode!: String = "echo"): AgentValue {
    objectValue([ValueField("bytes_hex", textValue(hex)), ValueField("mode", textValue(mode))])
}
func channelTestChildren(fixture: LifecycleManagerFixture, thread: String, outcome: String): Int64 {
    fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts receipt JOIN operations operation " +
        "ON operation.id=receipt.operation_id JOIN runs run ON run.id=operation.run_id " +
        "JOIN operation_effect_records effect ON effect.operation_id=operation.id WHERE run.thread_id='" + thread +
        "' AND effect.tool_id='host.process.channel.write' AND receipt.outcome='" + outcome + "'")
}
func channelTestHandoffs(fixture: LifecycleManagerFixture, thread: String): Int64 {
    fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events audit JOIN operations operation " +
        "ON operation.id=audit.operation_id JOIN runs run ON run.id=operation.run_id " +
        "JOIN operation_effect_records effect ON effect.operation_id=operation.id WHERE run.thread_id='" + thread +
        "' AND effect.tool_id='host.process.channel.write' AND audit.kind='operation_execution_handoff'")
}
func channelTestAwaitHandoff(fixture: LifecycleManagerFixture, thread: String): Unit {
    let deadline = MonoTime.now() + Duration.second * 8
    while (channelTestHandoffs(fixture, thread) == 0 && MonoTime.now() < deadline) { sleep(Duration.millisecond * 10) }
    if (channelTestHandoffs(fixture, thread) != 1) { throw IllegalStateException("real channel child never reached handoff") }
}
func channelTestOutput(fixture: LifecycleManagerFixture, thread: String, call: String): AgentValue {
    for (item in SqliteThreadCommitSink(fixture.database).loadThread(ThreadId(thread)).items) {
        match (item.content) {
            case ThreadItemContent.ToolResult(id, _, _, output, isError) =>
                if (id.value == call) {
                    if (isError) { throw IllegalStateException("channel result failed: " + stringifyUnifiedJson(output)) }
                    return output
                }
            case _ => ()
        }
    }
    throw IllegalStateException("missing actual canonical channel ToolResult")
}
func channelTestCall(fixture: LifecycleManagerFixture, thread: String, call: String, input: AgentValue,
    budget!: ExecutionBudget = ExecutionBudget(maxToolCalls: 2, maxConcurrentTools: 1)): Result<ToolInvocationResult> {
    fixture.product.vnext.executeCanonicalTool(SessionId(thread), fixture.ceiling(), ToolCall(call, fixture.name, input), budget: budget)
}
func channelTestAwaitReleased(fixture: LifecycleManagerFixture): Unit {
    let deadline = MonoTime.now() + Duration.second * 6
    while (fixture.manager.retainedCount() > 0 && MonoTime.now() < deadline) { sleep(Duration.millisecond * 10) }
    if (fixture.manager.retainedCount() != 0) { throw IllegalStateException("channel manager still retains cleanup ownership") }
}

@Test
class ProductPluginChannelServiceTests {
    @TestCase
    func realDirectRootWritesExactBinaryBytesWithOneChildReceiptAndOneSlot(): Unit {
        let fixture = LifecycleManagerFixture(completeCapabilities: true)
        try {
            let service = lifecycleTestRequire(fixture.startProtocol("channel-direct", "channel-direct-maintenance")).service.getOrThrow()
            let firstHex = "006869ff0a" // NUL and non-UTF8 are bytes, never JSON text re-encoding.
            let first = managedCompleted(channelTestCall(fixture, "channel-direct", "same-call", channelTestInput(firstHex)))
            @Expect(!first.isError)
            @Expect(lifecycleText(first.output, "status"), "complete")
            let result = first.output.field("result").getOrThrow()
            @Expect(lifecycleText(result, "bytes_hex"), firstHex)
            @Expect(lifecycleText(result, "receipt_id") != "")
            @Expect(channelTestChildren(fixture, "channel-direct", "completed"), 1)
            @Expect(channelTestHandoffs(fixture, "channel-direct"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            let child = fixture.database.query("SELECT o.normalized_plan FROM operations o " +
                "JOIN operation_effect_records e ON e.operation_id=o.id WHERE e.tool_id='host.process.channel.write'")
            @Expect(child.size, 1)
            let arguments = decodeStoredValue(child[0].required(0)).field("arguments").getOrThrow()
            @Expect(lifecycleText(arguments.field("intent").getOrThrow(), "bytes_hex"), firstHex)
            let binding = lifecycleTestRequire(service.bindingFor(fixture.name))
            @Expect(canonicalAgentValue(arguments.field("binding").getOrThrow()), canonicalAgentValue(binding))
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_parent_intent_authorized'"), 1)
            // Reusing a call id in a new real Run does not reuse an old child or
            // previous invocation's cancellation registration and observer.
            let second = managedCompleted(channelTestCall(fixture, "channel-direct", "same-call", channelTestInput("7365636f6e640a")))
            @Expect(lifecycleText(second.output.field("result").getOrThrow(), "bytes_hex"), "7365636f6e640a")
            @Expect(channelTestChildren(fixture, "channel-direct", "completed"), 2)
            @Expect(channelTestHandoffs(fixture, "channel-direct"), 2)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='channel-direct' AND state='completed'"), 2)
            // The same genuine child payload cannot turn a direct host-only
            // tool call into an admitted derived write.
            @Expect(managedRejected(fixture.product.vnext.executeCanonicalTool(SessionId("channel-direct"), fixture.ceiling(),
                ToolCall("hidden-writer-forgery", HOST_CHANNEL_WRITE_TOOL, arguments))))
            @Expect(channelTestHandoffs(fixture, "channel-direct"), 2)
        } finally { fixture.close() }
    }

    @TestCase
    func realCommittedRootFreezesBytesBeforeApprovalAndRejectedCallsNeverWrite(): Unit {
        let fixture = LifecycleManagerFixture(approval: ApprovalMode.AlwaysAsk, completeCapabilities: true)
        try {
            let _ = lifecycleTestRequire(fixture.startProtocol("channel-model", "channel-model-maintenance"))
            let session = fixture.product.applicationSession(sessionId: Some(SessionId("channel-model")))
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("channel-rejected", fixture.name, channelTestInput("72656a6563740a"))
            @Expect(session.submit("Invoke the channel fixture, after asking for approval.").isOk())
            @Expect(session.approval().isSome())
            @Expect(channelTestHandoffs(fixture, "channel-model"), 0)
            @Expect(session.decide(session.approval().getOrThrow().operationId.value, ApprovalDecision.Reject).isOk())
            @Expect(channelTestHandoffs(fixture, "channel-model"), 0)
            let hex = "616363657074000a"
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("channel-approved", fixture.name, channelTestInput(hex))
            @Expect(session.submit("Approve the exact bytes in the prepared channel call.").isOk())
            let approval = session.approval().getOrThrow()
            let before = fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?", [SqlParameter.Text(approval.operationId.value)])
            @Expect(before.size, 1)
            let plan = decodeStoredValue(before[0].required(0))
            let intents = plan.field("arguments").getOrThrow().field("host_plan").getOrThrow().field("intents").getOrThrow()
            @Expect(intents.items.size, 1)
            @Expect(lifecycleText(intents.items[0], "bytes_hex"), hex)
            @Expect(channelTestChildren(fixture, "channel-model", "completed"), 0)
            lifecycleTestRequire(session.decide(approval.operationId.value, ApprovalDecision.Approve))
            let output = channelTestOutput(fixture, "channel-model", "channel-approved")
            @Expect(lifecycleText(output.field("result").getOrThrow(), "bytes_hex"), hex)
            @Expect(channelTestChildren(fixture, "channel-model", "completed"), 1)
            @Expect(channelTestHandoffs(fixture, "channel-model"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM canonical_decision_items") > 0)
            let after = fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?", [SqlParameter.Text(approval.operationId.value)])
            @Expect(before[0].required(0), after[0].required(0))
        } finally { fixture.close() }
    }

    @TestCase
    func remoteUnknownAfterSuccessfulWriteKeepsChildReceiptAndRevokesWithoutReplay(): Unit {
        for (mode in ["unknown_after_write", "malformed_after_write"]) {
        let fixture = LifecycleManagerFixture(completeCapabilities: true)
        try {
            let service = lifecycleTestRequire(fixture.startProtocol("channel-unknown", "channel-unknown-maintenance")).service.getOrThrow()
            let result = channelTestCall(fixture, "channel-unknown", "unknown-call", channelTestInput("756e6b6e6f776e0a", mode: mode))
            @Expect(managedRejected(result))
            @Expect(channelTestChildren(fixture, "channel-unknown", "completed"), 1)
            @Expect(channelTestHandoffs(fixture, "channel-unknown"), 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts receipt JOIN operations operation " +
                "ON operation.id=receipt.operation_id JOIN runs run ON run.id=operation.run_id " +
                "WHERE run.thread_id='channel-unknown' AND receipt.outcome='unknown'"), 1)
            @Expect(!service.active())
            @Expect(managedRejected(channelTestCall(fixture, "channel-unknown", "new-key-is-not-retry-authority", channelTestInput("756e6b6e6f776e0a"))))
            @Expect(channelTestHandoffs(fixture, "channel-unknown"), 1)
            channelTestAwaitReleased(fixture)
        } finally { fixture.close() }
        }
    }

    @TestCase
    func sameCallIdBlockedStdinCancellationDoesNotRevokeOtherThreadsLease(): Unit {
        let fixture = LifecycleManagerFixture(completeCapabilities: true, blockedStdin: true, maxInputBytes: 20000)
        try {
            let first = lifecycleTestRequire(fixture.startProtocol("channel-cancel-a", "channel-cancel-maintenance-a")).service.getOrThrow()
            let second = lifecycleTestRequire(fixture.startProtocol("channel-cancel-b", "channel-cancel-maintenance-b")).service.getOrThrow()
            @Expect(lifecycleText(lifecycleTestRequire(first.bindingFor(fixture.name)), "lease_id") !=
                lifecycleText(lifecycleTestRequire(second.bindingFor(fixture.name)), "lease_id"))
            let sessionA = fixture.product.applicationSession(sessionId: Some(SessionId("channel-cancel-a")))
            let sessionB = fixture.product.applicationSession(sessionId: Some(SessionId("channel-cancel-b")))
            let longHex = String.fromUtf8(Array<Byte>(12000, repeat: 0x61)) // 6000 bytes exceed the real 4096-byte pipe.
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("shared-call", fixture.name, channelTestInput(longHex))
            let doneA = AtomicBool(false)
            let pendingA = spawn { try { sessionA.submit("Write the long channel message.") } finally { doneA.store(true) } }
            try {
                channelTestAwaitHandoff(fixture, "channel-cancel-a")
                @Expect(!doneA.load())
                fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("shared-call", fixture.name,
                    channelTestInput("6265650a", mode: "write_only"))
                lifecycleTestRequire(sessionB.submit("Write four bytes to the other independent Thread."))
                @Expect(channelTestChildren(fixture, "channel-cancel-b", "completed"), 1)
                let started = agentUtcMillis()
                @Expect(sessionA.cancel().isOk())
                let _ = pendingA.get()
                @Expect(agentUtcMillis() - started < 5000)
                @Expect(channelTestChildren(fixture, "channel-cancel-a", "unknown"), 1)
                @Expect(channelTestChildren(fixture, "channel-cancel-a", "completed"), 0)
                @Expect(channelTestHandoffs(fixture, "channel-cancel-a"), 1)
                @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='channel-cancel-a' AND state='cancelled'"), 1)
                @Expect(!first.active() && second.active())
                let after = managedCompleted(channelTestCall(fixture, "channel-cancel-b", "after-a-cancel",
                    channelTestInput("6f6b0a", mode: "write_only")))
                @Expect(!after.isError)
                @Expect(channelTestChildren(fixture, "channel-cancel-b", "completed"), 2)
            } finally { try { let _ = sessionA.cancel() } finally { let _ = pendingA.get() } }
        } finally { fixture.close() }
    }

    @TestCase
    func previousInvocationObserverCannotWriteIntoNextRealRun(): Unit {
        let fixture = LifecycleManagerFixture(completeCapabilities: true)
        try {
            let service = lifecycleTestRequire(fixture.startProtocol("channel-late", "channel-late-maintenance")).service.getOrThrow()
            @Expect(!managedCompleted(channelTestCall(fixture, "channel-late", "old-call", channelTestInput("6f6c640a"))).isError)
            @Expect(channelTestChildren(fixture, "channel-late", "completed"), 1)
            @Expect(managedRejected(channelTestCall(fixture, "channel-late", "new-call", channelTestInput("6e65770a", mode: "stale_observer"))))
            @Expect(channelTestChildren(fixture, "channel-late", "completed"), 1)
            @Expect(channelTestHandoffs(fixture, "channel-late"), 1)
            @Expect(!service.active())
            channelTestAwaitReleased(fixture)
        } finally { fixture.close() }
    }

    @TestCase
    func startupAndLaterWritesShareOneCumulativeInputLimit(): Unit {
        let fixture = LifecycleManagerFixture(completeCapabilities: true, maxInputBytes: 16)
        try {
            let service = lifecycleTestRequire(fixture.startProtocol("channel-total", "channel-total-maintenance")).service.getOrThrow()
            // Actual startup wrote six bytes. Each following call writes five.
            for (call in ["first-five", "second-five"]) {
                @Expect(!managedCompleted(channelTestCall(fixture, "channel-total", call, channelTestInput("313233340a"))).isError)
            }
            @Expect(channelTestChildren(fixture, "channel-total", "completed"), 2)
            let rejected = channelTestCall(fixture, "channel-total", "seventeenth-byte", channelTestInput("78"))
            @Expect(managedRejected(rejected))
            @Expect(rejected.isError())
            let actualError = rejected.error().getOrThrow()
            @Expect(actualError.kind, AgentErrorKind.RecoveryRequired)
            @Expect(actualError.code, "plugin.service_outcome_unknown")
            @Expect(!actualError.retryable && !actualError.fallbackAllowed)
            @Expect(channelTestChildren(fixture, "channel-total", "completed"), 2)
            // The attempted write has crossed canonical handoff, so a limit
            // failure is conservatively Unknown and never safely replayable.
            @Expect(channelTestChildren(fixture, "channel-total", "unknown"), 1)
            @Expect(fixture.database.query("SELECT receipt.id FROM operation_receipts receipt JOIN operations operation " +
                "ON operation.id=receipt.operation_id JOIN runs run ON run.id=operation.run_id " +
                "JOIN operation_effect_records effect ON effect.operation_id=operation.id " +
                "WHERE run.thread_id='channel-total' AND effect.tool_id=? AND receipt.outcome='unknown'",
                [SqlParameter.Text(fixture.name)]).size, 1)
            @Expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='channel-total' AND state='recovery_required'"), 1)
            @Expect(!service.active())
            @Expect(channelTestHandoffs(fixture, "channel-total"), 3)
            @Expect(managedRejected(channelTestCall(fixture, "channel-total", "new-key-cannot-reopen", channelTestInput("79"))))
            @Expect(channelTestHandoffs(fixture, "channel-total"), 3)
            @Expect(channelTestChildren(fixture, "channel-total", "unknown"), 1)
            @Expect(channelTestChildren(fixture, "channel-total", "completed"), 2)
            channelTestAwaitReleased(fixture)
        } finally { fixture.close() }
    }

    @TestCase
    func actualRootDeadlineInterruptsBlockedWriteAndPreservesUnknownReceipt(): Unit {
        let fixture = LifecycleManagerFixture(completeCapabilities: true, blockedStdin: true, maxInputBytes: 20000)
        try {
            let _ = lifecycleTestRequire(fixture.startProtocol("channel-deadline", "channel-deadline-maintenance"))
            let longHex = String.fromUtf8(Array<Byte>(12000, repeat: 0x61))
            let started = agentUtcMillis()
            let pending = spawn { channelTestCall(fixture, "channel-deadline", "deadline-call", channelTestInput(longHex),
                budget: ExecutionBudget(maxToolCalls: 2, maxConcurrentTools: 1, deadlineMillis: started + 3000)) }
            try {
                channelTestAwaitHandoff(fixture, "channel-deadline")
                @Expect(managedRejected(pending.get()))
                @Expect(agentUtcMillis() - started < 8000)
                @Expect(channelTestChildren(fixture, "channel-deadline", "unknown"), 1)
                @Expect(channelTestChildren(fixture, "channel-deadline", "completed"), 0)
                channelTestAwaitReleased(fixture)
            } finally { let _ = pending.get() }
        } finally { fixture.close() }
    }
}
