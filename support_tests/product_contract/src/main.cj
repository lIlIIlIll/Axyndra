package product_contract

import yjson_support.*

import yjson.*

import agent_core.*
import agent_domain.*
import agent_product.*
import agent_ports.*
import agent_store.*
import agent_testkit.*
import model_adapters.*
import persistence_runtime.*
import tool_runtime.*
import std.collection.*
import std.env.*
import std.fs.*
import std.process.*
import std.time.*

main(): Int64 {
    if (!exists(Path("target"))) {
        Directory.create("target", recursive: true)
    }
    let root = Directory.createTemp("target").toString()
    try {
        runProductIdContracts()
        if (getVariable("AXYNDRA_PRODUCT_CONTRACT_SCOPE") == Some("finalization")) {
            runApplicationResponseProjectionOnly(root)
            runHybridCompactionSummaryContracts(root)
            println("product finalization contract passed")
            return 0
        }
        if (getVariable("AXYNDRA_PRODUCT_CONTRACT_SCOPE") == Some("checkpoint")) {
            prepareProductContractWorkspace(root)
            let workspace = LocalWorkspace(root)
            let processes = LocalProcessPort(workspace)
            try {
                runCheckpointContracts(workspace, processes)
            } finally {
                processes.close()
            }
            println("product canonical checkpoint contract passed")
            return 0
        }
        if (getVariable("AXYNDRA_PRODUCT_CONTRACT_SCOPE") == Some("session-catalog")) {
            prepareProductContractWorkspace(root)
            runSessionCatalogContracts(root)
            println("product canonical session catalog contract passed")
            return 0
        }
        if (getVariable("AXYNDRA_PRODUCT_CONTRACT_SCOPE") == Some("process-hub")) {
            prepareProductContractWorkspace(root)
            let product = openProduct(
                config: ProductConfig(
                    stateRoot: root + "/focused-process-hub-state",
                    workspaceRoot: root,
                    fixture: true,
                    approvalMode: ApprovalMode.Yolo,
                    asyncEnabled: false
                )
            ).value().getOrThrow()
            try {
                runProcessHubContracts(root, product)
            } finally {
                product.close()
            }
            println("product process hub contract passed")
            return 0
        }
        if (getVariable("AXYNDRA_PRODUCT_CONTRACT_SCOPE") == Some("guarded-async")) {
            prepareProductContractWorkspace(root)
            runGuardedAndAsyncContracts(root)
            println("product guarded and async contract passed")
            return 0
        }
        if (getVariable("AXYNDRA_PRODUCT_CONTRACT_SCOPE") == Some("session-lifecycle")) {
            prepareProductContractWorkspace(root)
            let product = openProduct(config: ProductConfig(
                stateRoot: root + "/state",
                workspaceRoot: root,
                fixture: true,
                approvalMode: ApprovalMode.Yolo,
                asyncEnabled: false
            )).value().getOrThrow()
            try {
                runSessionLifecycleContracts(root, product, product.applicationSession())
            } finally {
                product.close()
            }
            println("product session lifecycle contract passed")
            return 0
        }
        prepareProductContractWorkspace(root)
        runToolContracts(root)
        runWriteApprovalClassificationContracts(root)
        runReadApprovalClassificationContracts(root)
        runApplicationContracts(root)
        runNetworkApprovalProductContracts(root)
        runSessionCatalogContracts(root)
        runAiApprovalContracts(root)
        runApprovalReviewerFailureContracts(root)
        println("product contract passed")
        0
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

func runProductIdContracts(): Unit {
    let first = ProductIds()
    let second = ProductIds()
    let observed = ArrayList<String>()
    for (_ in 0..64) {
        for (value in [first.nextRunId().value, second.nextRunId().value]) {
            expect(value.startsWith("run-") && value.size > 40,
                "product IDs include a time-ordered prefix and random identity")
            for (existing in observed) {
                expect(existing != value,
                    "independent ProductIds generators never share durable identity")
            }
            observed.add(value)
        }
    }
}

func runApplicationResponseProjectionOnly(root: String): Unit {
    let product = openProduct(
        config: ProductConfig(
            stateRoot: root + "/focused-application-response-state",
            workspaceRoot: root,
            fixture: true,
            approvalMode: ApprovalMode.Yolo,
            asyncEnabled: false
        )
    ).value().getOrThrow()
    let projected = product
        .applicationSession()
        .handle("application response projection")
        .value()
        .getOrThrow()
    expect(
        projected.text == "fixture response for application response projection" &&
            !projected.text.contains("end_turn") && match (projected.snapshot) {
                case Some(value) => value.summary == "end_turn"
                case None => false
            },
        "application response projects assistant content while preserving stop metadata"
    )
}

func runNetworkApprovalProductContracts(root: String): Unit {
    let enabled = openProduct(config: ProductConfig(
        settingsRoot: root + "/config",
        stateRoot: root + "/network-approval-enabled-state",
        workspaceRoot: root,
        fixture: true,
        approvalMode: ApprovalMode.AlwaysAsk,
        asyncEnabled: false
    )).value().getOrThrow()
    expect(
        enabled.registerTool(
            ToolDescriptor(
                ModelToolDefinition(
                    "network_policy_contract",
                    "network policy fixture",
                    objectValue([ValueField("type", textValue("object"))])
                ),
                Capability(CapabilityKind.NetworkAccess)
            ),
            NetworkContractTool()
        ).isOk(),
        "register network approval fixture"
    )
    let required = enabled.invokeLocalTool(
        SessionId("network-approval-enabled"),
        "network_policy_contract",
        objectValue([])
    )
    let disabledSettings = root + "/network-approval-disabled"
    Directory.create(disabledSettings, recursive: true)
    File.writeTo(
        disabledSettings + "/config.yml",
        ("approval:\n" + "  policy:\n" +
            "    ask_on_network: false\n").toArray()
    )
    let disabled = openProduct(config: ProductConfig(
        settingsRoot: disabledSettings,
        stateRoot: root + "/network-approval-disabled-state",
        workspaceRoot: root,
        fixture: true,
        approvalMode: ApprovalMode.AlwaysAsk,
        asyncEnabled: false
    )).value().getOrThrow()
    expect(
        disabled.registerTool(
            ToolDescriptor(
                ModelToolDefinition(
                    "network_policy_contract",
                    "network policy fixture",
                    objectValue([ValueField("type", textValue("object"))])
                ),
                Capability(CapabilityKind.NetworkAccess)
            ),
            NetworkContractTool()
        ).isOk(),
        "register disabled network approval fixture"
    )
    let allowed = disabled.invokeLocalTool(
        SessionId("network-approval-disabled"),
        "network_policy_contract",
        objectValue([])
    )
    expect(
        match (required) {
            case Result.Err(error) => error.code ==
                "cli.tool_approval_required"
            case _ => false
        } && match (allowed) {
            case Result.Ok(result) => result.output.text == "network-ok"
            case _ => false
        },
        "openProduct wires ask_on_network into network-only approval policy"
    )
}

func runSessionCatalogContracts(root: String): Unit {
    let stateRoot = root + "/session-catalog-state"
    let product = openProduct(
        config: ProductConfig(
            stateRoot: stateRoot,
            workspaceRoot: root,
            fixture: true,
            asyncEnabled: false
        )
    ).value().getOrThrow()
    let parent = SessionId("catalog-parent")
    let child = SessionId("catalog-child")
    var longTail = ""
    for (_ in 0..180) {
        longTail += "界"
    }
    product.replaceMessages(
        parent,
        [
            ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: "/help")]),
            ModelMessage(ModelRole.User,
                [ModelBlock(ModelBlockKind.Text,
                    text: "Build a safe session catalogue Authorization: Bearer secret-value " + longTail)])
        ]
    ).value().getOrThrow()
    product
        .replaceMessages(child,
            [ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: "Review the child branch")])])
        .value()
        .getOrThrow()
    product.setSessionName(parent, "Catalogue work").value().getOrThrow()
    product.setSessionParent(child, product.sessionReference(parent)).value().getOrThrow()
    product.refreshSessionIndex(parent).value().getOrThrow()
    product.refreshSessionIndex(child).value().getOrThrow()
    let parentInfo = product.sessionInfo(parent).value().getOrThrow()
    let childInfo = product.sessionInfo(child).value().getOrThrow()
    expect(
        parentInfo.name == "Catalogue work" && parentInfo.summary.startsWith("Build a safe session catalogue") &&
            parentInfo.summary.contains("[REDACTED]") && !parentInfo.summary.contains("secret-value") &&
            parentInfo.summary.toRuneArray().size <= 160 && parentInfo.updatedAt > 0 && childInfo.parentId == parent
            .value,
        "session catalogue persists a bounded redacted summary, activity time, and branch parent"
    )
    expect(product.replaceMessages(parent, [ModelMessage(
        ModelRole.User,
        [ModelBlock(ModelBlockKind.Text, text: "A later request must not replace canonical history")]
    )]).isError(), "canonical Thread seed is create-only")
    product.refreshSessionIndex(parent).value().getOrThrow()
    expect(
        product.sessionInfo(parent).value().getOrThrow().summary == parentInfo.summary,
        "session catalogue keeps the first meaningful request as its stable summary"
    )
    let cached = SessionId("catalog-cached")
    product
        .replaceMessages(cached,
            [ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: "Cached selector summary")])])
        .value()
        .getOrThrow()
    product.refreshSessionIndex(cached).value().getOrThrow()
    expect(
        product.sessionInfo(cached).value().getOrThrow().summary == "Cached selector summary",
        "indexed session details are projected from canonical Thread Items"
    )
    let prefix = SessionId("catalog-prefix")
    product
        .replaceMessages(prefix,
            [ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: "Prefix-only migration")])])
        .value()
        .getOrThrow()
    expect(
        product.sessionInfo(prefix).value().getOrThrow().summary == "Prefix-only migration",
        "session summary reads the canonical Thread prefix"
    )
    product.archiveSession(child).value().getOrThrow()
    expect(
        containsContractString(product.archivedSessions(), child.value) &&
            product.archivedSessionInfo(child).value().getOrThrow().summary == "Review the child branch",
        "soft archive preserves indexed session details"
    )
    product.restoreSession(child).value().getOrThrow()
    expect(
        !containsContractString(product.archivedSessions(), child.value) &&
            product.messages(child).value().getOrThrow().size == 1 &&
            product.sessionInfo(child).value().getOrThrow().parentId == parent.value,
        "archived sessions restore conversation and sidecar metadata"
    )
    product.close()
}

func prepareProductContractWorkspace(root: String): Unit {
    prepareContractFiles(root)
    runProviderConfigurationContracts(root)
}

func prepareContractFiles(root: String): Unit {
    File.writeTo(root + "/note.txt", "before\n".toArray())
    File.writeTo(
        root + "/lines.txt",
        "one\ntwo\nthree\n".toArray()
    )
    File.writeTo(
        root + "/Makefile",
        "all:\n\t@echo product\n".toArray()
    )
    Directory.create(root + "/ast", recursive: true)
    File.writeTo(
        root + "/ast/sample.py",
        ("def first(value):\n" + "    return value\n\n" + "def second():\n" + "    return 42\n").toArray()
    )
    Directory.create(root + "/lsp", recursive: true)
    File.writeTo(
        root + "/lsp/helper.py",
        ("def greet(name: str) -> str:\n" + "    return \"hi \" + name\n").toArray()
    )
    File.writeTo(
        root + "/lsp/use.py",
        ("from helper import greet\n" + "message = greet(\"Ada\")\n" + "print(message)\n").toArray()
    )
    File.writeTo(
        root + "/lsp/broken.py",
        "value: int = \"wrong\"\n".toArray()
    )
    File.writeTo(
        root + "/lsp/move_me.py",
        "MOVE_VALUE = 1\n".toArray()
    )
    File.writeTo(
        root + "/lsp/sample.resource",
        "resource\n".toArray()
    )
    File.writeTo(
        root + "/lsp/delete_me.txt",
        "delete me\n".toArray()
    )
    File.writeTo(
        root + "/lsp/rollback_delete.txt",
        "restore me\n".toArray()
    )
    let resourceServer = root + "/lsp/resource_server.py"
    File.writeTo(
        resourceServer,
        resourceLspServerSource().toArray()
    )
    File.writeTo(
        root + "/lsp.json",
        ("{\"servers\":{\"resource-contract\":{" + "\"command\":\"/usr/bin/python3\"," + "\"args\":[\"" + resourceServer +
            "\"]," + "\"fileTypes\":[\".resource\"]," + "\"languageId\":\"resource\"," + "\"rootMarkers\":[\".\"]}}}")
            .toArray()
    )
    File.writeTo(
        root + "/large-lines.txt",
        largeLinesContent().toArray()
    )
    Directory.create(root + "/config", recursive: true)
    File.writeTo(
        root + "/config/config.yml",
        ("default_model: local-openai/local-model\n" + "theme: contract\n" + "async:\n" + "  enabled: false\n" +
            "approval:\n" + "  mode: ai\n" + "  failure_policy: deny\n" + "  timeout_ms: 1200\n" +
            "  log_decisions: true\n" + "  reviewer:\n" + "    model: local-openai/backup-model\n" +
            "    reasoning_effort: medium\n" + "  policy:\n" + "    allow_workspace_writes: true\n" +
            "    ask_on_network: true\n" + "model_roles:\n" + "  approval: local-openai/backup-model\n" +
            "compaction:\n" + "  max_input_tokens: 120000\n" + "  trigger_percent: 87\n" +
            "  target_percent: 59\n" + "  emergency_max_messages: 600\n" +
            "  keep_recent_tokens: 52000\n" + "  summary_strategy: hybrid\n" +
            "  summary_model: local-openai/backup-model\n" + "  summary_timeout_ms: 1300\n" +
            "  summary_max_output_tokens: 700\n" + "  summary_failure_policy: fallback_structured\n" +
            "  models:\n" + "    local-openai/local-model:\n" +
            "      max_input_tokens: 180000\n" + "      trigger_percent: 91\n" +
            "      target_percent: 64\n").toArray()
    )
    File.writeTo(
        root + "/config/models.yml",
        ("models:\n" + "  - id: local-model\n" + "    provider: local-openai\n" +
            "    context_window: 200000\n" + "    max_output_tokens: 8192\n" +
            "    thinking:\n" + "      mode: effort\n" +
            "      levels: [minimal, low, medium, high, xhigh, max]\n" +
            "    structured_output: true\n" + "    prompt_cache: true\n" +
            "    input_modalities: [text, image]\n" + "    output_modalities: [text]\n" +
            "    input_cost_micros_per_million: 1000000\n" +
            "    output_cost_micros_per_million: 2000000\n" +
            "    cache_read_cost_micros_per_million: 250000\n" +
            "    cache_write_cost_micros_per_million: 1250000\n" +
            "    fast_service_tier: priority\n" + "  - id: backup-model\n" +
            "    provider: local-openai\n" + "    thinking:\n" + "      mode: none\n").toArray()
    )
    File.writeTo(
        root + "/config/providers.yml",
        ("providers:\n" + "  - id: local-openai\n" + "    provider: custom\n" + "    protocol: completions\n" +
            "    dialect: generic_chat\n" +
            "    base_url: http://127.0.0.1:11434\n" + "    api_key_env: LOCAL_API_KEY\n" + "    timeout_millis: 9000\n")
            .toArray()
    )
    Directory.create(root + "/config/themes", recursive: true)
    File.writeTo(
        root + "/config/themes/contract.json",
        ("{\"name\":\"contract\",\"vars\":{" + "\"accentColor\":\"#123456\",\"userBg\":\"#221d1a\"}," +
            "\"colors\":{\"accent\":\"accentColor\"," + "\"userMessageBg\":\"userBg\",\"userMessageText\":\"\"," +
            "\"text\":\"\",\"muted\":244," + "\"thinkingText\":\"accentColor\"}}").toArray()
    )
}

func largeLinesPrefix(): String {
    var prefix = "x"
    for (_ in 0..21) {
        prefix += prefix
    }
    prefix
}

func largeLinesContent(): String {
    largeLinesPrefix() + "\ntarget-after-megabyte\n"
}

func runProviderConfigurationContracts(root: String): Unit {
    runConfigFileContracts(root)
    runProviderProfileContracts(root)
    runProviderAuthenticationContracts(root)
}

func runAiApprovalContracts(root: String): Unit {
    let workspace = root + "/approval-ai"
    Directory.create(workspace + "/tmp", recursive: true)
    let product = openProduct(
        config: ProductConfig(
            stateRoot: root + "/approval-ai-state",
            workspaceRoot: workspace,
            fixture: true,
            approvalMode: ApprovalMode.AlwaysAsk,
            approvalRoutingModeOverride: Some(ApprovalRoutingMode.Ai),
            asyncEnabled: false
        )
    ).value().getOrThrow()
    let safe = product.applicationSession().handle("fixture approval safe").value().getOrThrow()
    expect(
        safe.approval.isNone() && exists(Path(workspace + "/tmp/result.txt")) &&
            String.fromUtf8(File.readFrom(workspace + "/tmp/result.txt")) == "hello\n",
        "AI reviewer approves one exact low-risk workspace write"
    )

    let deniedSession = product.applicationSession()
    let denied = deniedSession.handle("fixture approval dangerous").value().getOrThrow()
    expect(
        denied.approval.isNone() && denied.snapshot.isSome(),
        "permanent policy rejects rm -rf root before execution without opening approval"
    )

    let ask = match (product.applicationSession().handle("fixture approval ask")) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(
            "AI approval ask failed: " + error.code + ": " + error.message
        )
    }
    let pending = match (ask.approval) {
        case Some(value) => value
        case None => throw IllegalStateException(
            "AI approval ask did not pause: response=" + ask.text
        )
    }
    let review = pending.review.getOrThrow()
    expect(
        review.decision == ApprovalReviewDecision.AskUser && review.riskLevel == "high" && review.reason != "" &&
            pending.argumentHash != "" && containsContractString(pending.riskFlags, "git_destructive"),
        "force push is routed to the existing manual approval surface with reviewer context"
    )

    let _ = removeIfExists(workspace + "/tmp/result.txt")
    let manualState = root + "/approval-manual-state"
    let manualProduct = openProduct(
        config: ProductConfig(
            stateRoot: manualState,
            workspaceRoot: workspace,
            fixture: true,
            approvalMode: ApprovalMode.AlwaysAsk,
            approvalRoutingModeOverride: Some(ApprovalRoutingMode.Manual),
            asyncEnabled: false
        )
    ).value().getOrThrow()
    let manualApplication = manualProduct.applicationSession()
    let manual = manualApplication.handle("fixture approval safe").value().getOrThrow()
    expect(
        manual.approval.isNone() && exists(Path(workspace + "/tmp/result.txt")),
        "manual routing does not override a static policy that allows low-risk workspace writes"
    )
    let manualRisky = manualApplication.handle("fixture approval ask").value().getOrThrow()
    expect(
        manualRisky.approval.isSome() && manualRisky.approval.getOrThrow().review.isNone(),
        "manual remains the default route for requests that policy actually requires approval for"
    )
    let pendingSession = manualApplication.id()
    let restartedManual = openProduct(
        config: ProductConfig(
            stateRoot: manualState,
            workspaceRoot: workspace,
            fixture: true,
            approvalMode: ApprovalMode.AlwaysAsk,
            approvalRoutingModeOverride: Some(ApprovalRoutingMode.Manual),
            asyncEnabled: false
        )
    ).value().getOrThrow().applicationSession(sessionId: Some(pendingSession))
    let restoredApproval = restartedManual.approval().getOrThrow()
    expect(
        restoredApproval.operationId.value == manualRisky.approval.getOrThrow().operationId.value &&
            restoredApproval.callId == manualRisky.approval.getOrThrow().callId,
        "rebuilt product and application restore the same durable pending approval"
    )
    let restoredDecision = restartedManual.decide(
        restoredApproval.operationId.value, ApprovalDecision.Reject
    )
    expect(match (restoredDecision) {
        case Result.Ok(_) => true
        case Result.Err(error) => throw IllegalStateException(
            "restored approval settlement failed: " + error.code + ": " + error.message
        )
    }, "rebuilt application settles the restored durable pending approval")

    let failingPathRoot = "/tmp/axyndra-approval-missing-parent"
    let _ = removeIfExists(failingPathRoot, recursive: true)
    let failingApplication = openProduct(
        config: ProductConfig(
            stateRoot: root + "/approval-failure-state",
            workspaceRoot: workspace,
            fixture: true,
            approvalMode: ApprovalMode.AlwaysAsk,
            approvalRoutingModeOverride: Some(ApprovalRoutingMode.Manual),
            asyncEnabled: false
        )
    ).value().getOrThrow().applicationSession()
    let failingTurn = failingApplication.handle("fixture approval execution failure").value().getOrThrow()
    let failingApproval = failingTurn.approval.getOrThrow()
    let failedDecision = failingApplication.decide(
        failingApproval.operationId.value,
        ApprovalDecision.Approve
    )
    expect(
        failedDecision.isError() && failingApplication.approval().isNone() && failingApplication.cancel().isOk(),
        "a failed approved operation clears stale approval state and remains cancellable"
    )

    let never = openProduct(
        config: ProductConfig(
            stateRoot: root + "/approval-never-state",
            workspaceRoot: workspace,
            fixture: true,
            approvalMode: ApprovalMode.AlwaysAsk,
            approvalRoutingModeOverride: Some(ApprovalRoutingMode.Never),
            asyncEnabled: false
        )
    ).value().getOrThrow().applicationSession().handle("fixture approval ask").value().getOrThrow()
    expect(
        never.approval.isNone(),
        "never mode rejects privileged calls without opening a user prompt"
    )
}

func containsContractString(values: Array<String>, expected: String): Bool {
    for (value in values where value == expected) {
        return true
    }
    false
}

func runApprovalReviewerFailureContracts(root: String): Unit {
    let request = AgentRunRequest(
        RunId("review-run"),
        SessionId("review-session"),
        "fixture",
        "Run the requested operation",
        capabilities: CapabilitySet(values: [Capability(CapabilityKind.ProcessSpawn)])
    )
    let approval = ApprovalRequest(
        OperationId("review-operation"),
        "review-call",
        "bash",
        Capability(CapabilityKind.ProcessSpawn),
        preview: objectValue(
            [
                ValueField("command", textValue("git push --force origin main")),
                ValueField("token", textValue("do-not-leak"))
            ]
        ),
        sessionId: request.sessionId.value,
        argumentHash: "bound-hash",
        riskFlags: ["git_destructive", "network"]
    )
    let invalidPort = ApprovalFixturePort("not json")
    let invalid = ApprovalReviewer(
        invalidPort,
        ProductApprovalSettings(
            mode: ApprovalRoutingMode.Ai,
            failurePolicy: ApprovalFailurePolicy.AskUser,
            timeoutMillis: 100
        ),
        "fixture",
        root
    ).review(request, approval)
    expect(
        invalid.decision == ApprovalReviewDecision.AskUser && invalid.failureType == "approval.invalid_json" &&
            invalidPort.calls == 2 && !invalidPort.lastPrompt.contains("do-not-leak") &&
            invalidPort.lastPrompt.contains("[REDACTED]"),
        "invalid reviewer JSON is corrected once then fails closed to the user"
    )
    reportReviewerFailure("invalid_json", invalid)

    let illegal = ApprovalReviewer(
        ApprovalFixturePort("{\"decision\":\"maybe\",\"reason\":\"unclear\",\"riskLevel\":\"high\",\"approvedCapabilities\":[]}"),
        ProductApprovalSettings(
            mode: ApprovalRoutingMode.Ai,
            failurePolicy: ApprovalFailurePolicy.Deny,
            timeoutMillis: 100
        ),
        "fixture",
        root
    ).review(request, approval)
    expect(
        illegal.decision == ApprovalReviewDecision.Deny && illegal.failureType == "approval.invalid_decision",
        "illegal decision enums fail closed and never become approval"
    )

    let unavailable = ApprovalReviewer(
        ApprovalFixturePort("", fail: true),
        ProductApprovalSettings(
            mode: ApprovalRoutingMode.Ai,
            failurePolicy: ApprovalFailurePolicy.AskUser,
            timeoutMillis: 100
        ),
        "missing-model",
        root
    ).review(request, approval)
    expect(
        unavailable.decision == ApprovalReviewDecision.AskUser && unavailable.failureType == "fixture.model_missing",
        "missing reviewer model follows failurePolicy instead of fail-open"
    )
    reportReviewerFailure("invalid_model", unavailable)

    let slowPort = ApprovalFixturePort(
        "{\"decision\":\"approve\",\"reason\":\"late\",\"riskLevel\":\"low\",\"approvedCapabilities\":[\"process.spawn\"]}",
        delayMillis: 80
    )
    let timedOut = ApprovalReviewer(
        slowPort,
        ProductApprovalSettings(
            mode: ApprovalRoutingMode.Ai,
            failurePolicy: ApprovalFailurePolicy.Deny,
            timeoutMillis: 10
        ),
        "fixture",
        root
    ).review(request, approval)
    expect(
        timedOut.decision == ApprovalReviewDecision.Deny &&
            timedOut.failureType == "model.internal_timeout" && slowPort.cancelled,
        "reviewer timeout cancels the isolated request and fails closed"
    )
    reportReviewerFailure("timeout", timedOut)

    let expanded = ApprovalReviewer(
        ApprovalFixturePort("{\"decision\":\"approve\",\"reason\":\"looks safe\",\"riskLevel\":\"low\",\"approvedCapabilities\":[\"workspace.write\",\"network\"]}"),
        ProductApprovalSettings(
            mode: ApprovalRoutingMode.Ai,
            failurePolicy: ApprovalFailurePolicy.Deny,
            timeoutMillis: 100,
            askOnNetwork: false,
            askOnDestructiveCommands: false
        ),
        "fixture",
        root
    ).review(request, approval)
    expect(
        expanded.decision == ApprovalReviewDecision.Deny && expanded.failureType == "approval.invalid_capabilities",
        "reviewer cannot omit, replace, or expand the requested capability"
    )
    reportReviewerFailure("extra_capability", expanded)

    let missingCapabilities = ApprovalReviewer(
        ApprovalFixturePort("{\"decision\":\"approve\",\"reason\":\"safe\",\"riskLevel\":\"low\"}"),
        ProductApprovalSettings(
            mode: ApprovalRoutingMode.Ai,
            failurePolicy: ApprovalFailurePolicy.Deny,
            timeoutMillis: 100,
            askOnNetwork: false,
            askOnDestructiveCommands: false
        ),
        "fixture",
        root
    ).review(request, approval)
    expect(
        missingCapabilities.decision == ApprovalReviewDecision.Deny && missingCapabilities.failureType ==
            "approval.invalid_schema",
        "missing approvedCapabilities fails closed"
    )
    reportReviewerFailure("missing_approved_capabilities", missingCapabilities)

    let reasoned = ApprovalReviewer(
        ApprovalFixturePort(
            "{\"decision\":\"deny\",\"reason\":\"unsafe\",\"riskLevel\":\"high\",\"approvedCapabilities\":[]}",
            includeReasoning: true
        ),
        ProductApprovalSettings(
            mode: ApprovalRoutingMode.Ai,
            failurePolicy: ApprovalFailurePolicy.Deny,
            timeoutMillis: 100
        ),
        "fixture",
        root
    ).review(request, approval)
    expect(
        reasoned.decision == ApprovalReviewDecision.Deny && reasoned.failureType == "",
        "provider reasoning blocks are ignored while final approval JSON remains strict"
    )

    let redacted = redactApprovalValue(approval.preview, "")
    expect(
        redacted.field("token").getOrThrow().text == "[REDACTED]" &&
            redactApprovalText("Authorization: Bearer abc123") == "Authorization: Bearer [REDACTED]",
        "reviewer context redacts secret fields and bearer credentials"
    )
}

func reportReviewerFailure(name: String, review: ApprovalReview): Unit {
    println(
        "reviewer_failure fixture=" + name + " decision=" + approvalTestDecisionName(review.decision) +
            " risk=" + review.riskLevel + " approved_capabilities=" + review.approvedCapabilities.size.toString() +
            " latency_ms=" + review.latencyMillis.toString() + " failure_policy_result=" + review.failureType)
}

func approvalTestDecisionName(value: ApprovalReviewDecision): String {
    match (value) {
        case ApprovalReviewDecision.Approve => "approve"
        case ApprovalReviewDecision.Deny => "deny"
        case ApprovalReviewDecision.AskUser => "ask_user"
    }
}

class ApprovalFixturePort <: ModelPort {
    let output: String
    let fail: Bool
    let delayMillis: Int64
    let includeReasoning: Bool
    var calls: Int64 = 0
    var cancelled = false
    var lastPrompt = ""

    init(
        output: String,
        fail!: Bool = false,
        delayMillis!: Int64 = 0,
        includeReasoning!: Bool = false
    ) {
        this.output = output
        this.fail = fail
        this.delayMillis = delayMillis
        this.includeReasoning = includeReasoning
    }

    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        let _ = events
        expect(
            request.tools.isEmpty() && match (request.toolChoice) {
                case ModelToolChoice.NoTools => true
                case _ => false
            } && request.system.contains("INDEPENDENT_APPROVAL_REVIEWER"),
            "approval reviewer has an isolated no-tools model context"
        )
        calls += 1
        for (message in request.messages) {
            for (block in message.blocks where block.kind == ModelBlockKind.Text) {
                lastPrompt += block.text
            }
        }
        if (delayMillis > 0) {
            sleep(Duration.millisecond * delayMillis)
        }
        if (fail) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Configuration,
                    "fixture.model_missing",
                    "reviewer model does not exist"
                )
            )
        }
        Result.Ok(ModelReply(if (includeReasoning) {
            [
                ModelBlock(ModelBlockKind.Reasoning, text: "hidden fixture reasoning"),
                ModelBlock(ModelBlockKind.Text, text: output)
            ]
        } else {
            [ModelBlock(ModelBlockKind.Text, text: output)]
        }))
    }

    public func cancel(requestId: String): Result<Unit> {
        let _ = requestId
        cancelled = true
        Result.Ok(())
    }
}

