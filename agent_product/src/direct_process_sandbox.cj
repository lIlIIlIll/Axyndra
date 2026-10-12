package agent_product

import agent_domain.*
import agent_host_runtime.*
import agent_runtime.OwnedCanonicalDataFailure113
import agent_ports.*
import process4cj.*
import sandbox4cj.*
import std.collection.*
import std.env.*
import std.fs.*
import std.io.InputStream
import std.sync.*

// Direct-launch runtimes (LSP, DAP, and the process supervisor) cannot use
// ProcessRequest because their children outlive one request.  They still use
// exactly the same WorkspaceSandbox plan; only the one-shot timeout wrapper is
// intentionally omitted so the owning runtime controls cancellation/reaping.
class DirectEnvironmentBinding {
    let target: String
    let source: String
    let secret: Bool

    init(target: String, source: String, secret!: Bool = false) {
        if (!validEnvironmentName(target) || !validEnvironmentName(source)) {
            throw IllegalArgumentException("environment mappings require valid variable names")
        }
        if (!secret && (directSecretName(target) || directSecretName(source))) {
            throw IllegalArgumentException(
                "secret-like environment mappings must be declared in secret_env"
            )
        }
        this.target = target
        this.source = source
        this.secret = secret
    }
}

class DirectResolvedEnvironment {
    let entries: Array<SandboxEnvironmentEntry>
    let secretTargets: Array<String>
    let secretValues: Array<String>
    let redactor: SecretRedactor

    init(
        entries: Array<SandboxEnvironmentEntry>,
        secretTargets: Array<String>,
        secretValues: Array<String>
    ) {
        this.entries = entries
        this.secretTargets = secretTargets
        this.secretValues = secretValues
        this.redactor = SecretRedactor(secretValues)
    }
}

class DirectNetworkLease {
    let gateway: NetworkGatewayPort
    let lease: NetworkGatewayLease

    init(gateway: NetworkGatewayPort, lease: NetworkGatewayLease) {
        this.gateway = gateway
        this.lease = lease
    }

    func release(): Unit {
        let _ = gateway.release(lease)
    }
}

class DirectProcessHandle {
    let process: ManagedProcess
    let redactor: SecretRedactor
    let secretValues: Array<String>
    let sandboxed: Bool
    private let releaseAction: () -> Unit
    private var ownedReleaseAction180:?()->Result<Unit>
    private var ownedReleasing180=false
    private var ownedReleased180=false
    private let releaseLock = Mutex()
    private var released = false

    init(
        process: ManagedProcess,
        redactor: SecretRedactor,
        secretValues: Array<String>,
        sandboxed: Bool,
        releaseAction!: () -> Unit = { => () },
        ownedReleaseAction180!:?()->Result<Unit>=None<()->Result<Unit>>
    ) {
        this.process = process
        this.redactor = redactor
        this.secretValues = secretValues
        this.sandboxed = sandboxed
        this.releaseAction = releaseAction;this.ownedReleaseAction180=ownedReleaseAction180
    }

    private func releaseOwnedWholeHelper180():Result<Unit>{
        ownedReleaseAction180.getOrThrow()()
    }
    func releaseOwned180():Result<Unit>{
        releaseLock.lock()
        try{
            if(ownedReleased180){return Result<Unit>.Ok(())}
            if(ownedReleasing180 || ownedReleaseAction180.isNone()){
                return Result<Unit>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "hub.process_network_release_retained","actual Native network cleanup is unavailable or live"))}
            ownedReleasing180=true
        }finally{releaseLock.unlock()}
        try{
            let result=releaseOwnedWholeHelper180()
            if(result.isError()){return result}
            // The actual gateway Result and whole action helper returned before
            // the closure/token references disappear. Err/throw keeps them.
            releaseLock.lock();try{ownedReleaseAction180=None<()->Result<Unit>>;ownedReleased180=true}
            finally{releaseLock.unlock()}
            Result<Unit>.Ok(())
        }finally{releaseLock.lock();try{ownedReleasing180=false}finally{releaseLock.unlock()}}
    }
    func release(): Unit {
        var shouldRelease = false
        releaseLock.lock()
        try {
            if (!released) {
                released = true
                shouldRelease = true
            }
        } finally {
            releaseLock.unlock()
        }
        if (shouldRelease) { releaseAction() }
    }
}

