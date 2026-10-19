package product_thread_runtime_contract

import yjson_support.*

import yjson.*

import std.env.*
import std.fs.*
import std.collection.*
import std.convert.*
import std.sync.*
import std.time.*
import std.io.*
import process4cj as process
import agent_core.*
import agent_app_protocol.*
import agent_domain.*
import agent_extension_runtime.*
import agent_ports.*
import agent_product.*
import workspace_legacy_oracle.*
import program_native_contract.*
import shell_readonly_native_contract.*
import agent_runtime.*
import agent_store.*
import tool_runtime.*
import agent_testkit.*
import model_adapters.*

class ProductProgramDenialCase {
    let name: String
    let source: String

    init(name: String, source: String) {
        this.name = name
        this.source = source
    }
}
class ProgramCancellationGate {
    private let lock = Mutex()
    private var executionCount: Int64 = 0
    private var secondChildEntered = false
    private var released = false
    private var cancellationReceived = false

    func beginCall(): Int64 {
        lock.lock()
        try {
            executionCount += 1
            if (executionCount == 2) { secondChildEntered = true }
            executionCount
        } finally {
            lock.unlock()
        }
    }

    func waitForRelease(): Unit {
        while (true) {
            lock.lock()
            let isReleased = try { released } finally { lock.unlock() }
            if (isReleased) { return }
            sleep(Duration.millisecond)
        }
    }

    func secondCallEntered(): Bool {
        lock.lock()
        try { secondChildEntered } finally { lock.unlock() }
    }

    func releaseFromCancellation(): Unit {
        lock.lock()
        try {
            cancellationReceived = true
            released = true
        } finally {
            lock.unlock()
        }
    }

    func releaseForTest(): Unit {
        lock.lock()
        try { released = true } finally { lock.unlock() }
    }

    func cancellationWasReceived(): Bool {
        lock.lock()
        try { cancellationReceived } finally { lock.unlock() }
    }

    func calls(): Int64 {
        lock.lock()
        try { executionCount } finally { lock.unlock() }
    }
}

class ProgramCancellationReadExecutor <: ToolExecutor {
    private let gate: ProgramCancellationGate

    init(gate: ProgramCancellationGate) { this.gate = gate }

    public func execute(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolResult> {
        let _ = context.runId
        let callNumber = gate.beginCall()
        if (callNumber == 2) { gate.waitForRelease() }
        Result.Ok(ToolResult(
            prepared.call.callId,
            textValue("read child result")
        ))
    }

    public func cancel(runId: RunId): Result<Unit> {
        let _ = runId
        gate.releaseFromCancellation()
        Result.Ok(())
    }
}

func runProgramCancellationRecoveryContract(root: String, workspace: String): Unit {
    let sessionId = SessionId("product-program-cancel-recovery")
    let stateRoot = root + "/program-cancel-recovery-state"
    let gate = NativeProgramAdmissionCancellationGate(sessionId.value)
    let product = openProduct(config: ProductConfig(
        settingsRoot: root + "/program-cancel-recovery-settings",
        stateRoot: stateRoot,
        workspaceRoot: workspace,
        fixture: true,
        asyncEnabled: false,
        fixtureTransactionCommitMonitor: Some({transaction=>gate.observe(transaction)})
    )).value().getOrThrow()
    try {
        let registered=product.registerTool(ToolDescriptor(
            ModelToolDefinition("fixture.observe_program_cancellation","passive cancellation observation",objectValue([])),
            Capability(CapabilityKind.WorkspaceRead),controlOnly:true,hostServiceOnly:true,
            implementationVersion:"passive-program-cancellation-v1",
            implementationFingerprint:"passive-program-cancellation-v1",
            networkPolicyResolver:Some({_=>Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied))})),
            NativeProgramCancellationObserver(gate))
        expect(registered.isOk(),"install passive observer of the original catalog cancellation broadcast")
        let binding=NativeProgramContractBinding(product)
        gate.selectActualRead(binding.workspaceName("read"))
        product.fixtureProbe.getOrThrow().enqueueToolCallReply(
            "fixture-program-cancel-root-call",
            binding.name,
            objectValue([ValueField(
                "code",
                textValue("const first = await tools.read({\"path\":\"src/alpha.cj\"}); const second = await tools.read({\"path\":\"src/beta.cj\"}); return first;")
            )])
        )
        let session = product.applicationSession(sessionId: Some(sessionId))
        let submission = spawn {
            session.submit("Cancel a Program after its first child Receipt is durable.")
        }
        var secondChildEntered = false
        for (_ in 0..5000) {
            if (gate.secondCallEntered()) {
                secondChildEntered = true
                break
            }
            if (submission.tryGet().isSome()) { break }
            sleep(Duration.millisecond)
        }

        let database = SqliteDatabase(stateRoot + "/state.db")
        try {
            let completedBeforeCancel = database.scalarInt(
                "SELECT COUNT(*) FROM derived_operation_admissions admission " +
                    "JOIN operations child ON child.id=admission.operation_id " +
                    "JOIN runs ON runs.id=child.run_id " +
                    "JOIN operation_receipts receipt ON receipt.operation_id=child.id " +
                    "WHERE runs.thread_id='" + sessionId.value + "' " +
                    "AND admission.depth=1 AND admission.call_sequence=1 AND child.state='committed' " +
                    "AND receipt.outcome='completed'"
            )
            let cancel = spawn { session.cancel() }
            for (_ in 0..3000) {
                if (gate.cancellationWasReceived() || cancel.tryGet().isSome()) { break }
                sleep(Duration.millisecond)
            }
            if (!gate.cancellationWasReceived()) { gate.releaseForTest() }

            var submissionSettled = false
            var cancellationSettled = false
            for (_ in 0..10000) {
                submissionSettled = submission.tryGet().isSome()
                cancellationSettled = cancel.tryGet().isSome()
                if (submissionSettled && cancellationSettled) { break }
                sleep(Duration.millisecond)
            }
            if (!submissionSettled || !cancellationSettled) { gate.releaseForTest() }
            for (_ in 0..5000) {
                submissionSettled = submission.tryGet().isSome()
                cancellationSettled = cancel.tryGet().isSome()
                if (submissionSettled && cancellationSettled) { break }
                sleep(Duration.millisecond)
            }

            let cancelSucceeded = if (cancellationSettled) { cancel.get().isOk() } else { false }
            let runRows = database.query(
                "SELECT state FROM runs WHERE thread_id='" + sessionId.value + "'"
            )
            let runState = if (runRows.isEmpty()) { "missing" } else { runRows[0].required(0) }
            let completedChildReceipts = database.scalarInt(
                "SELECT COUNT(*) FROM derived_operation_admissions admission " +
                    "JOIN operations child ON child.id=admission.operation_id " +
                    "JOIN runs ON runs.id=child.run_id " +
                    "JOIN operation_receipts receipt ON receipt.operation_id=child.id " +
                    "WHERE runs.thread_id='" + sessionId.value + "' " +
                    "AND admission.depth=1 AND child.state='committed' AND receipt.outcome='completed'"
            )
            let completedRootReceipts = database.scalarInt(
                "SELECT COUNT(*) FROM operations root_operation " +
                    "JOIN runs ON runs.id=root_operation.run_id " +
                    "JOIN operation_receipts receipt ON receipt.operation_id=root_operation.id " +
                    "WHERE runs.thread_id='" + sessionId.value + "' " +
                    "AND receipt.outcome='completed' AND NOT EXISTS (" +
                    "SELECT 1 FROM derived_operation_admissions admission " +
                    "WHERE admission.operation_id=root_operation.id)"
            )
            let runDirectoryEntries = ArrayList<Unit>()
            if(exists(Path(stateRoot+"/runtime/tool-programs"))){
                Directory.walk(Path(stateRoot+"/runtime/tool-programs"),{_=>runDirectoryEntries.add(());true})}
            let businessAdmissions=database.scalarInt(
                "SELECT COUNT(*) FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id "+
                "JOIN runs r ON r.id=o.run_id WHERE r.thread_id="+sqliteText(sessionId.value)+" AND a.depth=1")
            let remainingRunDirectories = runDirectoryEntries.size
            expect(secondChildEntered && gate.firstCompletedAtBoundary() && completedBeforeCancel == 1,
                "cancellation starts only after child one has a completed durable Receipt")
            expect(gate.cancellationWasReceived() && cancelSucceeded &&
                submissionSettled && cancellationSettled && runState == "cancelled",
                "parent cancellation reaches the active Program and settles the Run")
            expect(completedChildReceipts >= 1 && businessAdmissions == 2 && gate.unexpectedExecutions() == 0,
                "cancellation preserves completed child evidence without replaying the child call")
            expect(completedRootReceipts == 0,
                "cancelled worker output is not committed as a successful root ToolResult")
            expect(remainingRunDirectories == 0,
                "cancelled Native Program retains no retired per-run worker directory; actual owner ACK completes before Product close")
        } finally {
            database.close()
        }
    } finally {
        gate.releaseForTest()
        product.close().value().getOrThrow()
    }
}

func programBudget(
    base: ResourceBudget,
    maxToolCalls: Int64,
    maxConcurrentTools: Int64
): ResourceBudget {
    ResourceBudget(
        maxInputTokens: base.maxInputTokens,
        maxOutputTokens: base.maxOutputTokens,
        requestOutputBudget: Some(base.requestOutputBudget),
        maxTotalInputTokens: base.maxTotalInputTokens,
        maxTotalOutputTokens: base.maxTotalOutputTokens,
        maxModelRequests: base.maxModelRequests,
        maxTurns: base.maxTurns,
        maxDrainModelRequests: base.maxDrainModelRequests,
        maxDrainTurns: base.maxDrainTurns,
        maxToolCalls: maxToolCalls,
        maxWallMillis: base.maxWallMillis,
        maxIdleMillis: base.maxIdleMillis,
        maxChildren: base.maxChildren,
        maxDepth: base.maxDepth,
        maxConcurrentChildren: base.maxConcurrentChildren,
        maxContextMessages: base.maxContextMessages,
        maxConcurrentTools: maxConcurrentTools,
        maxCostMicros: base.maxCostMicros,
        deadlineMillis: base.deadlineMillis,
        processLimits: base.processLimits
    )
}

func requestWithBudget(
    base: AgentRunRequest,
    budget: ResourceBudget
): AgentRunRequest {
    AgentRunRequest(
        base.runId,
        base.sessionId,
        base.model,
        base.prompt,
        system: base.system,
        thinking: base.thinking,
        modelCapabilitiesSnapshot: Some(base.modelCapabilitiesSnapshot),
        resolverVersion: base.resolverVersion,
        capabilities: base.capabilities,
        budget: budget,
        interactions: base.interactions,
        approvalModeOverride: base.approvalModeOverride,
        autoRetry: base.autoRetry,
        serviceTier: base.serviceTier,
        pricing: base.pricing,
        imageInputs: base.imageInputs,
        structuredOutput: base.structuredOutput,
        cachePolicy: base.cachePolicy,
        cacheKey: base.cacheKey,
        parallelToolCalls: base.parallelToolCalls,
        toolContext: base.toolContext,
        contextSnapshot: base.contextSnapshot,
        contextWindow: base.contextWindow,
        providerSafetyMargin: base.providerSafetyMargin,
        executionLaneId: base.executionLaneId
    )
}

func readOnlyWorkflowCatalogAvailable(product: ProductRuntime): Bool {
    let request = product.fixtureProbe.getOrThrow().lastRequest.getOrThrow()
    var hasRead = false
    var hasGrep = false
    var hasProgram = false
    var hasWrite = false
    var hasEdit = false
    var hasBash = false
    for (tool in request.tools) {
        if (tool.name == nativeWorkspaceContractToolName(product,"read")) { hasRead = true }
        if (tool.name == nativeWorkspaceContractToolName(product,"grep")) { hasGrep = true }
        if (tool.name == nativeProgramContractToolName(product)) { hasProgram = true }
        if (tool.name == "write" || tool.name == "plugin.axyndra:workspace.write") { hasWrite = true }
        if (tool.name == "edit" || tool.name == "plugin.axyndra:workspace.edit") { hasEdit = true }
        if (tool.name == "bash" || tool.name == "plugin.axyndra:shell.bash") { hasBash = true }
    }
    hasRead && hasGrep && hasProgram && !hasWrite && !hasEdit && !hasBash
}

func pluginAcquisitionReadPipe(stream: InputStream): Array<Byte> {
    let output = ArrayList<Byte>()
    let buffer = Array<Byte>(4096, repeat: 0)
    while (true) {
        let count = stream.read(buffer)
        if (count <= 0) { break }
        var index = 0
        while (index < count) {
            output.add(buffer[index])
            index += 1
        }
    }
    output.toArray()
}

func pluginAcquisitionRunFixtureCommand(
    executable: String,
    arguments: Array<String>,
    workingDirectory: String
): String {
    let child = process.startProcess(process.ProcessCommand(
        executable,
        arguments: arguments,
        workingDirectory: workingDirectory,
        maxOutputBytes: 16384
    ))
    let output = spawn { pluginAcquisitionReadPipe(child.stdout) }
    let error = spawn { pluginAcquisitionReadPipe(child.stderr) }
    let code = child.wait().code
    let stdout = output.get()
    let stderr = error.get()
    child.close()
    if (code != 0) {
        throw IllegalStateException(
            executable + " failed with status " + code.toString() + ": " + String.fromUtf8(stderr)
        )
    }
    String.fromUtf8(stdout)
}

func pluginAcquisitionRequireRecord(
    result: PluginRegistryResult<ProductPluginRecord>,
    context: String
): ProductPluginRecord {
    match (result) {
        case PluginRegistryResult.Ok(value) => supportRegistryRecord96(value)
        case PluginRegistryResult.Err(error) => throw IllegalStateException(
            context + ": " + error.code + ": " + supportRegistryExclusiveErrorText96(error)
        )
    }
}

func pluginAcquisitionRunCount(database: SqliteDatabase, sessionId: SessionId): Int64 {
    database.scalarInt(
        "SELECT COUNT(*) FROM runs WHERE thread_id='" + sessionId.value + "'"
    )
}

func pluginAcquisitionHasCompletedOperation(
    database: SqliteDatabase,
    sessionId: SessionId,
    expectedNetworkMode: NetworkPolicyMode
): Bool {
    let rows = database.query(
        "SELECT op.state,receipt.outcome,effect.normalized_plan,receipt.id " +
            "FROM operations op " +
            "JOIN runs ON runs.id=op.run_id " +
            "JOIN operation_receipts receipt ON receipt.operation_id=op.id " +
            "JOIN operation_effect_records effect ON effect.operation_id=op.id " +
            "WHERE runs.thread_id=?",
        [SqlParameter.Text(sessionId.value)]
    )
    if (rows.size != 1 || rows[0].required(0) != "committed" ||
        rows[0].required(1) != "completed" || rows[0].required(3) == "") {
        return false
    }
    match (decodeStoredValue(rows[0].required(2)).field("network")) {
        case Some(value) => match (parseNetworkPolicy(value)) {
            case Result.Ok(policy) => policy.mode == expectedNetworkMode
            case Result.Err(_) => false
        }
        case None => false
    }
}

func pluginAcquisitionStageCount(settingsRoot: String): Int64 {
    let stageRoot = settingsRoot + "/plugins/acquisition"
    if (!exists(Path(stageRoot))) { return 0 }
    var count: Int64 = 0
    for (_ in Directory.readFrom(stageRoot)) { count++ }
    count
}

func pluginAcquisitionCommandAvailable(product: ProductRuntime, namespace: String): Bool {
    for (command in product.javascriptPluginCommands()) {
        if (command.extensionId == namespace && command.name == "hello") { return true }
    }
    false
}