func runConfigFileContracts(root: String): Unit {
    let settings = loadProductSettings(root + "/config").value().getOrThrow()
    let localCompaction = settings.compaction.resolvedForModel("local-openai/local-model")
    let fallbackCompaction = settings.compaction.resolvedForModel("local-openai/backup-model")
    expect(
        settings.model == "local-openai/local-model" && !settings.asyncEnabled && settings.theme == "contract" &&
            settings.approval.mode == ApprovalRoutingMode.Ai && settings.approval.failurePolicy == ApprovalFailurePolicy
            .Deny && settings.approval.timeoutMillis == 1200 && settings.approval.reviewerModel ==
            "local-openai/backup-model" && settings.compaction.maxInputTokens == 120000 &&
            settings.compaction.triggerPercent == 87 && settings.compaction.targetPercent == 59 &&
            settings.compaction.emergencyMaxMessages == 600 && settings.compaction.keepRecentTokens == 52000 &&
            settings.compaction.summaryStrategy == "hybrid" && settings.compaction.summaryModel ==
            "local-openai/backup-model" && settings.compaction.summaryTimeoutMillis == 1300 &&
            settings.compaction.summaryMaxOutputTokens == 700 && settings.compaction.summaryFailurePolicy ==
            "fallback_structured" &&
            localCompaction.maxInputTokens == 180000 && localCompaction.triggerPercent == 91 &&
            localCompaction.targetPercent == 64 && localCompaction.summaryStrategy == "hybrid" &&
            localCompaction.summaryModel == "local-openai/backup-model" && fallbackCompaction.maxInputTokens == 120000 &&
            fallbackCompaction.triggerPercent == 87 && fallbackCompaction.targetPercent == 59,
        "config.yml selects global defaults and exact-model compaction watermarks"
    )
    Directory.create(root + "/legacy-config", recursive: true)
    File.writeTo(
        root + "/legacy-config/config.yml",
        ("provider: local-openai\n" + "model: local-model\n" + "base_url: http://127.0.0.1:11434\n").toArray()
    )
    expect(
        loadProductSettings(root + "/legacy-config").isError(),
        "legacy single-provider config keys are rejected"
    )
    Directory.create(root + "/pre-compaction-config", recursive: true)
    File.writeTo(
        root + "/pre-compaction-config/config.yml",
        "default_model: existing/model\n".toArray()
    )
    let preCompaction = loadProductSettings(root + "/pre-compaction-config").value().getOrThrow()
    expect(
        preCompaction.compaction.maxInputTokens == 100000 && preCompaction.compaction.requestMaxMessages == 24 &&
            preCompaction.compaction.triggerPercent == 88 && preCompaction.compaction.targetPercent == 60 &&
            preCompaction.compaction.summaryStrategy == "structured" && preCompaction.compaction.summaryModel == "" &&
            preCompaction.compaction.summaryTimeoutMillis == 5000 &&
            preCompaction.compaction.summaryMaxOutputTokens == 800 &&
            preCompaction.compaction.summaryFailurePolicy == "fallback_structured" &&
            preCompaction.compaction.modelOverrides.isEmpty(),
        "configs created before compaction settings retain compatible defaults"
    )
    Directory.create(root + "/invalid-model-compaction", recursive: true)
    File.writeTo(
        root + "/invalid-model-compaction/config.yml",
        ("compaction:\n" + "  models:\n" + "    provider/model:\n" + "      trigger_percent: 55\n" +
            "      target_percent: 60\n").toArray()
    )
    expect(
        loadProductSettings(root + "/invalid-model-compaction").isError(),
        "model compaction target must remain below its resolved trigger"
    )
    Directory.create(root + "/invalid-summary-compaction", recursive: true)
    File.writeTo(
        root + "/invalid-summary-compaction/config.yml",
        ("compaction:\n" + "  summary_strategy: model_only\n").toArray()
    )
    expect(
        loadProductSettings(root + "/invalid-summary-compaction").isError(),
        "compaction rejects a strategy that can discard authoritative structured facts"
    )
    expect(
        loadModelNames(root + "/config").value().getOrThrow().size == 2,
        "models.yml provides selectable model names"
    )
    let catalog = loadModelCatalog(root + "/config").value().getOrThrow()
    let localMetadata = catalog[0]
    expect(
        catalog.size == 2 && localMetadata.displayId() == "local-openai/local-model" &&
            localMetadata.contextWindow == Some(200000) && localMetadata.maxOutputTokens == Some(8192) &&
            match (localMetadata.thinking) {
                case Some(value) => value.mode == ThinkingControlMode.Effort &&
                    value.supportedLevels.size == 6
                case None => false
            } && localMetadata.structuredOutput == Some(true) &&
            localMetadata.promptCache == Some(true) && match (localMetadata.inputModalities) {
                case Some(values) => values.size == 2 && values[0] == "text" && values[1] == "image"
                case None => false
            } && match (localMetadata.outputModalities) {
                case Some(values) => values.size == 1 && values[0] == "text"
                case None => false
            } && localMetadata.inputCostMicrosPerMillion == Some(1000000) &&
            localMetadata.outputCostMicrosPerMillion == Some(2000000) &&
            localMetadata.cacheReadCostMicrosPerMillion == Some(250000) &&
            localMetadata.cacheWriteCostMicrosPerMillion == Some(1250000) &&
            localMetadata.fastServiceTier == "priority",
        "model catalog loads explicit thinking, limits, modalities, pricing, and fast-tier metadata"
    )
    let roundtripRoot = root + "/model-catalog-roundtrip"
    Directory.create(roundtripRoot, recursive: true)
    expect(
        upsertModelCatalogEntry(roundtripRoot, ModelCatalogEntry(
            "roundtrip-model",
            providerProfile: "roundtrip-provider",
            contextWindow: Some(321000),
            maxOutputTokens: Some(12000),
            apiId: "openai_chat_completions",
            dialect: "deepseek_chat",
            thinking: Some(ThinkingCapabilities(ThinkingControlMode.NoThinking)),
            structuredOutput: Some(false),
            promptCache: Some(true),
            inputModalities: Some(["text", "audio"]),
            outputModalities: Some(["text", "image"]),
            inputCostMicrosPerMillion: Some(101),
            outputCostMicrosPerMillion: Some(202),
            cacheReadCostMicrosPerMillion: Some(33),
            cacheWriteCostMicrosPerMillion: Some(44),
            fastServiceTier: "flex",
            defaultHeaders: [ProviderDefaultHeader("x-model-route", "roundtrip, canary")]
        )).isOk(),
        "rich model metadata is atomically written"
    )
    let roundtrip = loadModelCatalog(roundtripRoot).value().getOrThrow()[0]
    expect(
        roundtrip.contextWindow == Some(321000) && roundtrip.maxOutputTokens == Some(12000) &&
            roundtrip.apiId == "openai_chat_completions" && roundtrip.dialect == "deepseek_chat" &&
            match (roundtrip.thinking) {
                case Some(value) => value.mode == ThinkingControlMode.NoThinking
                case None => false
            } && roundtrip.structuredOutput == Some(false) &&
            roundtrip.promptCache == Some(true) && roundtrip.inputCostMicrosPerMillion == Some(101) &&
            roundtrip.outputCostMicrosPerMillion == Some(202) &&
            roundtrip.cacheReadCostMicrosPerMillion == Some(33) &&
            roundtrip.cacheWriteCostMicrosPerMillion == Some(44) && roundtrip.fastServiceTier == "flex" &&
            roundtrip.defaultHeaders.size == 1 &&
            roundtrip.defaultHeaders[0].name == "x-model-route" &&
            roundtrip.defaultHeaders[0].value == "roundtrip, canary",
        "rich model metadata round-trips without fabricated defaults"
    )
    let oldCatalogRoot = root + "/old-model-catalog"
    Directory.create(oldCatalogRoot, recursive: true)
    File.writeTo(
        oldCatalogRoot + "/models.yml",
        "models:\n  - id: old-model\n    provider: old-provider\n".toArray()
    )
    let oldMetadata = loadModelCatalog(oldCatalogRoot).value().getOrThrow()[0]
    expect(
        oldMetadata.contextWindow.isNone() && oldMetadata.maxOutputTokens.isNone() &&
            oldMetadata.thinking.isNone() && oldMetadata.inputModalities.isNone() &&
            oldMetadata.outputModalities.isNone() && oldMetadata.inputCostMicrosPerMillion.isNone() &&
            oldMetadata.fastServiceTier == "",
        "legacy id/provider-only catalogs remain readable with unknown metadata"
    )
    let thinkingCatalogRoot = root + "/thinking-model-catalog"
    Directory.create(thinkingCatalogRoot, recursive: true)
    File.writeTo(
        thinkingCatalogRoot + "/models.yml",
        ("models:\n  - id: budget-model\n    max_output_tokens: 32768\n" +
            "    thinking:\n      mode: budget\n" +
            "      levels: [low, medium, high]\n      budgets:\n" +
            "        low: 2048\n        medium: 8192\n        high: 16384\n").toArray()
    )
    let thinkingMetadata = loadModelCatalog(thinkingCatalogRoot).value().getOrThrow()[0]
    expect(match (thinkingMetadata.thinking) {
        case Some(value) => match (value.mode) {
            case ThinkingControlMode.Budget => value.supportedLevels.size == 3 &&
                value.budgetFor(ThinkingLevel.Medium) == Some(8192)
            case _ => false
        }
        case None => false
    }, "new model catalogs load explicit normalized thinking capabilities")
    let invalidThinkingRoot = root + "/invalid-thinking-model-catalog"
    Directory.create(invalidThinkingRoot, recursive: true)
    File.writeTo(
        invalidThinkingRoot + "/models.yml",
        ("models:\n  - id: invalid-budget-model\n    thinking:\n      mode: budget\n" +
            "      levels: [low, medium]\n      budgets:\n" +
            "        low: 8192\n        medium: 2048\n").toArray()
    )
    expect(loadModelCatalog(invalidThinkingRoot).isError(),
        "model catalog rejects decreasing custom budget tiers")
    let duplicateCatalogRoot = root + "/duplicate-model-catalog"
    Directory.create(duplicateCatalogRoot, recursive: true)
    File.writeTo(
        duplicateCatalogRoot + "/models.yml",
        ("models:\n  - id: duplicate\n    provider: provider\n" +
            "  - id: duplicate\n    provider: provider\n").toArray()
    )
    let fieldBeforeIdRoot = root + "/field-before-model-id"
    Directory.create(fieldBeforeIdRoot, recursive: true)
    File.writeTo(
        fieldBeforeIdRoot + "/models.yml",
        "models:\n  provider: provider\n  - id: model\n".toArray()
    )
    let unknownFieldRoot = root + "/unknown-model-field"
    Directory.create(unknownFieldRoot, recursive: true)
    File.writeTo(
        unknownFieldRoot + "/models.yml",
        "models:\n  - id: model\n    mystery: value\n".toArray()
    )
    expect(
        loadModelCatalog(duplicateCatalogRoot).isError() &&
            loadModelCatalog(fieldBeforeIdRoot).isError() &&
            loadModelCatalog(unknownFieldRoot).isError(),
        "strict model catalog parsing rejects duplicate entries, fields before id, and unknown fields"
    )
    Directory.create(root + "/unsafe-approval-config", recursive: true)
    File.writeTo(
        root + "/unsafe-approval-config/config.yml",
        ("approval:\n" + "  mode: ai\n" + "  failurePolicy: approve\n").toArray()
    )
    expect(
        loadProductSettings(root + "/unsafe-approval-config").isError(),
        "failurePolicy approve is rejected instead of becoming a fail-open mode"
    )
    let themes = loadProductThemes(root + "/config").value().getOrThrow()
    expect(
        themes.size == 1 && themes[0].name == "contract" && themes[0].accent == "#123456" && themes[0].userMessageBg ==
            "#221d1a" && themes[0].muted == "244",
        "OMP-compatible JSON themes resolve variables and palette indexes"
    )
    let configuredProductResult = openProduct(
        config: ProductConfig(
            settingsRoot: root + "/config",
            stateRoot: root + "/theme-state",
            workspaceRoot: root,
            approvalMode: ApprovalMode.Yolo,
            asyncEnabled: false
        )
    )
    expect(configuredProductResult.isOk(), "configured product opens: " + match (configuredProductResult) {
        case Result.Err(error) => error.code + ":" + error.message
        case Result.Ok(_) => "ok"
    })
    let configuredProduct = configuredProductResult.value().getOrThrow()
    let themeSession = configuredProduct.applicationSession()
    let localRequest = configuredProduct.request("local budget", modelOverride: "local-openai/local-model")
    let fallbackRequest = configuredProduct.request("fallback budget", modelOverride: "local-openai/backup-model")
    expect(
        localRequest.budget.maxInputTokens == 180000 && localRequest.budget.maxOutputTokens == 8192 &&
            localRequest.cachePolicy == ModelCachePolicy.StablePrefix && localRequest.cacheKey != "" &&
            fallbackRequest.budget.maxInputTokens == 120000 && fallbackRequest.budget.maxOutputTokens == 16384 &&
            localRequest.serviceTier == "" && match (localRequest.pricing) {
                case Some(value) => value.inputMicrosPerMillion == Some(1000000) &&
                    value.outputMicrosPerMillion == Some(2000000) &&
                    value.cacheReadMicrosPerMillion == Some(250000) &&
                    value.cacheWriteMicrosPerMillion == Some(1250000)
                case None => false
            } && fallbackRequest.pricing.isNone(),
        "each request resolves real model limits and only explicit pricing"
    )
    let metadataSession = SessionId("metadata-session")
    let history = ArrayList<ModelMessage>()
    for (index in 0..30) {
        history.add(ModelMessage(
            if (index % 2 == 0) { ModelRole.User } else { ModelRole.Assistant },
            [ModelBlock(ModelBlockKind.Text, text: "context message " + index.toString())]
        ))
    }
    configuredProduct.replaceMessages(metadataSession, history.toArray()).value().getOrThrow()
    configuredProduct.setSessionModel(metadataSession, "local-openai/local-model").value().getOrThrow()
    let estimatedContext = configuredProduct.contextUsage(metadataSession, "local-openai/local-model")
    expect(match ((estimatedContext.tokens, estimatedContext.contextWindow, estimatedContext.percent)) {
        case (Some(tokens), Some(window), Some(percent)) => tokens > 0 && window == 200000 && percent > 0.0
        case _ => false
    }, "context usage estimates the current provider projection before authoritative usage exists")
    expect(
        configuredProduct.setFastMode(metadataSession, "local-openai/local-model", true).isOk() &&
            configuredProduct.fastModeEnabled(metadataSession) &&
            configuredProduct.fastModeActive(metadataSession, "local-openai/local-model"),
        "fast mode enables only for a catalog model with an encodable explicit tier"
    )
    let fastRequest = configuredProduct.request(
        "fast request",
        sessionId: Some(metadataSession),
        modelOverride: "local-openai/local-model"
    )
    expect(
        fastRequest.serviceTier == "priority" && configuredProduct
            .setFastMode(SessionId("unsupported-fast"), "local-openai/backup-model", true).isError(),
        "request routing carries fast tier and unsupported models fail closed"
    )
    let contextDatabase = SqliteDatabase(root + "/theme-state/state.db")
    let canonicalContextRun = RunId(contextDatabase.query(
        "SELECT id FROM runs WHERE thread_id='metadata-session' ORDER BY started_at_millis LIMIT 1"
    )[0].required(0))
    SqliteRunRepository(contextDatabase).save(RunSnapshot(
        canonicalContextRun,
        metadataSession,
        RunState.Completed,
        modelRequests: 1,
        usage: Some(ModelUsage(inputTokens: 240000, outputTokens: 100)),
        lastInputTokens: 240000,
        lastOutputTokens: 100,
        lastRequestDurationMillis: 1000
    )).value().getOrThrow()
    let authoritativeContext = configuredProduct.contextUsage(metadataSession, "local-openai/local-model")
    expect(match ((authoritativeContext.tokens, authoritativeContext.contextWindow, authoritativeContext.percent)) {
        case (Some(tokens), Some(window), Some(percent)) => tokens == 240000 && window == 200000 && percent == 120.0
        case _ => false
    }, "provider-reported context usage is authoritative and honestly reports over-window percentages")
    expect(
        configuredProduct.compactSession(metadataSession, force: true).value().getOrThrow() > 0,
        "context fixture compacts its provider-facing projection"
    )
    let contextTurn = contextDatabase.query(
        "SELECT id FROM turns WHERE thread_id='metadata-session' ORDER BY ordinal LIMIT 1"
    )[0].required(0)
    contextDatabase.execute(
        "INSERT INTO runs(id,thread_id,turn_id,epoch,state,lane_snapshot,skill_snapshot,budget,usage," +
            "started_at_millis,finished_at_millis,cancellation_reason) VALUES(" +
            "'zz-local-only-after-context','metadata-session'," + sqliteText(contextTurn) +
            ",2,'failed','{}','{}','{}','{}',9999999999999,9999999999999,'fixture')"
    )
    SqliteRunRepository(contextDatabase).save(RunSnapshot(
        RunId("zz-local-only-after-context"),
        metadataSession,
        RunState.Failed,
        summary: "failed before provider"
    )).value().getOrThrow()
    contextDatabase.close()
    let reopenedProduct = openProduct(
        config: ProductConfig(
            settingsRoot: root + "/config",
            stateRoot: root + "/theme-state",
            workspaceRoot: root,
            approvalMode: ApprovalMode.Yolo,
            asyncEnabled: false
        )
    ).value().getOrThrow()
    let reopenedContext = reopenedProduct.contextUsage(metadataSession, "local-openai/local-model")
    expect(
        reopenedProduct.fastModeEnabled(metadataSession) &&
            reopenedProduct.fastModeActive(metadataSession, "local-openai/local-model") &&
            match ((reopenedContext.tokens, reopenedContext.percent)) {
                case (Some(tokens), Some(percent)) => tokens == 240000 && percent == 120.0
                case _ => false
            },
        "fast preference and last provider context usage survive compaction, a newer zero-request run, and reopen"
    )
    expect(
        themeSession.currentTheme() == "contract" && themeSession.handle("/theme light").isOk() &&
            loadProductSettings(root + "/config").value().getOrThrow().theme == "light" &&
            loadProductSettings(root + "/config").value().getOrThrow().approval.mode == ApprovalRoutingMode.Ai &&
            loadProductSettings(root + "/config").value().getOrThrow().compaction.triggerPercent == 87 &&
            loadProductSettings(root + "/config")
                .value()
                .getOrThrow()
                .compaction
                .resolvedForModel("local-openai/local-model")
                .maxInputTokens == 180000,
        "/theme persists global and model-specific compaction configuration"
    )
}

func runProviderProfileContracts(root: String): Unit {
    let profileRoot = root + "/profiles"
    expect(rejectsIllegalArgument({ =>
        let _ = ProviderDefaultHeader("authorization", "Bearer secret")
    }) && rejectsIllegalArgument({ =>
        let _ = ProviderDefaultHeader("x-route", "safe\r\ninjected: secret")
    }), "profile headers reject credential ownership and line injection before persistence")
    expect(
        ensureProductLayout(profileRoot).isOk(),
        "provider profile layout is created"
    )
    expect(
        upsertProviderProfile(
            profileRoot,
            ProviderProfile(
                "anthropic-official",
                "anthropic",
                "messages",
                "https://api.anthropic.com",
                "ANTHROPIC_API_KEY",
                dialect: "anthropic_messages",
                defaultHeaders: [ProviderDefaultHeader("x-profile-route", "anthropic")]
            )
        ).isOk() && upsertProviderProfile(
            profileRoot,
            ProviderProfile(
                "deepseek-anthropic",
                "anthropic",
                "messages",
                "https://api.deepseek.com/anthropic",
                "DEEPSEEK_API_KEY",
                dialect: "deepseek_messages"
            )
        ).isOk(),
        "multiple provider profiles coexist"
    )
    expect(
        upsertModelCatalogEntry(
            profileRoot,
            ModelCatalogEntry(
                "shared-model",
                providerProfile: "anthropic-official",
                thinking: Some(ThinkingCapabilities(
                    ThinkingControlMode.Budget,
                    supportedLevels: canonicalNonOffThinkingLevels()
                )),
                promptCache: Some(true)
            )
        ).isOk() && upsertModelCatalogEntry(
            profileRoot,
            ModelCatalogEntry(
                "shared-model",
                providerProfile: "deepseek-anthropic",
                thinking: Some(ThinkingCapabilities(
                    ThinkingControlMode.Budget,
                    supportedLevels: canonicalNonOffThinkingLevels()
                ))
            )
        ).isOk(),
        "same model ID can be bound to different provider profiles"
    )
    let profileModels = loadModelNames(profileRoot).value().getOrThrow()
    let loadedProfiles = loadProviderProfiles(profileRoot).value().getOrThrow()
    expect(
        loadedProfiles.size == 2 && profileModels.size == 2 &&
            profileModels[0] != profileModels[1] &&
            loadedProfiles[0].defaultHeaders.size == 1 &&
            loadedProfiles[0].defaultHeaders[0].name == "x-profile-route",
        "profile and qualified model catalogs round-trip"
    )
    let customLegacyRoot = root + "/custom-legacy-thinking"
    expect(ensureProductLayout(customLegacyRoot).isOk() &&
        upsertProviderProfile(customLegacyRoot, ProviderProfile(
            "pretend-anthropic", "anthropic", "messages",
            "https://example.invalid/anthropic", "CUSTOM_API_KEY",
            dialect: "anthropic_messages"
        )).isOk() && upsertModelCatalogEntry(
            customLegacyRoot,
            ModelCatalogEntry("custom-model", providerProfile: "pretend-anthropic")
        ).isOk(), "custom legacy thinking fixture is configured")
    File.writeTo(
        customLegacyRoot + "/config.yml",
        "default_model: pretend-anthropic/custom-model\n".toArray()
    )
    let rejectedLegacy = openProduct(config: ProductConfig(
        settingsRoot: customLegacyRoot,
        stateRoot: root + "/custom-legacy-thinking-rejected-state",
        workspaceRoot: root,
        asyncEnabled: false
    ))
    expect(match (rejectedLegacy) {
        case Result.Err(error) => error.kind == AgentErrorKind.Configuration &&
            error.code == "config.model_thinking_capability_missing"
        case Result.Ok(value) => value.close(); false
    }, "provider name and dialect cannot bypass exact official endpoint thinking validation")
    expect(upsertModelCatalogEntry(
        customLegacyRoot,
        ModelCatalogEntry(
            "custom-model", providerProfile: "pretend-anthropic",
            thinking: Some(ThinkingCapabilities(
                ThinkingControlMode.Effort,
                supportedLevels: [ThinkingLevel.Low, ThinkingLevel.High]
            ))
        )
    ).isOk(), "custom endpoint declares explicit thinking capability")
    let explicitProduct = openProduct(config: ProductConfig(
        settingsRoot: customLegacyRoot,
        stateRoot: root + "/custom-legacy-thinking-explicit-state",
        workspaceRoot: root,
        asyncEnabled: false
    )).value().getOrThrow()
    explicitProduct.close()
    File.writeTo(
        profileRoot + "/config.yml",
        "default_model: anthropic-official/shared-model\n".toArray()
    )
    let profiledProduct = openProduct(config: ProductConfig(
        settingsRoot: profileRoot,
        stateRoot: root + "/profile-capability-state",
        workspaceRoot: root,
        approvalMode: ApprovalMode.Yolo,
        asyncEnabled: false
    )).value().getOrThrow()
    let officialCache = profiledProduct.request(
        "official cache",
        modelOverride: "anthropic-official/shared-model"
    )
    let compatibleCache = profiledProduct.request(
        "compatible cache",
        modelOverride: "deepseek-anthropic/shared-model"
    )
    expect(
        officialCache.cachePolicy == ModelCachePolicy.StablePrefix && officialCache.cacheKey != "" &&
            compatibleCache.cachePolicy == ModelCachePolicy.Default && compatibleCache.cacheKey == "",
        "prompt caching follows explicit model capability and compatible endpoints remain conservative"
    )
    expect(
        saveProviderCredential(
            profileRoot,
            "anthropic-official",
            "anthropic-secret"
        ).isOk() && saveProviderCredential(
            profileRoot,
            "deepseek-anthropic",
            "deepseek-secret"
        ).isOk(),
        "provider credentials are stored independently"
    )
    let anthropicCredential = providerCredentialPath(
        profileRoot,
        "anthropic-official"
    ).value().getOrThrow()
    let deepseekCredential = providerCredentialPath(
        profileRoot,
        "deepseek-anthropic"
    ).value().getOrThrow()
    expect(
        anthropicCredential != deepseekCredential && String.fromUtf8(File.readFrom(anthropicCredential)).trimAscii() ==
            "anthropic-secret" && String.fromUtf8(File.readFrom(deepseekCredential)).trimAscii() == "deepseek-secret",
        "one provider credential cannot overwrite another"
    )
}

