package agent_product

import agent_domain.*
import agent_extensions.*
import agent_ports.*
import agent_sdk.*
import agent_extension_runtime.*
import agent_store.*
import persistence_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.sync.*
import workspace_search_extension.*
import workspace_write_extension.*
import ast_extension.*
import web_search_extension.*

public func installLocalTools(
    catalog: ToolCatalog,
    workspace: LocalWorkspace,
    processes: LocalProcessPort,
    uriRouter!: InternalUriRouter = InternalUriRouter(),
    todoRepository!: ?SessionMetadataRepository = None,
    taskRuntime!: ?ProductTaskRuntime = None,
    checkpointDatabase!: ?SqliteDatabase = None,
    askRuntime!: AskRuntime = AskRuntime(),
    goalRuntime!: ?ProductGoalRuntime = None,
    memoryRuntime!: ?ProductMemoryRuntime = None,
    skillRuntime!: ?ProductSkillRuntime = None,
    webSearchRuntime!: ?ProductWebSearchRuntime = None,
    artifactStore!: ?ProductArtifactStore = None,
    allowUnsafeDirectLaunchForTests!: Bool = false
): Result<Unit> {
    let astEdits = AstEditRuntime(workspace, processes)
    let extensions = ExtensionInstaller(
        ProductExtensionOperationHost(
            workspace, processes, uriRouter, astEdits,
            webSearchRuntime: webSearchRuntime
        )
    )
    let extensionRuntime = ExtensionRuntime(
        ProductExtensionLifecycleHost(extensions, catalog)
    )
    // Built-in SDK extensions participate in the same deterministic runtime
    // lifecycle as external compiled providers. Register them before the
    // remaining product-local tools so the public catalogue keeps its
    // established extension-first order.
    match (startBuiltInExtensionRuntime(extensionRuntime, webSearchRuntime.isSome())) {
        case ExtensionRuntimeResult.Ok(_) => ()
        case ExtensionRuntimeResult.Err(error) => return Result.Err(extensionRuntimeAgentError(error))
    }
    match (installLocalToolsWithExtensions(
        catalog,
        workspace,
        processes,
        extensions,
        uriRouter: uriRouter,
        todoRepository: todoRepository,
        taskRuntime: taskRuntime,
        checkpointDatabase: checkpointDatabase,
        askRuntime: askRuntime,
        goalRuntime: goalRuntime,
        memoryRuntime: memoryRuntime,
        skillRuntime: skillRuntime,
        artifactStore: artifactStore,
        allowUnsafeDirectLaunchForTests: allowUnsafeDirectLaunchForTests
    )) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    Result.Ok(())
}

func installLocalToolsWithExtensions(
    catalog: ToolCatalog,
    workspace: LocalWorkspace,
    processes: LocalProcessPort,
    extensions: ExtensionInstaller,
    uriRouter!: InternalUriRouter = InternalUriRouter(),
    todoRepository!: ?SessionMetadataRepository = None,
    taskRuntime!: ?ProductTaskRuntime = None,
    checkpointDatabase!: ?SqliteDatabase = None,
    askRuntime!: AskRuntime = AskRuntime(),
    goalRuntime!: ?ProductGoalRuntime = None,
    memoryRuntime!: ?ProductMemoryRuntime = None,
    skillRuntime!: ?ProductSkillRuntime = None,
    artifactStore!: ?ProductArtifactStore = None,
    allowUnsafeDirectLaunchForTests!: Bool = false
): Result<Unit> {
    match (installRequiredToolGroups(
        catalog,
        workspace,
        processes,
        extensions,
        uriRouter,
        taskRuntime,
        checkpointDatabase,
        askRuntime,
        artifactStore,
        allowUnsafeDirectLaunchForTests
    )) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (registerPlanTool(catalog)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    installOptionalToolGroups(
        catalog,
        todoRepository,
        taskRuntime,
        goalRuntime,
        memoryRuntime,
        skillRuntime
    )
}

func installRequiredToolGroups(
    catalog: ToolCatalog,
    workspace: LocalWorkspace,
    processes: LocalProcessPort,
    extensions: ExtensionInstaller,
    uriRouter: InternalUriRouter,
    taskRuntime: ?ProductTaskRuntime,
    checkpointDatabase: ?SqliteDatabase,
    askRuntime: AskRuntime,
    artifactStore: ?ProductArtifactStore,
    allowUnsafeDirectLaunchForTests: Bool
): Result<Unit> {
    match (installWorkspaceTools(
        catalog,
        workspace,
        processes,
        extensions,
        uriRouter,
        askRuntime,
        artifactStore
    )) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (installProcessTools(
        catalog,
        workspace,
        processes,
        extensions,
        taskRuntime,
        artifactStore
    )) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (installCheckpointTools(catalog, checkpointDatabase)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (installLspTools(
        catalog,
        workspace,
        sandboxEnabled: processes.sandboxEnabled(),
        allowUnsafeTestBypass: allowUnsafeDirectLaunchForTests
    )) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    installDebugTools(
        catalog,
        workspace,
        sandboxEnabled: processes.sandboxEnabled(),
        allowUnsafeTestBypass: allowUnsafeDirectLaunchForTests
    )
}

func installOptionalToolGroups(
    catalog: ToolCatalog,
    todoRepository: ?SessionMetadataRepository,
    taskRuntime: ?ProductTaskRuntime,
    goalRuntime: ?ProductGoalRuntime,
    memoryRuntime: ?ProductMemoryRuntime,
    skillRuntime: ?ProductSkillRuntime
): Result<Unit> {
    match (installGoalTools(catalog, goalRuntime)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (installMemoryTools(catalog, memoryRuntime)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (skillRuntime) {
        case Some(runtime) => match (registerSkillReferenceTool(catalog, runtime)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        case None => ()
    }
    match (installTodoTools(catalog, todoRepository)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    installTaskTools(catalog, taskRuntime)
}

func installWorkspaceTools(
    catalog: ToolCatalog,
    workspace: LocalWorkspace,
    processes: LocalProcessPort,
    extensions: ExtensionInstaller,
    uriRouter: InternalUriRouter,
    askRuntime: AskRuntime,
    artifactStore: ?ProductArtifactStore
): Result<Unit> {
    let _ = extensions
    match (registerAskTool(catalog, askRuntime)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (registerReadTool(catalog, workspace, uriRouter, artifactStore)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (registerGithubTool(catalog, processes)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    registerEditTool(catalog, workspace)
}

func registerPlanTool(catalog: ToolCatalog): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "plan_write",
                "Write the complete implementation plan for review. Call once in plan mode " +
                    "when the plan is finished. The plan must contain: Goal, Constraints, " +
                    "Approach (ordered steps naming files and symbols), Acceptance criteria " +
                    "(observable outcomes), Unresolved decisions.",
                objectSchema([schemaProperty("content", "string")], ["content"])
            ),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        PlanWriteTool()
    )
}

class PlanWriteTool <: ToolExecutor {
    public func execute(
        _: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let content = match (call.arguments.field("content")) {
            case Some(value) => value.text.trimAscii()
            case None => ""
        }
        if (content == "") {
            return Result.Err(
                AgentError(
                    AgentErrorKind.InvalidInput,
                    "plan_write.empty",
                    "plan_write requires a non-empty content field"
                )
            )
        }
        Result.Ok(
            ToolResult(
                call.callId,
                textValue("Plan recorded for review. The user reviews it via /plan-review before execution.")
            )
        )
    }
}

func registerAskTool(
    catalog: ToolCatalog,
    askRuntime: AskRuntime
): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "ask",
                "Ask the user one or more interactive questions. Answers provide information only; they cannot " +
                    "grant capabilities, change work mode, or approve a plan.",
                objectSchema([schemaAskQuestionsProperty()], ["questions"])
            ),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        AskTool(askRuntime)
    )
}

func registerReadTool(
    catalog: ToolCatalog,
    workspace: LocalWorkspace,
    uriRouter: InternalUriRouter,
    artifactStore: ?ProductArtifactStore
): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "read",
                "Read a UTF-8 file using hashline anchors, or page through a blob:sha256 artifact using byte offsets.",
                objectSchema(
                    [
                        schemaProperty("path", "string"),
                        schemaNullableNumberProperty("offset"),
                        schemaNullableNumberProperty("limit"),
                        schemaProperty("destination", "string")
                    ],
                    ["path"]
                )
            ),
            Capability(CapabilityKind.WorkspaceRead),
            capabilityResolver: {call => readCapabilityFor(workspace, uriRouter, call)},
            sideEffectResolver: {call => readRequiresApprovalFor(workspace, uriRouter, call)},
            approvalMetadataResolver: {call => readApprovalMetadataFor(workspace, uriRouter, call)}
        ),
        ReadTool(workspace, uriRouter, artifactStore)
    )
}

func registerGithubTool(
    catalog: ToolCatalog,
    processes: LocalProcessPort
): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            githubToolDefinition(),
            Capability(CapabilityKind.NetworkAccess),
            sideEffecting: true,
            capabilityResolver: githubCapabilityFor,
            additionalCapabilityResolver: githubAdditionalCapabilities,
            sideEffectResolver: githubSideEffecting
        ),
        GithubTool(ProductGithubRuntime(processes))
    )
}

func registerEditTool(
    catalog: ToolCatalog,
    workspace: LocalWorkspace
): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "edit",
                "Apply an atomic hashline patch after approval. Start with the exact [path#TAG] " +
                    "header returned by read; use SWAP N or SWAP N..=M followed by + replacement " +
                    "lines, DEL N or DEL N..=M, or INS.HEAD/INS.TAIL/INS.PRE N/INS.POST N followed " +
                    "by + inserted lines. Unified-diff @@ syntax is not accepted.",
                objectSchema([schemaProperty("input", "string")], ["input"])
            ),
            Capability(CapabilityKind.WorkspaceWrite),
            sideEffecting: true,
            capabilityResolver: {call => editCapabilityFor(workspace, call)},
            approvalMetadataResolver: {call => editApprovalMetadataFor(workspace, call)}
        ),
        HashlineEditTool(workspace)
    )
}

