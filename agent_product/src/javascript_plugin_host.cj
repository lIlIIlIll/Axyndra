package agent_product

import agent_domain.*
import agent_extension_runtime.*
import yjson.*
import yjson_support.*
import tool_runtime.*
import process4cj as process
import std.collection.*
import sandbox4cj.*
import std.sync.*
// Product-owned lifecycle wrapper for the process-backed JavaScript host. The
// extension runtime owns the wire protocol; this layer owns activation,
// cancellation bridging, tool registration, and product error semantics.
public class ProductJavaScriptPluginInvocationResult {
    public let value: AgentValue
    public let isError: Bool

    public init(value: AgentValue, isError: Bool) {
        this.value = value
        this.isError = isError
    }
}
public class ProductJavaScriptPluginCommand {
    public let extensionId: String
    public let name: String
    public let description: String

    public init(extensionId: String, name: String, description: String) {
        this.extensionId = extensionId
        this.name = name
        this.description = description
    }

    public prop routeName: String {
        get() { "plugin." + extensionId + "." + name }
    }
}

public class ProductJavaScriptPluginHook {
    public let extensionId: String
    public let descriptor: JavaScriptHookDescriptor

    public init(extensionId: String, descriptor: JavaScriptHookDescriptor) {
        this.extensionId = extensionId
        this.descriptor = descriptor
    }
}
public class ProductJavaScriptPluginHost {
    private let lock = Mutex()
    private let generations = ArrayList<ProductJavaScriptPluginGeneration>()
    private var closed = false

