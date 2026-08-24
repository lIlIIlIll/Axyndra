package handoff_request_contract

import agent_domain.*
import agent_product.*
import std.fs.*
import tool_runtime.*

main(): Int64 {
    if (!exists(Path("target"))) {
        Directory.create("target", recursive: true)
    }
    let root = Directory.createTemp("target").toString()
    try {
        let product = openProduct(config: ProductConfig(
            stateRoot: root + "/state",
            workspaceRoot: root,
            fixture: true,
            approvalMode: ApprovalMode.Yolo,
            asyncEnabled: false
        )).value().getOrThrow()
        let application = product.applicationSession()
        expect(
            application.handle("handoff source prompt").isOk(),
            "source turn completes"
        )
        let response = application
            .handle("/handoff retain protocol state")
            .value()
            .getOrThrow()
        let request = match (product.fixtureProbe) {
            case Some(probe) => probe.lastRequest.getOrThrow()
            case None => throw IllegalStateException("fixture probe is missing")
        }

        expect(response.agentInvoked, "handoff uses the model")
        expect(
            request.system.contains("Return only the document and do not call tools."),
            "handoff system override reaches the provider"
        )
        expect(
            request.cachePolicy == ModelCachePolicy.StablePrefix &&
                request.cacheKey != "",
            "handoff preserves stable-prefix cache protocol"
        )
        expect(
            request.parallelToolCalls,
            "handoff preserves provider parallel-tool capability"
        )
        expect(
            !request.tools.isEmpty(),
            "handoff preserves the base capability-derived tool protocol"
        )
        println("handoff request contract passed")
        0
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) {
        throw IllegalStateException(message)
    }
}