func pluginAcquisitionInvokeNativeCommand(product: ProductRuntime, namespace: String, invocation: String): Unit {
    let cancellation = CancellationSource()
    try {
        match (product.invokeJavaScriptPluginCommand(
            "plugin." + namespace + ".hello", "", SessionId("plugin-acquisition-native-commands"),
            invocation, cancellation.token, {_, _ => ()}
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => throw IllegalStateException(
                "acquired native command failed: " + error.code + ": " + error.message
            )
        }
    } finally { cancellation.close() }
}

func pluginAcquisitionNativeFixture(root: String): String {
    match (getVariable("AXYNDRA_NATIVE_PLUGIN_FIXTURE")) {
        case Some(value) => if (exists(Path(value))) { return canonicalize(Path(value)).toString() }
        case None => ()
    }
    let script = if (exists(Path("../native_plugin_fixture/build.sh"))) {
        "../native_plugin_fixture/build.sh"
    } else { "support_tests/native_plugin_fixture/build.sh" }
    expect(exists(Path(script)), "native acquisition fixture builder exists")
    let output = root + "/native-acquisition-fixture/native-plugin"
    let _ = pluginAcquisitionRunFixtureCommand(
        "/bin/bash", [canonicalize(Path(script)).toString(), output], root
    )
    output
}

func pluginAcquisitionWriteNativePackage(packageRoot: String, source: String, id: String): Unit {
    let entrypoint = "plugins/reviewer/native-plugin"
    File.writeTo(packageRoot + "/" + entrypoint, File.readFrom(Path(source)))
    let _ = pluginAcquisitionRunFixtureCommand("/bin/chmod", ["755", entrypoint], packageRoot)
    File.writeTo(packageRoot + "/axyndra.plugin.json", (
        "{\"id\":\"" + id + "\",\"version\":\"1.0.0\"," +
        "\"entrypoint\":\"" + entrypoint + "\",\"entry_kind\":\"native-executable\"," +
        "\"sdk_range\":\"[2.0.0,3.0.0)\",\"protocol_range\":\"axyndra-js-host-v2\"," +
        "\"signature\":\"fixture-native-signature\"," +
        "\"capabilities\":[],\"contributions\":[{\"kind\":\"command\",\"name\":\"hello\"}]}"
    ).toArray())
}

func productToolAvailable(product: ProductRuntime, expected: String): Bool {
    for (tool in product.tools()) {
        if (tool.name == expected) { return true }
    }
    false
}


func runPluginAcquisitionControlContract(root: String, workspace: String): Unit {
    let nativeFixture = pluginAcquisitionNativeFixture(root)
    let gitRoot = workspace + "/plugin-acquisition-git"
    Directory.create(gitRoot + "/plugins/reviewer", recursive: true)
    File.writeTo(gitRoot + "/LICENSE", "git fixture license\n".toArray())
    pluginAcquisitionWriteNativePackage(gitRoot, nativeFixture, "acquisition-git")
    File.writeTo(gitRoot + "/package.json", (
        "{\"name\":\"plugin-acquisition-git\",\"version\":\"1.0.0\"," +
        "\"license\":\"MIT\",\"dependencies\":{" +
        "\"plugin-acquisition-dependency\":\"1.0.0\"}}"
    ).toArray())
    let _ = pluginAcquisitionRunFixtureCommand(
        "/usr/bin/git", ["init"], gitRoot
    )
    let _ = pluginAcquisitionRunFixtureCommand(
        "/usr/bin/git", ["config", "user.name", "Fixture Author"], gitRoot
    )
    let _ = pluginAcquisitionRunFixtureCommand(
        "/usr/bin/git", ["config", "user.email", "fixture@example.test"], gitRoot
    )
    let _ = pluginAcquisitionRunFixtureCommand(
        "/usr/bin/git", ["add", "-f", "."], gitRoot
    )
    let gitTree = pluginAcquisitionRunFixtureCommand(
        "/usr/bin/git", ["write-tree"], gitRoot
    ).trimAscii()
    let gitRevision = pluginAcquisitionRunFixtureCommand(
        "/usr/bin/git", ["commit-tree", gitTree, "-m", "fixture source"], gitRoot
    ).trimAscii()
    let _ = pluginAcquisitionRunFixtureCommand(
        "/usr/bin/git", ["update-ref", "refs/heads/main", gitRevision], gitRoot
    )
    let _ = pluginAcquisitionRunFixtureCommand(
        "/usr/bin/git", ["symbolic-ref", "HEAD", "refs/heads/main"], gitRoot
    )

    let registryRoot = root + "/plugin-acquisition-registry"
    let npmPackageRoot = registryRoot + "/plugin-acquisition-fixture"
    let npmDependencyRoot = registryRoot + "/plugin-acquisition-dependency"
    Directory.create(npmPackageRoot + "/plugins/reviewer", recursive: true)
    Directory.create(npmPackageRoot + "/node_modules/plugin-bundled-dependency", recursive: true)
    Directory.create(npmDependencyRoot, recursive: true)
    File.writeTo(npmPackageRoot + "/LICENSE", "npm fixture license\n".toArray())
    pluginAcquisitionWriteNativePackage(npmPackageRoot, nativeFixture, "acquisition-npm")
    File.writeTo(npmPackageRoot + "/package.json", (
        "{\"name\":\"plugin-acquisition-fixture\",\"version\":\"1.0.0\"," +
        "\"license\":\"MIT\",\"dependencies\":{" +
        "\"plugin-acquisition-dependency\":\"1.0.0\"," +
        "\"plugin-bundled-dependency\":\"1.0.0\"}," +
        "\"bundledDependencies\":[\"plugin-bundled-dependency\"]," +
        "\"scripts\":{\"preinstall\":\"touch lifecycle-marker\"}}"
    ).toArray())
    File.writeTo(npmPackageRoot + "/node_modules/plugin-bundled-dependency/package.json", (
        "{\"name\":\"plugin-bundled-dependency\",\"version\":\"1.0.0\",\"license\":\"MIT\"}"
    ).toArray())
    File.writeTo(npmDependencyRoot + "/package.json", (
        "{\"name\":\"plugin-acquisition-dependency\",\"version\":\"1.0.0\"," +
        "\"license\":\"MIT\"}"
    ).toArray())
    File.writeTo(npmDependencyRoot + "/index.js", "module.exports = true;\n".toArray())

    let fixtureScript = if (exists(Path("fixtures/npm_registry.py"))) {
        "fixtures/npm_registry.py"
    } else {
        "support_tests/product_thread_runtime_contract/fixtures/npm_registry.py"
    }
    expect(exists(Path(fixtureScript)), "local npm registry fixture script exists")
    let registryServerScript = root + "/npm_registry.py"
    File.writeTo(registryServerScript, File.readFrom(Path(fixtureScript)))

    let stateRoot = root + "/plugin-acquisition-state"
    let settingsRoot = root + "/plugin-acquisition-settings"
    let product = openProduct(config: ProductConfig(
        settingsRoot: settingsRoot,
        stateRoot: stateRoot,
        workspaceRoot: workspace,
        fixture: true,
        approvalMode: ApprovalMode.AlwaysAsk,
        shellNetworkModeOverride: Some(ShellNetworkMode.Restricted),
        asyncEnabled: false,
        extensionSignatureVerifier: Some(FixedPluginSignatureVerifier(true))
    )).value().getOrThrow()
    expect(!productToolAvailable(product, "plugin_acquisition"),
        "the host-only acquisition tool is absent from model-visible tools")
    expect(!productToolAvailable(product,"bash") && !productToolAvailable(product,"bash_readonly"),
        "the acquisition contract removes both Shell registrations before source acquisition")
    expect(!productToolAvailable(product, "bash") && !productToolAvailable(product, "bash_readonly"),
        "Git and npm maintenance starts with no registered Shell tool")
    expect(!exists(Path(workspace + "/.axyndra/plugin-acquisition")),
        "plugin acquisition never creates writable-workspace staging")
    let database = SqliteDatabase(stateRoot + "/state.db")
    try {
        let readyFile = root + "/npm_registry.ready"
        let registryServer = process.startProcess(process.ProcessCommand(
            "/usr/bin/python3",
            arguments: ["-B", registryServerScript, registryRoot, readyFile],
            workingDirectory: root,
            maxOutputBytes: 4096
        ))
        try {
            var waitCount = 0
            while (!exists(Path(readyFile)) && waitCount < 500) {
                sleep(Duration.millisecond * 10)
                waitCount += 1
            }
            expect(exists(Path(readyFile)), "loopback npm registry starts and publishes its port")
            let registryPort = String.fromUtf8(File.readFrom(Path(readyFile))).trimAscii()
            let registryUrl = "http://127.0.0.1:" + registryPort + "/"

            let invalidGitSession = SessionId("plugin-acquisition-invalid-git")
            let invalidGit = product.importPluginSource(
                invalidGitSession,
                ProductPluginSourceRequest(PluginSourceKind.Git, gitRoot, revision: "main"),
                PluginInstallScope.Workspace,
                approvalDecision: ApprovalDecision.Approve
            )
            let invalidNpmSession = SessionId("plugin-acquisition-invalid-npm")
            let invalidNpm = product.importPluginSource(
                invalidNpmSession,
                ProductPluginSourceRequest(
                    PluginSourceKind.Npm,
                    "plugin-acquisition-fixture",
                    version: "^1.0.0",
                    registryUrl: registryUrl
                ),
                PluginInstallScope.Workspace,
                approvalDecision: ApprovalDecision.Approve
            )
            expect(match (invalidGit) {
                case PluginRegistryResult.Err(error) => error.code == "plugin.source_revision_invalid"
                case _ => false
            } && match (invalidNpm) {
                case PluginRegistryResult.Err(error) => error.code == "plugin.source_version_invalid"
                case _ => false
            } && pluginAcquisitionRunCount(database, invalidGitSession) == 0 &&
                pluginAcquisitionRunCount(database, invalidNpmSession) == 0,
                "unpinned source inputs fail before creating canonical operations")

            let gitSession = SessionId("plugin-acquisition-git-import")
            let gitRequest = ProductPluginSourceRequest(
                PluginSourceKind.Git, gitRoot, revision: gitRevision, registryUrl: registryUrl
            )
            let gitImport = product.importPluginSource(
                gitSession,
                gitRequest,
                PluginInstallScope.Workspace,
                approvalDecision: ApprovalDecision.Approve
            )
            let gitRecord = match (gitImport) {
                case PluginRegistryResult.Ok(value) => supportRegistryRecord96(value)
                case PluginRegistryResult.Err(error) => throw IllegalStateException(
                    "exact Git source import failed: " + error.code + ":" + supportRegistryExclusiveErrorText96(error)
                )
            }
            expect(!supportRegistryData96(gitRecord).enabled && supportRegistryField96(gitRecord,"revision") == gitRevision &&
                supportRegistryDescriptor96(gitRecord,"root").startsWith(
                    settingsRoot + "/plugins/packages/workspaces/") &&
                supportRegistryField96(gitRecord,"content_digest") != "" && supportRegistryField96(gitRecord,"content_digest") == supportRegistryDescriptor96(gitRecord,"content_digest") &&
                String.fromUtf8(File.readFrom(Path(supportRegistryDescriptor96(gitRecord,"root") + "/LICENSE"))) ==
                    "git fixture license\n" &&
                exists(Path(supportRegistryDescriptor96(gitRecord,"root") +
                    "/node_modules/plugin-acquisition-dependency/package.json")) &&
                exists(Path(supportRegistryDescriptor96(gitRecord,"root") + "/.axyndra-dependencies.lock.json")) &&
                !exists(Path(supportRegistryDescriptor96(gitRecord,"root") + "/.git")),
                "Git import installs registry dependencies and stores a disabled immutable licensed snapshot")
            expect(pluginAcquisitionHasCompletedOperation(
                database, gitSession, NetworkPolicyMode.Mediated
            ), "local Git dependency acquisition records its mediated registry access")
            let gitRunCount = pluginAcquisitionRunCount(database, gitSession)
            let cachedGit = product.importPluginSource(
                gitSession,
                gitRequest,
                PluginInstallScope.Workspace,
                approvalDecision: ApprovalDecision.Approve
            )
            expect(match (cachedGit) {
                case PluginRegistryResult.Ok(value) => supportRegistryField96(value,"content_digest") == supportRegistryField96(gitRecord,"content_digest")
                case _ => false
            } && pluginAcquisitionRunCount(database, gitSession) == gitRunCount,
                "an identical exact Git source reuses the verified offline snapshot without a Run")

            let npmSession = SessionId("plugin-acquisition-npm-import")
            let npmImport = product.importPluginSource(
                npmSession,
                ProductPluginSourceRequest(
                    PluginSourceKind.Npm,
                    "plugin-acquisition-fixture",
                    version: "1.0.0",
                    registryUrl: registryUrl
                ),
                PluginInstallScope.Workspace,
                approvalDecision: ApprovalDecision.Approve
            )
            let npmRecord = match (npmImport) {
                case PluginRegistryResult.Ok(value) => supportRegistryRecord96(value)
                case PluginRegistryResult.Err(error) =>
                    throw IllegalStateException(
                        "exact npm source import failed: " + error.code + ":" + supportRegistryExclusiveErrorText96(error)
                    )
            }
            let npmRoot = supportRegistryDescriptor96(npmRecord,"root")
            let npmLock = parseUnifiedJson(String.fromUtf8(File.readFrom(
                Path(npmRoot + "/.axyndra-dependencies.lock.json")
            )))
            let npmPackages = npmLock.field("packages").getOrThrow()
            let npmRootEntry = npmPackages.field("node_modules/plugin-acquisition-fixture").getOrThrow()
            let npmDependencyEntry = npmPackages.field(
                "node_modules/plugin-acquisition-dependency"
            ).getOrThrow()
            let npmIntegrity = npmRootEntry.field("integrity").getOrThrow().text
            let dependencyIntegrity = npmDependencyEntry.field("integrity").getOrThrow().text
            expect(!supportRegistryData96(npmRecord).enabled && supportRegistryField96(npmRecord,"version_lock") == "1.0.0" &&
                supportRegistryDescriptor96(npmRecord,"root").startsWith(
                    settingsRoot + "/plugins/packages/workspaces/") &&
                supportRegistryField96(npmRecord,"integrity") == npmIntegrity && npmIntegrity.startsWith("sha512-") &&
                dependencyIntegrity.startsWith("sha512-") &&
                supportRegistryField96(npmRecord,"content_digest") == supportRegistryDescriptor96(npmRecord,"content_digest") &&
                exists(Path(npmRoot + "/node_modules/plugin-acquisition-dependency/package.json")) &&
                exists(Path(npmRoot + "/node_modules/plugin-bundled-dependency/package.json")) &&
                !exists(Path(npmRoot + "/node_modules/node_modules")) &&
                String.fromUtf8(File.readFrom(Path(npmRoot + "/LICENSE"))) ==
                    "npm fixture license\n" &&
                !exists(Path(npmRoot + "/lifecycle-marker")),
                "npm import locks SRI, merges hoisted and bundled dependencies, preserves license, and skips scripts")
            expect(pluginAcquisitionHasCompletedOperation(
                database, npmSession, NetworkPolicyMode.Mediated
            ), "registry-backed npm acquisition records a completed receipt with mediated access")
            expect(product.pluginDoctor().isEmpty(),
                "fresh Git and npm snapshots pass plugin integrity and dependency diagnostics")

            let enabledGitResult = product.setPluginEnabled(
                supportRegistryDescriptor96(gitRecord,"id"), true, PluginInstallScope.Workspace
            )
            let enabledGitRecord = match (enabledGitResult) {
                case PluginRegistryResult.Ok(value) => supportRegistryRecord96(value)
                case PluginRegistryResult.Err(error) => throw IllegalStateException(
                    "Git fixture could not be enabled: " + error.code + ":" + supportRegistryExclusiveErrorText96(error)
                )
            }
            let enabledNpmResult = product.setPluginEnabled(
                supportRegistryDescriptor96(npmRecord,"id"), true, PluginInstallScope.Workspace
            )
            let enabledNpmRecord = match (enabledNpmResult) {
                case PluginRegistryResult.Ok(value) => supportRegistryRecord96(value)
                case PluginRegistryResult.Err(error) => throw IllegalStateException(
                    "npm fixture could not be enabled: " + error.code + ":" + supportRegistryExclusiveErrorText96(error)
                )
            }
            expect(enabledGitRecord.enabled && enabledNpmRecord.enabled &&
                pluginAcquisitionCommandAvailable(product, supportRegistryDescriptor96(gitRecord,"namespace")) &&
                pluginAcquisitionCommandAvailable(product, supportRegistryDescriptor96(npmRecord,"namespace")),
                "both acquired native command snapshots activate with Shell tools absent")
            pluginAcquisitionInvokeNativeCommand(product, supportRegistryDescriptor96(gitRecord,"namespace"), "git-before-update")
            pluginAcquisitionInvokeNativeCommand(product, supportRegistryDescriptor96(npmRecord,"namespace"), "npm-before-update")

            let failedNpmUpdateSession = SessionId("plugin-acquisition-npm-update-failure")
            let failedNpmUpdate = product.updatePluginSource(
                supportRegistryDescriptor96(npmRecord,"id"),
                PluginInstallScope.Workspace,
                failedNpmUpdateSession,
                ProductPluginSourceRequest(
                    PluginSourceKind.Npm,
                    "plugin-acquisition-fixture",
                    version: "9.9.9",
                    registryUrl: registryUrl
                ),
                approvalDecision: ApprovalDecision.Approve
            )
            let npmAfterFailure = pluginAcquisitionRequireRecord(product.setPluginEnabled(
                supportRegistryDescriptor96(npmRecord,"id"), true, PluginInstallScope.Workspace
            ), "npm prior source record")
            expect(match (failedNpmUpdate) {
                case PluginRegistryResult.Err(error) => error.code == "plugin.acquisition_command_failed"
                case _ => false
            } && pluginAcquisitionStageCount(settingsRoot) == 0 && supportRegistryData96(npmAfterFailure).enabled &&
                supportRegistryField96(npmAfterFailure,"version_lock") == supportRegistryField96(npmRecord,"version_lock") &&
                supportRegistryField96(npmAfterFailure,"integrity") == supportRegistryField96(npmRecord,"integrity") &&
                supportRegistryField96(npmAfterFailure,"content_digest") == supportRegistryField96(npmRecord,"content_digest") &&
                pluginAcquisitionCommandAvailable(product, supportRegistryDescriptor96(npmRecord,"namespace")),
                "missing npm version cleans staging and preserves the enabled prior snapshot")

            let failedGitUpdateSession = SessionId("plugin-acquisition-git-update-failure")
            let failedGitUpdate = product.updatePluginSource(
                supportRegistryDescriptor96(gitRecord,"id"),
                PluginInstallScope.Workspace,
                failedGitUpdateSession,
                ProductPluginSourceRequest(
                    PluginSourceKind.Git,
                    gitRoot,
                    revision: "0000000000000000000000000000000000000000"
                ),
                approvalDecision: ApprovalDecision.Approve
            )
            let gitAfterFailure = pluginAcquisitionRequireRecord(product.setPluginEnabled(
                supportRegistryDescriptor96(gitRecord,"id"), true, PluginInstallScope.Workspace
            ), "Git prior source record")
            let workspaceLock = String.fromUtf8(File.readFrom(Path(
                workspace + "/.axyndra/plugins/lock.jsonl"
            )))
            expect(match (failedGitUpdate) {
                case PluginRegistryResult.Err(error) => error.code == "plugin.acquisition_command_failed"
                case _ => false
            } && pluginAcquisitionStageCount(settingsRoot) == 0 && supportRegistryData96(gitAfterFailure).enabled &&
                supportRegistryField96(gitAfterFailure,"revision") == supportRegistryField96(gitRecord,"revision") &&
                supportRegistryField96(gitAfterFailure,"content_digest") == supportRegistryField96(gitRecord,"content_digest") &&
                pluginAcquisitionCommandAvailable(product, supportRegistryDescriptor96(gitRecord,"namespace")) &&
                workspaceLock.contains("\"enabled\":true") &&
                workspaceLock.contains("\"version_lock\":\"1.0.0\"") &&
                workspaceLock.contains(supportRegistryField96(gitRecord,"revision")) &&
                workspaceLock.contains(supportRegistryField96(npmRecord,"integrity")),
                "missing Git commit cleans staging and preserves both enabled source lock records")
            expect(product.pluginDoctor().isEmpty(),
                "failed source updates leave both installed snapshots diagnostically clean")
            pluginAcquisitionInvokeNativeCommand(product, supportRegistryDescriptor96(gitRecord,"namespace"), "git-after-update")
            pluginAcquisitionInvokeNativeCommand(product, supportRegistryDescriptor96(npmRecord,"namespace"), "npm-after-update")
            expect(!productToolAvailable(product, "bash") && !productToolAvailable(product, "bash_readonly"),
                "maintenance and native activation never restore removed Shell tools")
        } finally {
            try {
                registryServer.terminate(force: true)
            } catch (_: Exception) {}
            try {
                let _ = registryServer.wait()
                registryServer.close()
            } catch (_: Exception) {}
        }
    } finally {
        database.close()
        product.close().value().getOrThrow()
    }
}

func fixtureWorkflowUsageLine(
    mode: String,
    sample: Int64,
    elapsedMillis: Int64,
    snapshot: RunSnapshot,
    operations: Int64,
    receipts: Int64
): String {
    let cost = match (snapshot.costMicros) {
        case Some(value) => value.toString()
        case None => "unpriced"
    }
    "E3-08 mode=" + mode + " sample=" + sample.toString() +
        " elapsed_ms=" + elapsedMillis.toString() +
        " model_requests=" + snapshot.modelRequests.toString() +
        " input_tokens=" + snapshot.inputTokens.toString() +
        " output_tokens=" + snapshot.outputTokens.toString() +
        " reasoning_tokens=" + snapshot.reasoningTokens.toString() +
        " cache_read_tokens=" + snapshot.cacheReadTokens.toString() +
        " cache_write_tokens=" + snapshot.cacheWriteTokens.toString() +
        " cost_micros=" + cost +
        " last_model_ms=" + snapshot.lastRequestDurationMillis.toString() +
        " last_input_tokens=" + snapshot.lastInputTokens.toString() +
        " last_output_tokens=" + snapshot.lastOutputTokens.toString() +
        " tool_calls=" + snapshot.toolCalls.toString() +
        " turns=" + snapshot.turns.toString() +
        " operations=" + operations.toString() +
        " receipts=" + receipts.toString()
}

func runMatchedProductWorkflowContract(
    product: ProductRuntime,
    stateRoot: String,
    programSource: String,
    binding: NativeProgramContractBinding
): Unit {
    let prompt = "Find SymbolAnchor definitions, read both files, and summarize matching paths."
    let database = SqliteDatabase(stateRoot + "/state.db")
    try {
        let operationStore = DurableOperationStore(database)
        println("E3-08 deterministic fixture comparison; elapsed wall time is not a performance claim")
        var sampleCount: Int64 = 0
        for (sample in 0..3) {
            if (sample == 3) { break }
            let sampleNumber = sample + 1
            let ptcSession = SessionId("e3-08-ptc-" + sampleNumber.toString())
            product.fixtureProbe.getOrThrow().enqueueToolCallReply(
                "e3-08-ptc-call-" + sampleNumber.toString(),
                nativeProgramContractToolName(product),
                objectValue([ValueField("code", textValue(programSource))])
            )
            let ptcRequest = product.request(
                prompt,
                sessionId: Some(ptcSession),
                readOnly: true
            )
            let ptcStarted = MonoTime.now()
            let ptcResult = product.client.start(ptcRequest, {_ => ()})
            let ptcElapsed = (MonoTime.now() - ptcStarted).toMilliseconds()
            let ptcSnapshot = match (ptcResult) {
                case Result.Ok(AgentRunOutcome.Completed(snapshot)) => snapshot
                case _ => throw IllegalStateException("matched PTC workflow did not complete")
            }
            expect(ptcSnapshot.status == RunState.Completed &&
                readOnlyWorkflowCatalogAvailable(product),
                "PTC uses the same read-only catalog as native calls")

            let ptcHistory = SqliteThreadCommitSink(database).loadThread(
                ThreadId(ptcSession.value)
            )
            var ptcRootCallId = ""
            var ptcRootCallCount: Int64 = 0
            var ptcRootResultCount: Int64 = 0
            var ptcRootResult: ?AgentValue = None
            var ptcRootResultIsError = false
            for (item in ptcHistory.items) {
                match (item.content) {
                    case ThreadItemContent.ToolCall(callId, name, _) =>
                        if (name == nativeProgramContractToolName(product)) {
                            ptcRootCallId = callId.value
                            ptcRootCallCount += 1
                        }
                    case ThreadItemContent.ToolResult(callId, _, _, output, isError) =>
                        if (callId.value == ptcRootCallId) {
                            ptcRootResult = Some(output)
                            ptcRootResultIsError = isError
                            ptcRootResultCount += 1
                        }
                    case _ => ()
                }
            }
            let ptcRootOutput = match (ptcRootResult) {
                case Some(value) => value
                case None => objectValue([])
            }
            let ptcProgramValue = ptcRootOutput.field("value") ?? listValue([])
            let ptcRootOperationRows = database.query(
                "SELECT op.id FROM operations op WHERE op.run_id='" +
                    ptcSnapshot.runId.value + "' AND NOT EXISTS (" +
                    "SELECT 1 FROM derived_operation_admissions admission " +
                    "WHERE admission.operation_id=op.id)"
            )
            let ptcRootOperationId = if (ptcRootOperationRows.isEmpty()) {
                ""
            } else {
                ptcRootOperationRows[0].required(0)
            }
            let ptcChildRows = database.query(
                "SELECT admission.call_sequence,child.id,child.state,receipt.outcome,effect.tool_id " +
                    "FROM derived_operation_admissions admission " +
                    "JOIN operations child ON child.id=admission.operation_id " +
                    "JOIN operation_receipts receipt ON receipt.operation_id=child.id " +
                    "JOIN operation_effect_records effect ON effect.operation_id=child.id " +
                    "WHERE admission.parent_operation_id='" + ptcRootOperationId +
                    "' ORDER BY admission.call_sequence"
            )
            let ptcRootPlan = operationStore.loadPlan(
                OperationId(ptcRootOperationId), ptcSnapshot.runId
            ).value().getOrThrow()
            var ptcRootHasRead = false
            var ptcRootOnlyRead = true
            for (required in ptcRootPlan.requiredCapabilities) {
                if (required.kind == CapabilityKind.WorkspaceRead) {
                    ptcRootHasRead = true
                } else if (required.kind==CapabilityKind.ExtensionInvoke && binding.readonlyCapabilityAllowed(ptcRootPlan,required)) {
                    // Only this actual frozen contribution or an independently granted actual child QName.
                } else {
                    ptcRootOnlyRead = false
                }
            }
            var ptcChildPlansReadOnly = ptcChildRows.size == 3
            for (row in ptcChildRows) {
                let plan = operationStore.loadPlan(
                    OperationId(row.required(1)), ptcSnapshot.runId
                ).value().getOrThrow()
                var childHasRead = false
                var childOnlyRead = true
                for (required in plan.requiredCapabilities) {
                    if (required.kind == CapabilityKind.WorkspaceRead) {
                        childHasRead = true
                    } else if (required.kind==CapabilityKind.ExtensionInvoke && binding.readonlyCapabilityAllowed(plan,required)) {
                        // Only this actual frozen contribution or an independently granted actual child QName.
                    } else {
                        childOnlyRead = false
                    }
                }
                if (plan.effectClass != OperationEffectClass.ReadOnly ||
                    plan.networkPolicy.mode != NetworkPolicyMode.Denied ||
                    !childHasRead || !childOnlyRead) {
                    ptcChildPlansReadOnly = false
                }
            }
            let ptcGrepReceipt: ?VNextOperationReceipt = if (ptcChildRows.size == 3) {
                operationStore.loadDerivedOperationReceipt(
                    OperationId(ptcChildRows[0].required(1)), ptcSnapshot.runId
                ).value().getOrThrow()
            } else { None }
            let ptcAlphaReceipt: ?VNextOperationReceipt = if (ptcChildRows.size == 3) {
                operationStore.loadDerivedOperationReceipt(
                    OperationId(ptcChildRows[1].required(1)), ptcSnapshot.runId
                ).value().getOrThrow()
            } else { None }
            let ptcBetaReceipt: ?VNextOperationReceipt = if (ptcChildRows.size == 3) {
                operationStore.loadDerivedOperationReceipt(
                    OperationId(ptcChildRows[2].required(1)), ptcSnapshot.runId
                ).value().getOrThrow()
            } else { None }
            let ptcGrepOutput = match (ptcGrepReceipt) {
                case Some(receipt) => receipt.detail.field("output") ?? objectValue([])
                case None => objectValue([])
            }
            let ptcAlphaOutput = match (ptcAlphaReceipt) {
                case Some(receipt) => receipt.detail.field("output") ?? objectValue([])
                case None => objectValue([])
            }
            let ptcBetaOutput = match (ptcBetaReceipt) {
                case Some(receipt) => receipt.detail.field("output") ?? objectValue([])
                case None => objectValue([])
            }
            let ptcGrepFiles = ptcGrepOutput.field("files") ?? listValue([])
            let ptcAlphaContent = ptcAlphaOutput.field("content") ?? textValue("")
            let ptcBetaContent = ptcBetaOutput.field("content") ?? textValue("")
            let ptcEvidence = if (ptcProgramValue.unifiedKind == ValueKind.List &&
                ptcProgramValue.items.size == 2) {
                ptcProgramValue.items[0].text + "\n" + ptcAlphaContent.text + "\n" +
                    ptcProgramValue.items[1].text + "\n" + ptcBetaContent.text
            } else { "" }
            let ptcOperationCount = database.scalarInt(
                "SELECT COUNT(*) FROM operations WHERE run_id='" + ptcSnapshot.runId.value + "'"
            )
            let ptcReceiptCount = database.scalarInt(
                "SELECT COUNT(*) FROM operation_receipts receipt JOIN operations op " +
                    "ON op.id=receipt.operation_id WHERE op.run_id='" +
                    ptcSnapshot.runId.value + "'"
            )
            binding.requireCompletedBranches(database,ptcSnapshot.runId,ptcRootOperationId,["grep","read","read"])
            expect(ptcRootCallCount == 1 && ptcRootResultCount == 1 &&
                !ptcRootResultIsError && ptcRootOutput.field("status").getOrThrow().text == "completed" &&
                ptcRootHasRead && ptcRootOnlyRead &&
                ptcRootPlan.effectClass == OperationEffectClass.ReadOnly &&
                ptcRootPlan.networkPolicy.mode == NetworkPolicyMode.Denied &&
                ptcChildRows.size == 3 && ptcChildRows[0].required(4) == binding.workspaceName("grep") &&
                ptcChildRows[1].required(4) == binding.workspaceName("read") && ptcChildRows[2].required(4) == binding.workspaceName("read") &&
                ptcChildRows[0].required(3) == "completed" &&
                ptcChildRows[1].required(3) == "completed" &&
                ptcChildRows[2].required(3) == "completed" && ptcChildPlansReadOnly &&
                ptcOperationCount == 7 && ptcReceiptCount == 7 && ptcEvidence != "",
                "PTC completes the search-read workflow with only denied-network WorkspaceRead plans")

            let nativeSession = SessionId("e3-08-native-" + sampleNumber.toString())
            let nativeProbe = product.fixtureProbe.getOrThrow()
            nativeProbe.enqueueToolCallReply(
                "e3-08-native-grep-" + sampleNumber.toString(),
                binding.workspaceName("grep"),
                objectValue([
                    ValueField("pattern", textValue("SymbolAnchor")),
                    ValueField("path", textValue("src")),
                    ValueField("count", boolValue(true))
                ])
            )
            nativeProbe.enqueueToolCallReply(
                "e3-08-native-alpha-" + sampleNumber.toString(),
                binding.workspaceName("read"),
                objectValue([
                    ValueField("path", textValue("src/alpha.cj")),
                    ValueField("offset", integerValue(1)),
                    ValueField("limit", integerValue(3))
                ])
            )
            nativeProbe.enqueueToolCallReply(
                "e3-08-native-beta-" + sampleNumber.toString(),
                binding.workspaceName("read"),
                objectValue([
                    ValueField("path", textValue("src/beta.cj")),
                    ValueField("offset", integerValue(1)),
                    ValueField("limit", integerValue(3))
                ])
            )
            let nativeRequest = product.request(
                prompt,
                sessionId: Some(nativeSession),
                readOnly: true
            )
            let nativeStarted = MonoTime.now()
            let nativeResult = product.client.start(nativeRequest, {_ => ()})
            let nativeElapsed = (MonoTime.now() - nativeStarted).toMilliseconds()
            let nativeSnapshot = match (nativeResult) {
                case Result.Ok(AgentRunOutcome.Completed(snapshot)) => snapshot
                case _ => throw IllegalStateException("matched native workflow did not complete")
            }
            expect(nativeSnapshot.status == RunState.Completed &&
                readOnlyWorkflowCatalogAvailable(product),
                "native calls use the same read-only catalog as PTC")

            let nativeHistory = SqliteThreadCommitSink(database).loadThread(
                ThreadId(nativeSession.value)
            )
            let nativeCallNames = ArrayList<String>()
            let nativeOutputs = ArrayList<AgentValue>()
            let nativeResultErrors = ArrayList<Bool>()
            for (item in nativeHistory.items) {
                match (item.content) {
                    case ThreadItemContent.ToolCall(_, name, _) => nativeCallNames.add(name)
                    case ThreadItemContent.ToolResult(_, _, _, output, isError) =>
                        nativeOutputs.add(output)
                        nativeResultErrors.add(isError)
                    case _ => ()
                }
            }
            let nativeGrepOutput = if (nativeOutputs.size > 0) {
                nativeOutputs[0]
            } else { objectValue([]) }
            let nativeAlphaOutput = if (nativeOutputs.size > 1) {
                nativeOutputs[1]
            } else { objectValue([]) }
            let nativeBetaOutput = if (nativeOutputs.size > 2) {
                nativeOutputs[2]
            } else { objectValue([]) }
            let nativeGrepFiles = nativeGrepOutput.field("files") ?? listValue([])
            let nativeAlphaContent = nativeAlphaOutput.field("content") ?? textValue("")
            let nativeBetaContent = nativeBetaOutput.field("content") ?? textValue("")
            let nativeEvidence = if (nativeGrepFiles.unifiedKind == ValueKind.List &&
                nativeGrepFiles.items.size == 2) {
                nativeGrepFiles.items[0].field("path").getOrThrow().text + "\n" +
                    nativeAlphaContent.text + "\n" +
                    nativeGrepFiles.items[1].field("path").getOrThrow().text + "\n" +
                    nativeBetaContent.text
            } else { "" }
            let nativeOperationRows = database.query(
                "SELECT op.id FROM operations op WHERE op.run_id='" +
                    nativeSnapshot.runId.value + "'"
            )
            var nativePlansReadOnly = nativeOperationRows.size == 6
            for (row in nativeOperationRows) {
                let plan = operationStore.loadPlan(
                    OperationId(row.required(0)), nativeSnapshot.runId
                ).value().getOrThrow()
                var hasRead = false
                var onlyRead = true
                for (required in plan.requiredCapabilities) {
                    if (required.kind == CapabilityKind.WorkspaceRead) {
                        hasRead = true
                    } else if (required.kind==CapabilityKind.ExtensionInvoke && binding.readonlyCapabilityAllowed(plan,required)) {
                        // Only this actual frozen contribution or an independently granted actual child QName.
                    } else {
                        onlyRead = false
                    }
                }
                if (plan.effectClass != OperationEffectClass.ReadOnly ||
                    plan.networkPolicy.mode != NetworkPolicyMode.Denied ||
                    !hasRead || !onlyRead) {
                    nativePlansReadOnly = false
                }
            }
            let nativeOperationCount = database.scalarInt(
                "SELECT COUNT(*) FROM operations WHERE run_id='" + nativeSnapshot.runId.value + "'"
            )
            let nativeReceiptCount = database.scalarInt(
                "SELECT COUNT(*) FROM operation_receipts receipt JOIN operations op " +
                    "ON op.id=receipt.operation_id WHERE op.run_id='" +
                    nativeSnapshot.runId.value + "'"
            )
            let nativeRoots=database.query("SELECT o.id,e.tool_id FROM operations o JOIN operation_effect_records e ON e.operation_id=o.id "+
                "WHERE o.run_id=? AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=o.id) ORDER BY o.id",
                [SqlParameter.Text(nativeSnapshot.runId.value)])
            expect(nativeRoots.size==3,"the native comparison has exactly three actual ordinary roots")
            for(root in nativeRoots){binding.requireCompletedReadviewRoot(database,nativeSnapshot.runId,root.required(0),root.required(1))}
            expect(nativeCallNames.size == 3 && nativeCallNames[0] == binding.workspaceName("grep") &&
                nativeCallNames[1] == binding.workspaceName("read") && nativeCallNames[2] == binding.workspaceName("read") &&
                nativeOutputs.size == 3 && nativeResultErrors.size == 3 &&
                !nativeResultErrors[0] && !nativeResultErrors[1] && !nativeResultErrors[2] &&
                nativeGrepFiles.unifiedKind == ValueKind.List && nativeGrepFiles.items.size == 2 &&
                nativeGrepFiles.items[0].field("path").getOrThrow().text == "src/alpha.cj" &&
                nativeGrepFiles.items[1].field("path").getOrThrow().text == "src/beta.cj" &&
                nativeAlphaContent.text.contains("SymbolAnchor: alpha") &&
                nativeBetaContent.text.contains("SymbolAnchor: beta") &&
                nativeEvidence == ptcEvidence && nativePlansReadOnly &&
                nativeOperationCount == 6 && nativeReceiptCount == 6,
                "native and PTC workflows produce identical paths and file evidence under read-only plans")
            expect(ptcProgramValue.items[0].text == "src/alpha.cj" &&
                ptcProgramValue.items[1].text == "src/beta.cj" &&
                ptcGrepFiles.items.size == 2 &&
                ptcGrepFiles.items[0].field("path").getOrThrow().text == "src/alpha.cj" &&
                ptcGrepFiles.items[1].field("path").getOrThrow().text == "src/beta.cj" &&
                ptcAlphaContent.text == nativeAlphaContent.text &&
                ptcBetaContent.text == nativeBetaContent.text,
                "PTC-derived Receipts and native ToolResults carry matching complete evidence")
            println(fixtureWorkflowUsageLine(
                "ptc", sampleNumber, ptcElapsed, ptcSnapshot, ptcOperationCount, ptcReceiptCount
            ))
            println(fixtureWorkflowUsageLine(
                "native", sampleNumber, nativeElapsed, nativeSnapshot,
                nativeOperationCount, nativeReceiptCount
            ))
            sampleCount += 1
        }
        expect(sampleCount == 3,
            "matched Product workflow records three deterministic samples per execution mode")

        let missingReadSession = SessionId("e3-08-native-missing-read")
        product.fixtureProbe.getOrThrow().enqueueToolCallReply(
            "e3-08-native-missing-read-call",
            binding.workspaceName("read"),
            objectValue([ValueField("path", textValue("src/missing.cj"))])
        )
        let missingReadRequest = product.request(
            "Read src/missing.cj and report the read failure.",
            sessionId: Some(missingReadSession),
            readOnly: true
        )
        let missingReadResult = product.client.start(missingReadRequest, {_ => ()})
        let missingReadSnapshot = match (missingReadResult) {
            case Result.Ok(AgentRunOutcome.Completed(snapshot)) => snapshot
            case _ => throw IllegalStateException("native missing-file workflow did not settle")
        }
        let missingReadHistory = SqliteThreadCommitSink(database).loadThread(
            ThreadId(missingReadSession.value)
        )
        var missingReadToolFailure = false
        for (item in missingReadHistory.items) {
            match (item.content) {
                case ThreadItemContent.ToolResult(callId, _, _, output, isError) =>
                    if (callId.value == "e3-08-native-missing-read-call" && isError &&
                        output.unifiedKind != ValueKind.Null) {
                        missingReadToolFailure = true
                    }
                case _ => ()
            }
        }
        expect(missingReadSnapshot.status == RunState.Completed && missingReadToolFailure,
            "native workflow surfaces a missing-file ToolResult failure without terminating the model turn")
    } finally {
        database.close()
    }
}

func runNativeReadCancellationContract(root: String, workspace: String): Unit {
    let sessionId = SessionId("product-native-read-cancel")
    let stateRoot = root + "/native-read-cancel-state"
    let product = openProduct(config: ProductConfig(
        settingsRoot: root + "/native-read-cancel-settings",
        stateRoot: stateRoot,
        workspaceRoot: workspace,
        fixture: true,
        asyncEnabled: false
    )).value().getOrThrow()
    try {
        expect(!productToolAvailable(product,"read"), "retired built-in read is absent before the isolated foundational cancellation fixture")
        let gate = ProgramCancellationGate()
        let _ = gate.beginCall()
        let registered = product.registerTool(
            ToolDescriptor(
                ModelToolDefinition("fixture.native_read_cancellation", "blocking native read cancellation fixture", objectValue([])),
                Capability(CapabilityKind.WorkspaceRead),
                implementationVersion: "native-cancel-fixture-v1",
                implementationFingerprint: "native-cancel-read-v1",
                networkPolicyResolver: Some({_ =>
                    Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied))
                })
            ),
            ProgramCancellationReadExecutor(gate)
        )
        expect(registered.isOk(), "install the deterministic native read cancellation fixture")
        product.fixtureProbe.getOrThrow().enqueueToolCallReply(
            "native-cancel-read-call",
            "fixture.native_read_cancellation",
            objectValue([])
        )
        let request = product.request(
            "Read the selected file.",
            sessionId: Some(sessionId),
            readOnly: true
        )
        let submission = spawn { product.client.start(request, {_ => ()}) }
        var readEntered = false
        for (_ in 0..5000) {
            if (gate.secondCallEntered()) {
                readEntered = true
                break
            }
            if (submission.tryGet().isSome()) { break }
            sleep(Duration.millisecond)
        }
        let requestIdBeforeCancel = product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().requestId
        let cancel = spawn { product.client.cancel(request.runId) }
        for (_ in 0..3000) {
            if (gate.cancellationWasReceived() || cancel.tryGet().isSome()) { break }
            sleep(Duration.millisecond)
        }
        if (!gate.cancellationWasReceived()) { gate.releaseForTest() }
        var submissionSettled = false
        var cancellationSettled = false
        for (_ in 0..10000) {
            submissionSettled = submission.tryGet().isSome()
            cancellationSettled = cancel.tryGet().isSome()
            if (submissionSettled && cancellationSettled) { break }
            sleep(Duration.millisecond)
        }
        if (!submissionSettled || !cancellationSettled) { gate.releaseForTest() }
        for (_ in 0..5000) {
            submissionSettled = submission.tryGet().isSome()
            cancellationSettled = cancel.tryGet().isSome()
            if (submissionSettled && cancellationSettled) { break }
            sleep(Duration.millisecond)
        }
        let cancelSucceeded = if (cancellationSettled) { cancel.get().isOk() } else { false }
        let database = SqliteDatabase(stateRoot + "/state.db")
        try {
            let runRows = database.query(
                "SELECT state FROM runs WHERE id='" + request.runId.value + "'"
            )
            let runState = if (runRows.isEmpty()) { "missing" } else { runRows[0].required(0) }
            let completedRootReceipts = database.scalarInt(
                "SELECT COUNT(*) FROM operations op JOIN runs ON runs.id=op.run_id " +
                    "JOIN operation_receipts receipt ON receipt.operation_id=op.id " +
                    "WHERE runs.thread_id='" + sessionId.value + "' " +
                    "AND receipt.outcome='completed' AND NOT EXISTS (" +
                    "SELECT 1 FROM derived_operation_admissions admission " +
                    "WHERE admission.operation_id=op.id)"
            )
            expect(readEntered && gate.cancellationWasReceived() && cancelSucceeded &&
                submissionSettled && cancellationSettled && runState == "cancelled" &&
                gate.calls() == 2,
                "native Product read cancellation reaches the active executor and settles without hanging")
            let requestIdAfterCancel = product.fixtureProbe.getOrThrow().lastRequest.getOrThrow().requestId
            expect(completedRootReceipts == 1 && requestIdAfterCancel == requestIdBeforeCancel,
                "a native read that settles during cancellation retains its Receipt without a follow-up model request")
        } finally {
            database.close()
        }
    } finally {
        product.close()
    }
}

