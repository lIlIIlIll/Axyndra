package agent_rpc

import agent_core.*
import agent_domain.*
import agent_product.*
import tool_runtime.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// This deliberately is an ordinary callback, not a physical StdOut witness.
// It holds the real RPC worker inside its final callback to distinguish a
// completed operation from the complete invocation/Future having returned.
private class RpcWorkerFrameGate113 {
    let entered = AtomicBool(false)
    let released = AtomicBool(false)
    let armed = AtomicBool(false)
    let marker: String
    init(marker: String) { this.marker = marker }
    func emit(frame: String): Unit {
        if (!armed.load() || !frame.contains(marker)) { return }
        entered.store(true)
        let deadline = MonoTime.now() + Duration.second * 5
        while (!released.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 2) }
        if (!released.load()) { throw IllegalStateException("rpc worker fixture callback did not retire") }
    }
}

private class RpcWorkerActualTool113 <: ToolExecutor {
    let calls = AtomicInt64(0)
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        calls.fetchAdd(1)
        Result.Ok(ToolResult(prepared.call.callId, textValue("real approved worker result")))
    }
}

private func rpcWorkerWait113(condition: () -> Bool): Bool {
    let deadline = MonoTime.now() + Duration.second * 5
    while (!condition() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 2) }
    condition()
}

private func rpcWorkerRoot113(): String {
    if (!exists(Path("target"))) { Directory.create("target", recursive: true) }
    Directory.createTemp("target").toString()
}

@Test
class ActualRpcWorkerRetirement113Tests {
    @TestCase
    func alreadyAcceptedFollowUpDrainsOnceBeforeOriginalWorkerRetirement(): Unit {
        let root = rpcWorkerRoot113()
        let product = openProduct(config: ProductConfig(workspaceRoot: root,
            settingsRoot: root + "/settings", stateRoot: root + "/state", fixture: true,
            asyncEnabled: false, approvalMode: ApprovalMode.Yolo)).value().getOrThrow()
        let session = product.applicationSession()
        let gate = RpcWorkerFrameGate113("\"type\":\"prompt_result\"")
        let server = ProductJsonlRpcServer(session, { frame => gate.emit(frame) })
        gate.armed.store(true)
        let first = spawn { server.handle("{\"id\":\"first\",\"type\":\"prompt\",\"message\":\"hello original accepted turn\"}") }
        try {
            @Expect(rpcWorkerWait113({ => gate.entered.load() }))
            let firstCalls = product.fixtureProbe.getOrThrow().observedCallCount11318()
            let queued = spawn { server.handle("{\"id\":\"queued\",\"type\":\"follow_up\",\"message\":\"hello already accepted follow up\"}") }
            try {
                // Real queue admission occurs before its response obtains the
                // output lock held by the original worker's callback.
                @Expect(rpcWorkerWait113({ => session.queuedCount() == 1 }))
                server.beginRunWorkerShutdown113()
                @Expect(server.collectRunWorkerRetirement113(), false)
                gate.released.store(true)
                @Expect(first.get().contains("\"success\":true"))
                @Expect(queued.get().contains("\"success\":true"))
                @Expect(rpcWorkerWait113({ => server.collectRunWorkerRetirement113() }))
                @Expect(session.queuedCount(), 0)
                @Expect(product.fixtureProbe.getOrThrow().observedCallCount11318(), firstCalls + 1)
            } finally { gate.released.store(true); let _ = queued.get() }
        } finally {
            gate.released.store(true)
            let _ = first.get()
            server.close()
            product.close().value().getOrThrow()
            remove(root, recursive: true)
        }
    }