func runProviderAuthenticationContracts(root: String): Unit {
    let profileRoot = root + "/profiles"
    let anthropicCredential = providerCredentialPath(
        profileRoot,
        "anthropic-official"
    ).value().getOrThrow()
    let deepseekCredential = providerCredentialPath(
        profileRoot,
        "deepseek-anthropic"
    ).value().getOrThrow()
    let oauthRoot = root + "/oauth-profile"
    expect(
        ensureProductLayout(oauthRoot).isOk() && upsertProviderProfile(
            oauthRoot,
            ProviderProfile(
                "oauth-provider",
                "openai",
                "responses",
                "https://api.openai.com",
                "",
                authentication: "oauth",
                dialect: "openai_responses"
            )
        ).isOk() && upsertModelCatalogEntry(
            oauthRoot,
            ModelCatalogEntry(
                "oauth-model",
                providerProfile: "oauth-provider",
                thinking: Some(ThinkingCapabilities(
                    ThinkingControlMode.Effort,
                    supportedLevels: canonicalNonOffThinkingLevels()
                ))
            )
        ).isOk(),
        "provider profile schema reserves an explicit OAuth mode"
    )
    File.writeTo(
        oauthRoot + "/config.yml",
        "default_model: oauth-provider/oauth-model\n".toArray()
    )
    let oauthProduct = openProduct(
        config: ProductConfig(
            settingsRoot: oauthRoot,
            stateRoot: root + "/oauth-state",
            workspaceRoot: root
        )
    ).value().getOrThrow()
    match (oauthProduct.login(profileId: "oauth-provider")) {
        case Result.Err(error) => expect(
            error.code == "oauth_not_supported",
            "OAuth login returns the documented typed error"
        )
        case Result.Ok(_) => throw IllegalStateException("OAuth login unexpectedly succeeded")
    }
    match (oauthProduct.applicationSession().handle("oauth request")) {
        case Result.Err(error) => expect(
            error.code == "oauth_not_supported",
            "OAuth model invocation returns the documented typed error"
        )
        case Result.Ok(_) => throw IllegalStateException("OAuth model invocation unexpectedly succeeded")
    }
    File.writeTo(
        profileRoot + "/config.yml",
        "default_model: deepseek-anthropic/shared-model\n".toArray()
    )
    let profiledProduct = match (openProduct(
        config: ProductConfig(
            settingsRoot: profileRoot,
            stateRoot: root + "/profile-state",
            workspaceRoot: root
        )
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    expect(
        profiledProduct.models().size == 2 && profiledProduct.providerIdForModel("anthropic-official/shared-model") ==
            "anthropic-official" && profiledProduct.providerIdForModel("deepseek-anthropic/shared-model") ==
            "deepseek-anthropic",
        "qualified models resolve to their own provider profiles"
    )
    setVariable("ANTHROPIC_API_KEY", "anthropic-login-secret")
    setVariable("DEEPSEEK_API_KEY", "deepseek-login-secret")
    expect(
        profiledProduct.login(profileId: "anthropic-official").isOk() &&
            profiledProduct.login(profileId: "deepseek-anthropic").isOk(),
        "login targets a specific provider profile"
    )
    expect(
        profiledProduct.logout(profileId: "deepseek-anthropic").value().getOrThrow() && exists(
            Path(anthropicCredential)) && !exists(Path(deepseekCredential)),
        "logout removes only the selected provider credential"
    )
    removeVariable("ANTHROPIC_API_KEY")
    removeVariable("DEEPSEEK_API_KEY")
    setVariable("LOCAL_API_KEY", "contract-secret")
    let configuredProduct = match (openProduct(
        config: ProductConfig(
            settingsRoot: root + "/config",
            stateRoot: root + "/configured-state",
            workspaceRoot: root
        )
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(error.code + ": " + error.message)
    }
    expect(
        configuredProduct.login().isOk() && exists(Path(root + "/config/credentials/local-openai.key")),
        "login stores the configured environment credential"
    )
    expect(
        configuredProduct.logout().value().getOrThrow(),
        "logout removes the stored credential"
    )
    removeVariable("LOCAL_API_KEY")
}

func runToolContracts(root: String): Unit {
    let workspace = LocalWorkspace(root)
    let processes = LocalProcessPort(workspace, sandboxEnabled: true)
    runProcessCancellationContract(processes)
    let catalog = ToolCatalog()
    let askRuntime = AskRuntime()
    let toolDatabase = SqliteDatabase(root + "/tool-state.db")
    let todoRepository = SqliteSessionMetadataRepository(toolDatabase)
    expect(
        installLocalTools(
            catalog,
            workspace,
            processes,
            todoRepository: Some(todoRepository),
            askRuntime: askRuntime
        ).isOk(),
        "install local tools"
    )
    expectCoreToolSchemas(catalog)
    expectOrchestrationToolSchemas(workspace, processes)
    let pipeline = ToolPipeline(
        catalog,
        MemoryOperationRepository(),
        RecordingAuditPort(),
        ProductIds(),
        policy: DefaultCapabilityPolicy(mode: ApprovalMode.AlwaysAsk),
        permissions: SqlitePermissionRepository(toolDatabase)
    )
    let context = ToolInvocationContext(
        RunId("product-contract"),
        SessionId("product-contract"),
        CapabilitySet(
            values: [
                Capability(CapabilityKind.WorkspaceRead),
                Capability(CapabilityKind.WorkspaceWrite),
                Capability(CapabilityKind.ProcessSpawn),
                Capability(CapabilityKind.NetworkAccess)
            ]
        )
    )
    runAskToolContracts(pipeline, context, askRuntime)
    let initializedTodos = runAstSearchContracts(pipeline, context)
    runAstEditContracts(workspace, processes)
    runLspContracts(workspace, processes)
    runCheckpointContracts(workspace, processes)
    runTodoToolContracts(pipeline, context, todoRepository, initializedTodos, toolDatabase)
    runWorkspaceAndEvalContracts(pipeline, context, workspace, processes)
    runRestartedPermissionContracts(toolDatabase, context, workspace)
    processes.close().value().getOrThrow()
    toolDatabase.close()
}

func runWriteApprovalClassificationContracts(root: String): Unit {
    let workspaceRoot = root + "/write-classification/workspace"
    let tempOutside = Directory.createTemp("/tmp").toString()
    Directory.create(workspaceRoot, recursive: true)
    let workspace = LocalWorkspace(workspaceRoot)

    let inside = workspace.inspectWriteTarget(workspaceRoot + "/cube_model.js").value().getOrThrow()
    let insideMetadata = workspace.writeApprovalMetadata(inside.normalizedPath, "export const cube = 3\n")
    expect(
        workspace.rootPath() == canonicalize(workspaceRoot).toString() && inside.requestedPath == workspaceRoot +
            "/cube_model.js" && inside.realParentPath == canonicalize(workspaceRoot).toString() &&
            inside.permissionClass == "workspace.write" && insideMetadata.assessment.level == ApprovalRiskLevel.Low,
        "workspace writes use canonical target and parent paths and are low risk"
    )

    let outsidePath = tempOutside + "/cube_model.js"
    let outside = workspace.inspectWriteTarget(outsidePath).value().getOrThrow()
    let outsideMetadata = workspace.writeApprovalMetadata(outsidePath, "export const cube = 3\n")
    expect(
        outside.permissionClass == "temp.write" && outsideMetadata.assessment.level == ApprovalRiskLevel.Medium &&
            outsideMetadata.assessment.reasons[0].contains("outside the current workspace"),
        "temporary paths outside the workspace are not mislabeled workspace.write"
    )

    let prefixEscape = workspace.inspectWriteTarget(workspaceRoot + "-evil/file.js").value().getOrThrow()
    let parentEscape = workspace.inspectWriteTarget(workspaceRoot + "/../other/file.js").value().getOrThrow()
    expect(
        prefixEscape.permissionClass != "workspace.write" && parentEscape.permissionClass != "workspace.write",
        "same-prefix and parent traversal targets cannot inherit workspace permission"
    )

    let linkPath = workspaceRoot + "/link"
    let link = launch(
        "/bin/ln",
        ["-s", "/etc", linkPath],
        stdOut: ProcessRedirect.Pipe,
        stdErr: ProcessRedirect.Pipe
    )
    let (linkExit, _, linkError) = link.waitOutput()
    expect(linkExit == 0, "symlink fixture is created: " + String.fromUtf8(linkError))
    let symlinkEscape = workspace.inspectWriteTarget(linkPath + "/approval-test.conf").value().getOrThrow()
    expect(
        symlinkEscape.permissionClass == "sensitive-path.write" && symlinkEscape.sensitive,
        "existing parent symlinks are canonicalized before write classification"
    )

    let sudoers = workspace.writeApprovalMetadata("/etc/sudoers", "unsafe\n")
    expect(
        sudoers.capabilityLabel == "sensitive-path.write" && sudoers.assessment.level == ApprovalRiskLevel.Critical &&
            sudoers.grantScope.capability == "sensitive-path.write",
        "system and credential paths remain critical and narrowly scoped"
    )

    var content = ""
    for (index in 0..220) {
        if (content != "") {
            content += "\n"
        }
        content += "const value" + index.toString() + " = " + index.toString()
    }
    let summary = workspace.writeApprovalMetadata(outsidePath, content).writeSummary.getOrThrow()
    expect(
        summary.lines == 220 && summary.bytes > 1000 && summary.preview.size == 6 && summary.truncated &&
            summary.contentHash != "" && !summary.preview[0].contains("\\n"),
        "large writes expose bounded line previews, exact size metadata, and a stable content hash"
    )

    File.writeTo(workspaceRoot + "/existing.txt", "before\n".toArray())
    let overwrite = workspace.writeApprovalMetadata("existing.txt", "after\n")
    expect(
        overwrite.writeSummary.getOrThrow().action == "overwrite" && overwrite.writeSummary.getOrThrow().beforeBytes > 0 &&
            overwrite.assessment.level == ApprovalRiskLevel.Medium,
        "overwriting an existing workspace file raises risk above a create"
    )
    let _ = removeIfExists(tempOutside, recursive: true)
}

func runReadApprovalClassificationContracts(root: String): Unit {
    let workspaceRoot = root + "/read-classification/workspace"
    let tempOutside = Directory.createTemp("/tmp").toString()
    Directory.create(workspaceRoot, recursive: true)
    File.writeTo(workspaceRoot + "/inside.txt", "inside\n".toArray())
    File.writeTo(tempOutside + "/outside.txt", "temporary-content\n".toArray())
    let workspace = LocalWorkspace(workspaceRoot)

    let inside = workspace.inspectReadTarget("inside.txt").value().getOrThrow()
    let missingInside = workspace.inspectReadTarget("missing.txt").value().getOrThrow()
    let outside = workspace.inspectReadTarget(tempOutside + "/outside.txt").value().getOrThrow()
    expect(
        inside.permissionClass == "workspace.read" && inside.baseRisk == ApprovalRiskLevel.Low &&
            missingInside.permissionClass == "workspace.read" && !missingInside.exists &&
            outside.permissionClass == "temp.read" && outside.baseRisk == ApprovalRiskLevel.Medium &&
            outside.reason.contains("outside the current workspace"),
        "read targets distinguish workspace and temporary-directory capabilities"
    )

    let prefixEscapeRoot = workspaceRoot + "-evil"
    Directory.create(prefixEscapeRoot, recursive: true)
    File.writeTo(prefixEscapeRoot + "/outside.txt", "prefix-escape\n".toArray())
    expect(
        workspace.inspectReadTarget(prefixEscapeRoot + "/outside.txt").value().getOrThrow().permissionClass !=
            "workspace.read",
        "same-prefix read targets cannot inherit workspace permission"
    )

    let linkPath = workspaceRoot + "/system-link"
    let link = launch(
        "/bin/ln",
        ["-s", "/etc", linkPath],
        stdOut: ProcessRedirect.Pipe,
        stdErr: ProcessRedirect.Pipe
    )
    let (linkExit, _, linkError) = link.waitOutput()
    expect(linkExit == 0, "read symlink fixture is created: " + String.fromUtf8(linkError))
    let linkedSystemFile = workspace.inspectReadTarget(linkPath + "/hosts").value().getOrThrow()
    expect(
        linkedSystemFile.permissionClass == "sensitive-path.read" && linkedSystemFile.sensitive,
        "read classification canonicalizes symlinks before applying sensitive-path rules"
    )

    let catalog = ToolCatalog()
    expect(
        installLocalTools(catalog, workspace, LocalProcessPort(workspace)).isOk(),
        "install read approval contract tools"
    )
    let pipeline = ToolPipeline(
        catalog,
        MemoryOperationRepository(),
        RecordingAuditPort(),
        ProductIds(),
        policy: DefaultCapabilityPolicy(mode: ApprovalMode.AlwaysAsk)
    )
    let context = ToolInvocationContext(
        RunId("read-approval-contract"),
        SessionId("read-approval-contract"),
        CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])
    )
    let missingReadFailed = toolOutcomeFailed(
        pipeline.invoke(
            context,
            ToolCall(
                "read-missing-workspace",
                "read",
                objectValue([ValueField("path", textValue("missing.txt"))])
            )
        )
    )
    expect(
        missingReadFailed,
        "missing workspace reads fail as tool results without opening an external-path approval"
    )
    let outsideApproval = approvalFrom(
        pipeline.invoke(
            context,
            ToolCall(
                "read-temp",
                "read",
                objectValue([ValueField("path", textValue(tempOutside + "/outside.txt"))])
            )
        )
    )
    expect(
        outsideApproval.metadata.capabilityLabel == "temp.read" && outsideApproval.metadata.grantScope.pathPrefix ==
            canonicalize(tempOutside).toString(),
        "temporary reads enter approval with an exact normalized directory scope"
    )
    let approvedRead = completedFrom(
        pipeline.decide(context, outsideApproval.operationId, ApprovalDecision.Approve)
    )
    expect(
        approvedRead.output.field("content").getOrThrow().text.contains("temporary-content"),
        "an approved temporary read executes the originally reviewed path"
    )

    match (pipeline.invoke(
        context,
        ToolCall(
            "read-sensitive",
            "read",
            objectValue([ValueField("path", textValue(linkPath + "/hosts"))])
        )
    )) {
        case Result.Ok(ToolInvocationResult.Denied(denial)) => expect(
            denial.reason.code == "tool.hard_denied",
            "sensitive reads are denied before execution"
        )
        case _ => throw IllegalStateException("sensitive read did not fail closed")
    }
    expect(
        workspace.read(WorkspaceReadRequest(tempOutside + "/outside.txt")).isError(),
        "the workspace port remains workspace-only outside the approved read tool path"
    )
    let _ = removeIfExists(prefixEscapeRoot, recursive: true)
    let _ = removeIfExists(tempOutside, recursive: true)
}

func runProcessCancellationContract(processes: LocalProcessPort): Unit {
    let cancellable = spawn {
        processes.execute(
            ProcessRequest(
                "/bin/bash",
                operationId: OperationId("cancel-contract"),
                arguments: ["-lc", "sleep 5"],
                timeoutMillis: 10000
            )
        )
    }
    sleep(Duration.millisecond * 100)
    expect(
        processes.cancel(OperationId("cancel-contract")).isOk(),
        "running shell process can be cancelled"
    )
    let cancelled = cancellable.get().value().getOrThrow()
    expect(
        cancelled.exitCode != 0,
        "cancelled shell does not report success"
    )
}

func expectCoreToolSchemas(catalog: ToolCatalog): Unit {
    expectToolSchema(catalog, "ask", ["questions"], ["questions"])
    expectToolSchema(catalog, "plan_write", ["content"], ["content"])
    // The read contract includes the core path plus optional artifact
    // pagination/export fields. Object member order is not part of JSON Schema.
    expectToolSchemaWithOptionalExtensions(
        catalog,
        "read",
        ["path"],
        ["offset", "limit", "destination"],
        ["path"]
    )
    expectToolSchema(
        catalog,
        "write",
        ["path", "content"],
        ["path", "content"]
    )
    expectToolSchema(catalog, "edit", ["input"], ["input"])
    expectToolSchema(
        catalog,
        "grep",
        ["pattern", "path", "case", "gitignore", "skip", "count"],
        ["pattern"]
    )
    expectToolSchema(
        catalog,
        "glob",
        ["pattern", "hidden", "gitignore", "limit"],
        ["pattern"]
    )
    expectToolSchema(
        catalog,
        "bash",
        ["command", "env", "timeout", "cwd", "pty", "async"],
        ["command"]
    )
    expectToolSchema(
        catalog,
        "bash_readonly",
        ["command", "timeout"],
        ["command"]
    )
    expectToolSchema(
        catalog,
        "eval",
        ["language", "code", "title", "timeout", "reset"],
        ["language", "code"]
    )
    expectToolSchema(
        catalog,
        "ast_grep",
        ["pat", "path", "skip"],
        ["pat"]
    )
    expectToolSchema(
        catalog,
        "ast_edit",
        ["ops", "paths"],
        ["ops", "paths"]
    )
    expectToolSchema(
        catalog,
        "lsp",
        [
            "action",
            "file",
            "line",
            "symbol",
            "query",
            "new_name",
            "apply",
            "timeout",
            "payload"
        ],
        ["action"]
    )
    expectToolSchema(
        catalog,
        "todo",
        ["op", "list", "task", "phase", "items", "reason"],
        ["op"]
    )
}

func expectOrchestrationToolSchemas(
    workspace: LocalWorkspace,
    processes: LocalProcessPort
): Unit {
    let orchestrationCatalog = ToolCatalog()
    expect(
        installLocalTools(
            orchestrationCatalog,
            workspace,
            processes,
            taskRuntime: Some(ProductTaskRuntime())
        ).isOk(),
        "install orchestration tools"
    )
    expectToolSchema(
        orchestrationCatalog,
        "task",
        ["context", "tasks"],
        ["context", "tasks"]
    )
    expectToolSchema(
        orchestrationCatalog,
        "hub",
        [
            "op",
            "to",
            "message",
            "replyTo",
            "await",
            "from",
            "ids",
            "timeoutMs",
            "peek",
            "name",
            "application",
            "args",
            "env",
            "env_from",
            "secret_env",
            "network",
            "cwd",
            "pty",
            "ready",
            "restart",
            "persist",
            "detached",
            "lines",
            "head",
            "grep",
            "follow",
            "cursor",
            "for",
            "pattern",
            "text",
            "enter",
            "keys",
            "signal",
            "timeout"
        ],
        ["op"]
    )
    expectToolSchema(
        orchestrationCatalog,
        "yield",
        ["type", "result"],
        ["result"]
    )
}

func runAskToolContracts(
    pipeline: ToolPipeline,
    context: ToolInvocationContext,
    askRuntime: AskRuntime
): Unit {
    let headlessAsk = pipeline.invoke(
        context,
        askSingleCall("ask-headless")
    )
    expect(
        headlessAsk.isError() && headlessAsk.error().getOrThrow().code == "ask.interactive_required" &&
            headlessAsk.error().getOrThrow().message == "Ask tool requires interactive mode",
        "ask fails explicitly without an interactive surface"
    )
    askRuntime.setInteractive(context.sessionId, true)
    let askFuture = spawn {
        pipeline.invoke(
            context,
            askSingleCall("ask-single")
        )
    }
    let askRequest = waitForAsk(
        askRuntime,
        context.sessionId
    )
    expect(
        askRequest.questions.size == 1 && askRequest.questions[0].id == "auth_method" &&
            askRequest.questions[0].recommended == Some<Int64>(0) &&
            askRequest.questions[0].options[0].description.contains("Bearer"),
        "ask publishes its structured question and recommendation"
    )
    expect(
        askRuntime.resolve(
            context.sessionId,
            askRequest.requestId,
            ProductAskResolution.Answers(
                [
                    ProductAskAnswer(
                        "auth_method",
                        selectedOptions: ["missing"]
                    )
                ]
            )
        ).isError(),
        "ask rejects an answer outside the offered options"
    )
    expect(
        askRuntime.resolve(
            context.sessionId,
            askRequest.requestId,
            ProductAskResolution.Answers(
                [
                    ProductAskAnswer(
                        "auth_method",
                        selectedOptions: ["JWT"],
                        note: Some("small and stateless")
                    )
                ]
            )
        ).isOk(),
        "ask accepts a structured answer"
    )
    let askResult = completedFrom(askFuture.get())
    expect(
        askResult.output.field("content").getOrThrow().text == "User selected: JWT\n" +
            "User added note: small and stateless" && askResult
            .output
            .field("question")
            .getOrThrow()
            .text
            .contains("authentication") && askResult.output.field("selectedOptions").getOrThrow().items[0].text == "JWT",
        "ask returns OMP-compatible text and structured details"
    )
    runTimedAndMultipleAskContracts(pipeline, context, askRuntime)
    runAskResolutionContracts(pipeline, context, askRuntime)
}

func runTimedAndMultipleAskContracts(
    pipeline: ToolPipeline,
    context: ToolInvocationContext,
    askRuntime: AskRuntime
): Unit {
    let timedAskFuture = spawn {
        pipeline.invoke(
            context,
            askSingleCall("ask-timeout")
        )
    }
    let timedRequest = waitForAsk(askRuntime, context.sessionId)
    expect(
        askRuntime.resolve(
            context.sessionId,
            timedRequest.requestId,
            ProductAskResolution.Answers(
                [
                    ProductAskAnswer(
                        "auth_method",
                        timedOut: true
                    )
                ]
            )
        ).isOk(),
        "ask accepts a timeout signal from the interactive surface"
    )
    let timedAsk = completedFrom(timedAskFuture.get())
    expect(
        timedAsk.output.field("content").getOrThrow().text == "User selected: JWT (auto-selected after timeout)" && timedAsk
            .output
            .field("timedOut")
            .getOrThrow()
            .boolean,
        "ask timeout selects the recommended option"
    )
    let multipleAskFuture = spawn {
        pipeline.invoke(
            context,
            askMultipleCall("ask-multiple")
        )
    }
    let multipleRequest = waitForAsk(
        askRuntime,
        context.sessionId
    )
    expect(
        askRuntime.resolve(
            context.sessionId,
            multipleRequest.requestId,
            ProductAskResolution.Answers(
                [
                    ProductAskAnswer(
                        "storage",
                        selectedOptions: ["SQLite"]
                    ),
                    ProductAskAnswer(
                        "features",
                        selectedOptions: ["Search", "Export"],
                        customInput: Some("Audit log")
                    )
                ]
            )
        ).isOk(),
        "ask accepts ordered multi-question answers"
    )
    let multipleAsk = completedFrom(multipleAskFuture.get())
    expect(
        multipleAsk.output.field("content").getOrThrow().text == "User answers:\n" + "storage: SQLite\n" +
            "features: \"Audit log\"" && multipleAsk.output.field("results").getOrThrow().items.size == 2 &&
            multipleAsk.output.field("results").getOrThrow().items[1].field("selectedOptions").getOrThrow().items.size ==
            2,
        "ask formats multiple answers and retains selected details"
    )
}

func runAskResolutionContracts(
    pipeline: ToolPipeline,
    context: ToolInvocationContext,
    askRuntime: AskRuntime
): Unit {
    let chatAskFuture = spawn {
        pipeline.invoke(
            context,
            askSingleCall("ask-chat")
        )
    }
    let chatRequest = waitForAsk(askRuntime, context.sessionId)
    expect(
        askRuntime.resolve(
            context.sessionId,
            chatRequest.requestId,
            ProductAskResolution.Chat
        ).isOk(),
        "ask accepts the chat redirect"
    )
    let chatAsk = completedFrom(chatAskFuture.get())
    expect(
        chatAsk.output.field("chatRedirect").getOrThrow().boolean &&
            chatAsk.output.field("content").getOrThrow().text.contains("chat about this"),
        "ask returns a structured chat redirect"
    )
    let cancelledAskFuture = spawn {
        pipeline.invoke(
            context,
            askSingleCall("ask-cancel")
        )
    }
    let cancelledRequest = waitForAsk(
        askRuntime,
        context.sessionId
    )
    expect(
        askRuntime.resolve(
            context.sessionId,
            cancelledRequest.requestId,
            ProductAskResolution.Cancelled
        ).isOk(),
        "ask cancellation resolves the pending request"
    )
    let cancelledAsk = cancelledAskFuture.get()
    expect(
        cancelledAsk.isError() && cancelledAsk.error().getOrThrow().kind == AgentErrorKind.Cancelled,
        "ask cancellation aborts instead of returning fake success"
    )
    match (pipeline.invoke(
        context,
        askReservedLabelCall()
    )) {
        case Result.Ok(ToolInvocationResult.Completed(result)) => expect(
            result.isError && result.callId == "ask-reserved" &&
                result.output.field("error_kind").getOrThrow().text == "invalid_input",
            "ask returns reserved-label validation as a call-bound tool error"
        )
        case _ => throw IllegalStateException("ask reserved label was not denied")
    }
}

func runAstSearchContracts(
    pipeline: ToolPipeline,
    context: ToolInvocationContext
): ToolResult {
    let initializedTodos = completedFrom(
        pipeline.invoke(
            context,
            ToolCall(
                "todo-init",
                "todo",
                objectValue(
                    [
                        ValueField("op", textValue("init")),
                        ValueField(
                            "list",
                            listValue(
                                [
                                    objectValue(
                                        [
                                            ValueField(
                                                "phase",
                                                textValue("Foundation")
                                            ),
                                            ValueField(
                                                "items",
                                                listValue(
                                                    [
                                                        textValue("Scaffold"),
                                                        textValue("Wire")
                                                    ]
                                                )
                                            )
                                        ]
                                    ),
                                    objectValue(
                                        [
                                            ValueField(
                                                "phase",
                                                textValue("Verification")
                                            ),
                                            ValueField("items", listValue([textValue("Test")]))
                                        ]
                                    )
                                ]
                            )
                        )
                    ]
                )
            )
        )
    )
    let astMatches = completedFrom(
        pipeline.invoke(
            context,
            ToolCall(
                "ast-grep-contract",
                "ast_grep",
                objectValue(
                    [
                        ValueField("pat", textValue("return $VALUE")),
                        ValueField(
                            "path",
                            textValue("ast/**/*.py")
                        )
                    ]
                )
            )
        )
    )
    expect(
        !astMatches.isError && astMatches.output.field("match_count").getOrThrow().number == "2" &&
            astMatches.output.field("file_count").getOrThrow().number == "1" &&
            astMatches.output.field("content").getOrThrow().text.contains("[ast/sample.py#") &&
            astMatches.output.field("content").getOrThrow().text.contains("meta: VALUE=value") &&
            astMatches.output.field("content").getOrThrow().text.contains("meta: VALUE=42"),
        "ast_grep performs structural search with hashline anchors"
    )
    let astPaged = completedFrom(
        pipeline.invoke(
            context,
            ToolCall(
                "ast-grep-page",
                "ast_grep",
                objectValue(
                    [
                        ValueField("pat", textValue("return $VALUE")),
                        ValueField(
                            "path",
                            textValue("ast/sample.py")
                        ),
                        ValueField("skip", integerValue(1))
                    ]
                )
            )
        )
    )
    expect(
        astPaged.output.field("match_count").getOrThrow().number == "2" &&
            astPaged.output.field("visible_count").getOrThrow().number == "1" &&
            !astPaged.output.field("content").getOrThrow().text.contains("VALUE=value") &&
            astPaged.output.field("content").getOrThrow().text.contains("VALUE=42"),
        "ast_grep applies the stable match offset"
    )
    let astEmpty = completedFrom(
        pipeline.invoke(
            context,
            ToolCall(
                "ast-grep-empty",
                "ast_grep",
                objectValue(
                    [
                        ValueField(
                            "pat",
                            textValue("never_called($$$ARGS)")
                        ),
                        ValueField(
                            "path",
                            textValue("ast/sample.py")
                        )
                    ]
                )
            )
        )
    )
    expect(
        !astEmpty.isError && astEmpty.output.field("match_count").getOrThrow().number == "0" &&
            astEmpty.output.field("content").getOrThrow().text == "No matches found",
        "ast_grep treats zero structural matches as a successful result"
    )
    expect(
        toolOutcomeFailed(pipeline.invoke(
            context,
            ToolCall(
                "ast-grep-escape",
                "ast_grep",
                objectValue(
                    [
                        ValueField("pat", textValue("return $VALUE")),
                        ValueField("path", textValue("../*.py"))
                    ]
                )
            )
        )),
        "ast_grep rejects workspace escape through a glob base"
    )
    initializedTodos
}

func runAstEditContracts(
    workspace: LocalWorkspace,
    processes: LocalProcessPort
): Unit {
    let root = workspace.rootPath()
    let astEditCatalog = ToolCatalog()
    expect(
        installLocalTools(
            astEditCatalog,
            workspace,
            processes
        ).isOk(),
        "install isolated AST edit catalog"
    )
    let astEditPipeline = ToolPipeline(
        astEditCatalog,
        MemoryOperationRepository(),
        RecordingAuditPort(),
        ProductIds(),
        policy: DefaultCapabilityPolicy(mode: ApprovalMode.Yolo)
    )
    let astEditContext = ToolInvocationContext(
        RunId("ast-edit-contract"),
        SessionId("ast-edit-contract"),
        CapabilitySet(values: [Capability(CapabilityKind.WorkspaceWrite)])
    )
    let astOriginal = String.fromUtf8(File.readFrom(root + "/ast/sample.py"))
    let preview = completedFrom(
        astEditPipeline.invoke(
            astEditContext,
            astEditCall(
                "ast-edit-preview",
                "return $VALUE",
                "return wrap($VALUE)",
                ["ast/sample.py"]
            )
        )
    )
    expect(
        !preview.isError && !preview.output.field("applied").getOrThrow().boolean &&
            preview.output.field("total_replacements").getOrThrow().number == "2" &&
            preview.output.field("content").getOrThrow().text.contains("files NOT modified yet") &&
            preview.output.field("content").getOrThrow().text.contains("[ast/sample.py#") &&
            String.fromUtf8(File.readFrom(root + "/ast/sample.py")) == astOriginal,
        "ast_edit stages a hashline preview without modifying files"
    )
    let rejected = completedFrom(
        astEditPipeline.invoke(
            astEditContext,
            resolutionWrite(
                "ast-edit-reject",
                "xd://reject",
                "the rewrite is not wanted"
            )
        )
    )
    expect(
        rejected.output.field("action").getOrThrow().text == "discard" &&
            rejected.output.field("content").getOrThrow().text.contains("Discarded: AST Edit") &&
            String.fromUtf8(File.readFrom(root + "/ast/sample.py")) == astOriginal,
        "xd://reject discards the pending AST edit"
    )
    let _ = completedFrom(
        astEditPipeline.invoke(
            astEditContext,
            astEditCall(
                "ast-edit-stale-preview",
                "return $VALUE",
                "return wrap($VALUE)",
                ["ast/sample.py"]
            )
        )
    )
    let externallyChanged = astOriginal + "# external change\n"
    File.writeTo(
        root + "/ast/sample.py",
        externallyChanged.toArray()
    )
    let staleResolution = completedFrom(
        astEditPipeline.invoke(
            astEditContext,
            resolutionWrite(
                "ast-edit-stale-resolve",
                "xd://resolve",
                "apply the structural rewrite"
            )
        )
    )
    expect(
        staleResolution.isError &&
            staleResolution.output.field("error_kind").getOrThrow().text == "conflict" &&
            String.fromUtf8(File.readFrom(root + "/ast/sample.py")) == externallyChanged,
        "ast_edit rejects stale previews before any file is modified"
    )
    let _ = completedFrom(
        astEditPipeline.invoke(
            astEditContext,
            resolutionWrite(
                "ast-edit-stale-reject",
                "xd://reject",
                "the preview is stale"
            )
        )
    )
    File.writeTo(root + "/ast/sample.py", astOriginal.toArray())
    let _ = completedFrom(
        astEditPipeline.invoke(
            astEditContext,
            astEditCall(
                "ast-edit-apply-preview",
                "return $VALUE",
                "return wrap($VALUE)",
                ["ast/sample.py"]
            )
        )
    )
    let applied = completedFrom(
        astEditPipeline.invoke(
            astEditContext,
            resolutionWrite(
                "ast-edit-apply",
                "xd://resolve",
                "apply the reviewed structural rewrite"
            )
        )
    )
    let appliedSource = String.fromUtf8(File.readFrom(root + "/ast/sample.py"))
    expect(
        applied.output.field("applied").getOrThrow().boolean && applied.output.field("action").getOrThrow().text ==
            "apply" && applied.output.field("content").getOrThrow().text.contains("Applied 2 replacements in 1 file.") &&
            applied.output.field("content").getOrThrow().text.contains("[ast/sample.py#") && appliedSource.contains(
            "return wrap(value)") && appliedSource.contains("return wrap(42)"),
        "xd://resolve atomically applies the reviewed AST edit"
    )
    match (astEditPipeline.invoke(
        astEditContext,
        resolutionWrite(
            "ast-edit-duplicate-resolve",
            "xd://resolve",
            "do not apply twice"
        )
    )) {
        case Result.Ok(ToolInvocationResult.Completed(result)) => expect(
            result.isError &&
                result.output.field("error").getOrThrow().text == "tool.ast_edit_no_pending",
            "resolved AST edits cannot be applied twice"
        )
        case _ => throw IllegalStateException("duplicate AST resolve was not denied")
    }
    match (astEditPipeline.invoke(
        astEditContext,
        astEditCallWithOps(
            "ast-edit-duplicate-pattern",
            [
                ["return $VALUE", "return first($VALUE)"],
                ["return $VALUE", "return second($VALUE)"]
            ],
            ["ast/sample.py"]
        )
    )) {
        case Result.Ok(ToolInvocationResult.Completed(result)) => expect(
            result.isError &&
                result.output.field("error").getOrThrow().text == "tool.invalid_argument" &&
                result.output.field("message").getOrThrow().text.contains(
                    "Duplicate rewrite pattern"
                ),
            "ast_edit rejects duplicate rewrite patterns"
        )
        case _ => throw IllegalStateException("duplicate ast_edit pattern was not denied")
    }
}

func runLspContracts(
    workspace: LocalWorkspace,
    processes: LocalProcessPort
): Unit {
    let lspCatalog = ToolCatalog()
    expect(
        installLocalTools(
            lspCatalog,
            workspace,
            processes
        ).isOk(),
        "install isolated LSP catalog"
    )
    let lspPipeline = ToolPipeline(
        lspCatalog,
        MemoryOperationRepository(),
        RecordingAuditPort(),
        ProductIds(),
        policy: DefaultCapabilityPolicy(mode: ApprovalMode.Yolo)
    )
    let lspContext = ToolInvocationContext(
        RunId("lsp-contract"),
        SessionId("lsp-contract"),
        CapabilitySet(
            values: [
                Capability(CapabilityKind.WorkspaceRead),
                Capability(CapabilityKind.WorkspaceWrite),
                Capability(CapabilityKind.ProcessSpawn)
            ]
        )
    )
    runLspQueryContracts(lspPipeline, lspContext)
    runLspMutationContracts(lspPipeline, lspContext, workspace)
    runLspResourceContracts(lspPipeline, lspContext, workspace)
}

func runLspQueryContracts(
    lspPipeline: ToolPipeline,
    lspContext: ToolInvocationContext
): Unit {
    let lspStatus = completedFrom(
        lspPipeline.invoke(
            lspContext,
            lspCall("lsp-status", "status")
        )
    )
    expect(
        !lspStatus.isError && lspStatus
            .output
            .field("content")
            .getOrThrow()
            .text
            .contains("pyright (configured, not started)"),
        "lsp status distinguishes configured and started servers"
    )
    let lspDefinition = completedFrom(
        lspPipeline.invoke(
            lspContext,
            lspCall(
                "lsp-definition",
                "definition",
                file: "lsp/use.py",
                line: 2,
                symbol: "greet"
            )
        )
    )
    expect(
        !lspDefinition.isError && lspDefinition.output.field("content").getOrThrow().text.contains("lsp/helper.py:1:"),
        "lsp definition comes from the live pyright server"
    )
    let lspReferences = completedFrom(
        lspPipeline.invoke(
            lspContext,
            lspCall(
                "lsp-references",
                "references",
                file: "lsp/helper.py",
                line: 1,
                symbol: "greet"
            )
        )
    )
    expect(
        !lspReferences.isError && lspReferences.output.field("content").getOrThrow().text.contains("reference"),
        "lsp references executes the project-aware request"
    )
    let lspHover = completedFrom(
        lspPipeline.invoke(
            lspContext,
            lspCall(
                "lsp-hover",
                "hover",
                file: "lsp/use.py",
                line: 2,
                symbol: "greet"
            )
        )
    )
    expect(
        !lspHover.isError && lspHover.output.field("content").getOrThrow().text.contains("greet"),
        "lsp hover returns server type information"
    )
    let lspSymbols = completedFrom(
        lspPipeline.invoke(
            lspContext,
            lspCall(
                "lsp-symbols",
                "symbols",
                file: "lsp/helper.py"
            )
        )
    )
    expect(
        !lspSymbols.isError && lspSymbols.output.field("content").getOrThrow().text.contains("greet @ line 1"),
        "lsp document symbols are structured and rendered"
    )
    let lspCapabilities = completedFrom(
        lspPipeline.invoke(
            lspContext,
            lspCall(
                "lsp-capabilities",
                "capabilities",
                file: "lsp/helper.py"
            )
        )
    )
    expect(
        !lspCapabilities.isError && lspCapabilities.output.field("content").getOrThrow().text.contains("hoverProvider"),
        "lsp capabilities report the initialized server response"
    )
    let lspRaw = completedFrom(
        lspPipeline.invoke(
            lspContext,
            lspCall(
                "lsp-raw",
                "request",
                file: "lsp/helper.py",
                query: "textDocument/documentSymbol"
            )
        )
    )
    expect(
        !lspRaw.isError && lspRaw.output.field("content").getOrThrow().text.contains("\"name\":\"greet\""),
        "lsp raw request forwards a real method and JSON result"
    )
}

func runLspMutationContracts(
    lspPipeline: ToolPipeline,
    lspContext: ToolInvocationContext,
    workspace: LocalWorkspace
): Unit {
    let root = workspace.rootPath()
    let beforeRename = String.fromUtf8(File.readFrom(root + "/lsp/helper.py"))
    let renamePreview = completedFrom(
        lspPipeline.invoke(
            lspContext,
            lspCall(
                "lsp-rename-preview",
                "rename",
                file: "lsp/helper.py",
                line: 1,
                symbol: "greet",
                newName: "salute",
                apply: false
            )
        )
    )
    expect(
        !renamePreview.isError && renamePreview.output.field("content").getOrThrow().text.contains("Rename preview") &&
            String.fromUtf8(File.readFrom(root + "/lsp/helper.py")) == beforeRename,
        "lsp rename preview does not mutate files"
    )
    let renameApplied = completedFrom(
        lspPipeline.invoke(
            lspContext,
            lspCall(
                "lsp-rename-apply",
                "rename",
                file: "lsp/helper.py",
                line: 1,
                symbol: "greet",
                newName: "salute",
                apply: true
            )
        )
    )
    expect(
        !renameApplied.isError && String.fromUtf8(File.readFrom(root + "/lsp/helper.py")).contains("def salute") &&
            String.fromUtf8(File.readFrom(root + "/lsp/use.py")).contains("salute"),
        "lsp rename atomically applies the server workspace edit: " + renameApplied
            .output
            .field("content")
            .getOrThrow()
            .text
    )
    let lspDiagnostics = completedFrom(
        lspPipeline.invoke(
            lspContext,
            lspCall(
                "lsp-diagnostics",
                "diagnostics",
                file: "lsp/broken.py"
            )
        )
    )
    expect(
        !lspDiagnostics.isError && lspDiagnostics.output.field("content").getOrThrow().text.contains("error") &&
            lspDiagnostics.output.field("content").getOrThrow().text.contains("lsp/broken.py:1:"),
        "lsp diagnostics consumes live publishDiagnostics results"
    )
    let lspCodeActions = completedFrom(
        lspPipeline.invoke(
            lspContext,
            lspCall(
                "lsp-code-actions",
                "code_actions",
                file: "lsp/broken.py",
                line: 1
            )
        )
    )
    expect(
        !lspCodeActions.isError,
        "lsp code_actions queries the live server without fake actions"
    )
    let workspaceSymbols = completedFrom(
        lspPipeline.invoke(
            lspContext,
            lspCall(
                "lsp-workspace-symbols",
                "symbols",
                file: "*",
                query: "salute"
            )
        )
    )
    expect(
        !workspaceSymbols.isError && workspaceSymbols.output.field("content").getOrThrow().text.contains("salute"),
        "lsp workspace symbols aggregate initialized project servers"
    )
    let renameFilePreview = completedFrom(
        lspPipeline.invoke(
            lspContext,
            lspCall(
                "lsp-rename-file-preview",
                "rename_file",
                file: "lsp/move_me.py",
                newName: "lsp/moved.py",
                apply: false
            )
        )
    )
    expect(
        !renameFilePreview.isError && exists(Path(root + "/lsp/move_me.py")) && !exists(Path(root + "/lsp/moved.py")),
        "lsp rename_file preview leaves the filesystem unchanged: is_error=" +
            renameFilePreview.isError.toString() + " source=" +
            exists(Path(root + "/lsp/move_me.py")).toString() + " destination=" +
            exists(Path(root + "/lsp/moved.py")).toString() + " output=" +
            renameFilePreview.output.stringify()
    )
    let renameFileApplied = completedFrom(
        lspPipeline.invoke(
            lspContext,
            lspCall(
                "lsp-rename-file-apply",
                "rename_file",
                file: "lsp/move_me.py",
                newName: "lsp/moved.py",
                apply: true
            )
        )
    )
    expect(
        !renameFileApplied.isError && !exists(Path(root + "/lsp/move_me.py")) && exists(Path(root + "/lsp/moved.py")),
        "lsp rename_file applies the reviewed filesystem rename"
    )
    let lspReload = completedFrom(
        lspPipeline.invoke(
            lspContext,
            lspCall(
                "lsp-reload",
                "reload",
                file: "lsp/helper.py"
            )
        )
    )
    expect(
        !lspReload.isError && lspReload.output.field("content").getOrThrow().text.contains("Reloaded pyright"),
        "lsp reload replaces the persistent server process"
    )
}

func runLspResourceContracts(
    lspPipeline: ToolPipeline,
    lspContext: ToolInvocationContext,
    workspace: LocalWorkspace
): Unit {
    let root = workspace.rootPath()
    let lspResourceEdit = completedFrom(
        lspPipeline.invoke(
            lspContext,
            lspCall(
                "lsp-resource-edit",
                "code_actions",
                file: "lsp/sample.resource",
                line: 1,
                query: "0",
                apply: true
            )
        )
    )
    expect(
        !lspResourceEdit.isError && !exists(Path(root + "/lsp/resource-created.txt")) && exists(
            Path(root + "/lsp/nested/resource-renamed.txt")) &&
            String.fromUtf8(File.readFrom(root + "/lsp/nested/resource-renamed.txt")) == "renamed:created\n" &&
            !exists(Path(root + "/lsp/delete_me.txt")),
        "lsp applies ordered create, text, rename, and delete operations"
    )
    let lspResourceRollback = lspPipeline.invoke(
        lspContext,
        lspCall(
            "lsp-resource-rollback",
            "code_actions",
            file: "lsp/sample.resource",
            line: 1,
            query: "1",
            apply: true
        )
    )
    expect(
        toolOutcomeFailed(lspResourceRollback),
        "lsp rollback failure returns a call-bound tool error"
    )
    expect(
        !exists(Path(root + "/lsp/rollback-created.txt")) && !exists(Path(root + "/lsp/nested/rollback-renamed.txt")) &&
            exists(Path(root + "/lsp/rollback_delete.txt")) &&
            String.fromUtf8(File.readFrom(root + "/lsp/rollback_delete.txt")) == "restore me\n",
        "lsp rolls back prior resource operations when a later edit fails"
    )
    let lspServerApply = completedFrom(
        lspPipeline.invoke(
            lspContext,
            lspCall(
                "lsp-server-apply",
                "code_actions",
                file: "lsp/sample.resource",
                line: 1,
                query: "2",
                apply: true
            )
        )
    )
    expect(
        !lspServerApply.isError && exists(Path(root + "/lsp/server-applied.txt")) &&
            String.fromUtf8(File.readFrom(root + "/lsp/server-applied.txt")) == "from server request\n",
        "write LSP actions honor real workspace/applyEdit requests"
    )
    let lspReadOnlyApply = completedFrom(
        lspPipeline.invoke(
            lspContext,
            lspCall(
                "lsp-readonly-apply",
                "hover",
                file: "lsp/sample.resource",
                line: 1
            )
        )
    )
    expect(
        !lspReadOnlyApply.isError && lspReadOnlyApply
            .output
            .field("content")
            .getOrThrow()
            .text
            .contains("applied=False") && !exists(Path(root + "/lsp/forbidden-server-edit.txt")),
        "read-only LSP actions reject workspace/applyEdit mutations"
    )
}

func runCheckpointContracts(
    workspace: LocalWorkspace,
    processes: LocalProcessPort
): Unit {
    let root = workspace.rootPath()
    let database = SqliteDatabase(root + "/checkpoint-contract.db")
    let checkpointSession = SessionId("checkpoint-contract")
    let activeMessages = checkpointContractMessages(false)
    expect(
        SqliteThreadSeedStore(database).createCompleted(
            completedThreadSeedSnapshot(
                ThreadId(checkpointSession.value), root, activeMessages,
                createdAtMillis: 1
            )
        ).isOk(),
        "seed canonical checkpoint Thread"
    )
    let checkpointCatalog = ToolCatalog()
    expect(
        installLocalTools(
            checkpointCatalog,
            workspace,
            processes,
            checkpointDatabase: Some(database)
        ).isOk(),
        "install checkpoint tools with the canonical store"
    )
    expectToolSchema(
        checkpointCatalog,
        "checkpoint",
        ["goal"],
        ["goal"]
    )
    expectToolSchema(
        checkpointCatalog,
        "rewind",
        ["report"],
        ["report"]
    )
    let checkpointPipeline = ToolPipeline(
        checkpointCatalog,
        MemoryOperationRepository(),
        RecordingAuditPort(),
        ProductIds(),
        policy: DefaultCapabilityPolicy(mode: ApprovalMode.Yolo)
    )
    let checkpointContext = ToolInvocationContext(
        RunId("checkpoint-contract"),
        checkpointSession,
        CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])
    )
    expect(
        toolOutcomeFailed(checkpointPipeline.invoke(
            checkpointContext,
            ToolCall(
                "checkpoint-nested",
                "checkpoint",
                objectValue(
                    [
                        ValueField(
                            "goal",
                            textValue("nested investigation")
                        )
                    ]
                )
            )
        )),
        "checkpoint rejects a nested active checkpoint"
    )
    expect(!toolOutcomeFailed(checkpointPipeline.invoke(
        checkpointContext,
        ToolCall(
            "rewind-call",
            "rewind",
            objectValue([ValueField(
                "report", textValue("The parser boundary is in decode().")
            )])
        )
    )), "active canonical checkpoint accepts rewind")
    database.close()
    runRewindContract(workspace, processes)
}