    private let launcher: JavaScriptHostProcessLauncher
    public init() {
        launcher = ProductSandboxedJavaScriptHostLauncher()
    }
    public func mount(record: ProductPluginRecord): Result<Array<JavaScriptToolDescriptor>> {
        let descriptor = record.descriptor
        if (descriptor.entrypoint.trimAscii() == "") {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "plugin.entrypoint_missing",
                "JavaScript plugin activation requires an entrypoint"
            ))
        }
        if (descriptor.ecosystem != PluginEcosystem.Pi) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "plugin.ecosystem_unsupported",
                "only Pi ExtensionAPI packages can use the JavaScript extension host"
            ))
        }
        for (capability in descriptor.requestedCapabilities) {
            if (capability != "workspace.read" && capability != "workspace.write") {
                return Result.Err(AgentError(
                    AgentErrorKind.PermissionDenied,
                    "plugin.capability_unsupported",
                    "the JavaScript host supports workspace.read and workspace.write grants only"
                ))
            }
        }
        let bootstrap = match (startProductJavaScriptHost(descriptor, 1u64, launcher)) {
            case JavaScriptHostResult.Ok(value) => value
            case JavaScriptHostResult.Err(error) => return Result.Err(
                javascriptPluginAgentError(error)
            )
        }
        let tools = bootstrap.tools
        let commands = bootstrap.commands
        let hooks = bootstrap.hooks
        bootstrap.close()
        lock.lock()
        try {
            if (closed) {
                return Result.Err(AgentError(
                    AgentErrorKind.Configuration,
                    "plugin.host_closed",
                    "JavaScript plugin host is closed"
                ))
            }
            if (findLocked(descriptor.namespace).isSome()) {
                return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "plugin.already_active",
                    "the plugin already has an active JavaScript generation"
                ))
            }
            generations.add(ProductJavaScriptPluginGeneration(
                descriptor, tools, commands, hooks, 2u64
            ))
            Result.Ok(tools)
        } finally {
            lock.unlock()
        }
    }

    public func toolNames(extensionId: String): Array<String> {
        lock.lock()
        try {
            match (findLocked(extensionId.trimAscii())) {
                case Some(value) => value.toolNames()
                case None => []
            }
        } finally {
            lock.unlock()
        }
    }
    public func commands(): Array<ProductJavaScriptPluginCommand> {
        lock.lock()
        try {
            let output = ArrayList<ProductJavaScriptPluginCommand>()
            for (generation in generations) {
                for (command in generation.commands) {
                    output.add(ProductJavaScriptPluginCommand(
                        generation.extensionId, command.name, command.description
                    ))
                }
            }
            output.toArray()
        } finally {
            lock.unlock()
        }
    }

    public func hookDescriptors(): Array<ProductJavaScriptPluginHook> {
        lock.lock()
        try {
            let output = ArrayList<ProductJavaScriptPluginHook>()
            for (generation in generations) {
                for (hook in generation.hooks) {
                    output.add(ProductJavaScriptPluginHook(generation.extensionId, hook))
                }
            }
            output.toArray()
        } finally {
            lock.unlock()
        }
    }
    public func unmount(extensionId: String): Result<Unit> {
        var removed: ?ProductJavaScriptPluginGeneration = None
        lock.lock()
        try {
            for (index in 0..generations.size) {
                if (generations[index].extensionId == extensionId.trimAscii()) {
                    removed = Some(generations.remove(at: index))
                    break
                }
            }
        } finally {
            lock.unlock()
        }
        match (removed) {
            case Some(value) =>
                value.closeHosts()
                Result.Ok(())
            case None => Result.Ok(())
        }
    }

    public func close(): Result<Unit> {
        let removed = ArrayList<ProductJavaScriptPluginGeneration>()
        lock.lock()
        try {
            closed = true
            while (generations.size > 0) {
                removed.add(generations.remove(at: generations.size - 1))
            }
        } finally {
            lock.unlock()
        }
        for (generation in removed) { generation.closeHosts() }
        Result.Ok(())
    }
    public func invoke(
        extensionId: String,
        tool: String,
        argumentsJson: String,
        identity!: JavaScriptHostInvocationIdentity,
        cancellation!: CancellationToken,
        cwd!: String = "",
        hasUI!: Bool = false,
        processLimits!: ExecutionResourceLimits = ExecutionResourceLimits(),
        timeoutMillis!: Int64 = 0,
        observer!: ?JavaScriptHostObserver = None
    ): Result<ProductJavaScriptPluginInvocationResult> {
        if (cancellation.isCancelled()) {
            return javascriptPluginError<ProductJavaScriptPluginInvocationResult>(
                "extension.cancelled", "JavaScript plugin invocation was cancelled"
            )
        }
        if (!javascriptPluginLimitsFitHost(processLimits)) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "plugin.resource_limit_unavailable",
                "persistent JavaScript plugin host cannot enforce stricter per-invocation process limits"
            ))
        }
        let generation = match (find(extensionId.trimAscii())) {
            case Some(value) => value
            case None => return javascriptPluginError<ProductJavaScriptPluginInvocationResult>(
                "plugin.not_active", "JavaScript plugin has no active generation"
            )
        }
        let entry = match (generation.threadHost(identity.threadId, launcher)) {
            case JavaScriptHostResult.Ok(value) => value
            case JavaScriptHostResult.Err(error) => return Result.Err(javascriptPluginAgentError(error))
        }
        let processCancellation = match (generation.invocationCancellation(cancellation.deadlineMillis)) {
            case Some(value) => value
            case None => return javascriptPluginError<ProductJavaScriptPluginInvocationResult>(
                "plugin.not_active", "JavaScript plugin generation was revoked"
            )
        }
        entry.invokeLock.lock()
        if (cancellation.isCancelled()) {
            entry.invokeLock.unlock()
            processCancellation.close()
            return javascriptPluginError<ProductJavaScriptPluginInvocationResult>(
                "extension.cancelled", "JavaScript plugin invocation was cancelled"
            )
        }
        match (generation.threadHost(identity.threadId, launcher)) {
            case JavaScriptHostResult.Ok(_) => ()
            case JavaScriptHostResult.Err(error) =>
                entry.invokeLock.unlock()
                processCancellation.close()
                return Result.Err(javascriptPluginAgentError(error))
        }
        let registration = cancellation.onCancel({ _ =>
            let _ = processCancellation.cancel()
            entry.host.close()
        })
        try {
            let response = entry.host.invoke(
                tool,
                argumentsJson,
                identity: identity,
                context: Some(JavaScriptHostInvocationContext(cwd: cwd, hasUI: hasUI)),
                cancellation: processCancellation.token,
                timeoutMillis: timeoutMillis,
                observer: observer
            )
            if (generation.isClosing()) {
                return javascriptPluginError<ProductJavaScriptPluginInvocationResult>(
                    "extension.cancelled", "JavaScript plugin generation was revoked"
                )
            }
            if (cancellation.isCancelled()) {
                return javascriptPluginError<ProductJavaScriptPluginInvocationResult>(
                    "extension.cancelled", "JavaScript plugin invocation was cancelled"
                )
            }
            match (response) {
                case JavaScriptHostResult.Err(error) =>
                    Result.Err(javascriptPluginAgentError(error))
                case JavaScriptHostResult.Ok(value) =>
                    match (javascriptPluginDecodeValue(
                        value.resultJson, maxBytes: JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES
                    )) {
                        case Result.Ok(result) => Result.Ok(ProductJavaScriptPluginInvocationResult(
                            result, value.isError
                        ))
                        case Result.Err(error) => javascriptPluginError<ProductJavaScriptPluginInvocationResult>(
                            "extension.result_invalid", error.message
                        )
                    }
            }
        } finally {
            entry.invokeLock.unlock()
            registration.dispose()
            processCancellation.close()
        }
    }

    private func find(extensionId: String): ?ProductJavaScriptPluginGeneration {
        lock.lock()
        try { findLocked(extensionId) } finally { lock.unlock() }
    }

    private func findLocked(extensionId: String): ?ProductJavaScriptPluginGeneration {
        for (generation in generations) {
            if (generation.extensionId == extensionId) { return Some(generation) }
        }
        None
    }
}