    @TestCase
    func actualPromptFinalCallbackMustReturnBeforeShutdownReportsRetired(): Unit {
        let root = rpcWorkerRoot113()
        let product = openProduct(config: ProductConfig(workspaceRoot: root,
            settingsRoot: root + "/settings", stateRoot: root + "/state", fixture: true,
            asyncEnabled: false, approvalMode: ApprovalMode.Yolo)).value().getOrThrow()
        let gate = RpcWorkerFrameGate113("\"type\":\"prompt_result\"")
        let server = ProductJsonlRpcServer(product.applicationSession(), { frame => gate.emit(frame) })
        gate.armed.store(true)
        let request = spawn { server.handle("{\"id\":\"worker-prompt\",\"type\":\"prompt\",\"message\":\"hello worker boundary\"}") }
        try {
            @Expect(rpcWorkerWait113({ => gate.entered.load() }))
            server.beginRunWorkerShutdown113()
            // A complete business result already reached its output callback.
            // Neither that fact nor closing retires the physical worker.
            @Expect(server.collectRunWorkerRetirement113(), false)
            let count = product.fixtureProbe.getOrThrow().observedCallCount11318()
            @Expect(count > 0)
            gate.released.store(true)
            @Expect(request.get().contains("\"success\":true"))
            @Expect(rpcWorkerWait113({ => server.collectRunWorkerRetirement113() }))
            @Expect(server.handle("{\"id\":\"late\",\"type\":\"prompt\",\"message\":\"must not start\"}").contains("\"success\":false"))
            @Expect(server.handle("{\"id\":\"late-queue\",\"type\":\"prompt\",\"streamingBehavior\":\"followUp\",\"message\":\"must not queue\"}").contains("\"success\":false"))
            @Expect(product.fixtureProbe.getOrThrow().observedCallCount11318(), count)
        } finally {
            gate.released.store(true)
            let _ = request.get()
            server.close()
            product.close().value().getOrThrow()
            remove(root, recursive: true)
        }
    }

    @TestCase
    func actualApprovedDecisionCallbackCannotAuthorizeEarlyProductCleanupOrSecondExecution(): Unit {
        let root = rpcWorkerRoot113()
        let product = openProduct(config: ProductConfig(workspaceRoot: root,
            settingsRoot: root + "/settings", stateRoot: root + "/state", fixture: true,
            asyncEnabled: false, approvalMode: ApprovalMode.AlwaysAsk)).value().getOrThrow()
        let executor = RpcWorkerActualTool113()
        @Expect(product.registerTool(ToolDescriptor(ModelToolDefinition("rpc_worker_tool113",
            "Real approved RPC worker boundary", objectValue([
                ValueField("type", textValue("object")), ValueField("properties", objectValue([]))])),
            Capability(CapabilityKind.WorkspaceWrite), sideEffecting: true,
            implementationVersion: "rpc113", implementationFingerprint: "rpc113"), executor).isOk())
        let session = product.applicationSession()
        let gate = RpcWorkerFrameGate113("\"code\":\"tool.execution_completed\"")
        let server = ProductJsonlRpcServer(session, { frame => gate.emit(frame) })
        product.fixtureProbe.getOrThrow().enqueueToolCallReply("rpc-worker-call113", "rpc_worker_tool113", objectValue([]))
        try {
            @Expect(server.handle("{\"id\":\"ask\",\"type\":\"prompt\",\"message\":\"perform the actual approved fixture tool\"}").contains("\"success\":true"))
            @Expect(rpcWorkerWait113({ => session.approval().isSome() }))
            let operation = session.approval().getOrThrow().operationId.value
            @Expect(executor.calls.load(), 0)
            gate.armed.store(true)
            let decision = spawn {
                let deadline = MonoTime.now() + Duration.second * 5
                var answer = ""
                while (MonoTime.now() < deadline) {
                    answer = server.handle("{\"id\":\"approve\",\"type\":\"approve\",\"operationId\":\"" + operation + "\"}")
                    if (answer.contains("\"success\":true")) { break }
                    sleep(Duration.millisecond * 2)
                }
                answer
            }
            try {
                @Expect(rpcWorkerWait113({ => gate.entered.load() }))
                server.beginRunWorkerShutdown113()
                @Expect(executor.calls.load(), 1)
                @Expect(server.collectRunWorkerRetirement113(), false)
                gate.released.store(true)
                @Expect(decision.get().contains("\"success\":true"))
                @Expect(rpcWorkerWait113({ => server.collectRunWorkerRetirement113() }))
                @Expect(executor.calls.load(), 1)
                @Expect(server.handle("{\"id\":\"late-approve\",\"type\":\"approve\",\"operationId\":\"" + operation + "\"}").contains("\"success\":false"))
                @Expect(executor.calls.load(), 1)
            } finally { gate.released.store(true); let _ = decision.get() }
        } finally {
            gate.released.store(true)
            server.close()
            product.close().value().getOrThrow()
            remove(root, recursive: true)
        }
    }
}