func runRewindContract(
    workspace: LocalWorkspace,
    processes: LocalProcessPort
): Unit {
    let root = workspace.rootPath()
    let database = SqliteDatabase(root + "/rewind-contract.db")
    let checkpointSession = SessionId("rewind-contract")
    expect(SqliteThreadSeedStore(database).createCompleted(
        completedThreadSeedSnapshot(
            ThreadId(checkpointSession.value), root,
            checkpointContractMessages(true), createdAtMillis: 1
        )
    ).isOk(), "seed canonical completed rewind Thread")
    let restartedCheckpointCatalog = ToolCatalog()
    expect(
        installLocalTools(
            restartedCheckpointCatalog,
            workspace,
            processes,
            checkpointDatabase: Some(database)
        ).isOk(),
        "reinstall checkpoint tools after simulated restart"
    )
    let restartedCheckpointPipeline = ToolPipeline(
        restartedCheckpointCatalog,
        MemoryOperationRepository(),
        RecordingAuditPort(),
        ProductIds(),
        policy: DefaultCapabilityPolicy(mode: ApprovalMode.Yolo)
    )
    let checkpointContext = ToolInvocationContext(
        RunId("rewind-contract"), checkpointSession,
        CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])
    )
    let rewindResult = ToolResult(
        "rewind-call",
        objectValue([
            ValueField("content", textValue("Rewind requested.")),
            ValueField("report", textValue("The parser boundary is in decode().")),
            ValueField("rewound", boolValue(true)),
            ValueField("rewound_at", textValue("2026-08-11T00:00:00Z"))
        ])
    )
    expect(
        restartedCheckpointPipeline.afterResultPersisted(
            checkpointContext,
            "rewind",
            ToolInvocationResult.Completed(rewindResult)
        ).isOk(),
        "identical rewind result replay is idempotent"
    )
    let conflictingRewind = ToolResult(
        rewindResult.callId,
        objectValue([
            ValueField("content", textValue("Rewind requested.")),
            ValueField("report", textValue("different persisted report")),
            ValueField("rewound", boolValue(true)),
            ValueField(
                "rewound_at",
                rewindResult.output.field("rewound_at").getOrThrow()
            )
        ])
    )
    expect(
        restartedCheckpointPipeline.afterResultPersisted(
            checkpointContext,
            "rewind",
            ToolInvocationResult.Completed(conflictingRewind)
        ).isError(),
        "rewind receipt rejects different report content under the same checkpoint"
    )
    let thread = SqliteThreadCommitSink(database).loadThread(
        ThreadId(checkpointSession.value)
    )
    let checkpoint = SqliteContextCheckpointStore(database).loadLatest(
        thread, "agent-product-v1", "agent-core"
    ).getOrThrow()
    expect(
        checkpoint.coversThroughItemOrdinal == thread.items[thread.items.size - 1].ordinal &&
            checkpoint.structuredSummary.field("deterministic_summary")
                .getOrThrow().text.contains("The parser boundary is in decode().") &&
            conversationContains(modelMessagesFromCanonicalItems(thread.items), "scratch exploration"),
        "rewind saves a disposable projection while preserving canonical exploration"
    )
    expect(
        toolOutcomeFailed(restartedCheckpointPipeline.invoke(
            checkpointContext,
            ToolCall(
                "rewind-repeat",
                "rewind",
                objectValue(
                    [
                        ValueField(
                            "report",
                            textValue("repeat")
                        )
                    ]
                )
            )
        )),
        "completed checkpoint cannot be rewound twice"
    )
    database.close()
}

func checkpointContractMessages(completed: Bool): Array<ModelMessage> {
    let messages = ArrayList<ModelMessage>()
    messages.add(ModelMessage(ModelRole.User, [
        ModelBlock(ModelBlockKind.Text, text: "Investigate the parser.")
    ]))
    messages.add(ModelMessage(ModelRole.Assistant, [ModelBlock(
        ModelBlockKind.ToolCall, callId: "checkpoint-call", name: "checkpoint",
        arguments: objectValue([ValueField(
            "goal", textValue("find the parser boundary")
        )])
    )]))
    messages.add(ModelMessage(ModelRole.User, [ModelBlock(
        ModelBlockKind.ToolResult, callId: "checkpoint-call", name: "checkpoint",
        arguments: objectValue([
            ValueField("content", textValue("Checkpoint created.")),
            ValueField("goal", textValue("find the parser boundary")),
            ValueField("started_at", textValue("2026-08-11T00:00:00Z"))
        ])
    )]))
    messages.add(ModelMessage(ModelRole.User, [ModelBlock(
        ModelBlockKind.Text, text: "scratch exploration that remains canonical"
    )]))
    if (completed) {
        messages.add(ModelMessage(ModelRole.Assistant, [ModelBlock(
            ModelBlockKind.ToolCall, callId: "rewind-call", name: "rewind",
            arguments: objectValue([ValueField(
                "report", textValue("The parser boundary is in decode().")
            )])
        )]))
        messages.add(ModelMessage(ModelRole.User, [ModelBlock(
            ModelBlockKind.ToolResult, callId: "rewind-call", name: "rewind",
            arguments: objectValue([
                ValueField("content", textValue("Rewind requested.")),
                ValueField("report", textValue("The parser boundary is in decode().")),
                ValueField("rewound", boolValue(true)),
                ValueField("rewound_at", textValue("2026-08-11T00:00:00Z"))
            ])
        )]))
    }
    messages.toArray()
}

func runTodoToolContracts(
    pipeline: ToolPipeline,
    context: ToolInvocationContext,
    todoRepository: SessionMetadataRepository,
    initializedTodos: ToolResult,
    database: SqliteDatabase
): Unit {
    runTodoMutationContracts(
        pipeline,
        context,
        initializedTodos
    )
    runTodoViewContracts(
        pipeline,
        context,
        todoRepository,
        database
    )
}

func runTodoMutationContracts(
    pipeline: ToolPipeline,
    context: ToolInvocationContext,
    initializedTodos: ToolResult
): Unit {
    let initializedPhases = decodeTodoPhases(initializedTodos.output.field("phases").getOrThrow()).value().getOrThrow()
    expect(
        !initializedTodos.isError && initializedTodos.output.field("op").getOrThrow().text == "init" &&
            initializedPhases.size == 2 && initializedPhases[0].tasks[0].status == TodoStatus.InProgress &&
            initializedPhases[0].tasks[1].status == TodoStatus.Pending,
        "todo initializes explicitly and promotes the first pending task"
    )
    expect(
        completedFrom(
            pipeline.invoke(
                context,
                todoCall(
                    "todo-start",
                    "start",
                    task: "Wire"
                )
            )
        )
            .output
            .field("phases")
            .getOrThrow()
            .items[0]
            .field("tasks")
            .getOrThrow()
            .items[1]
            .field("status")
            .getOrThrow()
            .text == "in_progress",
        "todo start selects exactly one active task"
    )
    let doneResult = completedFrom(
        pipeline.invoke(
            context,
            todoCall("todo-done", "done", task: "Wire")
        )
    )
    expect(
        doneResult.output.field("completedTasks").getOrThrow().items.size == 1 &&
            decodeTodoPhases(doneResult.output.field("phases").getOrThrow()).value().getOrThrow()[0].tasks[0].status == TodoStatus
            .InProgress,
        "todo done reports completion and advances pending work"
    )
    let blockedResult = completedFrom(
        pipeline.invoke(
            context,
            todoCall(
                "todo-block",
                "block",
                task: "Scaffold",
                reason: "waiting\n  for input"
            )
        )
    )
    let blockedPhases = decodeTodoPhases(blockedResult.output.field("phases").getOrThrow()).value().getOrThrow()
    expect(
        blockedPhases[0].tasks[0].status == TodoStatus.Blocked && blockedPhases[0].tasks[0].blocker ==
            "waiting for input" && blockedPhases[1].tasks[0].status == TodoStatus.InProgress,
        "todo block normalizes its reason and advances other work"
    )
    let unblockedPhases = decodeTodoPhases(completedFrom(
        pipeline.invoke(
            context,
            todoCall(
                "todo-unblock",
                "unblock",
                task: "Scaffold"
            )
        )
    ).output.field("phases").getOrThrow()).value().getOrThrow()
    expect(
        unblockedPhases[0].tasks[0].status == TodoStatus.Pending && unblockedPhases[0].tasks[0].blocker == "",
        "todo unblock restores blocked work to pending"
    )
    expect(
        completedFrom(
            pipeline.invoke(
                context,
                todoCall(
                    "todo-append",
                    "append",
                    phase: "Verification",
                    items: ["Review"]
                )
            )
        ).output.field("phases").getOrThrow().items[1].field("tasks").getOrThrow().items.size == 2,
        "todo append adds tasks to an existing phase"
    )
    let duplicateAppend = completedFrom(
        pipeline.invoke(
            context,
            todoCall(
                "todo-append-duplicate",
                "append",
                phase: "Verification",
                items: ["Review", "Publish"]
            )
        )
    )
    expect(
        duplicateAppend.isError &&
            duplicateAppend.output.field("phases").getOrThrow().items[1].field("tasks").getOrThrow().items.size == 2,
        "todo rejects a duplicate append atomically"
    )
    expect(
        !completedFrom(
            pipeline.invoke(
                context,
                todoCall(
                    "todo-drop",
                    "drop",
                    phase: "Verification"
                )
            )
        ).isError,
        "todo drop closes every task in a phase"
    )
    let removedTaskPhases = decodeTodoPhases(completedFrom(
        pipeline.invoke(
            context,
            todoCall("todo-rm-task", "rm", task: "Wire")
        )
    ).output.field("phases").getOrThrow()).value().getOrThrow()
    expect(
        removedTaskPhases[0].tasks.size == 1 && removedTaskPhases[0].tasks[0].content == "Scaffold",
        "todo rm removes one task by exact content"
    )
    expect(
        !completedFrom(
            pipeline.invoke(
                context,
                todoCall(
                    "todo-append-cleanup",
                    "append",
                    phase: "Cleanup",
                    items: ["Clean"]
                )
            )
        ).isError && !completedFrom(
            pipeline.invoke(
                context,
                todoCall(
                    "todo-rm-phase",
                    "rm",
                    phase: "Cleanup"
                )
            )
        ).isError,
        "todo append creates phases and rm can clear one phase"
    )
}

func runTodoViewContracts(
    pipeline: ToolPipeline,
    context: ToolInvocationContext,
    todoRepository: SessionMetadataRepository,
    database: SqliteDatabase
): Unit {
    let beforeView = [
        TodoPhase(
            "Manual",
            [
                TodoItem(
                    "First",
                    status: TodoStatus.InProgress
                ),
                TodoItem(
                    "Second",
                    status: TodoStatus.InProgress
                )
            ]
        )
    ]
    expect(
        todoRepository.setTodoPhases(
            context.sessionId,
            encodeTodoPhases(beforeView)
        ).isOk(),
        "prepare unnormalized persisted todo state"
    )
    let viewed = completedFrom(
        pipeline.invoke(
            context,
            todoCall("todo-view", "view")
        )
    )
    let viewedPhases = decodeTodoPhases(viewed.output.field("phases").getOrThrow()).value().getOrThrow()
    let persistedAfterView = decodeTodoPhases(todoRepository.todoPhases(context.sessionId).value().getOrThrow())
        .value()
        .getOrThrow()
    expect(
        viewedPhases[0].tasks[0].status == TodoStatus.InProgress && viewedPhases[0].tasks[1].status == TodoStatus
            .InProgress && persistedAfterView[0].tasks[1].status == TodoStatus.InProgress,
        "todo view is pure and does not normalize or rewrite state"
    )
    let clearedTodos = completedFrom(
        pipeline.invoke(
            context,
            todoCall("todo-rm-all", "rm")
        )
    )
    expect(
        clearedTodos.output.field("phases").getOrThrow().items[0].field("tasks").getOrThrow().items.isEmpty() &&
            SqliteSessionMetadataRepository(database).todoPhases(context.sessionId).isOk(),
        "todo rm clears all tasks and state survives repository restart"
    )
    expect(
        pipeline.invoke(
            context,
            ToolCall(
                "read-1",
                "read",
                objectValue([ValueField("path", textValue("note.txt"))])
            )
        ).isOk(),
        "read executes safely"
    )
    expect(
        completedFrom(
            pipeline.invoke(
                context,
                ToolCall(
                    "read-extensionless",
                    "read",
                    objectValue([ValueField("path", textValue("Makefile"))])
                )
            )
        ).output.field("content").getOrThrow().text.contains("@echo product"),
        "read accepts extensionless text files"
    )
}

func runWorkspaceAndEvalContracts(
    pipeline: ToolPipeline,
    context: ToolInvocationContext,
    workspace: LocalWorkspace,
    processes: LocalProcessPort
): Unit {
    runWorkspaceReadEditBashContracts(
        pipeline,
        context,
        workspace
    )
    runEvalContracts(pipeline, context, workspace, processes)
    runPersistentShellContracts(pipeline, context, processes)
}

func runWorkspaceReadEditBashContracts(
    pipeline: ToolPipeline,
    context: ToolInvocationContext,
    workspace: LocalWorkspace
): Unit {
    runWorkspaceReadContracts(
        pipeline,
        context
    )
    runWorkspaceEditAndBashContracts(
        pipeline,
        context,
        workspace
    )
}

func runWorkspaceReadContracts(
    pipeline: ToolPipeline,
    context: ToolInvocationContext
): Unit {
    let largePrefix = largeLinesPrefix()
    let rangedRead = completedFrom(
        pipeline.invoke(
            context,
            ToolCall(
                "read-range",
                "read",
                objectValue(
                    [
                        ValueField("path", textValue("lines.txt")),
                        ValueField("offset", integerValue(2)),
                        ValueField("limit", integerValue(1))
                    ]
                )
            )
        )
    )
    expect(
        rangedRead.output.field("content").getOrThrow().text.contains("\n2:two") && rangedRead
            .output
            .field("truncated")
            .getOrThrow()
            .boolean,
        "read honors line ranges and reports truncation"
    )
    let inlineRead = completedFrom(
        pipeline.invoke(
            context,
            ToolCall(
                "read-inline",
                "read",
                objectValue([ValueField("path", textValue("lines.txt:2-2"))])
            )
        )
    )
    expect(
        inlineRead.output.field("content").getOrThrow().text.contains("\n2:two"),
        "read accepts the OMP inline line selector"
    )
    let lateRangeRead = completedFrom(
        pipeline.invoke(
            context,
            ToolCall(
                "read-late-range",
                "read",
                objectValue(
                    [
                        ValueField(
                            "path",
                            textValue("large-lines.txt:2-2")
                        )
                    ]
                )
            )
        )
    )
    expect(
        lateRangeRead.output.field("content").getOrThrow().text.contains("\n2:target-after-megabyte") &&
            lateRangeRead
            .output
            .field("content")
            .getOrThrow()
            .text
            .startsWith("[large-lines.txt#" + hashlineTag(largePrefix + "\ntarget-after-megabyte\n") + "]"),
        "read ranges beyond one MiB retain a full-file hashline anchor"
    )
    let directoryRead = completedFrom(
        pipeline.invoke(
            context,
            ToolCall(
                "read-dir",
                "read",
                objectValue([ValueField("path", textValue("."))])
            )
        )
    )
    expect(
        directoryRead.output.field("entries").getOrThrow().text.contains("lines.txt") &&
            directoryRead.output.field("total_count").getOrThrow().number == directoryRead
            .output
            .field("count")
            .getOrThrow()
            .number && directoryRead.output.field("returned_bytes").isSome() &&
            !directoryRead.output.field("truncated").getOrThrow().boolean,
        "read lists directories with bounded-output metadata"
    )
    expect(
        hashlineTag("before\n") == "F27C",
        "hashline tag matches the pinned OMP xxHash32 format"
    )
    let searchResult = pipeline.invoke(
        context,
        ToolCall(
            "search-1",
            "grep",
            objectValue(
                [
                    ValueField("pattern", textValue("before")),
                    ValueField("path", textValue("."))
                ]
            )
        )
    )
    match (searchResult) {
        case Result.Ok(_) => ()
        case Result.Err(error) => throw IllegalStateException("search_files failed: " + error.code + " " + error.message)
    }
}

func runWorkspaceEditAndBashContracts(
    pipeline: ToolPipeline,
    context: ToolInvocationContext,
    workspace: LocalWorkspace
): Unit {
    runHashlineContractAlignment(workspace)
    let root = workspace.rootPath()
    let editApproval = approvalFrom(
        pipeline.invoke(
            context,
            ToolCall(
                "edit-1",
                "edit",
                objectValue(
                    [
                        ValueField(
                            "input",
                            textValue("[note.txt#F27C]\n" + "SWAP 1..=1:\n" + "+after")
                        )
                    ]
                )
            )
        )
    )
    let editDetails = approvalDetails(editApproval)
    expect(
        editDetails.operationId.value == editApproval.operationId.value && editDetails.callId == "edit-1" &&
            editDetails.toolName == "edit" && editDetails.capability.kind == CapabilityKind.WorkspaceWrite &&
            approvalRiskName(editDetails.risk) == "low" && editDetails.metadata.capabilityLabel == "workspace.write" &&
            editDetails.arguments.field("input").isSome(),
        "approval presentation preserves the shared RPC/TUI preview fields"
    )
    expect(
        pipeline.decide(
            context,
            editApproval.operationId,
            ApprovalDecision.Approve
        ).isOk(),
        "approved edit executes"
    )
    expect(
        String.fromUtf8(File.readFrom(root + "/note.txt")) == "after\n",
        "hashline edit changed the anchored line"
    )
    File.writeTo(root + "/multi-a.txt", "alpha\n".toArray())
    File.writeTo(root + "/multi-b.txt", "beta\n".toArray())
    let multiEdit = approvalFrom(
        pipeline.invoke(
            context,
            ToolCall(
                "edit-multi",
                "edit",
                objectValue(
                    [
                        ValueField(
                            "input",
                            textValue(
                                "[multi-a.txt#" + hashlineTag("alpha\n") + "]\n" + "SWAP 1..=1:\n+A\n" + "[multi-b.txt#" +
                                    hashlineTag("beta\n") + "]\n" + "SWAP 1..=1:\n+B")
                        )
                    ]
                )
            )
        )
    )
    expect(
        pipeline.decide(
            context,
            multiEdit.operationId,
            ApprovalDecision.Approve
        ).isOk() && String.fromUtf8(File.readFrom(root + "/multi-a.txt")) == "A\n" &&
            String.fromUtf8(File.readFrom(root + "/multi-b.txt")) == "B\n",
        "multi-file hashline edit commits atomically"
    )
    File.writeTo(root + "/multi-a.txt", "fresh-a\n".toArray())
    File.writeTo(root + "/multi-b.txt", "fresh-b\n".toArray())
    let staleApproval = approvalFrom(
        pipeline.invoke(
            context,
            ToolCall(
                "edit-stale-multi",
                "edit",
                objectValue(
                    [
                        ValueField(
                            "input",
                            textValue(
                                "[multi-a.txt#" + hashlineTag("fresh-a\n") + "]\n" + "SWAP 1..=1:\n+changed-a\n" +
                                    "[multi-b.txt#0000]\n" + "SWAP 1..=1:\n+changed-b")
                        )
                    ]
                )
            )
        )
    )
    expect(
        toolOutcomeFailed(pipeline.decide(
            context,
            staleApproval.operationId,
            ApprovalDecision.Approve
        )) && String.fromUtf8(File.readFrom(root + "/multi-a.txt")) == "fresh-a\n" &&
            String.fromUtf8(File.readFrom(root + "/multi-b.txt")) == "fresh-b\n",
        "one stale anchor prevents every file in the transaction"
    )
    let bashApproval = approvalFrom(
        pipeline.invoke(
            context,
            ToolCall(
                "bash-1",
                "bash",
                objectValue(
                    [
                        ValueField(
                            "command",
                            textValue(
                                "export AXYNDRA_CONTRACT=kept && " + "mkdir -p nested && cd nested && " +
                                    "printf product-ok")
                        )
                    ]
                )
            )
        )
    )
    expect(
        pipeline.decide(
            context,
            bashApproval.operationId,
            ApprovalDecision.ApproveSession
        ).isOk(),
        "approved bash executes"
    )
}