func launchDirectPersistentProcess(
    workspaceRoot: String,
    sandboxEnabled: Bool,
    allowUnsafeTestBypass: Bool,
    filesystem: FilesystemIsolationMode,
    networkPolicy: NetworkPolicy,
    executable: String,
    arguments: Array<String>,
    cwd: String,
    bindings!: Array<DirectEnvironmentBinding> = [],
    literalEnvironment!: Array<SandboxEnvironmentEntry> = [],
    sandboxCaBundle!: String = "",
    errorCode!: String = "direct.process_start_failed",
    resourceLease180!: ?HostHubDerivedProcessLease180 = None,
    ownedStartCell180!: ?DirectOwnedStartCell180 = None
): Result<DirectProcessHandle> {
    let caBundle = sandboxCaBundle.trimAscii()
    let resolved = match (match(resourceLease180){
        case Some(lease)=>resolveDirectOwnedEnvironment180(bindings,literalEnvironment,lease)
        case None=>resolveDirectEnvironment(bindings,literalEnvironment)}) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    match(ownedStartCell180){case Some(cell)=>cell.retainPreparedLaunchData180(resolved);case None=>()}
    if (networkPolicyModeIsMediated(networkPolicy.mode) && !sandboxEnabled) {
        return Result.Err(AgentError(
            AgentErrorKind.Configuration,
            "sandbox.direct_launch_disabled",
            "mediated persistent process launch requires the workspace sandbox"
        ))
    }
    if (!sandboxEnabled && !allowUnsafeTestBypass) {
        return Result.Err(AgentError(
            AgentErrorKind.Configuration,
            "sandbox.direct_launch_disabled",
            "model-visible direct process launch requires the workspace sandbox"
        ))
    }
    if (!sandboxEnabled) {
        try {
            let process = match(startDirectOwnedCommand180(ProcessCommand(
                executable,
                arguments: arguments,
                workingDirectory: cwd,
                environment: directHostEnvironment(workspaceRoot, resolved.entries)
            ),resourceLease180,ownedStartCell180)) {case Result.Err(error)=>return Result.Err(error);case Result.Ok(actual)=>actual}
            let handle=DirectProcessHandle(
                process,
                resolved.redactor,
                resolved.secretValues,
                false,
                ownedReleaseAction180:match(resourceLease180){case Some(_)=>Some({=>Result<Unit>.Ok(())})
                    case None=>None<()->Result<Unit>>}
            )
            match(ownedStartCell180){case Some(cell)=>cell.retainReturnedHandle180(handle);case None=>()}
            return Result.Ok(handle)
        } catch (error: Exception) {
            if(resourceLease180.isSome()){throw error}
            return Result.Err(AgentError(
                AgentErrorKind.Transport,
                errorCode,
                resolved.redactor.redact(error.message)
            ))
        }
    }

    let sandboxEnvironment = ArrayList<SandboxEnvironmentEntry>()
    for (entry in resolved.entries) { sandboxEnvironment.add(entry) }
    let configuredNames = ArrayList<String>()
    for (entry in resolved.entries) { configuredNames.add(entry.name) }
    var caMount: ?SandboxReadOnlyMount = None
    if (caBundle != "") {
        if (directContains(configuredNames, "SSL_CERT_FILE") ||
            directContains(configuredNames, "CURL_CA_BUNDLE")) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "sandbox.environment_duplicate",
                "configured CA bundle variables cannot be overridden"
            ))
        }
        try {
            caMount = Some(SandboxReadOnlyMount(caBundle))
            sandboxEnvironment.add(SandboxEnvironmentEntry("SSL_CERT_FILE", caBundle))
            sandboxEnvironment.add(SandboxEnvironmentEntry("CURL_CA_BUNDLE", caBundle))
        } catch (error: Exception) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "sandbox.ca_unavailable",
                resolved.redactor.redact(error.message)
            ))
        }
    }
    match(ownedStartCell180){case Some(cell)=>cell.beginNetworkAcquisition180();case None=>()}
    let networkLease = match (match(ownedStartCell180){
        case Some(cell)=>acquireDirectOwnedNetworkLease180(networkPolicy,
            match(resourceLease180){case Some(value)=>Some(value.operationId);case None=>None<OperationId>},cell)
        case None=>acquireDirectNetworkLease(networkPolicy,
            operation180:match(resourceLease180){case Some(value)=>Some(value.operationId);case None=>None<OperationId>})}) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    // Keep the exact returned gateway/token before sandbox construction,
    // validation, arguments or any other allocation can throw.
    match(ownedStartCell180){case Some(cell)=>cell.retainNetwork(networkLease);case None=>()}
    let allowedNames = ArrayList<String>()
    for (entry in sandboxEnvironment) { allowedNames.add(entry.name) }
    let toolchain = configuredProductSandboxToolchain()
    let mounts = ArrayList<SandboxReadOnlyMount>()
    for (mount in toolchain.mounts) { mounts.add(mount) }
    match (caMount) {
        case Some(value) => mounts.add(value)
        case None => ()
    }
    match (networkLease) {
        case Some(value) =>
            try {
                addDirectSandboxMount(mounts, value.lease.bridgeExecutable)
                addDirectSandboxMount(mounts, Path(value.lease.bridgeSocket).parent.toString())
            } catch (error: Exception) {
                releaseDirectNetworkUnlessHeld180(networkLease,ownedStartCell180)
                return Result.Err(AgentError(
                    AgentErrorKind.Configuration,
                    errorCode,
                    resolved.redactor.redact(error.message)
                ))
            }
        case None => ()
    }
    let sandbox = try {
        WorkspaceSandbox(WorkspaceSandboxPolicy(
            workspaceRoot,
            filesystem: filesystem,
            process: ProcessIsolationMode.Isolated,
            network: match (networkPolicy.mode) {
                case NetworkPolicyMode.HostNetwork => NetworkIsolationMode.Allowed
                case NetworkPolicyMode.Denied => NetworkIsolationMode.Denied
                case NetworkPolicyMode.Mediated => NetworkIsolationMode.Mediated
            },
            environment: EnvironmentFilter(
                allowlist: allowedNames.toArray(),
                allowedSecrets: resolved.secretTargets,
                secretValues: resolved.secretValues
            ),
            resources: defaultProductSandboxResourceLimits(),
            readOnlyMounts: mounts.toArray(),
            pathEntries: toolchain.pathEntries
        ))
    } catch (error: Exception) {
        releaseDirectNetworkUnlessHeld180(networkLease,ownedStartCell180)
        return Result.Err(AgentError(
            AgentErrorKind.Configuration,
            errorCode,
            resolved.redactor.redact(error.message)
        ))
    }
    match (sandbox.availability()) {
        case SandboxResult.Ok(_) => ()
        case SandboxResult.Err(error) =>
            releaseDirectNetworkUnlessHeld180(networkLease,ownedStartCell180)
            return Result.Err(directRedactError(sandboxAgentError(error), resolved.redactor))
    }
    let plan = match (sandbox.plan(WorkspaceSandboxCommand(
        executable,
        arguments: arguments,
        workingDirectory: cwd,
        environment: sandboxEnvironment.toArray(),
        timeoutMillis: 60000,
        networkBridgeExecutable: match (networkLease) {
            case Some(value) => value.lease.bridgeExecutable
            case None => ""
        },
        networkBridgeSocket: match (networkLease) {
            case Some(value) => value.lease.bridgeSocket
            case None => ""
        }
    ))) {
        case SandboxResult.Ok(value) => value
        case SandboxResult.Err(error) =>
            releaseDirectNetworkUnlessHeld180(networkLease,ownedStartCell180)
            return Result.Err(directRedactError(sandboxAgentError(error), resolved.redactor))
    }
    try {
        let process = match(startDirectOwnedCommand180(ProcessCommand(
            plan.sandboxExecutable,
            arguments: plan.sandboxArguments,
            environment: HashMap<String, String>()
        ),resourceLease180,ownedStartCell180)) {
            case Result.Err(error)=>releaseDirectNetworkUnlessHeld180(networkLease,ownedStartCell180);return Result.Err(error)
            case Result.Ok(actual)=>actual }
        let handle=DirectProcessHandle(
            process,
            resolved.redactor,
            resolved.secretValues,
            true,
            releaseAction: { => releaseDirectNetworkUnlessHeld180(networkLease,ownedStartCell180) },
            ownedReleaseAction180:match(resourceLease180){
                case Some(_)=>Some({=>releaseDirectOwnedNetwork180(networkLease)})
                case None=>None<()->Result<Unit>>}
        )
        match(ownedStartCell180){case Some(cell)=>cell.retainReturnedHandle180(handle);case None=>()}
        Result.Ok(handle)
    } catch (error: Exception) {
        if(resourceLease180.isSome()){throw error}
        releaseDirectNetworkUnlessHeld180(networkLease,ownedStartCell180)
        Result.Err(AgentError(
            AgentErrorKind.Transport,
            errorCode,
            resolved.redactor.redact(error.message)
        ))
    }
}