func installProcessTools(
    catalog: ToolCatalog,
    workspace: LocalWorkspace,
    processes: LocalProcessPort,
    extensions: ExtensionInstaller,
    taskRuntime: ?ProductTaskRuntime,
    artifactStore: ?ProductArtifactStore
): Result<Unit> {
    let _ = extensions
    match (registerGlobTool(catalog, processes)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (registerBashTool(catalog, workspace, processes, taskRuntime, artifactStore)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (registerBashReadonlyTool(catalog, workspace, processes, artifactStore)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    registerEvalTool(catalog, processes, artifactStore)
}

class ProductExtensionLifecycleHost <: ExtensionLifecycleHost {
    private let installer: ExtensionInstaller
    private let catalog: ToolCatalog

    init(installer: ExtensionInstaller, catalog: ToolCatalog) {
        this.installer = installer
        this.catalog = catalog
    }

    public func activate(extension: Extension, source: String): HostLifecycleResult {
        var installed = false
        for (snapshot in installer.snapshots() where snapshot.id == extension.metadata().id) {
            installed = true
        }
        let result = if (installed) {
            installer.setEnabled(extension.metadata().id, true, catalog)
        } else {
            installer.install(extension, catalog, source: source)
        }
        match (result) {
            case Result.Ok(_) => HostLifecycleResult.Ok
            case Result.Err(error) => HostLifecycleResult.Err(error.code, error.message)
        }
    }

    public func deactivate(extensionId: String): HostLifecycleResult {
        match (installer.setEnabled(extensionId, false, catalog)) {
            case Result.Ok(_) => HostLifecycleResult.Ok
            case Result.Err(error) => HostLifecycleResult.Err(error.code, error.message)
        }
    }
}

func startBuiltInExtensionRuntime(
    runtime: ExtensionRuntime,
    webSearchEnabled: Bool
): ExtensionRuntimeResult<Unit> {
    runtime.start(
        [
            CompiledExtensionProvider(
                "axyndra.workspace-search",
                "embedded:first-party/workspace-search",
                workspaceSearchExtensionManifest(),
                { => WorkspaceSearchExtension() }
            ),
            CompiledExtensionProvider(
                "axyndra.workspace-write",
                "embedded:first-party/workspace-write",
                workspaceWriteExtensionManifest(),
                { => WorkspaceWriteExtension() }
            ),
            CompiledExtensionProvider(
                "axyndra.ast",
                "embedded:first-party/ast",
                astExtensionManifest(),
                { => AstExtension() }
            ),
            CompiledExtensionProvider(
                "axyndra.web-search",
                "embedded:first-party/web-search",
                webSearchExtensionManifest(),
                { => WebSearchExtension() }
            )
        ],
        [
            ConfiguredExtension("axyndra.workspace-search", required: true),
            ConfiguredExtension("axyndra.workspace-write", required: true),
            ConfiguredExtension("axyndra.ast", required: false),
            ConfiguredExtension("axyndra.web-search", enabled: webSearchEnabled, required: false)
        ]
    )
}

func extensionRuntimeAgentError(error: ExtensionRuntimeError): AgentError {
    AgentError(
        AgentErrorKind.Configuration,
        "extension_runtime." + extensionRuntimeErrorKindCode(error.kind),
        error.message,
        fields: [
            ErrorField("extension", error.extensionId),
            ErrorField("source", error.source),
            ErrorField("field", error.field)
        ]
    )
}

// Product-side authority implementation for the two SDK dogfood intents.
// It is invoked only by SdkToolExecutor after ToolPipeline authorization.
class ProductExtensionOperationHost <: ExtensionOperationHost {
    private let workspace: LocalWorkspace
    private let grep: GrepTool
    private let write: WriteTool
    private let astGrep: AstGrepTool
    private let astEdit: AstEditTool
    private let webSearch: ?WebSearchTool

    init(
        workspace: LocalWorkspace,
        processes: LocalProcessPort,
        uriRouter: InternalUriRouter,
        astEdits: AstEditRuntime,
        webSearchRuntime!: ?ProductWebSearchRuntime = None
    ) {
        this.workspace = workspace
        this.grep = GrepTool(workspace, processes)
        this.write = WriteTool(workspace, uriRouter, astEdits)
        this.astGrep = AstGrepTool(workspace, processes)
        this.astEdit = AstEditTool(astEdits)
        this.webSearch = match (webSearchRuntime) {
            case Some(value) => Some(WebSearchTool(value))
            case None => None
        }
    }

    public func resolveCapability(
        requirement: CapabilityRequirement,
        input: AgentValue
    ): Capability {
        if (requirement.name == "workspace.write") {
            return workspace.writeCapability(sdkInputText(input, "path"))
        }
        if (requirement.name == "workspace.read") {
            return Capability(CapabilityKind.WorkspaceRead)
        }
        if (requirement.name == "network.http") {
            return Capability(CapabilityKind.NetworkAccess)
        }
        Capability(CapabilityKind.ExtensionInvoke, resource: requirement.name)
    }

    public func approvalMetadata(
        requirement: CapabilityRequirement,
        input: AgentValue
    ): ToolApprovalMetadata {
        if (requirement.name == "workspace.write") {
            return workspace.writeApprovalMetadata(
                sdkInputText(input, "path"),
                sdkInputText(input, "content")
            )
        }
        defaultToolApprovalMetadata(resolveCapability(requirement, input))
    }

    public func execute(
        context: ToolInvocationContext,
        intent: OperationIntent
    ): Result<ExecutionResult> {
        let result = match (intent) {
            case OperationIntent.WorkspaceSearch(value) => grep.execute(
                context,
                ToolCall("sdk-workspace-search", "grep", objectValue([
                    ValueField("pattern", textValue(value.pattern)),
                    ValueField("path", textValue(value.path)),
                    ValueField("case", boolValue(value.caseSensitive)),
                    ValueField("gitignore", boolValue(value.respectGitignore)),
                    ValueField("skip", integerValue(value.skip)),
                    ValueField("count", boolValue(value.countOnly))
                ]))
            )
            case OperationIntent.WorkspaceWrite(value) => write.execute(
                context,
                ToolCall("sdk-workspace-write", "write", objectValue([
                    ValueField("path", textValue(value.path)),
                    ValueField("content", textValue(value.content))
                ]))
            )
            case OperationIntent.HostOperation(value) => match (value.operation) {
                case "ast_grep" => astGrep.execute(context, ToolCall(
                    "sdk-ast-grep", "ast_grep", value.input
                ))
                case "ast_edit" => astEdit.execute(context, ToolCall(
                    "sdk-ast-edit", "ast_edit", value.input
                ))
                case "web_search" => match (webSearch) {
                    case Some(tool) => tool.execute(context, ToolCall(
                        "sdk-web-search", "web_search", value.input
                    ))
                    case None => Result<ToolResult>.Err(AgentError(
                        AgentErrorKind.Configuration,
                        "extension.web_search_unavailable",
                        "web search host runtime is unavailable"
                    ))
                }
                case _ => Result<ToolResult>.Err(AgentError(
                    AgentErrorKind.Configuration,
                    "extension.operation_unknown",
                    "unknown SDK host operation: " + value.operation
                ))
            }
        }
        match (result) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(value) => Result.Ok(ExecutionResult(value.output))
        }
    }

    public func cancel(operation: String, runId: RunId): Result<Unit> {
        match (operation) {
            case "ast_grep" => astGrep.cancel(runId)
            case "ast_edit" => astEdit.cancel(runId)
            case _ => Result.Ok(())
        }
    }
}

func sdkInputText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(field) => if (field.kind == ValueKind.Text) { field.text } else { "" }
        case None => ""
    }
}

func registerGlobTool(
    catalog: ToolCatalog,
    processes: LocalProcessPort
): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "glob",
                "Find workspace paths using a glob pattern passed in `pattern`; " +
                    "use \"**/*.cj\" for recursive matches.",
                objectSchema(
                    [
                        schemaProperty("pattern", "string"),
                        schemaProperty("hidden", "boolean"),
                        schemaProperty("gitignore", "boolean"),
                        schemaProperty("limit", "number")
                    ],
                    ["pattern"]
                )
            ),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        GlobTool(processes)
    )
}

func registerBashTool(
    catalog: ToolCatalog,
    workspace: LocalWorkspace,
    processes: LocalProcessPort,
    taskRuntime: ?ProductTaskRuntime,
    artifactStore: ?ProductArtifactStore
): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "bash",
                "Run a shell command inside the workspace after approval.",
                objectSchema(
                    [
                        schemaProperty("command", "string"),
                        schemaStringMapProperty("env"),
                        schemaProperty("timeout", "number"),
                        schemaProperty("cwd", "string"),
                        schemaProperty("pty", "boolean"),
                        schemaProperty("async", "boolean")
                    ],
                    ["command"]
                )
            ),
            Capability(CapabilityKind.ProcessSpawn),
            sideEffecting: true
        ),
        BashTool(
            workspace,
            processes,
            taskRuntime: taskRuntime,
            artifactStore: artifactStore
        )
    )
}

func registerBashReadonlyTool(
    catalog: ToolCatalog,
    workspace: LocalWorkspace,
    processes: LocalProcessPort,
    artifactStore: ?ProductArtifactStore
): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "bash_readonly",
                "Run a read-only shell command inside the workspace. Use for " +
                    "inspection and analysis only: counting, listing, git status, " +
                    "file stats. Commands that write, delete, move, or reach the " +
                    "network are rejected. Never ask for async or pty.",
                objectSchema(
                    [
                        schemaProperty("command", "string"),
                        schemaProperty("timeout", "number")
                    ],
                    ["command"]
                )
            ),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        BashReadonlyTool(workspace, processes, artifactStore)
    )
}

// A read-only bash surface for inspection-only analysis (plan mode). It
// rejects side-effecting shapes at the token level before delegating to the
// normal bash executor. Being conservative here is fine: a false positive
// just forces the model to phrase the command differently; a false negative
// would leak a write into a supposed read-only window.
class BashReadonlyTool <: ToolExecutor {
    private let workspace: LocalWorkspace
    private let processes: LocalProcessPort
    private let artifactStore: ?ProductArtifactStore