class ProductSandboxedJavaScriptHostLauncher <: JavaScriptHostProcessLauncher {
    public func launch(
        command: process.ProcessCommand
    ): JavaScriptHostResult<process.ManagedProcess> {
        let sandbox = try {
            WorkspaceSandbox(WorkspaceSandboxPolicy(
                command.workingDirectory,
                filesystem: FilesystemIsolationMode.WorkspaceReadOnly,
                process: ProcessIsolationMode.Isolated,
                network: NetworkIsolationMode.Denied,
                environment: EnvironmentFilter(),
                resources: productJavaScriptHostResourceLimits(command.maxOutputBytes)
            ))
        } catch (error: Exception) {
            return JavaScriptHostResult.Err(JavaScriptHostError(
                "extension.sandbox_configuration", error.message
            ))
        }
        match (sandbox.availability()) {
            case SandboxResult.Ok(_) => ()
            case SandboxResult.Err(error) => return JavaScriptHostResult.Err(JavaScriptHostError(
                error.code, error.message
            ))
        }
        let plan = match (sandbox.plan(WorkspaceSandboxCommand(
            command.executable,
            arguments: command.arguments,
            workingDirectory: command.workingDirectory,
            timeoutMillis: 600000
        ))) {
            case SandboxResult.Ok(value) => value
            case SandboxResult.Err(error) => return JavaScriptHostResult.Err(JavaScriptHostError(
                error.code, error.message
            ))
        }
        try {
            JavaScriptHostResult.Ok(process.startProcess(process.ProcessCommand(
                plan.sandboxExecutable,
                arguments: plan.sandboxArguments,
                workingDirectory: plan.workingDirectory,
                environment: HashMap<String, String>(),
                maxOutputBytes: command.maxOutputBytes,
                terminateProcessTree: true
            )))
        } catch (error: Exception) {
            JavaScriptHostResult.Err(JavaScriptHostError(
                "extension.sandbox_process_spawn_failed", error.message
            ))
        }
    }
}

func productJavaScriptHostResourceLimits(maxOutputBytes: Int64): SandboxResourceLimits {
    SandboxResourceLimits(
        maxOutputBytes: maxOutputBytes,
        addressSpaceBytes: 4294967296,
        fileSizeBytes: 67108864,
        openFiles: 256,
        processes: 128,
        cpuSeconds: 3600
    )
}