func acquireDirectNetworkLease(
    policy: NetworkPolicy,
    operation180!: ?OperationId = None
): Result<?DirectNetworkLease> {
    if (!networkPolicyModeIsMediated(policy.mode)) {
        return Result.Ok(Option<DirectNetworkLease>.None)
    }
    let gateway: NetworkGatewayPort = LocalNetworkGatewayPort()
    match (gateway.acquire(match(operation180){case Some(value)=>value;case None=>OperationId("direct-process")}, policy)) {
        case Result.Ok(lease) => Result.Ok(Some(DirectNetworkLease(gateway, lease)))
        case Result.Err(error) => Result.Err(error)
    }
}

func releaseDirectNetworkLease(lease: ?DirectNetworkLease): Unit {
    match (lease) {
        case Some(value) => value.release()
        case None => ()
    }
}

func addDirectSandboxMount(
    mounts: ArrayList<SandboxReadOnlyMount>,
    path: String
): Unit {
    let candidate = SandboxReadOnlyMount(path)
    for (existing in mounts where existing.path == candidate.path) { return }
    mounts.add(candidate)
}


func resolveDirectEnvironment(
    bindings: Array<DirectEnvironmentBinding>,
    literalEnvironment: Array<SandboxEnvironmentEntry>
): Result<DirectResolvedEnvironment> {
    let entries = ArrayList<SandboxEnvironmentEntry>()
    let targets = ArrayList<String>()
    let secretTargets = ArrayList<String>()
    let secretValues = ArrayList<String>()
    for (literal in literalEnvironment) {
        if (directSecretName(literal.name)) {
            return Result.Err(AgentError(
                AgentErrorKind.PermissionDenied,
                "sandbox.literal_secret_denied",
                "secret-like literal environment values are forbidden; use secret_env",
                fields: [ErrorField("name", literal.name)]
            ))
        }
        if (directContains(targets, literal.name)) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "sandbox.environment_duplicate",
                "environment target is declared more than once",
                fields: [ErrorField("name", literal.name)]
            ))
        }
        targets.add(literal.name)
        entries.add(literal)
    }
    let variables = getVariables()
    for (binding in bindings) {
        if (directContains(targets, binding.target)) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "sandbox.environment_duplicate",
                "environment target is declared more than once",
                fields: [ErrorField("name", binding.target)]
            ))
        }
        var found = false
        for ((name, value) in variables where name == binding.source) {
            if (binding.secret && value.toArray().size < 4) {
                return Result.Err(AgentError(
                    AgentErrorKind.Configuration,
                    "sandbox.secret_value_too_short",
                    "secret environment values must contain at least four bytes",
                    fields: [ErrorField("name", binding.source)]
                ))
            }
            try {
                entries.add(SandboxEnvironmentEntry(binding.target, value))
            } catch (error: Exception) {
                return Result.Err(AgentError(
                    AgentErrorKind.Configuration,
                    "sandbox.environment_invalid",
                    error.message,
                    fields: [ErrorField("name", binding.source)]
                ))
            }
            if (binding.secret) {
                secretTargets.add(binding.target)
                secretValues.add(value)
            }
            targets.add(binding.target)
            found = true
            break
        }
        if (!found) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "sandbox.environment_source_missing",
                "required environment source is unavailable",
                fields: [ErrorField("name", binding.source)]
            ))
        }
    }
    Result.Ok(DirectResolvedEnvironment(
        entries.toArray(),
        secretTargets.toArray(),
        secretValues.toArray()
    ))
}