    init(
        workspace: LocalWorkspace,
        processes: LocalProcessPort,
        artifactStore: ?ProductArtifactStore
    ) {
        this.workspace = workspace
        this.processes = processes
        this.artifactStore = artifactStore
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let command = match (requiredString(call, "command")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (optionalBoolean(call, "async", false) || optionalBoolean(call, "pty", false)) {
            return invalidArgument(
                call,
                "command",
                "bash_readonly does not support async or pty"
            )
        }
        if (let Some(violation) <- readOnlyViolation(command)) {
            // Model-fixable: the run continues and the model sees a failed
            // tool result so it can rephrase the command (InvalidInput is
            // surfaced as a tool failure, not a run failure).
            return Result.Err(
                AgentError(
                    AgentErrorKind.InvalidInput,
                    "tool.readonly_rejected",
                    "bash_readonly only allows read-only commands: " + violation,
                    fields: [ErrorField("command", command)]
                )
            )
        }
        BashTool(
            workspace,
            processes,
            artifactStore: artifactStore,
            readOnly: true
        ).execute(context, call)
    }
}

func readOnlyViolation(command: String): ?String {
    // Side-effecting commands / operators. Token matching is deliberately
    // conservative (safe false positives over unsafe false negatives).
    let tokens = [
        "rm ",
        "mv ",
        "touch ",
        "mkdir ",
        "cp ",
        "ln ",
        "chmod ",
        "chown ",
        "tee ",
        "dd ",
        "curl ",
        "wget ",
        "nc ",
        "sudo ",
        "apt ",
        "yum ",
        "dnf ",
        "pacman ",
        "npm install",
        "npm i",
        "pip install",
        "git push",
        "git commit",
        "git checkout",
        "git reset",
        "git rm",
        "git clean",
        "cargo build",
        "cargo test",
        "cjpm build",
        "cjpm test",
        "make ",
        "kill ",
        "pkill ",
        "reboot"
    ]
    for (token in tokens) {
        if (command.contains(token)) {
            return Some("forbidden token '" + token.trimAscii() + "'")
        }
    }
    if (hasFileRedirection(command)) {
        return Some("output redirection is not read-only")
    }
    None
}

// Detect file redirections that write (or append) to a real path. Discard
// and merge shapes are read-only and allowed: `>/dev/null`, `2>/dev/null`,
// `2>&1` (stderr to stdout), and input redirection `<` (never checked).
func hasFileRedirection(command: String): Bool {
    var i: Int64 = 0
    while (i < command.size) {
        if (command[i] == b'>') {
            var j = i + 1
            while (j < command.size && command[j] == b' ') {
                j++
            }
            if (j < command.size) {
                let rest = command[j..]
                if (rest.startsWith("/dev/null")) {
                    i = j
                    continue
                }
                if (rest.startsWith("&1")) {
                    i = j
                    continue
                }
            }
            return true
        }
        i++
    }
    false
}

func registerEvalTool(
    catalog: ToolCatalog,
    processes: LocalProcessPort,
    artifactStore: ?ProductArtifactStore
): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "eval",
                "Execute one Python, JavaScript, Ruby, or Julia cell " + "in a persistent session runtime.",
                objectSchema(
                    [
                        schemaEnumProperty(
                            "language",
                            ["py", "js", "rb", "jl"]
                        ),
                        schemaProperty("code", "string"),
                        schemaProperty("title", "string"),
                        schemaProperty("timeout", "number"),
                        schemaProperty("reset", "boolean")
                    ],
                    ["language", "code"]
                )
            ),
            Capability(CapabilityKind.ProcessSpawn),
            sideEffecting: true
        ),
        EvalTool(processes, artifactStore)
    )
}

func installLspTools(
    catalog: ToolCatalog,
    workspace: LocalWorkspace,
    sandboxEnabled!: Bool = false,
    allowUnsafeTestBypass!: Bool = false
): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "lsp",
                "Query and mutate source through a real language server.",
                objectSchema(
                    [
                        schemaEnumProperty(
                            "action",
                            [
                                "diagnostics",
                                "definition",
                                "references",
                                "hover",
                                "symbols",
                                "rename",
                                "rename_file",
                                "code_actions",
                                "type_definition",
                                "implementation",
                                "status",
                                "reload",
                                "capabilities",
                                "request"
                            ]
                        ),
                        schemaProperty("file", "string"),
                        schemaProperty("line", "number"),
                        schemaProperty("symbol", "string"),
                        schemaProperty("query", "string"),
                        schemaProperty("new_name", "string"),
                        schemaProperty("apply", "boolean"),
                        schemaProperty("timeout", "number"),
                        schemaProperty("payload", "string")
                    ],
                    ["action"]
                )
            ),
            Capability(CapabilityKind.WorkspaceRead),
            sideEffecting: true,
            capabilityResolver: lspCapabilityFor,
            additionalCapabilityResolver: {
                call => lspAdditionalCapabilitiesFor(workspace, call)
            },
            sideEffectResolver: lspSideEffecting
        ),
        LspTool(
            workspace,
            LspRuntime(
                workspace,
                sandboxEnabled: sandboxEnabled,
                allowUnsafeTestBypass: allowUnsafeTestBypass
            )
        )
    )
}

func installDebugTools(
    catalog: ToolCatalog,
    workspace: LocalWorkspace,
    sandboxEnabled!: Bool = false,
    allowUnsafeTestBypass!: Bool = false
): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            debugToolDefinition(),
            Capability(CapabilityKind.WorkspaceRead),
            sideEffecting: true,
            capabilityResolver: debugCapabilityFor,
            additionalCapabilityResolver: {
                call => debugAdditionalCapabilities(workspace, call)
            },
            sideEffectResolver: debugSideEffecting
        ),
        DebugTool(DebugRuntime(
            workspace,
            sandboxEnabled: sandboxEnabled,
            allowUnsafeTestBypass: allowUnsafeTestBypass
        ))
    )
}

func installCheckpointTools(
    catalog: ToolCatalog,
    database: ?SqliteDatabase
): Result<Unit> {
    match (database) {
        case Some(value) =>
            let checkpoints = CheckpointRuntime(value)
            match (catalog.register(
                ToolDescriptor(
                    ModelToolDefinition(
                        "checkpoint",
                        "Create a context checkpoint before exploratory work.",
                        objectSchema([schemaProperty("goal", "string")], ["goal"])
                    ),
                    Capability(CapabilityKind.WorkspaceRead)
                ),
                CheckpointTool(checkpoints)
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            match (catalog.register(
                ToolDescriptor(
                    ModelToolDefinition(
                        "rewind",
                        "Replace checkpoint exploration with a concise report.",
                        objectSchema([schemaProperty("report", "string")], ["report"])
                    ),
                    Capability(CapabilityKind.WorkspaceRead)
                ),
                RewindTool(checkpoints)
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        case None => ()
    }
    Result.Ok(())
}

func installGoalTools(
    catalog: ToolCatalog,
    goalRuntime: ?ProductGoalRuntime
): Result<Unit> {
    match (goalRuntime) {
        case Some(runtime) => match (catalog.register(
            ToolDescriptor(
                goalToolDefinition(),
                Capability(CapabilityKind.WorkspaceRead)
            ),
            GoalTool(runtime)
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        case None => ()
    }
    Result.Ok(())
}

func installMemoryTools(
    catalog: ToolCatalog,
    memoryRuntime: ?ProductMemoryRuntime
): Result<Unit> {
    match (memoryRuntime) {
        case Some(runtime) => installMemoryRegistrations(catalog, runtime)
        case None => Result.Ok(())
    }
}

func installMemoryRegistrations(
    catalog: ToolCatalog,
    runtime: ProductMemoryRuntime
): Result<Unit> {
    match (registerMemoryEditTool(catalog, runtime)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (registerMemoryRetainTool(catalog, runtime)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (registerMemoryRecallTool(catalog, runtime)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (registerMemoryReflectTool(catalog, runtime)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (registerLearnTool(catalog, runtime)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    registerManageSkillTool(catalog, runtime)
}

func registerMemoryEditTool(
    catalog: ToolCatalog,
    runtime: ProductMemoryRuntime
): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            memoryEditDefinition(),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        MemoryEditTool(runtime)
    )
}

func registerMemoryRetainTool(
    catalog: ToolCatalog,
    runtime: ProductMemoryRuntime
): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            memoryRetainDefinition(),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        MemoryRetainTool(runtime)
    )
}

func registerMemoryRecallTool(
    catalog: ToolCatalog,
    runtime: ProductMemoryRuntime
): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            memoryRecallDefinition(),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        MemoryRecallTool(runtime)
    )
}

func registerMemoryReflectTool(
    catalog: ToolCatalog,
    runtime: ProductMemoryRuntime
): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            memoryReflectDefinition(),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        MemoryReflectTool(runtime)
    )
}

func registerLearnTool(
    catalog: ToolCatalog,
    runtime: ProductMemoryRuntime
): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            learnDefinition(),
            Capability(CapabilityKind.WorkspaceWrite),
            sideEffecting: true
        ),
        LearnTool(runtime)
    )
}

func registerManageSkillTool(
    catalog: ToolCatalog,
    runtime: ProductMemoryRuntime
): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            manageSkillDefinition(),
            Capability(CapabilityKind.WorkspaceWrite),
            sideEffecting: true
        ),
        ManageSkillTool(runtime)
    )
}

func installTodoTools(
    catalog: ToolCatalog,
    todoRepository: ?SessionMetadataRepository
): Result<Unit> {
    match (todoRepository) {
        case Some(repository) => match (catalog.register(
            ToolDescriptor(
                ModelToolDefinition(
                    "todo",
                    "Manage a structured todo list for this session.",
                    objectSchema(
                        [
                            schemaEnumProperty(
                                "op",
                                [
                                    "init",
                                    "start",
                                    "done",
                                    "rm",
                                    "drop",
                                    "block",
                                    "unblock",
                                    "append",
                                    "view"
                                ]
                            ),
                            todoInitListSchemaProperty(),
                            schemaProperty("task", "string"),
                            schemaProperty("phase", "string"),
                            schemaStringListProperty("items"),
                            schemaProperty("reason", "string")
                        ],
                        ["op"]
                    )
                ),
                Capability(CapabilityKind.WorkspaceRead)
            ),
            TodoTool(repository)
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        case None => ()
    }
    Result.Ok(())
}

func installTaskTools(
    catalog: ToolCatalog,
    taskRuntime: ?ProductTaskRuntime
): Result<Unit> {
    match (taskRuntime) {
        case Some(runtime) => installTaskRegistrations(catalog, runtime)
        case None => Result.Ok(())
    }
}

func installTaskRegistrations(
    catalog: ToolCatalog,
    runtime: ProductTaskRuntime
): Result<Unit> {
    match (registerProductTaskTool(catalog, runtime)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (registerProductHubTool(catalog, runtime)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    registerProductYieldTool(catalog, runtime)
}

func registerProductTaskTool(
    catalog: ToolCatalog,
    runtime: ProductTaskRuntime
): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            productTaskToolDefinition(),
            Capability(CapabilityKind.Delegate),
            sideEffecting: true
        ),
        ProductTaskTool(runtime)
    )
}

func productTaskToolDefinition(): ModelToolDefinition {
    ModelToolDefinition(
        "task",
        "Spawn typed child agents in durable child sessions. " +
            "Provide shared context and one or more task items.",
        objectSchema(
            [
                schemaProperty("context", "string"),
                taskItemsSchemaProperty()
            ],
            ["context", "tasks"]
        )
    )
}

func registerProductHubTool(
    catalog: ToolCatalog,
    runtime: ProductTaskRuntime
): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            productHubToolDefinition(),
            Capability(CapabilityKind.PeerMessage),
            capabilityResolver: Some(hubCapabilityFor),
            additionalCapabilityResolver: Some(hubAdditionalCapabilities),
            sideEffectResolver: Some(hubSideEffecting)
        ),
        ProductHubTool(runtime)
    )
}

