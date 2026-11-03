package github_contract

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_ports.*
import agent_product.*
import agent_store.*
import agent_runtime.*
import agent_testkit.*
import std.collection.*
import std.fs.*
import tool_runtime.*

main(): Int64 {
    if (!exists(Path("target"))) {
        Directory.create("target", recursive: true)
    }
    let root = Directory.createTemp("target").toString()
    try {
        verifySchema(root)
        verifyLegacyCommandMapping(root)
        println("legacy GitHub schema/argv oracle and actual absent-default contract passed")
        println("github contract passed")
        0
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

func verifySchema(root: String): Unit {
    verifyRetiredProductDefault(root)
    // The original schema union is a historical oracle, not a live registration.
    let definition = legacyGithubToolDefinition()
    expect(
        sameStringSet(propertyNames(definition.inputSchema), [
            "op", "repo", "branch", "path", "pr", "force",
            "forceWithLease", "title", "body", "base", "head",
            "draft", "fill", "reviewer", "assignee", "label",
            "query", "since", "until", "dateField", "limit", "run",
            "tail"
        ]) &&
        sameStringSet(requiredNames(definition.inputSchema), ["op"]) &&
        sameStringSet(enumNames(
            definition.inputSchema.field("properties").getOrThrow()
                .field("op").getOrThrow()
        ), [
            "repo_view", "file_read", "pr_create", "pr_checkout",
            "pr_push", "search_issues", "search_prs", "search_code",
            "search_commits", "search_repos", "run_watch"
        ]),
        "github exposes the reviewed root schema and operation union"
    )
    let pr = definition.inputSchema.field("properties").getOrThrow()
        .field("pr").getOrThrow()
    expect(
        pr.field("anyOf").getOrThrow().items.size == 2,
        "github pr accepts one string or a string list"
    )
}

func verifyLegacyCommandMapping(root: String): Unit {
    let workspace = LocalWorkspace(root)
    let processes = RecordingGithubProcessPort()
    let runtime = LegacyGithubRuntime(
        processes,
        ghExecutable: "/bin/echo",
        gitExecutable: "/bin/echo"
    )
    let context = ToolInvocationContext(
        RunId("github-run"),
        SessionId("github-session"),
        CapabilitySet(values: [
            Capability(CapabilityKind.NetworkAccess),
            Capability(CapabilityKind.WorkspaceWrite)
        ])
    )
    let viewed = invoke(runtime, context, call(
        "view",
        "repo_view",
        [
            ValueField("repo", textValue("acme/demo")),
            ValueField("branch", textValue("main"))
        ]
    ))
    expect(
        viewed.output.field("content").getOrThrow().text
            .startsWith("repo view acme/demo --branch main --json "),
        "repo_view executes the real gh repo view command"
    )
    let read = invoke(runtime, context, call(
        "read",
        "file_read",
        [
            ValueField("repo", textValue("acme/demo")),
            ValueField("branch", textValue("main")),
            ValueField("path", textValue("docs/guide.md"))
        ]
    ))
    expect(
        read.output.field("content").getOrThrow().text ==
            "api repos/acme/demo/contents/docs/guide.md?ref=main " +
                "-H Accept: application/vnd.github.raw+json",
        "file_read uses the GitHub contents API with a raw media type"
    )
    let created = invoke(runtime, context, call(
        "create",
        "pr_create",
        [
            ValueField("repo", textValue("acme/demo")),
            ValueField("title", textValue("Ship it")),
            ValueField("body", textValue("Validated")),
            ValueField("base", textValue("main")),
            ValueField("head", textValue("feature")),
            ValueField("draft", boolValue(true)),
            ValueField("reviewer", listValue([
                textValue("alice"), textValue("bob")
            ]))
        ]
    ))
    let createText = created.output.field("content").getOrThrow().text
    expect(
        createText.contains("pr create") &&
        createText.contains("--repo acme/demo") &&
        createText.contains("--title Ship it") &&
        createText.contains("--draft") &&
        createText.contains("--reviewer alice") &&
        createText.contains("--reviewer bob"),
        "pr_create maps all side-effecting options to gh"
    )
    let checkouts = invoke(runtime, context, ToolCall(
        "checkout",
        "github",
        objectValue([
            ValueField("op", textValue("pr_checkout")),
            ValueField("repo", textValue("acme/demo")),
            ValueField("pr", listValue([
                textValue("12"), textValue("feature")
            ])),
            ValueField("force", boolValue(true))
        ])
    ))
    expect(
        checkouts.output.field("targets").getOrThrow().items.size == 2 &&
        checkouts.output.field("content").getOrThrow().text
            .contains("pr checkout 12 --repo acme/demo --force") &&
        checkouts.output.field("content").getOrThrow().text
            .contains("pr checkout feature --repo acme/demo --force"),
        "pr_checkout executes every requested PR target"
    )
    let pushed = invoke(runtime, context, call(
        "push",
        "pr_push",
        [
            ValueField("branch", textValue("feature")),
            ValueField("forceWithLease", boolValue(true))
        ]
    ))
    expect(
        pushed.output.field("content").getOrThrow().text ==
            "-c credential.helper=!/bin/echo auth git-credential push " +
                "--force-with-lease --set-upstream origin feature",
        "pr_push uses git push with explicit force-with-lease"
    )
    let searched = invoke(runtime, context, call(
        "search",
        "search_issues",
        [
            ValueField("repo", textValue("acme/demo")),
            ValueField("query", textValue("bug")),
            ValueField("since", textValue("2026-01-01")),
            ValueField("until", textValue("2026-07-31")),
            ValueField("dateField", textValue("updated")),
            ValueField("limit", integerValue(5))
        ]
    ))
    let searchText = searched.output.field("content").getOrThrow().text
    expect(
        searchText.contains(
            "search issues bug updated:>=2026-01-01 " +
                "updated:<=2026-07-31"
        ) &&
        searchText.contains("--repo acme/demo --limit 5 --json"),
        "GitHub search applies repository, date and result bounds"
    )
    let watched = invoke(runtime, context, call(
        "watch",
        "run_watch",
        [
            ValueField("repo", textValue("acme/demo")),
            ValueField("run", textValue("123"))
        ]
    ))
    expect(
        watched.output.field("content").getOrThrow().text ==
            "run watch 123 --exit-status --repo acme/demo",
        "run_watch invokes the blocking Actions watch command"
    )
    expect(
        invocationFailed(
            runtime,
            context,
            call(
                "escape",
                "file_read",
                [
                    ValueField("repo", textValue("acme/demo")),
                    ValueField("path", textValue("../secret"))
                ]
            )
        ) &&
        invocationFailed(
            runtime,
            context,
            call("missing-pr", "pr_checkout", [])
        ),
        "GitHub paths and required PR targets fail closed"
    )
    expect(
        processes.requests.size > 0 &&
            requestsHaveNetwork(processes.requests.toArray()) &&
            requestMode(processes.requests.toArray(), "github-checkout") ==
                ProcessSandboxMode.WorkspaceReadWrite &&
            requestMode(processes.requests.toArray(), "github-push") ==
                ProcessSandboxMode.WorkspaceReadWrite &&
            requestMode(processes.requests.toArray(), "github-view") ==
                ProcessSandboxMode.WorkspaceReadOnly &&
            requestsScopeGithubSecrets(processes.requests.toArray()),
        "GitHub process requests always use network, scope auth secrets, and grant writes only to checkout/push"
    )
    let failing = LegacyGithubRuntime(
        RecordingGithubProcessPort(exitCode: 1),
        ghExecutable: "/bin/false",
        gitExecutable: "/bin/false"
    )
    expect(
        invocationFailed(
            failing,
            context,
            call("failure", "repo_view", [])
        ),
        "non-zero GitHub commands propagate a real tool failure"
    )
}

class RecordingGithubProcessPort <: ProcessPort {
    public let requests = ArrayList<ProcessRequest>()
    private let exitCode: Int64

    init(exitCode!: Int64 = 0) {
        this.exitCode = exitCode
    }

    public func execute(request: ProcessRequest): Result<ProcessResult> {
        requests.add(request)
        Result.Ok(ProcessResult(
            exitCode,
            stdout: if (exitCode == 0) {
                if (request.arguments.size >= 3 &&
                    request.arguments[request.arguments.size - 3] == "remote" &&
                    request.arguments[request.arguments.size - 2] == "get-url" &&
                    request.arguments[request.arguments.size - 1] == "origin") {
                    "https://github.com/acme/demo.git\n"
                } else {
                    joinArguments(request.arguments) + "\n"
                }
            } else {
                ""
            },
            stderr: if (exitCode == 0) { "" } else { "command failed" }
        ))
    }

    public func cancel(operationId: OperationId): Result<Unit> {
        let _ = operationId
        Result.Ok(())
    }
}

func joinArguments(arguments: Array<String>): String {
    var value = ""
    for (argument in arguments) {
        if (value != "") { value += " " }
        value += argument
    }
    value
}

func requestsHaveNetwork(requests: Array<ProcessRequest>): Bool {
    for (request in requests where networkPolicyModeIsDenied(request.networkPolicy.mode)) {
        return false
    }
    true
}

func requestMode(
    requests: Array<ProcessRequest>,
    operationId: String
): ProcessSandboxMode {
    for (request in requests where request.operationId.value == operationId) {
        return request.sandboxMode
    }
    ProcessSandboxMode.Host
}

func requestsScopeGithubSecrets(requests: Array<ProcessRequest>): Bool {
    for (request in requests) {
        if (!containsArgument(request.secretEnvironmentAllowlist, "GH_TOKEN") ||
            !containsArgument(request.secretEnvironmentAllowlist, "GITHUB_TOKEN")) {
            return false
        }
    }
    true
}

func containsArgument(values: Array<String>, expected: String): Bool {
    for (value in values where value == expected) { return true }
    false
}

func invoke(
    runtime: LegacyGithubRuntime,
    context: ToolInvocationContext,
    call: ToolCall
): ToolResult {
    invokeResult(runtime, context, call).value().getOrThrow()
}

func invocationFailed(
    runtime: LegacyGithubRuntime,
    context: ToolInvocationContext,
    call: ToolCall
): Bool {
    match (invokeResult(runtime, context, call)) {
        case Result.Err(_) => true
        case Result.Ok(result) => result.isError
    }
}

func invokeResult(
    runtime: LegacyGithubRuntime,
    context: ToolInvocationContext,
    call: ToolCall
): Result<ToolResult> {
    let catalog = ToolCatalog()
    let registration = catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "github",
                "GitHub contract fixture.",
                githubContractSchema()
            ),
            Capability(CapabilityKind.NetworkAccess),
            sideEffecting: true,
            networkPolicyResolver: Some({_value =>
                Result.Ok(githubContractNetworkPolicy(""))
            })
        ),
        GithubContractExecutor(runtime)
    )
    match (registration) {
        case Result.Err(error) => return Result.Err(error)
        case Result.Ok(_) => ()
    }
    let pipeline = ToolPipeline(
        catalog,
        InMemoryOperationRuntimePort(),
        GithubContractAudit(),
        GithubContractIds(call.callId),
        policy: DefaultCapabilityPolicy(mode: ApprovalMode.Yolo)
    )
    match (executePipelineCall(pipeline, context, call)) {
        case Result.Err(error) => Result.Err(error)
        case Result.Ok(ToolInvocationResult.Completed(result)) =>
            Result.Ok(result)
        case Result.Ok(ToolInvocationResult.NeedsApproval(_)) =>
            Result.Err(AgentError(
                AgentErrorKind.PermissionDenied,
                "github.contract_approval_required",
                "github contract fixture unexpectedly requires approval"
            ))
        case Result.Ok(ToolInvocationResult.Denied(_)) =>
            Result.Err(AgentError(
                AgentErrorKind.PermissionDenied,
                "github.contract_denied",
                "github contract fixture unexpectedly denied the operation"
            ))
    }
}