func resolveDirectOwnedEnvironment180(
    bindings: Array<DirectEnvironmentBinding>,
    literalEnvironment: Array<SandboxEnvironmentEntry>,
    lease:HostHubDerivedProcessLease180
): Result<DirectResolvedEnvironment> {
    let entries = ArrayList<SandboxEnvironmentEntry>()
    let targets = ArrayList<String>()
    let secretTargets = ArrayList<String>()
    let secretValues = ArrayList<String>()
    for (literal in literalEnvironment) {
        if (directSecretName(literal.name)) {
            return Result.Err(AgentError(
                AgentErrorKind.PermissionDenied,
                "sandbox.literal_secret_denied",
                "secret-like literal environment values are forbidden; use secret_env",
                fields: [ErrorField("name", literal.name)]
            ))
        }
        if (directContains(targets, literal.name)) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "sandbox.environment_duplicate",
                "environment target is declared more than once",
                fields: [ErrorField("name", literal.name)]
            ))
        }
        targets.add(literal.name)
        entries.add(literal)
    }
    for (binding in bindings) {
        if (directContains(targets, binding.target)) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "sandbox.environment_duplicate",
                "environment target is declared more than once",
                fields: [ErrorField("name", binding.target)]
            ))
        }
        var found = false
        match(selectedProcessEnvironment180(binding.source,{bytes=>lease.retainData180(bytes,8)})){
            case Some(value)=>
            if (binding.secret && value.size < 4) {
                return Result.Err(AgentError(
                    AgentErrorKind.Configuration,
                    "sandbox.secret_value_too_short",
                    "secret environment values must contain at least four bytes",
                    fields: [ErrorField("name", binding.source)]
                ))
            }
            try {
                entries.add(SandboxEnvironmentEntry(binding.target, value))
            } catch (error: Exception) {
                return Result.Err(AgentError(
                    AgentErrorKind.Configuration,
                    "sandbox.environment_invalid",
                    error.message,
                    fields: [ErrorField("name", binding.source)]
                ))
            }
            if (binding.secret) {
                secretTargets.add(binding.target)
                secretValues.add(value)
            }
            targets.add(binding.target)
            found = true
            case None=>()
        }
        if (!found) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "sandbox.environment_source_missing",
                "required environment source is unavailable",
                fields: [ErrorField("name", binding.source)]
            ))
        }
    }
    Result.Ok(DirectResolvedEnvironment(
        entries.toArray(),
        secretTargets.toArray(),
        secretValues.toArray()
    ))
}


