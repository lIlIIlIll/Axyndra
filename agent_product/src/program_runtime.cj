package agent_product

import yjson.*
import yjson_support.*
import agent_domain.*
import agent_runtime.*
import agent_ports.*
import tool_runtime.*
import sandbox4cj.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.sync.*

public class ProductToolProgramProcessExecution {
    public let result: ToolProgramResult
    public let programArtifact: ProductArtifact
    public let workerProcessId: String
    public let exitCode: Int64
    public let timedOut: Bool
    public let outputTruncated: Bool

    public init(
        result: ToolProgramResult,
        programArtifact: ProductArtifact,
        workerProcessId: String,
        exitCode: Int64,
        timedOut: Bool,
        outputTruncated: Bool
    ) {
        this.result = result
        this.programArtifact = programArtifact
        this.workerProcessId = workerProcessId
        this.exitCode = exitCode
        this.timedOut = timedOut
        this.outputTruncated = outputTruncated
    }
}

// Each call stages the content-addressed Program source in a private,
// per-invocation workspace and starts a fresh worker process. The only mounted
// workspace is that private directory; Program workers never inherit the
// product workspace, provider configuration, or network policy.
public class ProductToolProgramProcessRuntime {
    private let runtimeRoot: String
    private let artifacts: ProductArtifactStore
    private let workerExecutable: String
    private let activeLock = Mutex()
    private let activeProcesses = HashMap<String, LocalProcessPort>()
    private let cancelledBeforeLaunch = HashMap<String, Bool>()
    private let activeOperationsByRun = HashMap<String, ArrayList<String>>()

    public init(
        stateRoot: String,
        artifacts: ProductArtifactStore,
        workerExecutable: String
    ) {
        if (stateRoot.trimAscii() == "" || workerExecutable.trimAscii() == "") {
            throw IllegalArgumentException("Program process runtime requires state and worker paths")
        }
        this.runtimeRoot = Path(stateRoot).normalize().toString() + "/runtime/tool-programs"
        this.artifacts = artifacts
        this.workerExecutable = workerExecutable
    }