func runAstPluginQuery(product: ProductRuntime, tool: String, id: String, input: AgentValue): ToolResult {
    let budget = ExecutionBudget(maxToolCalls: 2, maxConcurrentTools: 1)
    let result = product.vnext.executeCanonicalTool(SessionId(id),
        CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke), Capability(CapabilityKind.WorkspaceRead)]),
        ToolCall(id, tool, input), budget: budget)
    let value = match (result) {
        case Result.Ok(ToolInvocationResult.Completed(output)) => output
        case Result.Err(error) => throw IllegalStateException("AST invocation failed: " + error.describe())
        case _ => throw IllegalStateException("AST invocation did not complete")
    }
    expect(budget.snapshot().toolCalls == 2 && budget.snapshot().activeTools == 0,
        "AST root and process worker share a two-call budget and one concurrent slot")
    value
}

func runAstPluginContract(root: String, workspace: String): Unit {
    let packageRoot = getVariable("AXYNDRA_AST_PLUGIN_PACKAGE").getOrThrow()
    expect(normalizedContentTag("before \t\r\n") == "F27C" && hashlineTag("before\n") == "F27C",
        "shared content tags retain the existing golden value and trailing-whitespace normalization")
    let source = "def sample(value):\n    return value\n\ndef constant():\n    return 42\n"
    Directory.create(workspace + "/ast", recursive: true)
    File.writeTo(workspace + "/ast/sample.py", source.toArray())
    let stateRoot = root + "/ast-plugin-state"
    let product = openProduct(config: ProductConfig(
        settingsRoot: root + "/ast-plugin-settings", stateRoot: stateRoot,
        workspaceRoot: workspace, fixture: true, asyncEnabled: false, approvalMode: ApprovalMode.Yolo
    )).value().getOrThrow()
    try {
        expect(!productToolAvailable(product, "ast_grep"), "AST query is absent until its process package is installed")
        expect(!productToolAvailable(product,"bash") && !productToolAvailable(product,"bash_readonly"),
            "AST query fixture removes both Shell registrations")
        expect(!productToolAvailable(product, "ast_edit"),
            "AST query fixture has no remaining static AST edit registration")
        let record = pluginAcquisitionRequireRecord(product.importLocalPlugin(packageRoot, PluginInstallScope.Workspace), "import AST package")
        let tool = "plugin." + supportRegistryDescriptor96(record,"namespace") + ".ast_grep"
        expect(!supportRegistryData96(record).enabled && !productToolAvailable(product, tool), "AST local import creates a disabled verified snapshot")
        let _ = pluginAcquisitionRequireRecord(product.setPluginEnabled(supportRegistryDescriptor96(record,"id"), true, PluginInstallScope.Workspace), "enable AST package")
        expect(productToolAvailable(product, tool), "AST package independently registers its declared query tool")
        let result = runAstPluginQuery(product, tool, "ast-plugin-query", objectValue([
            ValueField("pat", textValue("return $VALUE")), ValueField("path", textValue("ast/**/*.py"))
        ]))
        expect(!result.isError && result.output.field("match_count").getOrThrow().asNumberText() == "2" &&
            result.output.field("file_count").getOrThrow().asNumberText() == "1" &&
            result.output.field("content").getOrThrow().text.contains("[ast/sample.py#" + hashlineTag(source) + "]") &&
            result.output.field("content").getOrThrow().text.contains("VALUE=value") &&
            result.output.field("content").getOrThrow().text.contains("VALUE=42"),
            "installed AST native worker produces real structural matches, captures and shared hashline tags; actual=" + canonicalAgentValue(result.output))
        let paged = runAstPluginQuery(product, tool, "ast-plugin-page", objectValue([
            ValueField("pat", textValue("return $VALUE")), ValueField("path", textValue("ast/sample.py")), ValueField("skip", integerValue(1))
        ]))
        expect(!paged.isError && paged.output.field("visible_count").getOrThrow().asNumberText() == "1" &&
            !paged.output.field("content").getOrThrow().text.contains("VALUE=value"), "installed AST plugin preserves stable pagination")
        let empty = runAstPluginQuery(product, tool, "ast-plugin-empty", objectValue([
            ValueField("pat", textValue("never_called($$$ARGS)")), ValueField("path", textValue("ast/sample.py"))
        ]))
        expect(!empty.isError && empty.output.field("content").getOrThrow().text == "No matches found",
            "zero AST matches remain successful")
        let escaped = runAstPluginQuery(product, tool, "ast-plugin-escape", objectValue([
            ValueField("pat", textValue("return $VALUE")), ValueField("path", textValue("../*.py"))
        ]))
        expect(escaped.isError, "independent AST worker rejects a workspace escape")
        let denied = product.vnext.executeCanonicalTool(SessionId("ast-plugin-no-read"),
            CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke)]),
            ToolCall("ast-plugin-no-read", tool, objectValue([ValueField("pat", textValue("return $VALUE"))])))
        expect(match (denied) { case Result.Ok(ToolInvocationResult.Denied(_)) => true; case Result.Err(_) => true; case _ => false },
            "manifest read request does not grant missing WorkspaceRead authority")
        let database = SqliteDatabase(stateRoot + "/state.db")
        try {
            let roots = database.query("SELECT op.id,op.run_id,op.tool_call_item_id FROM operations op JOIN runs r ON r.id=op.run_id " +
                "WHERE r.thread_id='ast-plugin-query' AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=op.id)")
            expect(roots.size == 1, "Direct AST invocation has exactly one canonical parent Operation")
            let children = database.query("SELECT op.id,e.tool_id,receipt.outcome,op.tool_call_item_id FROM derived_operation_admissions a " +
                "JOIN operations op ON op.id=a.operation_id JOIN operation_effect_records e ON e.operation_id=op.id " +
                "JOIN operation_receipts receipt ON receipt.operation_id=op.id WHERE a.parent_operation_id='" + roots[0].required(0) + "'")
            expect(children.size == 1 && children[0].required(1) == "host.process.readonly" && children[0].required(2) == "completed" &&
                children[0].required(3) == roots[0].required(2), "AST worker owns one admitted generic process child with a completed Receipt")
            let plan = DurableOperationStore(database).loadPlan(OperationId(children[0].required(0)), RunId(roots[0].required(1))).value().getOrThrow()
            expect(plan.effectClass == OperationEffectClass.ReadOnly && plan.networkPolicy.mode == NetworkPolicyMode.Denied &&
                plan.requiredCapabilities.size == 1 && plan.requiredCapabilities[0].kind == CapabilityKind.WorkspaceRead,
                "generic worker plan freezes read-only workspace authority and denied network")
            expect(database.scalarInt("SELECT COUNT(*) FROM decision_operations d JOIN operations op ON op.id=d.operation_id " +
                "WHERE op.run_id='" + roots[0].required(1) + "'") == 0, "Direct AST query does not fabricate a ModelDecision")
        } finally { database.close() }
        let _ = pluginAcquisitionRequireRecord(product.setPluginEnabled(supportRegistryDescriptor96(record,"id"), false, PluginInstallScope.Workspace), "disable AST package")
        expect(!productToolAvailable(product, tool) && !productToolAvailable(product, "ast_grep") &&
            !productToolAvailable(product, "bash") && !productToolAvailable(product, "bash_readonly"),
            "disabling the independent AST package removes its query tool without restoring a host fallback")
    } finally { product.close() }
}

func astPluginEditArguments(): AgentValue {
    objectValue([
        ValueField("ops", listValue([objectValue([
            ValueField("pat", textValue("return $VALUE")), ValueField("out", textValue("return changed"))
        ])])),
        ValueField("paths", listValue([textValue("sample.py")]))
    ])
}

func astPluginEditPlan(product: ProductRuntime, tool: String, session: String): AgentValue {
    let budget = ExecutionBudget(maxToolCalls: 3, maxConcurrentTools: 1)
    let result = product.vnext.executeCanonicalTool(SessionId(session),
        CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke), Capability(CapabilityKind.WorkspaceRead)]),
        ToolCall(session, tool, astPluginEditArguments()), budget: budget)
    let output = match (result) {
        case Result.Ok(ToolInvocationResult.Completed(value)) => value
        case Result.Err(error) => throw IllegalStateException("AST edit failed: " + error.describe())
        case _ => throw IllegalStateException("AST edit did not complete its read-only proposal")
    }
    expect(!output.isError && !output.output.field("applied").getOrThrow().asBool(),
        "AST plugin only proposes changes; actual=" + canonicalAgentValue(output.output))
    expect(budget.snapshot().toolCalls == 3 && budget.snapshot().activeTools == 0,
        "AST edit root and two serial children share three calls and one concurrent slot")
    output.output.field("application_plan").getOrThrow()
}

func astPlanArguments(summary: AgentValue): AgentValue {
    objectValue([
        ValueField("plan_ref", summary.field("plan_ref").getOrThrow()),
        ValueField("plan_digest", summary.field("plan_digest").getOrThrow())
    ])
}

func astPlanApprovalSession(product: ProductRuntime, sessionId: String, plan: AgentValue): ApplicationSession {
    let session = product.applicationSession(sessionId: Some(SessionId(sessionId)))
    product.fixtureProbe.getOrThrow().enqueueToolCallReply(sessionId, "apply_file_plan", astPlanArguments(plan))
    let submitted = session.submit("Review this exact immutable AST edit plan.").value().getOrThrow()
    let approval = session.approval().getOrThrow()
    expect(submitted.approval.isSome() && approval.toolName == "apply_file_plan" &&
        approval.capability.kind == CapabilityKind.WorkspaceWrite && !approval.sessionApprovalAllowed &&
        approval.preview.field("plan_ref").getOrThrow().text == plan.field("plan_ref").getOrThrow().text &&
        approval.preview.field("plan_digest").getOrThrow().text == plan.field("plan_digest").getOrThrow().text,
        "AST application uses the existing exact, one-time write approval")
    session
}

func runAstEditPluginContract(root: String, parentWorkspace: String): Unit {
    let workspace = parentWorkspace + "/ast-edit-plugin"
    Directory.create(workspace, recursive: true)
    let path = workspace + "/sample.py"
    let original = "def sample():\n    return before\n"
    let replacement = "def sample():\n    return changed\n"
    File.writeTo(path, original.toArray())
    let stateRoot = root + "/ast-edit-plugin-state"
    var product = openProduct(config: ProductConfig(settingsRoot: root + "/ast-edit-plugin-settings",
        stateRoot: stateRoot, workspaceRoot: workspace, fixture: true, asyncEnabled: false,
        approvalMode: ApprovalMode.Yolo)).value().getOrThrow()
    try {
        expect(!productToolAvailable(product,"bash") && !productToolAvailable(product,"bash_readonly") &&
            !productToolAvailable(product, "ast_edit") && !productToolAvailable(product, "ast_grep"),
            "AST edit has no Shell registration or static AST fallback")
        let record = pluginAcquisitionRequireRecord(product.importLocalPlugin(
            getVariable("AXYNDRA_AST_PLUGIN_PACKAGE").getOrThrow(), PluginInstallScope.Workspace), "import AST edit package")
        let _ = pluginAcquisitionRequireRecord(product.setPluginEnabled(supportRegistryDescriptor96(record,"id"), true,
            PluginInstallScope.Workspace), "enable AST edit package")
        let tool = "plugin." + supportRegistryDescriptor96(record,"namespace") + ".ast_edit"
        let plan = astPluginEditPlan(product, tool, "ast-edit-propose")
        let freshPlan = astPluginEditPlan(product, tool, "ast-edit-fresh")
        expect(String.fromUtf8(File.readFrom(path)) == original,
            "real ast-grep rewrite and plan materialization leave the source file unchanged")
        let database = SqliteDatabase(stateRoot + "/state.db")
        try {
            let reference = plan.field("plan_ref").getOrThrow().text
            let artifact = ProductArtifactStore(stateRoot, database: Some(database)).read(reference, limit: 1048576).value().getOrThrow()
            let stored = parseUnifiedJson(artifact.content)
            let source = stored.field("source").getOrThrow()
            expect(!artifact.truncated && stored.field("schema").getOrThrow().text == "axyndra.file-application-plan/v2" &&
                source.field("kind").getOrThrow().text == "plugin" &&
                source.field("plugin_namespace").getOrThrow().text == supportRegistryDescriptor96(record,"namespace") &&
                source.field("plugin_version").getOrThrow().text == supportRegistryDescriptor96(record,"version") &&
                source.field("package_digest").getOrThrow().text == supportRegistryDescriptor96(record,"content_digest") &&
                source.field("contribution").getOrThrow().text == tool && source.field("program_id").isNone(),
                "immutable plan records the installed plugin origin without pretending to be a Program")
            let roots = database.query("SELECT op.id,op.run_id FROM operations op JOIN runs r ON r.id=op.run_id " +
                "WHERE r.thread_id='ast-edit-propose' AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=op.id)")
            let children = database.query("SELECT op.id,e.tool_id,receipt.outcome FROM derived_operation_admissions a " +
                "JOIN operations op ON op.id=a.operation_id JOIN operation_effect_records e ON e.operation_id=op.id " +
                "JOIN operation_receipts receipt ON receipt.operation_id=op.id WHERE a.parent_operation_id='" + roots[0].required(0) + "'")
            expect(roots.size == 1 && children.size == 2 && source.field("root_operation_id").getOrThrow().text == roots[0].required(0),
                "AST edit has one actual Direct root and exactly two durable children")
            var sawProcess = false
            var sawPlan = false
            for (child in children) {
                let childPlan = DurableOperationStore(database).loadPlan(OperationId(child.required(0)), RunId(roots[0].required(1))).value().getOrThrow()
                expect(child.required(2) == "completed" && childPlan.effectClass == OperationEffectClass.ReadOnly &&
                    childPlan.networkPolicy.mode == NetworkPolicyMode.Denied && childPlan.requiredCapabilities.size == 1 &&
                    childPlan.requiredCapabilities[0].kind == CapabilityKind.WorkspaceRead,
                    "proposal children retain read-only authority, denied network and completed receipts")
                if (child.required(1) == "host.process.readonly") { sawProcess = true }
                if (child.required(1) == "host.file.plan.propose") {
                    sawPlan = true
                    expect(source.field("generation_operation_id").getOrThrow().text == child.required(0),
                        "plan source binds its actual generating Operation")
                }
            }
            expect(sawProcess && sawPlan && database.scalarInt("SELECT COUNT(*) FROM decision_operations d JOIN operations op ON op.id=d.operation_id " +
                "WHERE op.run_id='" + roots[0].required(1) + "'") == 0,
                "Direct plugin proposal does not fabricate a ModelDecision")

            let forgedArtifact = ProductArtifactStore(stateRoot, database: Some(database)).persistText(
                artifact.content.replace(supportRegistryDescriptor96(record,"namespace"), "axyndra:forged-origin")
            ).value().getOrThrow()
            let forged = product.vnext.executeCanonicalTool(SessionId("ast-edit-forged-origin"),
                CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead), Capability(CapabilityKind.WorkspaceWrite)]),
                ToolCall("ast-edit-forged-origin", "apply_file_plan", objectValue([
                    ValueField("plan_ref", textValue(forgedArtifact.reference)),
                    ValueField("plan_digest", textValue(forgedArtifact.sha256))
                ])))
            let forgedCode = match (forged) {
                case Result.Ok(ToolInvocationResult.Completed(value)) =>
                    if (!value.isError) {
                        throw IllegalStateException("forged plan returned success: " + canonicalAgentValue(value.output))
                    }
                    match (value.output.field("error")) {
                        case Some(code) => code.text
                        case None => throw IllegalStateException("forged plan has no typed error: " + canonicalAgentValue(value.output))
                    }
                case Result.Err(error) => throw IllegalStateException("forged plan failed outside canonical preparation: " + error.describe())
                case _ => throw IllegalStateException("forged plan did not return its canonical preparation error")
            }
            expect(forgedCode == "application_plan.origin_uncommitted",
                "a content-addressed artifact cannot forge the plan's completed plugin origin: " + forgedCode)
            expect(database.scalarInt("SELECT COUNT(*) FROM operations op JOIN runs r ON r.id=op.run_id " +
                "WHERE r.thread_id='ast-edit-forged-origin'") == 0 &&
                database.scalarInt("SELECT COUNT(*) FROM operation_receipts receipt JOIN operations op ON op.id=receipt.operation_id " +
                "JOIN runs r ON r.id=op.run_id WHERE r.thread_id='ast-edit-forged-origin'") == 0,
                "forged origin is rejected before an Operation, handoff or execution Receipt exists")
            expect(String.fromUtf8(File.readFrom(path)) == original, "forged plan rejection is filesystem-free")

            // Native root invocation currently requests explicit invocation
            // approval as a side effect. Preview under a granted test policy,
            // then reopen the same durable artifacts under the actual write
            // approval policy; do not relax either production registration.
            product.close()
            product = openProduct(config: ProductConfig(settingsRoot: root + "/ast-edit-plugin-settings",
                stateRoot: stateRoot, workspaceRoot: workspace, fixture: true, asyncEnabled: false,
                approvalMode: ApprovalMode.AlwaysAsk)).value().getOrThrow()

            let denied = product.vnext.executeCanonicalTool(SessionId("ast-edit-apply-denied"),
                CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
                ToolCall("ast-edit-apply-denied", "apply_file_plan", astPlanArguments(plan)))
            expect(match (denied) { case Result.Ok(ToolInvocationResult.Denied(_)) => true; case Result.Err(_) => true; case _ => false },
                "the plugin's read grant cannot apply its proposed plan")
            let rejected = astPlanApprovalSession(product, "ast-edit-reject", plan)
            expect(rejected.decide(rejected.approval().getOrThrow().operationId.value, ApprovalDecision.Reject).isOk() &&
                String.fromUtf8(File.readFrom(path)) == original, "rejected AST plan has no file effects")
            let cancelled = astPlanApprovalSession(product, "ast-edit-cancel", plan)
            expect(cancelled.cancel().isOk() && String.fromUtf8(File.readFrom(path)) == original,
                "cancelling pending AST plan approval does not write")
            let stale = astPlanApprovalSession(product, "ast-edit-stale", plan)
            File.writeTo(path, (original + "# concurrent edit\n").toArray())
            let staleResult = stale.decide(stale.approval().getOrThrow().operationId.value, ApprovalDecision.Approve)
            expect(staleResult.isError() && String.fromUtf8(File.readFrom(path)) == original + "# concurrent edit\n",
                "exact AST plan application rejects a changed file without overwriting it")
            File.writeTo(path, original.toArray())
            let recovered = product.vnext.executeCanonicalTool(SessionId("ast-edit-recover"),
                CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
                ToolCall("ast-edit-recover", "recover_file_plan", astPlanArguments(freshPlan)))
            let continuation = match (recovered) {
                case Result.Ok(ToolInvocationResult.Completed(value)) =>
                    expect(!value.isError, "AST plan recovery succeeds before any writes")
                    value.output.field("continuation_plan").getOrThrow()
                case Result.Err(error) => throw IllegalStateException("AST plan recovery failed: " + error.describe())
                case _ => throw IllegalStateException("AST plan recovery did not complete")
            }
            let continuationArtifact = ProductArtifactStore(stateRoot, database: Some(database)).read(
                continuation.field("plan_ref").getOrThrow().text, limit: 1048576).value().getOrThrow()
            let continuationSource = parseUnifiedJson(continuationArtifact.content).field("source").getOrThrow()
            let freshSource = freshPlan.field("source").getOrThrow()
            expect(continuationSource.field("kind").getOrThrow().text == "plugin" &&
                continuationSource.field("root_operation_id").getOrThrow().text == freshSource.field("root_operation_id").getOrThrow().text &&
                continuationSource.field("generation_operation_id").getOrThrow().text == freshSource.field("generation_operation_id").getOrThrow().text &&
                continuationSource.field("recovery_operation_id").getOrThrow().text != "" &&
                continuationSource.field("recovery_run_id").getOrThrow().text != "" &&
                String.fromUtf8(File.readFrom(path)) == original,
                "recovery preserves the plugin source and binds a new recovery operation without writes")
            let approved = astPlanApprovalSession(product, "ast-edit-approve", continuation)
            expect(approved.decide(approved.approval().getOrThrow().operationId.value, ApprovalDecision.Approve).isOk() &&
                String.fromUtf8(File.readFrom(path)) == replacement, "one-time approval publishes the exact AST replacement")
            let (applied, applyError) = productThreadToolResult(database, "ast-edit-approve", "ast-edit-approve")
            expect(!applyError && applied.field("applied").getOrThrow().asBool() &&
                applied.field("applied_count").getOrThrow().asNumberText() == "1", "AST application retains the normal per-file result and Receipt")
        } finally { database.close() }
        let _ = pluginAcquisitionRequireRecord(product.setPluginEnabled(supportRegistryDescriptor96(record,"id"), false,
            PluginInstallScope.Workspace), "disable AST edit package")
        expect(!productToolAvailable(product, tool) && !productToolAvailable(product, "ast_edit"),
            "disabling the package does not restore the deleted static AST editor")
    } finally { product.close() }
}

func runJavaScriptPluginServiceBrokerContract(root: String, workspace: String): Unit {
    runPluginServiceBrokerContract(root, workspace, false)
    runPluginServiceBrokerContract(root, workspace, true)
    runPluginServiceBrokerContract(root, workspace, true, directNative: true)
    runPluginServiceBrokerContract(root, workspace, false, directPi: true)
}