func javascriptPluginLimitsFitHost(requested: ExecutionResourceLimits): Bool {
    let host = productJavaScriptHostResourceLimits(
        JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES * 4
    )
    javascriptPluginLimitFitsHost(requested.maxOutputBytes, host.maxOutputBytes) &&
    javascriptPluginLimitFitsHost(requested.addressSpaceBytes, host.addressSpaceBytes) &&
    javascriptPluginLimitFitsHost(requested.fileSizeBytes, host.fileSizeBytes) &&
    javascriptPluginLimitFitsHost(requested.openFiles, host.openFiles) &&
    javascriptPluginLimitFitsHost(requested.processes, host.processes) &&
    javascriptPluginLimitFitsHost(requested.cpuSeconds, host.cpuSeconds)
}

func javascriptPluginLimitFitsHost(requested: Int64, host: Int64): Bool {
    requested == 0 || requested >= host
}

class ProductJavaScriptPluginThreadHost {
    let threadId: String
    var host: JavaScriptExtensionHost
    let invokeLock = Mutex()

    init(threadId: String, host: JavaScriptExtensionHost) {
        this.threadId = threadId
        this.host = host
    }
}

class ProductJavaScriptPluginGeneration {
    let extensionId: String
    let descriptor: PluginPackageDescriptor
    let tools: Array<JavaScriptToolDescriptor>
    let commands: Array<JavaScriptCommandDescriptor>
    let hooks: Array<JavaScriptHookDescriptor>
    private let hostLock = Mutex()
    private let threadHosts = ArrayList<ProductJavaScriptPluginThreadHost>()
    private var nextGeneration: UInt64
    private var closing = false
    private let revocation = process.CancellationSource()

    init(
        descriptor: PluginPackageDescriptor,
        tools: Array<JavaScriptToolDescriptor>,
        commands: Array<JavaScriptCommandDescriptor>,
        hooks: Array<JavaScriptHookDescriptor>,
        nextGeneration: UInt64
    ) {
        this.extensionId = descriptor.namespace
        this.descriptor = descriptor
        this.tools = tools
        this.commands = commands
        this.hooks = hooks
        this.nextGeneration = nextGeneration
    }

    func toolNames(): Array<String> {
        let names = ArrayList<String>()
        for (tool in tools) { names.add(tool.name) }
        names.toArray()
    }

    func matchesDeclarations(host: JavaScriptExtensionHost): Bool {
        let actualTools = host.tools
        let actualCommands = host.commands
        let actualHooks = host.hooks
        if (actualTools.size != tools.size || actualCommands.size != commands.size ||
            actualHooks.size != hooks.size) { return false }
        for (index in 0..tools.size) {
            if (actualTools[index].name != tools[index].name ||
                actualTools[index].description != tools[index].description ||
                actualTools[index].inputSchemaJson != tools[index].inputSchemaJson) { return false }
        }
        for (index in 0..commands.size) {
            if (actualCommands[index].name != commands[index].name ||
                actualCommands[index].description != commands[index].description) { return false }
        }
        for (index in 0..hooks.size) {
            if (actualHooks[index].reference != hooks[index].reference) { return false }
        }
        true
    }

