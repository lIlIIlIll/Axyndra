package checkpoint_compaction_contract

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_core.*
import agent_product.*
import std.collection.*
import std.env.*
import std.fs.*

main(): Int64 {
    if (!exists(Path("target"))) { Directory.create("target", recursive: true) }
    let root = Directory.createTemp("target").toString()
    var canRemove = true
    try {
        let workspace = root + "/workspace"
        Directory.create(workspace, recursive: true)
        // The prefix must trigger compaction while the retained checkpoint fits the original target.
        let fixtureInputTokens: Int64 = 24000
        let product = openProduct(config: ProductConfig(
            settingsRoot: root + "/config",
            stateRoot: root + "/state",
            workspaceRoot: workspace,
            fixture: true,
            asyncEnabled: false,
            compactionOverride: Some(ProductCompactionSettings(
                maxInputTokens: fixtureInputTokens,
                triggerPercent: 80,
                targetPercent: 60,
                emergencyMaxMessages: 512,
                keepRecentTokens: 256,
                keepRecentMessages: 4,
                oversizedToolResultTokens: 512
            ))
        )).value().getOrThrow()
        canRemove = false
        try { runCheckpointScenarios(product, fixtureInputTokens) } finally {
            match (product.close()) {
                case Result.Ok(_) => canRemove = true
                case Result.Err(error) => eprintln("checkpoint Product cleanup: " + error.describe())
            }
        }
        expect(canRemove, "Product did not acknowledge cleanup; retained fixture: " + root)
        println("checkpoint compaction contract passed")
        0
    } finally {
        if (canRemove) { let _ = removeIfExists(root, recursive: true) }
    }
}

private func runCheckpointScenarios(product: ProductRuntime, fixtureInputTokens: Int64): Unit {
    installCompactionProvider(product)
    expect(estimateContextTokens([], tools: product.tools()) + 1024 < fixtureInputTokens * 60 / 100,
        "positive checkpoint fixture leaves room for protocol after the actual frozen tools")

    let preserved = SessionId("active-checkpoint-preserved")
    let preservedMessages = ArrayList<ModelMessage>()
    let prefix = repeated("x", 5000)
    for (index in 0..16) {
        preservedMessages.add(textMessage(
            "prefix-" + index.toString() + " " + prefix
        ))
    }
    expect(estimateMessagesTokens(preservedMessages.toArray()) >= fixtureInputTokens * 80 / 100,
        "the prefix alone must cross the unforced compaction trigger")
    product.replaceMessages(preserved, preservedMessages.toArray()).value().getOrThrow()
    let preservedId = createActiveCheckpoint(product, preserved)
    product.appendExternalMessageOnce(preserved, "small-exploration", textMessage("small active exploration")).value().getOrThrow()
    let removed = match (product.compactSession(preserved, force: false)) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException("checkpoint compaction failed: " + error.describe())
    }
    expect(removed > 0, "compaction must remove old messages")
    let preservedApplication = product.applicationSession(sessionId: Some(preserved))
    preservedApplication.setAutoCompaction(false)
    preservedApplication.handle("checkpoint projection probe").value().getOrThrow()
    let compacted = product.fixtureProbe.getOrThrow().lastRequest
        .getOrThrow().messages
    expect(hasCheckpointCall(compacted, preservedId), "projected request lost its checkpoint call")
    expect(hasCheckpointResult(compacted, preservedId), "projected request lost its checkpoint result")
    let rewind = match (product.invokeLocalTool(preserved, "plugin.axyndra:compaction.rewind",
        objectValue([ValueField("report", textValue("bounded findings"))]))) {
        case Result.Ok(result) => result
        case Result.Err(error) => throw IllegalStateException("rewind after compaction: " + error.describe())
    }
    try { expect(!rewind.isError, "rewind must consume the preserved checkpoint") }
    finally { rewind.releasePayload() }

    let reported = SessionId("checkpoint-report-projection")
    let reportedMessages = ArrayList<ModelMessage>()
    let reportPrefix = repeated("z", 5000)
    for (index in 0..20) {
        reportedMessages.add(textMessage(
            "report-prefix-" + index.toString() + " " + reportPrefix
        ))
    }
    product.replaceMessages(reported, reportedMessages.toArray()).value().getOrThrow()
    let firstReport = product.compactSessionReport(reported, force: false).value().getOrThrow()
    let _ = product.appendExternalMessageOnce(
        reported,
        "report-followup-1",
        textMessage("report follow-up one")
    ).value().getOrThrow()
    let _ = product.appendExternalMessageOnce(
        reported,
        "report-followup-2",
        textMessage("report follow-up two")
    ).value().getOrThrow()
    let secondReport = product.compactSessionReport(reported).value().getOrThrow()
    expect(
        firstReport.removedMessages > 0 && secondReport.removedMessages > 0 &&
        secondReport.beforeTokens < firstReport.beforeTokens &&
        secondReport.afterTokens <= secondReport.beforeTokens,
        "repeated compaction reports the active projected context before compaction"
    )

    let blocked = SessionId("active-checkpoint-too-large")
    product.replaceMessages(blocked, [textMessage("checkpoint setup")]).value().getOrThrow()
    let blockedId = createActiveCheckpoint(product, blocked)
    let branch = repeated("y", 5000)
    for (index in 0..16) {
        let name = "active-branch-" + index.toString()
        product.appendExternalMessageOnce(blocked, name, textMessage(name + " " + branch)).value().getOrThrow()
    }
    let before = product.messages(blocked).value().getOrThrow()
    let denied = product.compactSession(blocked, force: false)
    let after = product.messages(blocked).value().getOrThrow()
    expect(
        match (denied) {
            case Result.Err(error) => error.code == "session.compaction_checkpoint_active"
            case Result.Ok(_) => false
        } && after.size == before.size &&
        hasCheckpointCall(after, blockedId) &&
        hasCheckpointResult(after, blockedId),
        "an oversized active branch fails explicitly without orphaning its checkpoint"
    )
}