func productHubToolDefinition(): ModelToolDefinition {
    ModelToolDefinition(
        "hub",
        "Coordinate peers, manage background jobs, and " + "supervise project processes.",
        objectSchema(
            [
                schemaEnumProperty(
                    "op",
                    [
                        "send",
                        "wait",
                        "inbox",
                        "list",
                        "jobs",
                        "cancel",
                        "start",
                        "ps",
                        "logs",
                        "stop",
                        "restart",
                        "describe"
                    ]
                ),
                schemaProperty("to", "string"),
                schemaProperty("message", "string"),
                schemaProperty("replyTo", "string"),
                schemaProperty("await", "boolean"),
                schemaProperty("from", "string"),
                schemaStringListProperty("ids"),
                schemaProperty("timeoutMs", "number"),
                schemaProperty("peek", "boolean"),
                schemaProperty("name", "string"),
                schemaProperty("application", "string"),
                schemaStringListProperty("args"),
                schemaStringMapProperty("env"),
                schemaStringMapProperty("env_from"),
                schemaStringMapProperty("secret_env"),
                schemaProperty("network", "boolean"),
                schemaProperty("cwd", "string"),
                schemaProperty("pty", "boolean"),
                schemaHubReadyProperty(),
                schemaEnumProperty(
                    "restart",
                    ["no", "on-failure", "always"]
                ),
                schemaProperty("persist", "boolean"),
                schemaProperty("detached", "boolean"),
                schemaProperty("lines", "number"),
                schemaProperty("head", "boolean"),
                schemaProperty("grep", "string"),
                schemaProperty("follow", "boolean"),
                schemaProperty("cursor", "number"),
                schemaEnumProperty("for", ["ready", "exit"]),
                schemaProperty("pattern", "string"),
                schemaProperty("text", "string"),
                schemaProperty("enter", "boolean"),
                schemaStringListProperty("keys"),
                schemaEnumProperty(
                    "signal",
                    [
                        "SIGINT",
                        "SIGTERM",
                        "SIGHUP",
                        "SIGQUIT",
                        "SIGKILL"
                    ]
                ),
                schemaProperty("timeout", "number")
            ],
            ["op"]
        )
    )
}

func registerProductYieldTool(
    catalog: ToolCatalog,
    runtime: ProductTaskRuntime
): Result<Unit> {
    catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "yield",
                "Submit structured output from a delegated child agent.",
                objectSchema(
                    [
                        schemaYieldTypeProperty(),
                        schemaYieldResultProperty()
                    ],
                    ["result"]
                )
            ),
            Capability(CapabilityKind.WorkspaceRead)
        ),
        ProductYieldTool(runtime)
    )
}

class EvalTool <: ToolExecutor {
    private let processes: LocalProcessPort
    private let artifactStore: ?ProductArtifactStore
    private let cancellationLock = Mutex()
    private let cancelledRuns = ArrayList<String>()