func runPluginServiceBrokerContract(root: String, workspace: String, native: Bool, directNative!: Bool = false, directPi!: Bool = false): Unit {
    let directRoot = directNative || directPi
    let caseName = if (directPi) { "direct-pi-service-broker" } else if (directNative) { "direct-native-service-broker" } else if (native) { "native-service-broker" } else { "javascript-service-broker" }
    let caseRoot = root + "/" + caseName
    let pluginRoot = caseRoot + "/plugin"
    let stateRoot = caseRoot + "/state"
    Directory.create(pluginRoot, recursive: true)
    File.writeTo(workspace + "/service-input.txt", "SERVICE_FIXTURE_SENTINEL\n".toArray())
    if (native) {
        let executable = getVariable("AXYNDRA_NATIVE_TOOL_PLUGIN_FIXTURE").getOrThrow()
        File.writeTo(pluginRoot + "/native-plugin-tool", File.readFrom(Path(executable)))
        let _ = pluginAcquisitionRunFixtureCommand("/bin/chmod", ["755", "native-plugin-tool"], pluginRoot)
        File.writeTo(pluginRoot + "/axyndra.plugin.json", (
            "{\"id\":\"" + caseName + "-contract\",\"version\":\"1.0.0\",\"entrypoint\":\"native-plugin-tool\"," +
            "\"entry_kind\":\"native-executable\",\"sdk_range\":\"[2.0.0,3.0.0)\"," +
            "\"protocol_range\":\"axyndra-js-host-v2\",\"capabilities\":[\"workspace.read\"]," +
            "\"contributions\":[{\"kind\":\"tool\",\"name\":\"echo\"}]}"
        ).toArray())
    } else {
        File.writeTo(pluginRoot + "/package.json",
            "{\"name\":\"javascript-service-contract\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"service.js\"],\"axyndra\":{\"capabilities\":[\"workspace.read\"]}}}".toArray())
    }
    let javascript = "import { Type } from 'typebox';\n" +
        "export default function (pi) {\n" +
        "  pi.registerTool({\n" +
        "    name: 'service', label: 'Service', description: 'Read the fixture through controlled host execution',\n" +
        "    parameters: Type.Object({}),\n" +
        "    execute: async (_toolCallId, _params, _signal, onUpdate, _context) => {\n" +
        "      onUpdate({ content: [{ type: 'text', text: 'calling-service' }], details: { phase: 'calling-service' } });\n" +
        "      const result = await pi.exec('cat', ['service-input.txt']);\n" +
        "      onUpdate({ content: [{ type: 'text', text: 'service-completed' }], details: { code: result.code } });\n" +
        "      return { content: [{ type: 'text', text: result.stdout }], details: { exit_code: result.code, stderr: result.stderr, killed: result.killed } };\n" +
        "    },\n" +
        "  });\n" +
        "}\n"
    if (!native) { File.writeTo(pluginRoot + "/service.js", javascript.toArray()) }
    let product = openProduct(config: ProductConfig(
        settingsRoot: caseRoot + "/settings",
        stateRoot: stateRoot,
        workspaceRoot: workspace,
        fixture: true,
        approvalMode: ApprovalMode.Yolo,
        asyncEnabled: false,
        extensionSignatureVerifier: if (native) { None } else { Some(FixedPluginSignatureVerifier(true)) }
    )).value().getOrThrow()
    try {
        let readonlyShell = NativeReadonlyShellContractBinding(product)
        let imported = product.importLocalPlugin(
            pluginRoot, PluginInstallScope.Workspace
        )
        let record = match (imported) {
            case PluginRegistryResult.Ok(value) => supportRegistryRecord96(value)
            case PluginRegistryResult.Err(error) =>
                throw IllegalStateException(error.code + ": " + supportRegistryExclusiveErrorText96(error))
        }
        let activated = product.setPluginEnabled(
            supportRegistryDescriptor96(record,"id"), true, PluginInstallScope.Workspace
        )
        match (activated) {
            case PluginRegistryResult.Ok(discard96) => supportRegistryDiscard96(discard96)
            case PluginRegistryResult.Err(error) => throw IllegalStateException(
                "activate imported JavaScript service plugin: " + error.code + ": " + supportRegistryExclusiveErrorText96(error)
            )
        }
        let toolName = "plugin." + supportRegistryDescriptor96(record,"namespace") + if (native) { ".echo" } else { ".service" }
        let rootArguments = if (native) {
            objectValue([ValueField("mode", textValue("service_read"))])
        } else { objectValue([]) }
        let sessionId = SessionId(caseName + "-contract")
        let progress = ArrayList<String>()
        if (directRoot) {
            let budget = ExecutionBudget(maxToolCalls: 3, maxConcurrentTools: 1)
            let result = product.vnext.executeCanonicalTool(sessionId,
                CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke),
                    Capability(CapabilityKind.WorkspaceRead)]),
                ToolCall(caseName + "-root-call", toolName, rootArguments), budget: budget)
            expect(match (result) {
                case Result.Ok(ToolInvocationResult.Completed(value)) => !value.isError &&
                    canonicalAgentValue(value.output).contains("SERVICE_FIXTURE_SENTINEL")
                case Result.Err(error) => throw IllegalStateException(error.describe())
                case _ => false
            }, "real Direct " + (if (directPi) { "Pi" } else { "native" }) + " root executes its read-only child through the broker")
            expect(budget.snapshot().toolCalls == 3 && budget.snapshot().activeTools == 0,
                "Direct root and child charge the same explicit three-call budget and settle the single slot")
        } else {
            product.fixtureProbe.getOrThrow().enqueueToolCallReply(
                caseName + "-root-call", toolName, rootArguments)
            let session = product.applicationSession(sessionId: Some(sessionId))
            session.subscribe({ event =>
                match (event.payload) {
                    case AgentEventPayload.ToolOutput(_, ToolOutputChannel.Progress, delta) => progress.add(delta)
                    case _ => ()
                }
            })
            let submitted = session.submit("Read the fixture through the plugin host service.")
            expect(submitted.isOk() && submitted.value().getOrThrow().snapshot.isSome() &&
                submitted.value().getOrThrow().snapshot.getOrThrow().status == RunState.Completed,
                "Product completes the " + caseName + " Tool trajectory")
        }
        var progressPublished = false
        for (delta in progress) {
            if (delta.contains("calling-service")) { progressPublished = true }
        }

        let database = SqliteDatabase(stateRoot + "/state.db")
        try {
            let sourceJoins = if (directRoot) {
                "JOIN items canonical ON canonical.id=op.tool_call_item_id "
            } else {
                "JOIN decision_operations source ON source.operation_id=op.id " +
                "JOIN canonical_decision_items canonical ON canonical.item_id=op.tool_call_item_id " +
                "AND canonical.decision_id=source.decision_id "
            }
            let rootRows = database.query(
                "SELECT run.id,op.id,op.tool_call_item_id FROM operations op " +
                    "JOIN runs run ON run.id=op.run_id " +
                    "JOIN operation_effect_records effect ON effect.operation_id=op.id " +
                    sourceJoins + "WHERE run.thread_id='" + sessionId.value + "' " +
                    "AND effect.tool_id='" + toolName + "' " +
                    "AND NOT EXISTS (SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=op.id)"
            )
            expect(rootRows.size == 1, "plugin service parent has one canonical Operation")
            if (directRoot) {
                let directRows = database.query("SELECT items.provenance FROM items " +
                    "WHERE items.id='" + rootRows[0].required(2) + "' " +
                    "AND NOT EXISTS (SELECT 1 FROM canonical_decision_items c WHERE c.item_id=items.id) " +
                    "AND NOT EXISTS (SELECT 1 FROM decision_operations d WHERE d.operation_id='" +
                    rootRows[0].required(1) + "')")
                expect(directRows.size == 1, "Direct root is durably distinct from ModelDecision and CommittedToolCall")
                let provenance = decodeStoredProvenance(directRows[0].required(0))
                expect(provenance.source == "direct_tool" &&
                    provenance.runId.getOrThrow().value == rootRows[0].required(0) &&
                    provenance.operationId.getOrThrow().value == rootRows[0].required(1),
                    "Direct Item provenance freezes its owning Run and Operation")
            }
            let runId = RunId(rootRows[0].required(0))
            let rootOperationId = rootRows[0].required(1)
            if (directPi) {
                let laneRows = database.query("SELECT lane_snapshot FROM runs WHERE id=?",
                    [SqlParameter.Text(runId.value)])
                expect(laneRows.size == 1, "actual Direct Pi Run persists one owned lane snapshot")
                let lane = modelLaneFromSnapshotValue(decodeStoredValue(laneRows[0].required(0)))
                expect(lane.toolSet.threadId.isSome() && lane.toolSet.threadId.getOrThrow().value == sessionId.value &&
                    lane.capabilities.tools, "Direct Pi lane freezes the actual same-thread published tool set")
                var hasRoot = false
                var hasExecTarget = false
                for (entry in lane.toolSet.entries) {
                    if (entry.name == toolName && entry.availableAtSnapshot && entry.executorVersion.contains(":instance:")) {
                        hasRoot = true
                    }
                    if (entry.name == readonlyShell.name && entry.availableAtSnapshot) { hasExecTarget = true }
                }
                expect(hasRoot && hasExecTarget, "actual Pi root instance and shell route are pinned in the same Run snapshot")
                expect(database.scalarInt("SELECT COUNT(*) FROM model_decisions") == 0 &&
                    database.scalarInt("SELECT COUNT(*) FROM model_attempts") == 0,
                    "Direct Pi root and derived OS child do not fabricate model authority")
            }
            let operationStore = DurableOperationStore(database)
            let rootPlan = operationStore.loadPlan(
                OperationId(rootOperationId), runId
            ).value().getOrThrow()
            var rootHasExtensionInvoke = false
            var rootHasWorkspaceRead = false
            for (required in rootPlan.requiredCapabilities) {
                if (required.kind == CapabilityKind.ExtensionInvoke) {
                    rootHasExtensionInvoke = true
                }
                if (required.kind == CapabilityKind.WorkspaceRead) {
                    rootHasWorkspaceRead = true
                }
            }
            let childRows = database.query(
                "SELECT admission.operation_id,admission.call_sequence,child.state," +
                    "receipt.outcome,effect.tool_id,effect.reserved_result_item_id," +
                    "admission.request_key,child.tool_call_item_id " +
                    "FROM derived_operation_admissions admission " +
                    "JOIN operations child ON child.id=admission.operation_id " +
                    "JOIN operation_receipts receipt ON receipt.operation_id=child.id " +
                    "JOIN operation_effect_records effect ON effect.operation_id=child.id " +
                    "WHERE admission.parent_operation_id='" + rootOperationId + "'"
            )
            let childEvidence = if (childRows.isEmpty()) {
                "rows=" + childRows.size.toString()
            } else {
                "rows=" + childRows.size.toString() +
                    ",sequence=" + childRows[0].required(1) +
                    ",state=" + childRows[0].required(2) +
                    ",outcome=" + childRows[0].required(3) +
                    ",tool=" + childRows[0].required(4) +
                    ",result_item=" + childRows[0].required(5)
            }
            let rootReceiptRows = database.query(
                "SELECT outcome,detail FROM operation_receipts WHERE operation_id='" +
                    rootOperationId + "'"
            )
            let rootReceiptEvidence = if (rootReceiptRows.isEmpty()) {
                "root_receipt=missing"
            } else {
                "root_outcome=" + rootReceiptRows[0].required(0) +
                    ",root_detail=" + rootReceiptRows[0].required(1)
            }
            let allAdmissions = database.query(
                "SELECT operation_id,parent_operation_id,call_sequence " +
                    "FROM derived_operation_admissions"
            )
            let admissionEvidence = if (allAdmissions.isEmpty()) {
                "admissions=0"
            } else {
                "admissions=" + allAdmissions.size.toString() +
                    ",first_parent=" + allAdmissions[0].required(1) +
                    ",first_child=" + allAdmissions[0].required(0)
            }
            expect(childRows.size == 1 && childRows[0].required(1) == "1" &&
                childRows[0].required(2) == "committed" &&
                childRows[0].required(3) == "completed" &&
                childRows[0].required(4) == readonlyShell.name &&
                childRows[0].required(5) != "" &&
                childRows[0].required(6).startsWith("javascript-service:" + caseName + "-root-call:") &&
                childRows[0].required(7) == rootRows[0].required(2),
                "exec service persists one completed ordinary Native child Operation, admission, Receipt, and result Item; actual=" +
                    childEvidence + "; " + rootReceiptEvidence + "; " + admissionEvidence)
            let childOperationId = OperationId(childRows[0].required(0))
            let childPlan = operationStore.loadPlan(childOperationId, runId)
                .value().getOrThrow()
            var childWorkspaceReadCount: Int64 = 0
            var childHasUnexpectedCapability = false
            for (required in childPlan.requiredCapabilities) {
                if (required.kind == CapabilityKind.WorkspaceRead) {
                    childWorkspaceReadCount += 1
                } else if (required.kind != CapabilityKind.ExtensionInvoke || required.resource != readonlyShell.name) {
                    childHasUnexpectedCapability = true
                }
            }
            readonlyShell.requireCompletedBrokerTree(database, runId, rootOperationId)
            let receipt = operationStore.loadDerivedOperationReceipt(
                childOperationId, runId
            ).value().getOrThrow()
            let observedFixtureOutput = match (receipt) {
                case Some(value) => canonicalAgentValue(value.detail)
                    .contains("SERVICE_FIXTURE_SENTINEL")
                case None => false
            }
            expect(rootHasExtensionInvoke && rootHasWorkspaceRead,
                "plugin parent plan freezes ExtensionInvoke and explicit WorkspaceRead authority")
            expect(childPlan.effectClass == OperationEffectClass.ReadOnly &&
                childPlan.networkPolicy.mode == NetworkPolicyMode.Denied &&
                childWorkspaceReadCount >= 1 && !childHasUnexpectedCapability,
                "exec service child retains read-only effect, denied network, and each exact frozen resource and its own QName")
            expect((native || directPi || progressPublished) && observedFixtureOutput,
                caseName + " child Receipt records the workspace result and Pi progress remains visible; progress_count=" +
                    progress.size.toString() + "; progress_published=" +
                    progressPublished.toString() + "; receipt_contains_fixture=" +
                    observedFixtureOutput.toString())
        } finally {
            database.close()
        }
        if (directNative) {
            // The old two-call successful shortcut is physically retired. The
            // actual Native child and worker remain separately charged. This
            // exact budget refuses before any worker execution handoff.
            let twoCallBudget = ExecutionBudget(maxToolCalls: 2, maxConcurrentTools: 1)
            let twoCallSession = SessionId(caseName + "-two-call-budget-denied")
            let twoCallResult = product.vnext.executeCanonicalTool(twoCallSession,
                CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke), Capability(CapabilityKind.WorkspaceRead)]),
                ToolCall("direct-two-call-root", toolName, rootArguments), budget: twoCallBudget)
            expect(match (twoCallResult) { case Result.Ok(ToolInvocationResult.Completed(value)) => value.isError
                case Result.Err(_) => true; case _ => false }, "original two-call ceiling cannot execute a third actual worker")
            expect(twoCallBudget.snapshot().toolCalls == 2 && twoCallBudget.snapshot().activeTools == 0,
                "no implicit tool-call budget expansion and the actual owner slot settles")
            let boundedDb = SqliteDatabase(stateRoot + "/state.db")
            try {
                expect(boundedDb.query("SELECT id FROM runs WHERE thread_id=? AND state='completed'",[SqlParameter.Text(twoCallSession.value)]).isEmpty(),
                    "exhausted readonly subtree cannot become a successful Run")
                expect(boundedDb.query("SELECT audit.id FROM audit_events audit JOIN operations op ON op.id=audit.operation_id "+
                    "JOIN runs run ON run.id=op.run_id JOIN operation_effect_records e ON e.operation_id=op.id "+
                    "WHERE run.thread_id=? AND e.tool_id=? AND audit.kind='operation_execution_handoff'",
                    [SqlParameter.Text(twoCallSession.value), SqlParameter.Text(HOST_READ_VIEW_TOOL)]).isEmpty(),
                    "the unbudgeted worker has no canonical execution handoff")
            } finally { boundedDb.close() }
            let exhausted = ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1)
            let limitedSession = SessionId(caseName + "-budget-denied")
            let limited = product.vnext.executeCanonicalTool(limitedSession,
                CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke),
                    Capability(CapabilityKind.WorkspaceRead)]),
                ToolCall("direct-budget-child", toolName, rootArguments), budget: exhausted)
            expect(match (limited) {
                case Result.Ok(ToolInvocationResult.Completed(value)) => value.isError
                case Result.Err(_) => true
                case _ => false
            }, "Direct broker cannot exceed the parent tool-call ceiling")
            expect(exhausted.snapshot().toolCalls == 1 && exhausted.snapshot().activeTools == 0,
                "budget rejection restores the direct slot without spending a child call")
            let check = SqliteDatabase(stateRoot + "/state.db")
            try {
                expect(check.query("SELECT a.operation_id FROM derived_operation_admissions a " +
                    "JOIN operations o ON o.id=a.operation_id JOIN runs r ON r.id=o.run_id " +
                    "WHERE r.thread_id='" + limitedSession.value + "'").isEmpty(),
                    "budget rejection occurs before any child Operation admission")
            } finally { check.close() }
            // A broker result can carry is_error while the native root
            // successfully returns that structured response to its caller.
            remove(workspace + "/service-input.txt")
            let failedChildSession = SessionId(caseName + "-failed-child")
            try {
                let failedChild = product.vnext.executeCanonicalTool(failedChildSession,
                    CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke),
                        Capability(CapabilityKind.WorkspaceRead)]),
                    ToolCall("direct-failed-child", toolName, rootArguments))
                expect(match (failedChild) {
                    case Result.Ok(ToolInvocationResult.Completed(value)) =>
                        canonicalAgentValue(value.output).contains("is_error")
                    case Result.Err(error) => throw IllegalStateException(error.describe())
                    case _ => false
                }, "Direct caller receives the structured failing child result")
                let failedDb = SqliteDatabase(stateRoot + "/state.db")
                try {
                    let failedRuns = failedDb.query("SELECT state FROM runs WHERE thread_id='" +
                        failedChildSession.value + "'")
                    expect(failedRuns.size == 1 && failedRuns[0].required(0) == "failed",
                        "a failed child prevents a successfully returning Direct parent from completing the Run")
                    expect(failedDb.scalarInt("SELECT COUNT(*) FROM operation_receipts receipt " +
                        "JOIN operations op ON op.id=receipt.operation_id JOIN runs run ON run.id=op.run_id " +
                        "WHERE run.thread_id='" + failedChildSession.value + "'") == 3,
                        "the Direct parent, failed Native child and completed resource worker all retain their actual durable receipts")
                } finally { failedDb.close() }
            } finally {
                File.writeTo(workspace + "/service-input.txt", "SERVICE_FIXTURE_SENTINEL\n".toArray())
            }
            let spent = ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1)
            spent.reserve(BudgetCharge(toolCalls: 1)).value().getOrThrow()
            let spentSession = SessionId(caseName + "-root-budget-denied")
            let spentResult = product.vnext.executeCanonicalTool(spentSession,
                CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke),
                    Capability(CapabilityKind.WorkspaceRead)]),
                ToolCall("direct-spent-root", toolName, rootArguments), budget: spent)
            let spentDescription = match (spentResult) {
                case Result.Err(error) => error.describe()
                case Result.Ok(ToolInvocationResult.Completed(value)) =>
                    "completed is_error=" + value.isError.toString() + ";output=" + canonicalAgentValue(value.output)
                case _ => "non-terminal invocation result"
            }
            let spentDb = SqliteDatabase(stateRoot + "/state.db")
            try {
                let settled = spentDb.query("SELECT o.state,r.outcome,r.verification,r.detail,run.state FROM operations o " +
                    "JOIN operation_receipts r ON r.operation_id=o.id JOIN runs run ON run.id=o.run_id " +
                    "WHERE run.thread_id='" + spentSession.value + "'")
                let evidence = if (settled.isEmpty()) { "no receipt" } else {
                    "operation=" + settled[0].required(0) + ";outcome=" + settled[0].required(1) +
                        ";verification=" + settled[0].required(2) + ";detail=" + settled[0].required(3) +
                        ";run=" + settled[0].required(4)
                }
                expect(match (spentResult) {
                    case Result.Err(error) => error.code == "budget.tool_calls_exceeded"
                    case _ => false
                }, "already exhausted Direct budget rejects before executor handoff; actual=" +
                    spentDescription + "; durable=" + evidence)
                // Canonical result commit uses committed for every known
                // outcome; the Receipt and Run retain the actual failure.
                expect(settled.size == 1 && settled[0].required(0) == "committed" &&
                    settled[0].required(1) == "failed" && settled[0].required(4) == "failed" &&
                    decodeStoredValue(settled[0].required(2)).field("stage").getOrThrow().text == "prepared" &&
                    decodeStoredValue(settled[0].required(3)).field("code").getOrThrow().text == "budget.tool_calls_exceeded",
                    "pre-handoff budget failure commits a known failed receipt without unknown effects; actual=" + evidence)
                expect(spentDb.query("SELECT id FROM audit_events WHERE thread_id='" + spentSession.value +
                    "' AND kind='operation_execution_handoff'").isEmpty() &&
                    spentDb.query("SELECT a.operation_id FROM derived_operation_admissions a " +
                        "JOIN operations o ON o.id=a.operation_id JOIN runs run ON run.id=o.run_id " +
                        "WHERE run.thread_id='" + spentSession.value + "'").isEmpty(),
                    "root budget rejection creates neither an execution handoff nor a child admission")
                expect(spentDb.query("SELECT id FROM threads WHERE id='" + spentSession.value +
                    "' AND active_turn_id IS NOT NULL").isEmpty(),
                    "pre-handoff rejection leaves no active Thread or unresolved canonical ToolCall")
            } finally { spentDb.close() }
        }
    } finally {
        product.close()
    }
}
main(): Int64 {
    let tempRoot = match (getVariable("TMPDIR")) {
        case Some(value) => value
        case None => "/tmp"
    }
    let root = Directory.createTemp(tempRoot).toString()
    try {
        let workspace = root + "/workspace"
        Directory.create(workspace, recursive: true)
        if (workerArguments.contains("--ast-plugin-contract")) {
            runAstPluginContract(root, workspace)
            println("independent AST plugin contract passed")
            return 0
        }
        if (workerArguments.contains("--ast-edit-plugin-contract")) {
            runAstEditPluginContract(root, workspace)
            println("independent AST edit plugin contract passed")
            return 0
        }
        if (workerArguments.contains("--direct-pi-service-snapshot-contract")) {
            runPluginServiceBrokerContract(root, workspace, false, directPi: true)
            println("actual Direct Pi service snapshot contract passed")
            return 0
        }
        if (workerArguments.contains("--javascript-service-broker-contract")) {
            runJavaScriptPluginServiceBrokerContract(root, workspace)
            println("plugin service broker contract passed")
            return 0
        }
        if (workerArguments.contains("--plugin-acquisition-contract")) {
            runPluginAcquisitionControlContract(root, workspace)
            println("plugin acquisition contract passed")
            return 0
        }
        File.writeTo(workspace + "/input.txt", "durable tool input\n".toArray())
        Directory.create(workspace + "/src", recursive: true)
        let alphaSource = "fn alpha() {}\n// SymbolAnchor: alpha\n"
        File.writeTo(workspace + "/src/alpha.cj", alphaSource.toArray())
        File.writeTo(workspace + "/src/beta.cj", "fn beta() {}\n\n// SymbolAnchor: beta\n".toArray())
        runJavaScriptPluginServiceBrokerContract(root, workspace)
        runPluginAcquisitionControlContract(root, workspace)
        runAstPluginContract(root, workspace)
        runAstEditPluginContract(root, workspace)
        let stateRoot = root + "/state"
        let product = openProduct(config: ProductConfig(
            settingsRoot: root + "/settings",
            stateRoot: stateRoot,
            workspaceRoot: workspace,
            fixture: true,
            asyncEnabled: false,
            extensionSignatureVerifier: Some(FixedPluginSignatureVerifier(true)),
            compactionOverride: Some(ProductCompactionSettings(
                keepRecentMessages: 2
            ))
        )).value().getOrThrow()
        let programBinding = NativeProgramContractBinding(product)
        let sessionId = SessionId("durable-product-thread")
        let result = product.applicationSession(sessionId: Some(sessionId))
            .submit("persist the canonical owner")
        let firstRunState = match (result) {
            case Result.Ok(response) => match (response.snapshot) {
                case Some(snapshot) => runStateName(snapshot.status)
                case None => "missing_snapshot"
            }
            case Result.Err(error) => "error:" + error.code + ":" + error.message
        }
        expect(result.isOk() && result.value().getOrThrow().snapshot.isSome() &&
            result.value().getOrThrow().snapshot.getOrThrow().status == RunState.Completed,
            "fixture product completes its Run; actual=" + firstRunState)
        let toolSessionId = SessionId("durable-product-tool-thread")
        product.fixtureProbe.getOrThrow().enqueueToolCallReply("fixture-vnext-native-read",
            programBinding.workspaceName("read"),objectValue([ValueField("path",textValue("input.txt"))]))
        let toolResult = product.applicationSession(sessionId: Some(toolSessionId))
            .submit("fixture vnext read")
        expect(toolResult.isOk() && toolResult.value().getOrThrow().snapshot.isSome() &&
            toolResult.value().getOrThrow().snapshot.getOrThrow().status == RunState.Completed,
            "fixture product completes a canonical Tool trajectory")
        expect(product.compactSession(toolSessionId).value().getOrThrow() > 0,
            "product compaction creates a disposable canonical checkpoint")
        let resumed = product.applicationSession(sessionId: Some(toolSessionId))
            .submit("continue after checkpoint")
        expect(resumed.isOk() && match (product.fixtureProbe.getOrThrow().lastRequest) {
            case Some(request) => !request.messages.isEmpty() &&
                request.messages[0].blocks[0].text.startsWith(
                    "[Compacted canonical Thread through Item"
                )
            case None => false
        }, "next Turn projects checkpoint plus high-fidelity suffix")
        let productContext = InvocationContextProjection(contributions: [InvocationContextContribution(
            "contract.context", "product-review", "context://product-review",
            "Use the Product immutable context contract.", ContextContentTrust.UserSelected)])
        let skillResult = product.client.start(
            product.request(
                "run active skill",
                sessionId: Some(SessionId("durable-product-skill-thread")),
                contextSnapshot: Some(productContext)
            ),
            {_ => ()}
        )
        expect(skillResult.isOk() && match (product.fixtureProbe.getOrThrow().lastRequest) {
            case Some(request) => request.system.contains("<run_context ") &&
                request.system.contains("Use the Product immutable context contract.")
            case None => false
        }, "Product freezes explicit generic context into the Run")
        let pageEvent = product.appCommand(AppCommand(
            AppCommandMeta(AppCommandId("contract-page"), 1),
            AppCommandPayload.LoadItemsPage(ThreadId(sessionId.value), 0, 16)
        ))
        expect(match (pageEvent) {
            case Result.Ok(event) => match (event.payload) {
                case AppEventPayload.ItemsPage(page) =>
                    page.threadId.value == sessionId.value && page.items.size == 2 &&
                    event.meta.threadRevision == page.threadRevision
                case _ => false
            }
            case Result.Err(_) => false
        }, "Product serves canonical Thread pages through the typed App Protocol")
        let inspectedRunId = toolResult.value().getOrThrow().snapshot.getOrThrow().runId
        let inspectionEvent = product.appCommand(AppCommand(
            AppCommandMeta(AppCommandId("contract-inspection"), 2),
            AppCommandPayload.InspectRun(
                ThreadId(toolSessionId.value), inspectedRunId, 0, 25
            )
        ))
        expect(match (inspectionEvent) {
            case Result.Ok(event) => match (event.payload) {
                case AppEventPayload.RunInspection(page) =>
                    page.threadId.value == toolSessionId.value &&
                    page.runId.value == inspectedRunId.value &&
                    page.runState == "completed" &&
                    page.threadRevision == event.meta.threadRevision &&
                    page.compositionDigest.size == 64 &&
                    !page.contexts.isEmpty() &&
                    !page.modelRequests.isEmpty() &&
                    !page.operations.isEmpty() &&
                    page.modelRequests[0].attemptId != page.modelRequests[0].requestId &&
                    page.modelRequests[0].usageSource != "" &&
                    page.history.checkpointId == "" &&
                    page.modelRequests[0].semanticRequestDigest.size == 64 &&
                    page.modelRequests[0].wirePolicyDigest.size == 64 &&
                    page.operations[0].effectiveArgumentsDigest.size == 64 &&
                    event.meta.runId.isNone()
                case _ => false
            }
            case Result.Err(_) => false
        }, "older Run inspection exposes provider request and attempt identities")
        let resumedRunId = resumed.value().getOrThrow().snapshot.getOrThrow().runId
        let resumedInspectionEvent = product.appCommand(AppCommand(
            AppCommandMeta(AppCommandId("contract-inspection-resumed"), 3),
            AppCommandPayload.InspectRun(
                ThreadId(toolSessionId.value), resumedRunId, 0, 25
            )
        ))
        expect(match (resumedInspectionEvent) {
            case Result.Ok(event) => match (event.payload) {
                case AppEventPayload.RunInspection(page) =>
                    page.runId.value == resumedRunId.value &&
                    page.history.checkpointId != ""
                case _ => false
            }
            case Result.Err(_) => false
        }, "Run inspection loads the checkpoint frozen into that Run's context manifest")
        let slashRunId = product.latestRunId(ThreadId(toolSessionId.value)).value().getOrThrow()
        let inspectionSlash = product.applicationSession(sessionId: Some(toolSessionId)).handle("/inspect")
        expect(inspectionSlash.isOk() && inspectionSlash.value().getOrThrow().text.contains(
            "Run " + slashRunId.value
        ) && inspectionSlash.value().getOrThrow().text.contains("Model requests") &&
            inspectionSlash.value().getOrThrow().text.contains("Operations (newest first)"),
            "shared slash diagnostics render canonical Run evidence")
        expect(!product.appCommand(AppCommand(
            AppCommandMeta(
                AppCommandId("stale-page"),
                2,
                expectedThreadRevision: Some(0)
            ),
            AppCommandPayload.LoadItemsPage(ThreadId(sessionId.value), 0, 16)
        )).isOk(), "App Protocol rejects a stale expected Thread revision")
        let seededSession = SessionId("durable-product-seed-thread")
        expect(product.replaceMessages(seededSession, [
            ModelMessage(ModelRole.User, [
                ModelBlock(ModelBlockKind.Text, text: "seeded user history")
            ]),
            ModelMessage(ModelRole.Assistant, [
                ModelBlock(ModelBlockKind.Unknown, text: "durable system note")
            ])
        ]).isOk(), "Product creates offline canonical history through the seed boundary")
        expect(product.replaceMessages(seededSession, [
            ModelMessage(ModelRole.User, [
                ModelBlock(ModelBlockKind.Text, text: "must not overwrite")
            ])
        ]).isError(), "Product cannot replace an existing canonical Thread")
        let forkedSession = SessionId("durable-product-fork-thread")
        expect(product.forkSession(seededSession, forkedSession).isOk(),
            "Product fork clones canonical Items without a provider DTO round trip")
        expect(product.replaceMessages(
            SessionId("durable-product-invalid-seed"),
            [ModelMessage(ModelRole.Assistant, [
                ModelBlock(ModelBlockKind.Text, text: "assistant first")
            ])]
        ).isError(), "Product rejects invalid offline transcript ownership")

        let queuedApplication = product.applicationSession(sessionId: Some(sessionId))
        expect(queuedApplication.enqueue(
            "persisted-steering", "steer", "inspect the durable boundary"
        ).isOk() && match (queuedApplication.withdrawQueued("persisted-steering")) {
            case Result.Ok(QueuedWithdrawal.Withdrawn(_)) => true
            case _ => false
        } && queuedApplication.enqueue(
            "persisted-follow-up", "follow_up", "continue after recovery"
        ).isOk(),
            "Product Application writes queued interactions through the durable Lane Inbox")
        let deliveredSession = SessionId("durable-delivered-interaction")
        let deliveredApplication = product.applicationSession(
            sessionId: Some(deliveredSession)
        )
        expect(deliveredApplication.enqueue(
            "delivered-follow-up", "follow_up", "second durable intent"
        ).isOk() && deliveredApplication.submit("first durable intent").isOk(),
            "queued follow-up is consumed inside a live Product Run")

        isolatedPluginHostContract(workspace, root + "/settings")
        expect(product.vnext.validateIsolatedExtension(
            SignedExtensionPackageManifest(
                "product.signed", "1", "1", "1", "plugins/signed.wasm",
                [], [], [], 1u32, "compatible", "sha256:signed", "signature"
            ),
            ExtensionExecutionKind.WasmComponent, 1u64, []
        ).isOk(),
            "Product validates extension packages only through its configured trust root")

        let remoteTransport = ProductRecordingRemoteTransport()
        let remoteRealm = RemoteExecutionRealm(
            "product-worker", "https://worker.invalid/rpc", "product-worker-key",
            "product-worker-fs", "product-worker-process"
        )
        let remoteEnvelope = sealRemoteCapabilityEnvelope(
            SignedRemoteCapabilityEnvelope(
                "product-envelope", RunId("missing-remote-run"), LaneId("main"),
                remoteRealm.id, CapabilitySet(), 10, 30, "nonce"
            ),
            "signature"
        )
        expect(product.vnext.routeRemote(
            RemoteExecutionRouter(
                remoteRealm, CapabilitySet(), ProductRemoteVerifier(), remoteTransport
            ),
            remoteEnvelope,
            RemoteExecutionRequest(
                OperationId("missing-remote-operation"), RemoteServiceKind.Process,
                objectValue([]), "lane:main"
            ),
            20
        ).isError() && remoteTransport.dispatches == 0,
            "Product remote effects cannot bypass durable Operation admission")

        let mainBranch = product.vnext.laneBranch(
            ThreadId(sessionId.value), LaneId("main")
        ).value().getOrThrow()
        let reviewLane = LaneRecord(
            LaneId("review"), ThreadId(sessionId.value),
            LaneKind.SharedHistoryChild,
            objectValue([ValueField("profile", textValue("review"))]),
            parentLaneId: Some(LaneId("main")),
            forkItemId: Some(mainBranch[0]),
            createdAtMillis: 20
        )
        expect(product.vnext.createSharedHistoryLane(reviewLane).isOk() &&
            product.vnext.laneBranch(
                ThreadId(sessionId.value), LaneId("review")
            ).value().getOrThrow().size == 1,
            "Product exposes durable shared-history Lane creation and branch projection")

        let laneExecutionSession = SessionId("durable-product-review-execution")
        expect(product.client.start(product.request(
            "seed the review execution branch",
            sessionId: Some(laneExecutionSession)
        ), {_ => ()}).isOk(), "Product seeds a canonical main Lane before branching")
        let laneExecutionMain = product.vnext.laneBranch(
            ThreadId(laneExecutionSession.value), LaneId("main")
        ).value().getOrThrow()
        expect(product.vnext.createSharedHistoryLane(LaneRecord(
            LaneId("review"), ThreadId(laneExecutionSession.value),
            LaneKind.SharedHistoryChild,
            objectValue([ValueField("profile", textValue("review"))]),
            parentLaneId: Some(LaneId("main")),
            forkItemId: Some(laneExecutionMain[laneExecutionMain.size - 1]),
            createdAtMillis: 30
        )).isOk(), "Product creates the non-main execution Lane")
        let reviewExecutionRequest = product.request(
            "execute the complete model step on review",
            sessionId: Some(laneExecutionSession),
            executionLaneId: LaneId("review")
        )
        expect(product.client.start(reviewExecutionRequest, {_ => ()}).isOk(),
            "Product executes AgentCore through an explicit non-main Lane")

        let corruptQueueSession = SessionId("durable-product-corrupt-queue")
        expect(product.client.start(product.request(
            "seed the corrupt queue recovery fixture",
            sessionId: Some(corruptQueueSession)
        ), {_ => ()}).isOk(), "Product seeds a Thread for queued recovery evidence")
        let corruptEntryId = scopedInboxEntryId(
            ThreadId(corruptQueueSession.value), LaneId("main"), "corrupt-payload"
        )
        expect(product.vnext.enqueueLaneInput(DurableInboxEntry(
            corruptEntryId, ThreadId(corruptQueueSession.value), LaneId("main"),
            InboxEntryKind.Steering,
            objectValue([ValueField("correlation_id", textValue("corrupt-payload"))])
        )).isOk() && product.applicationSession(
            sessionId: Some(corruptQueueSession)
        ).resumeStartup().isError(),
            "corrupt durable queued input fails startup recovery instead of being ignored")
        let mainAdmission = product.vnext.acquireLaneRun(
            ThreadId(sessionId.value), LaneId("main"), RunId("product-main-lane-run"),
            "product-main-actor", 100, leaseMillis: 1000
        ).value().getOrThrow()
        let reviewAdmission = product.vnext.acquireLaneRun(
            ThreadId(sessionId.value), LaneId("review"), RunId("product-review-lane-run"),
            "product-review-actor", 100, leaseMillis: 1000
        ).value().getOrThrow()
        expect(product.vnext.acquireLaneRun(
            ThreadId(sessionId.value), LaneId("review"), RunId("product-review-race"),
            "product-review-racer", 100, leaseMillis: 1000
        ).isError() && mainAdmission.fenceToken == 1 &&
            reviewAdmission.fenceToken == 1,
            "Product admits different Lane actors concurrently but fences one Run per Lane")
        product.vnext.releaseLaneRun(mainAdmission, 110).value().getOrThrow()
        product.vnext.releaseLaneRun(reviewAdmission, 110).value().getOrThrow()
        let isolatedFork = product.vnext.forkThread(
            ThreadId(sessionId.value), LaneId("main"),
            mainBranch[mainBranch.size - 1], ThreadId("product-isolated-child"),
            "isolated-workspace", 20
        )
        expect(isolatedFork.isOk() &&
            isolatedFork.value().getOrThrow().size == mainBranch.size &&
            product.vnext.laneBranch(
                ThreadId("product-isolated-child"), LaneId("main")
            ).value().getOrThrow().size == mainBranch.size,
            "Product ForkThread freezes a Lane prefix into an isolated durable Thread")
        let team = TeamRecord(
            TeamId("product-team"), ThreadId(sessionId.value), LaneId("main"),
            "Product review", createdAtMillis: 21
        )
        let coordinator = TeamMemberRecord(
            TeamMemberId("product-coordinator"), team.id,
            ThreadId(sessionId.value), LaneId("main"), "coordinator",
            joinedAtMillis: 22
        )
        let reviewer = TeamMemberRecord(
            TeamMemberId("product-reviewer"), team.id,
            ThreadId(sessionId.value), LaneId("review"), "reviewer",
            joinedAtMillis: 23
        )
        expect(product.vnext.createTeam(team).isOk() &&
            product.vnext.addTeamMember(coordinator).isOk() &&
            product.vnext.addTeamMember(reviewer).isOk() &&
            product.vnext.teamRoster(team.id).value().getOrThrow().size == 2,
            "Product exposes the durable Team roster on real Thread Lanes")
        let storageLease = product.vnext.storageService.acquire(
            ComponentScope(RealmKind.Host, "product-host")
        ).value().getOrThrow()
        expect(storageLease.value == "sqlite-vnext",
            "Product resolves its semantic store through the typed host ServiceRegistry")
        storageLease.release()

        let programSessionId = SessionId("durable-product-program-thread")
        let programSource =
            "const search = await tools.grep({\"pattern\":\"SymbolAnchor\",\"path\":\"src\",\"count\":true});\n" +
            "const files = search.files;\n" +
            "const alpha = await tools.read({\"path\":\"src/alpha.cj\",\"offset\":1,\"limit\":3});\n" +
            "const beta = await tools.read({\"path\":\"src/beta.cj\",\"offset\":1,\"limit\":3});\n" +
            "const selected = files.filter(x => x.count);\n" +
            "const paths = selected.map(x => x.path);\n" +
            "return paths;"
        runMatchedProductWorkflowContract(product, stateRoot, programSource,programBinding)
        runProductFileApplicationPlanContracts(
            root, workspace, stateRoot, product
        )
        product.fixtureProbe.getOrThrow().enqueueToolCallReply(
            "fixture-program-root-call",
            programBinding.name,
            objectValue([ValueField("code", textValue(programSource))])
        )
        let programResult = product.applicationSession(
            sessionId: Some(programSessionId)
        ).submit("Find SymbolAnchor definitions, read both files, and summarize matching paths.")
        let programRunState = match (programResult) {
            case Result.Ok(response) => match (response.snapshot) {
                case Some(snapshot) => runStateName(snapshot.status)
                case None => "missing_snapshot"
            }
            case Result.Err(error) => "error:" + error.code + ":" + error.message
        }
        expect(programResult.isOk() && programResult.value().getOrThrow().snapshot.isSome() &&
            programResult.value().getOrThrow().snapshot.getOrThrow().status == RunState.Completed,
            "Product executes model-selected read-only PTC through AgentCore and the independent worker; actual=" +
                programRunState)
        let firstProgramRunId = programResult.value().getOrThrow().snapshot.getOrThrow().runId.value
        let programInspection = product.runInspection(
            ThreadId(programSessionId.value), RunId(firstProgramRunId), beforeCursor: 0, limit: 25
        )
        expect(programInspection.isOk() && programInspection.value().getOrThrow().operations.any({ operation =>
            operation.toolName == programBinding.name &&
                operation.programSdk == "program-language-v1/native-readonly-v1" &&
                operation.programArtifactHash.size == 64 &&
                operation.effectiveArgumentsDigest.size == 64
        }), "Run inspection explains Program SDK, content identity and canonical arguments without source text")
        product.fixtureProbe.getOrThrow().enqueueToolCallReply(
            "fixture-program-rerun-root-call",
            programBinding.name,
            objectValue([ValueField("code", textValue(programSource))])
        )
        let rerunSessionId = SessionId("durable-product-program-rerun-thread")
        let firstProgramRerun = product.applicationSession(
            sessionId: Some(rerunSessionId)
        ).submit("Run the same read-only Program.")
        let firstRerunRunId = match (firstProgramRerun) {
            case Result.Ok(response) => match (response.snapshot) {
                case Some(snapshot) =>
                    if (snapshot.status == RunState.Completed) {
                        snapshot.runId.value
                    } else {
                        ""
                    }
                case None => ""
            }
            case Result.Err(_) => ""
        }
        expect(
            firstRerunRunId != "" && firstRerunRunId != firstProgramRunId,
            "Program execution in a new Thread completes with a fresh Run ID"
        )
        product.fixtureProbe.getOrThrow().enqueueToolCallReply(
            "fixture-program-rerun-root-call-second",
            programBinding.name,
            objectValue([ValueField("code", textValue(programSource))])
        )
        let programRerun = product.applicationSession(
            sessionId: Some(rerunSessionId)
        ).submit("Run the same read-only Program again in this Thread.")
        let programRerunIdentity = match (programRerun) {
            case Result.Ok(response) => match (response.snapshot) {
                case Some(snapshot) =>
                    if (snapshot.status == RunState.Completed &&
                        firstRerunRunId != "" &&
                        snapshot.runId.value != firstRerunRunId &&
                        snapshot.runId.value != firstProgramRunId) {
                        "completed_with_new_run_identity"
                    } else {
                        "invalid_run_identity:" + snapshot.runId.value
                    }
                case None => "missing_snapshot"
            }
            case Result.Err(error) => "error:" + error.code + ":" + error.message
        }
        expect(
            programRerunIdentity == "completed_with_new_run_identity",
            "re-running a completed Program in the same Thread starts a new Run identity; actual=" +
                programRerunIdentity
        )
        let directProgramBypass = product.vnext.executeCanonicalTool(
            SessionId("durable-product-direct-program-bypass"),
            CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
            ToolCall(
                "direct-program-bypass",
                programBinding.name,
                objectValue([ValueField("code", textValue("return 1;"))])
            )
        )
        expect(match (directProgramBypass) {
            case Result.Err(error) => error.code == "tool.capability_denied"
            case _ => false
        }, "run_program cannot bypass the committed AgentCore root through direct control calls")
        let partialProgramSessionId = SessionId("durable-product-program-partial")
        let partialProgramSource =
            "const first = await tools.read({\"path\":\"src/alpha.cj\"});\n" +
            "const denied = await tools.write({\"path\":\"src/e3-06-denied.cj\",\"content\":\"must not be written\"});\n" +
            "return first;"
        product.fixtureProbe.getOrThrow().enqueueToolCallReply(
            "fixture-program-partial-root-call",
            programBinding.name,
            objectValue([ValueField("code", textValue(partialProgramSource))])
        )
        let partialProgramResponse = product.applicationSession(
            sessionId: Some(partialProgramSessionId)
        ).submit("Read an available file and then a missing file in a Program.")
        let partialProgramRunId = match (partialProgramResponse) {
            case Result.Ok(response) => match (response.snapshot) {
                case Some(snapshot) => snapshot.runId.value
                case None => "missing_snapshot"
            }
            case Result.Err(error) => "error:" + error.code + ":" + error.message
        }
        expect(partialProgramRunId != "" && partialProgramRunId != "missing_snapshot" &&
            !partialProgramRunId.startsWith("error:"),
            "partial Program execution has a durable root Run; actual=" + partialProgramRunId)
        let denialDatabase = SqliteDatabase(stateRoot + "/state.db")
        let oneSlotBase = product.request(
            "Find definitions with sequential Program reads",
            sessionId: Some(SessionId("durable-product-program-one-slot"))
        )
        let oneSlotRequest = requestWithBudget(
            oneSlotBase,
            programBudget(oneSlotBase.budget, 8, 1)
        )
        product.fixtureProbe.getOrThrow().enqueueToolCallReply(
            "fixture-program-one-slot-root-call",
            programBinding.name,
            objectValue([ValueField("code", textValue(programSource))])
        )
        let oneSlotBudgetEvents = ArrayList<ExecutionUsage>()
        let oneSlotResult = product.client.start(oneSlotRequest, { event =>
            match (event.payload) {
                case AgentEventPayload.BudgetUpdated(usage) => oneSlotBudgetEvents.add(usage)
                case _ => ()
            }
        })
        var slotHandoffStage: Int64 = 0
        var allChildCallsCharged = false
        for (usage in oneSlotBudgetEvents) {
            if (slotHandoffStage == 0 && usage.toolCalls == 1 && usage.activeTools == 1) {
                slotHandoffStage = 1
            } else if (slotHandoffStage == 1 && usage.toolCalls == 1 && usage.activeTools == 0) {
                slotHandoffStage = 2
            } else if (slotHandoffStage == 2 && usage.toolCalls == 2 && usage.activeTools == 1) {
                slotHandoffStage = 3
            }
            if (usage.toolCalls == 7 && usage.activeTools == 1) {
                allChildCallsCharged = true
            }
        }
        expect(match (oneSlotResult) {
            case Result.Ok(AgentRunOutcome.Completed(snapshot)) =>
                snapshot.status == RunState.Completed
            case _ => false
        } && slotHandoffStage == 3 && allChildCallsCharged,
            "sequential PTC children yield the parent slot, acquire one shared slot, and consume Run tool budget"
        )

        let boundedBase = product.request(
            "Read a file inside a one-call Run budget",
            sessionId: Some(SessionId("durable-product-program-budget"))
        )
        let boundedRequest = requestWithBudget(
            boundedBase,
            programBudget(boundedBase.budget, 1, 1)
        )
        product.fixtureProbe.getOrThrow().enqueueToolCallReply(
            "fixture-program-budget-root-call",
            programBinding.name,
            objectValue([ValueField(
                "code",
                textValue("return await tools.read({\"path\":\"src/alpha.cj\",\"offset\":1,\"limit\":1});")
            )])
        )
        let boundedResult = product.client.start(boundedRequest, {_ => ()})
        let boundedResultSummary = match (boundedResult) {
            case Result.Err(error) => error.code
            case Result.Ok(_) => "success"
        }
        expect(match (boundedResult) {
            case Result.Err(error) => error.code == "budget.tool_calls_exceeded"
            case _ => false
        }, "parent maxToolCalls blocks the child scheduler reservation; actual=" +
            boundedResultSummary)
        let boundedFailedRootReceipts = denialDatabase.scalarInt(
            "SELECT COUNT(*) FROM operation_receipts receipt " +
                "JOIN operations root_operation " +
                "ON root_operation.id=receipt.operation_id " +
                "WHERE root_operation.run_id='" + boundedRequest.runId.value +
                "' AND receipt.outcome='failed'"
        )
        expect(boundedFailedRootReceipts == 1,
            "budget rejection leaves one failed root receipt")
        let boundedChildAdmissions = denialDatabase.scalarInt(
            "SELECT COUNT(*) FROM derived_operation_admissions " +
                "WHERE parent_operation_id IN (SELECT id FROM operations " +
                "WHERE run_id='" + boundedRequest.runId.value + "')"
        )
        expect(boundedChildAdmissions == 0,
            "budget rejection occurs before durable child admission")
        expect(String.fromUtf8(File.readFrom(
            workspace + "/src/alpha.cj"
        )) == alphaSource, "budget rejection leaves the workspace unchanged")

        for (scenario in [
            ProductProgramDenialCase(
                "write",
                "return await tools.write({\"path\":\"src/alpha.cj\",\"content\":\"modified\"});"
            ),
            ProductProgramDenialCase(
                "shell",
                "return await tools.bash({\"command\":\"touch src/program-shell-escape\"});"
            ),
            ProductProgramDenialCase(
                "network",
                "return await tools[\"host.network.http\"]({\"intent_id\":\"fixture-network-probe\"});"
            ),
            ProductProgramDenialCase(
                "nested-program",
                "return await tools.run_program({\"source\":\"return 1;\"});"
            ),
            ProductProgramDenialCase(
                "model-api",
                "return await model.generate({\"prompt\":\"fixture\"});"
            ),
            ProductProgramDenialCase(
                "provider-api",
                "return await provider.complete({\"prompt\":\"fixture\"});"
            )
        ]) {
            let rejectedSessionId = SessionId(
                "durable-product-program-denied-" + scenario.name
            )
            product.fixtureProbe.getOrThrow().enqueueToolCallReply(
                "fixture-program-denied-" + scenario.name,
                programBinding.name,
                objectValue([ValueField("code", textValue(scenario.source))])
            )
            let rejectedResult = product.applicationSession(
                sessionId: Some(rejectedSessionId)
            ).submit("Attempt prohibited Program access: " + scenario.name)
            let rejectedRunId = match (rejectedResult) {
                case Result.Ok(response) => match (response.snapshot) {
                    case Some(snapshot) => Some(snapshot.runId.value)
                    case None => None<String>
                }
                case Result.Err(_) => None<String>
            }
            let rejectionObserved = match (rejectedRunId) {
                case Some(runId) =>
                    denialDatabase.scalarInt(
                        "SELECT COUNT(*) FROM operation_receipts receipt " +
                            "JOIN operations root_operation " +
                            "ON root_operation.id=receipt.operation_id " +
                            "WHERE root_operation.run_id='" + runId +
                            "' AND receipt.outcome='failed'"
                    ) == 1 && denialDatabase.scalarInt(
                        "SELECT COUNT(*) FROM derived_operation_admissions " +
                            "WHERE parent_operation_id IN (SELECT id FROM operations " +
                            "WHERE run_id='" + runId + "')"
                    ) == 0 && String.fromUtf8(File.readFrom(
                        workspace + "/src/alpha.cj"
                    )) == alphaSource
                case None => false
            }
            expect(
                rejectionObserved,
                "Product rejects forbidden PTC " + scenario.name +
                    " before child admission or workspace effects"
            )
        }
        denialDatabase.close()
        runNativeReadCancellationContract(root, workspace)
        runProgramCancellationRecoveryContract(root, workspace)
        let pluginRoot = workspace + "/plugin-package"
        Directory.create(pluginRoot, recursive: true)
        let nativeExecutable = getVariable("AXYNDRA_NATIVE_TOOL_PLUGIN_FIXTURE").getOrThrow()
        File.writeTo(pluginRoot + "/native-plugin-tool", File.readFrom(Path(nativeExecutable)))
        let _ = pluginAcquisitionRunFixtureCommand("/bin/chmod", ["755", "native-plugin-tool"], pluginRoot)
        File.writeTo(pluginRoot + "/axyndra.plugin.json", (
            "{\"id\":\"fixture-plugin\",\"version\":\"1.0.0\",\"entrypoint\":\"native-plugin-tool\"," +
            "\"entry_kind\":\"native-executable\",\"sdk_range\":\"[2.0.0,3.0.0)\"," +
            "\"protocol_range\":\"axyndra-js-host-v2\",\"signature\":\"signature-process\"," +
            "\"capabilities\":[],\"contributions\":[{\"kind\":\"tool\",\"name\":\"echo\"}]}"
        ).toArray())
        let importedPlugin = product.importLocalPlugin(pluginRoot, PluginInstallScope.Workspace)
        expect(importedPlugin.isOk(), "Product imports an executable plugin package into the durable lock")
        let pluginId = match (importedPlugin) {
            case PluginRegistryResult.Ok(record) => supportRegistryDescriptor96(record,"id")
            case PluginRegistryResult.Err(_) => ""
        }
        let enabledPlugin = product.setPluginEnabled(pluginId, true)
        let enabledPluginState = match (enabledPlugin) {
            case PluginRegistryResult.Ok(record) => if (supportRegistryData96(record).enabled) { "enabled" } else { "disabled" }
            case PluginRegistryResult.Err(error) => error.code + ":" + supportRegistryErrorText96(error)
        }
        expect(enabledPlugin.isOk() && match (enabledPlugin) {
            case PluginRegistryResult.Ok(record) => supportRegistryData96(record).enabled
            case PluginRegistryResult.Err(_) => false
        }, "Product enables a verified plugin and mounts its isolated generation; actual=" +
            enabledPluginState)
        let pluginNamespace = match (importedPlugin) {
            case PluginRegistryResult.Ok(record) => supportRegistryDescriptor96(record,"namespace")
            case PluginRegistryResult.Err(_) => ""
        }
        let pluginToolName = "plugin." + pluginNamespace + ".echo"
        var pluginToolSeen = false
        for (definition in product.tools()) {
            if (definition.name == pluginToolName) { pluginToolSeen = true }
        }
        expect(pluginToolSeen, "enabled native plugin publishes only its declared isolated tool")
        let nativeSessionName = "durable-product-native-plugin"
        let nativeCallId = "fixture-native-plugin-call"
        let nativeSession = product.applicationSession(sessionId: Some(SessionId(nativeSessionName)))
        product.fixtureProbe.getOrThrow().enqueueToolCallReply(nativeCallId, pluginToolName, objectValue([]))
        let nativeWaiting = nativeSession.submit("Execute the declared native plugin tool.").value().getOrThrow()
        let nativeApproval = nativeSession.approval().getOrThrow()
        expect(nativeWaiting.approval.isSome() && nativeApproval.toolName == pluginToolName,
            "native plugin execution retains the normal one-time approval barrier")
        let nativeCompleted = nativeSession.decide(nativeApproval.operationId.value, ApprovalDecision.Approve)
            .value().getOrThrow()
        expect(nativeCompleted.snapshot.isSome() &&
            nativeCompleted.snapshot.getOrThrow().status == RunState.Completed,
            "approved native plugin runs through the real Product process host")
        let nativeDatabase = SqliteDatabase(stateRoot + "/state.db")
        try {
            let (nativeOutput, nativeIsError) = productThreadToolResult(nativeDatabase, nativeSessionName, nativeCallId)
            expect(!nativeIsError && nativeOutput.field("runtime").getOrThrow().text == "native" &&
                nativeOutput.field("calls").getOrThrow().asNumberText() == "1" &&
                nativeDatabase.scalarInt(
                    "SELECT COUNT(*) FROM operation_receipts receipt JOIN operations op ON op.id=receipt.operation_id " +
                    "JOIN runs ON runs.id=op.run_id WHERE runs.thread_id='" + nativeSessionName +
                    "' AND receipt.outcome='completed'"
                ) == 1,
                "standalone native executable runs once and leaves one completed canonical Receipt")
        } finally { nativeDatabase.close() }
        let disabledPlugin = product.setPluginEnabled(pluginId, false)
        expect(disabledPlugin.isOk() && product.pluginSnapshots().any({ snapshot =>
            supportRegistryDescriptor96(snapshot,"id") == pluginId && !supportRegistryData96(snapshot).enabled
        }) && !product.tools().any({ definition => definition.name == pluginToolName }),
            "Product disables the native plugin and removes its declared tool")
        product.close().value().getOrThrow()

        let database = SqliteDatabase(stateRoot + "/state.db")
        try {
            expect(database.scalarInt(
                "SELECT COUNT(*) FROM run_lane_bindings WHERE run_id='" +
                    reviewExecutionRequest.runId.value + "' AND thread_id='" +
                    laneExecutionSession.value + "' AND lane_id='review'"
            ) == 1 && database.scalarInt(
                "SELECT COUNT(*) FROM step_records WHERE run_id='" +
                    reviewExecutionRequest.runId.value + "' AND lane_id='review'"
            ) >= 1 && database.scalarInt(
                "SELECT COUNT(*) FROM context_manifests manifest JOIN step_records step " +
                    "ON step.id=manifest.step_id WHERE step.run_id='" +
                    reviewExecutionRequest.runId.value + "' AND manifest.lane_id='review'"
            ) >= 1 && database.scalarInt(
                "SELECT COUNT(*) FROM item_tree_edges edge JOIN items item ON item.id=edge.item_id " +
                    "WHERE item.turn_id='turn-" + reviewExecutionRequest.runId.value +
                    "' AND edge.lane_id='review'"
            ) >= 1,
                "non-main Product Run keeps Run, Step, Context and Item Lane enclosure aligned")
            let thread = database.query(
                "SELECT revision,COALESCE(active_turn_id,'') FROM threads WHERE id='" +
                    sessionId.value + "'"
            )
            expect(thread.size == 1 && thread[0].required(0) == "3" &&
                thread[0].required(1) == "",
                "completed product Turn releases the durable Thread owner")
            expect(database.scalarInt(
                "SELECT COUNT(*) FROM turns WHERE thread_id='" + sessionId.value +
                    "' AND state='completed'"
            ) == 1 && database.scalarInt(
                "SELECT COUNT(*) FROM runs WHERE thread_id='" + sessionId.value +
                    "' AND state='completed'"
            ) == 1,
                "product composition persists matching completed Turn and Run records")
            expect(database.scalarInt(
                "SELECT COUNT(*) FROM items WHERE thread_id='" + sessionId.value + "'"
            ) == 2,
                "product composition persists canonical user and assistant Items")
            expect(database.scalarInt(
                "SELECT COUNT(*) FROM lane_inbox_entries WHERE thread_id='" +
                    sessionId.value + "' AND lane_id='main' AND status='applied'"
            ) == 1 && database.scalarInt(
                "SELECT COUNT(*) FROM step_records WHERE thread_id='" +
                    sessionId.value + "' AND status='completed'"
            ) == 1,
                "product admission and terminal settlement enclose the user input in one durable Step")
            expect(database.scalarInt(
                "SELECT COUNT(*) FROM composition_snapshots snapshot JOIN " +
                    "run_composition_bindings binding ON binding.snapshot_id=snapshot.id " +
                    "JOIN runs ON runs.id=binding.run_id WHERE runs.thread_id='" +
                    sessionId.value + "'"
            ) == 1 && database.scalarInt(
                "SELECT COUNT(*) FROM context_manifests WHERE thread_id='" +
                    sessionId.value + "'"
            ) == 1 && database.scalarInt(
                "SELECT COUNT(*) FROM run_continuation_facts facts JOIN runs " +
                    "ON runs.id=facts.run_id WHERE runs.thread_id='" + sessionId.value +
                    "' AND facts.phase='accepted'"
            ) == 1 && database.scalarInt(
                "SELECT COUNT(*) FROM run_continuation_facts facts JOIN runs " +
                    "ON runs.id=facts.run_id WHERE runs.thread_id='" + sessionId.value +
                    "' AND facts.phase='context_ready' AND " +
                    "facts.payload LIKE '%context_manifest_id%'"
            ) == 1 && database.scalarInt(
                "SELECT COUNT(*) FROM run_continuation_facts facts JOIN runs " +
                    "ON runs.id=facts.run_id WHERE runs.thread_id='" + sessionId.value +
                    "' AND facts.phase='model_effect_pending' AND " +
                    "facts.payload LIKE '%context_manifest_id%'"
            ) >= 1,
                "product freezes Composition, accepted continuation and exact Context Manifest before effects")
            let toolThread = database.query(
                "SELECT revision,COALESCE(active_turn_id,'') FROM threads WHERE id='" +
                    toolSessionId.value + "'"
            )
            expect(toolThread.size == 1 && toolThread[0].required(0) == "8" &&
                toolThread[0].required(1) == "",
                "Tool trajectory and resumed Turn settle under one Thread owner")
            expect(database.scalarInt(
                "SELECT COUNT(*) FROM items WHERE thread_id='" + toolSessionId.value + "'"
            ) == 6 && database.scalarInt(
                "SELECT COUNT(*) FROM operations JOIN runs ON runs.id=operations.run_id " +
                    "WHERE runs.thread_id='" + toolSessionId.value + "' AND operations.state='committed'"
            ) == 2 && database.scalarInt(
                "SELECT COUNT(*) FROM operation_receipts JOIN operations " +
                    "ON operations.id=operation_receipts.operation_id JOIN runs " +
                    "ON runs.id=operations.run_id WHERE runs.thread_id='" + toolSessionId.value +
                    "' AND operation_receipts.outcome='completed'"
            ) == 2,
                "one actual Native model ToolCall commits its own Root and Host readview child, with one paired model ToolResult")
            let firstReadRoots=database.query("SELECT o.id,o.run_id,e.tool_id FROM operations o JOIN runs r ON r.id=o.run_id "+
                "JOIN operation_effect_records e ON e.operation_id=o.id WHERE r.thread_id=? "+
                "AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=o.id)",
                [SqlParameter.Text(toolSessionId.value)])
            expect(firstReadRoots.size==1,"the original model Tool trajectory has one actual ordinary Native Root")
            programBinding.requireCompletedReadviewRoot(database,RunId(firstReadRoots[0].required(1)),
                firstReadRoots[0].required(0),firstReadRoots[0].required(2))
            expect(database.scalarInt(
                "SELECT COUNT(*) FROM context_checkpoints WHERE thread_id='" +
                    toolSessionId.value + "'"
            ) == 1,
                "checkpoint is durable while canonical Items remain unmodified")
            let programHistory = SqliteThreadCommitSink(database).loadThread(
                ThreadId(programSessionId.value)
            )
            var rootCallItemId = ""
            var rootToolCallCount: Int64 = 0
            var rootToolResultCount: Int64 = 0
            var rootResult: ?AgentValue = None
            for (item in programHistory.items) {
                match (item.content) {
                    case ThreadItemContent.ToolCall(_, name, _) =>
                        if (name == programBinding.name) {
                            rootToolCallCount += 1
                            rootCallItemId = item.id.value
                        }
                    case ThreadItemContent.ToolResult(_, _, _, output, isError) =>
                        rootToolResultCount += 1
                        if (!isError) { rootResult = Some(output) }
                    case _ => ()
                }
            }
            let rootOutput = match (rootResult) {
                case Some(value) => value
                case None => objectValue([])
            }
            let programValue = match (rootOutput.field("value")) {
                case Some(value) => value
                case None => listValue([])
            }
            let programRunRows = database.query(
                "SELECT id,state FROM runs WHERE thread_id='" +
                    programSessionId.value + "'"
            )
            let programRunId = if (programRunRows.isEmpty()) {
                ""
            } else {
                programRunRows[0].required(0)
            }
            let rootOperationRows = database.query(
                "SELECT op.id FROM operations op WHERE op.run_id='" + programRunId +
                    "' AND op.tool_call_item_id='" + rootCallItemId + "' " +
                    "AND NOT EXISTS (SELECT 1 FROM derived_operation_admissions a " +
                    "WHERE a.operation_id=op.id)"
            )
            let rootOperationId = if (rootOperationRows.isEmpty()) {
                ""
            } else {
                rootOperationRows[0].required(0)
            }
            let childRows = database.query(
                "SELECT a.call_sequence,op.id,op.state,r.outcome,e.tool_id," +
                    "e.reserved_result_item_id FROM derived_operation_admissions a " +
                    "JOIN operations op ON op.id=a.operation_id " +
                    "JOIN operation_receipts r ON r.operation_id=op.id " +
                    "JOIN operation_effect_records e ON e.operation_id=op.id " +
                    "WHERE a.parent_operation_id='" + rootOperationId + "' " +
                    "ORDER BY a.call_sequence"
            )
            var childPlansReadOnly = childRows.size == 3
            let operationStore = DurableOperationStore(database)
            for (row in childRows) {
                let plan = operationStore.loadPlan(
                    OperationId(row.required(1)), RunId(programRunId)
                ).value().getOrThrow()
                var childHasWorkspaceRead = false
                var childCapabilitiesReadOnly = true
                for (required in plan.requiredCapabilities) {
                    if (required.kind == CapabilityKind.WorkspaceRead) {
                        childHasWorkspaceRead = true
                    } else if (required.kind==CapabilityKind.ExtensionInvoke && programBinding.readonlyCapabilityAllowed(plan,required)) {
                        // Only this actual frozen contribution or an independently granted actual child QName.
                    } else {
                        childCapabilitiesReadOnly = false
                    }
                }
                if (plan.effectClass != OperationEffectClass.ReadOnly ||
                    plan.networkPolicy.mode != NetworkPolicyMode.Denied ||
                    !childHasWorkspaceRead || !childCapabilitiesReadOnly) {
                    childPlansReadOnly = false
                }
            }
            let reservedChildItems = database.scalarInt(
                "SELECT COUNT(*) FROM items item JOIN operation_effect_records e " +
                    "ON e.reserved_result_item_id=item.id JOIN derived_operation_admissions a " +
                    "ON a.operation_id=e.operation_id WHERE a.parent_operation_id='" +
                    rootOperationId + "'"
            )
            let programOperations = database.scalarInt(
                "SELECT COUNT(*) FROM operations WHERE run_id='" + programRunId + "'"
            )
            let programReceipts = database.scalarInt(
                "SELECT COUNT(*) FROM operation_receipts receipt JOIN operations op " +
                    "ON op.id=receipt.operation_id WHERE op.run_id='" + programRunId + "'"
            )
            let programThreadItems = database.scalarInt(
                "SELECT COUNT(*) FROM items WHERE thread_id='" + programSessionId.value + "'"
            )
            let programToolCalls = database.scalarInt(
                "SELECT COUNT(*) FROM items WHERE thread_id='" + programSessionId.value +
                    "' AND kind='tool_call'"
            )
            let programToolResults = database.scalarInt(
                "SELECT COUNT(*) FROM items WHERE thread_id='" + programSessionId.value +
                    "' AND kind='tool_result'"
            )
            let absentReceipt: ?VNextOperationReceipt = None
            let grepReceipt = if (childRows.size == 3) {
                operationStore.loadDerivedOperationReceipt(
                    OperationId(childRows[0].required(1)), RunId(programRunId)
                ).value().getOrThrow()
            } else { absentReceipt }
            let grepOutput = match (grepReceipt) {
                case Some(receipt) => receipt.detail.field("output") ?? objectValue([])
                case None => objectValue([])
            }
            let grepFiles = match (grepOutput.field("files")) {
                case Some(value) => value
                case None => listValue([])
            }
            let alphaReceipt = if (childRows.size == 3) {
                operationStore.loadDerivedOperationReceipt(
                    OperationId(childRows[1].required(1)), RunId(programRunId)
                ).value().getOrThrow()
            } else { absentReceipt }
            let betaReceipt = if (childRows.size == 3) {
                operationStore.loadDerivedOperationReceipt(
                    OperationId(childRows[2].required(1)), RunId(programRunId)
                ).value().getOrThrow()
            } else { absentReceipt }
            let alphaOutput = match (alphaReceipt) {
                case Some(receipt) => receipt.detail.field("output") ?? objectValue([])
                case None => objectValue([])
            }
            let betaOutput = match (betaReceipt) {
                case Some(receipt) => receipt.detail.field("output") ?? objectValue([])
                case None => objectValue([])
            }
            let alphaContent = alphaOutput.field("content") ?? textValue("")
            let betaContent = betaOutput.field("content") ?? textValue("")
            let ptcReceiptEvidence = if (programValue.unifiedKind == ValueKind.List &&
                programValue.items.size == 2) {
                programValue.items[0].text + "\n" + alphaContent.text + "\n" +
                    programValue.items[1].text + "\n" + betaContent.text
            } else {
                ""
            }
            expect(programRunRows.size == 1 &&
                programRunRows[0].required(1) == "completed" &&
                rootToolCallCount == 1 && rootToolResultCount == 1 &&
                rootOutput.field("status").getOrThrow().text == "completed" &&
                programValue.unifiedKind == ValueKind.List && programValue.items.size == 2 &&
                programValue.items[0].text == "src/alpha.cj" &&
                programValue.items[1].text == "src/beta.cj" &&
                alphaContent.text.contains("SymbolAnchor: alpha") &&
                betaContent.text.contains("SymbolAnchor: beta") &&
                ptcReceiptEvidence != "",
                "canonical PTC filters symbol paths and retains both read receipts")
            let programArtifactReference = rootOutput.field("program_artifact").getOrThrow().text
            let programArtifactHash = rootOutput.field("program_sha256").getOrThrow().text
            let programArtifact = ProductArtifactStore(
                stateRoot, database: Some(database)
            ).read(
                programArtifactReference
            ).value().getOrThrow()
            expect(programArtifact.reference == programArtifactReference &&
                programArtifact.content == programSource &&
                programArtifactReference == "blob:sha256:" + programArtifactHash &&
                programArtifactHash.size == 64 &&
                !rootOutput.field("output_truncated").getOrThrow().asBool(),
                "reconstructed root ToolResult carries a verified source artifact reference and complete output")
            expect(childRows.size == 3 && childRows[0].required(0) == "1" &&
                childRows[0].required(3) == "completed" && childRows[0].required(4) == programBinding.workspaceName("grep") &&
                childRows[1].required(0) == "2" && childRows[1].required(3) == "completed" &&
                childRows[1].required(4) == programBinding.workspaceName("read") && childRows[2].required(0) == "3" &&
                childRows[2].required(3) == "completed" && childRows[2].required(4) == programBinding.workspaceName("read") &&
                childPlansReadOnly && reservedChildItems == 0,
                "search and independent reads have ordered read-only Denied-network Receipts without child Thread Items")
            expect(grepFiles.unifiedKind == ValueKind.List && grepFiles.items.size == 2 &&
                grepFiles.items[0].field("path").getOrThrow().text == "src/alpha.cj" &&
                grepFiles.items[1].field("path").getOrThrow().text == "src/beta.cj" &&
                alphaContent.text.contains("SymbolAnchor: alpha") &&
                betaContent.text.contains("SymbolAnchor: beta"),
                "derived Receipts preserve actual search positions and both independent file evidence payloads")
            programBinding.requireCompletedBranches(database,RunId(programRunId),rootOperationId,["grep","read","read"])
            expect(rootOperationRows.size == 1 && programOperations == 7 &&
                programReceipts == 7 && programThreadItems == 4 &&
                programToolCalls == 1 && programToolResults == 1 &&
                database.scalarInt(
                    "SELECT COUNT(*) FROM threads WHERE id='durable-product-direct-program-bypass'"
                ) == 0,
                "Product persists one canonical root ToolCall/ToolResult plus three actual business children and their three readview children, each with real Receipts and no synthetic child items or bypass Run")
            let partialHistory = SqliteThreadCommitSink(database).loadThread(
                ThreadId(partialProgramSessionId.value)
            )
            var partialRootCallItemId = ""
            var partialRootToolCallCount: Int64 = 0
            var partialRootToolResultCount: Int64 = 0
            var partialRootResult: ?AgentValue = None
            var partialRootResultIsError = false
            for (item in partialHistory.items) {
                match (item.content) {
                    case ThreadItemContent.ToolCall(_, name, _) =>
                        if (name == programBinding.name) {
                            partialRootToolCallCount += 1
                            partialRootCallItemId = item.id.value
                        }
                    case ThreadItemContent.ToolResult(_, _, _, output, isError) =>
                        partialRootToolResultCount += 1
                        partialRootResult = Some(output)
                        partialRootResultIsError = isError
                    case _ => ()
                }
            }
            let partialRootOutput = match (partialRootResult) {
                case Some(value) => value
                case None => objectValue([])
            }
            let partialRootStatus = partialRootOutput.field("status") ?? textValue("")
            let partialRootValue = partialRootOutput.field("value") ?? nullValue()
            let partialRootSubCallCount = partialRootOutput.field("sub_call_count") ?? integerValue(0)
            let partialRootErrorCode = partialRootOutput.field("error_code") ?? textValue("")
            let partialRootOperationRows = database.query(
                "SELECT op.id FROM operations op WHERE op.run_id='" + partialProgramRunId +
                    "' AND op.tool_call_item_id='" + partialRootCallItemId + "' " +
                    "AND NOT EXISTS (SELECT 1 FROM derived_operation_admissions a " +
                    "WHERE a.operation_id=op.id)"
            )
            let partialRootOperationId = if (partialRootOperationRows.isEmpty()) {
                ""
            } else {
                partialRootOperationRows[0].required(0)
            }
            let partialChildRows = database.query(
                "SELECT a.call_sequence,op.state,r.outcome FROM derived_operation_admissions a " +
                    "JOIN operations op ON op.id=a.operation_id " +
                    "JOIN operation_receipts r ON r.operation_id=op.id " +
                    "WHERE a.parent_operation_id='" + partialRootOperationId + "' " +
                    "ORDER BY a.call_sequence"
            )
            expect(partialRootOperationRows.size == 1 &&
                partialRootToolCallCount == 1 && partialRootToolResultCount == 1 &&
                partialRootResultIsError && partialRootStatus.text == "partial" &&
                partialRootValue.unifiedKind == ValueKind.Null &&
                partialRootSubCallCount.text == "2" && partialRootErrorCode.text != "" &&
                partialChildRows.size == 1 &&
                partialChildRows[0].required(0) == "1" &&
                partialChildRows[0].required(2) == "completed" &&
                database.scalarInt(
                    "SELECT COUNT(*) FROM items WHERE thread_id='" +
                        partialProgramSessionId.value + "' AND kind IN ('tool_call','tool_result')"
                ) == 2 &&
                database.scalarInt(
                    "SELECT COUNT(*) FROM items item JOIN operation_effect_records e " +
                        "ON e.reserved_result_item_id=item.id JOIN derived_operation_admissions a " +
                        "ON a.operation_id=e.operation_id WHERE a.parent_operation_id='" +
                        partialRootOperationId + "'"
                ) == 0,
                "Product reconstructs a terminal partial root from its ToolResult and linked child Receipts without synthetic child Items")
            expect(database.scalarInt(
                "SELECT COUNT(*) FROM step_records step JOIN runs ON runs.id=step.run_id " +
                    "WHERE runs.thread_id='" + toolSessionId.value + "'"
            ) >= 2 && database.scalarInt(
                "SELECT COUNT(DISTINCT manifest.step_id) FROM context_manifests manifest " +
                    "WHERE manifest.thread_id='" + toolSessionId.value + "'"
            ) >= 2,
                "each Product model request owns a distinct durable Step and Context Manifest")
            expect(database.query(
                "SELECT status FROM lane_inbox_entries WHERE thread_id='" +
                    sessionId.value + "' AND payload LIKE '%persisted-steering%'"
            )[0].required(0) == "rejected" && database.query(
                "SELECT status FROM lane_inbox_entries WHERE thread_id='" +
                    sessionId.value + "' AND payload LIKE '%persisted-follow-up%'"
            )[0].required(0) == "queued",
                "withdrawal is durable and undelivered interaction survives process close")
            let deliveredRow = database.query(
                "SELECT id,status FROM lane_inbox_entries WHERE thread_id='" +
                    deliveredSession.value + "' AND payload LIKE '%delivered-follow-up%'"
            )[0]
            let deliveredEntryId = deliveredRow.required(0)
            let deliveredStatus = deliveredRow.required(1)
            let deliveredSteps = database.scalarInt(
                "SELECT COUNT(*) FROM step_records WHERE thread_id='" +
                    deliveredSession.value + "'"
            )
            let deliveredEnclosures = database.scalarInt(
                "SELECT COUNT(*) FROM step_records WHERE input_entry_id='" +
                    deliveredEntryId + "' AND accepted_item_id='" + deliveredEntryId + "'"
            )
            expect(deliveredStatus == "applied" && deliveredSteps >= 2 &&
                deliveredEnclosures == 1,
                "delivered interaction is atomically enclosed by its next model Step; " +
                    "status=${deliveredStatus} steps=${deliveredSteps} " +
                    "enclosures=${deliveredEnclosures}")
            expect(database.scalarInt(
                "SELECT COUNT(*) FROM audit_events WHERE thread_id='product-isolated-child' " +
                    "AND kind='thread.forked'"
            ) == 1 && SqliteThreadCommitSink(database).loadThread(
                ThreadId("product-isolated-child")
            ).activeRunId.isNone(),
                "isolated Product fork reopens without inheriting active Run authority")
            expect(database.scalarInt(
                "SELECT COUNT(*) FROM items WHERE thread_id='" + seededSession.value + "'"
            ) == 2 && database.scalarInt(
                "SELECT COUNT(*) FROM items WHERE thread_id='" + forkedSession.value + "'"
            ) == 2 && database.scalarInt(
                "SELECT COUNT(*) FROM items WHERE thread_id='" + forkedSession.value +
                    "' AND kind='system_note'"
            ) == 1,
                "canonical fork preserves non-provider semantic Items exactly")

            let faultProduct=openProduct(config:ProductConfig(settingsRoot:root+"/settings",stateRoot:stateRoot,
                workspaceRoot:workspace,fixture:true,asyncEnabled:false,
                extensionSignatureVerifier:Some(FixedPluginSignatureVerifier(true)),
                compactionOverride:Some(ProductCompactionSettings(keepRecentMessages:2)))).value().getOrThrow()
            try{
                let faultBinding=NativeProgramContractBinding(faultProduct)
            let admissionFailureSession = SessionId("fault-matrix-admission-persistence")
            expect(!productToolAvailable(faultProduct,"read"),
                "retired read alias is absent before the independent root admission persistence fault observer")
            let admissionFailureProbe = ProgramCancellationGate()
            expect(faultProduct.registerTool(
                ToolDescriptor(
                    ModelToolDefinition("fixture.admission_failure_probe", "independent admission failure execution probe", objectValue([])),
                    Capability(CapabilityKind.WorkspaceRead),
                    implementationVersion: "fault-matrix-admission-v1",
                    implementationFingerprint: "fault-matrix-admission-read-v1",
                    networkPolicyResolver: Some({_ =>
                        Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied))
                    })
                ),
                ProgramCancellationReadExecutor(admissionFailureProbe)
            ).isOk(), "fault matrix installs the admission execution probe")
            database.execute(
                "CREATE TRIGGER reject_fault_matrix_operation BEFORE INSERT ON operations " +
                    "WHEN (SELECT thread_id FROM runs WHERE id=NEW.run_id)='" +
                    admissionFailureSession.value + "' BEGIN " +
                    "SELECT RAISE(ABORT,'injected operation admission persistence failure'); END"
            )
            faultProduct.fixtureProbe.getOrThrow().enqueueToolCallReply(
                "fixture-admission-persistence-root",
                faultBinding.name,
                objectValue([ValueField(
                    "code", textValue("return await tools.read({});")
                )])
            )
            let admissionFailure = try {
                faultProduct.applicationSession(sessionId: Some(admissionFailureSession))
                    .submit("Attempt a Program while root admission persistence fails.")
            } finally {
                database.execute("DROP TRIGGER reject_fault_matrix_operation")
            }
            expect(admissionFailure.isError() && admissionFailureProbe.calls() == 0 &&
                database.scalarInt(
                    "SELECT COUNT(*) FROM operations op JOIN runs ON runs.id=op.run_id " +
                        "WHERE runs.thread_id='" + admissionFailureSession.value + "'"
                ) == 0 && database.scalarInt(
                    "SELECT COUNT(*) FROM derived_operation_admissions admission " +
                        "JOIN operations op ON op.id=admission.operation_id " +
                        "JOIN runs ON runs.id=op.run_id WHERE runs.thread_id='" +
                        admissionFailureSession.value + "'"
                ) == 0,
                "root admission persistence failure starts no Program or child executor and creates no bypass admission")
            let failedThread=SqliteThreadCommitSink(database).loadThread(ThreadId(admissionFailureSession.value))
            var realFaultCalls:Int64=0
            for(item in failedThread.items){match(item.content){
                case ThreadItemContent.ToolCall(callId,name,_)=>
                    if(callId.value=="fixture-admission-persistence-root" && name==faultBinding.name){realFaultCalls+=1}
                case _=>()}}
            expect(realFaultCalls==1,"actual canonical model ToolCall exists before its SQLite admission trigger refuses the Root")
            }finally{faultProduct.close().getOrThrow()}

        } finally {
            database.close()
        }
        let reopened = openProduct(config: ProductConfig(
            settingsRoot: root + "/settings",
            stateRoot: stateRoot,
            workspaceRoot: workspace,
            fixture: true,
            asyncEnabled: false
        )).value().getOrThrow()
        let restoredInputs = reopened.applicationSession(
            sessionId: Some(sessionId)
        ).takeFollowUps()
        expect(restoredInputs.size == 1 &&
            restoredInputs[0].correlationId == "persisted-follow-up" &&
            restoredInputs[0].text == "continue after recovery",
            "Application restores undelivered durable Inbox input after process reopen")
        reopened.close().value().getOrThrow()
        println("product Thread Runtime contract passed")
        0
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

