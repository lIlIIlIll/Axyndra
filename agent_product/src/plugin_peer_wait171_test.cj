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

func peerWaitSelection171(f: WorkflowChildFixture111): Unit {
    jobSnapshotSelection165(f)
    @Expect(f.product.setPluginEnabled(f.namespace, false).isOk())
    let settings = parseUnifiedJson(String.fromUtf8(File.readFrom(f.root + "/settings/plugins/primitives.json")))
    let tool = settings.field("plugins").getOrThrow().items[0].field("tools").getOrThrow().items[1]
    tool.put("services", listValue([textValue("peer.receive"), textValue("peer.wait"), textValue("peer.send")]))
    tool.put("invocation_capability", objectValue([ValueField("catalog", textValue("workspace.read")),
        ValueField("services", objectValue([ValueField("peer.receive", textValue("workspace.read")),
            ValueField("peer.wait", textValue("workspace.read")), ValueField("peer.send", textValue("peer.message"))]))]))
    File.writeTo(f.root + "/settings/plugins/primitives.json", stringifyUnifiedJson(settings).toArray())
    @Expect(f.product.setPluginEnabled(f.namespace, true).isOk())
}
func peerWaitCall171(f: WorkflowChildFixture111, id: String, sender: String, timeout: Int64): ToolCall {
    ToolCall(id, "plugin." + f.namespace + ".hub", objectValue([ValueField("op", textValue("wait")),
        ValueField("from", textValue(sender)), ValueField("timeoutMs", integerValue(timeout))]))
}
func peerWaitSeedActualMail171(f: WorkflowChildFixture111, thread: SessionId): ProductHubMessageSnapshot {
    // Original real child model -> installed canonical Native Hub sender -> original
    // SQLite Task snapshot; no synthetic Source/Receipt/history/response.
    f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("actual-peer-wait-mail-171", "plugin." + f.namespace + ".hub", objectValue([
        ValueField("op", textValue("send")), ValueField("to", textValue("Main")),
        ValueField("message", textValue("actual waiting mail 雪\\\"\n")), ValueField("replyTo", textValue("original-reply-171"))]))
    let result = hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(thread, f.capabilities(),
        f.call(thread.value), budget: f.budget()))
    try { @Expect(!result.isError); expectCanonicalReturnedReceipt(f.database, result) }
    finally { result.releasePayload() }
    let roots = ProductTaskPersistence(f.database).loadAll()
    @Expect(roots.size, 1); @Expect(roots[0].messages.size, 1)
    @Expect(!roots[0].messages[0].consumed)
    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='hub'"), 0)
    roots[0].messages[0].snapshot
}
func expectPeerWaitOriginalFields171(result: ToolResult, expected: ProductHubMessageSnapshot): Unit {
    @Expect(!result.isError); @Expect(result.payloadLease.isSome())
    @Expect(httpIntentText(result.output, "op"), "wait")
    let value = result.output.field("waited").getOrThrow()
    @Expect(encodeAgentValue(value), encodeAgentValue(hubMessageValue(expected)))
    @Expect(httpIntentText(value, "id"), expected.id)
    @Expect(httpIntentText(value, "from"), expected.from)
    @Expect(httpIntentText(value, "to"), expected.to)
    @Expect(httpIntentText(value, "message"), expected.message)
    @Expect(httpIntentText(value, "replyTo"), expected.replyTo)
    @Expect(value.field("createdAt").getOrThrow().asInt64(), expected.createdAt)
}

