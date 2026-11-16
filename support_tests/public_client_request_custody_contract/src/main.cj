package public_client_request_custody_contract

import agent_core.*
import agent_domain.*
import agent_product.*
import std.env.*
import std.fs.*

private func installNativeWorkspace(product: ProductRuntime): Unit {
    let source = getVariable("AXYNDRA_WORKSPACE_PLUGIN_PACKAGE").getOrThrow()
    match (product.importLocalPlugin(source, PluginInstallScope.Workspace)) {
        case PluginRegistryResult.Ok(record) => record.close()
        case PluginRegistryResult.Err(error) =>
            let code = try { error.code } finally { error.close() }
            throw IllegalStateException("Native import failed: " + code)
    }
    match (product.setPluginEnabled("axyndra:workspace", true, PluginInstallScope.Workspace)) {
        case PluginRegistryResult.Ok(record) => record.close()
        case PluginRegistryResult.Err(error) =>
            let code = try { error.code } finally { error.close() }
            throw IllegalStateException("Native enable failed: " + code)
    }
}

// The outer caller receives only the existing paid owner. No request or Run
// snapshot escapes this complete frame, and no replacement payer is created.
private func completePublicCallerFrame(product: ProductRuntime): PlanRequestCustody204 {
    let request = product.request("Say custody complete.",
        sessionId: Some(SessionId("public-client-request-custody")),
        contextSnapshot: Some(InvocationContextProjection()))
    let owner = match (request.planRequestCustody204) {
        case Some(value) => value
        case None => throw IllegalStateException("Native-backed request has no existing custody")
    }
    match (product.client.start(request, {_ => ()})) {
        case Result.Ok(AgentRunOutcome.Completed(snapshot)) =>
            if (snapshot.status != RunState.Completed) {
                throw IllegalStateException("public client did not complete its Run")
            }
        case Result.Ok(_) => throw IllegalStateException("public client did not return a completed Run")
        case Result.Err(error) => throw IllegalStateException("public client failed: " + error.code)
    }
    if (product.fixtureProbe.getOrThrow().observedCallCount11318() != 1) {
        throw IllegalStateException("the public request must make one real fixture-model call")
    }
    owner
}

main(): Int64 {
    let root = Directory.createTemp("/tmp").toString()
    try {
        Directory.create(root + "/workspace", recursive: true)
        let product = openProduct(config: ProductConfig(
            settingsRoot: root + "/settings", stateRoot: root + "/state",
            workspaceRoot: root + "/workspace", fixture: true, asyncEnabled: false
        )).value().getOrThrow()
        try {
            installNativeWorkspace(product)
            let owner = completePublicCallerFrame(product)
            if (owner.isDataReturned204()) {
                throw IllegalStateException("request DATA returned before the application caller ACK")
            }
            // This ACK follows the actual caller-frame return. It cannot
            // replace accepted Core tasks, output ACK or settlement witnesses.
            owner.returnApplicationFrame204()
            if (!owner.isDataReturned204()) {
                throw IllegalStateException("completed public client retains acknowledged request DATA")
            }
            println("public client request custody contract passed")
            0
        } finally { product.close().value().getOrThrow() }
    } finally { remove(root, recursive: true) }
}