    public func execute(
        prepared: PreparedToolInvocation,
        context: ToolInvocationContext,
        onFrame: (String) -> Result<?String>,
        limits!: ToolProgramLimits = ToolProgramLimits(maxParallelCalls: 1u64),
        processLimits!: ExecutionResourceLimits = ExecutionResourceLimits()
    ): Result<ProductToolProgramProcessExecution> {
        match (registerProgramRun(context.runId, prepared.operationId)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        try {
            executeProgram(prepared, context, onFrame, limits, processLimits)
        } finally {
            unregisterProgramRun(context.runId, prepared.operationId)
        }
    }

    private func executeProgram(
        prepared: PreparedToolInvocation,
        context: ToolInvocationContext,
        onFrame: (String) -> Result<?String>,
        limits: ToolProgramLimits,
        processLimits: ExecutionResourceLimits
    ): Result<ProductToolProgramProcessExecution> {
        if (prepared.call.name != "run_program" ||
            prepared.operationPlan.toolName != "run_program" ||
            prepared.operationPlan.effectClass != OperationEffectClass.ReadOnly) {
            return programProcessError<ProductToolProgramProcessExecution>(
                AgentErrorKind.PermissionDenied,
                "tool_program.prepared_root_required",
                "Program execution requires a prepared read-only run_program invocation"
            )
        }
        let rootToolCall = match (prepared.committedToolCall) {
            case Some(value) => value
            case None => return programProcessError<ProductToolProgramProcessExecution>(
                AgentErrorKind.PermissionDenied,
                "tool_program.committed_root_required",
                "Program execution requires an AgentCore-committed root ToolCall"
            )
        }
        if (rootToolCall.block.name != "run_program" ||
            !networkPolicyModeIsDenied(prepared.operationPlan.networkPolicy.mode)) {
            return programProcessError<ProductToolProgramProcessExecution>(
                AgentErrorKind.PermissionDenied,
                "tool_program.root_policy_denied",
                "Program root plan must be read-only and deny network access"
            )
        }
        let source = match (prepared.operationPlan.canonicalArguments.field("source")) {
            case Some(value) =>
                if (value.unifiedKind != ValueKind.Text) {
                    return programProcessError<ProductToolProgramProcessExecution>(
                        AgentErrorKind.InvalidInput,
                        "tool_program.source_missing",
                        "prepared run_program source must be text"
                    )
                }
                value.text
            case None => return programProcessError<ProductToolProgramProcessExecution>(
                AgentErrorKind.InvalidInput,
                "tool_program.source_missing",
                "prepared run_program arguments do not contain source text"
            )
        }
        let programId = artifactSha256(source.toArray())
        let program = match (compileRestrictedToolProgram(programId, source)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let timeoutMillis = programLimitMillis(limits.maxWallTimeMillis)
        if (!program.readOnly || timeoutMillis < 1 ||
            program.source.toArray().size > PRODUCT_TOOL_PROGRAM_MAX_SOURCE_BYTES) {
            return programProcessError<ProductToolProgramProcessExecution>(
                AgentErrorKind.InvalidInput,
                "tool_program.input_invalid",
                "Program source or process timeout is outside the supported bounds"
            )
        }
        let operationId = prepared.operationId
        let networkPolicy = prepared.operationPlan.networkPolicy
        let executable = match (canonicalProgramWorkerExecutable(workerExecutable)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let artifact = match (artifacts.persistText(program.source)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let stagedSource = match (artifacts.read(
            artifact.reference,
            limit: PRODUCT_TOOL_PROGRAM_MAX_SOURCE_BYTES
        )) {
            case Result.Ok(value) => value.content
            case Result.Err(error) => return Result.Err(error)
        }
        if (stagedSource != program.source || artifactSha256(stagedSource.toArray()) != artifact.sha256) {
            return programProcessError<ProductToolProgramProcessExecution>(
                AgentErrorKind.RecoveryRequired,
                "tool_program.artifact_mismatch",
                "the persisted Program source artifact does not match the compiled source"
            )
        }
        match (ensureProgramRuntimeRoot(runtimeRoot)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let runDirectory = try {
            Directory.createTemp(Path(runtimeRoot)).toString()
        } catch (error: Exception) {
            return programProcessError<ProductToolProgramProcessExecution>(
                AgentErrorKind.Internal,
                "tool_program.workspace_create_failed",
                error.message
            )
        }
        let sourcePath = Path(runDirectory).join("program.source").toString()
        try {
            File.writeTo(sourcePath, stagedSource.toArray())
        } catch (error: Exception) {
            let _ = removeIfExists(runDirectory, recursive: true)
            return programProcessError<ProductToolProgramProcessExecution>(
                AgentErrorKind.Internal,
                "tool_program.source_stage_failed",
                error.message
            )
        }
        match (artifactChmod(sourcePath, "400")) {
            case Result.Ok(_) => ()
            case Result.Err(error) =>
                let _ = removeIfExists(runDirectory, recursive: true)
                return Result.Err(error)
        }
        let sourceInfo = try { FileInfo(Path(sourcePath)) } catch (error: Exception) {
            let _ = removeIfExists(runDirectory, recursive: true)
            return programProcessError<ProductToolProgramProcessExecution>(
                AgentErrorKind.Internal,
                "tool_program.source_stage_failed",
                error.message
            )
        }
        if (!sourceInfo.isRegular() || sourceInfo.isSymbolicLink() ||
            sourceInfo.size != artifact.bytes) {
            let _ = removeIfExists(runDirectory, recursive: true)
            return programProcessError<ProductToolProgramProcessExecution>(
                AgentErrorKind.PermissionDenied,
                "tool_program.source_stage_unsafe",
                "the staged Program source is not a bounded regular file"
            )
        }

        let sandboxToolchain = configuredProductSandboxToolchain()
        let nativeRoot = match (canonicalProgramNativeRoot()) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                let _ = removeIfExists(runDirectory, recursive: true)
                return Result.Err(error)
        }
        let runtimeLibraryPath = match (productProgramWorkerLibraryPath(sandboxToolchain, nativeRoot)) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                let _ = removeIfExists(runDirectory, recursive: true)
                return Result.Err(error)
        }
        let environmentLauncher = match (canonicalProgramEnvironmentLauncher()) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                let _ = removeIfExists(runDirectory, recursive: true)
                return Result.Err(error)
        }
        let mounts = ArrayList<SandboxReadOnlyMount>()
        for (mount in sandboxToolchain.mounts) { mounts.add(mount) }
        try {
            for (path in [environmentLauncher, executable]) {
                var mounted = false
                for (mount in mounts where mount.path == path) { mounted = true }
                if (!mounted) { mounts.add(SandboxReadOnlyMount(path)) }
            }
            if (nativeRoot != "") {
                let nativeLibrary = nativeRoot + "/libprocess4cj_native.so"
                var mounted = false
                for (mount in mounts where mount.path == nativeLibrary) { mounted = true }
                if (!mounted) { mounts.add(SandboxReadOnlyMount(nativeLibrary)) }
            }
        } catch (error: Exception) {
            let _ = removeIfExists(runDirectory, recursive: true)
            return programProcessError<ProductToolProgramProcessExecution>(
                AgentErrorKind.Configuration,
                "tool_program.worker_mount_failed",
                error.message
            )
        }
        let workspace = try {
            LocalWorkspace(runDirectory)
        } catch (error: Exception) {
            let _ = removeIfExists(runDirectory, recursive: true)
            return programProcessError<ProductToolProgramProcessExecution>(
                AgentErrorKind.Configuration,
                "tool_program.workspace_invalid",
                error.message
            )
        }
        let processPort = LocalProcessPort(
            workspace,
            sandboxEnabled: true,
            sandboxResources: defaultProductSandboxResourceLimits(),
            sandboxReadOnlyMounts: mounts.toArray(),
            sandboxPathEntries: sandboxToolchain.pathEntries
        )
        processPort.reserveOperation(operationId)
        let wasCancelled = match (registerProgramProcess(operationId, processPort)) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                processPort.releaseOperation(operationId)
                let _ = processPort.close()
                let _ = removeIfExists(runDirectory, recursive: true)
                return Result.Err(error)
        }
        if (wasCancelled) { let _ = processPort.cancel(operationId) }
        let request = ProcessRequest(
            environmentLauncher,
            operationId: operationId,
            arguments: [
                "LD_LIBRARY_PATH=" + runtimeLibraryPath,
                executable,
                "__tool-program-worker-v1",
                artifact.sha256,
                sourcePath,
                limits.maxInstructions.toString(),
                limits.maxSubCalls.toString(),
                limits.maxParallelCalls.toString(),
                limits.maxDepth.toString(),
                limits.maxWallTimeMillis.toString(),
                limits.maxComputeTimeMillis.toString(),
                limits.maxResultBytes.toString(),
                limits.maxLogBytes.toString()
            ],
            timeoutMillis: timeoutMillis,
            sandboxMode: ProcessSandboxMode.WorkspaceReadOnly,
            networkPolicy: Some(networkPolicy),
            processLimits: processLimits
        )
        let execution = try {
            processPort.executeInteractive(request, context.cancellation, onFrame)
        } finally {
            unregisterProgramProcess(operationId)
            processPort.releaseOperation(operationId)
            let _ = processPort.close()
            let _ = removeIfExists(runDirectory, recursive: true)
        }
        let processResult = match (execution) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (processResult.timedOut) {
            return programProcessError<ProductToolProgramProcessExecution>(
                AgentErrorKind.Timeout,
                "tool_program.process_timeout",
                "the independent Program worker exceeded its process timeout"
            )
        }
        if (processResult.truncated) {
            return programProcessError<ProductToolProgramProcessExecution>(
                AgentErrorKind.Protocol,
                "tool_program.output_limit",
                "the independent Program worker exceeded its bounded output protocol"
            )
        }
        if (processResult.exitCode != 0) {
            return programProcessError<ProductToolProgramProcessExecution>(
                AgentErrorKind.Transport,
                "tool_program.worker_failed",
                "the independent Program worker exited unsuccessfully"
            )
        }
        decodeProductToolProgramWorkerResult(
            processResult.stdout,
            artifact,
            processResult.exitCode,
            processResult.timedOut,
            processResult.truncated
        )
    }

    public func cancel(operationId: OperationId): Result<Unit> {
        var process: ?LocalProcessPort = None
        activeLock.lock()
        try {
            if (activeProcesses.contains(operationId.value)) {
                process = activeProcesses.get(operationId.value)
            } else {
                cancelledBeforeLaunch[operationId.value] = true
            }
        } finally {
            activeLock.unlock()
        }
        match (process) {
            case Some(value) => value.cancel(operationId)
            case None => Result.Ok(())
        }
    }


    public func cancelRun(runId: RunId): Result<Unit> {
        let operationIds = ArrayList<String>()
        let processes = ArrayList<LocalProcessPort>()
        activeLock.lock()
        try {
            let active = activeOperationsByRun.get(runId.value)
            if (active.isSome()) {
                for (operationId in active.getOrThrow()) {
                    let process = activeProcesses.get(operationId)
                    if (process.isSome()) {
                        operationIds.add(operationId)
                        processes.add(process.getOrThrow())
                    } else {
                        cancelledBeforeLaunch[operationId] = true
                    }
                }
            }
        } finally {
            activeLock.unlock()
        }
        var failure: ?AgentError = None
        for (index in 0..operationIds.size) {
            match (processes[index].cancel(OperationId(operationIds[index]))) {
                case Result.Ok(_) => ()
                case Result.Err(error) => if (failure.isNone()) { failure = Some(error) }
            }
        }
        match (failure) {
            case Some(error) => Result.Err(error)
            case None => Result.Ok(())
        }
    }

    private func registerProgramRun(
        runId: RunId,
        operationId: OperationId
    ): Result<Unit> {
        activeLock.lock()
        try {
            var operations = match (activeOperationsByRun.get(runId.value)) {
                case Some(value) => value
                case None => ArrayList<String>()
            }
            for (existing in operations where existing == operationId.value) {
                return programProcessError<Unit>(
                    AgentErrorKind.Conflict,
                    "tool_program.operation_active",
                    "a Program worker already owns this operation identifier"
                )
            }
            operations.add(operationId.value)
            activeOperationsByRun[runId.value] = operations
            Result.Ok(())
        } finally {
            activeLock.unlock()
        }
    }


    private func unregisterProgramRun(
        runId: RunId,
        operationId: OperationId
    ): Unit {
        activeLock.lock()
        try {
            let active = activeOperationsByRun.get(runId.value)
            if (active.isSome()) {
                let operations = active.getOrThrow()
                for (index in 0..operations.size) {
                    if (operations[index] == operationId.value) {
                        operations.remove(at: index)
                        break
                    }
                }
                if (operations.isEmpty()) { activeOperationsByRun.remove(runId.value) }
            }
            cancelledBeforeLaunch.remove(operationId.value)
        } finally {
            activeLock.unlock()
        }
    }

    private func registerProgramProcess(
        operationId: OperationId,
        process: LocalProcessPort
    ): Result<Bool> {
        activeLock.lock()
        try {
            if (activeProcesses.contains(operationId.value)) {
                return programProcessError<Bool>(
                    AgentErrorKind.Conflict,
                    "tool_program.operation_active",
                    "a Program worker already owns this operation identifier"
                )
            }
            activeProcesses[operationId.value] = process
            Result.Ok(cancelledBeforeLaunch.get(operationId.value) ?? false)
        } finally {
            activeLock.unlock()
        }
    }

    private func unregisterProgramProcess(operationId: OperationId): Unit {
        activeLock.lock()
        try {
            activeProcesses.remove(operationId.value)
            cancelledBeforeLaunch.remove(operationId.value)
        } finally {
            activeLock.unlock()
        }
    }
}

func programLimitMillis(value: UInt64): Int64 {
    if (value > UInt64(Int64.Max)) { Int64.Max } else { Int64(value) }
}

func canonicalProgramWorkerExecutable(value: String): Result<String> {
    if (!Path(value).isAbsolute() || !exists(Path(value))) {
        return programProcessError<String>(
            AgentErrorKind.Configuration,
            "tool_program.worker_unavailable",
            "the configured Program worker executable is unavailable"
        )
    }
    try {
        let info = FileInfo(Path(value))
        if (!info.isRegular() || info.isSymbolicLink()) {
            return programProcessError<String>(
                AgentErrorKind.Configuration,
                "tool_program.worker_invalid",
                "the configured Program worker must be a regular executable file"
            )
        }
        Result.Ok(canonicalize(Path(value)).toString())
    } catch (error: Exception) {
        programProcessError<String>(
            AgentErrorKind.Configuration,
            "tool_program.worker_invalid",
            error.message
        )
    }
}
func canonicalProgramEnvironmentLauncher(): Result<String> {
    let authored = "/usr/bin/env"
    if (!exists(Path(authored))) {
        return programProcessError<String>(AgentErrorKind.Configuration, "tool_program.launcher_unavailable", "the fixed env launcher is unavailable")
    }
    try {
        let resolved = canonicalize(Path(authored)).toString()
        let info = FileInfo(Path(resolved))
        if (!info.isRegular() || !info.canExecute()) {
            return programProcessError<String>(AgentErrorKind.Configuration, "tool_program.launcher_invalid", "the fixed env launcher must resolve to an executable regular file")
        }
        Result.Ok(resolved)
    } catch (_: Exception) {
        programProcessError<String>(AgentErrorKind.Configuration, "tool_program.launcher_invalid", "the fixed env launcher could not be validated")
    }
}
func canonicalProgramNativeRoot(): Result<String> {
    match (getVariable("AXYNDRA_NATIVE_ROOT")) {
        case None => Result.Ok("")
        case Some(authored) =>
            if (!Path(authored).isAbsolute() || !exists(Path(authored))) {
                return programProcessError<String>(AgentErrorKind.Configuration, "tool_program.native_runtime_unavailable", "the configured native runtime root is unavailable")
            }
            try {
                let rootInfo = FileInfo(Path(authored))
                if (!rootInfo.isDirectory() || rootInfo.isSymbolicLink()) {
                    return programProcessError<String>(AgentErrorKind.Configuration, "tool_program.native_runtime_invalid", "the configured native runtime root must be a real directory")
                }
                let root = canonicalize(Path(authored)).toString()
                if (root.contains(":") || root.contains("=")) {
                    return programProcessError<String>(AgentErrorKind.Configuration, "tool_program.native_runtime_invalid", "the native runtime root contains unsupported loader delimiters")
                }
                let libraryPath = root + "/libprocess4cj_native.so"
                let libraryInfo = FileInfo(Path(libraryPath))
                if (!libraryInfo.isRegular() || libraryInfo.isSymbolicLink()) {
                    return programProcessError<String>(AgentErrorKind.Configuration, "tool_program.native_library_invalid", "the configured native runtime library must be a regular nonsymlink file")
                }
                if (canonicalize(Path(libraryPath)).toString() != libraryPath) {
                    return programProcessError<String>(AgentErrorKind.Configuration, "tool_program.native_library_invalid", "the configured native runtime library path is not canonical")
                }
                Result.Ok(root)
            } catch (_: Exception) {
                programProcessError<String>(AgentErrorKind.Configuration, "tool_program.native_library_invalid", "the configured native runtime library could not be validated")
            }
    }
}

func productProgramWorkerLibraryPath(toolchain: ProductSandboxToolchain, nativeRoot: String): Result<String> {
    let sdkAuthored = match (getVariable("CANGJIE_SDK_ROOT")) {
        case Some(value) => value
        case None => match (getVariable("CANGJIE_HOME")) {
            case Some(value) => value
            case None => ""
        }
    }
    let stdxAuthored = match (getVariable("CANGJIE_STDX_PATH")) {
        case Some(value) => value
        case None => ""
    }
    if (sdkAuthored == "" || stdxAuthored == "") {
        return programProcessError<String>(AgentErrorKind.Configuration, "tool_program.runtime_libraries_unavailable", "the configured Cangjie SDK and stdx roots are required for the worker")
    }
    let sdkRoot = match (canonicalProgramToolchainRoot(sdkAuthored, toolchain)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let stdxRoot = match (canonicalProgramToolchainRoot(stdxAuthored, toolchain)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let candidates = [stdxRoot, sdkRoot + "/runtime/lib/linux_x86_64_cjnative", sdkRoot + "/tools/lib"]
    let libraries = ArrayList<String>()
    for (candidate in candidates) {
        let directory = match (canonicalProgramRuntimeDirectory(candidate, [sdkRoot, stdxRoot], toolchain)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (directory.contains(":") || directory.contains("=")) {
            return programProcessError<String>(AgentErrorKind.Configuration, "tool_program.runtime_library_path_invalid", "configured SDK library paths contain unsupported loader delimiters")
        }
        var duplicate = false
        for (existing in libraries where existing == directory) { duplicate = true }
        if (!duplicate) { libraries.add(directory) }
    }
    if (nativeRoot != "") {
        var duplicate = false
        for (existing in libraries where existing == nativeRoot) { duplicate = true }
        if (!duplicate) { libraries.add(nativeRoot) }
    }
    var result = ""
    for (directory in libraries) {
        if (result != "") { result += ":" }
        result += directory
    }
    Result.Ok(result)
}

func canonicalProgramToolchainRoot(authored: String, toolchain: ProductSandboxToolchain): Result<String> {
    if (!Path(authored).isAbsolute() || !exists(Path(authored))) {
        return programProcessError<String>(AgentErrorKind.Configuration, "tool_program.runtime_root_unavailable", "a configured Cangjie runtime root is unavailable")
    }
    try {
        let info = FileInfo(Path(authored))
        if (!info.isDirectory() || info.isSymbolicLink()) {
            return programProcessError<String>(AgentErrorKind.Configuration, "tool_program.runtime_root_invalid", "configured Cangjie runtime roots must be real directories")
        }
        let resolved = canonicalize(Path(authored)).toString()
        var mounted = false
        for (mount in toolchain.mounts where mount.path == resolved) { mounted = true }
        if (!mounted || resolved.contains(":") || resolved.contains("=")) {
            return programProcessError<String>(AgentErrorKind.Configuration, "tool_program.runtime_root_unmounted", "configured Cangjie runtime roots must be present in the readonly sandbox toolchain")
        }
        Result.Ok(resolved)
    } catch (_: Exception) {
        programProcessError<String>(AgentErrorKind.Configuration, "tool_program.runtime_root_invalid", "a configured Cangjie runtime root could not be validated")
    }
}

func canonicalProgramRuntimeDirectory(authored: String, roots: Array<String>, toolchain: ProductSandboxToolchain): Result<String> {
    if (!exists(Path(authored))) {
        return programProcessError<String>(AgentErrorKind.Configuration, "tool_program.runtime_library_unavailable", "a required Cangjie runtime library directory is unavailable")
    }
    try {
        let info = FileInfo(Path(authored))
        if (!info.isDirectory() || info.isSymbolicLink()) {
            return programProcessError<String>(AgentErrorKind.Configuration, "tool_program.runtime_library_invalid", "Cangjie runtime libraries must be real directories")
        }
        let resolved = canonicalize(Path(authored)).toString()
        var contained = false
        for (root in roots where resolved == root || resolved.startsWith(root + "/")) { contained = true }
        var mounted = false
        for (mount in toolchain.mounts where resolved == mount.path || resolved.startsWith(mount.path + "/")) { mounted = true }
        if (!contained || !mounted) {
            return programProcessError<String>(AgentErrorKind.Configuration, "tool_program.runtime_library_unmounted", "Cangjie runtime libraries must remain inside readonly sandbox toolchain roots")
        }
        Result.Ok(resolved)
    } catch (_: Exception) {
        programProcessError<String>(AgentErrorKind.Configuration, "tool_program.runtime_library_invalid", "a Cangjie runtime library directory could not be validated")
    }
}

func ensureProgramRuntimeRoot(path: String): Result<Unit> {
    try {
        if (!exists(Path(path))) { Directory.create(path, recursive: true) }
        let info = FileInfo(Path(path))
        if (!info.isDirectory() || info.isSymbolicLink()) {
            return programProcessError<Unit>(
                AgentErrorKind.PermissionDenied,
                "tool_program.runtime_root_unsafe",
                "the Program runtime root must be a real directory"
            )
        }
        artifactChmod(path, "700")
    } catch (error: Exception) {
        programProcessError<Unit>(
            AgentErrorKind.Internal,
            "tool_program.runtime_root_failed",
            error.message
        )
    }
}

func decodeProductToolProgramWorkerResult(
    output: String,
    artifact: ProductArtifact,
    exitCode: Int64,
    timedOut: Bool,
    outputTruncated: Bool
): Result<ProductToolProgramProcessExecution> {
    let response = try {
        parseUnifiedJson(output.trimAscii(), maxBytes: 1048576, maxDepth: 16)
    } catch (_: JsonException) {
        return programProcessError<ProductToolProgramProcessExecution>(
            AgentErrorKind.Protocol,
            "tool_program.response_invalid",
            "the independent Program worker returned invalid JSON"
        )
    }
    if (response.unifiedKind != ValueKind.Object) {
        return programProcessError<ProductToolProgramProcessExecution>(
            AgentErrorKind.Protocol,
            "tool_program.response_invalid",
            "the independent Program worker response must be an object"
        )
    }
    let protocol = match (response.field("protocol")) {
        case Some(value) => value.text
        case None => ""
    }
    let digest = match (response.field("program_artifact_sha256")) {
        case Some(value) => value.text
        case None => ""
    }
    let workerProcessId = match (response.field("worker_process_id")) {
        case Some(value) => value.text
        case None => ""
    }
    let status = match (response.field("status")) {
        case Some(value) => value.text
        case None => ""
    }
    let value = match (response.field("value")) {
        case Some(node) => node
        case None => return programProcessError<ProductToolProgramProcessExecution>(
            AgentErrorKind.Protocol,
            "tool_program.response_invalid",
            "the independent Program worker omitted its result value"
        )
    }
    let instructionsText = match (response.field("instructions")) {
        case Some(node) => node.text
        case None => ""
    }
    let instructions = try { UInt64.parse(instructionsText) } catch (_: Exception) {
        return programProcessError<ProductToolProgramProcessExecution>(
            AgentErrorKind.Protocol,
            "tool_program.response_invalid",
            "the independent Program worker instruction count is invalid"
        )
    }
    let errorCode = match (response.field("error_code")) {
        case Some(node) => node.text
        case None => ""
    }
    let errorMessage = match (response.field("error_message")) {
        case Some(node) => node.text
        case None => ""
    }
    let kind = match (response.field("kind")) {
        case Some(node) => node.text
        case None => ""
    }
    if (kind != "complete" || protocol != PRODUCT_TOOL_PROGRAM_WORKER_PROTOCOL.toString() ||
        digest != artifact.sha256 || workerProcessId == "") {
        return programProcessError<ProductToolProgramProcessExecution>(
            AgentErrorKind.Protocol,
            "tool_program.response_identity_mismatch",
            "the Program worker response identity did not match the staged source artifact"
        )
    }
    let programStatus = match (status) {
        case "completed" => ToolProgramStatus.Completed
        case "partial" => ToolProgramStatus.Partial
        case "failed" => ToolProgramStatus.Failed
        case "recovery_required" => ToolProgramStatus.RecoveryRequired
        case _ => return programProcessError<ProductToolProgramProcessExecution>(
            AgentErrorKind.Protocol,
            "tool_program.response_status_invalid",
            "the independent Program worker returned an unsupported status"
        )
    }
    Result.Ok(ProductToolProgramProcessExecution(
        ToolProgramResult(
            programStatus,
            value,
            [],
            instructions,
            errorCode: errorCode,
            errorMessage: errorMessage
        ),
        artifact,
        workerProcessId,
        exitCode,
        timedOut,
        outputTruncated
    ))
}

func programProcessError<T>(
    kind: AgentErrorKind,
    code: String,
    message: String
): Result<T> {
    Result.Err(AgentError(kind, code, message))
}

let PRODUCT_PROGRAM_SUBCALL_MAX_FRAME_BYTES: Int64 = 1048576
let PRODUCT_PROGRAM_SUBCALL_MAX_CALLS: UInt64 = 32u64

public class ProductRunProgramExecutor <: ToolExecutor {
    private let runtime: ProductToolProgramProcessRuntime
    private let catalog: ToolCatalog
    private let pipeline: ToolPipeline
    private let operations: OperationRuntimePort
    private let ids: IdGenerator

    public init(
        runtime: ProductToolProgramProcessRuntime,
        catalog: ToolCatalog,
        pipeline: ToolPipeline,
        operations: OperationRuntimePort,
        ids: IdGenerator
    ) {
        this.runtime = runtime
        this.catalog = catalog
        this.pipeline = pipeline
        this.operations = operations
        this.ids = ids
    }

    public func execute(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolResult> {
        if (prepared.call.name != "run_program" ||
            prepared.operationPlan.toolName != "run_program" ||
            prepared.operationPlan.effectClass != OperationEffectClass.ReadOnly) {
            return programProcessError<ToolResult>(
                AgentErrorKind.PermissionDenied,
                "tool_program.prepared_root_required",
                "Program execution requires a prepared read-only run_program invocation"
            )
        }
        let committed = match (prepared.committedToolCall) {
            case Some(value) => value
            case None => return programProcessError<ToolResult>(
                AgentErrorKind.PermissionDenied,
                "tool_program.committed_root_required",
                "Program execution requires an AgentCore-committed root ToolCall"
            )
        }
        let source = match (prepared.operationPlan.canonicalArguments.field("source")) {
            case Some(value) => value.text
            case None => return programProcessError<ToolResult>(
                AgentErrorKind.InvalidInput,
                "tool_program.source_missing",
                "prepared run_program arguments do not contain source text"
            )
        }
        if (match (prepared.operationPlan.canonicalArguments.field("source")) {
            case Some(value) => value.unifiedKind != ValueKind.Text
            case None => true
        }) {
            return programProcessError<ToolResult>(
                AgentErrorKind.InvalidInput,
                "tool_program.source_missing",
                "prepared run_program source must be text"
            )
        }
        let digest = artifactSha256(source.toArray())
        let bridge = ProductProgramSubcallHost(
            catalog, pipeline, operations, ids, prepared, context, committed, digest
        )
        let execution = match (runtime.execute(
            prepared,
            context,
            {frame => bridge.onFrame(frame)},
            limits: ToolProgramLimits(
                maxSubCalls: PRODUCT_PROGRAM_SUBCALL_MAX_CALLS,
                maxParallelCalls: 1u64
            ),
            processLimits: context.budget.processLimits
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let result = execution.result
        let status = match (result.status) {
            case ToolProgramStatus.Completed => "completed"
            case ToolProgramStatus.Partial => "partial"
            case ToolProgramStatus.Failed => "failed"
            case ToolProgramStatus.RecoveryRequired => "recovery_required"
        }
        Result.Ok(ToolResult(
            prepared.call.callId,
            objectValue([
                ValueField("status", textValue(status)),
                ValueField("value", result.value),
                ValueField("program_artifact", textValue(execution.programArtifact.reference)),
                ValueField("program_sha256", textValue(execution.programArtifact.sha256)),
                ValueField("instruction_count", integerValue(workerInt64(result.instructions))),
                ValueField("sub_call_count", integerValue(workerInt64(bridge.callCount()))),
                ValueField("worker_process_id", textValue(execution.workerProcessId)),
                ValueField("error_code", textValue(result.errorCode)),
                ValueField("error_message", textValue(result.errorMessage)),
                ValueField("output_truncated", boolValue(execution.outputTruncated))
            ]),
            isError: result.status != ToolProgramStatus.Completed,
            receiptId: "receipt-" + prepared.operationId.value
        ))
    }

    public func cancel(runId: RunId): Result<Unit> {
        runtime.cancelRun(runId)
    }
}

class ProductProgramSubcallHost {
    private let catalog: ToolCatalog
    private let pipeline: ToolPipeline
    private let operations: OperationRuntimePort
    private let ids: IdGenerator
    private let rootPrepared: PreparedToolInvocation
    private let rootContext: ToolInvocationContext
    private let rootToolCall: CommittedToolCallRef
    private let programDigest: String
    private let childContext: ToolInvocationContext
    private var sequence: UInt64 = 0u64
    private var childResponse: ?String = None

    init(
        catalog: ToolCatalog,
        pipeline: ToolPipeline,
        operations: OperationRuntimePort,
        ids: IdGenerator,
        rootPrepared: PreparedToolInvocation,
        rootContext: ToolInvocationContext,
        rootToolCall: CommittedToolCallRef,
        programDigest: String
    ) {
        this.catalog = catalog
        this.pipeline = pipeline
        this.operations = operations
        this.ids = ids
        this.rootPrepared = rootPrepared
        this.rootContext = rootContext
        this.rootToolCall = rootToolCall
        this.programDigest = programDigest
        this.childContext = makeProgramChildContext(rootPrepared, rootContext)
    }

    public func callCount(): UInt64 { sequence }

    public func onFrame(frame: String): Result<?String> {
        if (frame.toArray().size > PRODUCT_PROGRAM_SUBCALL_MAX_FRAME_BYTES) {
            return programHostError<?String>(
                AgentErrorKind.Protocol,
                "tool_program.frame_limit",
                "Program bridge frame exceeded its byte limit"
            )
        }
        let value = try {
            parseUnifiedJson(frame, maxBytes: PRODUCT_PROGRAM_SUBCALL_MAX_FRAME_BYTES, maxDepth: 16)
        } catch (_: Exception) {
            return programHostError<?String>(
                AgentErrorKind.Protocol,
                "tool_program.frame_invalid",
                "Program worker emitted an invalid JSON bridge frame"
            )
        }
        if (value.unifiedKind != ValueKind.Object ||
            !programFrameNumberIs(value, "protocol", PRODUCT_TOOL_PROGRAM_WORKER_PROTOCOL)) {
            return programHostError<?String>(
                AgentErrorKind.Protocol,
                "tool_program.frame_identity_invalid",
                "Program worker frame has an invalid protocol identity"
            )
        }
        let kind = programFrameText(value, "kind")
        if (kind == "complete") {
            if (programFrameText(value, "program_artifact_sha256") != programDigest ||
                !programFrameNumberPositive(value, "worker_process_id")) {
                return programHostError<?String>(
                    AgentErrorKind.Protocol,
                    "tool_program.completion_identity_invalid",
                    "Program completion frame does not match the staged source artifact"
                )
            }
            return Result.Ok(None)
        }
        if (kind != "tool_call") {
            return programHostError<?String>(
                AgentErrorKind.Protocol,
                "tool_program.frame_kind_invalid",
                "Program worker emitted an unsupported bridge frame"
            )
        }
        let next = sequence + 1u64
        if (next > PRODUCT_PROGRAM_SUBCALL_MAX_CALLS) {
            sequence = next
            return encodeProgramBridgeResponse(programDeniedFrame(
                next,
                programFrameText(value, "call_id"),
                "tool_program.subcall_limit",
                "Program exceeded the host subcall limit"
            ))
        }
        if (!programFrameNumberIs(value, "sequence", workerInt64(next)) ||
            programFrameText(value, "call_id") != programDigest + "-sub-" + next.toString()) {
            return programHostError<?String>(
                AgentErrorKind.Protocol,
                "tool_program.request_identity_invalid",
                "Program tool call sequence or call ID did not match the staged source"
            )
        }
        sequence = next
        childResponse = None
        match (rootContext.withNestedToolSlot(rootPrepared.operationId, { =>
            match (executeChildFrame(next, value)) {
                case Result.Ok(result) =>
                    childResponse = result
                    Result.Ok(())
                case Result.Err(error) => Result.Err(error)
            }
        })) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => Result.Ok(childResponse)
        }
    }

    private func executeChildFrame(
        callSequence: UInt64,
        value: AgentValue
    ): Result<?String> {
        let tool = programFrameText(value, "tool")
        let arguments = match (value.field("arguments")) {
            case Some(item) => item
            case None => return encodeProgramBridgeResponse(programDeniedFrame(
                callSequence, programFrameText(value, "call_id"),
                "tool_program.arguments_invalid",
                "Program tool arguments must be an object"
            ))
        }
        if (arguments.unifiedKind != ValueKind.Object) {
            return encodeProgramBridgeResponse(programDeniedFrame(
                callSequence, programFrameText(value, "call_id"),
                "tool_program.arguments_invalid",
                "Program tool arguments must be an object"
            ))
        }
        let call = ToolCall(programFrameText(value, "call_id"), tool, arguments)
        if (!programSubcallAllowed(tool)) {
            return encodeProgramBridgeResponse(programDeniedFrame(
                callSequence, call.callId, "tool_program.tool_not_allowed",
                "Program subcalls are limited to the host read-only tool allowlist"
            ))
        }
        match (pipeline.prepare(childContext, call)) {
            case Result.Err(error) => encodeProgramBridgeResponse(
                programDeniedFrame(callSequence, call.callId, error.code, error.message)
            )
            case Result.Ok(ToolPreparation.Completed(result)) =>
                let error = programResultError(result)
                encodeProgramBridgeResponse(programDeniedFrame(
                    callSequence, call.callId, error.code, error.message
                ))
            case Result.Ok(ToolPreparation.Denied(denial)) =>
                encodeProgramBridgeResponse(programDeniedFrame(
                    callSequence, call.callId, denial.reason.code, denial.reason.message
                ))
            case Result.Ok(ToolPreparation.Ready(prepared)) =>
                handlePreparedCall(callSequence, call, prepared, None)
            case Result.Ok(ToolPreparation.NeedsApproval(prepared, _)) =>
                handlePreparedCall(
                    callSequence, call, prepared,
                    Some(AgentError(
                        AgentErrorKind.PermissionDenied,
                        "tool_program.approval_unavailable",
                        "Program subcalls cannot pause for interactive approval"
                    ))
                )
        }
    }

    private func handlePreparedCall(
        callSequence: UInt64,
        call: ToolCall,
        prepared: PreparedToolInvocation,
        approvalRejection: ?AgentError
    ): Result<?String> {
        match (validateChildPlan(prepared)) {
            case Result.Err(error) => return encodeProgramBridgeResponse(
                programDeniedFrame(callSequence, call.callId, error.code, error.message)
            )
            case Result.Ok(_) => ()
        }
        let replay = match (admitPrepared(prepared)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return encodeProgramBridgeResponse(
                programDeniedFrame(callSequence, call.callId, error.code, error.message)
            )
        }
        match (replay) {
            case Some(receipt) => return responseFromReceipt(callSequence, call, receipt)
            case None => ()
        }
        if (approvalRejection.isSome()) {
            let error = approvalRejection.getOrThrow()
            return settleAndDeny(
                callSequence, call, prepared, OperationOutcome.Rejected, error
            )
        }
        let result = pipeline.executePrepared(childContext, prepared)
        match (result) {
            case Result.Ok(ToolInvocationResult.Completed(toolResult)) =>
                settleToolResult(callSequence, call, prepared, toolResult)
            case Result.Ok(ToolInvocationResult.Denied(denial)) =>
                settleAndDeny(
                    callSequence, call, prepared, OperationOutcome.Rejected, denial.reason
                )
            case Result.Ok(ToolInvocationResult.NeedsApproval(_)) =>
                settleAndDeny(
                    callSequence, call, prepared,
                    OperationOutcome.Rejected,
                    AgentError(
                        AgentErrorKind.PermissionDenied,
                        "tool_program.approval_unavailable",
                        "Program subcalls cannot pause for interactive approval"
                    )
                )
            case Result.Err(error) => settleExecutionError(
                callSequence, call, prepared, error
            )
        }
    }

    private func validateChildPlan(prepared: PreparedToolInvocation): Result<Unit> {
        if (!programSubcallAllowed(prepared.call.name) ||
            prepared.operationPlan.toolName != prepared.call.name ||
            prepared.operationPlan.effectClass != OperationEffectClass.ReadOnly ||
            !networkPolicyModeIsDenied(prepared.operationPlan.networkPolicy.mode)) {
            return programHostError<Unit>(
                AgentErrorKind.PermissionDenied,
                "tool_program.child_plan_denied",
                "Program child plan must be allowlisted, read-only, and deny network access"
            )
        }
        let descriptor = match (catalog.resolvedDescriptor(prepared.call)) {
            case Some(value) => value
            case None => return programHostError<Unit>(
                AgentErrorKind.PermissionDenied,
                "tool_program.child_descriptor_missing",
                "Program child tool is no longer registered"
            )
        }
        if (descriptor.sideEffecting) {
            return programHostError<Unit>(
                AgentErrorKind.PermissionDenied,
                "tool_program.child_effect_denied",
                "Program child tool resolved as side-effecting"
            )
        }
        let childNetwork = match (descriptor.networkPolicy(prepared.call)) {
            case Result.Ok(value) => value
            case Result.Err(_) => return programHostError<Unit>(
                AgentErrorKind.PermissionDenied,
                "tool_program.child_network_denied",
                "Program child tool must use a frozen denied-network policy"
            )
        }
        if (!networkPolicyModeIsDenied(childNetwork.mode)) {
            return programHostError<Unit>(
                AgentErrorKind.PermissionDenied,
                "tool_program.child_network_denied",
                "Program child tool must use a frozen denied-network policy"
            )
        }
        let rootCeiling = CapabilitySet(values: rootPrepared.operationPlan.requiredCapabilities)
        for (required in prepared.operationPlan.requiredCapabilities) {
            if (required.kind != CapabilityKind.WorkspaceRead ||
                !rootCeiling.allows(required.kind, resource: required.resource) ||
                !rootContext.capabilities.allows(required.kind, resource: required.resource)) {
                return programHostError<Unit>(
                    AgentErrorKind.PermissionDenied,
                    "tool_program.child_capability_exceeded",
                    "Program child requires a capability outside the committed root ceiling"
                )
            }
        }
        for (required in descriptor.requiredCapabilities()) {
            if (required.kind != CapabilityKind.WorkspaceRead ||
                !rootCeiling.allows(required.kind, resource: required.resource) ||
                !rootContext.capabilities.allows(required.kind, resource: required.resource)) {
                return programHostError<Unit>(
                    AgentErrorKind.PermissionDenied,
                    "tool_program.child_capability_exceeded",
                    "Program child descriptor requires a capability outside the root ceiling"
                )
            }
        }
        Result.Ok(())
    }

    private func admitPrepared(
        prepared: PreparedToolInvocation
    ): Result<?VNextOperationReceipt> {
        let operationId = prepared.operationId
        match (operations.loadPlan(operationId, rootContext.runId)) {
            case Result.Ok(_) => return programHostError<?VNextOperationReceipt>(
                AgentErrorKind.Conflict,
                "operation.derived_id_collision",
                "host-generated child Operation ID is already in use"
            )
            case Result.Err(error) => if (error.code != "operation.not_found") {
                return Result.Err(error)
            }
        }
        let admitted = match (operations.prepareDerivedOperation(
            operationId,
            rootPrepared.operationId,
            rootContext.runId,
            rootToolCall,
            prepared.call.callId,
            prepared.operationPlan
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (admitted.value == operationId.value) { return Result.Ok(None) }
        match (operations.loadDerivedOperationReceipt(admitted, rootContext.runId)) {
            case Result.Ok(Some(receipt)) => Result.Ok(Some(receipt))
            case Result.Ok(None) => programHostError<?VNextOperationReceipt>(
                AgentErrorKind.RecoveryRequired,
                "operation.derived_receipt_missing",
                "duplicate Program request has no durable child Receipt; execution was not repeated"
            )
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func settleToolResult(
        callSequence: UInt64,
        call: ToolCall,
        prepared: PreparedToolInvocation,
        result: ToolResult
    ): Result<?String> {
        let outcome = if (result.isError) { OperationOutcome.Failed } else {
            OperationOutcome.Completed
        }
        let receipt = VNextOperationReceipt(
            "receipt-" + prepared.operationId.value,
            prepared.operationId,
            outcome,
            objectValue([
                ValueField("call_id", textValue(call.callId)),
                ValueField("tool", textValue(call.name)),
                ValueField("output", result.output),
                ValueField("is_error", boolValue(result.isError)),
                ValueField("error_code", textValue("")),
                ValueField("error_message", textValue(""))
            ]),
            verificationValue(call, prepared),
            agentUtcMillis()
        )
        match (operations.settleDerivedOperation(
            rootContext.runId, rootPrepared.operationId, receipt
        )) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        encodeProgramBridgeResponse(programCompletedFrame(
            callSequence, call.callId, result.output, result.isError, receipt.receiptId
        ))
    }

    private func settleAndDeny(
        callSequence: UInt64,
        call: ToolCall,
        prepared: PreparedToolInvocation,
        outcome: OperationOutcome,
        error: AgentError
    ): Result<?String> {
        let receipt = VNextOperationReceipt(
            "receipt-" + prepared.operationId.value,
            prepared.operationId,
            outcome,
            objectValue([
                ValueField("call_id", textValue(call.callId)),
                ValueField("tool", textValue(call.name)),
                ValueField("error_code", textValue(error.code)),
                ValueField("error_message", textValue(error.message))
            ]),
            verificationValue(call, prepared),
            agentUtcMillis()
        )
        match (operations.settleDerivedOperation(
            rootContext.runId, rootPrepared.operationId, receipt
        )) {
            case Result.Err(settleError) => return Result.Err(settleError)
            case Result.Ok(_) => ()
        }
        encodeProgramBridgeResponse(programDeniedFrame(
            callSequence, call.callId, error.code, error.message
        ))
    }

    private func settleExecutionError(
        callSequence: UInt64,
        call: ToolCall,
        prepared: PreparedToolInvocation,
        error: AgentError
    ): Result<?String> {
        let state = match (operations.loadDerivedOperationState(
            prepared.operationId, rootContext.runId
        )) {
            case Result.Ok(value) => value
            case Result.Err(stateError) => return Result.Err(stateError)
        }
        let outcome = if (state == "prepared" || state == "waiting_approval") {
            OperationOutcome.Rejected
        } else if (state == "executing") {
            OperationOutcome.Unknown
        } else {
            match (operations.loadDerivedOperationReceipt(prepared.operationId, rootContext.runId)) {
                case Result.Ok(Some(receipt)) => return responseFromReceipt(callSequence, call, receipt)
                case Result.Ok(None) => return programHostError<?String>(
                    AgentErrorKind.RecoveryRequired,
                    "operation.derived_terminal_receipt_missing",
                    "terminal child Operation has no Receipt; execution was not repeated"
                )
                case Result.Err(receiptError) => return Result.Err(receiptError)
            }
        }
        settleAndDeny(callSequence, call, prepared, outcome, error)
    }

    private func verificationValue(
        call: ToolCall,
        prepared: PreparedToolInvocation
    ): AgentValue {
        objectValue([
            ValueField("request_key", textValue(call.callId)),
            ValueField("request_digest", textValue(prepared.operationPlan.bindingDigest)),
            ValueField("parent_operation_id", textValue(rootPrepared.operationId.value)),
            ValueField("program_artifact_sha256", textValue(programDigest)),
            ValueField("sequence", integerValue(workerInt64(sequence)))
        ])
    }

    private func responseFromReceipt(
        callSequence: UInt64,
        call: ToolCall,
        receipt: VNextOperationReceipt
    ): Result<?String> {
        if (receipt.operationId.value == "" ||
            programReceiptText(receipt.detail, "call_id") != call.callId ||
            programReceiptText(receipt.detail, "tool") != call.name) {
            return programHostError<?String>(
                AgentErrorKind.Conflict,
                "operation.derived_receipt_request_mismatch",
                "stored child Receipt does not match the duplicate Program request"
            )
        }
        match (receipt.outcome) {
            case OperationOutcome.Completed | OperationOutcome.Failed =>
                let output = match (receipt.detail.field("output")) {
                    case Some(value) => value
                    case None => return programHostError<?String>(
                        AgentErrorKind.RecoveryRequired,
                        "operation.derived_receipt_output_missing",
                        "stored completed child Receipt has no output"
                    )
                }
                let errorValue = match (receipt.detail.field("is_error")) {
                    case Some(value) => value
                    case None => boolValue(receipt.outcome == OperationOutcome.Failed)
                }
                let isError = if (errorValue.unifiedKind == ValueKind.Boolean) {
                    errorValue.asBool()
                } else {
                    receipt.outcome == OperationOutcome.Failed
                }
                encodeProgramBridgeResponse(programCompletedFrame(
                    callSequence, call.callId, output, isError, receipt.receiptId
                ))
            case _ => encodeProgramBridgeResponse(programDeniedFrame(
                callSequence,
                call.callId,
                programReceiptText(receipt.detail, "error_code"),
                programReceiptText(receipt.detail, "error_message")
            ))
        }
    }
}

func makeProgramChildContext(
    rootPrepared: PreparedToolInvocation,
    rootContext: ToolInvocationContext
): ToolInvocationContext {
    let capabilities = ArrayList<Capability>()
    for (required in rootPrepared.operationPlan.requiredCapabilities) {
        if (required.kind == CapabilityKind.WorkspaceRead &&
            rootContext.capabilities.allows(required.kind, resource: required.resource)) {
            capabilities.add(Capability(required.kind, resource: required.resource))
        }
    }
    ToolInvocationContext(
        rootContext.runId,
        rootContext.sessionId,
        CapabilitySet(values: capabilities.toArray()),
        sequence: rootContext.currentSequence(),
        epoch: rootContext.epoch,
        toolContext: ToolContextDescriptor(
            workspaceRoot: rootContext.workspaceRoot,
            cwd: rootContext.cwd,
            environment: rootContext.environment,
            services: rootContext.services
        ),
        cancellation: rootContext.cancellation,
        approvalModeOverride: rootContext.approvalModeOverride,
        outputSink: rootContext.outputSink,
        budget: rootContext.budget,
        budgetModeFn: rootContext.budgetModeFn,
        skills: rootContext.skills,
        toolSetSnapshot: rootContext.toolSetSnapshot
    )
}

func programSubcallAllowed(name: String): Bool {
    name == "read" || name == "grep" || name == "glob"
}


func programFrameText(value: AgentValue, name: String): String {
    let item = match (value.field(name)) {
        case Some(found) => found
        case None => return ""
    }
    if (item.unifiedKind == ValueKind.Text) { item.text } else { "" }
}

func programFrameNumber(value: AgentValue, name: String): ?Int64 {
    let item = match (value.field(name)) {
        case Some(found) => found
        case None => return None
    }
    if (item.unifiedKind != ValueKind.Number) { return None }
    try { Some(Int64.parse(item.asNumberText())) } catch (_: Exception) { None }
}

func programFrameNumberIs(value: AgentValue, name: String, expected: Int64): Bool {
    match (programFrameNumber(value, name)) {
        case Some(actual) => actual == expected
        case None => false
    }
}

func programFrameNumberPositive(value: AgentValue, name: String): Bool {
    match (programFrameNumber(value, name)) {
        case Some(actual) => actual > 0
        case None => false
    }
}

func programReceiptText(value: AgentValue, name: String): String {
    programFrameText(value, name)
}

func programResultError(result: ToolResult): AgentError {
    let code = programReceiptText(result.output, "code")
    let message = programReceiptText(result.output, "message")
    AgentError(
        AgentErrorKind.InvalidInput,
        if (code == "") { "tool_program.child_preparation_rejected" } else { code },
        if (message == "") { "Program child tool preparation was rejected" } else { message }
    )
}

func programCompletedFrame(
    sequence: UInt64,
    callId: String,
    output: AgentValue,
    isError: Bool,
    receiptId: String
): AgentValue {
    objectValue([
        ValueField("protocol", integerValue(PRODUCT_TOOL_PROGRAM_WORKER_PROTOCOL)),
        ValueField("kind", textValue("tool_result")),
        ValueField("sequence", integerValue(workerInt64(sequence))),
        ValueField("call_id", textValue(callId)),
        ValueField("outcome", textValue("completed")),
        ValueField("output", output),
        ValueField("is_error", boolValue(isError)),
        ValueField("receipt_id", textValue(receiptId))
    ])
}

func programDeniedFrame(
    sequence: UInt64,
    callId: String,
    errorCode: String,
    errorMessage: String
): AgentValue {
    objectValue([
        ValueField("protocol", integerValue(PRODUCT_TOOL_PROGRAM_WORKER_PROTOCOL)),
        ValueField("kind", textValue("tool_result")),
        ValueField("sequence", integerValue(workerInt64(sequence))),
        ValueField("call_id", textValue(callId)),
        ValueField("outcome", textValue("denied")),
        ValueField("error_code", textValue(if (errorCode == "") { "tool_program.subcall_denied" } else { errorCode })),
        ValueField("error_message", textValue(if (errorMessage == "") { "Program child request was denied" } else { errorMessage }))
    ])
}

func encodeProgramBridgeResponse(value: AgentValue): Result<?String> {
    let encoded = stringifyUnifiedJson(value)
    if (encoded.toArray().size > PRODUCT_PROGRAM_SUBCALL_MAX_FRAME_BYTES) {
        return programHostError<?String>(
            AgentErrorKind.Protocol,
            "tool_program.response_limit",
            "Program child response exceeded its byte limit"
        )
    }
    Result.Ok(Some(encoded))
}

func programHostError<T>(kind: AgentErrorKind, code: String, message: String): Result<T> {
    Result.Err(AgentError(kind, code, message))
}