func executeIsolatedPluginTool(
    host: ProductIsolatedPluginHost,
    extensionId: String,
    callId: String,
    arguments: AgentValue,
    additionalCapabilities: Array<Capability>,
    networkPolicy: NetworkPolicy
): Result<ToolInvocationResult> {
    let toolName = "plugin." + extensionId + ".invoke"
    let call = ToolCall(callId, toolName, arguments)
    let descriptor = ToolDescriptor(
        ModelToolDefinition(toolName, "isolated plugin contract", objectValue([])),
        Capability(CapabilityKind.ExtensionInvoke),
        sideEffecting: true,
        additionalCapabilities: additionalCapabilities,
        implementationVersion: "isolated-plugin-contract-v1",
        implementationFingerprint: extensionId,
        networkPolicyResolver: Some({_ => Result.Ok(networkPolicy)})
    )
    let catalog = ToolCatalog()
    match (catalog.register(descriptor, ProductPluginToolExecutor(host, extensionId))) {
        case Result.Err(error) => return Result.Err(error)
        case Result.Ok(_) => ()
    }
    let pipeline = ToolPipeline(
        catalog,
        InMemoryOperationRuntimePort(),
        RecordingAuditPort(),
        DeterministicIds(prefix: callId),
        policy: DefaultCapabilityPolicy(mode: ApprovalMode.Yolo)
    )
    executePipelineCall(
        pipeline,
        ToolInvocationContext(
            RunId("run-" + callId),
            SessionId("session-" + callId),
            CapabilitySet(values: descriptor.requiredCapabilities(call))
        ),
        call
    )
}
func isolatedPluginFixtureDescriptor(
    root: String,
    id: String,
    entrypoint: String,
    capabilitiesJson: String,
    signature: String
): PluginPackageDescriptor {
    Directory.create(root + "/plugins", recursive: true)
    File.writeTo(root + "/" + entrypoint, "fixture entrypoint\n".toArray())
    File.writeTo(root + "/axyndra.plugin.json", (
        "{\"id\":\"" + id + "\",\"version\":\"1.0.0\"," +
        "\"entrypoint\":\"" + entrypoint + "\",\"capabilities\":" +
        capabilitiesJson + ",\"signature\":\"" + signature + "\"}"
    ).toArray())
    match (inspectPluginPackage(root)) {
        case PluginPackageResult.Ok(value) => value
        case PluginPackageResult.Err(error) => throw IllegalStateException(
            error.code + ": " + error.message
        )
    }
}

