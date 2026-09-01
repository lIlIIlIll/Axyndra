package subagent_product_contract

import agent_domain.*
import agent_product.*
import tool_runtime.*
import yjson.JsonNode
import yjson_support.*
import std.collection.*
import std.fs.*

main(): Int64 {
    if (!exists(Path("target"))) { Directory.create("target", recursive: true) }
    let root = Directory.createTemp("target").toString()
    try {
        Directory.create(root + "/workspace", recursive: true)
        let product = openProduct(config: ProductConfig(
            settingsRoot: root + "/config",
            stateRoot: root + "/state",
            workspaceRoot: root + "/workspace",
            fixture: true,
            approvalMode: ApprovalMode.Yolo,
            asyncEnabled: false
        )).value().getOrThrow()
        let application = product.applicationSession()
        let capturedChildRequests = ArrayList<ModelRequest>()
        application.subscribeSubagents({ event =>
            if (event.kind == "lifecycle" && event.snapshot.id == "fixture-child" &&
                event.snapshot.status == "completed") {
                match (product.fixtureProbe) {
                    case Some(probe) => match (probe.lastRequest) {
                        case Some(request) => capturedChildRequests.add(request)
                        case None => ()
                    }
                    case None => ()
                }
            }
        })
        let turn = match (application.handle("fixture task")) {
            case Result.Ok(value) => value
            case Result.Err(error) => throw IllegalStateException(
                "fixture task failed: " + error.describe()
            )
        }
        let records = application.allSubagents()
        let transcript = match (application.subagentTranscript(
            subagentId: "fixture-child"
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => throw IllegalStateException(
                "fixture child transcript failed: " + error.describe() +
                    "; parent_tool_calls=" + toolCalls(application) +
                    "; parent_tool_results=" + toolResults(application)
            )
        }
        if (!turn.agentInvoked || records.size != 1 ||
            records[0].id != "fixture-child" ||
            records[0].status != "completed" || transcript.messages.size < 4) {
            throw IllegalStateException(
                "subagent product state mismatch: invoked=" +
                    turn.agentInvoked.toString() + ",records=" +
                    records.size.toString() + ",messages=" +
                    transcript.messages.size.toString() +
                    ",parent_tool_results=" + toolResults(application)
            )
        }
        let childRequest = if (capturedChildRequests.isEmpty()) {
            throw IllegalStateException(
                "fixture child request was not observable at child completion"
            )
        } else {
            capturedChildRequests[capturedChildRequests.size - 1]
        }
        if (!isFixtureChildRequest(childRequest) ||
            !childRequest.parallelToolCalls ||
            childRequest.cachePolicy != ModelCachePolicy.StablePrefix ||
            childRequest.cacheKey.trimAscii() == "" ||
            !childRequest.system.contains(
                "<prompt_section kind=\"base\" trust=\"system\" stability=\"stable\" " +
                    "source=\"axyndra-subagent-reviewer\""
            ) ||
            !childRequest.system.contains(
                "<untrusted_data kind=\"dynamic_context\" trust=\"external\" stability=\"turn\" " +
                    "source=\"delegated-task-context\""
            ) ||
            !childRequest.system.contains("single child fixture context") ||
            hasTool(childRequest, "write") || hasTool(childRequest, "edit") ||
            hasTool(childRequest, "github") || hasTool(childRequest, "bash")) {
            throw IllegalStateException(
                "subagent request protocol mismatch: child=" +
                    isFixtureChildRequest(childRequest).toString() +
                    ",parallel=" + childRequest.parallelToolCalls.toString() +
                    ",cache_stable=" +
                    (childRequest.cachePolicy == ModelCachePolicy.StablePrefix).toString() +
                    ",cache_key=" + childRequest.cacheKey +
                    ",system=" + childRequest.system
            )
        }
        product.closeMcp().value().getOrThrow()
        println("subagent product contract passed")
        0
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

func hasTool(request: ModelRequest, name: String): Bool {
    for (tool in request.tools where tool.name == name) { return true }
    false
}

func isFixtureChildRequest(request: ModelRequest): Bool {
    if (!request.system.contains("You are the reviewer delegated agent.")) {
        return false
    }
    for (message in request.messages where message.role == ModelRole.User) {
        for (block in message.blocks where block.kind == ModelBlockKind.Text &&
            block.text == "child fixture yield") {
            return true
        }
    }
    false
}

func toolCalls(application: ApplicationSession): String {
    let messages = application.messages().value().getOrThrow()
    var result = ""
    for (message in messages) {
        for (block in message.blocks where block.kind == ModelBlockKind.ToolCall) {
            if (result != "") { result += " | " }
            let context = match (block.arguments.field("context")) {
                case Some(value) => value.text
                case None => "<missing>"
            }
            let tasks = match (block.arguments.field("tasks")) {
                case Some(value) => value.items.size.toString()
                case None => "<missing>"
            }
            result += block.name + ":context=" + context + ":tasks=" + tasks
        }
    }
    result
}

func toolResults(application: ApplicationSession): String {
    let messages = application.messages().value().getOrThrow()
    var result = ""
    for (message in messages) {
        for (block in message.blocks where block.kind == ModelBlockKind.ToolResult) {
            if (result != "") { result += " | " }
            let error = match (block.arguments.field("error")) {
                case Some(value) => value.text
                case None => ""
            }
            result += block.name + ":is_error=" + block.isError.toString() +
                ":text=" + block.text + ":error=" + error
        }
    }
    result
}