func directHostEnvironment(
    workspaceRoot: String,
    entries: Array<SandboxEnvironmentEntry>
): HashMap<String, String> {
    let environment = HashMap<String, String>()
    environment["PATH"] = "/usr/local/bin:/usr/bin:/bin"
    environment["HOME"] = workspaceRoot
    environment["TMPDIR"] = "/tmp"
    environment["LANG"] = "C.UTF-8"
    for (entry in entries) { environment[entry.name] = entry.value }
    environment
}

func directRedactError(error: AgentError, redactor: SecretRedactor): AgentError {
    let fields = ArrayList<ErrorField>()
    for (field in error.fields) {
        fields.add(ErrorField(field.name, redactor.redact(field.value)))
    }
    AgentError(
        error.kind,
        error.code,
        redactor.redact(error.message),
        retryable: error.retryable,
        fallbackAllowed: error.fallbackAllowed,
        fields: fields.toArray()
    )
}

func directSecretName(name: String): Bool {
    let normalized = name.toAsciiUpper().replace("-", "_")
    normalized.contains("SECRET") || normalized.contains("TOKEN") ||
        normalized.contains("PASSWORD") || normalized.contains("PASSWD") ||
        normalized.contains("CREDENTIAL") || normalized.endsWith("_KEY") ||
        normalized.contains("API_KEY") || normalized == "SSH_AUTH_SOCK" ||
        normalized.contains("COOKIE")
}

func directContains(values: ArrayList<String>, value: String): Bool {
    for (existing in values where existing == value) { return true }
    false
}