func isolatedPluginHostContract(workspace: String, settingsRoot: String): Unit {
    let managedPackageRoot = settingsRoot + "/plugins/packages"
    Directory.create(managedPackageRoot, recursive: true)
    let managedPackageRoots = [managedPackageRoot]
    let processRoot = managedPackageRoot + "/isolated-plugin-package"
    let packageOnlyRoot = managedPackageRoot + "/package-only"
    let wasmRoot = managedPackageRoot + "/wasm-package"
    let processDescriptor = isolatedPluginFixtureDescriptor(
        processRoot, "review.process", "plugins/reviewer",
        "[\"workspace.read\"]", "signature-process"
    )
    let processManifest = SignedExtensionPackageManifest(
        "review.process", "1.0.0", ">=1.0.0 <2.0.0", "1",
        "plugins/reviewer", ["review"], [], ["workspace.read"],
        1u32, "compatible", processDescriptor.contentDigest, "signature-process"
    )
    let processLaunch = match (validateIsolatedPluginPackage(
        processManifest, ExtensionExecutionKind.ProcessPlugin, 7u64,
        ["workspace.read"], FixedPluginSignatureVerifier(true),
        packageRoot: processRoot
    )) {
        case SafeLifecycleResult.Ok(value) => value
        case SafeLifecycleResult.Err(error) => throw IllegalStateException(error)
    }
    let processPort = RecordingPluginProcessPort("{\"accepted\":true}")
    let host = ProductIsolatedPluginHost(
        processPort, workspace, managedPackageRoots: managedPackageRoots
    )
    expect(host.mountInitial(processLaunch).isOk(),
        "isolated Process generation mounts before admission")
    let processResult = executeIsolatedPluginTool(
        host,
        "review.process",
        "call-1",
        objectValue([ValueField("path", textValue("input.txt"))]),
        [Capability(CapabilityKind.WorkspaceRead)],
        NetworkPolicy(NetworkPolicyMode.Denied)
    )
    expect(processResult.isOk() && processPort.requests.size == 1 &&
        processPort.requests[0].executable == processRoot + "/plugins/reviewer" &&
        processPort.requests[0].workingDirectory == processRoot &&
        processPort.requests[0].sandboxMode == ProcessSandboxMode.WorkspaceReadOnly &&
        processPort.requests[0].filesystemRoot == "" &&
        processPort.requests[0].readOnlyMounts == [processRoot] &&
        networkPolicyModeIsDenied(processPort.requests[0].networkPolicy.mode) &&
        processPort.requests[0].environmentAllowlist.isEmpty() &&
        processPort.requests[0].arguments.size == 2 &&
        processPort.requests[0].arguments[1].contains("axyndra-extension-v1"),
        "Process plugin executes only through the bounded read-only sandbox protocol")
    File.writeTo(
        processRoot + "/plugins/reviewer",
        "tampered entrypoint\n".toArray()
    )
    let staleResult = executeIsolatedPluginTool(
        host,
        "review.process",
        "call-stale",
        objectValue([]),
        [Capability(CapabilityKind.WorkspaceRead)],
        NetworkPolicy(NetworkPolicyMode.Denied)
    )
    expect(match (staleResult) {
        case Result.Ok(ToolInvocationResult.Completed(result)) => result.isError &&
            match (result.output.field("error")) {
                case Some(code) => code.text == "extension.snapshot_stale"
                case None => false
            }
        case _ => false
    } && processPort.requests.size == 1,
        "isolated plugin refuses modified signed package bytes before execution")
    File.writeTo(
        processRoot + "/plugins/reviewer",
        "fixture entrypoint\n".toArray()
    )
    let processReload = match (validateIsolatedPluginPackage(
        processManifest, ExtensionExecutionKind.ProcessPlugin, 8u64,
        ["workspace.read"], FixedPluginSignatureVerifier(true),
        packageRoot: processRoot
    )) {
        case SafeLifecycleResult.Ok(value) => value
        case SafeLifecycleResult.Err(error) => throw IllegalStateException(error)
    }
    expect(host.reload(processReload).isOk() && executeIsolatedPluginTool(
        host,
        "review.process",
        "call-1b",
        objectValue([]),
        [Capability(CapabilityKind.WorkspaceRead)],
        NetworkPolicy(NetworkPolicyMode.Denied)
    ).isOk() && host.diagnostics().size == 2 &&
        host.diagnostics()[0].state == ExtensionLifecycleState.Inactive &&
        !host.diagnostics()[0].accepting &&
        host.diagnostics()[1].state == ExtensionLifecycleState.Active &&
        host.diagnostics()[1].generation == 8u64,
        "isolated plugin reload fences the old generation before subsequent admission")

    let cancellationPort = AtomicCancellationPluginProcessPort()
    let cancellationHost = ProductIsolatedPluginHost(
        cancellationPort, workspace, managedPackageRoots: managedPackageRoots
    )
    expect(cancellationHost.mountInitial(processLaunch).isOk(),
        "cancellation race generation mounts from the managed snapshot")
    let invocation = spawn {
        executeIsolatedPluginTool(
            cancellationHost,
            "review.process",
            "call-cancel-race",
            objectValue([]),
            [Capability(CapabilityKind.WorkspaceRead)],
            NetworkPolicy(NetworkPolicyMode.Denied)
        )
    }
    var reservationEntered = false
    for (_ in 0..5000) {
        if (cancellationPort.reservationEntered()) {
            reservationEntered = true
            break
        }
        sleep(Duration.millisecond)
    }
    let deactivation = spawn {
        let outcome: Result<Unit> = match (cancellationHost.deactivate("review.process")) {
            case Result.Ok(_) => cancellationHost.cancelAll("review.process")
            case Result.Err(error) => Result.Err(error)
        }
        outcome
    }
    cancellationPort.allowReservation()
    let deactivated = deactivation.get()
    let cancelledInvocation = invocation.get()
    let invocationFailed = match (cancelledInvocation) {
        case Result.Ok(ToolInvocationResult.Completed(result)) => result.isError
        case Result.Ok(_) => false
        case Result.Err(_) => true
    }
    expect(reservationEntered && deactivated.isOk() && invocationFailed &&
        cancellationPort.reservedBeforeExecute() && cancellationPort.cancelled() &&
        cancellationPort.released(),
        "deactivation sees atomically admitted plugin operations and cancellation stays sticky until launch")

    let packageOnlyDescriptor = isolatedPluginFixtureDescriptor(
        packageOnlyRoot, "review.package-only", "plugins/reviewer",
        "[]", "signature-package-only"
    )
    let packageOnlyManifest = SignedExtensionPackageManifest(
        "review.package-only", "1.0.0", ">=1.0.0 <2.0.0", "1",
        "plugins/reviewer", ["review"], [], [],
        1u32, "compatible", packageOnlyDescriptor.contentDigest, "signature-package-only"
    )
    let packageOnlyLaunch = match (validateIsolatedPluginPackage(
        packageOnlyManifest, ExtensionExecutionKind.ProcessPlugin, 1u64,
        [], FixedPluginSignatureVerifier(true),
        packageRoot: packageOnlyRoot
    )) {
        case SafeLifecycleResult.Ok(value) => value
        case SafeLifecycleResult.Err(error) => throw IllegalStateException(error)
    }
    let packageOnlyPort = RecordingPluginProcessPort("{\"accepted\":true}")
    let packageOnlyHost = ProductIsolatedPluginHost(
        packageOnlyPort, workspace, managedPackageRoots: managedPackageRoots
    )
    expect(packageOnlyHost.mountInitial(packageOnlyLaunch).isOk() &&
        executeIsolatedPluginTool(
            packageOnlyHost,
            "review.package-only",
            "call-package-only",
            objectValue([]),
            [],
            NetworkPolicy(NetworkPolicyMode.Denied)
        ).isOk() && packageOnlyPort.requests.size == 1 &&
        packageOnlyPort.requests[0].sandboxMode == ProcessSandboxMode.IsolatedReadOnly &&
        packageOnlyPort.requests[0].filesystemRoot == packageOnlyRoot &&
        packageOnlyPort.requests[0].readOnlyMounts.isEmpty(),
        "plugin without workspace capability receives only its package filesystem")

    let wasmDescriptor = isolatedPluginFixtureDescriptor(
        wasmRoot, "review.wasm", "plugins/reviewer.wasm",
        "[\"workspace.write\",\"network.access:api.example.com:443\"]",
        "signature-wasm"
    )
    let wasmManifest = SignedExtensionPackageManifest(
        "review.wasm", "1.0.0", ">=1.0.0 <2.0.0", "1",
        "plugins/reviewer.wasm", ["review"], [],
        ["workspace.write", "network.access:api.example.com:443"], 1u32, "compatible",
        wasmDescriptor.contentDigest, "signature-wasm"
    )
    let wasmLaunch = match (validateIsolatedPluginPackage(
        wasmManifest, ExtensionExecutionKind.WasmComponent, 8u64,
        ["workspace.write", "network.access:api.example.com:443"], FixedPluginSignatureVerifier(true),
        packageRoot: wasmRoot
    )) {
        case SafeLifecycleResult.Ok(value) => value
        case SafeLifecycleResult.Err(error) => throw IllegalStateException(error)
    }
    let wasmPort = RecordingPluginProcessPort("{\"accepted\":true}")
    let wasmHost = ProductIsolatedPluginHost(
        wasmPort, workspace, wasmRuntime: "wasmtime-fixture",
        managedPackageRoots: managedPackageRoots
    )
    expect(wasmHost.mountInitial(wasmLaunch).isOk() && executeIsolatedPluginTool(
        wasmHost,
        "review.wasm",
        "call-2",
        objectValue([]),
        [Capability(CapabilityKind.WorkspaceWrite)],
        NetworkPolicy(
            NetworkPolicyMode.Mediated,
            egress: [NetworkEgressRule("api.example.com", 443u16)]
        )
    ).isOk() && wasmPort.requests.size == 1 &&
        wasmPort.requests[0].executable == "wasmtime-fixture" &&
        wasmPort.requests[0].arguments[0] == wasmRoot + "/plugins/reviewer.wasm" &&
        wasmPort.requests[0].workingDirectory == wasmRoot &&
        wasmPort.requests[0].sandboxMode == ProcessSandboxMode.WorkspaceReadWrite &&
        wasmPort.requests[0].filesystemRoot == "" &&
        wasmPort.requests[0].readOnlyMounts == [wasmRoot] &&
        networkPolicyModeIsMediated(wasmPort.requests[0].networkPolicy.mode) &&
        wasmPort.requests[0].networkPolicy.egress.size == 1 &&
        wasmPort.requests[0].networkPolicy.egress[0].host == "api.example.com" &&
        wasmPort.requests[0].networkPolicy.egress[0].port == 443u16,
        "WASM plugin uses the fixed runtime and its explicitly granted mediated authority")

    let truncated = RecordingPluginProcessPort("{}", truncated: true)
    let truncatedHost = ProductIsolatedPluginHost(
        truncated, workspace, managedPackageRoots: managedPackageRoots
    )
    expect(truncatedHost.mountInitial(processLaunch).isOk() && match (executeIsolatedPluginTool(
        truncatedHost,
        "review.process",
        "call-3",
        objectValue([]),
        [Capability(CapabilityKind.WorkspaceRead)],
        NetworkPolicy(NetworkPolicyMode.Denied)
    )) {
        case Result.Ok(ToolInvocationResult.Completed(result)) => result.isError &&
            match (result.output.field("error")) {
                case Some(code) => code.text == "extension.output_truncated"
                case None => false
            }
        case _ => false
    }, "truncated isolated plugin output fails closed")
    expect(validateIsolatedPluginPackage(
        SignedExtensionPackageManifest(
            "escape", "1", "1", "1", "../escape", [], [], [], 1u32,
            "none", "sha256:escape", "signature"
        ),
        ExtensionExecutionKind.ProcessPlugin, 1u64, [],
        FixedPluginSignatureVerifier(true)
    ).isOk() == false, "isolated plugin entrypoint cannot escape its package")
}

