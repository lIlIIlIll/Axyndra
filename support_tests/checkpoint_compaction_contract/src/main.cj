package checkpoint_compaction_contract

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_product.*
import std.collection.*
import std.fs.*

main(): Int64 {
    if (!exists(Path("target"))) { Directory.create("target", recursive: true) }
    let root = Directory.createTemp("target").toString()
    try {
        let workspace = root + "/workspace"
        Directory.create(workspace, recursive: true)
        let product = openProduct(config: ProductConfig(
            settingsRoot: root + "/config",
            stateRoot: root + "/state",
            workspaceRoot: workspace,
            fixture: true,
            asyncEnabled: false,
            compactionOverride: Some(ProductCompactionSettings(
                maxInputTokens: 20000,
                triggerPercent: 80,
                targetPercent: 60,
                emergencyMaxMessages: 512,
                keepRecentTokens: 256,
                keepRecentMessages: 4,
                oversizedToolResultTokens: 512
            ))
        )).value().getOrThrow()

        let preserved = SessionId("active-checkpoint-preserved")
        let preservedMessages = ArrayList<ModelMessage>()
        for (index in 0..12) {
            preservedMessages.add(textMessage(
                "prefix-" + index.toString() + " " + repeated("x", 5000)
            ))
        }
        preservedMessages.add(checkpointCall("checkpoint-preserved"))
        preservedMessages.add(checkpointResult("checkpoint-preserved"))
        preservedMessages.add(textMessage("small active exploration"))
        product.replaceMessages(preserved, preservedMessages.toArray()).value().getOrThrow()
        let removed = product.compactSession(preserved, force: false).value().getOrThrow()
        let preservedApplication = product.applicationSession(sessionId: Some(preserved))
        preservedApplication.setAutoCompaction(false)
        preservedApplication.handle("checkpoint projection probe").value().getOrThrow()
        let compacted = product.fixtureProbe.getOrThrow().lastRequest
            .getOrThrow().messages
        expect(
            removed > 0 && hasCheckpointCall(compacted, "checkpoint-preserved") &&
            hasCheckpointResult(compacted, "checkpoint-preserved") &&
            product.invokeLocalTool(
                preserved,
                "rewind",
                objectValue([ValueField("report", textValue("bounded findings"))])
            ).isOk(),
            "compaction preserves the complete active checkpoint protocol and rewind state"
        )

        let blocked = SessionId("active-checkpoint-too-large")
        let blockedMessages = ArrayList<ModelMessage>()
        blockedMessages.add(textMessage("checkpoint setup"))
        blockedMessages.add(checkpointCall("checkpoint-blocked"))
        blockedMessages.add(checkpointResult("checkpoint-blocked"))
        for (index in 0..16) {
            blockedMessages.add(textMessage(
                "active-branch-" + index.toString() + " " + repeated("y", 5000)
            ))
        }
        product.replaceMessages(blocked, blockedMessages.toArray()).value().getOrThrow()
        let before = product.messages(blocked).value().getOrThrow()
        let denied = product.compactSession(blocked, force: false)
        let after = product.messages(blocked).value().getOrThrow()
        expect(
            match (denied) {
                case Result.Err(error) => error.code == "session.compaction_checkpoint_active"
                case Result.Ok(_) => false
            } && after.size == before.size &&
            hasCheckpointCall(after, "checkpoint-blocked") &&
            hasCheckpointResult(after, "checkpoint-blocked"),
            "an oversized active branch fails explicitly without orphaning its checkpoint"
        )
        product.closeMcp().value().getOrThrow()
        println("checkpoint compaction contract passed")
        0
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

func checkpointCall(callId: String): ModelMessage {
    ModelMessage(ModelRole.Assistant, [ModelBlock(
        ModelBlockKind.ToolCall,
        callId: callId,
        name: "checkpoint",
        arguments: objectValue([ValueField("goal", textValue("retain active exploration"))])
    )])
}

func checkpointResult(callId: String): ModelMessage {
    ModelMessage(ModelRole.User, [ModelBlock(
        ModelBlockKind.ToolResult,
        text: "Checkpoint created.",
        callId: callId,
        name: "checkpoint",
        arguments: objectValue([
            ValueField("goal", textValue("retain active exploration")),
            ValueField("started_at", textValue("2026-08-10T00:00:00Z"))
        ])
    )])
}

func textMessage(value: String): ModelMessage {
    ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: value)])
}

func repeated(value: String, count: Int64): String {
    var result = ""
    for (_ in 0..count) { result += value }
    result
}

func hasCheckpointCall(messages: Array<ModelMessage>, callId: String): Bool {
    for (message in messages) {
        for (block in message.blocks where block.kind == ModelBlockKind.ToolCall &&
             block.name == "checkpoint" && block.callId == callId) { return true }
    }
    false
}

func hasCheckpointResult(messages: Array<ModelMessage>, callId: String): Bool {
    for (message in messages) {
        for (block in message.blocks where block.kind == ModelBlockKind.ToolResult &&
             block.name == "checkpoint" && block.callId == callId) { return true }
    }
    false
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