func runHashlineContractAlignment(workspace: LocalWorkspace): Unit {
    let content = "one\ntwo\nthree\n"
    let header = "[contract.txt#" + hashlineTag(content) + "]\n"
    expectHashlineReplacement(
        header + "SWAP 2..=3:\n+second\n+third",
        content,
        "one\nsecond\nthird\n",
        "documented multiline SWAP range is accepted"
    )
    expectHashlineRejected(
        header + "SWAP 2.=3:\n+legacy",
        content,
        "edit.invalid_hashline",
        "expected [path#TAG]",
        "undocumented malformed range is rejected with actionable grammar"
    )
    expectHashlineRejected(
        "[contract.txt#0000]\nSWAP 2:\n+stale",
        content,
        "edit.stale_anchor",
        "current file",
        "stale target is rejected"
    )
    expectHashlineRejected(
        header + "SWAP 1:\n+first\nDEL 1",
        content,
        "edit.invalid_hashline",
        "overlap",
        "overlapping target is deterministically rejected"
    )
    expectHashlineReplacement(
        header + "DEL 2..=3",
        content,
        "one\n",
        "documented delete range is accepted"
    )
    expectHashlineReplacement(
        header + "INS.POST 1:\n+inserted",
        content,
        "one\ninserted\ntwo\nthree\n",
        "documented insert is accepted"
    )
    match (applyHashlineEdit(
        "[missing.txt#0000]\nSWAP 1:\n+x",
        {path => match (workspace.read(WorkspaceReadRequest(path))) {
            case Result.Ok(value) => Result.Ok(value.content)
            case Result.Err(error) => Result.Err(error)
        }}
    )) {
        case Result.Err(error) => expect(
            error.code == "workspace.read",
            "missing edit target is rejected by the workspace"
        )
        case Result.Ok(_) => expect(false, "missing edit target must not be accepted")
    }
    match (applyHashlineEdit(
        "[../outside.txt#0000]\nSWAP 1:\n+x",
        {path => match (workspace.read(WorkspaceReadRequest(path))) {
            case Result.Ok(value) => Result.Ok(value.content)
            case Result.Err(error) => Result.Err(error)
        }}
    )) {
        case Result.Err(error) => expect(
            error.code == "workspace.path_escape",
            "edit path outside the workspace is rejected"
        )
        case Result.Ok(_) => expect(false, "outside edit target must not be accepted")
    }
}

func expectHashlineReplacement(
    input: String,
    current: String,
    expected: String,
    message: String
): Unit {
    match (applyHashlineEdit(input, {_ => Result.Ok(current)})) {
        case Result.Ok(mutation) => expect(mutation.replacement == expected, message)
        case Result.Err(error) => throw IllegalStateException(
            message + ": " + error.code + " " + error.message
        )
    }
}

func expectHashlineRejected(
    input: String,
    current: String,
    code: String,
    messageFragment: String,
    message: String
): Unit {
    match (applyHashlineEdit(input, {_ => Result.Ok(current)})) {
        case Result.Err(error) => expect(
            error.code == code && error.message.contains(messageFragment),
            message
        )
        case Result.Ok(_) => expect(false, message)
    }
}

func runEvalContracts(
    pipeline: ToolPipeline,
    context: ToolInvocationContext,
    workspace: LocalWorkspace,
    processes: LocalProcessPort
): Unit {
    let pythonFirst = completedFrom(
        pipeline.invoke(
            context,
            evalCall(
                "eval-py-first",
                "py",
                "counter = 40\ncounter + 2",
                reset: true
            )
        )
    )
    expect(
        !pythonFirst.isError && pythonFirst.output.field("content").getOrThrow().text.trimAscii() == "42",
        "python eval executes a real cell"
    )
    let pythonPersistent = completedFrom(
        pipeline.invoke(
            context,
            evalCall(
                "eval-py-persistent",
                "py",
                "counter += 1\ncounter"
            )
        )
    )
    expect(
        !pythonPersistent.isError && pythonPersistent.output.field("content").getOrThrow().text.trimAscii() == "41",
        "python eval preserves state across calls"
    )
    let pythonTimeout = completedFrom(
        pipeline.invoke(
            context,
            evalCall(
                "eval-py-timeout",
                "py",
                "import time\ntime.sleep(2)",
                timeout: 1
            )
        )
    )
    expect(
        pythonTimeout.isError && pythonTimeout.output.field("timed_out").getOrThrow().boolean &&
            pythonTimeout.output.field("content").getOrThrow().text.contains("timed out"),
        "python eval enforces the cell timeout"
    )
    let pythonAfterTimeout = completedFrom(
        pipeline.invoke(
            context,
            evalCall(
                "eval-py-after-timeout",
                "py",
                "counter"
            )
        )
    )
    expect(
        !pythonAfterTimeout.isError && pythonAfterTimeout.output.field("content").getOrThrow().text.trimAscii() == "41",
        "python eval kernel remains reusable after timeout"
    )
    runEvalCancellationContract(workspace, processes)
    runEvalLanguageContracts(pipeline, context)
}

func runEvalCancellationContract(
    workspace: LocalWorkspace,
    processes: LocalProcessPort
): Unit {
    let cancelCatalog = ToolCatalog()
    expect(
        installLocalTools(
            cancelCatalog,
            workspace,
            processes
        ).isOk(),
        "install isolated eval cancellation catalog"
    )
    let cancelPipeline = ToolPipeline(
        cancelCatalog,
        MemoryOperationRepository(),
        RecordingAuditPort(),
        ProductIds(),
        policy: DefaultCapabilityPolicy(mode: ApprovalMode.Yolo)
    )
    let cancelContext = ToolInvocationContext(
        RunId("eval-cancel-contract"),
        SessionId("eval-cancel-contract"),
        CapabilitySet(values: [Capability(CapabilityKind.ProcessSpawn)])
    )
    let cancelledEvalFuture = spawn {
        cancelPipeline.invoke(
            cancelContext,
            evalCall(
                "eval-py-cancel",
                "py",
                "import time\ntime.sleep(10)"
            )
        )
    }
    var activeObserved = false
    for (_ in 0..500) {
        if (processes.hasActiveOperation(
            OperationId("eval-" + cancelContext.runId.value)
        )) {
            activeObserved = true
            break
        }
        sleep(Duration.millisecond * 10)
    }
    expect(
        activeObserved && cancelPipeline.cancel(cancelContext.runId).isOk(),
        "eval cancellation reaches the active runtime"
    )
    let cancelledEval = completedFrom(cancelledEvalFuture.get())
    expect(
        cancelledEval.isError &&
            cancelledEval.output.field("status").getOrThrow().text == "error" &&
            cancelledEval.output.field("exit_code").getOrThrow().number != "0",
        "cancelled eval reports a failed cell instead of fake success"
    )
}

func runEvalLanguageContracts(
    pipeline: ToolPipeline,
    context: ToolInvocationContext
): Unit {
    let pythonReset = completedFrom(
        pipeline.invoke(
            context,
            evalCall(
                "eval-py-reset",
                "py",
                "globals().get('counter', 'missing')",
                reset: true
            )
        )
    )
    expect(
        !pythonReset.isError && pythonReset.output.field("content").getOrThrow().text.trimAscii() == "missing",
        "python eval reset clears only the selected runtime"
    )
    let javascriptFirst = completedFrom(
        pipeline.invoke(
            context,
            evalCall(
                "eval-js-first",
                "js",
                "let value = 7; value",
                reset: true
            )
        )
    )
    let javascriptPersistent = completedFrom(
        pipeline.invoke(
            context,
            evalCall(
                "eval-js-persistent",
                "js",
                "value += 2; value"
            )
        )
    )
    expect(
        !javascriptFirst.isError && javascriptFirst.output.field("content").getOrThrow().text.trimAscii() == "7" &&
            !javascriptPersistent.isError &&
            javascriptPersistent.output.field("content").getOrThrow().text.trimAscii() == "9",
        "javascript eval executes and preserves VM bindings"
    )
    let javascriptFailure = completedFrom(
        pipeline.invoke(
            context,
            evalCall(
                "eval-js-error",
                "js",
                "throw new Error('eval-contract-error')"
            )
        )
    )
    expect(
        javascriptFailure.isError && javascriptFailure
            .output
            .field("content")
            .getOrThrow()
            .text
            .contains("eval-contract-error"),
        "javascript eval surfaces runtime failures as tool errors"
    )
    let rubyFirst = completedFrom(
        pipeline.invoke(
            context,
            evalCall(
                "eval-rb-first",
                "rb",
                "counter = 5\ncounter",
                reset: true
            )
        )
    )
    let rubyPersistent = completedFrom(
        pipeline.invoke(
            context,
            evalCall(
                "eval-rb-persistent",
                "rb",
                "counter += 2\ncounter"
            )
        )
    )
    expect(
        !rubyFirst.isError && rubyFirst.output.field("content").getOrThrow().text.trimAscii() == "5" &&
            !rubyPersistent.isError && rubyPersistent.output.field("content").getOrThrow().text.trimAscii() == "7",
        "ruby eval executes and preserves binding state"
    )
}

func runPersistentShellContracts(
    pipeline: ToolPipeline,
    context: ToolInvocationContext,
    processes: LocalProcessPort
): Unit {
    let persistedShell = completedFrom(
        pipeline.invoke(
            context,
            ToolCall(
                "bash-2",
                "bash",
                objectValue(
                    [
                        ValueField(
                            "command",
                            textValue("printf \"$AXYNDRA_CONTRACT:\"; pwd")
                        )
                    ]
                )
            )
        )
    )
    let isolatedStdout = persistedShell.output.field("stdout")
        .getOrThrow().text.trimAscii()
    let isolatedCwd = persistedShell.output.field("cwd")
        .getOrThrow().text
    expect(
        isolatedStdout == "kept:" + isolatedCwd && isolatedCwd.endsWith("/nested"),
        "sandboxed persistent bash retains session state inside one isolation profile"
    )
    let emptyInputCommand = completedFrom(
        pipeline.invoke(
            context,
            ToolCall(
                "bash-empty-input",
                "bash",
                objectValue(
                    [
                        ValueField(
                            "command",
                            textValue(
                                "head -2 $(find . -type f -name 'definitely-missing-testrunner' 2>/dev/null | head -1) 2>/dev/null; printf marker-ok")
                        )
                    ]
                )
            )
        )
    )
    expect(
        emptyInputCommand.output.field("stdout").getOrThrow().text.contains("marker-ok"),
        "persistent shell does not consume completion markers as command stdin"
    )
    let binaryOutput = completedFrom(
        pipeline.invoke(
            context,
            ToolCall(
                "bash-binary-output",
                "bash",
                objectValue(
                    [
                        ValueField(
                            "command",
                            textValue("printf 'before\\377\\000after\\n'; printf 'err-before\\376err-after' >&2")
                        )
                    ]
                )
            )
        )
    )
    expect(
        !binaryOutput.isError && binaryOutput.output.field("stdout").getOrThrow().text.contains("before") &&
            binaryOutput.output.field("stdout").getOrThrow().text.contains("\u{FFFD}") && binaryOutput
            .output
            .field("stdout")
            .getOrThrow()
            .text
            .contains("\u{0}") && binaryOutput.output.field("stdout").getOrThrow().text.contains("after") && binaryOutput
            .output
            .field("stderr")
            .getOrThrow()
            .text
            .contains("err-before") && binaryOutput.output.field("stderr").getOrThrow().text.contains("\u{FFFD}") &&
            binaryOutput.output.field("stderr").getOrThrow().text.contains("err-after"),
        "persistent shell recognizes completion markers after binary stdout and stderr"
    )
    let boundaryOutput = completedFrom(
        pipeline.invoke(
            context,
            ToolCall(
                "bash-binary-boundary",
                "bash",
                objectValue(
                    [
                        ValueField(
                            "command",
                            textValue(
                                "head -c 4095 /dev/zero | tr '\\000' a; printf '\\377boundary-tail'; " +
                                    "printf '\\036AXYNDRA_DONE_fake:0:/tmp\\037'"
                            )
                        )
                    ]
                )
            )
        )
    )
    expect(
        !boundaryOutput.isError && boundaryOutput.output.field("stdout").getOrThrow().text.startsWith("aaaa") &&
            boundaryOutput.output.field("stdout").getOrThrow().text.contains("boundary-tail") && boundaryOutput
            .output
            .field("stdout")
            .getOrThrow()
            .text
            .contains("AXYNDRA_DONE_fake"),
        "persistent shell handles invalid UTF-8 across read boundaries and marker-like output"
    )
    let largeOutput = completedFrom(
        pipeline.invoke(
            context,
            ToolCall(
                "bash-large-output",
                "bash",
                objectValue(
                    [
                        ValueField(
                            "command",
                            textValue("head -c 131072 /dev/zero | tr '\\000' z; printf large-output-tail")
                        )
                    ]
                )
            )
        )
    )
    expect(
        !largeOutput.isError && largeOutput.output.field("stdout").getOrThrow().text.size >= 131072 && largeOutput
            .output
            .field("stdout")
            .getOrThrow()
            .text
            .contains("large-output-tail"),
        "large stdout does not delay persistent shell completion marker recognition"
    )
    let nonzeroOutput = completedFrom(
        pipeline.invoke(
            context,
            ToolCall(
                "bash-nonzero-output",
                "bash",
                objectValue([ValueField("command", textValue("printf nonzero-output; false"))])
            )
        )
    )
    let signalledOutput = completedFrom(
        pipeline.invoke(
            context,
            ToolCall(
                "bash-signalled-output",
                "bash",
                objectValue([ValueField("command", textValue("sh -c 'kill -TERM $$'"))])
            )
        )
    )
    expect(
        nonzeroOutput.isError && nonzeroOutput.output.field("exit_code").getOrThrow().number == "1" && nonzeroOutput
            .output
            .field("stdout")
            .getOrThrow()
            .text == "nonzero-output" && signalledOutput.isError && signalledOutput
            .output
            .field("exit_code")
            .getOrThrow()
            .number == "143",
        "persistent shell parses normal nonzero and signal termination statuses"
    )
    let timeoutStarted = MonoTime.now()
    let timeoutResult = processes.executeShell(
        SessionId("persistent-shell-timeout-contract"),
        ProcessRequest(
            "/bin/bash",
            operationId: OperationId("persistent-shell-timeout-operation"),
            arguments: ["printf timeout-stdout; printf timeout-stderr >&2; sleep 5"],
            timeoutMillis: 1000,
            sandboxMode: ProcessSandboxMode.WorkspaceReadWrite
        )
    ).value().getOrThrow()
    let timeoutElapsed = (MonoTime.now() - timeoutStarted).toMilliseconds()
    expect(
        timeoutResult.timedOut && timeoutResult.exitCode == 124 && timeoutResult.stdout.contains("timeout-stdout") &&
            timeoutResult.stderr.contains("timeout-stderr") && timeoutElapsed >= 900 && timeoutElapsed <= 1600,
        "persistent shell uses a monotonic deadline and preserves partial output on timeout"
    )
    let ptyResult = completedFrom(
        pipeline.invoke(
            context,
            ToolCall(
                "bash-pty",
                "bash",
                objectValue(
                    [
                        ValueField("command", textValue("printf pty-ok")),
                        ValueField("pty", boolValue(true)),
                        ValueField(
                            "env",
                            objectValue([ValueField("AXYNDRA_PTY", textValue("yes"))])
                        )
                    ]
                )
            )
        )
    )
    expect(
        ptyResult.output.field("stdout").getOrThrow().text.contains("pty-ok") && ptyResult
            .output
            .field("pty")
            .getOrThrow()
            .boolean,
        "bash supports an explicitly requested PTY"
    )
    expect(
        toolOutcomeFailed(pipeline.invoke(
            context,
            ToolCall(
                "bash-escape-cwd",
                "bash",
                objectValue(
                    [
                        ValueField("command", textValue("pwd")),
                        ValueField("cwd", textValue("../"))
                    ]
                )
            )
        )),
        "bash cwd cannot escape the workspace"
    )
}

func runRestartedPermissionContracts(
    database: SqliteDatabase,
    context: ToolInvocationContext,
    workspace: LocalWorkspace
): Unit {
    let restartedCatalog = ToolCatalog()
    let restartedProcesses = LocalProcessPort(
        workspace,
        sandboxEnabled: true
    )
    expect(
        installLocalTools(
            restartedCatalog,
            workspace,
            restartedProcesses
        ).isOk(),
        "reinstall local tools after restart"
    )
    let restartedPipeline = ToolPipeline(
        restartedCatalog,
        MemoryOperationRepository(),
        RecordingAuditPort(),
        ProductIds(),
        policy: DefaultCapabilityPolicy(mode: ApprovalMode.AlwaysAsk),
        permissions: SqlitePermissionRepository(database)
    )
    match (restartedPipeline.invoke(
        context,
        ToolCall(
            "bash-after-restart",
            "bash",
            objectValue(
                [
                    ValueField(
                        "command",
                        textValue("printf permission-restored")
                    )
                ]
            )
        )
    )) {
        case Result.Ok(ToolInvocationResult.Completed(result)) => expect(
            result.output.field("stdout").getOrThrow().text == "permission-restored",
            "restored session grant executes the same capability"
        )
        case _ => throw IllegalStateException("session approval was not restored after restart")
    }
    expect(
        workspace.read(WorkspaceReadRequest("../escape.txt")).isError(),
        "workspace escape is denied"
    )
    restartedProcesses.close().value().getOrThrow()
}

func verifyToolLimitClamping(application: ApplicationSession): Unit {
    // A small file so glob/read have something to scan in the workspace.
    File.writeTo(
        application.workspaceRoot() + "/clamp-check.txt",
        "one\ntwo\nthree\n".toArray()
    )
    // OMP clamps an over-limit glob limit to 200 instead of failing
    // (Math.min(MAX_LIMIT, ...) in tools/glob.ts).
    let globResult = application.invokeLocalTool(
        "glob",
        objectValue(
            [
                ValueField("pattern", textValue("**/*.txt")),
                ValueField("limit", integerValue(300))
            ]
        )
    )
    expect(
        globResult.isOk(),
        "glob clamps an over-limit limit instead of failing"
    )
    let globPatternResult = application.invokeLocalTool(
        "glob",
        objectValue(
            [
                ValueField("pattern", textValue("**/*.txt")),
                ValueField("limit", integerValue(500))
            ]
        )
    )
    let globAllResult = application.invokeLocalTool(
        "glob",
        objectValue([ValueField("pattern", textValue("**/*"))])
    )
    var globPatternCount = ""
    var globAllCount = ""
    match (globPatternResult) {
        case Result.Ok(result) => match (result.output.field("count")) {
            case Some(value) => globPatternCount = value.number
            case None => ()
        }
        case _ => ()
    }
    match (globAllResult) {
        case Result.Ok(result) => match (result.output.field("count")) {
            case Some(value) => globAllCount = value.number
            case None => ()
        }
        case _ => ()
    }
    expect(
        globPatternResult.isOk() && globAllResult.isOk() && globPatternCount != "" && globAllCount != "" &&
            globPatternCount != globAllCount,
        "glob honors the pattern field instead of returning the full listing"
    )
    // OMP clamps an over-limit read limit instead of failing
    // (Math.min with DEFAULT_MAX_LINES in tools/read.ts).
    let readResult = application.invokeLocalTool(
        "read",
        objectValue(
            [
                ValueField("path", textValue("clamp-check.txt")),
                ValueField("limit", integerValue(20000))
            ]
        )
    )
    expect(
        readResult.isOk() && readResult.value().getOrThrow().output.field("content").getOrThrow().text.contains("one"),
        "read clamps an over-limit limit instead of failing"
    )
    // bash_readonly: a read-only command runs; a write-shaped command is
    // rejected before execution.
    let readonlyOk = application.invokeLocalTool(
        "bash_readonly",
        objectValue([ValueField("command", textValue("printf 'one\\ntwo\\nthree\\n' | wc -l"))])
    )
    expect(
        match (readonlyOk) {
            case Result.Ok(result) => result.output.field("stdout").getOrThrow().text.trimAscii() == "3"
            case _ => false
        },
        "bash_readonly runs a read-only command"
    )
    // Discard/merge redirections (2>/dev/null, 2>&1) are read-only and must
    // not be rejected — a pure inspection pipeline like this one counts
    // lines without touching any file.
    let readonlyDiscard = application.invokeLocalTool(
        "bash_readonly",
        objectValue(
            [
                ValueField(
                    "command",
                    textValue("find . -type f -print0 | xargs -0 wc -l 2>/dev/null | tail -1")
                )
            ]
        )
    )
    expect(
        match (readonlyDiscard) {
            case Result.Ok(result) => result.output.field("stdout").getOrThrow().text.trimAscii() != ""
            case _ => false
        },
        "bash_readonly allows discard redirections (2>/dev/null)"
    )
    let readonlyWrite = application.invokeLocalTool(
        "bash_readonly",
        objectValue([ValueField("command", textValue("touch /tmp/oop-nope"))])
    )
    expect(
        readonlyWrite.isError() && match (readonlyWrite.error()) {
            case Some(error) => error.code == "tool.readonly_rejected" && error.kind == AgentErrorKind.InvalidInput
            case None => false
        },
        "bash_readonly rejects a write command"
    )
    // Count mode is part of the descriptor and returns aggregate matches.
    let grepCount = application.invokeLocalTool(
        "grep",
        objectValue(
            [
                ValueField("pattern", textValue("one")),
                ValueField("path", textValue("clamp-check.txt")),
                ValueField("count", boolValue(true))
            ]
        )
    )
    expect(
        match (grepCount) {
            case Result.Ok(result) => match (result.output.field("total")) {
                case Some(value) => value.number == "1"
                case None => false
            }
            case _ => false
        },
        "grep count returns the total instead of matched lines"
    )
}

func runApplicationContracts(root: String): Unit {
    let responseProduct = openProduct(
        config: ProductConfig(
            stateRoot: root + "/application-response-state",
            workspaceRoot: root,
            fixture: true,
            approvalMode: ApprovalMode.Yolo,
            asyncEnabled: false
        )
    ).value().getOrThrow()
    let projected = responseProduct
        .applicationSession()
        .handle("application response projection")
        .value()
        .getOrThrow()
    expect(
        projected.text == "fixture response for application response projection" &&
            !projected.text.contains("end_turn") && match (projected.snapshot) {
                case Some(value) => value.summary == "end_turn"
                case None => false
            },
        "application response projects assistant content while preserving stop metadata"
    )
    let product = openProduct(
        config: ProductConfig(
            stateRoot: root + "/state",
            workspaceRoot: root,
            fixture: true,
            approvalMode: ApprovalMode.Yolo,
            asyncEnabled: false
        )
    ).value().getOrThrow()
    let application = product.applicationSession()
    let productToolchain = root + "-product-toolchain"
    Directory.create(productToolchain + "/bin", recursive: true)
    File.writeTo(productToolchain + "/sentinel", "unchanged".toArray())
    setVariable("CANGJIE_SDK_ROOT", productToolchain)
    let sandboxProduct = openProduct(
        config: ProductConfig(
            settingsRoot: root + "/sandbox-application-settings",
            stateRoot: root + "/sandbox-application-state",
            workspaceRoot: root,
            fixture: false,
            approvalMode: ApprovalMode.Yolo,
            asyncEnabled: false
        )
    ).value().getOrThrow()
    removeVariable("CANGJIE_SDK_ROOT")
    let sandboxApplication = sandboxProduct.applicationSession()
    let fullRequest = product.request("network capability contract")
    let readOnlyRequest = product.request(
        "read-only capability contract",
        readOnly: true
    )
    expect(
        fullRequest.capabilities.allows(CapabilityKind.NetworkAccess) &&
            !readOnlyRequest.capabilities.allows(
                CapabilityKind.NetworkAccess
            ) && fullRequest.toolContext.workspaceRoot == canonicalize(root).toString() &&
            fullRequest.toolContext.cwd == canonicalize(root).toString() &&
            productToolEnvironmentIsSafe(fullRequest.toolContext.environment) &&
            fullRequest.toolContext.services.contains(ToolServiceKind.Workspace, name: "local-workspace") &&
            fullRequest.toolContext.services.contains(ToolServiceKind.Process, name: "local-process") &&
            fullRequest.toolContext.services.contains(
                ToolServiceKind.Conversation,
                name: "session-conversation"
            ),
        "full product requests bind canonical tool context and network while read-only requests omit network"
    )
    let contextRegistered = product.registerTool(
        ToolDescriptor(
            ModelToolDefinition(
                "tool_context_contract",
                "tool invocation context fixture",
                objectValue([ValueField("type", textValue("object"))])
            ),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        ToolContextContractTool(canonicalize(root).toString())
    ).isOk()
    let contextInvoked = match (application.invokeLocalTool(
        "tool_context_contract",
        objectValue([])
    )) {
        case Result.Ok(value) => value.output.boolean
        case _ => false
    }
    let contextRemoved = product.unregisterTool("tool_context_contract")
    expect(
        contextRegistered && contextInvoked && contextRemoved,
        "Product local tool execution receives the explicit safe ToolInvocationContext descriptor"
    )
    let networkRegistered = product.registerTool(
        ToolDescriptor(
            ModelToolDefinition(
                "network_contract",
                "network capability fixture",
                objectValue([ValueField("type", textValue("object"))])
            ),
            Capability(CapabilityKind.NetworkAccess)
        ),
        NetworkContractTool()
    ).isOk()
    let networkInvoked = match (application.invokeLocalTool(
        "network_contract",
        objectValue([])
    )) {
        case Result.Ok(value) => value.output.text == "network-ok"
        case _ => false
    }
    let networkRemoved = product.unregisterTool("network_contract")
    expect(
        networkRegistered && networkInvoked && networkRemoved,
        "local CLI tool invocation carries the full network capability set"
    )
    let fixtureBash = application.executeBash("printf fixture-host-bypass")
    let sandboxBash = sandboxApplication.executeBash("printf sandboxed-control")
    let resourceBash = sandboxApplication.executeBash("ulimit -n")
    let controlledPath = sandboxApplication.executeBash("printf \"$PATH\"")
    let readOnlyToolchain = sandboxApplication.executeBash(
        "printf changed > " + productToolchain + "/sentinel"
    )
    let limits = defaultProductSandboxResourceLimits()
    expect(
        match (fixtureBash) {
            case Result.Ok(result) => result.exitCode == 0 &&
                result.stdout == "fixture-host-bypass"
            case _ => false
        } && match (sandboxBash) {
            case Result.Ok(result) => result.exitCode == 0 &&
                result.stdout == "sandboxed-control"
            case _ => false
        } && match (resourceBash) {
            case Result.Ok(result) => result.exitCode == 0 && result.stdout.trimAscii() == "4096"
            case _ => false
        } && match (controlledPath) {
            case Result.Ok(result) => result.exitCode == 0 &&
                result.stdout.split(":").contains(productToolchain + "/bin")
            case _ => false
        } && match (readOnlyToolchain) {
            case Result.Ok(result) => result.exitCode != 0
            case _ => false
        } && String.fromUtf8(File.readFrom(productToolchain + "/sentinel")) == "unchanged" &&
            limits.maxOutputBytes > 0 && limits.addressSpaceBytes > 0 && limits.fileSizeBytes > 0 &&
            limits.openFiles > 0 && limits.processes > 0 && limits.cpuSeconds > 0,
        "fixture and production controls share the sandbox, apply non-zero prlimits, and mount only an explicit read-only toolchain PATH"
    )
    runApplicationInteractionContracts(application)
    verifyToolLimitClamping(sandboxApplication)
    runSlashCommandContracts(
        root,
        product,
        application
    )
    runModeAndDiagnosticContracts(product)
    runLocalTodoContracts(
        root,
        product
    )
    runBranchAndHandoffContracts(product)
    runSubagentContracts(product)
    runProcessHubContracts(
        root,
        product
    )
    runGuardedAndAsyncContracts(root)
    runSubagentCancellationContracts(product)
    runSessionLifecycleContracts(
        root,
        product,
        application
    )
    sandboxProduct.close()
    product.close()
    responseProduct.close()
    let _ = removeIfExists(productToolchain, recursive: true)
}

class NetworkContractTool <: ToolExecutor {
    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let _ = context
        Result.Ok(ToolResult(call.callId, textValue("network-ok")))
    }
}

class ToolContextContractTool <: ToolExecutor {
    private let expectedRoot: String

    init(expectedRoot: String) {
        this.expectedRoot = expectedRoot
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let valid = context.workspaceRoot == expectedRoot && context.cwd == expectedRoot &&
            productToolEnvironmentIsSafe(context.environment) &&
            context.environment.value("AXYNDRA_CONTEXT_SECRET").isNone() &&
            context.services.contains(ToolServiceKind.Workspace, name: "local-workspace") &&
            context.services.contains(ToolServiceKind.Process, name: "local-process") &&
            context.services.contains(ToolServiceKind.Conversation, name: "session-conversation") &&
            context.services.contains(ToolServiceKind.Artifact, name: "product-artifact") &&
            context.services.contains(ToolServiceKind.Memory, name: "product-memory") &&
            context.services.contains(ToolServiceKind.Task, name: "product-task") &&
            context.services.contains(ToolServiceKind.Extension, name: "product-extension") &&
            !context.cancellation.isCancelled()
        Result.Ok(ToolResult(call.callId, boolValue(valid)))
    }
}

func productToolEnvironmentIsSafe(environment: ToolEnvironmentView): Bool {
    for (name in environment.names() where
        name != "TERM" && name != "COLORTERM" && name != "NO_COLOR") {
        return false
    }
    true
}