    func threadHost(
        threadId: String,
        launcher: JavaScriptHostProcessLauncher
    ): JavaScriptHostResult<ProductJavaScriptPluginThreadHost> {
        hostLock.lock()
        try {
            if (closing) {
                return JavaScriptHostResult.Err(JavaScriptHostError(
                    "plugin.not_active", "JavaScript plugin is no longer active"
                ))
            }
            if (threadId.trimAscii() == "") {
                return JavaScriptHostResult.Err(JavaScriptHostError(
                    "extension.invocation_identity_invalid", "JavaScript plugin invocation requires a thread identity"
                ))
            }
            var selected: ?ProductJavaScriptPluginThreadHost = None
            for (entry in threadHosts where entry.threadId == threadId) {
                selected = Some(entry)
                break
            }
            let entry = match (selected) {
                case Some(value) => value
                case None =>
                    if (threadHosts.size >= 64) {
                        return JavaScriptHostResult.Err(JavaScriptHostError(
                            "extension.pi_thread_limit", "Pi extension reached the 64-thread state limit"
                        ))
                    }
                    let started = startThreadHost(launcher)
                    match (started) {
                        case JavaScriptHostResult.Err(error) => return JavaScriptHostResult.Err(error)
                        case JavaScriptHostResult.Ok(value) =>
                            let added = ProductJavaScriptPluginThreadHost(threadId, value)
                            threadHosts.add(added)
                            return JavaScriptHostResult.Ok(added)
                    }
            }
            if (!entry.host.isClosed) { return JavaScriptHostResult.Ok(entry) }
            match (startThreadHost(launcher)) {
                case JavaScriptHostResult.Err(error) => JavaScriptHostResult.Err(error)
                case JavaScriptHostResult.Ok(value) =>
                    entry.host = value
                    JavaScriptHostResult.Ok(entry)
            }
        } finally {
            hostLock.unlock()
        }
    }

    private func startThreadHost(
        launcher: JavaScriptHostProcessLauncher
    ): JavaScriptHostResult<JavaScriptExtensionHost> {
        if (descriptor.contentDigest.trimAscii() != "") {
            let inspected = match (inspectPluginPackage(descriptor.root)) {
                case PluginPackageResult.Ok(value) => value
                case PluginPackageResult.Err(_) => return JavaScriptHostResult.Err(JavaScriptHostError(
                    "plugin.snapshot_stale", "Pi package no longer matches its mounted snapshot"
                ))
            }
            if (inspected.namespace != descriptor.namespace ||
                inspected.version != descriptor.version ||
                inspected.contentDigest != descriptor.contentDigest ||
                inspected.root != descriptor.root) {
                return JavaScriptHostResult.Err(JavaScriptHostError(
                    "plugin.snapshot_stale", "Pi package no longer matches its mounted snapshot"
                ))
            }
        }
        let started = match (startProductJavaScriptHost(descriptor, nextGeneration, launcher)) {
            case JavaScriptHostResult.Err(error) => return JavaScriptHostResult.Err(error)
            case JavaScriptHostResult.Ok(value) => value
        }
        if (!matchesDeclarations(started)) {
            started.close()
            return JavaScriptHostResult.Err(JavaScriptHostError(
                "plugin.registration_changed", "Pi package registrations changed after activation"
            ))
        }
        nextGeneration += 1u64
        JavaScriptHostResult.Ok(started)
    }
    func isClosing(): Bool {
        hostLock.lock()
        try { closing }
        finally { hostLock.unlock() }
    }

    func invocationCancellation(deadlineMillis: Int64): ?process.CancellationSource {
        hostLock.lock()
        try {
            if (closing) { return None }
            Some(revocation.child(deadlineMillis: deadlineMillis))
        } finally {
            hostLock.unlock()
        }
    }

    func closeHosts(): Unit {
        hostLock.lock()
        let activeHosts = try {
            closing = true
            threadHosts.toArray()
        } finally {
            hostLock.unlock()
        }
        let _ = revocation.cancel()
        for (entry in activeHosts) {
            entry.host.close()
        }
        revocation.close()
    }
}

public class ProductJavaScriptPluginToolExecutor <: ToolExecutor {
    private let host: ProductJavaScriptPluginHost
    private let extensionId: String
    private let toolName: String
    private let serviceRuntime: ?ProductJavaScriptPluginServiceRuntime

    public init(
        host: ProductJavaScriptPluginHost,
        extensionId: String,
        toolName: String
    ) {
        this.host = host
        this.extensionId = extensionId.trimAscii()
        this.toolName = toolName.trimAscii()
        this.serviceRuntime = None
    }

    init(
        host: ProductJavaScriptPluginHost,
        extensionId: String,
        toolName: String,
        serviceRuntime!: ?ProductJavaScriptPluginServiceRuntime
    ) {
        this.host = host
        this.extensionId = extensionId.trimAscii()
        this.toolName = toolName.trimAscii()
        this.serviceRuntime = serviceRuntime
    }