@Test
class InstalledWorkflowActualPeerWait171Tests {
    @TestCase
    func originalWholeMessageAndForeignTimeoutUseActualMailboxAndOneCanonicalTake171(): Unit {
        let f = WorkflowChildFixture111(); let owner = SessionId("peer-wait-original-owner-171")
        try {
            peerWaitSelection171(f)
            let expected = peerWaitSeedActualMail171(f, owner)
            let starts = f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.child.start'")
            let models = f.database.scalarInt("SELECT COUNT(*) FROM model_attempts")
            let foreignResult171 = hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(SessionId("peer-wait-foreign-171"),
                f.capabilities(delegate: false), peerWaitCall171(f, "foreign-wait-171", expected.from, 20), budget: f.budget()))
            try {
                @Expect(!foreignResult171.isError); @Expect(foreignResult171.payloadLease.isSome())
                @Expect(foreignResult171.output.field("waited").getOrThrow().unifiedKind, ValueKind.Null)
                expectCanonicalReturnedReceipt(f.database, foreignResult171)
            } finally { foreignResult171.releasePayload() }
            @Expect(!ProductTaskPersistence(f.database).loadAll()[0].messages[0].consumed)
            let actual = hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(owner, f.capabilities(delegate: false),
                peerWaitCall171(f, "original-wait-171", expected.from, 0), budget: f.budget()))
            try { expectPeerWaitOriginalFields171(actual, expected); expectCanonicalReturnedReceipt(f.database, actual) }
            finally { actual.releasePayload() }
            @Expect(ProductTaskPersistence(f.database).loadAll()[0].messages[0].consumed)
            let empty = hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(owner, f.capabilities(delegate: false),
                peerWaitCall171(f, "already-taken-wait-171", expected.from, 20), budget: f.budget()))
            try { @Expect(!empty.isError); @Expect(empty.output.field("waited").getOrThrow().unifiedKind, ValueKind.Null) }
            finally { empty.releasePayload() }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.child.start'"), starts + 3)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), models)
        } finally { f.close() }
    }
    @TestCase
    func originalSqlWriteRefusalKeepsEveryMailboxByteAndDoesNotInventCompletedTake171(): Unit {
        let f = WorkflowChildFixture111(); let owner = SessionId("peer-wait-sql-owner-171")
        var trigger = false
        try {
            peerWaitSelection171(f); let expected = peerWaitSeedActualMail171(f, owner)
            let before = f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts receipt JOIN operation_effect_records effect ON effect.operation_id=receipt.operation_id WHERE effect.tool_id='host.child.start' AND receipt.outcome='completed'")
            f.database.execute("CREATE TRIGGER deny_peer_wait_171 BEFORE UPDATE ON task_snapshots WHEN instr(NEW.payload,'\"consumed\":true')>0 BEGIN SELECT RAISE(ABORT,'actual peer wait persistence denied'); END")
            trigger = true
            let result = f.product.vnext.executeCanonicalTool(owner, f.capabilities(delegate: false),
                peerWaitCall171(f, "sql-failed-wait-171", expected.from, 0), budget: f.budget())
            match (result) {
                case Result.Err(_) => ()
                case Result.Ok(ToolInvocationResult.Completed(value)) => try { @Expect(value.isError) } finally { value.releasePayload() }
                case _ => @Expect(false) }
            let stored = ProductTaskPersistence(f.database).loadAll()[0].messages[0]
            @Expect(!stored.consumed); @Expect(encodeAgentValue(hubMessageValue(stored.snapshot)), encodeAgentValue(hubMessageValue(expected)))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts receipt JOIN operation_effect_records effect ON effect.operation_id=receipt.operation_id WHERE effect.tool_id='host.child.start' AND receipt.outcome='completed'"), before)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts receipt JOIN operation_effect_records effect ON effect.operation_id=receipt.operation_id WHERE effect.tool_id='host.child.start' AND receipt.outcome='unknown'"), 1)
        } finally { if (trigger) { f.database.execute("DROP TRIGGER deny_peer_wait_171") }; f.close() }
    }
    @TestCase
    func actualCallerCancellationJoinsWaitingFutureAndLeavesOriginalUnmatchedMailUnconsumed171(): Unit {
        let f = WorkflowChildFixture111(); let ownerThread = SessionId("peer-wait-cancel-owner-171")
        let cancel = CancellationSource(); let owner = ProductDirectPreparationOwner({ => cancel.token.check() })
        try {
            peerWaitSelection171(f); let expected = peerWaitSeedActualMail171(f, ownerThread)
            let sender = "not-yet-sent-171"
            let admitted = f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions")
            let work = spawn { f.product.vnext.executeDeferredCanonicalTool(ownerThread, f.capabilities(delegate: false),
                peerWaitCall171(f, "cancel-peer-wait-171", sender, 0), owner, cancel.token, budget: f.budget()) }
            var joined = false
            try {
                jobWaitActualDerived166(f, admitted + 1); jobWaitActualExecuting166(f, "cancel-peer-wait-171")
                @Expect(!ProductTaskPersistence(f.database).loadAll()[0].messages[0].consumed)
                let _ = cancel.cancel(); let result = work.get(); joined = true
                match (result) {
                    case Result.Err(_) => ()
                    case Result.Ok(ToolInvocationResult.Completed(value)) => try { @Expect(value.isError) } finally { value.releasePayload() }
                    case Result.Ok(ToolInvocationResult.Denied(_)) => ()
                    case _ => @Expect(false) }
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), admitted + 1)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'") > 0)
                let stored = ProductTaskPersistence(f.database).loadAll()[0].messages[0]
                @Expect(!stored.consumed); @Expect(encodeAgentValue(hubMessageValue(stored.snapshot)), encodeAgentValue(hubMessageValue(expected)))
            } finally { let _ = cancel.cancel(); if (!joined) { let _ = work.get() } }
        } finally { let _ = owner.cancel(); cancel.close(); f.close() }
    }
    @TestCase
    func actualZeroTimeoutPeerWaitOutlivesNativeWatchdogUntilOriginalChildSends171(): Unit {
        let f = WorkflowChildFixture111(asynchronous: true); let probe = JobWaitHeldTool166()
        let owner = SessionId("peer-wait-actual-long-owner-171")
        try {
            peerWaitSelection171(f); jobWaitInstall166(f, probe)
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("actual-late-peer-mail-171", "plugin." + f.namespace + ".hub", objectValue([
                ValueField("op", textValue("send")), ValueField("to", textValue("Main")),
                ValueField("message", textValue("actual late child message 雪")), ValueField("replyTo", textValue("late-171"))]))
            let parent = hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(owner, f.capabilities(),
                childBackgroundCall111(f, owner.value), budget: f.budget()))
            try { @Expect(!parent.isError); expectCanonicalReturnedReceipt(f.database, parent) }
            finally { parent.releasePayload() }
            jobWaitEntered166(probe)
            let jobs = f.product.asyncJobs(owner); @Expect(jobs.size, 1)
            let sender = jobs[0].agentId
            let admitted = f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions")
            let models = f.database.scalarInt("SELECT COUNT(*) FROM model_attempts")
            let finished = AtomicBool(false)
            let work = spawn {
                try { f.product.vnext.executeCanonicalTool(owner, f.capabilities(delegate: false),
                    peerWaitCall171(f, "actual-long-peer-wait-171", sender, 0), budget: f.budget()) }
                finally { finished.store(true) } }
            var joined = false
            try {
                jobWaitActualDerived166(f, admitted + 1); jobWaitActualExecuting166(f, "actual-long-peer-wait-171")
                // Existing Native watchdog is 30 seconds; production retains
                // the canonical Kernel waiter before Native starts. This test
                // stays within the unchanged original sixty-second case cap.
                sleep(Duration.second * 31)
                @Expect(!finished.load()); @Expect(!probe.returned.load()); @Expect(probe.calls.load(), 1)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), models)
                probe.released.store(true)
                let result = hostServiceEntryCompleted(work.get()); joined = true
                try {
                    let roots = ProductTaskPersistence(f.database).loadAll()
                    @Expect(roots.size, 1); @Expect(roots[0].messages.size, 1)
                    @Expect(roots[0].messages[0].consumed)
                    expectPeerWaitOriginalFields171(result, roots[0].messages[0].snapshot)
                    @Expect(httpIntentText(result.output.field("waited").getOrThrow(), "message"), "actual late child message 雪")
                    expectCanonicalReturnedReceipt(f.database, result)
                } finally { result.releasePayload() }
                @Expect(probe.returned.load()); @Expect(probe.calls.load(), 1)
            } finally { probe.released.store(true); if (!joined) { let _ = work.get() } }
        } finally { probe.released.store(true); f.close() }
    }
}