func runApplicationInteractionContracts(application: ApplicationSession): Unit {
    application.setAskInteractive(true)
    let applicationAskFuture = spawn {
        application.invokeLocalTool(
            "ask",
            askSingleCall("application-ask").arguments
        )
    }
    let applicationAsk = waitForApplicationAsk(application)
    expect(
        application.answerAsk(
            applicationAsk.requestId,
            ProductAskResolution.Answers(
                [
                    ProductAskAnswer(
                        "auth_method",
                        customInput: Some("Mutual TLS")
                    )
                ]
            )
        ).isOk(),
        "application session resolves its interactive ask"
    )
    let applicationAskResult = applicationAskFuture.get().value().getOrThrow()
    expect(
        applicationAskResult.output.field("content").getOrThrow().text == "User provided custom input: Mutual TLS",
        "application and tool runtime share the same ask coordinator"
    )
    let previousAskSession = application.id()
    let nextAskSession = application.newSession().value().getOrThrow()
    expect(
        previousAskSession.value != nextAskSession.value,
        "application creates a distinct session before ask migration"
    )
    let migratedAskFuture = spawn {
        application.invokeLocalTool(
            "ask",
            askSingleCall("application-ask-migrated").arguments
        )
    }
    let migratedAsk = waitForApplicationAsk(application)
    expect(
        migratedAsk.sessionId.value == nextAskSession.value && application.answerAsk(
            migratedAsk.requestId,
            ProductAskResolution.Answers(
                [
                    ProductAskAnswer(
                        "auth_method",
                        selectedOptions: ["OAuth2"]
                    )
                ]
            )
        ).isOk(),
        "interactive ask surface follows application session changes"
    )
    let _ = migratedAskFuture.get().value().getOrThrow()
    let withdrawalApplication = application
    expect(
        withdrawalApplication.enqueue("withdraw-1", "steer", "old steering").isOk() && withdrawalApplication.enqueue(
            "withdraw-2",
            "follow_up",
            "new follow up"
        ).isOk(),
        "application queues inputs for safe single-item withdrawal"
    )
    expect(
        match (withdrawalApplication.enqueue("withdraw-2", "steer", "duplicate")) {
            case Result.Err(error) => error.code == "application.duplicate_queue_correlation_id"
            case _ => false
        } && withdrawalApplication.queuedCount() == 2,
        "application rejects duplicate non-empty queued correlation ids"
    )
    expect(
        match (withdrawalApplication.withdrawQueued("withdraw-2")) {
            case Result.Ok(QueuedWithdrawal.Withdrawn(queued)) => queued.kind == "follow_up" && queued.input ==
                "new follow up"
            case _ => false
        } && withdrawalApplication.queuedCount() == 1,
        "application withdraws exactly the identified queued item"
    )
    expect(
        match (withdrawalApplication.withdrawQueued("withdraw-2")) {
            case Result.Ok(QueuedWithdrawal.AlreadyDelivered) => true
            case _ => false
        } && withdrawalApplication.takeSteering().size == 1 && match (withdrawalApplication.withdrawQueued(
            "withdraw-1")) {
            case Result.Ok(QueuedWithdrawal.AlreadyDelivered) => true
            case _ => false
        },
        "application reports already delivered without withdrawing an earlier item"
    )
    expect(
        withdrawalApplication.enqueue("", "rpc", "empty correlation one").isOk() && withdrawalApplication.enqueue(
            "",
            "rpc",
            "empty correlation two"
        ).isOk() && withdrawalApplication.queuedCount() == 2 && match (withdrawalApplication.withdrawQueued("")) {
            case Result.Err(error) => error.code == "application.empty_queue_correlation_id"
            case _ => false
        },
        "application preserves empty RPC correlation ids while refusing ambiguous withdrawal"
    )
    withdrawalApplication.clearQueued()
    expect(
        application.enqueue("rpc-1", "steer", "first steer").isOk() &&
            application.enqueue("rpc-2", "steer", "second steer").isOk() && application.enqueue(
            "rpc-3",
            "follow_up",
            "first follow up"
        ).isOk() && application.enqueue(
            "rpc-4",
            "follow_up",
            "second follow up"
        ).isOk() && application.queuedCount() == 4,
        "application session owns queued interactions"
    )
    let approvalBoundary = Result<ApplicationResponse>.Ok(
        ApplicationResponse(
            true,
            approval: Some(
                ApprovalRequest(
                    OperationId("queue-approval"),
                    "queue-call",
                    "write",
                    Capability(CapabilityKind.WorkspaceWrite)
                )
            )
        )
    )
    expect(
        application.takeQueuedAtSafeBoundary(approvalBoundary).isNone() && application.queuedCount() == 4,
        "approval boundary preserves queued steer input"
    )
    let firstSteering = application.takeSteering()
    application.setSteeringMode(QueueDeliveryMode.All)
    let remainingSteering = application.takeSteering()
    application.setFollowUpMode(QueueDeliveryMode.All)
    let followUps = application.takeFollowUps()
    application.setInterruptMode(RunInterruptMode.Wait)
    expect(
        firstSteering.size == 1 && firstSteering[0].text == "first steer" && remainingSteering.size == 1 &&
            remainingSteering[0].text == "second steer" && followUps.size == 2 && followUps[0].text == "first follow up" &&
            followUps[1].text == "second follow up" && application.interruptMode() == RunInterruptMode.Wait &&
            application.queuedCount() == 0,
        "application queue applies typed delivery and interrupt modes"
    )
}

func runSlashCommandContracts(
    root: String,
    product: ProductRuntime,
    application: ApplicationSession
): Unit {
    let help = application.handle("/help").value().getOrThrow()
    expect(
        !help.agentInvoked && help.text.contains("Setup & help\n\n") && help.text.contains("Work modes\n\n") &&
            help.text.contains("/plan [request] — Toggle read-only planning mode  \n") && help
            .text
            .contains("/cancel — Cancel active work or approval  \n") && !help.text.contains("/approve-session"),
        "local help uses terminal-safe hard breaks and contains only public slash commands"
    )
    let tools = application.handle("/tools").value().getOrThrow()
    let setup = application.handle("/setup").value().getOrThrow()
    let providers = application.handle("/providers").value().getOrThrow()
    let switchModel = application.handle("/switch").value().getOrThrow()
    let branch = application.handle("/branch").value().getOrThrow()
    let emptyJobs = application.handle("/jobs").value().getOrThrow()
    let stats = application.handle("/stats").value().getOrThrow()
    let sshHelp = application.handle("/ssh help").value().getOrThrow()
    let emptySsh = application.handle("/ssh list").value().getOrThrow()
    let addedSsh = application
        .handle("/ssh add alpha --host example.com --user elliot " + "--port 2222")
        .value()
        .getOrThrow()
    let listedSsh = application.handle("/ssh list").value().getOrThrow()
    let removedSsh = application.handle("/ssh remove alpha").value().getOrThrow()
    let emptyDump = application.handle("/dump").value().getOrThrow()
    let exportPath = root + "/session-export.html"
    let exported = application.handle("/export " + exportPath).value().getOrThrow()
    expect(
        tools.text ==
            "tools: ast_grep ast_edit web_search grep write ask read github edit glob bash bash_readonly eval " +
            "checkpoint rewind lsp debug plan_write goal memory_edit " +
            "retain recall reflect learn manage_skill read_skill_reference todo " +
            "task hub yield" && !setup.agentInvoked &&
            isProviderSetupAction(setup.action) && !providers.agentInvoked && isProviderSetupAction(providers.action) &&
            isModelSelectorAction(switchModel.action) && isBranchSelectorAction(branch.action) &&
            !emptyJobs.agentInvoked && emptyJobs.text == "No background jobs." && !stats.agentInvoked &&
            stats.text.contains("session stats:") && !sshHelp.agentInvoked && sshHelp.text.contains("/ssh add") &&
            !emptySsh.agentInvoked && emptySsh.text == "No SSH hosts configured." && !addedSsh.agentInvoked &&
            addedSsh.text == "Added SSH host \"alpha\" (project)." && listedSsh.text ==
            "alpha | example.com | elliot | 2222 [project]" && removedSsh.text ==
            "Removed SSH host \"alpha\" from project config." && !emptyDump.agentInvoked && emptyDump.text ==
            "No messages to dump yet." && !exported.agentInvoked && exported.text == "Session exported to: " + exportPath &&
            exists(Path(exportPath)) && String
            .fromUtf8(File.readFrom(exportPath))
            .contains("<title>axyndra session</title>"),
        "implemented product inspection commands remain local: " + tools.text
    )
    let dumpApplication = product.applicationSession()
    expect(
        dumpApplication.handle("dump contract prompt").isOk(),
        "prepare a durable session transcript for dump"
    )
    let dumped = dumpApplication.handle("/dump ignored-by-upstream").value().getOrThrow()
    let requestPath = dumpApplication.dumpLlmRequest().value().getOrThrow()
    let requestJson = String.fromUtf8(File.readFrom(requestPath))
    expect(
        !dumped.agentInvoked && dumped.text.contains("## Configuration") && dumped.text.contains("## Available Tools") &&
            dumped.text.contains("## User") && dumped.text.contains("dump contract prompt") && dumped
            .text
            .contains("## Assistant") && dumped.text.contains("Reconstructed current-session request JSON: /") &&
            dumped.text.contains("not a historical provider wire capture") && exists(Path(requestPath)) &&
            requestJson.contains("\"messages\"") && requestJson.contains("\"tools\"") && requestJson.contains(
            "dump contract prompt") && requestJson.contains("\"kind\":\"reconstructed_current_request\"") &&
            requestJson.contains("\"workMode\":\"none\"") && requestJson.contains("\"system\"") && requestJson
            .contains("\"thinkingLevel\":\"medium\""),
        "slash dump returns the transcript and persists a labelled current-request reconstruction"
    )
    expect(
        application.handle("/setup invalid").isError() && application.handle("/switch fixture").isError() &&
            application.handle("/branch unexpected").isError(),
        "modal slash commands reject unsupported arguments locally"
    )
}

func runModeAndDiagnosticContracts(product: ProductRuntime): Unit {
    let modeApplication = product.applicationSession()
    let planEnabled = modeApplication.handle("/plan fixture task write").value().getOrThrow()
    // Plan mode raises the default Medium effort by two levels to XHigh.
    expect(
        match (product.fixtureProbe) {
            case Some(probe) => probe.lastThinking == ThinkingLevel.XHigh
            case None => false
        },
        "plan mode raises default thinking by two levels with High as the floor"
    )
    let explicitPlanApplication = product.applicationSession()
    explicitPlanApplication.setThinking(ThinkingLevel.Low)
    expect(explicitPlanApplication.handle("/plan explicit thinking precedence").isOk() &&
        match (product.fixtureProbe) {
            case Some(probe) => probe.lastThinking == ThinkingLevel.Low
            case None => false
        }, "explicit user thinking has precedence over Plan mode preference")
    let planTools = modeApplication.handle("/tools").value().getOrThrow()
    let planReview = modeApplication.handle("/plan-review").value().getOrThrow()
    let planRequestPath = modeApplication.dumpLlmRequest().value().getOrThrow()
    let planRequest = decodeAgentValue(String.fromUtf8(File.readFrom(planRequestPath))).value().getOrThrow()
    let planDisabled = modeApplication.handle("/plan").value().getOrThrow()
    let vibeRun = modeApplication.handle("/vibe inspect this workspace").value().getOrThrow()
    let vibeDisabled = modeApplication.handle("/vibe").value().getOrThrow()
    let guided = modeApplication.handle("/guided-goal ship a reliable release").value().getOrThrow()
    // Plan mode must let the agent write the plan through plan_write and
    // /plan-review must surface the tool payload (the structured plan).
    let planEvents = ArrayList<AgentEvent>()
    modeApplication.subscribe({event => planEvents.add(event)})
    let planWriteRun = modeApplication.handle("/plan fixture plan write").value().getOrThrow()
    let planWriteReview = modeApplication.handle("/plan-review").value().getOrThrow()
    let automaticPlanReview = match (planWriteRun.planReview) {
        case Some(value) => value
        case None => ""
    }
    expect(
        planWriteRun.agentInvoked && automaticPlanReview.contains("Goal: ship a plan") &&
            automaticPlanReview.contains("Acceptance: contract passes") && planWriteReview.planReview.isSome() &&
            planWriteReview.text == automaticPlanReview,
        "plan_write completion automatically carries the same authoritative plan that /plan-review reopens"
    )
    let editedPlan = modeApplication.updateLatestPlan(
        "",
        "# Goal\n\nShip the edited plan.\n\n# Verification\n\nRun the product contract."
    ).value().getOrThrow()
    let editedPlanReview = modeApplication.handle("/plan-review").value().getOrThrow()
    expect(
        editedPlan.contains("Ship the edited plan") && editedPlanReview.text == editedPlan &&
            modeApplication.updateLatestPlan("stale-review-hash", "# Goal\n\nStale edit").isError(),
        "plan review edits persist through the structured plan payload and reject stale writers"
    )
    let recoveredPlanRun = modeApplication.handle("fixture plan omitted").value().getOrThrow()
    let recoveredPlanReview = modeApplication.handle("/plan-review").value().getOrThrow()
    var planUpdatedCount: Int64 = 0
    var latestPlanEventBody = ""
    var latestPlanEventId = ""
    for (event in planEvents) {
        let code = match (event.detail.field("code")) {
            case Some(value) => value.text
            case None => ""
        }
        if (code == "plan.updated") {
            planUpdatedCount += 1
            latestPlanEventBody = match (event.detail.field("body")) {
                case Some(value) => value.text
                case None => ""
            }
            latestPlanEventId = match (event.detail.field("id")) {
                case Some(value) => value.text
                case None => ""
            }
        }
    }
    expect(
        recoveredPlanRun.agentInvoked && recoveredPlanReview.text.contains("Goal: ship a plan") && planUpdatedCount >= 2 &&
            latestPlanEventBody.contains("Acceptance: contract passes") && latestPlanEventId != "",
        "plan mode corrects an omitted plan_write and publishes plan.updated"
    )
    expect(
        planEnabled.agentInvoked && planEnabled.text.contains("fixture response") &&
            !planEnabled.text.contains("end_turn") && modeApplication.allSubagents().isEmpty() &&
            planTools.text.contains(" read") && !planTools.text.contains(" write") && !planTools
            .text
            .contains(" task") && !planReview.agentInvoked && planReview.text.contains("Latest plan:") &&
            planRequest.field("thinkingLevel").getOrThrow().text == "xhigh" && planRequest
            .field("workMode")
            .getOrThrow()
            .text == "plan" && planRequest.field("system").getOrThrow().text.contains("PLAN MODE IS ACTIVE") &&
            requestHasTool(planRequest, "read") && requestHasTool(planRequest, "plan_write") && requestHasTool(
            planRequest, "bash_readonly") && !requestHasTool(planRequest, "write") && !requestHasTool(
            planRequest, "bash") && !requestHasTool(planRequest, "task") &&
            !planDisabled.agentInvoked && planDisabled.text == "Plan mode disabled." && vibeRun.agentInvoked &&
            vibeRun.text.contains("fixture response") && !vibeRun.text.contains("end_turn") &&
            !vibeDisabled.agentInvoked && guided.agentInvoked && guided.text.contains("fixture response") &&
            !guided.text.contains("end_turn"),
        "work mode commands alter real request behavior and guided goal " + "starts an agent interview"
    )
    runNaturalLanguagePlanApprovalContracts(product)
    let persistedMode = product.applicationSession()
    let persistedModeId = persistedMode.id()
    expect(
        persistedMode.handle("/plan").isOk(),
        "enable a session-scoped persisted work mode"
    )
    let restoredMode = product.applicationSession(sessionId: Some(persistedModeId))
    expect(
        restoredMode.handle("/debug").value().getOrThrow().text.contains("plan_mode: true") &&
            restoredMode.handle("/goal set blocked by plan").isError() && restoredMode.handle("/plan").isOk(),
        "work mode survives session restoration and excludes goal mode"
    )
    let loopApplication = product.applicationSession()
    let loopOn = loopApplication.handle("/loop 2").value().getOrThrow()
    let loopDebug = loopApplication.handle("/debug").value().getOrThrow()
    let loopOff = loopApplication.handle("/loop").value().getOrThrow()
    let queueApplication = product.applicationSession()
    let queued = queueApplication.handle("/queue inspect after yield").value().getOrThrow()
    expect(
        !loopOn.agentInvoked && loopOn.text.contains("Iterations: 2") && loopDebug.text.contains("loop_mode: true") &&
            loopOff.text == "Loop mode disabled." && !queued.agentInvoked && queueApplication.queuedCount() == 1,
        "loop and queue commands use ApplicationSession safe-boundary state"
    )
    let diagnostics = [
        modeApplication.handle("/changelog").value().getOrThrow(),
        modeApplication.handle("/changelog full").value().getOrThrow(),
        modeApplication.handle("/hotkeys").value().getOrThrow(),
        modeApplication.handle("/context").value().getOrThrow(),
        modeApplication.handle("/extensions").value().getOrThrow(),
        modeApplication.handle("/tree").value().getOrThrow(),
        modeApplication.handle("/debug").value().getOrThrow()
    ]
    for (diagnostic in diagnostics) {
        expect(
            !diagnostic.agentInvoked && diagnostic.text != "",
            "information and diagnostic slash commands stay local"
        )
    }
    expect(
        diagnostics[0].text.contains("axyndra 1.0.0") && diagnostics[1].text.contains("axyndra 1.0.0") &&
            diagnostics[2].text.contains("Ctrl+C") && diagnostics[3].text.contains("Context estimate:") &&
            diagnostics[4].text.contains("Extension control center:") && diagnostics[5].text.contains("Session tree:") &&
            diagnostics[6].text.contains("Debug snapshot:") && modeApplication.handle("/changelog nope").isError() &&
            modeApplication.handle("/hotkeys nope").isError() && modeApplication.handle("/plan-review nope").isError(),
        "diagnostic commands expose truthful state and validate arguments"
    )
}

func runNaturalLanguagePlanApprovalContracts(product: ProductRuntime): Unit {
    let accepted = [
        "执行吧",
        "开始执行",
        "执行计划",
        "按计划执行",
        "批准并执行",
        "继续执行",
        "execute",
        "execute it",
        "execute the plan",
        "start execution",
        "approve and execute",
        "proceed with execution",
        " 执行吧！ ",
        "EXECUTE THE PLAN!"
    ]
    for (phrase in accepted) {
        let application = product.applicationSession()
        expect(
            application.handle("/plan fixture plan write").isOk(),
            "prepare a structured plan for natural-language approval"
        )
        let approved = application.handle(phrase)
        let transcript = application.messages().value().getOrThrow()
        expect(
            approved.isOk() && approved.value().getOrThrow().agentInvoked && application.workMode() == "none" &&
                conversationContainsText(transcript, "source=natural-language"),
            "standalone plan approval phrase starts a new execution run: " + phrase
        )
    }

    for (phrase in ["不要执行", "执行吧，但先修改范围", "execute the plan?"]) {
        let application = product.applicationSession()
        expect(
            application.handle("/plan fixture plan write").isOk() && application.handle(phrase).isOk() &&
                application.workMode() == "plan",
            "negated, qualified, and interrogative text does not approve a plan: " + phrase
        )
    }

    let missing = product.applicationSession()
    expect(missing.handle("/plan").isOk(), "enable plan mode without generating a plan")
    expect(
        match (missing.handle("执行吧")) {
            case Result.Err(error) => error.code == "application.plan_approval_missing" && missing.workMode() == "plan"
            case _ => false
        },
        "natural-language approval requires a structured plan and preserves plan mode on failure"
    )

    let changed = product.applicationSession()
    expect(
        changed.handle("/plan fixture plan write").isOk(),
        "prepare a structured plan for stale-review validation"
    )
    let detailedStale = changed.approveLatestPlanForReview(expectedHash: "stale")
    expect(
        match (detailedStale) {
            case PlanApprovalOutcome.NotConsumed(error) => error.code == "application.plan_changed" && changed
                .workMode() == "plan" && error.field("current_hash").isSome()
            case _ => false
        },
        "plan approval reports a stale review as not consumed and preserves plan mode"
    )

    for (contextMode in ["fresh", "compact", "keep"]) {
        let application = product.applicationSession()
        expect(
            application.handle("/plan fixture plan write").isOk(),
            "prepare a structured plan for " + contextMode + " execution context"
        )
        let previousSession = application.id().value
        let approved = application.approveLatestPlan(contextMode: contextMode)
        let transcript = application.messages().value().getOrThrow()
        expect(
            approved.isOk() && approved.value().getOrThrow().agentInvoked && application.workMode() == "none" &&
                conversationContainsText(transcript, "<approved-plan>") && (if (contextMode == "fresh") {
                    application.id().value != previousSession
                } else {
                    application.id().value == previousSession
                }),
            "plan approval applies the selected " + contextMode + " context policy before execution"
        )
    }

    let executionFailure = product.applicationSession()
    expect(
        executionFailure.handle("/plan fixture plan write").isOk(),
        "prepare a structured plan for post-approval execution failure"
    )
    let failureMarker = "FIXTURE-APPROVED-PLAN-EXECUTION-FAILURE"
    let _ = executionFailure.updateLatestPlan(
        "",
        "# Goal\n\n" + failureMarker + "\n\n# Verification\n\nPreserve the first execution error."
    ).value().getOrThrow()
    let previousSession = executionFailure.id().value
    let failedApproval = executionFailure.approveLatestPlanForReview(contextMode: "fresh")
    let currentSession = executionFailure.id().value
    let failedTranscript = executionFailure.messages().value().getOrThrow()
    let inactiveReview = executionFailure.handle("/plan-review")
    expect(
        match (failedApproval) {
            case PlanApprovalOutcome.Consumed(Result.Err(error)) => error.code == "fixture.plan_execution_failed" &&
                error.message == "fixture approved-plan execution failed"
            case _ => false
        } && executionFailure.workMode() == "none" && currentSession != previousSession && product
            .sessionInfo(SessionId(currentSession))
            .value()
            .getOrThrow()
            .parentId == previousSession && conversationContainsText(failedTranscript, "<approved-plan>") && match (
            inactiveReview) {
            case Result.Err(error) => error.code == "application.plan_mode_inactive"
            case _ => false
        },
        "post-approval execution failure consumes review, preserves the original error, and keeps fresh-session lineage"
    )
}

func requestHasTool(request: AgentValue, name: String): Bool {
    match (request.field("tools")) {
        case Some(tools) => for (tool in tools.items) {
            match (tool.field("name")) {
                case Some(value) => if (value.text == name) { return true }
                case None => ()
            }
        }
        case None => ()
    }
    false
}

func conversationContainsText(messages: Array<ModelMessage>, expected: String): Bool {
    for (message in messages) {
        for (block in message.blocks where block.text.contains(expected)) {
            return true
        }
    }
    false
}

func runLocalTodoContracts(
    root: String,
    product: ProductRuntime
): Unit {
    let todoApplication = product.applicationSession()
    expect(
        todoApplication.handle("/todo").value().getOrThrow().text == "No todos. Use /todo append <task> to start one." &&
            todoApplication.handle("/todo append \"Build Phase\" write tests").value().getOrThrow().text ==
            "Appended to Build Phase: Write tests" &&
            todoApplication.handle("/todo append Build run gate").value().getOrThrow().text ==
            "Appended to Build Phase: Run gate",
        "slash todo creates and fuzzy-matches durable phases"
    )
    let todoView = todoApplication.handle("/todo").value().getOrThrow()
    let todoStarted = todoApplication.handle("/todo start gate").value().getOrThrow()
    let todoDone = todoApplication.handle("/todo done gate").value().getOrThrow()
    expect(
        todoView.text.contains("# Build Phase") && todoView.text.contains("- [/] Write tests") &&
            todoView.text.contains("- [ ] Run gate") && todoStarted.text == "Started: Run gate" && todoDone.text ==
            "Marked completed: Run gate",
        "slash todo view and fuzzy task lifecycle follow OMP markers"
    )
    let todoExported = todoApplication.handle("/todo export").value().getOrThrow()
    expect(
        todoExported.text == "Wrote todos to " + root + "/TODO.md" && exists(Path(root + "/TODO.md")),
        "slash todo export atomically writes the default Markdown path"
    )
    File.writeTo(
        root + "/TODO.md",
        ("# Imported\n" + "- [!] Resolve issue <!-- blocker: waiting upstream -->\n" + "- [x] Already done\n").toArray()
    )
    let todoImported = todoApplication.handle("/todo import").value().getOrThrow()
    let importedMarkdown = todoApplication.todoMarkdown().value().getOrThrow()
    let copiedTodos = todoApplication.handle("/todo copy").value().getOrThrow()
    expect(
        todoImported.text == "Imported 1 phase(s), 2 task(s) from " + root + "/TODO.md." && importedMarkdown.contains(
            "- [!] Resolve issue <!-- blocker: waiting upstream -->") && copiedTodos
            .text
            .contains("Copy not available in non-interactive mode") && copiedTodos.text.contains("# Imported"),
        "todo Markdown import preserves blocked reasons and copy output"
    )
    let beforeInvalidTodo = todoApplication.todoMarkdown().value().getOrThrow()
    File.writeTo(
        root + "/TODO.md",
        "# Broken\n- [?] Invalid marker\n".toArray()
    )
    let invalidTodoImport = todoApplication.handle("/todo import")
    expect(
        invalidTodoImport.isError() && invalidTodoImport.error().getOrThrow().code == "application.todo_markdown_invalid" &&
            todoApplication.todoMarkdown().value().getOrThrow() == beforeInvalidTodo &&
            todoApplication.handle("/todo edit").isError(),
        "invalid todo Markdown rolls back and edit stays TUI-specific"
    )
    let replacedTodo = todoApplication.replaceTodoMarkdown("# Native editor\n- [ ] Save from cjtui\n")
    let clipboardPayload = product.copyTextToClipboard(
        "todo clipboard contract",
        nativeEnabled: false
    ).value().getOrThrow()
    expect(
        replacedTodo.value().getOrThrow() == "Saved 1 phase(s), 1 task(s)." &&
            todoApplication.todoMarkdown().value().getOrThrow().contains("- [/] Save from cjtui") &&
            clipboardPayload.osc52Base64 == "dG9kbyBjbGlwYm9hcmQgY29udHJhY3Q=" && !clipboardPayload.nativeCopied &&
            todoApplication.handle("/todo rm").value().getOrThrow().text == "Cleared all todos.",
        "native todo editor round-trip and clear persist typed state"
    )
}

func runBranchAndHandoffContracts(product: ProductRuntime): Unit {
    let branchApplication = product.applicationSession()
    let branchSource = branchApplication.id()
    expect(
        branchApplication.handle("branch source prompt").isOk(),
        "prepare a durable user turn for slash branching"
    )
    let branchMessages = branchApplication.branchMessages().value().getOrThrow()
    expect(
        branchMessages.size == 1 && branchMessages[0].text == "branch source prompt",
        "branch selector exposes durable user entries"
    )
    let branchResult = branchApplication.branchAt(branchMessages[0].entryId).value().getOrThrow()
    expect(
        branchResult.sessionId.value != branchSource.value && branchResult.text == "branch source prompt" &&
            branchApplication.messages().value().getOrThrow().isEmpty(),
        "slash branch selection creates a prefix session and restores draft"
    )
    let handoffApplication = product.applicationSession()
    let handoffSource = handoffApplication.id()
    expect(
        handoffApplication.handle("handoff source prompt").isOk(),
        "prepare a durable turn for slash handoff"
    )
    let handoffResponse = handoffApplication.handle("/handoff preserve verification details").value().getOrThrow()
    let handedOffMessages = handoffApplication.messages().value().getOrThrow()
    expect(
        handoffResponse.agentInvoked && handoffResponse.text.startsWith("handoff session: ") &&
            handoffApplication.id().value != handoffSource.value && handedOffMessages.size == 1 &&
            handedOffMessages[0].role == ModelRole.User && handedOffMessages[0].blocks.size == 1 &&
            handedOffMessages[0].blocks[0].text.contains("<handoff-context>"),
        "slash handoff invokes the model and enters the generated session"
    )
    let aliasApplication = product.applicationSession()
    let beforeClear = aliasApplication.id()
    let cleared = aliasApplication.handle("/clear").value().getOrThrow()
    let quit = aliasApplication.handle("/quit").value().getOrThrow()
    expect(
        !cleared.agentInvoked && cleared.text.startsWith("new session: ") && aliasApplication.id().value != beforeClear
            .value && !quit.agentInvoked && quit.exitRequested,
        "OMP clear and quit aliases execute their real lifecycle behavior"
    )
}