private func installCompactionProvider(product: ProductRuntime): Unit {
    let namespace = "axyndra:compaction"
    let record = match (product.importLocalPlugin(getVariable("AXYNDRA_COMPACTION_PLUGIN_PACKAGE").getOrThrow())) {
        case PluginRegistryResult.Ok(value) => value
        case PluginRegistryResult.Err(error) =>
            let code = error.code; error.close(); throw IllegalStateException("compaction import: " + code)
    }
    try {
        expect(record.descriptor.textEquals(PluginDescriptorText.Namespace, namespace), "expected the Compaction package")
        let digest = match (record.descriptor.copyText(PluginDescriptorText.ContentDigest)) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) =>
                let code = error.code; error.close(); throw IllegalStateException("compaction digest: " + code)
        }
        try {
            expect(digest.byteCount == 71, "expected a sha256 package digest")
            let paid = digest.deriveCopiedDataPayment(65536 + digest.byteCount * 256)
            try { writeCompactionSelections(product.settingsRoot, namespace, digest) } finally { paid.close() }
        } finally { digest.close() }
    } finally { record.close() }
    match (product.setPluginEnabled(namespace, true)) {
        case PluginRegistryResult.Ok(enabled) => enabled.close()
        case PluginRegistryResult.Err(error) =>
            let code = error.code; error.close(); throw IllegalStateException("compaction enable: " + code)
    }
}

private func writeCompactionSelections(settings: String, namespace: String, source: OwnedRegistryUtf8): Unit {
    let digest = String.fromUtf8(Array<UInt8>(source.byteCount, { i => source.byteAt(i) }))
    let policy = objectValue([ValueField("version", integerValue(1)), ValueField("bindings", objectValue([
        ValueField("compaction", objectValue([ValueField("namespace", textValue(namespace)),
            ValueField("provider", textValue("summarize")), ValueField("package_digest", textValue(digest))]))]))])
    let tools = ["checkpoint", "rewind"].map { name => objectValue([
        ValueField("name", textValue(name)), ValueField("provider", textValue("summarize")),
        ValueField("action", textValue("canonical.context.project")), ValueField("capability", textValue("workspace.read")),
        ValueField("effect", textValue("read_only"))]) }
    let grants = objectValue([ValueField("version", integerValue(1)), ValueField("plugins", listValue([
        objectValue([ValueField("namespace", textValue(namespace)), ValueField("package_digest", textValue(digest)),
            ValueField("tools", listValue(tools))])]))])
    for ((file, value) in [("policies.json", policy), ("canonical-data.json", grants)]) {
        let path = Path(settings).join("plugins").join(file)
        expect(!exists(path), "fixture must not replace an existing Compaction selection")
        File.writeTo(path, stringifyUnifiedJson(value).toArray())
    }
}

private func createActiveCheckpoint(product: ProductRuntime, session: SessionId): String {
    let name = "plugin.axyndra:compaction.checkpoint"
    let result = match (product.invokeLocalTool(session, name, objectValue([
        ValueField("goal", textValue("retain active exploration"))]))) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException("create checkpoint: " + error.describe())
    }
    try { expect(!result.isError, "installed checkpoint must succeed") } finally { result.releasePayload() }
    // Re-read the canonical call rather than retaining DATA from the returned result.
    let messages = product.messages(session).value().getOrThrow()
    for (message in messages) {
        for (block in message.blocks where block.kind == ModelBlockKind.ToolCall && block.name == name) {
            expect(hasCheckpointResult(messages, block.callId), "checkpoint must have a successful matching result")
            return block.callId
        }
    }
    throw IllegalStateException("installed checkpoint did not persist its call")
}

func textMessage(value: String): ModelMessage {
    ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: value)])
}

func repeated(value: String, count: Int64): String {
    let result = StringBuilder()
    for (_ in 0..count) { result.append(value) }
    result.toString()
}

func hasCheckpointCall(messages: Array<ModelMessage>, callId: String): Bool {
    for (message in messages) {
        for (block in message.blocks where block.kind == ModelBlockKind.ToolCall &&
             block.name == "plugin.axyndra:compaction.checkpoint" && block.callId == callId) { return true }
    }
    false
}

func hasCheckpointResult(messages: Array<ModelMessage>, callId: String): Bool {
    for (message in messages) {
        for (block in message.blocks where block.kind == ModelBlockKind.ToolResult &&
             block.name == "plugin.axyndra:compaction.checkpoint" && block.callId == callId && !block.isError) { return true }
    }
    false
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