    init(
        processes: LocalProcessPort,
        artifactStore: ?ProductArtifactStore
    ) {
        this.processes = processes
        this.artifactStore = artifactStore
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let language = match (requiredString(call, "language")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (language != "py" && language != "js" && language != "rb" && language != "jl") {
            return invalidArgument(
                call,
                "language",
                "language must be \"py\", \"js\", \"rb\", or \"jl\""
            )
        }
        let code = match (requiredString(call, "code")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let timeoutSeconds = optionalInteger(call, "timeout", 30)
        if (timeoutSeconds < 0 || timeoutSeconds > 3600) {
            return invalidArgument(
                call,
                "timeout",
                "timeout must be between 0 and 3600 seconds"
            )
        }
        let timeoutMillis = if (timeoutSeconds == 0) {
            604800000
        } else {
            timeoutSeconds * 1000
        }
        let execution = processes.executeEval(
            context.sessionId,
            language,
            code,
            optionalBoolean(call, "reset", false),
            ProcessRequest(
                match (language) {
                    case "py" => "/usr/bin/python3"
                    case "js" => "/usr/bin/bun"
                    case "rb" => "/usr/bin/ruby"
                    case _ => "/usr/bin/julia"
                },
                operationId: evalOperationId(context.runId),
                timeoutMillis: timeoutMillis,
                sandboxMode: ProcessSandboxMode.WorkspaceReadWrite
            )
        )
        let cancelled = takeEvalCancellation(context.runId)
        let result = match (execution) {
            case Result.Ok(value) => if (cancelled) {
                EvalExecutionResult(
                    -1,
                    stderr: "eval cell cancelled",
                    transportClosed: true
                )
            } else {
                value
            }
            case Result.Err(error) => return Result.Err(error)
        }
        let captured = captureProductProcessArtifacts(
            artifactStore,
            result.stdout,
            result.stderr
        )
        let failed = result.exitCode != 0 || result.timedOut || result.transportClosed
        var text = captured.stdout.preview
        if (captured.stderr.preview != "") {
            if (text != "") {
                text += "\n"
            }
            text += captured.stderr.preview
        }
        if (text == "") {
            text = if (failed) {
                "eval cell failed without output"
            } else {
                "(no output)"
            }
        }
        Result.Ok(
            ToolResult(
                call.callId,
                objectValue(
                    [
                        ValueField("content", textValue(text)),
                        ValueField("language", textValue(language)),
                        ValueField(
                            "title",
                            textValue(optionalString(call, "title", ""))
                        ),
                        ValueField(
                            "status",
                            textValue(if (result.timedOut) {
                                "error"
                            } else if (failed) {
                                "error"
                            } else {
                                "complete"
                            })
                        ),
                        ValueField("stdout", textValue(captured.stdout.preview)),
                        ValueField("stderr", textValue(captured.stderr.preview)),
                        ValueField("stdout_bytes", integerValue(captured.stdout.bytes)),
                        ValueField("stderr_bytes", integerValue(captured.stderr.bytes)),
                        ValueField("artifacts", captured.artifactsValue()),
                        ValueField("artifact_error", captured.errorValue()),
                        ValueField("exit_code", integerValue(result.exitCode)),
                        ValueField(
                            "duration_ms",
                            integerValue(result.durationMillis)
                        ),
                        ValueField("timed_out", boolValue(result.timedOut)),
                        ValueField(
                            "truncated",
                            boolValue(captured.stdout.truncated || captured.stderr.truncated)
                        ),
                        ValueField(
                            "reset",
                            boolValue(optionalBoolean(call, "reset", false))
                        )
                    ]
                ),
                isError: failed
            )
        )
    }

    public func cancel(runId: RunId): Result<Unit> {
        markEvalCancellation(runId)
        match (processes.cancel(evalOperationId(runId))) {
            case Result.Ok(_) => Result.Ok(())
            case Result.Err(error) =>
                if (error.code == "process.operation_not_running") {
                    Result.Ok(())
                } else {
                    let _ = takeEvalCancellation(runId)
                    Result.Err(error)
                }
        }
    }

    private func markEvalCancellation(runId: RunId): Unit {
        cancellationLock.lock()
        try {
            for (value in cancelledRuns where value == runId.value) { return }
            cancelledRuns.add(runId.value)
        } finally {
            cancellationLock.unlock()
        }
    }

    private func takeEvalCancellation(runId: RunId): Bool {
        cancellationLock.lock()
        try {
            for (index in 0..cancelledRuns.size) {
                if (cancelledRuns[index] == runId.value) {
                    cancelledRuns.remove(at: index)
                    return true
                }
            }
            false
        } finally {
            cancellationLock.unlock()
        }
    }
}

class ReadTool <: ToolExecutor {
    private let workspace: LocalWorkspace
    private let uriRouter: InternalUriRouter
    private let artifactStore: ?ProductArtifactStore

    init(
        workspace: LocalWorkspace,
        uriRouter: InternalUriRouter,
        artifactStore: ?ProductArtifactStore
    ) {
        this.workspace = workspace
        this.uriRouter = uriRouter
        this.artifactStore = artifactStore
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let authoredPath = match (requiredString(call, "path")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let target = parseReadTarget(authoredPath)
        let path = target.path
        let destination = optionalString(call, "destination", "")
        if (destination != "") {
            if (!isProductArtifactReference(path)) {
                return invalidArgument(
                    call,
                    "destination",
                    "destination is only supported when path is a blob:sha256 artifact reference"
                )
            }
            let store = match (artifactStore) {
                case Some(value) => value
                case None => return Result.Err(
                    AgentError(
                        AgentErrorKind.Configuration,
                        "artifact.store_unavailable",
                        "artifact export requires an installed artifact store",
                        fields: [ErrorField("artifact", path)]
                    )
                )
            }
            return match (store.export(path, workspace, destination)) {
                case Result.Ok(value) => Result.Ok(ToolResult(call.callId, value))
                case Result.Err(error) => Result.Err(error)
            }
        }
        if (isProductArtifactReference(path)) {
            return readArtifact(call, path)
        }
        if (uriRouter.canHandle(path)) {
            return readInternalUri(context, call, target)
        }
        if (uriRouter.looksLikeUri(path)) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.InvalidInput,
                    "tool.uri_unknown",
                    "unknown URI protocol: " + path
                )
            )
        }
        let resolved = match (workspace.resolveReadTarget(
            path,
            allowDirectory: true
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (FileInfo(resolved).isDirectory()) {
            return readDirectory(call.callId, path, resolved)
        }
        let offset = if (target.hasRange) {
            target.offset
        } else {
            optionalInteger(call, "offset", 1)
        }
        let limit = if (target.hasRange) {
            target.limit
        } else {
            optionalInteger(call, "limit", 2000)
        }
        if (offset < 1) {
            return invalidArgument(
                call,
                "offset",
                "offset must be a positive line number"
            )
        }
        if (limit < 1) {
            return invalidArgument(
                call,
                "limit",
                "limit must be a positive number"
            )
        }
        // OMP clamps an over-limit request to the maximum instead of failing
        // (Math.min with DEFAULT_MAX_LINES in tools/read.ts).
        let effectiveLimit = min(limit, 10000)
        try {
            let raw = File.readFrom(resolved)
            if (looksBinary(raw)) {
                return Result.Err(
                    AgentError(
                        AgentErrorKind.InvalidInput,
                        "tool.read_binary",
                        "binary files are not supported",
                        fields: [ErrorField("path", path)]
                    )
                )
            }
            let byteLimit: Int64 = 1048576
            let content = String.fromUtf8(raw)
            let lines = content.split("\n")
            let start = min(offset - 1, lines.size)
            let end = min(lines.size, start + effectiveLimit)
            let selected = joinLines(lines[start..end])
            let selectedBytes = unsafe { selected.rawData() }
            let prefix = utf8BytePrefix(selectedBytes, byteLimit)
            let returned = String.fromUtf8(prefix)
            Result.Ok(
                ToolResult(
                    call.callId,
                    objectValue(
                        [
                            ValueField("path", textValue(path)),
                            ValueField(
                                "content",
                                textValue(if (target.raw) {
                                    returned
                                } else {
                                    formatHashlineRange(
                                        path,
                                        content,
                                        returned,
                                        start + 1
                                    )
                                })
                            ),
                            ValueField("bytes", integerValue(raw.size)),
                            ValueField(
                                "returned_bytes",
                                integerValue(prefix.size)
                            ),
                            ValueField("offset", integerValue(start + 1)),
                            ValueField(
                                "truncated",
                                boolValue(selectedBytes.size > prefix.size || end < lines.size)
                            )
                        ]
                    )
                )
            )
        } catch (error: Exception) {
            Result.Err(
                AgentError(
                    AgentErrorKind.InvalidInput,
                    "tool.read_failed",
                    error.message,
                    fields: [ErrorField("path", path)]
                )
            )
        }
    }

    public func cancel(runId: RunId): Result<Unit> {
        uriRouter.cancel(runId)
    }

    private func readArtifact(
        call: ToolCall,
        reference: String
    ): Result<ToolResult> {
        let store = match (artifactStore) {
            case Some(value) => value
            case None => return Result.Err(
                AgentError(
                    AgentErrorKind.Configuration,
                    "artifact.store_unavailable",
                    "artifact reads require an installed artifact store",
                    fields: [ErrorField("artifact", reference)]
                )
            )
        }
        let offset = optionalInteger(call, "offset", 0)
        let limit = optionalInteger(call, "limit", 1048576)
        match (store.read(reference, offset: offset, limit: limit)) {
            case Result.Ok(value) => Result.Ok(
                ToolResult(call.callId, value.value())
            )
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func readInternalUri(
        context: ToolInvocationContext,
        call: ToolCall,
        target: ReadTarget
    ): Result<ToolResult> {
        let resource = match (uriRouter.read(
            context,
            target.path
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let offset = if (target.hasRange) {
            target.offset
        } else {
            optionalInteger(call, "offset", 1)
        }
        let limit = if (target.hasRange) {
            target.limit
        } else {
            optionalInteger(call, "limit", 2000)
        }
        if (offset < 1) {
            return invalidArgument(
                call,
                "offset",
                "offset must be a positive line number"
            )
        }
        if (limit < 1) {
            return invalidArgument(
                call,
                "limit",
                "limit must be a positive number"
            )
        }
        let effectiveLimit = min(limit, 10000)
        let lines = resource.content.split("\n")
        let start = min(offset - 1, lines.size)
        let end = min(lines.size, start + effectiveLimit)
        let selected = joinLines(lines[start..end])
        let selectedBytes = unsafe { selected.rawData() }
        let prefix = utf8BytePrefix(selectedBytes, 1048576)
        let allBytes = unsafe { resource.content.rawData() }
        Result.Ok(
            ToolResult(
                call.callId,
                objectValue(
                    [
                        ValueField("path", textValue(target.path)),
                        ValueField(
                            "content",
                            textValue(String.fromUtf8(prefix))
                        ),
                        ValueField("bytes", integerValue(allBytes.size)),
                        ValueField("returned_bytes", integerValue(prefix.size)),
                        ValueField("offset", integerValue(start + 1)),
                        ValueField(
                            "truncated",
                            boolValue(selectedBytes.size > prefix.size || end < lines.size)
                        ),
                        ValueField(
                            "content_type",
                            textValue(resource.contentType)
                        ),
                        ValueField("notes", textListValue(resource.notes)),
                        ValueField("immutable", boolValue(resource.immutable))
                    ]
                )
            )
        )
    }

    private func readDirectory(
        callId: String,
        path: String,
        resolved: String
    ): Result<ToolResult> {
        try {
            let entries = ArrayList<String>()
            let entryLimit: Int64 = 2000
            var total: Int64 = 0
            for (entry in Directory.readFrom(resolved)) {
                total++
                let child = Path(resolved).join(entry.name)
                insertSorted(entries, if (FileInfo(child).isDirectory()) {
                    entry.name + "/"
                } else {
                    entry.name
                })
                if (entries.size > entryLimit) {
                    entries.remove(at: entries.size - 1)
                }
            }
            let rendered = joinLines(entries.toArray())
            let bytes = unsafe { rendered.rawData() }
            let returned = utf8BytePrefix(bytes, 1048576)
            let truncated = total > entries.size || returned.size < bytes.size
            Result.Ok(
                ToolResult(
                    callId,
                    objectValue(
                        [
                            ValueField("path", textValue(path)),
                            ValueField(
                                "entries",
                                textValue(String.fromUtf8(returned))
                            ),
                            ValueField("count", integerValue(entries.size)),
                            ValueField("total_count", integerValue(total)),
                            ValueField(
                                "returned_bytes",
                                integerValue(returned.size)
                            ),
                            ValueField("truncated", boolValue(truncated))
                        ]
                    )
                )
            )
        } catch (error: Exception) {
            Result.Err(
                AgentError(
                    AgentErrorKind.InvalidInput,
                    "tool.read_directory_failed",
                    error.message
                )
            )
        }
    }
}

class ReadTarget {
    let path: String
    let offset: Int64
    let limit: Int64
    let hasRange: Bool
    let raw: Bool

    init(
        path: String,
        offset!: Int64 = 1,
        limit!: Int64 = 2000,
        hasRange!: Bool = false,
        raw!: Bool = false
    ) {
        this.path = path
        this.offset = offset
        this.limit = limit
        this.hasRange = hasRange
        this.raw = raw
    }
}

func parseReadTarget(authored: String): ReadTarget {
    var source = authored
    var raw = false
    if (source.endsWith(":raw")) {
        source = source[..source.size - 4]
        raw = true
    }
    let separator = source.lastIndexOf(":")
    if (separator.isNone()) {
        return ReadTarget(source, raw: raw)
    }
    let index = separator.getOrThrow()
    let selector = source[index + 1..]
    let path = source[..index]
    let plus = selector.indexOf("+")
    if (plus.isSome()) {
        let split = plus.getOrThrow()
        let start = parsePositiveLine(selector[..split])
        let count = parsePositiveLine(selector[split + 1..])
        if (start > 0 && count > 0 && path != "") {
            return ReadTarget(
                path,
                offset: start,
                limit: count,
                hasRange: true,
                raw: raw
            )
        }
    }
    let dash = selector.indexOf("-")
    if (dash.isSome()) {
        let split = dash.getOrThrow()
        let start = parsePositiveLine(selector[..split])
        let end = parsePositiveLine(selector[split + 1..])
        if (start > 0 && end >= start && path != "") {
            return ReadTarget(
                path,
                offset: start,
                limit: end - start + 1,
                hasRange: true,
                raw: raw
            )
        }
    }
    let line = parsePositiveLine(selector)
    if (line > 0 && path != "") {
        return ReadTarget(
            path,
            offset: line,
            limit: 1,
            hasRange: true,
            raw: raw
        )
    }
    ReadTarget(source, raw: raw)
}

func parsePositiveLine(source: String): Int64 {
    let normalized = if (source.startsWith("L")) {
        source[1..]
    } else {
        source
    }
    try {
        let value = Int64.parse(normalized)
        if (value > 0) {
            value
        } else {
            -1
        }
    } catch (_: Exception) {
        -1
    }
}

class WriteTool <: ToolExecutor {
    private let workspace: LocalWorkspace
    private let uriRouter: InternalUriRouter
    private let astEdits: AstEditRuntime

    init(
        workspace: LocalWorkspace,
        uriRouter: InternalUriRouter,
        astEdits: AstEditRuntime
    ) {
        this.workspace = workspace
        this.uriRouter = uriRouter
        this.astEdits = astEdits
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let path = match (requiredString(call, "path")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let content = match (requiredString(call, "content")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (path == "xd://resolve") {
            return astEdits.resolve(context, call.callId, content.trimAscii())
        }
        if (path == "xd://reject") {
            return astEdits.reject(context, call.callId, content.trimAscii())
        }
        if (uriRouter.canHandle(path)) {
            return match (uriRouter.write(context, path, content)) {
                case Result.Ok(_) =>
                    let contentBytes = unsafe { content.rawData() }
                    Result.Ok(
                        ToolResult(
                            call.callId,
                            objectValue(
                                [
                                    ValueField("path", textValue(path)),
                                    ValueField(
                                        "bytes",
                                        integerValue(contentBytes.size)
                                    )
                                ]
                            )
                        )
                    )
                case Result.Err(error) => Result.Err(error)
            }
        }
        if (uriRouter.looksLikeUri(path)) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.PermissionDenied,
                    "tool.uri_unknown",
                    "unknown URI protocol: " + path
                )
            )
        }
        match (workspace.writeFile(path, content)) {
            case Result.Ok(summary) => Result.Ok(ToolResult(call.callId, summary))
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func cancel(runId: RunId): Result<Unit> {
        match (astEdits.cancel(runId)) {
            case Result.Ok(_) => uriRouter.cancel(runId)
            case Result.Err(error) => Result.Err(error)
        }
    }
}

func writeArgumentText(value: AgentValue, field: String): String {
    match (value.field(field)) {
        case Some(item) =>
            if (item.kind == ValueKind.Text) {
                item.text
            } else {
                ""
            }
        case None => ""
    }
}

func readToolPath(call: ToolCall): String {
    parseReadTarget(writeArgumentText(call.arguments, "path")).path
}

func readCapabilityFor(
    workspace: LocalWorkspace,
    uriRouter: InternalUriRouter,
    call: ToolCall
): Capability {
    let destination = readExportDestination(call)
    if (destination != "") {
        return workspace.writeCapability(destination)
    }
    let path = readToolPath(call)
    if (isProductArtifactReference(path) || uriRouter.looksLikeUri(path)) {
        return Capability(CapabilityKind.WorkspaceRead, resource: path)
    }
    workspace.readCapability(path)
}

func readRequiresApprovalFor(
    workspace: LocalWorkspace,
    uriRouter: InternalUriRouter,
    call: ToolCall
): Bool {
    if (readExportDestination(call) != "") {
        return true
    }
    let path = readToolPath(call)
    !isProductArtifactReference(path) && !uriRouter.looksLikeUri(path) && workspace.readRequiresApproval(path)
}

func readApprovalMetadataFor(
    workspace: LocalWorkspace,
    uriRouter: InternalUriRouter,
    call: ToolCall
): ToolApprovalMetadata {
    let destination = readExportDestination(call)
    if (destination != "") {
        return artifactExportApprovalMetadata(
            workspace,
            destination,
            readToolPath(call)
        )
    }
    let path = readToolPath(call)
    if (isProductArtifactReference(path) || uriRouter.looksLikeUri(path)) {
        return defaultToolApprovalMetadata(Capability(CapabilityKind.WorkspaceRead, resource: path))
    }
    workspace.readApprovalMetadata(path)
}

func readExportDestination(call: ToolCall): String {
    writeArgumentText(call.arguments, "destination")
}

func artifactExportApprovalMetadata(
    workspace: LocalWorkspace,
    destination: String,
    reference: String
): ToolApprovalMetadata {
    let base = workspace.writeApprovalMetadata(destination, "")
    let flags = ArrayList<String>()
    flags.add(all: base.assessment.flags)
    flags.add("artifact_export")
    let reasons = ArrayList<String>()
    reasons.add(all: base.assessment.reasons)
    reasons.add("The read tool will atomically write a complete artifact into the workspace")
    let level = if (base.assessment.level == ApprovalRiskLevel.Low) {
        ApprovalRiskLevel.Medium
    } else {
        base.assessment.level
    }
    let summary: ?WriteApprovalSummary = match (base.writeSummary) {
        case Some(value) => Some(
            WriteApprovalSummary(
                value.path,
                value.action,
                value.exists,
                0,
                0,
                language: value.language,
                preview: ["export " + reference],
                contentHash: reference,
                beforeBytes: value.beforeBytes
            )
        )
        case None => None
    }
    ToolApprovalMetadata(
        base.capabilityLabel,
        RiskAssessment(level, flags: flags.toArray(), reasons: reasons.toArray()),
        ApprovalGrantScope(
            base.grantScope.capability,
            pathPrefix: base.grantScope.pathPrefix,
            toolName: "read"
        ),
        writeSummary: summary
    )
}

func editCapabilityFor(workspace: LocalWorkspace, call: ToolCall): Capability {
    let paths = hashlineApprovalPaths(writeArgumentText(call.arguments, "input"))
    if (paths.isEmpty()) {
        return Capability(CapabilityKind.WorkspaceWrite)
    }
    workspace.writeCapability(paths[0])
}

func editApprovalMetadataFor(workspace: LocalWorkspace, call: ToolCall): ToolApprovalMetadata {
    let paths = hashlineApprovalPaths(writeArgumentText(call.arguments, "input"))
    if (paths.isEmpty()) {
        return ToolApprovalMetadata(
            "outside-workspace.write",
            RiskAssessment(
                ApprovalRiskLevel.High,
                flags: ["unresolved_path", "edit"],
                reasons: ["Edit target paths could not be safely resolved before approval"]
            ),
            ApprovalGrantScope("outside-workspace.write", toolName: "edit")
        )
    }
    var level = ApprovalRiskLevel.Low
    var permissionClass = "workspace.write"
    var scopePath = workspace.rootPath()
    let flags = ArrayList<String>()
    let reasons = ArrayList<String>()
    flags.add("edit")
    reasons.add("Patch modifies existing file content")
    for (path in paths) {
        let target = match (workspace.inspectWriteTarget(path)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return ToolApprovalMetadata(
                "outside-workspace.write",
                RiskAssessment(
                    ApprovalRiskLevel.High,
                    flags: ["unresolved_path", "edit"],
                    reasons: ["Edit target path could not be safely resolved: " + error.message]
                ),
                ApprovalGrantScope("outside-workspace.write", toolName: "edit")
            )
        }
        if (target.permissionClass != "workspace.write") {
            permissionClass = target.permissionClass
            scopePath = if (paths.size == 1) {
                target.realParentPath
            } else {
                ""
            }
        }
        level = higherApprovalRisk(level, target.baseRisk)
        if (target.criticalFile) {
            level = higherApprovalRisk(level, ApprovalRiskLevel.High)
            if (!containsText(flags, "critical_file")) {
                flags.add("critical_file")
            }
            if (!containsText(reasons, "Target includes a critical configuration or lock file")) {
                reasons.add("Target includes a critical configuration or lock file")
            }
        }
        if (target.sensitive) {
            level = ApprovalRiskLevel.Critical
            permissionClass = "sensitive-path.write"
            if (!containsText(flags, "sensitive_path")) {
                flags.add("sensitive_path")
            }
            if (!containsText(reasons, target.reason)) {
                reasons.add(target.reason)
            }
        } else if (target.permissionClass != "workspace.write" && !containsText(reasons, target.reason)) {
            reasons.add(target.reason)
        }
    }
    ToolApprovalMetadata(
        permissionClass,
        RiskAssessment(level, flags: flags.toArray(), reasons: reasons.toArray()),
        ApprovalGrantScope(permissionClass, pathPrefix: scopePath, toolName: "edit")
    )
}

func hashlineApprovalPaths(input: String): Array<String> {
    let paths = ArrayList<String>()
    for (line in input.replace("\r", "").split("\n")) {
        if (!line.startsWith("[") || !line.endsWith("]")) {
            continue
        }
        match (line.indexOf("#")) {
            case Some(index) =>
                if (index > 1) {
                    let path = line[1..index]
                    if (!containsText(paths, path)) {
                        paths.add(path)
                    }
                }
            case None => ()
        }
    }
    paths.toArray()
}

func containsText(values: ArrayList<String>, expected: String): Bool {
    for (value in values where value == expected) {
        return true
    }
    false
}

func textListValue(values: Array<String>): AgentValue {
    let items = ArrayList<AgentValue>()
    for (value in values) {
        items.add(textValue(value))
    }
    listValue(items.toArray())
}

class GrepTool <: ToolExecutor {
    private let workspace: LocalWorkspace
    private let processes: ProcessPort

    init(workspace: LocalWorkspace, processes: ProcessPort) {
        this.workspace = workspace
        this.processes = processes
    }

    public func execute(
        _context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let _ = _context
        let query = match (requiredString(call, "pattern")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let path = optionalString(call, "path", ".")
        let countMode = optionalBoolean(call, "count", false)
        let limit: Int64 = 1000
        let arguments = ArrayList<String>()
        arguments.add("--line-number")
        arguments.add("--no-heading")
        arguments.add("--color")
        arguments.add("never")
        arguments.add("--sort")
        arguments.add("path")
        if (countMode) {
            arguments.add("-c")
            arguments.add("--with-filename")
        }
        if (!optionalBoolean(call, "case", false)) {
            arguments.add("--ignore-case")
        }
        if (!optionalBoolean(call, "gitignore", true)) {
            arguments.add("--no-ignore")
        }
        // Glob patterns (e.g. "*.toml", "**/*.cj") become rg --glob filters
        // and must appear BEFORE the "--" separator; a literal path would
        // make rg look for a file literally named "*.toml" and fail with an
        // IO error.
        var globs = ArrayList<String>()
        var paths = ArrayList<String>()
        for (part in path.split(";")) {
            let candidate = part.trimAscii()
            if (candidate == "") {
                continue
            }
            if (hasGlobChars(candidate)) {
                globs.add(candidate)
            } else {
                match (workspace.resolve(candidate, allowDirectory: true)) {
                    case Result.Ok(_) => paths.add(candidate)
                    case Result.Err(error) => return Result.Err(error)
                }
            }
        }
        for (glob in globs) {
            arguments.add("--glob")
            arguments.add(glob)
        }
        arguments.add("--")
        arguments.add(query)
        for (candidate in paths) {
            arguments.add(candidate)
        }
        if (paths.isEmpty() && globs.isEmpty()) {
            arguments.add(".")
        }
        if (paths.isEmpty() && !globs.isEmpty()) {
            arguments.add(".")
        }
        let result = match (processes.execute(
            ProcessRequest(
                "rg",
                arguments: arguments.toArray(),
                timeoutMillis: 15000,
                sandboxMode: ProcessSandboxMode.WorkspaceReadOnly
            )
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (result.timedOut) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Timeout,
                    "tool.search_timeout",
                    "workspace search timed out"
                )
            )
        }
        if (result.exitCode != 0 && result.exitCode != 1) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Internal,
                    "tool.search_failed",
                    if (result.stderr.trimAscii() == "") {
                        "workspace search failed"
                    } else {
                        result.stderr.trimAscii()
                    }
                )
            )
        }
        let skip = optionalInteger(call, "skip", 0)
        if (skip < 0) {
            return invalidArgument(call, "skip", "skip must not be negative")
        }
        if (countMode) {
            // rg -c prints "path:count" per line; fold into per-file counts
            // and a total instead of returning matched lines.
            let files = ArrayList<AgentValue>()
            var total: Int64 = 0
            for (line in result.stdout.split("\n")) {
                if (line == "") {
                    continue
                }
                match (line.lastIndexOf(":")) {
                    case Some(separator) =>
                        if (separator > 0) {
                            let filePath = line[..separator]
                            let countText = line[separator + 1..]
                            let parsed = try {
                                Int64.parse(countText)
                            } catch (_: Exception) {
                                -1
                            }
                            if (parsed >= 0) {
                                files.add(
                                    objectValue(
                                        [
                                            ValueField("path", textValue(filePath)),
                                            ValueField("count", integerValue(parsed))
                                        ]
                                    )
                                )
                                total += parsed
                            }
                        }
                    case None => ()
                }
            }
            return Result.Ok(
                ToolResult(
                    call.callId,
                    objectValue(
                        [
                            ValueField("files", listValue(files.toArray())),
                            ValueField("total", integerValue(total)),
                            ValueField(
                                "truncated",
                                boolValue(files.size >= limit)
                            )
                        ]
                    )
                )
            )
        }
        let limited = limitLines(
            result.stdout,
            limit,
            skip: skip
        )
        Result.Ok(
            ToolResult(
                call.callId,
                objectValue(
                    [
                        ValueField("matches", textValue(limited.text)),
                        ValueField("found", boolValue(result.exitCode == 0)),
                        ValueField("count", integerValue(limited.count)),
                        ValueField("truncated", boolValue(limited.truncated))
                    ]
                )
            )
        )
    }
}

func hasGlobChars(value: String): Bool {
    for (rune in value.runes()) {
        if (rune == r'*' || rune == r'?' || rune == r'[' || rune == r']' || rune == r'{' || rune == r'}') {
            return true
        }
    }
    false
}

class GlobTool <: ToolExecutor {
    private let processes: ProcessPort
    init(processes: ProcessPort) {
        this.processes = processes
    }

    public func execute(
        _context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let _ = _context
        let patternArg = optionalString(call, "pattern", "")
        let pattern = if (patternArg != "") {
            patternArg
        } else {
            return invalidArgument(call, "pattern", "glob pattern must not be empty")
        }
        let limit = optionalInteger(call, "limit", 200)
        if (limit < 1) {
            return invalidArgument(
                call,
                "limit",
                "limit must be a positive number"
            )
        }
        // OMP clamps an over-limit request to the maximum instead of failing:
        // Math.min(MAX_LIMIT, ...) in tools/glob.ts.
        let effectiveLimit = min(limit, 200)
        let arguments = ArrayList<String>()
        arguments.add("--files")
        arguments.add("--sort")
        arguments.add("path")
        if (optionalBoolean(call, "hidden", false)) {
            arguments.add("--hidden")
        }
        if (!optionalBoolean(call, "gitignore", true)) {
            arguments.add("--no-ignore")
        }
        if (pattern != "." && pattern != "") {
            arguments.add("--glob")
            arguments.add(pattern)
        }
        let result = match (processes.execute(
            ProcessRequest(
                "rg",
                arguments: arguments.toArray(),
                timeoutMillis: 15000,
                sandboxMode: ProcessSandboxMode.WorkspaceReadOnly
            )
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (result.exitCode != 0 && result.exitCode != 1) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Internal,
                    "tool.glob_failed",
                    result.stderr
                )
            )
        }
        let values = result.stdout.split("\n")
        var output = ""
        var count: Int64 = 0
        for (value in values where value != "" && count < effectiveLimit) {
            if (output != "") {
                output += "\n"
            }
            output += value
            count += 1
        }
        Result.Ok(
            ToolResult(
                call.callId,
                objectValue(
                    [
                        ValueField("paths", textValue(output)),
                        ValueField("count", integerValue(count)),
                        ValueField("truncated", boolValue(count == effectiveLimit && values.size > effectiveLimit))
                    ]
                )
            )
        )
    }
}

class HashlineEditTool <: ToolExecutor {
    private let workspace: WorkspacePort
    init(workspace: WorkspacePort) {
        this.workspace = workspace
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let input = match (requiredString(call, "input")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let prepared = match (applyHashlineEdits(input, {
            path => match (workspace.read(WorkspaceReadRequest(path))) {
                case Result.Ok(value) => Result.Ok(value.content)
                case Result.Err(error) => Result.Err(error)
            }
        })) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let mutations = ArrayList<WorkspaceMutation>()
        for (index in 0..prepared.size) {
            let value = prepared[index]
            mutations.add(
                WorkspaceMutation(
                    OperationId("edit-" + context.runId.value + "-" + call.callId + "-" + index.toString()),
                    value.path,
                    value.expected,
                    value.replacement
                )
            )
        }
        let receipts = match (workspace.commitAll(mutations.toArray())) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let paths = ArrayList<AgentValue>()
        var changed: Int64 = 0
        for (mutation in mutations) {
            paths.add(textValue(mutation.path))
            if (mutation.expected != mutation.replacement) {
                changed += 1
            }
        }
        Result.Ok(
            ToolResult(
                call.callId,
                objectValue(
                    [
                        ValueField("paths", listValue(paths.toArray())),
                        ValueField("changed", integerValue(changed)),
                        ValueField("files", integerValue(mutations.size))
                    ]
                ),
                receiptId: receipts[0].operationId.value
            )
        )
    }
}

func bashSandboxMode(
    _processes: LocalProcessPort,
    readOnly: Bool
): ProcessSandboxMode {
    let _ = _processes
    if (readOnly) {
        ProcessSandboxMode.WorkspaceReadOnly
    } else {
        ProcessSandboxMode.WorkspaceReadWrite
    }
}

class BashTool <: ToolExecutor {
    private let workspace: LocalWorkspace
    private let processes: LocalProcessPort
    private let taskRuntime: ?ProductTaskRuntime
    private let artifactStore: ?ProductArtifactStore
    private let readOnly: Bool
    init(
        workspace: LocalWorkspace,
        processes: LocalProcessPort,
        taskRuntime!: ?ProductTaskRuntime = None,
        artifactStore!: ?ProductArtifactStore = None,
        readOnly!: Bool = false
    ) {
        this.workspace = workspace
        this.processes = processes
        this.taskRuntime = taskRuntime
        this.artifactStore = artifactStore
        this.readOnly = readOnly
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let asynchronous = optionalBoolean(call, "async", false)
        if (asynchronous && optionalBoolean(call, "pty", false)) {
            return invalidArgument(
                call,
                "async",
                "asynchronous bash jobs do not support pty"
            )
        }
        if (asynchronous) {
            let runtime = match (taskRuntime) {
                case Some(value) => value
                case None => return Result.Err(
                    AgentError(
                        AgentErrorKind.Configuration,
                        "async.runtime_unavailable",
                        "managed job runtime is not installed"
                    )
                )
            }
            let command = match (requiredString(call, "command")) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            return runtime.startBashJob(
                context,
                call,
                command,
                {
                    operationId => executeSync(context, call, operationId)
                }
            )
        }
        executeSync(
            context,
            call,
            bashOperationId(context.runId)
        )
    }

    private func executeSync(
        context: ToolInvocationContext,
        call: ToolCall,
        operationId: OperationId
    ): Result<ToolResult> {
        let command = match (requiredString(call, "command")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let timeoutSeconds = optionalInteger(call, "timeout", 60)
        if (timeoutSeconds < 0 || timeoutSeconds > 600) {
            return invalidArgument(
                call,
                "timeout",
                "timeout must be between 0 and 600 seconds"
            )
        }
        let timeoutMillis = if (timeoutSeconds == 0) {
            600000
        } else {
            timeoutSeconds * 1000
        }
        let prepared = match (prepareShellCommand(
            call,
            command,
            workspace
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let pty = optionalBoolean(call, "pty", false)
        let shellArguments = ["--noprofile", "--norc", "-lc", prepared]
        let request = if (pty) {
            ProcessRequest(
                "script",
                operationId: operationId,
                arguments: [
                    "-qefc",
                    "/bin/bash --noprofile --norc -lc " + shellQuote(prepared),
                    "/dev/null"
                ],
                timeoutMillis: timeoutMillis,
                sandboxMode: bashSandboxMode(processes, readOnly)
            )
        } else {
            ProcessRequest(
                "/bin/bash",
                operationId: operationId,
                arguments: shellArguments,
                timeoutMillis: timeoutMillis,
                sandboxMode: bashSandboxMode(processes, readOnly)
            )
        }
        let result = match (if (pty) {
            processes.execute(request)
        } else {
            processes.executeShell(context.sessionId, request)
        }) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let captured = captureProductProcessArtifacts(
            artifactStore,
            result.stdout,
            result.stderr
        )
        Result.Ok(
            ToolResult(
                call.callId,
                objectValue(
                    [
                        ValueField("exit_code", integerValue(result.exitCode)),
                        ValueField("stdout", textValue(captured.stdout.preview)),
                        ValueField("stderr", textValue(captured.stderr.preview)),
                        ValueField("stdout_bytes", integerValue(captured.stdout.bytes)),
                        ValueField("stderr_bytes", integerValue(captured.stderr.bytes)),
                        ValueField("artifacts", captured.artifactsValue()),
                        ValueField("artifact_error", captured.errorValue()),
                        ValueField("timed_out", boolValue(result.timedOut)),
                        ValueField(
                            "truncated",
                            boolValue(
                                result.truncated || captured.stdout.truncated || captured.stderr.truncated
                            )
                        ),
                        ValueField(
                            "cwd",
                            textValue(result.workingDirectory)
                        ),
                        ValueField("pty", boolValue(pty))
                    ]
                ),
                isError: result.exitCode != 0
            )
        )
    }

    public func cancel(runId: RunId): Result<Unit> {
        match (processes.cancel(bashOperationId(runId))) {
            case Result.Ok(_) => Result.Ok(())
            case Result.Err(error) =>
                if (error.code == "process.operation_not_running") {
                    Result.Ok(())
                } else {
                    Result.Err(error)
                }
        }
    }
}

func bashOperationId(runId: RunId): OperationId {
    OperationId("bash-" + runId.value)
}

func evalOperationId(runId: RunId): OperationId {
    OperationId("eval-" + runId.value)
}

func requiredString(call: ToolCall, name: String): Result<String> {
    match (call.arguments.field(name)) {
        case Some(value) =>
            if (value.kind == ValueKind.Text) {
                Result.Ok(value.text)
            } else {
                invalidArgument(call, name, "argument must be a string")
            }
        case None => invalidArgument(call, name, "required argument is missing")
    }
}

func optionalString(call: ToolCall, name: String, fallback: String): String {
    match (call.arguments.field(name)) {
        case Some(value) =>
            if (value.kind == ValueKind.Text) {
                value.text
            } else {
                fallback
            }
        case None => fallback
    }
}

func optionalInteger(call: ToolCall, name: String, fallback: Int64): Int64 {
    match (call.arguments.field(name)) {
        case Some(value) =>
            if (value.kind == ValueKind.Number) {
                try {
                    Int64.parse(value.number)
                } catch (_: Exception) {
                    fallback
                }
            } else {
                fallback
            }
        case None => fallback
    }
}

func optionalBoolean(call: ToolCall, name: String, fallback: Bool): Bool {
    match (call.arguments.field(name)) {
        case Some(value) =>
            if (value.kind == ValueKind.Boolean) {
                value.boolean
            } else {
                fallback
            }
        case None => fallback
    }
}

func prepareShellCommand(
    call: ToolCall,
    command: String,
    workspace: LocalWorkspace
): Result<String> {
    var prefix = ""
    let cwd = optionalString(call, "cwd", "")
    if (cwd != "") {
        let resolved = match (workspace.resolve(
            cwd,
            allowDirectory: true
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        prefix += "cd " + shellQuote(resolved) + " && "
    }
    match (call.arguments.field("env")) {
        case Some(value) =>
            if (value.kind != ValueKind.Object) {
                return invalidArgument(
                    call,
                    "env",
                    "env must be an object of string values"
                )
            }
            for (field in value.fields) {
                if (field.value.kind != ValueKind.Text || !validEnvironmentName(field.name)) {
                    return invalidArgument(
                        call,
                        "env",
                        "env keys and values must be valid strings"
                    )
                }
                prefix += "export " + field.name + "=" + shellQuote(field.value.text) + "; "
            }
        case None => ()
    }
    Result.Ok(prefix + command)
}

func validEnvironmentName(value: String): Bool {
    if (value == "") {
        return false
    }
    let bytes = unsafe { value.rawData() }
    for (index in 0..bytes.size) {
        let byte = bytes[index]
        let allowed = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 95 || (index > 0 && byte >= 48 &&
            byte <= 57)
        if (!allowed) {
            return false
        }
    }
    true
}

func shellQuote(value: String): String {
    "'" + value.replace("'", "'\"'\"'") + "'"
}

func invalidArgument<T>(
    call: ToolCall,
    name: String,
    message: String
): Result<T> {
    Result.Err(
        AgentError(
            AgentErrorKind.InvalidInput,
            "tool.invalid_argument",
            message,
            fields: [
                ErrorField("tool", call.name),
                ErrorField("argument", name)
            ]
        )
    )
}

func schemaProperty(name: String, kind: String): ValueField {
    ValueField(name, objectValue([ValueField("type", textValue(kind))]))
}

func schemaNullableNumberProperty(name: String): ValueField {
    ValueField(
        name,
        objectValue(
            [
                ValueField(
                    "type",
                    listValue(
                        [
                            textValue("number"),
                            textValue("null")
                        ]
                    )
                )
            ]
        )
    )
}

func schemaStringMapProperty(name: String): ValueField {
    ValueField(
        name,
        objectValue(
            [
                ValueField("type", textValue("object")),
                ValueField(
                    "additionalProperties",
                    objectValue([ValueField("type", textValue("string"))])
                )
            ]
        )
    )
}

func schemaStringListProperty(name: String): ValueField {
    ValueField(
        name,
        objectValue(
            [
                ValueField("type", textValue("array")),
                ValueField("items", objectValue([ValueField("type", textValue("string"))]))
            ]
        )
    )
}

func schemaAskQuestionsProperty(): ValueField {
    ValueField(
        "questions",
        objectValue(
            [
                ValueField("type", textValue("array")),
                ValueField("minItems", integerValue(1)),
                ValueField(
                    "items",
                    objectValue(
                        [
                            ValueField("type", textValue("object")),
                            ValueField(
                                "properties",
                                objectValue(
                                    [
                                        schemaProperty("id", "string"),
                                        schemaProperty("question", "string"),
                                        schemaProperty("header", "string"),
                                        ValueField(
                                            "options",
                                            objectValue(
                                                [
                                                    ValueField("type", textValue("array")),
                                                    ValueField(
                                                        "items",
                                                        objectValue(
                                                            [
                                                                ValueField("type", textValue("object")),
                                                                ValueField(
                                                                    "properties",
                                                                    objectValue(
                                                                        [
                                                                            schemaProperty("label", "string"),
                                                                            schemaProperty("description", "string"),
                                                                            schemaProperty("preview", "string")
                                                                        ]
                                                                    )
                                                                ),
                                                                ValueField("required", listValue([textValue("label")])),
                                                                ValueField(
                                                                    "additionalProperties",
                                                                    boolValue(false)
                                                                )
                                                            ]
                                                        )
                                                    )
                                                ]
                                            )
                                        ),
                                        schemaProperty("multi", "boolean"),
                                        schemaProperty("recommended", "number")
                                    ]
                                )
                            ),
                            ValueField(
                                "required",
                                listValue(
                                    [
                                        textValue("id"),
                                        textValue("question"),
                                        textValue("options")
                                    ]
                                )
                            ),
                            ValueField("additionalProperties", boolValue(false))
                        ]
                    )
                )
            ]
        )
    )
}

func schemaHubReadyProperty(): ValueField {
    ValueField(
        "ready",
        objectValue(
            [
                ValueField("type", textValue("object")),
                ValueField(
                    "properties",
                    objectValue(
                        [
                            schemaProperty("log", "string"),
                            schemaProperty("port", "number"),
                            schemaProperty("host", "string"),
                            schemaProperty("timeout", "number")
                        ]
                    )
                ),
                ValueField("additionalProperties", boolValue(false))
            ]
        )
    )
}

func hubCapabilityFor(call: ToolCall): Capability {
    let op = match (call.arguments.field("op")) {
        case Some(value) => value.text
        case None => ""
    }
    let processName = match (call.arguments.field("name")) {
        case Some(value) => value.text.trimAscii()
        case None => ""
    }
    match (op) {
        case "start" | "stop" | "restart" => Capability(CapabilityKind.ProcessSpawn)
        case "send" =>
            if (processName == "") {
                Capability(CapabilityKind.PeerMessage)
            } else {
                Capability(CapabilityKind.ProcessSpawn)
            }
        case "wait" | "inbox" | "list" | "jobs" | "cancel" | "ps" | "logs" | "describe" => Capability(
            CapabilityKind.WorkspaceRead)
        case _ => Capability(CapabilityKind.Delegate)
    }
}

func hubAdditionalCapabilities(call: ToolCall): Array<Capability> {
    let op = optionalString(call, "op", "")
    if ((op == "start" && optionalBoolean(call, "network", false)) ||
        op == "restart") {
        [Capability(CapabilityKind.NetworkAccess)]
    } else {
        []
    }
}

func lspCapabilityFor(call: ToolCall): Capability {
    if (lspReadOnlyAction(optionalString(call, "action", ""))) {
        Capability(CapabilityKind.WorkspaceRead)
    } else {
        Capability(CapabilityKind.WorkspaceWrite)
    }
}

func lspSideEffecting(call: ToolCall): Bool {
    !lspReadOnlyAction(optionalString(call, "action", ""))
}

func lspReadOnlyAction(action: String): Bool {
    match (action) {
        case "diagnostics" | "definition" | "type_definition" | "implementation" | "references" | "hover" | "symbols"
            | "status" | "capabilities" => true
        case _ => false
    }
}

func hubSideEffecting(call: ToolCall): Bool {
    let op = match (call.arguments.field("op")) {
        case Some(value) => value.text
        case None => ""
    }
    if (op == "start" || op == "stop" || op == "restart") {
        return true
    }
    if (op != "send") {
        return false
    }
    match (call.arguments.field("name")) {
        case Some(value) => value.text.trimAscii() != ""
        case None => false
    }
}

func schemaEnumProperty(
    name: String,
    values: Array<String>
): ValueField {
    let encoded = ArrayList<AgentValue>()
    for (value in values) {
        encoded.add(textValue(value))
    }
    ValueField(
        name,
        objectValue(
            [
                ValueField("type", textValue("string")),
                ValueField("enum", listValue(encoded.toArray()))
            ]
        )
    )
}

func schemaAnyProperty(name: String): ValueField {
    ValueField(
        name,
        objectValue(
            [
                ValueField(
                    "type",
                    listValue(
                        [
                            textValue("object"),
                            textValue("boolean"),
                            textValue("string"),
                            textValue("null")
                        ]
                    )
                )
            ]
        )
    )
}

func schemaYieldTypeProperty(): ValueField {
    ValueField(
        "type",
        objectValue(
            [
                ValueField(
                    "anyOf",
                    listValue(
                        [
                            objectValue([ValueField("type", textValue("string"))]),
                            objectValue(
                                [
                                    ValueField("type", textValue("array")),
                                    ValueField("minItems", integerValue(1)),
                                    ValueField("items", objectValue([ValueField("type", textValue("string"))]))
                                ]
                            )
                        ]
                    )
                )
            ]
        )
    )
}

func schemaYieldResultProperty(): ValueField {
    ValueField(
        "result",
        objectValue(
            [
                ValueField(
                    "anyOf",
                    listValue(
                        [
                            objectValue(
                                [
                                    ValueField("type", textValue("object")),
                                    ValueField("properties", objectValue([schemaProperty("data", "object")])),
                                    ValueField("required", listValue([textValue("data")])),
                                    ValueField(
                                        "additionalProperties",
                                        boolValue(false)
                                    )
                                ]
                            ),
                            objectValue(
                                [
                                    ValueField("type", textValue("object")),
                                    ValueField("properties", objectValue([schemaProperty("error", "string")])),
                                    ValueField("required", listValue([textValue("error")])),
                                    ValueField(
                                        "additionalProperties",
                                        boolValue(false)
                                    )
                                ]
                            ),
                            objectValue(
                                [
                                    ValueField("type", textValue("object")),
                                    ValueField("properties", objectValue([])),
                                    ValueField("required", listValue([])),
                                    ValueField(
                                        "additionalProperties",
                                        boolValue(false)
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

func todoInitListSchemaProperty(): ValueField {
    ValueField(
        "list",
        objectValue(
            [
                ValueField("type", textValue("array")),
                ValueField(
                    "items",
                    objectValue(
                        [
                            ValueField("type", textValue("object")),
                            ValueField(
                                "properties",
                                objectValue(
                                    [
                                        schemaProperty("phase", "string"),
                                        ValueField(
                                            "items",
                                            objectValue(
                                                [
                                                    ValueField("type", textValue("array")),
                                                    ValueField("items",
                                                        objectValue([ValueField("type", textValue("string"))])),
                                                    ValueField("minItems", integerValue(1))
                                                ]
                                            )
                                        )
                                    ]
                                )
                            ),
                            ValueField(
                                "required",
                                listValue(
                                    [
                                        textValue("phase"),
                                        textValue("items")
                                    ]
                                )
                            ),
                            ValueField("additionalProperties", boolValue(false))
                        ]
                    )
                )
            ]
        )
    )
}

func taskItemsSchemaProperty(): ValueField {
    ValueField(
        "tasks",
        objectValue(
            [
                ValueField("type", textValue("array")),
                ValueField(
                    "items",
                    objectValue(
                        [
                            ValueField("type", textValue("object")),
                            ValueField(
                                "properties",
                                objectValue(
                                    [
                                        schemaProperty("name", "string"),
                                        schemaProperty("agent", "string"),
                                        schemaProperty("task", "string"),
                                        schemaAnyProperty("outputSchema"),
                                        schemaEnumProperty(
                                            "schemaMode",
                                            ["permissive", "strict"]
                                        )
                                    ]
                                )
                            ),
                            ValueField("required", listValue([textValue("task")])),
                            ValueField("additionalProperties", boolValue(false))
                        ]
                    )
                )
            ]
        )
    )
}

func objectSchema(
    properties: Array<ValueField>,
    required: Array<String>
): AgentValue {
    let requiredValues = ArrayList<AgentValue>()
    for (name in required) {
        requiredValues.add(textValue(name))
    }
    objectValue(
        [
            ValueField("type", textValue("object")),
            ValueField("properties", objectValue(properties)),
            ValueField("required", listValue(requiredValues.toArray())),
            ValueField("additionalProperties", boolValue(false))
        ]
    )
}

class LimitedLines {
    let text: String
    let count: Int64
    let truncated: Bool

    init(text: String, count: Int64, truncated: Bool) {
        this.text = text
        this.count = count
        this.truncated = truncated
    }
}

func limitLines(
    source: String,
    limit: Int64,
    skip!: Int64 = 0
): LimitedLines {
    let lines = source.split("\n")
    var text = ""
    var count: Int64 = 0
    var available: Int64 = 0
    for (line in lines where line != "") {
        available += 1
        if (available > skip && count < limit) {
            if (text != "") {
                text += "\n"
            }
            text += line
            count += 1
        }
    }
    LimitedLines(text, count, available > count)
}

func looksBinary(bytes: Array<Byte>): Bool {
    let sample = min(bytes.size, 8192)
    for (index in 0..sample) {
        if (bytes[index] == 0) {
            return true
        }
    }
    false
}

func utf8BytePrefix(bytes: Array<Byte>, limit: Int64): Array<Byte> {
    var end = min(bytes.size, limit)
    while (end > 0) {
        let candidate = bytes[..end]
        try {
            let _ = String.fromUtf8(candidate)
            return candidate
        } catch (_: Exception) {
            end -= 1
        }
    }
    []
}

func insertSorted(values: ArrayList<String>, value: String): Unit {
    values.add(value)
    var index = values.size - 1
    while (index > 0 && values[index] < values[index - 1]) {
        let previous = values[index - 1]
        values[index - 1] = values[index]
        values[index] = previous
        index -= 1
    }
}