func runSubagentContracts(product: ProductRuntime): Unit {
    let taskApplication = product.applicationSession()
    let subagentEvents = ArrayList<ProductSubagentEvent>()
    taskApplication.subscribeSubagents({
        event => subagentEvents.add(event)
    })
    let taskTurn = contractValue(
        taskApplication.handle("fixture task"),
        "fixture task"
    )
    let childTranscript = contractValue(
        taskApplication.subagentTranscript(subagentId: "fixture-child"),
        "fixture child transcript"
    )
    let childHasYield = transcriptHasTool(childTranscript.messages, "yield")
    let sawRunning = hasSubagentLifecycle(subagentEvents.toArray(), "running")
    let sawCompleted = hasSubagentLifecycle(subagentEvents.toArray(), "completed")
    expect(
        taskTurn.agentInvoked && taskApplication.subagents().isEmpty() && childTranscript.messages.size >= 4 &&
            subagentSlashCommandsVisible(taskApplication) && childHasYield && sawRunning && sawCompleted,
        "task runs a typed child session, captures yield, and exposes " +
            "its durable transcript through agents and agent commands; " +
            "invoked=" + taskTurn.agentInvoked.toString() +
            ", active=" + taskApplication.subagents().size.toString() +
            ", messages=" + childTranscript.messages.size.toString() +
            ", yield=" + childHasYield.toString() +
            ", running=" + sawRunning.toString() +
            ", completed=" + sawCompleted.toString()
    )
    let batchTurn = taskApplication.handle("fixture task batch").value().getOrThrow()
    expect(
        batchTurn.agentInvoked && taskApplication.subagents().isEmpty() &&
            taskApplication.subagentTranscript(subagentId: "fixture-batch-a").isOk() &&
            taskApplication.subagentTranscript(subagentId: "fixture-batch-b").isOk(),
        "task batch launches every item through bounded parallel child " + "sessions"
    )
    let hubSendTurn = taskApplication.handle("fixture task hub send").value().getOrThrow()
    var hubDeliveryVisible = false
    for (_ in 0..100) {
        if (transcriptHasText(
            taskApplication.messages().value().getOrThrow(),
            "child report delivered"
        )) {
            hubDeliveryVisible = true
            break
        }
        sleep(Duration.millisecond * 10)
    }
    let hubInboxTurn = taskApplication.handle("fixture hub inbox").value().getOrThrow()
    let hubListTurn = taskApplication.handle("fixture hub list").value().getOrThrow()
    let hubMessages = taskApplication.messages().value().getOrThrow()
    let hubInboxVisible = toolResultListContains(
        hubMessages,
        "fixture-hub-inbox-call",
        "inbox",
        "message",
        "child report delivered"
    )
    let hubListVisible = toolResultListContains(
        hubMessages,
        "fixture-hub-list-call",
        "peers",
        "id",
        "fixture-hub-child"
    )
    expect(
        hubSendTurn.agentInvoked && hubDeliveryVisible && hubInboxTurn.agentInvoked &&
            hubInboxVisible && hubListTurn.agentInvoked && hubListVisible,
        "hub send durably injects a child message while inbox and list expose the scoped coordination state; " +
            "send=" + hubSendTurn.agentInvoked.toString() +
            ", delivery=" + hubDeliveryVisible.toString() +
            ", inboxRun=" + hubInboxTurn.agentInvoked.toString() +
            ", inbox=" + hubInboxVisible.toString() +
            ", listRun=" + hubListTurn.agentInvoked.toString() +
            ", list=" + hubListVisible.toString()
    )
    let childTranscriptBefore = taskApplication
        .subagentTranscript(subagentId: "fixture-hub-child")
        .value()
        .getOrThrow()
    let childMessagesBefore = childTranscriptBefore.messages.size
    let reviveTurn = taskApplication.handle("fixture hub send child").value().getOrThrow()
    var childRevived = false
    for (_ in 0..200) {
        let transcript = taskApplication.subagentTranscript(subagentId: "fixture-hub-child").value().getOrThrow()
        if (transcript.messages.size > childMessagesBefore && transcriptHasText(
            transcript.messages,
            "follow up child"
        ) && taskApplication.subagents().isEmpty()) {
            childRevived = true
            break
        }
        sleep(Duration.millisecond * 10)
    }
    let childDelta = taskApplication.subagentTranscript(
        subagentId: "fixture-hub-child",
        fromItem: childTranscriptBefore.nextItem
    ).value().getOrThrow()
    let childFullAfter = taskApplication.subagentTranscript(subagentId: "fixture-hub-child").value().getOrThrow()
    let childInvalidCursor = taskApplication.subagentTranscript(
        subagentId: "fixture-hub-child",
        fromItem: max(1, childTranscriptBefore.nextItem - 1)
    ).value().getOrThrow()
    expect(
        reviveTurn.agentInvoked && childRevived && !childDelta.reset && childDelta.messages.size > 0 &&
            childDelta.messages.size < childFullAfter.messages.size && !childInvalidCursor.reset &&
            childInvalidCursor.messages.size > childDelta.messages.size && transcriptHasText(
            childDelta.messages,
            "follow up child"
        ),
        "direct hub send revives a completed child on its durable " +
        "session and canonical item cursors return only the follow-up suffix"
    )
    let uiMessage = taskApplication.messageSubagent(
        "fixture-hub-child",
        "message from focused tui conversation"
    )
    var uiMessageVisible = false
    for (_ in 0..200) {
        let transcript = taskApplication.subagentTranscript(subagentId: "fixture-hub-child").value().getOrThrow()
        if (transcriptHasText(
            transcript.messages,
            "message from focused tui conversation"
        )) {
            uiMessageVisible = true
            break
        }
        sleep(Duration.millisecond * 10)
    }
    expect(
        uiMessage.isOk() && uiMessageVisible,
        "focused TUI conversations send through the durable hub channel"
    )
    let agentsCommand = taskApplication.handle("/agents").value().getOrThrow()
    expect(
        !agentsCommand.agentInvoked && agentsCommand.text.contains("fixture-hub-child") && agentsCommand
            .text
            .contains("status=completed"),
        "/agents reports retained child lifecycle without a model call"
    )
}

func runProcessHubContracts(
    root: String,
    product: ProductRuntime
): Unit {
    let processApplication = product.applicationSession()
    let processStart = processApplication.handle("fixture hub process start").value().getOrThrow()
    let processStartResult = toolResultValue(
        processApplication.messages().value().getOrThrow(),
        "fixture-hub-process-start-call"
    ).getOrThrow()
    let startedDaemon = processStartResult.field("daemon").getOrThrow()
    expect(
        processStart.agentInvoked && !processStartResult.field("readyTimedOut").getOrThrow().boolean &&
            startedDaemon.field("state").getOrThrow().text == "ready" &&
            startedDaemon.field("readyMatch").getOrThrow().text == "READY" &&
            startedDaemon.field("pid").getOrThrow().unifiedKind == ValueKind.Number &&
            startedDaemon.field("id").getOrThrow().text != "" && startedDaemon.field("owner").getOrThrow().text != "",
        "hub start supervises a named process and waits for its ready " + "condition"
    )
    let processLogs = processApplication.handle("fixture hub process logs").value().getOrThrow()
    let processLogResult = toolResultValue(
        processApplication.messages().value().getOrThrow(),
        "fixture-hub-process-logs-call"
    ).getOrThrow()
    expect(
        processLogs.agentInvoked && processLogResult.field("text").getOrThrow().text.contains("READY") &&
            processLogResult.field("cursor").getOrThrow().number != "0",
        "hub logs exposes bounded output and a monotonic byte cursor"
    )
    expect(
        processApplication.handle("fixture hub process send").value().getOrThrow().agentInvoked,
        "hub send writes to the supervised process stdin"
    )
    let processWait = processApplication.handle("fixture hub process wait").value().getOrThrow()
    let processWaitResult = toolResultValue(
        processApplication.messages().value().getOrThrow(),
        "fixture-hub-process-wait-call"
    ).getOrThrow()
    expect(
        processWait.agentInvoked && !processWaitResult.field("timedOut").getOrThrow().boolean &&
            processWaitResult.field("matched").getOrThrow().text == "ECHO:hello",
        "hub wait observes a regex produced after stdin delivery"
    )
    let processDescribe = processApplication.handle("fixture hub process describe").value().getOrThrow()
    let processSpec = toolResultValue(
        processApplication.messages().value().getOrThrow(),
        "fixture-hub-process-describe-call"
    ).getOrThrow().field("spec").getOrThrow()
    expect(
        processDescribe.agentInvoked && processSpec.field("application").getOrThrow().text == "/bin/bash" &&
            processSpec.field("restart").getOrThrow().text == "no" && !processSpec
            .field("persist")
            .getOrThrow()
            .boolean && !processSpec.field("detached").getOrThrow().boolean,
        "hub describe returns the immutable launch specification"
    )
    let processRestart = processApplication.handle("fixture hub process restart").value().getOrThrow()
    let restartedDaemon = toolResultValue(
        processApplication.messages().value().getOrThrow(),
        "fixture-hub-process-restart-call"
    ).getOrThrow().field("daemon").getOrThrow()
    expect(
        processRestart.agentInvoked && restartedDaemon.field("state").getOrThrow().text == "ready" &&
            restartedDaemon.field("restartCount").getOrThrow().number == "0",
        "manual hub restart relaunches without counting as an automatic " + "restart"
    )
    let processPs = processApplication.handle("fixture hub process ps").value().getOrThrow()
    expect(
        processPs.agentInvoked && toolResultListContains(
            processApplication.messages().value().getOrThrow(),
            "fixture-hub-process-ps-call",
            "daemons",
            "name",
            "fixture-daemon"
        ),
        "hub ps lists project-scoped supervised processes"
    )
    let processStop = processApplication.handle("fixture hub process stop").value().getOrThrow()
    let stoppedDaemon = toolResultValue(
        processApplication.messages().value().getOrThrow(),
        "fixture-hub-process-stop-call"
    ).getOrThrow().field("daemon").getOrThrow()
    expect(
        processStop.agentInvoked && stoppedDaemon.field("state").getOrThrow().text == "exited" &&
            stoppedDaemon.field("pid").getOrThrow().unifiedKind == ValueKind.Null,
        "hub stop terminates the process group and returns a terminal " + "snapshot"
    )
    let guardedHubProduct = openProduct(
        config: ProductConfig(
            stateRoot: root + "/guarded-hub-state",
            workspaceRoot: root,
            fixture: true,
            approvalMode: ApprovalMode.AlwaysAsk,
            asyncEnabled: false
        )
    ).value().getOrThrow()
    let guardedHub = guardedHubProduct.applicationSession()
    let guardedHubStart = match (guardedHub.handle("fixture hub process start")) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(
            "guarded hub start failed: " + error.code + ": " + error.message
        )
    }
    let guardedHubStartApproval = guardedHubStart.approval.getOrThrow()
    expect(
        guardedHubStartApproval.capability.kind == CapabilityKind.ProcessSpawn,
        "hub start resolves to process-spawn approval"
    )
    let guardedHubStartDecision = guardedHub.decide(
        guardedHubStartApproval.operationId.value,
        ApprovalDecision.Approve
    )
    match (guardedHubStartDecision) {
        case Result.Ok(_) => ()
        case Result.Err(error) => throw IllegalStateException(
            "approved hub start failed: " + error.code + ": " + error.message
        )
    }
    expect(guardedHubStartDecision.isOk(), "approved hub start executes once")
    let guardedHubLogs = guardedHub.handle("fixture hub process logs").value().getOrThrow()
    expect(
        guardedHubLogs.approval.isNone(),
        "hub process inspection stays read-only"
    )
    let guardedHubSend = guardedHub.handle("fixture hub process send").value().getOrThrow()
    let guardedHubSendApproval = guardedHubSend.approval.getOrThrow()
    expect(
        guardedHubSendApproval.capability.kind == CapabilityKind.ProcessSpawn && guardedHub.decide(
            guardedHubSendApproval.operationId.value,
            ApprovalDecision.RejectWithReason("contract rejection")
        ).isOk(),
        "hub process input is separately approval-gated"
    )
    let guardedHubStop = guardedHub.handle("fixture hub process stop").value().getOrThrow()
    let guardedHubStopApproval = guardedHubStop.approval.getOrThrow()
    expect(
        guardedHubStopApproval.capability.kind == CapabilityKind.ProcessSpawn && guardedHub.decide(
            guardedHubStopApproval.operationId.value,
            ApprovalDecision.Approve
        ).isOk(),
        "hub stop uses process-spawn approval and cleans up the daemon"
    )
    guardedHubProduct.close()
}

func runGuardedAndAsyncContracts(root: String): Unit {
    let guardedProduct = openProduct(
        config: ProductConfig(
            stateRoot: root + "/guarded-task-state",
            workspaceRoot: root,
            fixture: true,
            approvalMode: ApprovalMode.AlwaysAsk,
            asyncEnabled: false
        )
    ).value().getOrThrow()
    let guardedApplication = guardedProduct.applicationSession()
    let guardedTurn = guardedApplication.handle("fixture task write").value().getOrThrow()
    let guardedApproval = guardedTurn.approval.getOrThrow()
    let guardedDecision = guardedApplication.decide(
        guardedApproval.operationId.value,
        ApprovalDecision.Approve
    ).value().getOrThrow()
    let blockedChildren = guardedApplication.subagents()
    expect(
        blockedChildren.isEmpty(),
        "task-role workspace child settles without inheriting the parent's approval"
    )
    expect(guardedDecision.snapshot.isSome(),
        "approved parent task returns a terminal Run snapshot")
    expect(exists(Path(root + "/child-approved.txt")),
        "approved child workspace mutation creates its artifact")
    expect(String.fromUtf8(File.readFrom(root + "/child-approved.txt")) ==
        "written by child\n", "approved child workspace mutation preserves content")
    expect(guardedApplication.subagents().isEmpty(),
        "blocking child lifecycle settles before the parent decision returns")
    let guardedCancelApplication = guardedProduct.applicationSession()
    let cancelledApproval = guardedCancelApplication
        .handle("fixture task write")
        .value()
        .getOrThrow()
        .approval
        .getOrThrow()
    expect(
        guardedCancelApplication.cancel().isOk() && guardedCancelApplication.approval().isNone() &&
            transcriptHasErrorToolResult(
            guardedCancelApplication.messages().value().getOrThrow(),
            cancelledApproval.callId
        ),
        "cancelling a pending approval clears application state and repairs its tool result"
    )
    let secondApproval = guardedCancelApplication
        .handle("fixture task write")
        .value()
        .getOrThrow()
        .approval
        .getOrThrow()
    expect(
        secondApproval.operationId.value != cancelledApproval.operationId.value &&
            guardedCancelApplication.approval().isSome(),
        "a second approval is exposed immediately after cancelling the first"
    )
    expect(
        guardedCancelApplication.cancel().isOk(),
        "second pending approval remains cancellable"
    )
    let asyncProduct = openProduct(
        config: ProductConfig(
            stateRoot: root + "/async-state",
            workspaceRoot: root,
            fixture: true,
            approvalMode: ApprovalMode.Yolo,
            asyncEnabled: true
        )
    ).value().getOrThrow()
    let asyncApplication = asyncProduct.applicationSession()
    let asyncTurn = asyncApplication.handle("fixture task").value().getOrThrow()
    let asyncJobs = asyncApplication.waitForAsyncJobs(
        [],
        timeoutMillis: 5000
    )
    expect(
        asyncTurn.agentInvoked && asyncJobs.size == 1 && asyncJobs[0].id == "fixture-child" && asyncJobs[0].status ==
            "completed" && asyncJobs[0].result.isSome() && transcriptHasAsyncResult(
            asyncApplication.messages().value().getOrThrow(),
            "fixture-child"
        ),
        "non-blocking task returns as a managed job and injects its " + "settled result into the parent session"
    )
    let jobsCommand = asyncApplication.handle("/jobs").value().getOrThrow()
    expect(
        !jobsCommand.agentInvoked && jobsCommand.text.contains("fixture-child") && jobsCommand
            .text
            .contains("status=completed"),
        "/jobs reports the managed job registry locally"
    )
    let hubTurn = asyncApplication.handle("fixture hub jobs").value().getOrThrow()
    expect(
        hubTurn.agentInvoked && transcriptHasTool(
            asyncApplication.messages().value().getOrThrow(),
            "hub"
        ),
        "hub jobs is a real model-facing tool over the managed job " + "registry"
    )
    let asyncBashApplication = asyncProduct.applicationSession()
    let asyncBashTurn = asyncBashApplication.handle("fixture async bash").value().getOrThrow()
    let asyncBashJobs = asyncBashApplication.waitForAsyncJobs(
        [],
        timeoutMillis: 5000
    )
    expect(
        asyncBashTurn.agentInvoked && asyncBashJobs.size == 1 && asyncBashJobs[0].jobType == "bash" &&
            asyncBashJobs[0].status == "completed" && asyncBashJobs[0].result.isSome() &&
            asyncBashJobs[0].result.getOrThrow().field("stdout").getOrThrow().text == "async-bash-result",
        "bash async:true runs as a managed job with captured output"
    )
    let asyncBashCancelApplication = asyncProduct.applicationSession()
    let asyncBashCancelTurn = asyncBashCancelApplication.handle("fixture async bash wait").value().getOrThrow()
    let waitingBashJobs = asyncBashCancelApplication.asyncJobs()
    expect(
        waitingBashJobs.size == 1,
        "async bash wait registers before control returns"
    )
    let cancelledBashJobs = asyncBashCancelApplication.cancelAsyncJobs([waitingBashJobs[0].id])
    sleep(Duration.millisecond * 100)
    expect(
        asyncBashCancelTurn.agentInvoked && waitingBashJobs.size == 1 && cancelledBashJobs.size == 1 &&
            cancelledBashJobs[0].jobType == "bash" && cancelledBashJobs[0].status == "cancelled",
        "hub cancel terminates a specific asynchronous bash process"
    )
    let asyncBatchApplication = asyncProduct.applicationSession()
    let asyncBatchTurn = asyncBatchApplication.handle("fixture task batch").value().getOrThrow()
    var asyncBatchJobs = asyncBatchApplication.asyncJobs()
    for (_ in 0..500) {
        if (allAsyncJobsSettled(asyncBatchJobs, 2)) {
            break
        }
        sleep(Duration.millisecond * 10)
        asyncBatchJobs = asyncBatchApplication.asyncJobs()
    }
    expect(
        asyncBatchTurn.agentInvoked && allAsyncJobsSettled(asyncBatchJobs, 2),
        "non-blocking task batch allocates and settles one managed job " + "per child"
    )
    let asyncCancelApplication = asyncProduct.applicationSession()
    let asyncCancelTurn = asyncCancelApplication.handle("fixture task cancel").value().getOrThrow()
    let runningJobs = asyncCancelApplication.asyncJobs()
    expect(
        asyncCancelTurn.agentInvoked && runningJobs.size == 1 && runningJobs[0].status == "running",
        "long-running task is observable as a managed background job"
    )
    let cancelledJobs = asyncCancelApplication.cancelAsyncJobs([runningJobs[0].id])
    sleep(Duration.millisecond * 100)
    expect(
        cancelledJobs.size == 1 && cancelledJobs[0].status == "cancelled" && asyncCancelApplication
            .subagents()
            .isEmpty(),
        "hub cancellation stops the specific background child and its " + "running process"
    )
    asyncProduct.close()
    guardedProduct.close()
}

func runSubagentCancellationContracts(product: ProductRuntime): Unit {
    let cancelApplication = product.applicationSession()
    let cancelEvents = ArrayList<ProductSubagentEvent>()
    cancelApplication.subscribeSubagents({
        event => cancelEvents.add(event)
    })
    let cancellingTask = spawn {
        cancelApplication.handle("fixture task cancel")
    }
    var childBecameActive = false
    var activeChildId = ""
    for (_ in 0..40) {
        let active = cancelApplication.subagents()
        for (candidate in active where
            candidate.task == "child fixture bash wait") {
            childBecameActive = true
            activeChildId = candidate.id
        }
        if (childBecameActive) {
            break
        }
        sleep(Duration.millisecond * 25)
    }
    expect(
        childBecameActive,
        "long-running child becomes visible before cancellation"
    )
    let cancellation = cancelApplication.cancelSubagent(activeChildId)
    expect(match (cancellation) {
        case Result.Ok(_) => true
        case Result.Err(error) => throw IllegalStateException(
            "focused child cancellation failed: " + error.code + ": " + error.message
        )
    }, "focused conversation cancellation reaches the selected child task")
    let _ = cancellingTask.get()
    expect(
        cancelApplication.subagents().isEmpty() && hasSubagentLifecycle(
            cancelEvents.toArray(),
            "cancelled"
        ),
        "focused child cancellation clears that child without requiring " + "the Main conversation to fail"
    )
}

func runSessionLifecycleContracts(
    root: String,
    product: ProductRuntime,
    application: ApplicationSession
): Unit {
    runAtomicProjectionWrapperContract(product)
    let selected = application.handle("/model fixture-next").value().getOrThrow()
    expect(
        !selected.agentInvoked && selected.text == "model: fixture-next",
        "model selection is local"
    )
    application.setAutoCompaction(false)
    for (index in 0..7) {
        let turn = application.handle("compact fixture " + index.toString()).value().getOrThrow()
        expect(turn.agentInvoked, "fixture turn invokes the agent")
    }
    let compacted = application.handle("/compact").value().getOrThrow()
    expect(application.handle("checkpoint projection probe").isOk(),
        "next model request consumes the saved checkpoint")
    let activeContext = match (product.fixtureProbe.getOrThrow().lastRequest) {
        case Some(request) => request.messages
        case None => throw IllegalStateException("checkpoint projection request was not captured")
    }
    let fullTranscript = product.messages(application.id()).value().getOrThrow()
    expect(compacted.text.startsWith("compacted messages: "),
        "manual compaction reports its projected history reduction")
    expect(!activeContext.isEmpty() && !activeContext[0].blocks.isEmpty() &&
        activeContext[0].blocks[0].text.startsWith(
            "[Compacted canonical Thread through Item"
        ), "model context starts with a canonical Thread checkpoint")
    expect(activeContext[0].blocks[0].text.contains("key excerpts:"),
        "canonical checkpoint retains deterministic structured excerpts")
    expect(activeContext.size < fullTranscript.size,
        "checkpoint projection is smaller than canonical history")
    expect(!fullTranscript[0].blocks[0].text.contains(
        "[Compacted canonical Thread"
    ), "compaction never rewrites canonical transcript Items")
    let contextStats = application.handle("/context").value().getOrThrow()
    expect(
        contextStats.text.contains(
            "\nmessages: " + fullTranscript.size.toString() + "\n"
        ),
        "/context reports the provider-neutral canonical diagnostic projection"
    )
    // The retained window must never start on an orphan tool-result message:
    // its paired assistant tool call was compacted away, so a later provider
    // request would reject the dangling tool_result block.
    let orphanMessages = ArrayList<ModelMessage>()
    orphanMessages.add(
        ModelMessage(
            ModelRole.User,
            [ModelBlock(ModelBlockKind.Text, text: "orphan seed prompt")]
        )
    )
    orphanMessages.add(
        ModelMessage(
            ModelRole.Assistant,
            [ModelBlock(ModelBlockKind.Text, text: "orphan seed reply")]
        )
    )
    orphanMessages.add(
        ModelMessage(
            ModelRole.User,
            [ModelBlock(
                ModelBlockKind.ToolResult,
                callId: "call_compacted",
                name: "bash"
            )]
        )
    )
    for (index in 0..11) {
        orphanMessages.add(
            ModelMessage(
                ModelRole.User,
                [ModelBlock(
                    ModelBlockKind.Text,
                    text: "orphan fill " + index.toString()
                )]
            )
        )
    }
    let orphanSession = SessionId("orphan-compaction")
    expect(
        product.replaceMessages(
            orphanSession,
            orphanMessages.toArray()
        ).isError(),
        "canonical Thread seed rejects an orphan ToolResult before compaction"
    )
    let automaticMessages = ArrayList<ModelMessage>()
    for (index in 0..13) {
        automaticMessages.add(
            ModelMessage(
                ModelRole.User,
                [
                    ModelBlock(
                        ModelBlockKind.Text,
                        text: "automatic " + index.toString()
                    )
                ]
            )
        )
    }
    let automaticSession = SessionId("automatic-compaction")
    expect(
        product.replaceMessages(
            automaticSession,
            automaticMessages.toArray()
        ).isOk(),
        "automatic compaction history is seeded"
    )
    let automaticApplication = product.applicationSession(sessionId: Some(automaticSession))
    expect(
        automaticApplication.autoCompactionEnabled() &&
            automaticApplication.handle("trigger automatic compaction").isOk(),
        "automatic compaction runs after a completed turn"
    )
    let compactedAutomatically = product.messages(automaticSession).value().getOrThrow()
    expect(
        compactedAutomatically.size > 13 && !compactedAutomatically[0].blocks[0].text.contains(
            "[Compacted canonical Thread"
        ),
        "automatic compaction does not rewrite a short low-token history"
    )
    runResourceCompactionContracts(root)
    runStructuredCompactionSummaryContract(root, product)
    runHybridCompactionSummaryContracts(root)
    let sourceBeforeFork = application.id()
    let sourceTranscript = product.messages(sourceBeforeFork).value().getOrThrow()
    let exportPath = root + "/append-only-session.html"
    product.exportSessionHtml(sourceBeforeFork, exportPath).value().getOrThrow()
    expect(
        String.fromUtf8(File.readFrom(exportPath)).contains("compact fixture 0"),
        "session export uses the full transcript after compaction"
    )
    let forked = application.handle("/fork").value().getOrThrow()
    expect(
        forked.text.startsWith("session forked: ") && application.model() == "fixture-next",
        "session branch inherits the source model"
    )
    let branchSession = application.id()
    expect(
        product.sessionModel(branchSession).value().getOrThrow() == "fixture-next" &&
            product.messages(branchSession).value().getOrThrow().size == sourceTranscript.size &&
            durableCheckpointCount(root + "/state/state.db", branchSession) > 0,
        "fork copies the full transcript and its durable ContextCheckpoint"
    )
    expect(
        application.handle("/model fixture-branch").isOk(),
        "branched session can select its own model"
    )
    expect(
        application.enqueue("", "steer", "stale steer").isOk(),
        "active session accepts a steer at the interaction boundary"
    )
    let fresh = application.handle("/new").value().getOrThrow()
    expect(
        fresh.text.startsWith("new session: ") && application.model() == "fixture" && application.queuedCount() == 0,
        "new session starts with the default model and no stale steer"
    )
    let freshSession = application.id()
    expect(
        application.handle("/model fixture-fresh").isOk() && application
            .handle("/session " + branchSession.value)
            .isOk() && application.model() == "fixture-branch",
        "switching sessions restores the selected model"
    )
    let restoredApplication = product.applicationSession(sessionId: Some(freshSession))
    expect(
        restoredApplication.model() == "fixture-fresh",
        "recreated application session restores durable model metadata"
    )
    let legacySession = SessionId("legacy-without-model")
    let migratedApplication = product.applicationSession(sessionId: Some(legacySession))
    expect(
        migratedApplication.model() == "fixture" && product.sessionModel(legacySession).value().getOrThrow() == "fixture",
        "legacy session without model metadata is lazily migrated"
    )
    let restartedProduct = openProduct(
        config: ProductConfig(
            stateRoot: root + "/state",
            workspaceRoot: root,
            fixture: true,
            approvalMode: ApprovalMode.Yolo
        )
    ).value().getOrThrow()
    expect(
        restartedProduct.applicationSession(sessionId: Some(branchSession)).model() == "fixture-branch",
        "product restart restores the per-session model"
    )
    expect(
        application.handle("/made-up").isError(),
        "unknown slash input is rejected locally"
    )
    expect(
        application.handle("/rename contract session").value().getOrThrow().text == "session name: contract session",
        "session name is persisted through the product command"
    )
    expect(
        product.sessionName(application.id()).value().getOrThrow() == "contract session",
        "session name is readable from durable metadata"
    )
    let ompSession = root + "/session-archive.jsonl"
    File.writeTo(
        ompSession,
        ("{\"type\":\"session\",\"version\":3,\"id\":\"omp-1\"," +
            "\"timestamp\":\"2026-07-30T00:00:00Z\",\"cwd\":\"/tmp\"}\n" +
            "{\"type\":\"message\",\"id\":\"m1\",\"parentId\":null," +
            "\"timestamp\":\"2026-07-30T00:00:01Z\",\"message\":{" + "\"role\":\"user\",\"content\":\"hello\"}}\n" +
            "{\"type\":\"message\",\"id\":\"m2\",\"parentId\":\"m1\"," +
            "\"timestamp\":\"2026-07-30T00:00:02Z\",\"message\":{" + "\"role\":\"assistant\",\"content\":[{" +
            "\"type\":\"text\",\"text\":\"world\"}]}}\n" + "{\"type\":\"model_change\",\"id\":\"m3\"," +
            "\"parentId\":\"m2\",\"timestamp\":\"2026-07-30T00:00:03Z\"," + "\"model\":\"openai/gpt\"}\n").toArray()
    )
    let imported = application.handle("/import " + ompSession).value().getOrThrow()
    expect(
        imported.text.contains("2 messages") && imported.text.contains("2 entries skipped"),
        "session archive JSONL import reports imported and unsupported entries"
    )
    let importedSession = application.id()
    expect(
        containsSession(
            product.sessions().value().getOrThrow(),
            importedSession
        ),
        "imported session archive is selectable"
    )
    let archiveDatabase = SqliteDatabase(root + "/state/state.db")
    let archivedArtifact = ProductArtifactStore(
        root + "/state",
        database: Some(archiveDatabase)
    ).persistText("archive-artifact-body").value().getOrThrow()
    archiveDatabase.close()
    let reset = application.handle("/reset contract-reset").value().getOrThrow()
    expect(
        reset.text.startsWith("state archived and reset") && exists(
            Path(root + "/state/archives/contract-reset.state.db")) && exists(Path(
            root + "/state/archives/contract-reset.blobs/" + archivedArtifact.sha256 + ".txt"
        )),
        "archive/reset snapshots SQLite and every referenced artifact body before clearing state"
    )
    expect(
        application.handle("after reset").value().getOrThrow().agentInvoked,
        "the current process remains usable after archive/reset"
    )
}

func runAtomicProjectionWrapperContract(product: ProductRuntime): Unit {
    let session = SessionId("product-canonical-external-input")
    product.replaceMessages(session, [ModelMessage(
        ModelRole.User,
        [ModelBlock(ModelBlockKind.Text, text: "canonical input seed")]
    )]).value().getOrThrow()
    let receiptId = "product-canonical-input-receipt"
    let report = ModelMessage(ModelRole.User, [ModelBlock(
        ModelBlockKind.Text, text: "canonical input report"
    )])
    let first = spawn {
        product.appendExternalMessageOnce(session, receiptId, report)
    }
    let second = spawn {
        product.appendExternalMessageOnce(session, receiptId, report)
    }
    let firstCommit = first.get().value().getOrThrow()
    let secondCommit = second.get().value().getOrThrow()
    expect(
        firstCommit != secondCommit && product.messages(session).value().getOrThrow().size == 2,
        "canonical external input distinguishes first commit from receipt replay"
    )
    let appendA = ModelMessage(ModelRole.User, [ModelBlock(
        ModelBlockKind.Text, text: "canonical input a"
    )])
    let appendB = ModelMessage(ModelRole.User, [ModelBlock(
        ModelBlockKind.Text, text: "canonical input b"
    )])
    let differentA = spawn {
        product.appendExternalMessageOnce(session, "product-input-a", appendA)
    }
    let differentB = spawn {
        product.appendExternalMessageOnce(session, "product-input-b", appendB)
    }
    expect(
        differentA.get().value().getOrThrow() &&
            differentB.get().value().getOrThrow() &&
            product.messages(session).value().getOrThrow().size == 4,
        "canonical owner serializes concurrent distinct external inputs"
    )
    let retryReceipt = "product-input-retry"
    let retryMessage = ModelMessage(ModelRole.User, [ModelBlock(
        ModelBlockKind.Text, text: "canonical input retry"
    )])
    let retryFirst = spawn {
        product.appendExternalMessageOnce(session, retryReceipt, retryMessage)
    }
    let retrySecond = spawn {
        product.appendExternalMessageOnce(session, retryReceipt, retryMessage)
    }
    expect(
        retryFirst.get().value().getOrThrow() !=
            retrySecond.get().value().getOrThrow() &&
            product.messages(session).value().getOrThrow().size == 5,
        "canonical external input is exactly once for concurrent retries"
    )
}