class FixedPluginSignatureVerifier <: ExtensionPackageSignatureVerifier {
    private let valid: Bool
    init(valid: Bool) { this.valid = valid }
    public func verify(_manifest: SignedExtensionPackageManifest): Bool {
        let _ = _manifest
        valid
    }
}

class ProductRemoteVerifier <: RemoteCapabilitySignatureVerifier {
    public func verify(
        _envelope: SignedRemoteCapabilityEnvelope,
        transportIdentity: String
    ): Bool {
        let _ = _envelope.id
        transportIdentity == "product-worker-key"
    }
}

class ProductRecordingRemoteTransport <: RemoteWorkerTransport {
    var dispatches: Int64 = 0

    public func dispatch(
        realm: RemoteExecutionRealm,
        envelope: SignedRemoteCapabilityEnvelope,
        request: RemoteExecutionRequest
    ): Result<AgentValue> {
        let _ = realm.id
        let _ = envelope.id
        let _ = request.routeKey
        dispatches += 1
        Result.Ok(objectValue([]))
    }
}

class RecordingPluginProcessPort <: ProcessPort {
    public let requests = ArrayList<ProcessRequest>()
    private let output: String
    private let truncated: Bool

    init(output: String, truncated!: Bool = false) {
        this.output = output
        this.truncated = truncated
    }

    public func execute(request: ProcessRequest): Result<ProcessResult> {
        requests.add(request)
        Result.Ok(ProcessResult(0, stdout: output, truncated: truncated))
    }

    public func cancel(_operationId: OperationId): Result<Unit> {
        let _ = _operationId
        Result.Ok(())
    }
}

class AtomicCancellationPluginProcessPort <: ProcessPort {
    private let lock = Mutex()
    private var reservationEnteredValue = false
    private var reservationAllowed = false
    private var reserved = false
    private var reservedBeforeExecuteValue = false
    private var cancelledValue = false
    private var releasedValue = false

    public func reserveOperation(_operationId: OperationId): Unit {
        let _ = _operationId
        lock.lock()
        try {
            reservationEnteredValue = true
            reserved = true
        } finally { lock.unlock() }
        while (true) {
            lock.lock()
            let allowed = try { reservationAllowed } finally { lock.unlock() }
            if (allowed) { return }
            sleep(Duration.millisecond)
        }
    }

    public func releaseOperation(_operationId: OperationId): Unit {
        let _ = _operationId
        lock.lock()
        try {
            reserved = false
            releasedValue = true
        } finally { lock.unlock() }
    }

    public func execute(_request: ProcessRequest): Result<ProcessResult> {
        let _ = _request.executable
        lock.lock()
        try { reservedBeforeExecuteValue = reserved } finally { lock.unlock() }
        for (_ in 0..5000) {
            lock.lock()
            let cancelled = try { cancelledValue } finally { lock.unlock() }
            if (cancelled) {
                return Result.Err(AgentError(
                    AgentErrorKind.Cancelled,
                    "process.cancelled",
                    "reserved plugin process was cancelled before or during launch"
                ))
            }
            sleep(Duration.millisecond)
        }
        Result.Err(AgentError(
            AgentErrorKind.Transport,
            "process.cancel_timeout",
            "plugin cancellation was not delivered"
        ))
    }

    public func cancel(_operationId: OperationId): Result<Unit> {
        let _ = _operationId
        lock.lock()
        try { cancelledValue = true } finally { lock.unlock() }
        Result.Ok(())
    }

    func reservationEntered(): Bool {
        lock.lock(); try { reservationEnteredValue } finally { lock.unlock() }
    }
    func allowReservation(): Unit {
        lock.lock(); try { reservationAllowed = true } finally { lock.unlock() }
    }
    func cancelled(): Bool {
        lock.lock(); try { cancelledValue } finally { lock.unlock() }
    }
    func released(): Bool {
        lock.lock(); try { releasedValue } finally { lock.unlock() }
    }
    func reservedBeforeExecute(): Bool {
        lock.lock(); try { reservedBeforeExecuteValue } finally { lock.unlock() }
    }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException("contract failed: " + message) }
}

func filePlanProposal(operations: Array<AgentValue>): AgentValue {
    objectValue([
        ValueField("schema", textValue("axyndra.file-change-proposal/v1")),
        ValueField("operations", listValue(operations))
    ])
}

func filePlanCreateOperation(path: String, content: String): AgentValue {
    objectValue([
        ValueField("kind", textValue("create")),
        ValueField("path", textValue(path)),
        ValueField("content", textValue(content))
    ])
}

func filePlanReplaceOperation(
    path: String,
    expectedContent: String,
    content: String
): AgentValue {
    objectValue([
        ValueField("kind", textValue("replace")),
        ValueField("path", textValue(path)),
        ValueField("expected_content", textValue(expectedContent)),
        ValueField("content", textValue(content))
    ])
}

func filePlanProgramSource(proposal: AgentValue): String {
    "return " + encodeAgentValue(objectValue([
        ValueField("application_plan", proposal)
    ])) + ";"
}

func productThreadToolResult(
    database: SqliteDatabase,
    sessionName: String,
    callId: String
): (AgentValue, Bool) {
    let history = SqliteThreadCommitSink(database).loadThread(
        ThreadId(sessionName)
    )
    for (item in history.items) {
        match (item.content) {
            case ThreadItemContent.ToolResult(resultCallId, _, _, output, isError) =>
                if (resultCallId.value == callId) { return (output, isError) }
            case _ => ()
        }
    }
    throw IllegalStateException("Product thread has no result for tool call: " + callId)
}

func runProductProgramToolCall(
    product: ProductRuntime,
    database: SqliteDatabase,
    sessionName: String,
    callId: String,
    source: String
): (AgentValue, Bool) {
    let sessionId = SessionId(sessionName)
    product.fixtureProbe.getOrThrow().enqueueToolCallReply(
        callId,
        nativeProgramContractToolName(product),
        objectValue([ValueField("code", textValue(source))])
    )
    let _ = product.applicationSession(sessionId: Some(sessionId)).submit(
        "Exercise the read-only Program application-plan contract."
    )
    let history = SqliteThreadCommitSink(database).loadThread(
        ThreadId(sessionId.value)
    )
    var rootCallCount: Int64 = 0
    var rootResultCount: Int64 = 0
    var rootOutput: ?AgentValue = None
    var rootIsError = false
    for (item in history.items) {
        match (item.content) {
            case ThreadItemContent.ToolCall(itemCallId, name, _) =>
                if (itemCallId.value == callId && name == nativeProgramContractToolName(product)) {
                    rootCallCount += 1
                }
            case ThreadItemContent.ToolResult(itemCallId, _, _, output, isError) =>
                if (itemCallId.value == callId) {
                    rootResultCount += 1
                    rootOutput = Some(output)
                    rootIsError = isError
                }
            case _ => ()
        }
    }
    expect(rootCallCount == 1 && rootResultCount == 1,
        "Program plan scenario persists one canonical root Tool trajectory: " + callId)
    (rootOutput.getOrThrow(), rootIsError)
}

func expectRejectedFilePlan(
    product: ProductRuntime,
    database: SqliteDatabase,
    sessionName: String,
    callId: String,
    source: String,
    expectedCode: String,
    label: String
): Unit {
    let (output, isError) = runProductProgramToolCall(
        product, database, sessionName, callId, source
    )
    let actualCode = match (output.field("error_code")) {
        case Some(value) => value.text
        case None => ""
    }
    expect(isError && actualCode == expectedCode,
        label + "; expected=" + expectedCode + "; actual=" + actualCode)
}

func runProductFileApplicationPlanContracts(
    root: String,
    workspace: String,
    stateRoot: String,
    product: ProductRuntime
): Unit {
    let binding=NativeProgramContractBinding(product,filePlanProposals:true)
    let database = SqliteDatabase(stateRoot + "/state.db")
    try {
        let artifacts = ProductArtifactStore(stateRoot, database: Some(database))
        let alphaPath = workspace + "/src/alpha.cj"
        let originalAlpha = String.fromUtf8(File.readFrom(Path(alphaPath)))
        let createdPath = workspace + "/src/e5-02-created.cj"
        let largeCreatedPath = workspace + "/src/e5-02-large.cj"
        expect(!exists(Path(createdPath)) && !exists(Path(largeCreatedPath)),
            "plan targets begin absent")

        let largeBuilder = StringBuilder()
        for (_ in 0..9000) { largeBuilder.append("x") }
        let largeContent = largeBuilder.toString()
        let createContent = "fn planned() {}\n"
        let replacementContent = originalAlpha + "// plan-only marker\n"
        let validValue = objectValue([
            ValueField("answer", integerValue(42)),
            ValueField("application_plan", filePlanProposal([
                filePlanCreateOperation("src/e5-02-created.cj", createContent),
                filePlanReplaceOperation(
                    "src/alpha.cj", originalAlpha, replacementContent
                ),
                filePlanCreateOperation("src/e5-02-large.cj", largeContent)
            ]))
        ])
        let validSource =
            "const inspected = await tools.read({\"path\":\"src/alpha.cj:raw\"});\n" +
            "return " + encodeAgentValue(validValue) + ";"
        let (validOutput, validIsError) = runProductProgramToolCall(
            product, database, "e5-02-valid-plan", "fixture-e5-02-valid-plan", validSource
        )
        expect(!validIsError, "valid read-only Program returns a stored plan; output=" +
            encodeAgentValue(validOutput))
        expect(Int64.parse(validOutput.field("sub_call_count").getOrThrow().asNumberText()) == 2,
            "the Program executes one raw workspace read and one separately charged actual preview request")
        let programValue = validOutput.field("value").getOrThrow()
        let planSummary = programValue.field("application_plan").getOrThrow()
        expect(programValue.field("answer").getOrThrow().asNumberText() == "42" &&
            planSummary.field("schema").getOrThrow().text == "axyndra.file-application-plan/v2",
            "plan generation preserves the Program value and returns the immutable plan summary")
        expect(String.fromUtf8(File.readFrom(Path(alphaPath))) == originalAlpha &&
            !exists(Path(createdPath)) && !exists(Path(largeCreatedPath)),
            "plan generation does not mutate any workspace target")

        let planReference = planSummary.field("plan_ref").getOrThrow().text
        let planDigest = planSummary.field("plan_digest").getOrThrow().text
        expect(planDigest.size == 64 && planReference == "blob:sha256:" + planDigest,
            "summary carries a content-addressed plan reference and digest")
        let planRead = artifacts.read(planReference, limit: 1048576).value().getOrThrow()
        expect(planRead.reference == planReference && planRead.bytes == planRead.returnedBytes &&
            !planRead.truncated,
            "plan artifact is readable in full from the Product artifact store")
        let plan = parseUnifiedJson(planRead.content)
        expect(plan.field("schema").getOrThrow().text == "axyndra.file-application-plan/v2",
            "stored plan records its versioned schema")
        let sourceIdentity = plan.field("source").getOrThrow()
        binding.requireGeneratedFilePlan(database,sourceIdentity,planSummary,validValue.field("application_plan").getOrThrow(),validSource)
        let sourceArtifact=artifacts.read(validOutput.field("program_artifact").getOrThrow().text,limit:262144).value().getOrThrow()
        expect(!sourceArtifact.truncated && sourceArtifact.content==validSource &&
            sourceArtifact.reference=="blob:sha256:"+validOutput.field("program_sha256").getOrThrow().text &&
            sourceIdentity.field("root_operation_id").getOrThrow().text!="",
            "stored plan binds its actual Native root, actual generation Receipt and complete immutable Program source artifact")
        let workspaceId = plan.field("workspace_id").getOrThrow().text
        expect(workspaceId.startsWith("workspace:sha256:") && !workspaceId.contains(workspace),
            "stored plan identifies the workspace without exposing its local path")

        let operations = plan.field("operations").getOrThrow().items
        expect(operations.size == 3 &&
            operations[0].field("kind").getOrThrow().text == "create" &&
            operations[0].field("path").getOrThrow().text == "src/e5-02-created.cj" &&
            operations[1].field("kind").getOrThrow().text == "replace" &&
            operations[1].field("path").getOrThrow().text == "src/alpha.cj" &&
            operations[2].field("path").getOrThrow().text == "src/e5-02-large.cj",
            "stored plan preserves ordered create and replace targets")
        let createPrecondition = operations[0].field("precondition").getOrThrow()
        let replacePrecondition = operations[1].field("precondition").getOrThrow()
        let originalArtifact = artifacts.persistText(originalAlpha).value().getOrThrow()
        let createContentMetadata = operations[0].field("content").getOrThrow()
        let replaceContentMetadata = operations[1].field("content").getOrThrow()
        let createArtifact = artifacts.persistText(createContent).value().getOrThrow()
        let replacementArtifact = artifacts.persistText(replacementContent).value().getOrThrow()
        let largeArtifact = artifacts.persistText(largeContent).value().getOrThrow()
        expect(createPrecondition.field("state").getOrThrow().text == "absent" &&
            replacePrecondition.field("state").getOrThrow().text == "regular_file" &&
            replacePrecondition.field("sha256").getOrThrow().text == originalArtifact.sha256 &&
            Int64.parse(replacePrecondition.field("bytes").getOrThrow().asNumberText()) ==
                originalAlpha.toArray().size,
            "stored plan records absent and exact-content replacement preconditions")
        expect(createContentMetadata.field("encoding").getOrThrow().text == "utf-8" &&
            createContentMetadata.field("sha256").getOrThrow().text == createArtifact.sha256 &&
            replaceContentMetadata.field("sha256").getOrThrow().text == replacementArtifact.sha256 &&
            operations[2].field("content").getOrThrow().field("sha256").getOrThrow().text ==
                largeArtifact.sha256,
            "stored plan records each output encoding and content digest")
        expect(Int64.parse(createContentMetadata.field("bytes").getOrThrow().asNumberText()) ==
            createContent.toArray().size &&
            Int64.parse(replaceContentMetadata.field("bytes").getOrThrow().asNumberText()) ==
                replacementContent.toArray().size,
            "stored plan records exact UTF-8 output byte lengths")

        let patchMetadata = plan.field("patch_artifact").getOrThrow()
        let patchReference = patchMetadata.field("ref").getOrThrow().text
        let patchDigest = patchMetadata.field("sha256").getOrThrow().text
        expect(patchDigest.size == 64 && patchReference == "blob:sha256:" + patchDigest &&
            Int64.parse(patchMetadata.field("bytes").getOrThrow().asNumberText()) > 0,
            "plan carries a versioned immutable patch reference and digest")
        let patchRead = artifacts.read(patchReference, limit: 1048576).value().getOrThrow()
        expect(patchRead.bytes == patchRead.returnedBytes && !patchRead.truncated,
            "patch artifact is readable in full")
        let patch = parseUnifiedJson(patchRead.content)
        let patchOperations = patch.field("operations").getOrThrow().items
        expect(patch.field("schema").getOrThrow().text == "axyndra.file-patch/v1" &&
            patchOperations.size == 3 &&
            patchOperations[0].field("utf8_content").getOrThrow().text == createContent &&
            patchOperations[1].field("utf8_content").getOrThrow().text == replacementContent &&
            patchOperations[2].field("utf8_content").getOrThrow().text == largeContent,
            "patch artifact contains exact ordered UTF-8 replacement payloads")
        let preview = plan.field("preview").getOrThrow()
        let previewText = preview.field("text").getOrThrow().text
        expect(preview.field("format").getOrThrow().text == "unified_diff" &&
            preview.field("truncated").getOrThrow().asBool() &&
            previewText.toArray().size <= 8192 && previewText.contains("[preview truncated]") &&
            previewText.contains("+++ b/src/e5-02-created.cj") &&
            previewText.contains("+// plan-only marker"),
            "unified preview shows planned changes and truncates at the byte bound")

        runProductFilePlanAuthorizationContracts(
            product,
            database,
            workspace,
            planReference,
            planDigest,
            alphaPath,
            originalAlpha,
            createContent,
            replacementContent,
            largeContent,
            createdPath,
            largeCreatedPath
        )
        let malformed = objectValue([
            ValueField("schema", textValue("axyndra.file-change-proposal/v1")),
            ValueField("operations", listValue([])),
            ValueField("unexpected", boolValue(true))
        ])
        expectRejectedFilePlan(product, database, "e5-02-invalid-shape",
            "fixture-e5-02-invalid-shape", filePlanProgramSource(malformed),
            "application_plan.structure_invalid", "invalid proposal structure is rejected")
        let traversal = filePlanProposal([
            filePlanCreateOperation("../e5-02-outside.cj", "not written")
        ])
        expectRejectedFilePlan(product, database, "e5-02-invalid-path",
            "fixture-e5-02-invalid-path", filePlanProgramSource(traversal),
            "application_plan.path_invalid", "out-of-workspace target is rejected")
        let oversizedPathBuilder = StringBuilder()
        for (_ in 0..1400) { oversizedPathBuilder.append("\u{754C}") }
        expectRejectedFilePlan(product, database, "e5-02-path-byte-limit",
            "fixture-e5-02-path-byte-limit",
            filePlanProgramSource(filePlanProposal([filePlanCreateOperation(
                "src/" + oversizedPathBuilder.toString(), "not written"
            )])),
            "application_plan.path_invalid",
            "non-ASCII target paths are bounded by their UTF-8 byte length")
        let stale = objectValue([
            ValueField("kind", textValue("replace")),
            ValueField("path", textValue("src/alpha.cj")),
            ValueField("expected_content", textValue("stale content")),
            ValueField("content", textValue("not applied"))
        ])
        expectRejectedFilePlan(product, database, "e5-02-stale-precondition",
            "fixture-e5-02-stale-precondition", filePlanProgramSource(filePlanProposal([stale])),
            "application_plan.precondition_conflict", "stale expected file content is rejected")
        expectRejectedFilePlan(product, database, "e5-02-existing-create",
            "fixture-e5-02-existing-create",
            filePlanProgramSource(filePlanProposal([
                filePlanCreateOperation("src/alpha.cj", "not applied")
            ])),
            "application_plan.create_target_exists", "create over an existing file is rejected")
        let mismatch = objectValue([
            ValueField("schema", textValue("axyndra.file-change-proposal/v1")),
            ValueField("source", objectValue([
                ValueField("program_digest", textValue("not-the-prepared-digest"))
            ])),
            ValueField("operations", listValue([
                filePlanCreateOperation("src/e5-02-source-mismatch.cj", "not written")
            ]))
        ])
        expectRejectedFilePlan(product, database, "e5-02-source-mismatch",
            "fixture-e5-02-source-mismatch", filePlanProgramSource(mismatch),
            "application_plan.plugin_proposal_invalid", "proposal cannot supply the actual Host-owned source identity")
        let tooMany = ArrayList<AgentValue>()
        for (index in 0..33) {
            tooMany.add(filePlanCreateOperation(
                "src/e5-02-over-limit-" + index.toString() + ".cj", "x"
            ))
        }
        expectRejectedFilePlan(product, database, "e5-02-operation-limit",
            "fixture-e5-02-operation-limit",
            filePlanProgramSource(filePlanProposal(tooMany.toArray())),
            "application_plan.limit_exceeded", "operation count above the bound is rejected")
        expect(String.fromUtf8(File.readFrom(Path(alphaPath))) == originalAlpha &&
            !exists(Path(workspace + "/src/e5-02-outside.cj")) &&
            !exists(Path(workspace + "/src/e5-02-source-mismatch.cj")),
            "rejected proposals leave all workspace files unchanged")
    } finally {
        database.close()
        binding.configure(false)
    }
    runProductPlanArtifactStoreFailureContract(root, workspace)
}

