package testkit_extension_contract

import agent_sdk.*
import legacy_extension_sdk.*
import yjson.*
import yjson_support.*
import legacy_extension_testkit.*
import workspace_search_extension.*
import workspace_write_extension.*

main(): Int64 {
    readOnlyContracts()
    sideEffectContract()
    networkContract()
    cancellationAndDeadlineContract()
    println("public agent testkit extension contract passed")
    0
}

func readOnlyContracts(): Unit {
    let search = ExtensionContractHarness(WorkspaceSearchExtension())
    let prepared = requireSdkOk(search.prepare(
        "grep",
        jsonObject([JsonObjectEntry("pattern", jsonString("needle"))]),
        workspaceRoot: "/workspace",
        cwd: "/workspace",
        callId: "search-1"
    ))
    assertCapabilityRequested(prepared.definition, "workspace.read")
    expect(match (prepared.intent) {
        case OperationIntent.WorkspaceSearch(_) => true
        case _ => false
    }, "workspace search prepares a read intent")

}

func sideEffectContract(): Unit {
    let write = ExtensionContractHarness(WorkspaceWriteExtension())
    let prepared = requireSdkOk(write.prepare(
        "write",
        jsonObject([
            JsonObjectEntry("path", jsonString("notes/testkit.txt")),
            JsonObjectEntry("content", jsonString("safe"))
        ]),
        workspaceRoot: "/workspace",
        cwd: "/workspace",
        callId: "write-1"
    ))
    assertCapabilityRequested(prepared.definition, "workspace.write")
    expect(prepared.definition.effect == ExtensionEffect.SideEffect,
        "write remains explicitly side-effecting")
    expect(match (prepared.intent) {
        case OperationIntent.WorkspaceWrite(value) => value.path == "notes/testkit.txt"
        case _ => false
    }, "write harness observes only an untrusted intent")
}

func networkContract(): Unit {
    let network = ExtensionContractHarness(NetworkContractExtension())
    let prepared = requireSdkOk(network.prepare(
        "network_probe",
        jsonObject([JsonObjectEntry("value", jsonString("fixture"))]),
        callId: "network-1"
    ))
    assertCapabilityRequested(prepared.definition, "network.http")
    expect(match (prepared.intent) {
        case OperationIntent.HostOperation(value) => value.operation == "network_probe"
        case _ => false
    }, "SDK fixture prepares an untrusted intent without raw HTTP authority")
}

class NetworkContractExtension <: Extension {
    public func metadata(): ExtensionMetadata {
        ExtensionMetadata("contract.network", "Network contract", "1.0.0", "Generic network fixture.")
    }
    public func tools(): Array<ExtensionTool> { [NetworkContractTool()] }
}

class NetworkContractTool <: ExtensionTool {
    public func definition(): ExtensionToolDefinition {
        ExtensionToolDefinition("network_probe", "Generic network fixture.", jsonObject([]),
            [networkHttp(resource: "network_probe")])
    }
    public func validate(input: JsonNode): SdkResult<JsonNode> { SdkResult.Ok(input) }
    public func prepare(invocation: ToolInvocation): SdkResult<OperationIntent> {
        SdkResult.Ok(OperationIntent.HostOperation(HostOperationIntent("network_probe", invocation.input)))
    }
    public func decode(_invocation: ToolInvocation, result: ExecutionResult): SdkResult<ToolOutput> {
        SdkResult.Ok(ToolOutput(structured: result.value))
    }
}

func cancellationAndDeadlineContract(): Unit {
    let cancellation = ManualCancellation()
    expect(cancellation.cancel(reason: "test cancellation"), "first cancellation wins")
    let clock = ManualClock(initialMillis: 100)
    let search = ExtensionContractHarness(WorkspaceSearchExtension())
    expect(search.prepare(
        "grep",
        jsonObject([JsonObjectEntry("pattern", jsonString("x"))]),
        cancellation: cancellation
    ).isOk() == false, "cancelled SDK invocation fails before intent preparation")
    let prepared = requireSdkOk(search.prepare(
        "grep",
        jsonObject([JsonObjectEntry("pattern", jsonString("x"))]),
        deadline: clock.deadlineAfter(10)
    ))
    expect(!prepared.invocation.deadline.exceeded(clock.nowMillis()), "deadline begins before expiry")
    clock.advance(10)
    expect(prepared.invocation.deadline.exceeded(clock.nowMillis()), "deadline advances deterministically")
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