func runResourceCompactionContracts(root: String): Unit {
    let settings = ProductCompactionSettings(
        maxInputTokens: 20000,
        triggerPercent: 85,
        targetPercent: 60,
        emergencyMaxMessages: 200,
        keepRecentTokens: 8000,
        keepRecentMessages: 6,
        oversizedToolResultTokens: 2000,
        modelOverrides: [ProductModelCompactionSettings(
            "fixture-large",
            maxInputTokens: Some(100000)
        )]
    )
    let product = openProduct(
        config: ProductConfig(
            stateRoot: root + "/resource-compaction-state",
            workspaceRoot: root,
            fixture: true,
            asyncEnabled: false,
            compactionOverride: Some(settings)
        )
    ).value().getOrThrow()
    let session = SessionId("resource-compaction")
    var large = ""
    for (_ in 0..12000) {
        large += "x"
    }
    let history = ArrayList<ModelMessage>()
    for (index in 0..8) {
        history.add(ModelMessage(
            ModelRole.User,
            [ModelBlock(ModelBlockKind.Text, text: "large " + index.toString() + " " + large)]
        ))
    }
    let modelSession = SessionId("model-resource-compaction")
    product.replaceMessages(modelSession, history.toArray()).value().getOrThrow()
    product.setSessionModel(modelSession, "fixture-large").value().getOrThrow()
    expect(
        product.compactSession(modelSession, force: false).value().getOrThrow() == 0,
        "a model-specific larger input budget suppresses premature automatic compaction"
    )
    product.setSessionModel(modelSession, "fixture").value().getOrThrow()
    let resourceCompaction = product.compactSession(modelSession, force: false)
    expect(
        match (resourceCompaction) {
            case Result.Ok(value) => value > 0
            case Result.Err(error) => throw IllegalStateException(
                "resource compaction failed: " + error.code + ": " + error.message
            )
        },
        "automatic compaction re-evaluates the active session model watermark"
    )
    product.replaceMessages(session, history.toArray()).value().getOrThrow()
    let application = product.applicationSession(sessionId: Some(session))
    expect(application.handle("trigger resource compaction").isOk(), "large resource history completes a turn")
    application.setAutoCompaction(false)
    expect(application.handle("resource checkpoint projection probe").isOk(),
        "next resource request consumes the automatic checkpoint")
    let compacted = product.fixtureProbe.getOrThrow().lastRequest
        .getOrThrow().messages
    let fullTranscript = product.messages(session).value().getOrThrow()
    expect(
        !compacted.isEmpty() && !compacted[0].blocks.isEmpty() &&
            compacted[0].blocks[0].text.contains("[Compacted canonical Thread"),
        "resource threshold projects the durable checkpoint into the next model request"
    )
    let projectedTokens = estimateMessagesTokens(compacted)
    let targetTokens = settings.maxInputTokens * settings.targetPercent / 100
    expect(
        projectedTokens <= targetTokens,
        "resource checkpoint projection stays below target tokens: actual=" +
            projectedTokens.toString() + ", target=" + targetTokens.toString()
    )
    expect(
        fullTranscript.size > compacted.size,
        "resource checkpoint projection is smaller than canonical history: projection=" +
            compacted.size.toString() + ", canonical=" + fullTranscript.size.toString()
    )
    expect(
        !fullTranscript[0].blocks[0].text.contains("[Compacted canonical Thread"),
        "resource compaction never rewrites canonical Thread Items"
    )
    let previousSize = compacted.size
    let previousSummary = compacted[0].blocks[0].text
    expect(application.handle("small follow-up").isOk(), "small post-compaction turn completes")
    let afterSmallGrowth = product.fixtureProbe.getOrThrow().lastRequest
        .getOrThrow().messages
    expect(
        afterSmallGrowth.size > previousSize && afterSmallGrowth[0].blocks[0].text == previousSummary,
        "hysteresis prevents immediate summary-of-summary compaction after small growth"
    )
}

func runStructuredCompactionSummaryContract(
    root: String,
    product: ProductRuntime
): Unit {
    let session = SessionId("structured-compaction")
    product.createGoal(session, "Preserve deterministic compaction facts").value().getOrThrow()
    product.setTodoPhases(session, [TodoPhase(
        "Verification",
        [TodoItem("rerun product contract", status: TodoStatus.InProgress)]
    )]).value().getOrThrow()
    let messages = ArrayList<ModelMessage>()
    messages.add(ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: "record facts")]))
    messages.add(ModelMessage(ModelRole.Assistant, [ModelBlock(
        ModelBlockKind.ToolCall,
        callId: "write-summary",
        name: "write",
        arguments: objectValue([ValueField("path", textValue("created.cj"))])
    )]))
    messages.add(ModelMessage(ModelRole.User, [ModelBlock(
        ModelBlockKind.ToolResult,
        callId: "write-summary",
        name: "write",
        arguments: objectValue([
            ValueField("path", textValue("created.cj")),
            ValueField("action", textValue("create"))
        ])
    )]))
    messages.add(ModelMessage(ModelRole.Assistant, [ModelBlock(
        ModelBlockKind.ToolCall,
        callId: "test-summary",
        name: "bash",
        arguments: objectValue([ValueField("command", textValue("cjpm test"))])
    )]))
    messages.add(ModelMessage(ModelRole.User, [ModelBlock(
        ModelBlockKind.ToolResult,
        callId: "test-summary",
        name: "bash",
        arguments: objectValue([
            ValueField("exit_code", integerValue(1)),
            ValueField("stderr", textValue("contract failed"))
        ]),
        isError: true
    )]))
    for (index in 0..14) {
        messages.add(ModelMessage(
            if (index % 2 == 0) { ModelRole.User } else { ModelRole.Assistant },
            [ModelBlock(ModelBlockKind.Text, text: "recent " + index.toString())]
        ))
    }
    product.replaceMessages(session, messages.toArray()).value().getOrThrow()
    expect(product.compactSession(session, force: true).value().getOrThrow() > 0, "structured history compacts")
    let summary = durableCheckpointSummary(root + "/state/state.db", session)
    expect(
        summary.contains("goal:") && summary.contains("Preserve deterministic compaction facts") &&
            summary.contains("unresolved:") && summary.contains("rerun product contract") &&
            summary.contains("tools: write, bash") && summary.contains("created.cj (Created)") &&
            summary.contains("important commands:") && summary.contains("cjpm test") &&
            summary.contains("diagnostics:") && summary.contains("contract failed"),
        "structured summary preserves reliable goal, todo, file, command, result, and diagnostic facts"
    )
}

func runHybridCompactionSummaryContracts(root: String): Unit {
    let product = openProduct(
        config: ProductConfig(
            stateRoot: root + "/hybrid-compaction-state",
            workspaceRoot: root,
            fixture: true,
            asyncEnabled: false,
            compactionOverride: Some(ProductCompactionSettings(
                keepRecentMessages: 6,
                summaryStrategy: "hybrid",
                summaryModel: "fixture",
                summaryTimeoutMillis: 1000,
                summaryMaxOutputTokens: 200,
                summaryFailurePolicy: "fallback_structured"
            ))
        )
    ).value().getOrThrow()

    let hybridSession = SessionId("hybrid-compaction")
    product.createGoal(hybridSession, "Preserve facts while adding semantic context").value().getOrThrow()
    let hybridMessages = ArrayList<ModelMessage>()
    hybridMessages.add(ModelMessage(
        ModelRole.User,
        [ModelBlock(ModelBlockKind.Text, text: "Record the authoritative hybrid facts")]
    ))
    for (index in 0..14) {
        hybridMessages.add(ModelMessage(
            if (index % 2 == 0) { ModelRole.Assistant } else { ModelRole.User },
            [ModelBlock(ModelBlockKind.Text, text: "hybrid history " + index.toString())]
        ))
    }
    product.replaceMessages(hybridSession, hybridMessages.toArray()).value().getOrThrow()
    expect(product.compactSession(hybridSession, force: true).value().getOrThrow() > 0, "hybrid history compacts")
    let hybridSummary = durableCheckpointSummary(
        root + "/hybrid-compaction-state/state.db", hybridSession
    )
    expect(
        hybridSummary.contains("goal:") &&
            hybridSummary.contains("Preserve facts while adding semantic context") &&
            hybridSummary.contains("model-generated overview (non-authoritative):") &&
            hybridSummary.contains(
                "The session established concrete facts and left clearly identified work for the next turn."
            ),
        "hybrid compaction appends a non-authoritative model overview after deterministic facts"
    )
    let hybridStats = product.dashboardStats().value().getOrThrow()
    var hybridHasRun = false
    for (value in hybridStats.byRun where value.sessionId == hybridSession.value) {
        hybridHasRun = true
    }
    expect(
        !hybridHasRun,
        "standalone compaction does not fabricate a semantic Run without a Turn owner"
    )

    let fallbackSession = SessionId("hybrid-compaction-fallback")
    let fallbackMessages = ArrayList<ModelMessage>()
    fallbackMessages.add(ModelMessage(
        ModelRole.User,
        [ModelBlock(ModelBlockKind.Text, text: "FIXTURE-COMPACTION-SUMMARY-FAILURE preserve this fact")]
    ))
    for (index in 0..14) {
        fallbackMessages.add(ModelMessage(
            if (index % 2 == 0) { ModelRole.Assistant } else { ModelRole.User },
            [ModelBlock(ModelBlockKind.Text, text: "fallback history " + index.toString())]
        ))
    }
    product.replaceMessages(fallbackSession, fallbackMessages.toArray()).value().getOrThrow()
    expect(
        product.compactSession(fallbackSession, force: true).value().getOrThrow() > 0,
        "hybrid compaction succeeds when its optional model summary fails"
    )
    let fallbackSummary = durableCheckpointSummary(
        root + "/hybrid-compaction-state/state.db", fallbackSession
    )
    expect(
        fallbackSummary.contains("FIXTURE-COMPACTION-SUMMARY-FAILURE") &&
            !fallbackSummary.contains("model-generated overview (non-authoritative):"),
        "hybrid model failure falls back to the authoritative structured summary"
    )
    let fallbackStats = product.dashboardStats().value().getOrThrow()
    var fallbackHasRun = false
    for (value in fallbackStats.byRun where value.sessionId == fallbackSession.value) {
        fallbackHasRun = true
    }
    expect(
        !fallbackHasRun,
        "failed optional compaction summary does not create an ownerless maintenance Run"
    )
}

func durableCheckpointSummary(path: String, sessionId: SessionId): String {
    let database = SqliteDatabase(path)
    try {
        let rows = database.query(
            "SELECT payload FROM context_checkpoints WHERE thread_id=" +
                sqliteText(sessionId.value) +
                " ORDER BY covers_through_item_ordinal DESC,id DESC LIMIT 1"
        )
        if (rows.size != 1) {
            throw IllegalStateException("durable ContextCheckpoint is missing")
        }
        let payload = decodeStoredValue(rows[0].required(0))
        let structured = payload.field("structured_summary").getOrThrow()
        structured.field("deterministic_summary").getOrThrow().text
    } finally {
        database.close()
    }
}

func durableCheckpointCount(path: String, sessionId: SessionId): Int64 {
    let database = SqliteDatabase(path)
    try {
        database.query(
            "SELECT id FROM context_checkpoints WHERE thread_id=" +
                sqliteText(sessionId.value)
        ).size
    } finally {
        database.close()
    }
}

func containsSession(
    sessions: Array<SessionId>,
    expected: SessionId
): Bool {
    for (candidate in sessions where candidate.value == expected.value) {
        return true
    }
    false
}

func waitForAsk(
    runtime: AskRuntime,
    sessionId: SessionId
): ProductAskRequest {
    for (_ in 0..500) {
        match (runtime.current(sessionId)) {
            case Some(value) => return value
            case None => sleep(Duration.millisecond * 10)
        }
    }
    throw IllegalStateException("timed out waiting for ask request")
}

func waitForApplicationAsk(session: ApplicationSession): ProductAskRequest {
    for (_ in 0..500) {
        match (session.pendingAsk()) {
            case Some(value) => return value
            case None => sleep(Duration.millisecond * 10)
        }
    }
    throw IllegalStateException("timed out waiting for application ask request")
}

func askSingleCall(callId: String): ToolCall {
    ToolCall(
        callId,
        "ask",
        objectValue(
            [
                ValueField(
                    "questions",
                    listValue(
                        [
                            objectValue(
                                [
                                    ValueField("id", textValue("auth_method")),
                                    ValueField(
                                        "question",
                                        textValue("Which authentication method should this API use?")
                                    ),
                                    ValueField(
                                        "options",
                                        listValue(
                                            [
                                                objectValue(
                                                    [
                                                        ValueField("label", textValue("JWT")),
                                                        ValueField(
                                                            "description",
                                                            textValue("Bearer tokens for stateless clients.")
                                                        )
                                                    ]
                                                ),
                                                objectValue(
                                                    [
                                                        ValueField("label", textValue("OAuth2")),
                                                        ValueField(
                                                            "preview",
                                                            textValue("Delegated authorization")
                                                        )
                                                    ]
                                                )
                                            ]
                                        )
                                    ),
                                    ValueField("recommended", integerValue(0))
                                ]
                            )
                        ]
                    )
                )
            ]
        )
    )
}

func askMultipleCall(callId: String): ToolCall {
    ToolCall(
        callId,
        "ask",
        objectValue(
            [
                ValueField(
                    "questions",
                    listValue(
                        [
                            objectValue(
                                [
                                    ValueField("id", textValue("storage")),
                                    ValueField(
                                        "question",
                                        textValue("Which storage backend?")
                                    ),
                                    ValueField(
                                        "options",
                                        listValue(
                                            [
                                                objectValue([ValueField("label", textValue("SQLite"))]),
                                                objectValue([ValueField("label", textValue("PostgreSQL"))])
                                            ]
                                        )
                                    )
                                ]
                            ),
                            objectValue(
                                [
                                    ValueField("id", textValue("features")),
                                    ValueField(
                                        "question",
                                        textValue("Which features should be enabled?")
                                    ),
                                    ValueField(
                                        "options",
                                        listValue(
                                            [
                                                objectValue([ValueField("label", textValue("Search"))]),
                                                objectValue([ValueField("label", textValue("Export"))])
                                            ]
                                        )
                                    ),
                                    ValueField("multi", boolValue(true))
                                ]
                            )
                        ]
                    )
                )
            ]
        )
    )
}

func askReservedLabelCall(): ToolCall {
    ToolCall(
        "ask-reserved",
        "ask",
        objectValue(
            [
                ValueField(
                    "questions",
                    listValue(
                        [
                            objectValue(
                                [
                                    ValueField("id", textValue("reserved")),
                                    ValueField("question", textValue("Choose")),
                                    ValueField(
                                        "options",
                                        listValue(
                                            [
                                                objectValue(
                                                    [
                                                        ValueField(
                                                            "label",
                                                            textValue("Other (type your own)")
                                                        )
                                                    ]
                                                )
                                            ]
                                        )
                                    )
                                ]
                            )
                        ]
                    )
                )
            ]
        )
    )
}

func expectToolSchema(
    catalog: ToolCatalog,
    toolName: String,
    expectedProperties: Array<String>,
    expectedRequired: Array<String>
): Unit {
    for (definition in catalog.definitions() where definition.name == toolName) {
        let properties = definition.inputSchema.field("properties").getOrThrow()
        let required = definition.inputSchema.field("required").getOrThrow()
        let propertyNames = ArrayList<String>()
        for (field in properties.fields) {
            propertyNames.add(field.name)
        }
        let requiredNames = ArrayList<String>()
        for (value in required.items) {
            requiredNames.add(value.text)
        }
        expect(
            sameStrings(propertyNames.toArray(), expectedProperties) && sameStrings(requiredNames.toArray(),
                expectedRequired),
            toolName + " schema exposes the reviewed tool wire surface"
        )
        return
    }
    throw IllegalStateException("missing tool schema: " + toolName)
}

func expectToolSchemaWithOptionalExtensions(
    catalog: ToolCatalog,
    toolName: String,
    ompProperties: Array<String>,
    optionalExtensions: Array<String>,
    expectedRequired: Array<String>
): Unit {
    let expectedProperties = ArrayList<String>()
    expectedProperties.add(all: ompProperties)
    expectedProperties.add(all: optionalExtensions)
    for (definition in catalog.definitions() where definition.name == toolName) {
        let properties = definition.inputSchema.field("properties").getOrThrow()
        let required = definition.inputSchema.field("required").getOrThrow()
        let propertyNames = ArrayList<String>()
        for (field in properties.fields) {
            propertyNames.add(field.name)
        }
        let requiredNames = ArrayList<String>()
        for (value in required.items) {
            requiredNames.add(value.text)
        }
        expect(
            sameStrings(propertyNames.toArray(), expectedProperties.toArray()) &&
                sameStrings(requiredNames.toArray(), expectedRequired),
            toolName + " schema exposes the reviewed core and artifact fields"
        )
        return
    }
    throw IllegalStateException("missing tool schema: " + toolName)
}

func sameStrings(left: Array<String>, right: Array<String>): Bool {
    if (left.size != right.size) {
        return false
    }
    for (candidate in left) {
        var found = false
        for (expected in right) {
            if (candidate == expected) {
                found = true
                break
            }
        }
        if (!found) {
            return false
        }
    }
    true
}

func transcriptHasTool(
    messages: Array<ModelMessage>,
    toolName: String
): Bool {
    for (message in messages) {
        for (block in message.blocks where block.kind == ModelBlockKind.ToolCall && block.name == toolName) {
            return true
        }
    }
    false
}

func transcriptHasText(
    messages: Array<ModelMessage>,
    text: String
): Bool {
    for (message in messages) {
        for (block in message.blocks where block.text.contains(text)) {
            return true
        }
    }
    false
}

func transcriptHasErrorToolResult(
    messages: Array<ModelMessage>,
    callId: String
): Bool {
    for (message in messages) {
        for (block in message.blocks where block.kind == ModelBlockKind.ToolResult && block.callId == callId && block
            .isError) {
            return true
        }
    }
    false
}

func toolResultListContains(
    messages: Array<ModelMessage>,
    callId: String,
    listName: String,
    fieldName: String,
    expected: String
): Bool {
    for (message in messages) {
        for (block in message.blocks where block.kind == ModelBlockKind.ToolResult && block.callId == callId) {
            match (block.arguments.field(listName)) {
                case Some(value) => for (item in value.items) {
                    match (item.field(fieldName)) {
                        case Some(field) =>
                            if (field.unifiedKind == ValueKind.Text && field.text == expected) {
                                return true
                            }
                        case None => ()
                    }
                }
                case None => ()
            }
        }
    }
    false
}

func toolResultValue(
    messages: Array<ModelMessage>,
    callId: String
): ?AgentValue {
    for (message in messages) {
        for (block in message.blocks where block.kind == ModelBlockKind.ToolResult && block.callId == callId) {
            return Some(block.arguments)
        }
    }
    None
}

func transcriptHasAsyncResult(
    messages: Array<ModelMessage>,
    jobId: String
): Bool {
    for (message in messages) {
        for (block in message.blocks where block.kind == ModelBlockKind.Text && block.text.contains("<async-result>") &&
            block.text.contains("\"id\":\"" + jobId + "\"")) {
            return true
        }
    }
    false
}

func allAsyncJobsSettled(
    jobs: Array<ProductAsyncJobSnapshot>,
    expected: Int64
): Bool {
    if (jobs.size != expected) {
        return false
    }
    for (job in jobs where job.status == "running") {
        return false
    }
    true
}

func hasSubagentLifecycle(
    events: Array<ProductSubagentEvent>,
    status: String
): Bool {
    for (event in events where event.kind == "lifecycle" && event.snapshot.status == status) {
        return true
    }
    false
}

func isProviderSetupAction(action: ApplicationAction): Bool {
    match (action) {
        case ApplicationAction.OpenProviderSetup => true
        case _ => false
    }
}

func isModelSelectorAction(action: ApplicationAction): Bool {
    match (action) {
        case ApplicationAction.OpenModelSelector => true
        case _ => false
    }
}

func isBranchSelectorAction(action: ApplicationAction): Bool {
    match (action) {
        case ApplicationAction.OpenBranchSelector => true
        case _ => false
    }
}

func todoCall(
    callId: String,
    op: String,
    task!: String = "",
    phase!: String = "",
    items!: Array<String> = [],
    reason!: String = ""
): ToolCall {
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("op", textValue(op)))
    if (task != "") {
        fields.add(ValueField("task", textValue(task)))
    }
    if (phase != "") {
        fields.add(ValueField("phase", textValue(phase)))
    }
    if (!items.isEmpty()) {
        let encoded = ArrayList<AgentValue>()
        for (item in items) {
            encoded.add(textValue(item))
        }
        fields.add(ValueField("items", listValue(encoded.toArray())))
    }
    if (reason != "") {
        fields.add(ValueField("reason", textValue(reason)))
    }
    ToolCall(callId, "todo", objectValue(fields.toArray()))
}

func evalCall(
    callId: String,
    language: String,
    code: String,
    reset!: Bool = false,
    timeout!: Int64 = 30
): ToolCall {
    ToolCall(
        callId,
        "eval",
        objectValue(
            [
                ValueField("language", textValue(language)),
                ValueField("code", textValue(code)),
                ValueField("reset", boolValue(reset)),
                ValueField("timeout", integerValue(timeout))
            ]
        )
    )
}

func astEditCall(
    callId: String,
    pattern: String,
    output: String,
    paths: Array<String>
): ToolCall {
    astEditCallWithOps(callId, [[pattern, output]], paths)
}

func astEditCallWithOps(
    callId: String,
    ops: Array<Array<String>>,
    paths: Array<String>
): ToolCall {
    let encodedOps = ArrayList<AgentValue>()
    for (op in ops) {
        encodedOps.add(
            objectValue(
                [
                    ValueField("pat", textValue(op[0])),
                    ValueField("out", textValue(op[1]))
                ]
            )
        )
    }
    let encodedPaths = ArrayList<AgentValue>()
    for (path in paths) {
        encodedPaths.add(textValue(path))
    }
    ToolCall(
        callId,
        "ast_edit",
        objectValue(
            [
                ValueField("ops", listValue(encodedOps.toArray())),
                ValueField("paths", listValue(encodedPaths.toArray()))
            ]
        )
    )
}

func resolutionWrite(
    callId: String,
    path: String,
    reason: String
): ToolCall {
    ToolCall(
        callId,
        "write",
        objectValue(
            [
                ValueField("path", textValue(path)),
                ValueField("content", textValue(reason))
            ]
        )
    )
}

func lspCall(
    callId: String,
    action: String,
    file!: String = "",
    line!: Int64 = 0,
    symbol!: String = "",
    query!: String = "",
    newName!: String = "",
    apply!: ?Bool = None
): ToolCall {
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("action", textValue(action)))
    if (file != "") {
        fields.add(ValueField("file", textValue(file)))
    }
    if (line > 0) {
        fields.add(ValueField("line", integerValue(line)))
    }
    if (symbol != "") {
        fields.add(ValueField("symbol", textValue(symbol)))
    }
    if (query != "") {
        fields.add(ValueField("query", textValue(query)))
    }
    if (newName != "") {
        fields.add(ValueField("new_name", textValue(newName)))
    }
    match (apply) {
        case Some(value) => fields.add(ValueField("apply", boolValue(value)))
        case None => ()
    }
    ToolCall(callId, "lsp", objectValue(fields.toArray()))
}

func resourceLspServerSource(): String {
    ("import json, sys\n" + "root_uri = ''\n" + "def receive():\n" + "    length = None\n" + "    while True:\n" +
        "        line = sys.stdin.buffer.readline()\n" + "        if not line:\n" + "            return None\n" +
        "        if line in (b'\\r\\n', b'\\n'):\n" + "            break\n" +
        "        name, value = line.decode().split(':', 1)\n" + "        if name.lower() == 'content-length':\n" +
        "            length = int(value.strip())\n" + "    return json.loads(sys.stdin.buffer.read(length))\n" +
        "def send(value):\n" + "    body = json.dumps(value, separators=(',', ':')).encode()\n" +
        "    sys.stdout.buffer.write(" + "f'Content-Length: {len(body)}\\r\\n\\r\\n'.encode() + body)\n" +
        "    sys.stdout.buffer.flush()\n" + "while True:\n" + "    message = receive()\n" + "    if message is None:\n" +
        "        break\n" + "    method = message.get('method', '')\n" + "    if method == 'initialize':\n" +
        "        root_uri = message['params']['rootUri']\n" +
        "        result = {'capabilities': {'codeActionProvider': True}}\n" +
        "    elif method == 'textDocument/codeAction':\n" + "        created = root_uri + '/lsp/resource-created.txt'\n" +
        "        renamed = root_uri + '/lsp/nested/resource-renamed.txt'\n" +
        "        deleted = root_uri + '/lsp/delete_me.txt'\n" + "        rollback_created = root_uri + " +
        "'/lsp/rollback-created.txt'\n" + "        rollback_renamed = root_uri + " +
        "'/lsp/nested/rollback-renamed.txt'\n" + "        rollback_deleted = root_uri + " +
        "'/lsp/rollback_delete.txt'\n" + "        missing = root_uri + '/lsp/missing-after-operations.txt'\n" +
        "        result = [{'title': 'Apply resource operations', 'edit': {" + "'documentChanges': [" +
        "{'kind': 'create', 'uri': created}, " + "{'textDocument': {'uri': created, 'version': None}, " +
        "'edits': [{'range': {'start': {'line': 0, 'character': 0}, " + "'end': {'line': 0, 'character': 0}}, " +
        "'newText': 'created\\n'}]}, " + "{'kind': 'rename', 'oldUri': created, 'newUri': renamed}, " +
        "{'textDocument': {'uri': renamed, 'version': None}, " +
        "'edits': [{'range': {'start': {'line': 0, 'character': 0}, " + "'end': {'line': 0, 'character': 0}}, " +
        "'newText': 'renamed:'}]}, " + "{'kind': 'delete', 'uri': deleted}]}}, " +
        "{'title': 'Rollback resource operations', 'edit': {" + "'documentChanges': [" +
        "{'kind': 'create', 'uri': rollback_created}, " + "{'textDocument': {'uri': rollback_created, 'version': None}, " +
        "'edits': [{'range': {'start': {'line': 0, 'character': 0}, " + "'end': {'line': 0, 'character': 0}}, " +
        "'newText': 'temporary\\n'}]}, " + "{'kind': 'rename', 'oldUri': rollback_created, " +
        "'newUri': rollback_renamed}, " + "{'kind': 'delete', 'uri': rollback_deleted}, " +
        "{'textDocument': {'uri': missing, 'version': None}, " +
        "'edits': [{'range': {'start': {'line': 0, 'character': 0}, " + "'end': {'line': 0, 'character': 0}}, " +
        "'newText': 'must fail'}]}]}}, " + "{'title': 'Server apply edit', " +
        "'command': {'command': 'resource.apply'}}]\n" + "    elif method == 'workspace/executeCommand':\n" +
        "        target = root_uri + '/lsp/server-applied.txt'\n" +
        "        send({'jsonrpc': '2.0', 'id': 'server-edit', " + "'method': 'workspace/applyEdit', 'params': {'edit': {" +
        "'documentChanges': [" + "{'kind': 'create', 'uri': target}, " +
        "{'textDocument': {'uri': target, 'version': None}, " +
        "'edits': [{'range': {'start': {'line': 0, 'character': 0}, " + "'end': {'line': 0, 'character': 0}}, " +
        "'newText': 'from server request\\n'}]}]}}})\n" + "        applied = receive()\n" +
        "        result = applied.get('result')\n" + "    elif method == 'textDocument/hover':\n" +
        "        target = root_uri + '/lsp/forbidden-server-edit.txt'\n" +
        "        send({'jsonrpc': '2.0', 'id': 'readonly-edit', " +
        "'method': 'workspace/applyEdit', 'params': {'edit': {" + "'documentChanges': [" +
        "{'kind': 'create', 'uri': target}]}}})\n" + "        applied = receive()\n" + "        result = {'contents': " +
        "'applied=' + str(applied['result']['applied'])}\n" + "    elif method == 'shutdown':\n" +
        "        result = None\n" + "    else:\n" + "        result = None\n" + "    if 'id' in message:\n" +
        "        send({'jsonrpc': '2.0', 'id': message['id'], " + "'result': result})\n")
}

func conversationContains(
    messages: Array<ModelMessage>,
    text: String
): Bool {
    for (message in messages) {
        for (block in message.blocks where block.text.contains(text)) {
            return true
        }
    }
    false
}

func subagentSlashCommandsVisible(application: ApplicationSession): Bool {
    let agentList = application.handle("/agents").value().getOrThrow()
    let agentTranscript = application.handle("/agent fixture-child").value().getOrThrow()
    !agentList.agentInvoked && agentList.text.contains("fixture-child") && agentList.text.contains("session=") &&
        !agentTranscript.agentInvoked && agentTranscript.text.contains("Tool Call: yield")
}

func approvalFrom(result: Result<ToolInvocationResult>): ApprovalRequest {
    match (result) {
        case Result.Ok(ToolInvocationResult.NeedsApproval(value)) => value
        case Result.Ok(_) => throw IllegalStateException("expected approval request")
        case Result.Err(error) => throw IllegalStateException(error.message)
    }
}

func completedFrom(result: Result<ToolInvocationResult>): ToolResult {
    match (result) {
        case Result.Ok(ToolInvocationResult.Completed(value)) => value
        case Result.Ok(_) => throw IllegalStateException("expected completed tool")
        case Result.Err(error) => throw IllegalStateException(error.message)
    }
}

func contractValue<T>(result: Result<T>, label: String): T {
    match (result) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(
            label + " failed: " + error.describe()
        )
    }
}

func toolOutcomeFailed(result: Result<ToolInvocationResult>): Bool {
    match (result) {
        case Result.Ok(ToolInvocationResult.Completed(value)) => value.isError
        case Result.Ok(ToolInvocationResult.Denied(_)) => true
        case Result.Ok(_) => false
        case Result.Err(_) => true
    }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) {
        throw IllegalStateException(message)
    }
}

func rejectsIllegalArgument(action: () -> Unit): Bool {
    try {
        action()
        false
    } catch (_: IllegalArgumentException) {
        true
    }
}