    public func execute(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolResult> {
        if (context.cancellation.isCancelled()) {
            return Result.Err(AgentError(
                AgentErrorKind.Cancelled,
                "extension.cancelled",
                "JavaScript plugin invocation was cancelled"
            ))
        }
        if (context.epoch < 1) {
            return Result.Err(AgentError(
                AgentErrorKind.Protocol,
                "extension.invocation_identity_invalid",
                "JavaScript plugin invocation requires the active run epoch"
            ))
        }
        let identity = JavaScriptHostInvocationIdentity(
            threadId: context.sessionId.value,
            runId: context.runId.value,
            epoch: context.epoch,
            operationId: prepared.operationId.value,
            callId: prepared.call.callId
        )
        let observer: JavaScriptHostObserver = match (serviceRuntime) {
            case Some(runtime) => runtime.observer(context, prepared)
            case None => ProductJavaScriptPluginInvocationObserver(context, prepared, None)
        }
        let hasUI = match (serviceRuntime) {
            case Some(runtime) => runtime.hasUI(context.sessionId)
            case None => false
        }
        let workingDirectory = if (context.cwd.trimAscii() == "") {
            context.workspaceRoot
        } else {
            context.cwd
        }
        match (host.invoke(
            extensionId,
            toolName,
            stringifyUnifiedJson(prepared.operationPlan.canonicalArguments),
            identity: identity,
            cancellation: context.cancellation,
            cwd: workingDirectory,
            hasUI: hasUI,
            processLimits: context.budget.processLimits,
            observer: Some(observer)
        )) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(value) =>
                match (context.outputSink.emit(ToolOutputChunk(
                    prepared.call.callId,
                    if (value.isError) { ToolOutputChannel.Stderr } else { ToolOutputChannel.Stdout },
                    stringifyUnifiedJson(value.value)
                ))) {
                    case Result.Err(error) => Result.Err(error)
                    case Result.Ok(_) => Result.Ok(ToolResult(
                        prepared.call.callId,
                        value.value,
                        isError: value.isError
                    ))
                }
        }
    }

    public func cancel(runId: RunId): Result<Unit> {
        let _ = runId
        Result.Ok(())
    }
}
func startProductJavaScriptHost(
    descriptor: PluginPackageDescriptor,
    generation: UInt64,
    launcher: JavaScriptHostProcessLauncher
): JavaScriptHostResult<JavaScriptExtensionHost> {
    startJavaScriptExtensionHostWithLauncher(JavaScriptHostLaunchRequest(
        descriptor.root,
        descriptor.entrypoint,
        runtime: "node",
        profile: JavaScriptHostLaunchProfile.PiV0871,
        extensionId: descriptor.id,
        extensionVersion: descriptor.version,
        generation: generation,
        grantedCapabilities: [],
        enforceNodePermissions: true
    ), launcher)
}
func javascriptPluginAgentError(error: JavaScriptHostError): AgentError {
    let kind = if (error.code == "extension.invocation_timeout" ||
        error.code == "extension.handshake_timeout") {
        AgentErrorKind.Timeout
    } else if (error.code == "extension.permission_denied") {
        AgentErrorKind.PermissionDenied
    } else if (error.code.startsWith("sandbox.") ||
        error.code.startsWith("extension.sandbox_")) {
        AgentErrorKind.Configuration
    } else {
        AgentErrorKind.Protocol
    }
    AgentError(kind, error.code, error.message)
}
func javascriptPluginDecodeValue(
    source: String,
    maxBytes!: Int64 = 1048576
): Result<AgentValue> {
    try {
        Result.Ok(parseUnifiedJson(source, maxBytes: maxBytes))
    } catch (error: JsonException) {
        Result.Err(AgentError(
            AgentErrorKind.Protocol,
            "value.invalid_json",
            error.message
        ))
    }
}

func javascriptPluginError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Protocol, code, message))
}
