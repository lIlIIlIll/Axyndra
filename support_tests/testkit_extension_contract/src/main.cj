package testkit_extension_contract

import agent_sdk.*
import ast_extension.*
import yjson.*
import yjson_support.*
import axyndra_agent_testkit.*
import web_search_extension.*
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

    let ast = ExtensionContractHarness(AstExtension())
    let astPrepared = requireSdkOk(ast.prepare(
        "ast_grep",
        jsonObject([JsonObjectEntry("pat", jsonString("$X"))]),
        workspaceRoot: "/workspace",
        cwd: "/workspace",
        callId: "ast-1"
    ))
    assertCapabilityRequested(astPrepared.definition, "workspace.read")
    expect(match (astPrepared.intent) {
        case OperationIntent.HostOperation(value) => value.operation == "ast_grep"
        case _ => false
    }, "AST search prepares an opaque host intent without executor authority")
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
    let web = ExtensionContractHarness(WebSearchExtension())
    let prepared = requireSdkOk(web.prepare(
        "web_search",
        jsonObject([JsonObjectEntry("query", jsonString("cangjie"))]),
        callId: "web-1"
    ))
    assertCapabilityRequested(prepared.definition, "network.http")
    expect(match (prepared.intent) {
        case OperationIntent.HostOperation(value) => value.operation == "web_search"
        case _ => false
    }, "web search prepares a bounded host intent without raw HTTP authority")
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