class GithubContractExecutor <: ToolExecutor {
    private let runtime: LegacyGithubRuntime

    init(runtime: LegacyGithubRuntime) {
        this.runtime = runtime
    }

    public func execute(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolResult> {
        runtime.execute(context, prepared)
    }
}

class GithubContractAudit <: AuditPort {
    public func append(event: AgentEvent): Result<Unit> {
        let _ = event
        Result.Ok(())
    }
}

class GithubContractIds <: IdGenerator {
    private let operationName: String

    init(operationName: String) {
        this.operationName = operationName
    }

    public func nextRunId(): RunId { RunId("github-contract-run") }
    public func nextSessionId(): SessionId { SessionId("github-contract-session") }
    public func nextOperationId(): OperationId {
        OperationId("github-" + operationName)
    }
}

func githubContractSchema(): AgentValue {
    objectValue([
        ValueField("type", textValue("object")),
        ValueField("required", listValue([textValue("op")]))
    ])
}

func githubContractNetworkPolicy(operation: String): NetworkPolicy {
    let _ = operation
    NetworkPolicy(
        NetworkPolicyMode.Mediated,
        egress: [
            NetworkEgressRule("api.github.com", 443u16),
            NetworkEgressRule("github.com", 443u16)
        ]
    )
}

func call(
    id: String,
    op: String,
    fields: Array<ValueField>
): ToolCall {
    let values = ArrayList<ValueField>()
    values.add(ValueField("op", textValue(op)))
    values.add(all: fields)
    ToolCall(id, "github", objectValue(values.toArray()))
}

func toolDefinition(
    product: ProductRuntime,
    name: String
): ModelToolDefinition {
    for (definition in product.tools() where definition.name == name) {
        return definition
    }
    throw IllegalStateException("missing product tool: " + name)
}

func propertyNames(schema: AgentValue): Array<String> {
    let names = ArrayList<String>()
    for (field in schema.field("properties").getOrThrow().fields) {
        names.add(field.name)
    }
    names.toArray()
}

func requiredNames(schema: AgentValue): Array<String> {
    let names = ArrayList<String>()
    for (value in schema.field("required").getOrThrow().items) {
        names.add(value.text)
    }
    names.toArray()
}

func enumNames(schema: AgentValue): Array<String> {
    let names = ArrayList<String>()
    for (value in schema.field("enum").getOrThrow().items) {
        names.add(value.text)
    }
    names.toArray()
}

func sameStringSet(left: Array<String>, right: Array<String>): Bool {
    if (left.size != right.size) { return false }
    for (candidate in left) {
        var found = false
        for (expected in right) {
            if (candidate == expected) { found = true; break }
        }
        if (!found) { return false }
    }
    true
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}

// A real Product with fresh settings has no GitHub executor or package. The
// ordinary missing-tool route keeps its existing durable canonical failure.
func verifyRetiredProductDefault(root: String): Unit {
    let product = openProduct(config: ProductConfig(
        settingsRoot: root + "/settings", stateRoot: root + "/state", workspaceRoot: root,
        fixture: true, approvalMode: ApprovalMode.Yolo, asyncEnabled: false
    )).value().getOrThrow()
    try {
        for (definition in product.tools()) {
            expect(definition.name != "github" &&
                !definition.name.startsWith("plugin.axyndra:github.service."),
                "GitHub business tools require an installed and started native service")
        }
        let missing = product.vnext.executeCanonicalTool(SessionId("github-contract-missing"),
            CapabilitySet(values: [Capability(CapabilityKind.NetworkAccess),
                Capability(CapabilityKind.WorkspaceWrite)]),
            ToolCall("missing-github", "github", objectValue([ValueField("op", textValue("repo_view"))])))
        let result = match (missing.value().getOrThrow()) {
            case ToolInvocationResult.Completed(value) => value
            case _ => throw IllegalStateException("missing GitHub must retain the original canonical failure")
        }
        expect(result.isError && result.output.field("error").getOrThrow().text == "tool.not_found",
            "missing GitHub uses the real canonical rejection")
        let missingService = product.startPluginService(SessionId("github-service-missing"),
            "axyndra:github", "stdio", "session", approvalDecision: ApprovalDecision.Approve,
            budget: ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1))
        expect(missingService.isError() && missingService.error().getOrThrow().code == "plugin.not_found",
            "a missing package cannot manufacture a service origin")
        let database = SqliteDatabase(root + "/state/state.db")
        try {
            expect(database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='github-contract-missing' AND state='failed'") == 1,
                "missing GitHub persists exactly one failed Run")
            expect(database.scalarInt("SELECT COUNT(*) FROM items WHERE thread_id='github-contract-missing' AND kind='user_message'") == 1,
                "missing GitHub persists the real user request")
            expect(database.scalarInt("SELECT COUNT(*) FROM items WHERE thread_id='github-contract-missing' AND kind='tool_call'") == 0,
                "unknown GitHub does not mint a ToolCall")
            expect(database.scalarInt("SELECT COUNT(*) FROM operations operation JOIN runs run ON run.id=operation.run_id WHERE run.thread_id='github-contract-missing'") == 0,
                "unknown GitHub does not acquire an Operation")
            expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts receipt JOIN operations operation ON operation.id=receipt.operation_id JOIN runs run ON run.id=operation.run_id WHERE run.thread_id='github-contract-missing'") == 0,
                "unknown GitHub does not mint a Receipt")
            expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE thread_id='github-contract-missing' AND kind='operation_execution_handoff'") == 0,
                "unknown GitHub never crosses a native handoff")
            expect(database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='github-service-missing'") == 0,
                "missing package rejection does not create an authorized service Run")
        } finally { database.close() }
    } finally { expect(product.close().isOk(), "actual Product owner must acknowledge cleanup") }
}
