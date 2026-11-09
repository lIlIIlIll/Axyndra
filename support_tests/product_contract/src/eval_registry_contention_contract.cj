package product_contract

import agent_domain.*
import agent_product.*
import eval_native_contract.*
import tool_runtime.*
import yjson.*
import yjson_support.*

// The independent Product imports/enables the real package in the same
// workspace while the original persistent service remains idle. Its accepted
// cell then cancels through Application, without lending authority to this
// service. Neither scope may restart a withdrawn generation.
func runEvalRegistryContentionContract204(root: String): Unit {
    let workspace = LocalWorkspace(root)
    let processes = LocalProcessPort(workspace, sandboxEnabled: true)
    let scope = NativeEvalContractScope(root)
    let thread = SessionId("eval-registry-contention")
    let context = ToolInvocationContext(RunId("eval-registry-contention"), thread,
        CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead),
            Capability(CapabilityKind.WorkspaceWrite), Capability(CapabilityKind.ProcessSpawn)]))
    try {
        let first = completedFrom(executeNativeEvalCall(scope, context,
            evalCall("contention-first", "py", "counter = 41\ncounter", reset: true)))
        expect(!first.isError && first.output.field("content").getOrThrow().text.trimAscii() == "41",
            "original installed Python service starts with persistent state")
        let binding = scope.binding("py")
        let starts = binding.count("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.plugin.lifecycle.start'")
        runEvalCancellationContract(workspace, processes)
        let after = completedFrom(executeNativeEvalCall(scope, context,
            evalCall("contention-after", "py", "counter")))
        expect(!after.isError && after.output.field("content").getOrThrow().text.trimAscii() == "41" &&
            binding.visible(thread), "independent Registry writes and cancellation preserve the original service and state")
        let reset = completedFrom(executeNativeEvalCall(scope, context,
            evalCall("contention-reset", "py", "globals().get('counter', 'missing')", reset: true)))
        expect(!reset.isError && reset.output.field("content").getOrThrow().text.trimAscii() == "missing" &&
            starts == 1 && binding.count("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.plugin.lifecycle.start'") == starts,
            "original service resets without an implicit restart or new startup authority")
        let receipts = binding.childReceipts()
        match (binding.product.setPluginEnabled(binding.namespace, false)) {
            case PluginRegistryResult.Ok(record) => record.close()
            case PluginRegistryResult.Err(error) =>
                try { throw IllegalStateException(error.code) } finally { error.close() }
        }
        expect(nativeEvalFailed(binding.call(thread, evalCall("contention-disabled", "py", "42"))) &&
            binding.childReceipts() == receipts,
            "actual disable still rejects the next cell before any child effect")
    } finally {
        scope.close()
        processes.close().value().getOrThrow()
    }
}

func runEvalLanguagesProductContract204(root: String): Unit {
    let scope = NativeEvalContractScope(root)
    let context = ToolInvocationContext(RunId("eval-languages"), SessionId("eval-languages"),
        CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead),
            Capability(CapabilityKind.WorkspaceWrite), Capability(CapabilityKind.ProcessSpawn)]))
    try { runEvalLanguageContracts(scope, context) } finally { scope.close() }
}