// Only the actual admitted resource path supplies this private lease. The
// Registry window encloses physical start, not log/readiness/process waits.
// Allocated and installed in the actual daemon record before command/network
// preparation or the physical launch. Unknown start/SQL commit retains this
// reachable cell; it cannot release the network lease or infer no process.
class DirectOwnedStartCell180 {
    private let lock=Mutex()
    private var attempted=false
    private var opened:?ManagedProcess=None<ManagedProcess>
    private var returnedHandle180:?DirectProcessHandle=None<DirectProcessHandle>
    private var nativeCustody180:?ProcessNativeStartCustody180=None<ProcessNativeStartCustody180>
    private var preparedData180:?DirectResolvedEnvironment=None<DirectResolvedEnvironment>
    private var openedReleaseAttempted180=false
    private var openedReleaseReturned180=false
    private var openedReleaseFailure180:?Exception=None<Exception>
    private var network:?DirectNetworkLease=None<DirectNetworkLease>
    private var networkAttempted180=false
    private var rawNetworkReturned180=false
    private var gateway180:?NetworkGatewayPort=None<NetworkGatewayPort>
    private var rawNetworkLease180:?NetworkGatewayLease=None<NetworkGatewayLease>
    private var networkFailure180:?AgentError=None<AgentError>
    private var networkAcquisitionFailure180:?Exception=None<Exception>
    private var networkReturned180=false
    private var unlaunchedReleaseAttempted180=false
    private var unlaunchedReleaseReturned180=false
    private var unlaunchedReleaseFailure180:?Exception=None<Exception>
    init(){}
    func installNativeCustodyBeforeStart180(value:ProcessNativeStartCustody180):Unit{
        lock.lock();try{if(nativeCustody180.isSome()){throw IllegalStateException("native start holder already installed")};nativeCustody180=Some(value)}
        finally{lock.unlock()}
    }
    func awaitActualNativeWaitForCleanup180(monitor:HostHubProcessProducerCell,
        control:HostHubProcessProducerCell):Int64{
        let native=nativeCustody180Snapshot().getOrThrow()
        let code=native.awaitActualWaitForCleanup180()
        if(native.hasActualWaitFailure180()){
            // Preserve the original status-reader exception BEFORE signaling
            // or another fallible cleanup. The original prepaid controller
            // pays its actual fixed signal frame without a fresh allocator.
            native.withActualWaitFailure180({error=>monitor.retainFailureBeforeCleanup180(error)})
            try{native.signalActualCleanupTree180("SIGKILL",{bytes=>control.requirePrepaidPhysicalFrame180(bytes)})}
            catch(error:Exception){monitor.retainActualCleanupFailure180(error)}
        }
        code
    }
    func nativePhysicalResourcesReturned180():Bool{
        match(nativeCustody180Snapshot()){case Some(value)=>value.physicalResourcesReturned180();case None=>false}
    }
    func signalOriginalNativeCleanup180(signal:String,control:HostHubProcessProducerCell):Unit{
        nativeCustody180Snapshot().getOrThrow().signalActualCleanupTree180(signal,{bytes=>control.requirePrepaidPhysicalFrame180(bytes)})
    }
    func canResumeUnwrappedNative180():Bool{
        match(nativeCustody180Snapshot()){case Some(value)=>value.canResumeUnwrappedPlatform180();case None=>false}
    }
    func originalUnwrappedPid180():Int64{nativeCustody180Snapshot().getOrThrow().originalRetainedPid180()}
    func originalUnwrappedStart180():Int64{nativeCustody180Snapshot().getOrThrow().originalRetainedStart180()}
    func withActualUnwrappedStream180(errorStream:Bool,consume:(InputStream)->Unit):Unit{
        nativeCustody180Snapshot().getOrThrow().withActualStream180(errorStream,consume)
    }
    func closeUnwrappedNativeAfterJoined180(fund:(Int64)->Unit):Unit{
        nativeCustody180Snapshot().getOrThrow().closeActualRetainedPlatform180(fund)
    }
    func requireActualNativeWaitResult180():Unit{
        lock.lock();let actual=try{nativeCustody180.getOrThrow()}finally{lock.unlock()}
        actual.requireActualWaitResult180()
    }
    func nativeCustody180Snapshot():?ProcessNativeStartCustody180{
        lock.lock();try{nativeCustody180}finally{lock.unlock()}
    }
    func admitActualNativeCloseErrors180(cell:HostHubProcessProducerCell):Bool{
        let native=match(nativeCustody180Snapshot()){case Some(value)=>value;case None=>return false}
        native.admitActualCloseErrors180({error=>
            cell.retainActualCleanupFailure180(error);!cell.hasUnregisteredSecondary180()})
    }
    func retainPreparedLaunchData180(value:DirectResolvedEnvironment):Unit{
        lock.lock();try{preparedData180=Some(value)}finally{lock.unlock()}
    }
    func retainReturnedHandle180(value:DirectProcessHandle):Unit{
        lock.lock();try{returnedHandle180=Some(value)}finally{lock.unlock()}
    }
    func returnedHandle180Snapshot():?DirectProcessHandle{
        lock.lock();try{returnedHandle180}finally{lock.unlock()}
    }
    func hasActualOpened180():Bool{lock.lock();try{opened.isSome()}finally{lock.unlock()}}
    func actualOpenedSecrets180():Array<String>{lock.lock();try{preparedData180.getOrThrow().secretValues}finally{lock.unlock()}}
    private func releaseOpenedNetworkWholeHelper180():Unit{
        match(rawNetworkLease180){case Some(value)=>
            match(gateway180.getOrThrow().release(value)){
                case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(_)=>()}
            case None=>()}
    }
    func releaseAfterActualOpenedJoin180():Unit{
        lock.lock();try{
            if(openedReleaseReturned180){return}
            if((opened.isNone() && !(nativeCustody180.isSome() && nativeCustody180.getOrThrow().nativeFailedResourcesReturned180())) ||
                !attempted || (networkAttempted180 && !rawNetworkReturned180)){
                throw IllegalStateException("actual partial-open network owner remains unobserved")}
            match(openedReleaseFailure180){case Some(error)=>throw error;case None=>()}
            if(openedReleaseAttempted180){throw IllegalStateException("actual opened network release remains unobserved")}
            openedReleaseAttempted180=true
        }finally{lock.unlock()}
        try{releaseOpenedNetworkWholeHelper180()}
        catch(error:Exception){lock.lock();try{openedReleaseFailure180=Some(error)}finally{lock.unlock()};throw error}
        lock.lock();try{
            // Only the partial-wrapper monitor calls this after real wait,
            // both complete pump Futures and the actual FD-close helper.
            network=None<DirectNetworkLease>;rawNetworkLease180=None<NetworkGatewayLease>
            gateway180=None<NetworkGatewayPort>;openedReleaseReturned180=true
        }finally{lock.unlock()}
    }
    func releaseAfterFailedNativeResources180():Unit{
        lock.lock();try{
            if(opened.isSome() || nativeCustody180.isNone() || !nativeCustody180.getOrThrow().nativeFailedResourcesReturned180()){
                throw IllegalStateException("actual failed native resources have no return witness")}
            if(openedReleaseReturned180){return}
            if(networkAttempted180 && !rawNetworkReturned180){
                throw IllegalStateException("actual failed native network acquisition remains unknown")}
            match(openedReleaseFailure180){case Some(error)=>throw error;case None=>()}
            if(openedReleaseAttempted180){throw IllegalStateException("actual failed native release remains unobserved")}
            openedReleaseAttempted180=true
        }finally{lock.unlock()}
        try{releaseOpenedNetworkWholeHelper180()}
        catch(error:Exception){lock.lock();try{openedReleaseFailure180=Some(error)}finally{lock.unlock()};throw error}
        lock.lock();try{network=None<DirectNetworkLease>;rawNetworkLease180=None<NetworkGatewayLease>
            gateway180=None<NetworkGatewayPort>;openedReleaseReturned180=true}finally{lock.unlock()}
    }
    func beginNetworkAcquisition180():Unit{
        lock.lock();try{networkAttempted180=true}finally{lock.unlock()}
    }
    func retainNetwork(value:?DirectNetworkLease):Unit{lock.lock();try{network=value;networkReturned180=true}finally{lock.unlock()}}
    func retainNetworkGatewayBeforeAcquire180(value:NetworkGatewayPort):Unit{
        lock.lock();try{gateway180=Some(value)}finally{lock.unlock()}
    }
    func retainActualNetworkLease180(value:NetworkGatewayLease):Unit{
        lock.lock();try{rawNetworkLease180=Some(value);rawNetworkReturned180=true}finally{lock.unlock()}
    }
    func noteNetworkNotMediated180():Unit{
        lock.lock();try{rawNetworkReturned180=true}finally{lock.unlock()}
    }
    func retainNetworkAcquireError180(error:AgentError):Unit{
        lock.lock();try{networkFailure180=Some(error);rawNetworkReturned180=true}finally{lock.unlock()}
    }
    func retainUnknownNetworkAcquire180(error:Exception):Unit{
        lock.lock();try{networkAcquisitionFailure180=Some(error)}finally{lock.unlock()}
    }
    private func releaseUnlaunchedNetworkHelper180():Unit{
        // The exact token is installed before DirectNetworkLease allocation.
        // An allocation failure does not lose the gateway's returned resource.
        match(rawNetworkLease180){case Some(value)=>
            match(gateway180.getOrThrow().release(value)){
                case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(_)=>()}
            case None=>()}
    }
    func releaseNeverStarted180():Unit{
        lock.lock()
        try{
            if(attempted || unlaunchedReleaseReturned180){return}
            match(unlaunchedReleaseFailure180){case Some(error)=>throw error;case None=>()}
            if(networkAttempted180 && !rawNetworkReturned180){
                throw IllegalStateException("unknown network acquisition remains in its registered launch owner")}
            if(unlaunchedReleaseAttempted180){
                throw IllegalStateException("actual unlaunched release remains unobserved")}
            unlaunchedReleaseAttempted180=true
        }finally{lock.unlock()}
        try{releaseUnlaunchedNetworkHelper180()}
        catch(error:Exception){lock.lock();try{unlaunchedReleaseFailure180=Some(error)}finally{lock.unlock()};throw error}
        // Clear only after the gateway Result and whole helper returned. The
        // registered error/unknown branch cannot silently retry or refund.
        lock.lock();try{
            network=None<DirectNetworkLease>;rawNetworkLease180=None<NetworkGatewayLease>
            gateway180=None<NetworkGatewayPort>;unlaunchedReleaseReturned180=true
        }finally{lock.unlock()}
    }
    func enterActualStart():Unit{lock.lock();try{attempted=true}finally{lock.unlock()}}
    func retainActualProcess(value:ManagedProcess):Unit{lock.lock();try{opened=Some(value)}finally{lock.unlock()}}
    func actualProcess():ManagedProcess{lock.lock();try{opened.getOrThrow()}finally{lock.unlock()}}
    func unknownOrOpened():Bool{lock.lock();try{attempted}finally{lock.unlock()}}
    // The only production caller is the outer native incarnation join, after
    // monitor/readiness/both pumps' complete Future/get helpers returned.
    private func clearNativeCopiesWholeHelper180():Bool{
        match(nativeCustody180Snapshot()){case Some(actual)=>actual.clearAfterActualResources180();case None=>!attempted}
    }
    func clearAfterActualIncarnationJoin180():Bool{
        // Only the outer supervisor calls this AFTER the original source's
        // exact producer/error consumers retired. The native helper returns
        // before its holder is detached; unknown wait/FD/network stays paid.
        // Check the actual gateway helper before clearing the native holder.
        // An unknown release must leave every original native copy reachable.
        lock.lock();try{
            if(networkAttempted180 && !openedReleaseReturned180 && !unlaunchedReleaseReturned180){return false}
        }finally{lock.unlock()}
        if(!clearNativeCopiesWholeHelper180()){return false}
        lock.lock();try{
            opened=None<ManagedProcess>;network=None<DirectNetworkLease>
            returnedHandle180=None<DirectProcessHandle>;preparedData180=None<DirectResolvedEnvironment>
            nativeCustody180=None<ProcessNativeStartCustody180>;gateway180=None<NetworkGatewayPort>
            rawNetworkLease180=None<NetworkGatewayLease>;networkFailure180=None<AgentError>
            networkAcquisitionFailure180=None<Exception>;openedReleaseFailure180=None<Exception>
            unlaunchedReleaseFailure180=None<Exception>;true
        }finally{lock.unlock()}
    }
}
func releaseDirectNetworkUnlessHeld180(network:?DirectNetworkLease,cell:?DirectOwnedStartCell180):Unit{
    match(cell){case Some(value)=>value.releaseNeverStarted180();return;case None=>()}
    releaseDirectNetworkLease(network)
}

func startDirectOwnedCommand180(command:ProcessCommand,lease:?HostHubDerivedProcessLease180,
    cell:?DirectOwnedStartCell180):Result<ManagedProcess>{
    match(lease){case None=>Result.Ok(startProcess(command));case Some(value)=>
        let actual=match(cell){case Some(found)=>found;case None=>
            return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,"hub.process_launch_custody_missing",
                "actual Native process has no preinstalled launch holder"))}
        value.retainData180(262144,32)
        let native=ProcessNativeStartCustody180()
        actual.installNativeCustodyBeforeStart180(native)
        value.installActualNativeReceiptBeforeEffect180(native.failedStartReceiptBeforeEffect180())
        match(value.withPhysicalEffect180({=>
            actual.enterActualStart()
            let process=native.start180(command,{bytes=>value.retainData180(bytes,8)})
            actual.retainActualProcess(process)
            Result<Unit>.Ok(())})){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        Result<ManagedProcess>.Ok(actual.actualProcess())}
}