func runProductFilePlanAuthorizationContracts(
    product: ProductRuntime,
    database: SqliteDatabase,
    workspace: String,
    planReference: String,
    planDigest: String,
    alphaPath: String,
    originalAlpha: String,
    createContent: String,
    replacementContent: String,
    largeContent: String,
    createdPath: String,
    largeCreatedPath: String
): Unit {
    let invalidSessionName = "e5-03-invalid-digest"
    let invalidCallId = "fixture-e5-03-invalid-digest"
    let invalidSession = product.applicationSession(
        sessionId: Some(SessionId(invalidSessionName))
    )
    product.fixtureProbe.getOrThrow().enqueueToolCallReply(
        invalidCallId,
        "apply_file_plan",
        objectValue([
            ValueField("plan_ref", textValue(planReference)),
            ValueField("plan_digest", textValue(planDigest + "-changed"))
        ])
    )
    let invalidResponse = invalidSession.submit(
        "Reject a plan reference whose digest does not match."
    ).value().getOrThrow()
    let (invalidOutput, invalidIsError) = productThreadToolResult(
        database, invalidSessionName, invalidCallId
    )
    expect(invalidResponse.approval.isNone() && invalidSession.approval().isNone() &&
        invalidIsError &&
        invalidOutput.field("error").getOrThrow().text ==
            "application_plan.plan_artifact_invalid",
        "a mismatched plan digest is rejected before approval")
    expect(String.fromUtf8(File.readFrom(Path(alphaPath))) == originalAlpha &&
        !exists(Path(createdPath)) && !exists(Path(largeCreatedPath)),
        "a mismatched plan digest has no workspace effects")

    let nestedProgramSource = "const attempted = await tools.apply_file_plan(" +
        encodeAgentValue(objectValue([
            ValueField("plan_ref", textValue(planReference)),
            ValueField("plan_digest", textValue(planDigest))
        ])) + "); return attempted;"
    let (nestedProgramOutput, nestedProgramIsError) = runProductProgramToolCall(
        product,
        database,
        "e5-03-nested-apply",
        "fixture-e5-03-nested-apply",
        nestedProgramSource
    )
    let nestedProgramError = match (nestedProgramOutput.field("error_code")) {
        case Some(value) => value.text
        case None => ""
    }
    expect(nestedProgramIsError && nestedProgramError == "tool_program.tool_not_allowed" &&
        String.fromUtf8(File.readFrom(Path(alphaPath))) == originalAlpha &&
        !exists(Path(createdPath)) && !exists(Path(largeCreatedPath)),
        "a Program child cannot bypass Core authorization for a file plan")

    let validSessionName = "e5-03-authorize-valid"
    let validCallId = "fixture-e5-03-authorize-valid"
    let validSessionId = SessionId(validSessionName)
    let validSession = product.applicationSession(
        sessionId: Some(validSessionId)
    )
    product.fixtureProbe.getOrThrow().enqueueToolCallReply(
        validCallId,
        "apply_file_plan",
        objectValue([
            ValueField("plan_ref", textValue(planReference)),
            ValueField("plan_digest", textValue(planDigest))
        ])
    )
    let waitingResponse = validSession.submit(
        "Review this stored file application plan."
    ).value().getOrThrow()
    let pendingApproval = validSession.approval().getOrThrow()
    let pendingTargets = pendingApproval.preview.field("approval_targets").getOrThrow().items
    let pendingOperations = pendingApproval.preview.field("operations").getOrThrow().items
    expect(waitingResponse.approval.isSome() &&
        pendingApproval.callId == validCallId &&
        pendingApproval.toolName == "apply_file_plan" &&
        pendingApproval.capability.kind == CapabilityKind.WorkspaceWrite &&
        pendingApproval.preview.field("plan_ref").getOrThrow().text == planReference &&
        pendingApproval.preview.field("plan_digest").getOrThrow().text == planDigest &&
        pendingOperations.size == 3 && pendingTargets.size == 3 &&
        pendingOperations[0].field("path").getOrThrow().text == "src/e5-02-created.cj" &&
        pendingOperations[1].field("path").getOrThrow().text == "src/alpha.cj" &&
        pendingOperations[2].field("path").getOrThrow().text == "src/e5-02-large.cj" &&
        pendingTargets[0].field("path").getOrThrow().text.contains("e5-02-created.cj") &&
        pendingTargets[1].field("path").getOrThrow().text.contains("alpha.cj") &&
        pendingTargets[2].field("path").getOrThrow().text.contains("e5-02-large.cj") &&
        !pendingApproval.sessionApprovalAllowed &&
        !pendingApproval.metadata.sessionApprovalAllowed &&
        pendingTargets[0].field("path").getOrThrow().text.startsWith(
            canonicalize(workspace).toString() + "/"
        ) && pendingTargets[1].field("path").getOrThrow().text.startsWith(
            canonicalize(workspace).toString() + "/"
        ) && pendingTargets[2].field("path").getOrThrow().text.startsWith(
            canonicalize(workspace).toString() + "/"
        ),
        "approval binds the exact immutable plan, ordered targets, and one-time scope")

    let resumedSession = product.applicationSession(
        sessionId: Some(validSessionId)
    )
    let restoredApproval = resumedSession.approval().getOrThrow()
    expect(restoredApproval.operationId.value == pendingApproval.operationId.value &&
        !restoredApproval.sessionApprovalAllowed &&
        !restoredApproval.metadata.sessionApprovalAllowed,
        "restored pending approval retains its one-time-only scope")
    let sessionGrant = resumedSession.decide(
        restoredApproval.operationId.value,
        ApprovalDecision.ApproveSession
    )
    let sessionGrantErrorCode = match (sessionGrant) {
        case Result.Err(error) => error.code
        case Result.Ok(_) => "ok"
    }
    expect(sessionGrantErrorCode == "approval.session_scope_forbidden",
        "session-wide approval returns the one-time-scope error; actual=" + sessionGrantErrorCode)
    expect(resumedSession.approval().isSome(),
        "session-wide approval rejection retains the pending approval")
    let oneTimeResult = resumedSession.decide(
        restoredApproval.operationId.value,
        ApprovalDecision.Approve
    )
    let oneTimeErrorDetail = match (oneTimeResult) {
        case Result.Err(error) => error.code + ": " + error.message
        case Result.Ok(_) => "ok"
    }
    expect(oneTimeErrorDetail == "ok",
        "one-time approval succeeds; actual=" + oneTimeErrorDetail)
    let oneTime = oneTimeResult.value().getOrThrow()
    let (authorizedOutput, authorizedIsError) = productThreadToolResult(
        database, validSessionName, validCallId
    )
    let applicationResults = authorizedOutput.field("results").getOrThrow().items
    expect(oneTime.approval.isNone() && resumedSession.approval().isNone() &&
        !authorizedIsError &&
        authorizedOutput.field("status").getOrThrow().text == "complete" &&
        authorizedOutput.field("stop_reason").getOrThrow().text == "complete" &&
        authorizedOutput.field("applied").getOrThrow().asBool() &&
        authorizedOutput.field("plan_ref").getOrThrow().text == planReference &&
        authorizedOutput.field("plan_digest").getOrThrow().text == planDigest &&
        authorizedOutput.field("applied_count").getOrThrow().asNumberText() == "3" &&
        authorizedOutput.field("conflict_count").getOrThrow().asNumberText() == "0" &&
        authorizedOutput.field("failed_no_effect_count").getOrThrow().asNumberText() == "0" &&
        authorizedOutput.field("not_started_count").getOrThrow().asNumberText() == "0" &&
        authorizedOutput.field("unknown_count").getOrThrow().asNumberText() == "0" &&
        !authorizedOutput.field("reconciliation_required").getOrThrow().asBool() &&
        applicationResults.size == 3 &&
        applicationResults[0].field("status").getOrThrow().text == "applied" &&
        applicationResults[1].field("status").getOrThrow().text == "applied" &&
        applicationResults[2].field("status").getOrThrow().text == "applied",
        "one-time approval applies the exact ordered plan with per-item results")
    expect(String.fromUtf8(File.readFrom(Path(alphaPath))) == replacementContent &&
        String.fromUtf8(File.readFrom(Path(createdPath))) == createContent &&
        String.fromUtf8(File.readFrom(Path(largeCreatedPath))) == largeContent,
        "successful E5-04 execution publishes every approved target exactly")
    let _ = removeIfExists(createdPath)
    let _ = removeIfExists(largeCreatedPath)
    File.writeTo(alphaPath, originalAlpha.toArray())

    let staleSessionName = "e5-03-stale-precondition"
    let staleCallId = "fixture-e5-03-stale-precondition"
    let staleSession = product.applicationSession(
        sessionId: Some(SessionId(staleSessionName))
    )
    product.fixtureProbe.getOrThrow().enqueueToolCallReply(
        staleCallId,
        "apply_file_plan",
        objectValue([
            ValueField("plan_ref", textValue(planReference)),
            ValueField("plan_digest", textValue(planDigest))
        ])
    )
    let _ = staleSession.submit("Approve only while the planned contents remain current.")
        .value().getOrThrow()
    let staleApproval = staleSession.approval().getOrThrow()
    let concurrentAlpha = originalAlpha + "// changed after review\n"
    try {
        File.writeTo(alphaPath, concurrentAlpha.toArray())
        let staleDecision = staleSession.decide(
            staleApproval.operationId.value,
            ApprovalDecision.Approve
        )
        expect(match (staleDecision) {
            case Result.Err(error) => error.code == "application_plan.precondition_conflict"
            case Result.Ok(_) => false
        } && staleSession.approval().isSome() &&
            String.fromUtf8(File.readFrom(Path(alphaPath))) == concurrentAlpha &&
            !exists(Path(createdPath)) && !exists(Path(largeCreatedPath)),
            "approval revalidates target preconditions and refuses stale contents")
    } finally {
        let _ = staleSession.cancel()
        File.writeTo(alphaPath, originalAlpha.toArray())
    }
    runProductFilePlanRecoveryContracts(
        product,
        database,
        planReference,
        planDigest,
        alphaPath,
        originalAlpha,
        createContent,
        replacementContent,
        largeContent,
        createdPath,
        largeCreatedPath
    )
}

func runProductFilePlanRecoveryContracts(
    product: ProductRuntime,
    database: SqliteDatabase,
    planReference: String,
    planDigest: String,
    alphaPath: String,
    originalAlpha: String,
    createContent: String,
    replacementContent: String,
    largeContent: String,
    createdPath: String,
    largeCreatedPath: String
): Unit {
    File.writeTo(createdPath, createContent.toArray())
    let recoverySessionName = "e5-05-partial-recovery"
    let recoveryCallId = "fixture-e5-05-partial-recovery"
    let recoverySession = product.applicationSession(
        sessionId: Some(SessionId(recoverySessionName))
    )
    product.fixtureProbe.getOrThrow().enqueueToolCallReply(
        recoveryCallId,
        "recover_file_plan",
        objectValue([
            ValueField("plan_ref", textValue(planReference)),
            ValueField("plan_digest", textValue(planDigest))
        ])
    )
    let recoverySubmission = recoverySession.submit(
        "Reconcile a partially applied file plan without replaying writes."
    )
    let recoveryResponse = match (recoverySubmission) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(
            "recovery submission failed: " + error.code + ": " + error.message
        )
    }
    let (recoveryOutput, recoveryIsError) = productThreadToolResult(
        database, recoverySessionName, recoveryCallId
    )
    let recoveryItems = recoveryOutput.field("results").getOrThrow().items
    let continuation = recoveryOutput.field("continuation_plan").getOrThrow()
    let continuationRef = continuation.field("plan_ref").getOrThrow().text
    let continuationDigest = continuation.field("plan_digest").getOrThrow().text
    expect(!recoveryIsError && recoveryResponse.approval.isNone() &&
        recoverySession.approval().isNone() &&
        recoveryOutput.field("status").getOrThrow().text == "continuation_ready" &&
        recoveryOutput.field("applied_count").getOrThrow().asNumberText() == "1" &&
        recoveryOutput.field("not_started_count").getOrThrow().asNumberText() == "2" &&
        recoveryOutput.field("conflict_count").getOrThrow().asNumberText() == "0" &&
        recoveryOutput.field("unknown_count").getOrThrow().asNumberText() == "0" &&
        recoveryOutput.field("requires_new_authorization").getOrThrow().asBool() &&
        !recoveryOutput.field("automatic_rollback").getOrThrow().asBool() &&
        recoveryOutput.field("compensation_requires_new_plan").getOrThrow().asBool() &&
        continuationRef != planReference && continuationDigest != planDigest &&
        recoveryItems.size == 3 &&
        recoveryItems[0].field("status").getOrThrow().text == "applied" &&
        recoveryItems[1].field("status").getOrThrow().text == "not_started" &&
        recoveryItems[2].field("status").getOrThrow().text == "not_started" &&
        String.fromUtf8(File.readFrom(Path(createdPath))) == createContent &&
        String.fromUtf8(File.readFrom(Path(alphaPath))) == originalAlpha &&
        !exists(Path(largeCreatedPath)),
        "recovery validates actual state and creates a distinct continuation without replaying writes")

    let continuationSessionName = "e5-05-continuation-apply"
    let continuationCallId = "fixture-e5-05-continuation-apply"
    let continuationSession = product.applicationSession(
        sessionId: Some(SessionId(continuationSessionName))
    )
    product.fixtureProbe.getOrThrow().enqueueToolCallReply(
        continuationCallId,
        "apply_file_plan",
        objectValue([
            ValueField("plan_ref", textValue(continuationRef)),
            ValueField("plan_digest", textValue(continuationDigest))
        ])
    )
    let continuationWaiting = continuationSession.submit(
        "Apply the fresh continuation only after separate authorization."
    ).value().getOrThrow()
    let continuationApproval = continuationSession.approval().getOrThrow()
    let continuationOperations = continuationApproval.preview.field("operations")
        .getOrThrow().items
    expect(continuationWaiting.approval.isSome() &&
        continuationOperations.size == 2 &&
        continuationOperations[0].field("path").getOrThrow().text == "src/alpha.cj" &&
        continuationOperations[1].field("path").getOrThrow().text == "src/e5-02-large.cj" &&
        String.fromUtf8(File.readFrom(Path(createdPath))) == createContent &&
        String.fromUtf8(File.readFrom(Path(alphaPath))) == originalAlpha &&
        !exists(Path(largeCreatedPath)),
        "continuation is a new canonical operation and cannot reuse the earlier write authorization")
    let continued = continuationSession.decide(
        continuationApproval.operationId.value,
        ApprovalDecision.Approve
    ).value().getOrThrow()
    let (continuedOutput, continuedIsError) = productThreadToolResult(
        database, continuationSessionName, continuationCallId
    )
    expect(continued.approval.isNone() && !continuedIsError &&
        continuedOutput.field("status").getOrThrow().text == "complete" &&
        continuedOutput.field("applied_count").getOrThrow().asNumberText() == "2" &&
        String.fromUtf8(File.readFrom(Path(createdPath))) == createContent &&
        String.fromUtf8(File.readFrom(Path(alphaPath))) == replacementContent &&
        String.fromUtf8(File.readFrom(Path(largeCreatedPath))) == largeContent,
        "freshly authorized continuation applies only the previously unexecuted operations")

    let completeSessionName = "e5-05-reconcile-complete"
    let completeCallId = "fixture-e5-05-reconcile-complete"
    let completeSession = product.applicationSession(
        sessionId: Some(SessionId(completeSessionName))
    )
    product.fixtureProbe.getOrThrow().enqueueToolCallReply(
        completeCallId,
        "recover_file_plan",
        objectValue([
            ValueField("plan_ref", textValue(planReference)),
            ValueField("plan_digest", textValue(planDigest))
        ])
    )
    let _ = completeSession.submit(
        "Reconcile a plan whose writes all happened before its result was recorded."
    ).value().getOrThrow()
    let (completeOutput, completeIsError) = productThreadToolResult(
        database, completeSessionName, completeCallId
    )
    expect(!completeIsError &&
        completeOutput.field("status").getOrThrow().text == "reconciled_complete" &&
        completeOutput.field("applied_count").getOrThrow().asNumberText() == "3" &&
        completeOutput.field("not_started_count").getOrThrow().asNumberText() == "0" &&
        !completeOutput.field("requires_new_authorization").getOrThrow().asBool() &&
        completeOutput.field("continuation_plan").getOrThrow().unifiedKind == ValueKind.Null,
        "recovery recognizes completed effects and never blindly replays an unrecorded write")

    let userAlpha = replacementContent + "// user change after application\n"
    File.writeTo(alphaPath, userAlpha.toArray())
    let conflictSessionName = "e5-05-recovery-user-conflict"
    let conflictCallId = "fixture-e5-05-recovery-user-conflict"
    let conflictSession = product.applicationSession(
        sessionId: Some(SessionId(conflictSessionName))
    )
    product.fixtureProbe.getOrThrow().enqueueToolCallReply(
        conflictCallId,
        "recover_file_plan",
        objectValue([
            ValueField("plan_ref", textValue(planReference)),
            ValueField("plan_digest", textValue(planDigest))
        ])
    )
    let _ = conflictSession.submit(
        "Reconcile without overwriting a later user edit."
    ).value().getOrThrow()
    let (conflictOutput, conflictIsError) = productThreadToolResult(
        database, conflictSessionName, conflictCallId
    )
    expect(conflictIsError &&
        conflictOutput.field("status").getOrThrow().text == "conflict" &&
        conflictOutput.field("applied_count").getOrThrow().asNumberText() == "2" &&
        conflictOutput.field("conflict_count").getOrThrow().asNumberText() == "1" &&
        !conflictOutput.field("requires_new_authorization").getOrThrow().asBool() &&
        !conflictOutput.field("automatic_rollback").getOrThrow().asBool() &&
        conflictOutput.field("continuation_plan").getOrThrow().unifiedKind == ValueKind.Null &&
        String.fromUtf8(File.readFrom(Path(alphaPath))) == userAlpha &&
        String.fromUtf8(File.readFrom(Path(createdPath))) == createContent &&
        String.fromUtf8(File.readFrom(Path(largeCreatedPath))) == largeContent,
        "recovery reports conflict and never lets rollback overwrite a later user change")

    let _ = removeIfExists(createdPath)
    let _ = removeIfExists(largeCreatedPath)
    File.writeTo(alphaPath, originalAlpha.toArray())
}

func runProductPlanArtifactStoreFailureContract(root: String, workspace: String): Unit {
    let failureStateRoot = root + "/file-plan-artifact-failure-state"
    let storageFault=NativeProgramPlanArtifactFault("e5-02-artifact-store-failure",failureStateRoot+"/blobs")
    let product = openProduct(config: ProductConfig(
        settingsRoot: root + "/file-plan-artifact-failure-settings",
        stateRoot: failureStateRoot,
        workspaceRoot: workspace,
        fixture: true,
        asyncEnabled: false,
        fixtureTransactionCommitMonitor:Some({transaction=>storageFault.observe(transaction)})
    )).value().getOrThrow()
    let database = SqliteDatabase(failureStateRoot + "/state.db")
    try {
        let binding=NativeProgramContractBinding(product,filePlanProposals:true,inputAttachment:false)
        storageFault.selectActualRead(binding.workspaceName("read"))
        let originalAlpha = String.fromUtf8(File.readFrom(
            Path(workspace + "/src/alpha.cj")
        ))
        let failureValue = objectValue([
            ValueField("application_plan", filePlanProposal([
                filePlanReplaceOperation(
                    "src/alpha.cj", originalAlpha,
                    originalAlpha + "// must remain unapplied\n"
                )
            ]))
        ])
        let failureSource =
            "const inspected = await tools.read({\"path\":\"src/alpha.cj\"});\n" +
            "return " + encodeAgentValue(failureValue) + ";"
        let (output, isError) = runProductProgramToolCall(
            product, database, "e5-02-artifact-store-failure",
            "fixture-e5-02-artifact-store-failure", failureSource
        )
        let errorCode = match (output.field("error_code")) {
            case Some(value) => value.text
            case None => ""
        }
        expect(storageFault.wasApplied() && isError && errorCode == "application_plan.artifact_store_unavailable" &&
            String.fromUtf8(File.readFrom(Path(workspace + "/src/alpha.cj"))) == originalAlpha,
            "missing plan artifact storage rejects generation without changing workspace")
    } finally {
        database.close()
        storageFault.restore()
        product.close().value().getOrThrow()
    }
}


// Test consumer DATA only. No copied metadata becomes an installed Source,
// pin, receipt, grant, operation, or replacement public Registry record.
// The source Registry byte carrier pays its complete copied graph before
// allocating an Array/String/DOM. Original configuration/public fixture text
// has no retirement protocol, so those independent loans remain paid.
class SupportRegistryCopyDebt96 {
    let payment:LogicalJsonOwnerReservation
    let previous:?SupportRegistryCopyDebt96
    init(payment:LogicalJsonOwnerReservation,previous:?SupportRegistryCopyDebt96){
        this.payment=payment;this.previous=previous}
}
class SupportRegistryRecordData96 {
    let record:ProductPluginRecord
    private let graph:AgentValue
    private let payment:LogicalJsonOwnerReservation
    private let lock=Mutex()
    private var pending:?LogicalJsonOwnerReservation=None<LogicalJsonOwnerReservation>
    let enabled:Bool
    let explicitlyDisabled:Bool
    let sourceKind:PluginSourceKind
    let scope:PluginInstallScope
    let previous:?SupportRegistryRecordData96
    init(record:ProductPluginRecord,graph:AgentValue,payment:LogicalJsonOwnerReservation,
        enabled:Bool,explicitlyDisabled:Bool,sourceKind:PluginSourceKind,scope:PluginInstallScope,
        previous:?SupportRegistryRecordData96){
        this.record=record;this.graph=graph;this.payment=payment
        this.enabled=enabled;this.explicitlyDisabled=explicitlyDisabled;this.sourceKind=sourceKind
        this.scope=scope;this.previous=previous}
    func text(key:String,descriptor!:Bool=false):String{
        lock.lock();try{
            if(pending.isSome()){throw LogicalJsonPayloadError("same copied metadata keeps its failed occurrence payment")}
            let value=if(descriptor){graph.field("descriptor").getOrThrow().field(key).getOrThrow().text}
                else{graph.field(key).getOrThrow().text}
            let loan=payment.deriveRetainedLease();pending=Some(loan)
            loan.ensureRetainedPeak(supportRegistryInvoice96(value.size,0))
            supportRegistryRetain96(loan);pending=None<LogicalJsonOwnerReservation>;value
        }finally{lock.unlock()}
    }
}
class SupportRegistryCopies96 {
    let lock=Mutex()
    var payments:?SupportRegistryCopyDebt96=None<SupportRegistryCopyDebt96>
    var records:?SupportRegistryRecordData96=None<SupportRegistryRecordData96>
}
let supportRegistryCopies96=SupportRegistryCopies96()
func supportRegistryInvoice96(bytes:Int64,nodes:Int64):Int64{
    if(bytes<0 || nodes<0 || nodes>(134217728-8192)/1024 ||
        bytes>(134217728-8192-nodes*1024)/64){
        throw LogicalJsonPayloadError("registry copied data cannot fit the original shared capacity")}
    bytes*64+nodes*1024+8192
}
func supportRegistryRetain96(payment:LogicalJsonOwnerReservation):Unit{
    supportRegistryCopies96.lock.lock();try{
        supportRegistryCopies96.payments=Some(SupportRegistryCopyDebt96(payment,supportRegistryCopies96.payments))
    }finally{supportRegistryCopies96.lock.unlock()}
}
func supportRegistryText96(result:PluginRegistryResult<OwnedRegistryUtf8>):String{
    let source=match(result){case PluginRegistryResult.Ok(value)=>value
        case PluginRegistryResult.Err(error)=>throw IllegalStateException(supportRegistryExclusiveErrorText96(error))}
    try{
        let size=source.byteCount
        let payment=source.deriveCopiedDataPayment(supportRegistryInvoice96(size,0))
        supportRegistryRetain96(payment)
        let bytes=Array<UInt8>(size,{index=>source.byteAt(index)})
        String.fromUtf8(bytes)
    }finally{source.close()}
}
func supportRegistryErrorText96(error:PluginRegistryOwnedError):String{
        match(error.staticReason){
            case PluginRegistryStaticReason.MetadataCapacity=>"registry metadata cannot fit the original shared capacity"
            case PluginRegistryStaticReason.ExecutionNotCurrent=>"installed execution pin is not current"
            case PluginRegistryStaticReason.InstalledRecordAbsent=>"installed record is absent"
            case PluginRegistryStaticReason.ComponentAliasInvalid=>"initial context configuration or its exact installed binding is unavailable"
            case PluginRegistryStaticReason.None=>supportRegistryText96(error.copyText(PluginRegistryErrorText.Message))}
}
func supportRegistryExclusiveErrorText96(error:PluginRegistryOwnedError):String{
    try{supportRegistryErrorText96(error)}finally{error.close()}
}
func supportRegistryExclusiveErrorCode96(error:PluginRegistryOwnedError):String{
    try{error.code}finally{error.close()}
}
func supportRegistryDiscard96(record:ProductPluginRecord):Unit{record.close()}
func supportRegistryOkay96(result:PluginRegistryResult<ProductPluginRecord>):Bool{
    match(result){case PluginRegistryResult.Ok(record)=>record.close();true
        case PluginRegistryResult.Err(error)=>error.close();false}
}
func supportRegistryData96(record:ProductPluginRecord):SupportRegistryRecordData96{
    supportRegistryCopies96.lock.lock();try{
        var current=supportRegistryCopies96.records
        while(current.isSome()){
            let row=current.getOrThrow()
            if(refEq(row.record,record)){return row};current=row.previous}
    }finally{supportRegistryCopies96.lock.unlock()}
    // Read real immutable scalar data while the actual view is live. State
    // replacement may revoke it later; the test's original metadata stays in
    // this independent same-bank copy instead of resurrecting that view.
    let enabled=record.enabled;let disabled=record.explicitlyDisabled
    let kind=record.sourceKind;let scope=record.scope
    let source=match(record.copyJson()){case PluginRegistryResult.Ok(value)=>value
        case PluginRegistryResult.Err(error)=>throw IllegalStateException(supportRegistryExclusiveErrorText96(error))}
    try{
        let size=source.byteCount
        var quoted=false;var escaped=false;var primitive=false;var nodes:Int64=0
        for(index in 0..size){
            let byte=source.byteAt(index)
            if(quoted){if(escaped){escaped=false}else if(byte==92u8){escaped=true}else if(byte==34u8){quoted=false};continue}
            if(byte==34u8){nodes+=1;quoted=true;primitive=false}
            else if(byte==123u8 || byte==91u8){nodes+=1;primitive=false}
            else if(byte==44u8 || byte==58u8 || byte==125u8 || byte==93u8 || byte<=32u8){primitive=false}
            else if(!primitive){nodes+=1;primitive=true}}
        let payment=source.deriveCopiedDataPayment(supportRegistryInvoice96(size,nodes))
        supportRegistryRetain96(payment)
        let bytes=Array<UInt8>(size,{index=>source.byteAt(index)})
        let graph=parseUnifiedJson(String.fromUtf8(bytes),maxBytes:size)
        supportRegistryCopies96.lock.lock();try{
            let row=SupportRegistryRecordData96(record,graph,payment,enabled,disabled,kind,scope,supportRegistryCopies96.records)
            supportRegistryCopies96.records=Some(row);row
        }finally{supportRegistryCopies96.lock.unlock()}
    }finally{source.close()}
}
func supportRegistryRecord96(record:ProductPluginRecord):ProductPluginRecord{
    let _=supportRegistryData96(record);record
}
func supportRegistryDescriptor96(record:ProductPluginRecord,key:String):String{
    let row=supportRegistryData96(record)
    // Each returned occurrence is separately paid before it can escape into
    // configuration, a path, a fixture field, an exception or another frame.
    row.text(key,descriptor:true)
}
func supportRegistryField96(record:ProductPluginRecord,key:String):String{
    supportRegistryData96(record).text(key)
}
