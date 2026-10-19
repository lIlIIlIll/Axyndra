package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.reserveNativeControlMetadata
import agent_plugin_registry.*
import agent_domain as domain
import agent_ports.*
import process4cj.*
import sandbox4cj.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.io.*
import std.process.*
import std.sync.*
import std.time.*

let HOST_NATIVE_DEFAULT_IO_BYTES: Int64 = 16777216

// Only the actual owner can construct this nonserialized close report. It
// preserves channel cleanup and native termination errors for the Product
// wrapper's original subsequent Shell/Eval cleanup and error precedence.
public class HostNativeProcessClose {
    public let channelResult: Result<Unit>
    public let firstError: String
    init(channelResult: Result<Unit>, firstError: String) {
        this.channelResult = channelResult; this.firstError = firstError
    }
}

// Trusted composition configures immutable typed model/lifecycle adapters.
// Default adapters are absent and reject claims/grants. Raw methods neither
// create canonical source/admission authority nor settle an Operation Receipt.
public class HostLocalProcessPort <: ProcessPort & HostLifecycleProcessLauncher & HostModelProcessLauncher & HostRegistryPackageProcessPort {
    private let workspace: HostProcessWorkspaceRoot
    private let registryAdmission: ?() -> Result<PluginRegistryExecutionFence>
    private let lifecycleLaunchAuthorityValue: ?HostLifecycleProcessLaunchAuthority
    private let modelLaunchAuthorityValue: ?HostModelProcessLaunchAuthority
    private let sandboxEnabledValue: Bool
    private let sandboxResourcesValue: SandboxResourceLimits
    private let lifecycleChannelOutputBytesValue: Int64
    private let sandboxReadOnlyMountsValue: Array<SandboxReadOnlyMount>
    private let sandboxPathEntriesValue: Array<String>
    private let sandboxCaBundleValue: String
    private let sandboxCaBundleMountValue: ?SandboxReadOnlyMount
    private let networkGatewayValue: ?NetworkGatewayPort
    private let activeLock = Mutex()
    private var hookEntries159h: ?HostHookProcessEntry159h = None<HostHookProcessEntry159h>
    private var hookFrames159h: Int64 = 0
    private let active = ArrayList<HostActiveNativeProcess>()
    private let reserved = HashMap<String, Bool>()
    // Pending launch and pending cleanup count toward the same finite quota.
    // Every field of these owners except cleanup/release task state is guarded
    // by activeLock; callbacks and process methods always run outside it.
    private let channelOwners = ArrayList<HostNativeProcessChannelOwner>()
    private var channelsClosed = false
    public init(
        workspace: HostProcessWorkspaceRoot,
        lifecycleLaunchAuthority!: ?HostLifecycleProcessLaunchAuthority = None,
        modelLaunchAuthority!: ?HostModelProcessLaunchAuthority = None,
        sandboxEnabled!: Bool = false,
        sandboxResources!: SandboxResourceLimits = defaultHostProcessSandboxResourceLimits(),
        lifecycleChannelOutputBytes!: ?Int64 = None,
        sandboxReadOnlyMounts!: Array<SandboxReadOnlyMount> = [],
        sandboxPathEntries!: Array<String> = [],
        sandboxCaBundle!: String = "",
        networkGateway!: ?NetworkGatewayPort = None,
        registryAdmission!: ?() -> Result<PluginRegistryExecutionFence> = None
    ) {
        this.workspace = workspace
        this.registryAdmission = registryAdmission
        this.lifecycleLaunchAuthorityValue = lifecycleLaunchAuthority
        this.modelLaunchAuthorityValue = modelLaunchAuthority
        this.sandboxEnabledValue = sandboxEnabled
        this.sandboxResourcesValue = sandboxResources
        let channelOutput = match (lifecycleChannelOutputBytes) {
            case Some(value) => value
            case None => if (sandboxResources.maxOutputBytes > 0) {
                min(HOST_NATIVE_DEFAULT_IO_BYTES, sandboxResources.maxOutputBytes)
            } else { HOST_NATIVE_DEFAULT_IO_BYTES }
        }
        if (channelOutput < 1 || channelOutput > HOST_LIFECYCLE_TRANSPORT_OUTPUT_BYTES) {
            throw IllegalArgumentException("lifecycle transport output requires a finite host ceiling")
        }
        this.lifecycleChannelOutputBytesValue = channelOutput
        let mounts = ArrayList<SandboxReadOnlyMount>()
        for (mount in sandboxReadOnlyMounts) { mounts.add(SandboxReadOnlyMount(mount.path)) }
        this.sandboxReadOnlyMountsValue = mounts.toArray()
        this.sandboxPathEntriesValue = sandboxPathEntries.clone()
        this.sandboxCaBundleValue = sandboxCaBundle.trimAscii()
        this.sandboxCaBundleMountValue = if (this.sandboxCaBundleValue == "") {
            None
        } else {
            try {
                Some(SandboxReadOnlyMount(this.sandboxCaBundleValue))
            } catch (_: Exception) {
                None
            }
        }
        this.networkGatewayValue = networkGateway
    }


    public func sandboxEnabled(): Bool { sandboxEnabledValue }

    public func sandboxResourceLimits(): SandboxResourceLimits {
        SandboxResourceLimits(
            maxOutputBytes: sandboxResourcesValue.maxOutputBytes,
            addressSpaceBytes: sandboxResourcesValue.addressSpaceBytes,
            fileSizeBytes: sandboxResourcesValue.fileSizeBytes,
            openFiles: sandboxResourcesValue.openFiles,
            processes: sandboxResourcesValue.processes,
            cpuSeconds: sandboxResourcesValue.cpuSeconds
        )
    }



    private func verifyModelProcessClaim(claim: HostModelProcessLaunchClaim, owner: ProcessResourceOwner): Result<Unit> {
        match (modelLaunchAuthorityValue) {
            case Some(authority) => authority.verify(claim, owner)
            case None => hostNativeModelAdmissionDenied()
        }
    }
    private func modelProcessClaimCancellation(claim: HostModelProcessLaunchClaim): Result<domain.CancellationToken> {
        match (modelLaunchAuthorityValue) {
            case Some(authority) => authority.cancellation(claim)
            case None => hostNativeModelAdmissionDenied()
        }
    }
    public func openClaimedModelChannel(request: ProcessRequest, claim: HostModelProcessLaunchClaim,
        maxInputBytes: Int64): Result<ProcessChannel> {
        match (verifyModelProcessClaim(claim, request.resourceOwner)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (!networkPolicyModeIsDenied(request.networkPolicy.mode) ||
            request.sandboxMode != ProcessSandboxMode.IsolatedReadOnly ||
            !request.readOnlyMounts.isEmpty() || !request.environmentAllowlist.isEmpty()) {
            return hostNativeModelAdmissionDenied<ProcessChannel>()
        }
        let cancellation = match (modelProcessClaimCancellation(claim)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        openChannelInternal(request, cancellation, maxInputBytes, false, Option<AtomicBool>.None, modelClaim: Some(claim))
    }
    public func openClaimedModelHttpExchange(owner: ProcessResourceOwner, claim: HostModelProcessLaunchClaim,
        rawRequest: AgentValue, packageRoot: String, policy: NetworkPolicy,
        credentials: Array<HostPluginHttpCredentialValue>, limits: ExecutionResourceLimits,
        payloadBody!: ?Array<Byte> = None, expanded!: Bool = false): Result<HostHttpExchangeReader> {
        match (verifyModelProcessClaim(claim, owner)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (!networkPolicyModeIsMediated(policy.mode)) { return hostNativeModelAdmissionDenied<HostHttpExchangeReader>() }
        let cancellation = match (modelProcessClaimCancellation(claim)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        openOwnedHttpExchange(owner, rawRequest, packageRoot, policy, cancellation,
            credentials, limits, payloadBody: payloadBody, expanded: expanded, modelClaim: Some(claim))
    }

    // Raw, bounded I/O primitive only. The caller must already own an
    // operation/lifecycle grant; this method does not mint canonical authority.
    public func openChannel(request: ProcessRequest, cancellation: domain.CancellationToken): Result<ProcessChannel> {
        openChannel(request, cancellation, 1048576)
    }

    public func openChannel(
        authored: ProcessRequest,
        cancellation: domain.CancellationToken,
        maxInputBytes: Int64
    ): Result<ProcessChannel> {
        if (authored.resourceOwner.operation.isNone()) { return hostNativeModelAdmissionDenied<ProcessChannel>() }
        openChannelInternal(authored, cancellation, maxInputBytes, false, Option<AtomicBool>.None)
    }

    // Only the actual claimed-Attempt gate can reach this entry. Descriptive
    // ModelAttempt IDs and public raw-process calls are insufficient.


    // Host-private fixed HTTP transport. No raw secret-bearing ProcessChannel
    // or general launcher leaves this method. Execution authority must already
    // have crossed canonical handoff in the caller's actual child Operation.
    public func openHttpExchange(operationId: OperationId, rawRequest: AgentValue,
        packageRoot: String, policy: NetworkPolicy, cancellation: domain.CancellationToken,
        credentials: Array<HostPluginHttpCredentialValue>, limits: ExecutionResourceLimits,
        payloadBody!: ?Array<Byte> = None, expanded!: Bool = false
    ): Result<HostHttpExchangeReader> {
        openOwnedHttpExchange(ProcessResourceOwner.Operation(operationId), rawRequest,
            packageRoot, policy, cancellation, credentials, limits,
            payloadBody: payloadBody, expanded: expanded)
    }



    private func openOwnedHttpExchange(resourceOwner: ProcessResourceOwner, rawRequest: AgentValue,
        packageRoot: String, policy: NetworkPolicy, cancellation: domain.CancellationToken,
        credentials: Array<HostPluginHttpCredentialValue>, limits: ExecutionResourceLimits,
        payloadBody!: ?Array<Byte> = None, expanded!: Bool = false,
        modelClaim!: ?HostModelProcessLaunchClaim = None
    ): Result<HostHttpExchangeReader> {
        let launch = match (prepareHostHttpStreamLaunch(rawRequest, credentials, policy, payloadBody: payloadBody, expanded: expanded,
            timeoutMaximum: if (modelClaim.isSome()) { Int64.Max } else { 120000 },
            allowZeroTimeout: modelClaim.isSome(), modelEnvelope: modelClaim.isSome())) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        var timeout = launch.timeoutMillis
        if (cancellation.deadlineMillis > 0) {
            let remaining = cancellation.deadlineMillis - agentUtcMillis()
            if (remaining < 1) {
                return Result.Err(AgentError(AgentErrorKind.Cancelled, "http.exchange_cancelled",
                    "HTTP exchange deadline elapsed before launch"))
            }
            timeout = if (timeout == 0 && modelClaim.isSome()) { remaining } else { min(timeout, remaining) }
        }
        let wireLimit = launch.maxBodyBytes + 40960
        let boundedLimits = ExecutionResourceLimits(
            maxOutputBytes: if (limits.maxOutputBytes > 0) { min(wireLimit, limits.maxOutputBytes) } else { wireLimit },
            addressSpaceBytes: limits.addressSpaceBytes, fileSizeBytes: limits.fileSizeBytes,
            openFiles: limits.openFiles, processes: limits.processes, cpuSeconds: limits.cpuSeconds)
        let request = ProcessRequest("/usr/bin/curl", resourceOwner: Some(resourceOwner),
            arguments: launch.arguments, workingDirectory: packageRoot, timeoutMillis: timeout,
            sandboxMode: ProcessSandboxMode.IsolatedReadOnly, filesystemRoot: packageRoot,
            networkPolicy: Some(policy), redactedValues: launch.secrets, processLimits: boundedLimits)
        let launchStarted = AtomicBool(false)
        let channel = match (openChannelInternal(request, cancellation, max(1, launch.body.size), true, Some(launchStarted), modelClaim: modelClaim)) {
            case Result.Err(error) =>
                if (cancellation.isCancelled()) {
                    return Result.Err(AgentError(AgentErrorKind.Cancelled, "http.exchange_cancelled",
                        "HTTP exchange caller was cancelled", retryable: false, fallbackAllowed: false))
                }
                if (launchStarted.load()) { return hostNativeHttpUnknown("HTTP launch crossed its process handoff without a response owner") }
                return Result.Err(error)
            case Result.Ok(value) => value
        }
        let reader = HostHttpExchangeReader(channel, cancellation, launch.secrets, maxBodyBytes: launch.maxBodyBytes)
        var handedOff = false
        try {
            var offset: Int64 = 0
            while (offset < launch.body.size) {
                match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                let end = min(launch.body.size, offset + 65536)
                if (channel.write(launch.body[offset..end]).isError()) { return hostNativeHttpUnknown("HTTP request write is unverified") }
                offset = end
            }
            if (channel.closeInput().isError()) { return hostNativeHttpUnknown("HTTP request input closure is unverified") }
            match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            handedOff = true
            Result.Ok(reader)
        } catch (_: Exception) { hostNativeHttpUnknown("HTTP exchange could not publish a bounded response owner") }
        finally {
            // An unacknowledged close remains in channelOwners, even if no
            // reader can be returned. The executor retries closeChannelOperation.
            if (!handedOff) { let _ = reader.close() }
        }
    }

    // This host setting governs raw service transport only. Embedders that
    // omit it retain their existing ordinary-process output ceiling.
    private func lifecycleChannelResources(requested: ExecutionResourceLimits): SandboxResourceLimits {
        let ordinary = hostEffectiveProcessResources(sandboxResourcesValue, requested)
        SandboxResourceLimits(
            maxOutputBytes: hostIntersectProcessLimit(lifecycleChannelOutputBytesValue, requested.maxOutputBytes),
            addressSpaceBytes: ordinary.addressSpaceBytes, fileSizeBytes: ordinary.fileSizeBytes,
            openFiles: ordinary.openFiles, processes: ordinary.processes, cpuSeconds: ordinary.cpuSeconds)
    }

    // The shared host port carries an opaque capability, never decoded grant
    // data. Only this actual operator grant reaches the existing private
    // launcher; the shared marker alone grants no process authority.
    public func openLifecycleChannel(request: ProcessRequest,
        grant: HostLifecycleProcessLaunchGrant,
        cancellation: domain.CancellationToken, maximumInput: Int64): Result<ProcessChannel> {
        let binding = match (lifecycleLaunchAuthorityValue) {
            case Some(authority) => match (authority.bind(grant)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            case None => return hostNativeLifecycleGrantMismatch<ProcessChannel>()
        }
        openLifecycleBoundChannel(request, binding, cancellation, maximumInput)
    }

    // Package-private: the sole lifecycle owner calls after actual canonical
    // handoff. No ProcessPort method accepts or returns a raw secret channel.


    private func openLifecycleBoundChannel(request: ProcessRequest, binding: HostLifecycleProcessLaunchBinding,
        cancellation: domain.CancellationToken, maximumInput: Int64): Result<ProcessChannel> {
        match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        // Host mode is selected only from the same current operator grant as the
        // request. Public raw callers cannot supply this internal permission.
        let granted = match (binding.processRequest(request.operationId)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        if (canonicalAgentValue(networkPolicyCanonicalValue(granted.networkPolicy)) !=
            canonicalAgentValue(networkPolicyCanonicalValue(request.networkPolicy))) {
            return Result.Err(hostNativeChannelFactoryError(AgentErrorKind.PermissionDenied,
                "process.channel_grant_mismatch", "process network policy differs from its current grant"))
        }
        if (request.processLimits.maxOutputBytes != granted.processLimits.maxOutputBytes ||
            request.processLimits.maxOutputBytes > lifecycleChannelOutputBytesValue) {
            return Result.Err(hostNativeChannelFactoryError(AgentErrorKind.PermissionDenied,
                "process.channel_transport_ceiling", "granted transport output exceeds the actual host ceiling"))
        }
        let environment = match (binding.resolveProcessEnvironment()) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        let namespaceGrant=match(binding as HostActualManagedProcessLaunchBinding){
            case Some(value)=>value.namespaceGrant();case None=>None<HostManagedProcessGrant>}
        let raw = match (openChannelInternal(request, cancellation, maximumInput, false, Option<AtomicBool>.None,
            processEnvironment: Some(environment), lifecycleHostNetwork: networkPolicyModeIsHost(granted.networkPolicy.mode),
            lifecycleTransport: true,
            initialOutputWindowBytes: Some(binding.initialOutputWindowBytes()),
            registryEffect: Some({ => hostEnterLifecycleRegistryEffect(binding) }),managedNamespace:namespaceGrant)) {
            case Result.Err(error) => return Result.Err(AgentError(error.kind,
                "process.channel_environment_launch_failed", "configured process could not be launched",
                retryable: false, fallbackAllowed: false))
            case Result.Ok(value) => value
        }
        try {
            if (environment.secrets().isEmpty()) { return Result.Ok(raw) }
            Result.Ok(HostProcessSecretChannel(raw, environment.secrets(),
                lifecycleChannelResources(request.processLimits).maxOutputBytes))
        } catch (_: Exception) {
            // Failed wrapper publication does not lose the retained native owner.
            let _ = raw.abort(); let _ = raw.close()
            hostProcessEnvironmentChannelError("process.channel_output_boundary_unavailable")
        }
    }

    private func openChannelInternal(authored: ProcessRequest, cancellation: domain.CancellationToken,
        maxInputBytes: Int64, wrappedHttp: Bool, launchStarted: ?AtomicBool,
        processEnvironment!: ?HostLifecycleProcessLaunchEnvironment = None,
        lifecycleHostNetwork!: Bool = false,
        lifecycleTransport!: Bool = false,
        initialOutputWindowBytes!: ?Int64 = None,
        modelClaim!: ?HostModelProcessLaunchClaim = None,
        registryEffect!: ?() -> Result<PluginRegistryExecutionFence> = None,
        managedNamespace!: ?HostManagedProcessGrant = None<HostManagedProcessGrant>): Result<ProcessChannel> {
        if ((authored.resourceOwner.operation.isNone() && modelClaim.isNone()) ||
            (authored.resourceOwner.operation.isSome() && modelClaim.isSome())) {
            return hostNativeModelAdmissionDenied<ProcessChannel>()
        }
        match (modelClaim) { case Some(claim) =>
            match (verifyModelProcessClaim(claim, authored.resourceOwner)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            case None => () }
        // Array-valued request fields are copied before any asynchronous work.
        let request = try {
            ProcessRequest(authored.executable, resourceOwner: Some(authored.resourceOwner),
                arguments: authored.arguments.clone(), workingDirectory: authored.workingDirectory,
                timeoutMillis: authored.timeoutMillis, sandboxMode: authored.sandboxMode,
                filesystemRoot: authored.filesystemRoot, readOnlyMounts: authored.readOnlyMounts.clone(),
                networkPolicy: NetworkPolicy(authored.networkPolicy.mode,
                    egress: authored.networkPolicy.egress, publish: authored.networkPolicy.publish),
                environmentAllowlist: match (processEnvironment) { case Some(value) => value.names(); case None => authored.environmentAllowlist.clone() },
                secretEnvironmentAllowlist: match (processEnvironment) { case Some(value) => value.secretNames(); case None => authored.secretEnvironmentAllowlist.clone() },
                redactedValues: match (processEnvironment) { case Some(value) => value.secrets(); case None => authored.redactedValues.clone() },
                displayServerAccess: authored.displayServerAccess,
                processLimits: authored.processLimits)
        } catch (_: Exception) {
            return Result.Err(hostNativeChannelFactoryError(AgentErrorKind.InvalidInput,
                "process.channel_request_invalid", "process channel request could not be frozen"))
        }
        if (request.sandboxMode == ProcessSandboxMode.Host ||
            (!networkPolicyModeIsDenied(request.networkPolicy.mode) &&
                !networkPolicyModeIsMediated(request.networkPolicy.mode) &&
                 !(lifecycleHostNetwork && networkPolicyModeIsHost(request.networkPolicy.mode))) ||
            request.displayServerAccess) {
            return Result.Err(hostNativeChannelFactoryError(AgentErrorKind.PermissionDenied,
                "process.channel_policy_denied", "process channel network requires its explicit private lifecycle grant"))
        }
        if (processEnvironment.isNone() &&
            (!request.secretEnvironmentAllowlist.isEmpty() || (!wrappedHttp && !request.redactedValues.isEmpty()))) {
            return Result.Err(hostNativeChannelFactoryError(AgentErrorKind.PermissionDenied,
                "process.channel_secrets_unsupported", "raw channels do not support secret injection or streaming redaction"))
        }
        for (name in request.environmentAllowlist where name == "PATH") {
            return Result.Err(hostNativeChannelFactoryError(AgentErrorKind.PermissionDenied,
                "process.channel_path_denied", "raw channels use the sandbox's fixed system PATH"))
        }
        let outputLimit = if (lifecycleTransport) { lifecycleChannelResources(request.processLimits).maxOutputBytes }
            else { hostEffectiveProcessResources(sandboxResourcesValue, request.processLimits).maxOutputBytes }
        let outputMaximum = if (lifecycleTransport) { HOST_LIFECYCLE_TRANSPORT_OUTPUT_BYTES } else { HOST_NATIVE_DEFAULT_IO_BYTES }
        let modelOwned = modelClaim.isSome()
        // The actual private Attempt gate above is required for this lifetime
        // and input allowance. Public raw/Service paths retain their finite
        // limits; host output/address-space/etc intersections are unchanged.
        if ((if (modelOwned) { request.timeoutMillis < 0 } else { request.timeoutMillis < 1 || request.timeoutMillis > 3600000 }) ||
            maxInputBytes < 1 || maxInputBytes > (if (modelOwned) { 67108864 } else { 16777216 }) ||
            outputLimit < 1 || outputLimit > outputMaximum) {
            return Result.Err(hostNativeChannelFactoryError(AgentErrorKind.InvalidInput,
                "process.channel_limits_invalid", "channels require finite lifetime and byte reservations within host ceilings"))
        }
        if (request.resourceOwner.key == ProcessResourceOwner.Operation(OperationId("process")).key) {
            return Result.Err(hostNativeChannelFactoryError(AgentErrorKind.InvalidInput,
                "process.channel_operation_required", "channel requires an explicit operation identity"))
        }
        if (!sandboxEnabledValue) { return hostSandboxRequired<ProcessChannel>(request) }
        if (networkPolicyModeIsMediated(request.networkPolicy.mode) &&
            (sandboxCaBundleValue == "" || sandboxCaBundleMountValue.isNone())) {
            return Result.Err(hostNativeChannelFactoryError(AgentErrorKind.Configuration,
                "sandbox.ca_unavailable", "no readable sandbox CA bundle is available"))
        }
        match (cancellation.check()) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let admission: ?() -> Result<PluginRegistryExecutionFence> = match (modelClaim) {
            case Some(claim) => Some({ => hostEnterInstalledModelRegistryEffect(claim, request.resourceOwner) })
            case None => match (registryEffect) { case Some(value) => Some(value); case None => registryAdmission }
        }
        let owner = HostNativeProcessChannelOwner(request.resourceOwner, cancellation)
        var reservationError: ?AgentError = None
        activeLock.lock()
        try {
            if (channelsClosed) {
                reservationError = Some(hostNativeChannelFactoryError(AgentErrorKind.Cancelled,
                    "process.channel_port_closed", "process channel admission is closed"))
            } else if (resourceReservedCancelled(request.resourceOwner)) {
                reservationError = Some(hostNativeChannelFactoryError(AgentErrorKind.Cancelled,
                    "process.cancelled", "process operation was cancelled before launch"))
            } else if (channelOwners.size >= 32) {
                reservationError = Some(hostNativeChannelFactoryError(AgentErrorKind.InvalidInput,
                    "process.channel_capacity", "process channel ownership limit reached"))
            } else {
                var duplicate = false
                match (request.resourceOwner.operation) { case Some(id) => if (hookActiveLocked159h(id)) { duplicate = true }; case None => () }
                for (item in channelOwners where item.resourceOwner.key == request.resourceOwner.key) { duplicate = true }
                for (item in active where ProcessResourceOwner.Operation(item.operationId).key == request.resourceOwner.key) { duplicate = true }
                if (duplicate) {
                    reservationError = Some(hostNativeChannelFactoryError(AgentErrorKind.InvalidInput,
                        "process.channel_operation_duplicate", "operation already owns a live process or channel"))
                } else { channelOwners.add(owner) }
            }
        } finally { activeLock.unlock() }
        match (reservationError) {
            case Some(error) => owner.cancellation.close(); return Result.Err(error)
            case None => ()
        }
        try {
            match (openReservedChannel(request, owner, maxInputBytes, outputLimit, launchStarted, processEnvironment, modelClaim, outputMaximum, initialOutputWindowBytes, admission, managedNamespace)) {
                case Result.Ok(channel) => Result.Ok(channel)
                case Result.Err(error) =>
                    finishFailedChannelOpen(owner)
                    Result.Err(error)
            }
        } catch (_: Exception) {
            // Errors may contain paths or process diagnostics. The public raw
            // transport failure stays bounded and never reflects environment.
            finishFailedChannelOpen(owner)
            Result.Err(hostNativeChannelFactoryError(AgentErrorKind.Transport,
                "process.channel_launch_failed", "isolated process channel could not be opened"))
        }
    }

    private func openReservedChannel(request: ProcessRequest, owner: HostNativeProcessChannelOwner,
        maxInputBytes: Int64, maxOutputBytes: Int64, launchStarted: ?AtomicBool,
        processEnvironment: ?HostLifecycleProcessLaunchEnvironment,
        modelClaim: ?HostModelProcessLaunchClaim, outputMaximum: Int64,
        initialOutputWindowBytes: ?Int64, registryEffect: ?() -> Result<PluginRegistryExecutionFence>,
        managedNamespace: ?HostManagedProcessGrant): Result<ProcessChannel> {
        if (channelOwnerCancelled(owner)) {
            return Result.Err(hostNativeChannelFactoryError(AgentErrorKind.Cancelled,
                "process.channel_cancelled", "channel was cancelled before preparation"))
        }
        let filesystemRoot = if (request.sandboxMode == ProcessSandboxMode.IsolatedReadOnly) {
            canonicalize(Path(request.filesystemRoot)).toString()
        } else { workspace.rootPath() }
        for (authoredMount in request.readOnlyMounts) {
            let mount = SandboxReadOnlyMount(authoredMount)
            if (processRootsOverlap(filesystemRoot, mount.resolvedPath)) {
                return Result.Err(hostNativeChannelFactoryError(AgentErrorKind.PermissionDenied,
                    "process.channel_mount_overlap", "explicit read-only grants cannot overlap the channel workspace"))
            }
        }
        let workingDirectory = if (request.workingDirectory == "") {
            if (request.sandboxMode == ProcessSandboxMode.IsolatedReadOnly) {
                request.filesystemRoot
            } else { workspace.rootPath() }
        } else { request.workingDirectory }
        // WorkspaceSandbox.plan resolves cwd against the selected root and
        // explicit read-only mounts, and rejects every other host path.
        let lease = match (acquireNetworkGateway(request)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        activeLock.lock()
        try { owner.gateway = lease } finally { activeLock.unlock() }
        match (lease) {
            case Some(value) =>
                if (value.resourceOwner.key != request.resourceOwner.key ||
                    value.bridgeExecutable == "" || value.bridgeSocket == "") {
                    return Result.Err(hostNativeChannelFactoryError(AgentErrorKind.Configuration,
                        "process.channel_gateway_invalid", "mediated channel requires its exact operation's isolated gateway bridge"))
                }
            case None => ()
        }
        if (channelOwnerCancelled(owner)) {
            return Result.Err(hostNativeChannelFactoryError(AgentErrorKind.Cancelled,
                "process.channel_cancelled", "channel was cancelled during gateway acquisition"))
        }
        let filesystem = if (request.sandboxMode == ProcessSandboxMode.WorkspaceReadWrite) {
            FilesystemIsolationMode.WorkspaceReadWrite
        } else { FilesystemIsolationMode.WorkspaceReadOnly }
        let sandbox = processSandbox(request, filesystem, networkLease: lease, strictChannel: true)
        let environment = ArrayList<SandboxEnvironmentEntry>()
        // Only the fixed host-selected CA bundle is added. This never inherits
        // ambient proxy/PATH/loader variables or general sandbox mount lists.
        if (!networkPolicyModeIsDenied(request.networkPolicy.mode)) { environment.add(all: sandboxEnvironment(request)) }
        match (processEnvironment) { case Some(value) => environment.add(all: value.entries()); case None => () }
        let plan = match (sandbox.plan(WorkspaceSandboxCommand(request.executable,
            arguments: request.arguments, workingDirectory: workingDirectory,
            environment: environment.toArray(),
            // Channels launch sandboxExecutable/sandboxArguments below, not
            // the plan's one-shot GNU-timeout wrapper. Their monitor owns the
            // actual timeout/token. A positive unused planning value preserves
            // the existing public sandbox command constructor invariant.
            timeoutMillis: max(1, request.timeoutMillis),
            networkBridgeExecutable: match (lease) { case Some(value) => value.bridgeExecutable; case None => "" },
            networkBridgeSocket: match (lease) { case Some(value) => value.bridgeSocket; case None => "" }
        ))) {
            case SandboxResult.Ok(value) => value
            case SandboxResult.Err(error) => return Result.Err(hostSandboxAgentError(error))
        }
        match (sandbox.availability()) {
            case SandboxResult.Err(error) => return Result.Err(hostSandboxAgentError(error))
            case SandboxResult.Ok(_) => ()
        }
        if (channelOwnerCancelled(owner)) {
            return Result.Err(hostNativeChannelFactoryError(AgentErrorKind.Cancelled,
                "process.channel_cancelled", "channel was cancelled before launch"))
        }
        match (modelClaim) { case Some(claim) =>
            match (verifyModelProcessClaim(claim, request.resourceOwner)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            case None => () }
        // Only the trusted sandbox executable/argv are launched. This never
        // falls back to executing request.executable on the host.
        // process4cj treats an empty map as inherit: a nonempty fixed map is
        // necessary even for the outer sandbox launcher, before --clearenv.
        let launcherEnvironment = HashMap<String, String>()
        launcherEnvironment["PATH"] = "/usr/local/bin:/usr/bin:/bin"
        launcherEnvironment["LANG"] = "C.UTF-8"
        // Host-only monotone witness: even a throwing start can cross the
        // OS process boundary. Pre-launch policy failures remain known failures.
        let held = match (hostAcquireRegistryEffect(registryEffect)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let process = try {
            match (launchStarted) { case Some(value) => value.store(true); case None => () }
            match(managedNamespace){
                case None=>startProcess(ProcessCommand(plan.sandboxExecutable,
                    arguments:plan.sandboxArguments,workingDirectory:plan.workingDirectory,
                    environment:launcherEnvironment,maxOutputBytes:maxOutputBytes,terminateProcessTree:true))
                case Some(actual)=>
                    let projected=match(hostManagedNamespaceSandboxArguments(plan.sandboxArguments,
                        networkPolicyModeIsHost(request.networkPolicy.mode))){
                        case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(value)=>value}
                    match(actual.withBorrowedNamespaces<ManagedProcess>({owned=>
                        Result.Ok(startProcessInSandboxNamespaces(ProcessCommand(plan.sandboxExecutable,
                            arguments:projected,workingDirectory:plan.workingDirectory,
                            environment:launcherEnvironment,maxOutputBytes:maxOutputBytes,terminateProcessTree:true),owned))})){
                        case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(value)=>value}
            }
        } finally { hostCloseRegistryEffect(held) }
        activeLock.lock()
        try { owner.processStarted = true } finally { activeLock.unlock() }
        let channel = HostNativeProcessChannel(process, owner.cancellation.token,
            request.timeoutMillis, maxInputBytes, maxOutputBytes,
            { => releaseChannelOwner(owner) }, modelAttemptLifetime: modelClaim.isSome(), outputMaximum: outputMaximum,
            initialOutputWindowBytes: initialOutputWindowBytes, registryAdmission: registryEffect)
        var cancelled = false
        activeLock.lock()
        try {
            owner.opening = false
            // Initialization failure can finish cleanup before publication.
            // Never restore an owner already retired by that callback.
            if (!owner.released) { owner.channel = Some(channel) }
            cancelled = channelsClosed || owner.cancelled || owner.released ||
                (resourceReservedCancelled(request.resourceOwner))
        } finally { activeLock.unlock() }
        match (channel.initializationError()) {
            case Some(error) => let _ = channel.close(); return Result.Err(error)
            case None => ()
        }
        match (modelClaim) { case Some(claim) => if (verifyModelProcessClaim(claim, request.resourceOwner).isError()) { cancelled = true }; case None => () }
        if (cancelled || owner.cancellation.token.isCancelled()) {
            let _ = owner.cancellation.cancel()
            let _ = channel.close()
            return Result.Err(hostNativeChannelFactoryError(AgentErrorKind.Cancelled,
                "process.channel_cancelled", "channel admission was revoked during launch"))
        }
        Result.Ok(channel)
    }

    private func channelOwnerCancelled(owner: HostNativeProcessChannelOwner): Bool {
        var revoked = false
        activeLock.lock()
        try { revoked = channelsClosed || owner.cancelled || resourceReservedCancelled(owner.resourceOwner) }
        finally { activeLock.unlock() }
        revoked || owner.cancellation.token.isCancelled()
    }

    private func finishFailedChannelOpen(owner: HostNativeProcessChannelOwner): Unit {
        var noProcess = false
        var channel: ?ProcessChannel = None
        activeLock.lock()
        try {
            owner.opening = false
            owner.cancelled = true
            noProcess = !owner.processStarted
            channel = owner.channel
        } finally { activeLock.unlock() }
        let _ = owner.cancellation.cancel()
        if (noProcess) { cleanupUnlaunchedChannel(owner) }
        match (channel) { case Some(value) => let _ = value.close(); case None => () }
    }

    private func releaseChannelOwner(owner: HostNativeProcessChannelOwner): Unit {
        // Gateway release can wait on its own process. Never run it under the
        // admission lock, and never retire the reservation before it succeeds.
        owner.releaseLock.lock()
        try {
            var released = false
            var lease: ?NetworkGatewayLease = None
            activeLock.lock()
            try { released = owner.released; lease = owner.gateway } finally { activeLock.unlock() }
            if (released) { return }
            match (lease) {
                case Some(value) =>
                    match (networkGatewayValue) {
                        case Some(gateway) =>
                            match (gateway.release(value)) {
                                case Result.Err(_) => throw IllegalStateException("process.channel_gateway_release_failed")
                                case Result.Ok(_) => ()
                            }
                        case None => throw IllegalStateException("process.channel_gateway_release_unavailable")
                    }
                case None => ()
            }
            owner.cancellation.close()
            activeLock.lock()
            try {
                owner.released = true
                owner.channel = None
                owner.gateway = None
                for (index in 0..channelOwners.size) {
                    if (channelOwners[index].resourceOwner.key == owner.resourceOwner.key) {
                        channelOwners.remove(at: index)
                        break
                    }
                }
            } finally { activeLock.unlock() }
        } finally { owner.releaseLock.unlock() }
    }

    private func cleanupUnlaunchedChannel(owner: HostNativeProcessChannelOwner): Unit {
        // A failed prepare can already own a gateway. Reclaim it in an owned
        // task so a slow gateway cannot turn Port.close into a blocking wait.
        owner.cleanupLock.lock()
        try {
            if (!owner.cleanupStarted || (owner.cleanupDone.load() && owner.cleanupFailed.load())) {
                owner.cleanupStarted = true
                owner.cleanupDone.store(false)
                owner.cleanupFailed.store(false)
                try {
                    owner.cleanup = Some(spawn {
                        try { releaseChannelOwner(owner) }
                        catch (_: Exception) { owner.cleanupFailed.store(true) }
                        finally { owner.cleanupDone.store(true) }
                    })
                } catch (_: Exception) {
                    // Failure to create a cleanup task is not permission to
                    // return its gateway or capacity. A later close retries.
                    owner.cleanupStarted = false
                    owner.cleanupFailed.store(true)
                    owner.cleanupDone.store(true)
                }
            }
        } finally { owner.cleanupLock.unlock() }
    }

    public func closeChannelOperation(operationId: OperationId): Result<Unit> {
        closeChannelResource(ProcessResourceOwner.Operation(operationId))
    }

    public func closeChannelResource(resourceOwner: ProcessResourceOwner): Result<Unit> {
        var selected: ?HostNativeProcessChannelOwner = None
        activeLock.lock()
        try {
            for (owner in channelOwners where owner.resourceOwner.key == resourceOwner.key) {
                owner.cancelled = true
                selected = Some(owner)
                break
            }
        } finally { activeLock.unlock() }
        let owner = match (selected) {
            case Some(value) => value
            // Idempotent acknowledgement at this point in time. Operation IDs
            // must be unique to their caller's lifecycle; this is not a ban on
            // a future independently admitted operation using the same ID.
            case None => return Result.Ok(())
        }
        var cleanupError: ?AgentError = None
        try { let _ = owner.cancellation.cancel() }
        catch (_: Exception) {
            cleanupError = Some(hostNativeChannelFactoryError(AgentErrorKind.Transport,
                "process.channel_close_failed", "channel cancellation could not complete"))
        }
        var channel: ?ProcessChannel = None
        var opening = false
        var unlaunched = false
        activeLock.lock()
        try {
            if (owner.released) { return Result.Ok(()) }
            channel = owner.channel
            opening = owner.opening
            unlaunched = !owner.opening && !owner.processStarted
        } finally { activeLock.unlock() }
        if (opening) {
            return Result.Err(hostNativeChannelFactoryError(AgentErrorKind.Transport,
                "process.channel_close_pending", "channel launch or cleanup remains owned and pending"))
        }
        try {
            match (channel) {
                case Some(value) =>
                    match (value.close()) {
                        case Result.Err(error) => cleanupError = Some(error)
                        case Result.Ok(_) => ()
                    }
                case None => if (unlaunched) { cleanupUnlaunchedChannel(owner) }
            }
        } catch (_: Exception) {
            cleanupError = Some(hostNativeChannelFactoryError(AgentErrorKind.Transport,
                "process.channel_close_failed", "channel cleanup could not start"))
        }
        // Observe the captured owner, never cancel a newly admitted sibling
        // or infer release from cancel/close success alone. The callback sets
        // released only after native I/O and gateway cleanup actually finish.
        activeLock.lock()
        try { if (owner.released) { return Result.Ok(()) } }
        finally { activeLock.unlock() }
        match (cleanupError) {
            case Some(error) => Result.Err(error)
            case None => Result.Err(hostNativeChannelFactoryError(AgentErrorKind.Transport,
                "process.channel_close_pending", "channel launch or cleanup remains owned and pending"))
        }
    }

    private func closeChannels(): Result<Unit> {
        let owners: Array<HostNativeProcessChannelOwner>
        activeLock.lock()
        try {
            channelsClosed = true
            owners = channelOwners.toArray()
            for (owner in owners) { owner.cancelled = true }
        } finally { activeLock.unlock() }
        var firstError: ?AgentError = None
        // Revoke every owner before awaiting any individual cleanup. One
        // slow or failed channel must not retain permission for its siblings.
        for (owner in owners) {
            try { let _ = owner.cancellation.cancel() }
            catch (_: Exception) {
                if (firstError.isNone()) { firstError = Some(hostNativeChannelFactoryError(AgentErrorKind.Transport,
                    "process.channel_close_failed", "one or more channel owners could not be cancelled")) }
            }
        }
        for (owner in owners) {
            var channel: ?ProcessChannel = None
            var unlaunched = false
            activeLock.lock()
            try {
                channel = owner.channel
                unlaunched = !owner.opening && !owner.processStarted && !owner.released
            } finally { activeLock.unlock() }
            try {
                match (channel) {
                    case Some(value) =>
                        match (value.close()) {
                            case Result.Err(error) => if (firstError.isNone()) { firstError = Some(error) }
                            case Result.Ok(_) => ()
                        }
                    case None => if (unlaunched) { cleanupUnlaunchedChannel(owner) }
                }
            } catch (_: Exception) {
                if (firstError.isNone()) { firstError = Some(hostNativeChannelFactoryError(AgentErrorKind.Transport,
                    "process.channel_close_failed", "one or more channel cleanup tasks could not start")) }
            }
        }
        var retained = false
        activeLock.lock()
        try { retained = !channelOwners.isEmpty() } finally { activeLock.unlock() }
        match (firstError) {
            case Some(error) => Result.Err(error)
            case None =>
                if (retained) {
                    Result.Err(hostNativeChannelFactoryError(AgentErrorKind.Transport,
                        "process.channel_close_pending", "channel launch or cleanup remains owned and pending"))
                } else { Result.Ok(()) }
        }
    }
    // Product lifecycle boundary: no process, persistent shell, or eval
    // kernel owned by this execution plane may outlive ProductRuntime.close().
    public func beginNativeClose(): HostNativeProcessClose {
        let channelResult = closeChannels()
        let hookError159h = closeHookProcesses159h()
        var firstError = ""
        activeLock.lock()
        try {
            for (entry in active) {
                try {
                    entry.forceTerminateOwned()
                } catch (error: Exception) {
                    if (firstError == "") { firstError = error.message }
                }
            }
            active.clear()
        } finally {
            activeLock.unlock()
        }
        if (firstError == "") { firstError = hookError159h }
        HostNativeProcessClose(channelResult, firstError)
    }

    public func close(): Result<Unit> {
        let closing = beginNativeClose()
        let channelResult = closing.channelResult
        let firstError = closing.firstError
        if (firstError == "") {
            channelResult
        } else {
            Result.Err(AgentError(
                AgentErrorKind.Transport,
                "process.execution_plane_close_failed",
                firstError
            ))
        }
    }

    // The same process owner, with exactly the old fresh package-worker
    // sandbox projection. Product toolchains, CA, gateway, configured mounts
    // and host environment additions are deliberately absent from this path.
    // The canonical executor must validate its actual parent/package/source.
    public func executePackageReadOnlyWithRegistry(request: ProcessRequest, workspaceRoot: String,
        acquire: () -> Result<PluginRegistryExecutionFence>): Result<ProcessResult> {
        executePackageReadOnlyWithAdmission(request, workspaceRoot, Some(acquire))
    }

    public func executePackageReadOnly(request: ProcessRequest, workspaceRoot: String): Result<ProcessResult> {
        executePackageReadOnlyWithAdmission(request, workspaceRoot, None<(() -> Result<PluginRegistryExecutionFence>)>)
    }

    private func executePackageReadOnlyWithAdmission(request: ProcessRequest, workspaceRoot: String,
        registryEffect: ?() -> Result<PluginRegistryExecutionFence>): Result<ProcessResult> {
        if (request.resourceOwner.operation.isNone()) { return hostNativeModelAdmissionDenied<ProcessResult>() }
        if (request.sandboxMode != ProcessSandboxMode.WorkspaceReadOnly ||
            !networkPolicyModeIsDenied(request.networkPolicy.mode) || request.filesystemRoot != "" ||
            request.readOnlyMounts.size != 1 || !request.environmentAllowlist.isEmpty() ||
            !request.secretEnvironmentAllowlist.isEmpty() || !request.redactedValues.isEmpty() ||
            request.displayServerAccess || request.timeoutMillis < 1 || request.timeoutMillis > 60000) {
            return hostPluginResourceError("extension.process_narrow_profile", "package worker requires its exact readonly, network-denied host profile")
        }
        let root = try { canonicalize(Path(workspaceRoot)).toString() }
            catch (_: Exception) { return hostPluginResourceError("extension.process_workspace_invalid", "workspace root is unavailable") }
        if (root != workspaceRoot || request.workingDirectory != root) {
            return hostPluginResourceError("extension.process_narrow_root", "package worker requires the current canonical workspace as its exact working directory")
        }
        if (reservedOperationCancelled(request.operationId)) {
            return Result.Err(AgentError(AgentErrorKind.Cancelled, "process.cancelled", "process operation was cancelled before launch"))
        }
        let mounts = ArrayList<SandboxReadOnlyMount>()
        let mount = SandboxReadOnlyMount(request.readOnlyMounts[0])
        if (!processRootsOverlap(root, mount.resolvedPath)) { mounts.add(mount) }
        let sandbox = WorkspaceSandbox(WorkspaceSandboxPolicy(
            root, filesystem: FilesystemIsolationMode.WorkspaceReadOnly,
            process: ProcessIsolationMode.Isolated, network: NetworkIsolationMode.Denied,
            environment: EnvironmentFilter(allowlist: [
                "TERM", "COLORTERM", "NO_COLOR", "CANGJIE_HOME",
                "CANGJIE_SDK_ROOT", "CANGJIE_STDX_PATH", "JAVA_HOME"
            ], allowedSecrets: [], secretValues: []),
            resources: hostEffectiveProcessResources(defaultHostProcessSandboxResourceLimits(), request.processLimits),
            readOnlyMounts: mounts.toArray(), pathEntries: []
        ))
        // sandbox4cj owns native process.close in its execution finally. The
        // existing owner records late cancellation in onStarted; removing
        // this operation is necessary even if execution throws before return.
        let execution = try {
            sandbox.execute(WorkspaceSandboxCommand(
                request.executable, arguments: request.arguments, workingDirectory: root,
                environment: [], timeoutMillis: request.timeoutMillis,
                networkBridgeExecutable: "", networkBridgeSocket: ""),
                onStarted: Some({process => register(request.operationId, process)}),
                acquireLaunch: hostSandboxRegistryAdmission(match (registryEffect) { case Some(value) => Some(value); case None => registryAdmission }))
        } finally { finish(request.operationId) }
        match (execution) {
            case SandboxResult.Err(error) => Result.Err(hostSandboxAgentError(error))
            case SandboxResult.Ok(value) => Result.Ok(ProcessResult(
                value.exitCode, stdout: value.stdout, stderr: value.stderr,
                timedOut: value.timedOut, workingDirectory: root, truncated: value.outputTruncated))
        }
    }

    public func execute(request: ProcessRequest): Result<ProcessResult> {
        if (request.resourceOwner.operation.isNone()) { return hostNativeModelAdmissionDenied<ProcessResult>() }
        let requiresSandbox = request.sandboxMode != ProcessSandboxMode.Host ||
            networkPolicyModeIsMediated(request.networkPolicy.mode) ||
            networkPolicyModeIsDenied(request.networkPolicy.mode)
        if (requiresSandbox &&
            !networkPolicyModeIsDenied(request.networkPolicy.mode) &&
            (sandboxCaBundleValue == "" || sandboxCaBundleMountValue.isNone())) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "sandbox.ca_unavailable",
                "no readable sandbox CA bundle is available",
                retryable: false,
                fallbackAllowed: false
            ))
        }
        if (reservedOperationCancelled(request.operationId)) {
            return Result.Err(AgentError(AgentErrorKind.Cancelled, "process.cancelled", "process operation was cancelled before launch"))
        }
        let workingDirectory = if (request.sandboxMode == ProcessSandboxMode.IsolatedReadOnly) {
            if (request.workingDirectory == "") {
                request.filesystemRoot
            } else {
                request.workingDirectory
            }
        } else if (request.workingDirectory == "") {
            workspace.rootPath()
        } else {
            match (readOnlyMountedWorkingDirectory(
                request.workingDirectory, request.readOnlyMounts
            )) {
                case Some(value) => value
                case None => match (workspace.resolve(
                    request.workingDirectory,
                    allowDirectory: true
                )) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
            }
        }
        if (requiresSandbox) {
            if (!sandboxEnabledValue) {
                return hostSandboxRequired<ProcessResult>(request)
            }
            let gatewayLease = match (acquireNetworkGateway(request)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            let result = executeSandboxed(
                request,
                workingDirectory,
                networkLease: gatewayLease
            )
            releaseNetworkGateway(gatewayLease)
            return result
        }
        try {
            let arguments = ArrayList<String>()
            arguments.add(hostNativeTimeoutSeconds(request.timeoutMillis))
            arguments.add(request.executable)
            arguments.add(all: request.arguments)
            let launchArguments = ArrayList<String>()
            // Keep the tracked session leader alive until its command exits.
            // Without --wait, util-linux setsid forks and returns immediately.
            launchArguments.add("--wait")
            launchArguments.add("timeout")
            launchArguments.add(all: arguments.toArray())
            let held = match (hostAcquireRegistryEffect(registryAdmission)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            let process = try { launch(
                "setsid",
                launchArguments.toArray(),
                workingDirectory: Path(workingDirectory),
                environment: if (request.displayServerAccess) {
                    scopedDisplayServerEnvironment(request)
                } else {
                    None
                },
                stdOut: if (request.displayServerAccess) {
                    ProcessRedirect.Discard
                } else {
                    ProcessRedirect.Pipe
                },
                stdErr: if (request.displayServerAccess) {
                    ProcessRedirect.Discard
                } else {
                    ProcessRedirect.Pipe
                }
            ) } finally { hostCloseRegistryEffect(held) }
            register(request.operationId, process)
            let outputBudget = BoundedOutputBudget(
                hostEffectiveProcessResources(
                    sandboxResourcesValue, request.processLimits
                ).maxOutputBytes
            )
            let (output, error) = if (request.displayServerAccess) {
                (
                    Array<Byte>(0, repeat: 0),
                    Array<Byte>(0, repeat: 0)
                )
            } else {
                // Start both readers before waiting for either pipe.  A child
                // can fill stderr while stdout remains open.
                let outputFuture = spawn {
                    readBounded(process.stdOutPipe, outputBudget)
                }
                let errorFuture = spawn {
                    readBounded(process.stdErrPipe, outputBudget)
                }
                (outputFuture.get(), errorFuture.get())
            }
            let code = process.wait()
            Result.Ok(
                ProcessResult(
                    code,
                    stdout: decodeProcessOutput(output),
                    stderr: decodeProcessOutput(error),
                    timedOut: code == 124,
                    truncated: outputBudget.wasTruncated()
                )
            )
        } catch (error: Exception) {
            Result.Err(
                AgentError(
                    AgentErrorKind.Transport,
                    "process.execute",
                    error.message
                )
            )
        } finally { finish(request.operationId) }
    }

    // Program's worker protocol is full duplex over process stdio. This is a
    // concrete LocalProcessPort facility, not a new general ProcessPort
    // authority surface: it only launches WorkspaceReadOnly + Denied jobs.
    public func executeInteractive(
        request: ProcessRequest,
        cancellation: domain.CancellationToken,
        onFrame: (String) -> Result<?String>
    ): Result<ProcessResult> {
        if (registryAdmission.isSome()) {
            return hostPluginResourceError("process.registry_interactive_unsupported", "this legacy interactive transport cannot retain installed execution admission")
        }
        if (request.resourceOwner.operation.isNone()) { return hostNativeModelAdmissionDenied<ProcessResult>() }
        if (request.sandboxMode != ProcessSandboxMode.WorkspaceReadOnly ||
            !networkPolicyModeIsDenied(request.networkPolicy.mode)) {
            return Result.Err(AgentError(
                AgentErrorKind.PermissionDenied,
                "process.interactive_policy_denied",
                "interactive child processes require read-only workspace isolation and denied network"
            ))
        }
        if (!sandboxEnabledValue) { return hostSandboxRequired<ProcessResult>(request) }
        if (request.timeoutMillis < 1 || reservedOperationCancelled(request.operationId)) {
            return Result.Err(AgentError(
                AgentErrorKind.Cancelled,
                "process.cancelled",
                "interactive process was cancelled before launch"
            ))
        }
        let workingDirectory = if (request.workingDirectory == "") {
            workspace.rootPath()
        } else {
            match (workspace.resolve(request.workingDirectory, allowDirectory: true)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
        }
        let sandbox = processSandbox(request, FilesystemIsolationMode.WorkspaceReadOnly)
        let plan = match (sandbox.plan(WorkspaceSandboxCommand(
            request.executable,
            arguments: request.arguments,
            workingDirectory: workingDirectory,
            environment: sandboxEnvironment(request),
            timeoutMillis: request.timeoutMillis
        ))) {
            case SandboxResult.Ok(value) => value
            case SandboxResult.Err(error) => return Result.Err(hostSandboxAgentError(error))
        }
        match (sandbox.availability()) {
            case SandboxResult.Ok(_) => ()
            case SandboxResult.Err(error) => return Result.Err(hostSandboxAgentError(error))
        }
        try {
            let launchArguments = ArrayList<String>()
            launchArguments.add("--wait")
            launchArguments.add(plan.sandboxExecutable)
            launchArguments.add(all: plan.sandboxArguments)
            let process = launch(
                "setsid",
                launchArguments.toArray(),
                workingDirectory: Path(workingDirectory),
                environment: HashMap<String, String>(),
                stdIn: ProcessRedirect.Pipe,
                stdOut: ProcessRedirect.Pipe,
                stdErr: ProcessRedirect.Pipe
            )
            register(request.operationId, process)
            let outputBudget = BoundedOutputBudget(
                hostEffectiveProcessResources(
                    sandboxResourcesValue, request.processLimits
                ).maxOutputBytes
            )
            let termination = HostInteractiveProcessTerminationState()
            let deadline = MonoTime.now() + Duration.millisecond * request.timeoutMillis
            let outputFuture = spawn {
                hostReadInteractiveProgramFrames(
                    process.stdOutPipe,
                    process.stdInPipe,
                    outputBudget,
                    onFrame,
                    { => let _ = cancel(request.operationId) }
                )
            }
            let errorFuture = spawn { readBounded(process.stdErrPipe, outputBudget) }
            let monitor = spawn {
                while (process.isAlive()) {
                    if (cancellation.isCancelled()) {
                        termination.stop(cancelled: true)
                        let _ = cancel(request.operationId)
                        break
                    }
                    if (MonoTime.now() >= deadline) {
                        termination.stop(timedOut: true)
                        let _ = cancel(request.operationId)
                        break
                    }
                    sleep(Duration.millisecond * 10)
                }
            }
            let code = process.wait()
            let stdout = outputFuture.get()
            let stderr = errorFuture.get()
            monitor.get()
            finish(request.operationId)
            if (termination.cancelled()) {
                Result.Err(AgentError(
                    AgentErrorKind.Cancelled,
                    "process.cancelled",
                    "interactive process was cancelled"
                ))
            } else if (termination.timedOut()) {
                Result.Ok(ProcessResult(
                    code,
                    stdout: match (stdout) {
                        case Result.Ok(value) => value
                        case Result.Err(_) => ""
                    },
                    stderr: decodeProcessOutput(stderr),
                    timedOut: true,
                    workingDirectory: workingDirectory,
                    truncated: outputBudget.wasTruncated()
                ))
            } else {
                match (stdout) {
                    case Result.Err(error) => Result.Err(error)
                    case Result.Ok(value) => Result.Ok(ProcessResult(
                        code,
                        stdout: value,
                        stderr: decodeProcessOutput(stderr),
                        workingDirectory: workingDirectory,
                        truncated: outputBudget.wasTruncated()
                    ))
                }
            }
        } catch (error: Exception) {
            let _ = cancel(request.operationId)
            finish(request.operationId)
            Result.Err(AgentError(
                AgentErrorKind.Transport,
                "process.interactive_execute",
                error.message
            ))
        }
    }



    private func acquireNetworkGateway(
        request: ProcessRequest
    ): Result<?NetworkGatewayLease> {
        if (!networkPolicyModeIsMediated(request.networkPolicy.mode)) {
            return Result.Ok(Option<NetworkGatewayLease>.None)
        }
        match (networkGatewayValue) {
            case Some(gateway) =>
                match (gateway.acquireResource(request.resourceOwner, request.networkPolicy)) {
                    case Result.Ok(value) => Result.Ok(Some(value))
                    case Result.Err(error) => Result.Err(error)
                }
            case None => Result.Err(networkGatewayUnavailableError())
        }

    }
    private func releaseNetworkGateway(lease: ?NetworkGatewayLease): Unit {
        match (lease) {
            case None => ()
            case Some(value) =>
                match (networkGatewayValue) {
                    case Some(gateway) => let _ = gateway.release(value)
                    case None => ()
                }
        }
    }


    private func executeSandboxed(
        request: ProcessRequest,
        workingDirectory: String,
        networkLease!: ?NetworkGatewayLease = None
    ): Result<ProcessResult> {
        let filesystem = if (request.sandboxMode == ProcessSandboxMode.Host) {
            FilesystemIsolationMode.Host
        } else if (request.sandboxMode == ProcessSandboxMode.WorkspaceReadOnly ||
            request.sandboxMode == ProcessSandboxMode.IsolatedReadOnly) {
            FilesystemIsolationMode.WorkspaceReadOnly
        } else {
            FilesystemIsolationMode.WorkspaceReadWrite
        }
        let sandbox = processSandbox(request, filesystem, networkLease: networkLease)
        let execution = sandbox.execute(
            WorkspaceSandboxCommand(
                request.executable,
                arguments: request.arguments,
                workingDirectory: workingDirectory,
                environment: sandboxEnvironment(request),
                timeoutMillis: request.timeoutMillis,
                networkBridgeExecutable: match (networkLease) {
                    case Some(value) => value.bridgeExecutable
                    case None => ""
                },
                networkBridgeSocket: match (networkLease) {
                    case Some(value) => value.bridgeSocket
                    case None => ""
                }
            ),
            onStarted: Some({process => register(request.operationId, process)}),
            acquireLaunch: hostSandboxRegistryAdmission(registryAdmission)
        )
        finish(request.operationId)
        match (execution) {
            case SandboxResult.Err(error) => Result.Err(hostSandboxAgentError(error))
            case SandboxResult.Ok(value) => Result.Ok(ProcessResult(
                value.exitCode,
                stdout: value.stdout,
                stderr: value.stderr,
                timedOut: value.timedOut,
                workingDirectory: workingDirectory,
                truncated: value.outputTruncated
            ))
        }
    }

    private func processEnvironmentAllowlist(
        request: ProcessRequest,
        includeDisplayServer!: Bool = false
    ): Array<String> {
        let allowed = ArrayList<String>()
        allowed.add(all: [
            "TERM", "COLORTERM", "NO_COLOR", "CANGJIE_HOME",
            "CANGJIE_SDK_ROOT", "CANGJIE_STDX_PATH", "JAVA_HOME"
        ])
        allowed.add(all: request.environmentAllowlist)
        if (includeDisplayServer) {
            // Clipboard clients receive only display routing and X11 authority.
            // PATH stays excluded; sandbox4cj pins every host-filesystem command
            // to fixed system directories after filtering.
            allowed.add(all: [
                "DISPLAY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "XAUTHORITY"
            ])
        }
        if (sandboxCaBundleValue != "") {
            allowed.add("SSL_CERT_FILE")
            allowed.add("CURL_CA_BUNDLE")
        }
        // EnvironmentFilter requires secret names to be present in both
        // allowlists, keeping an explicit secret grant as the only path to
        // credential injection.
        allowed.add(all: request.secretEnvironmentAllowlist)
        allowed.toArray()
    }
    private func sandboxEnvironment(
        request: ProcessRequest
    ): Array<SandboxEnvironmentEntry> {
        let entries = ArrayList<SandboxEnvironmentEntry>()
        if (sandboxCaBundleValue != "") {
            entries.add(SandboxEnvironmentEntry("SSL_CERT_FILE", sandboxCaBundleValue))
            entries.add(SandboxEnvironmentEntry("CURL_CA_BUNDLE", sandboxCaBundleValue))
        }
        if (request.displayServerAccess) {
            match (displayServerAuthorityPath()) {
                case Some(value) => entries.add(SandboxEnvironmentEntry("XAUTHORITY", value))
                case None => ()
            }
        }
        entries.toArray()
    }

    private func scopedDisplayServerEnvironment(
        request: ProcessRequest
    ): HashMap<String, String> {
        let filtered = EnvironmentFilter(
            allowlist: processEnvironmentAllowlist(request, includeDisplayServer: true),
            allowedSecrets: request.secretEnvironmentAllowlist,
            secretValues: request.redactedValues
        ).filterCurrent()
        let environment = HashMap<String, String>()
        var hasUsablePath = false
        for (entry in filtered.entries) {
            environment[entry.name] = entry.value
            if (entry.name == "PATH" && entry.value.trimAscii() != "") {
                hasUsablePath = true
            }
        }
        if (!hasUsablePath) {
            environment["PATH"] = "/usr/local/bin:/usr/bin:/bin"
        }
        // Stable defaults keep HOME, TMPDIR, and LANG predictable while the
        // explicitly allowlisted PATH remains available to user-installed tools.
        environment["HOME"] = workspace.rootPath()
        environment["TMPDIR"] = "/tmp"
        environment["LANG"] = "C.UTF-8"
        // HOME stays workspace-scoped; expose only the X11 authority path.
        match (displayServerAuthorityPath()) {
            case Some(value) => environment["XAUTHORITY"] = value
            case None => ()
        }
        environment
    }
    private func displayServerAuthorityPath(): ?String {
        match (getVariable("XAUTHORITY")) {
            case Some(value) =>
                if (value.trimAscii() != "" && !value.contains("\u{0000}")) {
                    return Some(value)
                }
            case None => ()
        }
        match (getVariable("HOME")) {
            case Some(value) =>
                let home = value.trimAscii()
                if (home != "" && !home.contains("\u{0000}") && Path(home).isAbsolute()) {
                    Some(Path(home).join(".Xauthority").normalize().toString())
                } else {
                    None
                }
            case None => None
        }
    }
    private func readOnlyMountedWorkingDirectory(
        authored: String,
        mounts: Array<String>
    ): ?String {
        if (!Path(authored).isAbsolute()) { return None }
        try {
            let resolved = canonicalize(Path(authored)).toString()
            for (authoredMount in mounts) {
                let mount = SandboxReadOnlyMount(authoredMount)
                if (resolved == mount.resolvedPath ||
                    resolved.startsWith(mount.resolvedPath + "/")) {
                    return Some(resolved)
                }
            }
        } catch (_: Exception) {}
        None
    }

    private func processSandbox(
        request: ProcessRequest,
        filesystem: FilesystemIsolationMode,
        networkLease!: ?NetworkGatewayLease = None,
        strictChannel!: Bool = false
    ): WorkspaceSandbox {
        let filesystemRoot = if (request.sandboxMode == ProcessSandboxMode.IsolatedReadOnly) {
            canonicalize(Path(request.filesystemRoot)).toString()
        } else {
            workspace.rootPath()
        }
        let allowed = if (strictChannel) {
            let names = ArrayList<String>()
            names.add(all: request.environmentAllowlist)
            if (!networkPolicyModeIsDenied(request.networkPolicy.mode) && sandboxCaBundleValue != "") {
                names.add(all: ["SSL_CERT_FILE", "CURL_CA_BUNDLE"])
            }
            names.toArray()
        } else { processEnvironmentAllowlist(request, includeDisplayServer: request.displayServerAccess) }
        let mounts = ArrayList<SandboxReadOnlyMount>()
        if (!strictChannel) {
            for (mount in sandboxReadOnlyMountsValue) { mounts.add(mount) }
        }
        for (authored in request.readOnlyMounts) {
            let mount = SandboxReadOnlyMount(authored)
            if (!processRootsOverlap(filesystemRoot, mount.resolvedPath)) {
                var duplicate = false
                for (existing in mounts where existing.path == mount.path) { duplicate = true }
                if (!duplicate) { mounts.add(mount) }
            }
        }
        if (!strictChannel || !networkPolicyModeIsDenied(request.networkPolicy.mode)) {
            match (sandboxCaBundleMountValue) {
                case Some(caMount) =>
                    var duplicate = false
                    for (existing in mounts where existing.path == caMount.path) { duplicate = true }
                    if (!duplicate) { mounts.add(caMount) }
                case None => ()
            }
        }
        match (networkLease) {
            case Some(value) =>
                mounts.add(SandboxReadOnlyMount(value.bridgeExecutable))
                mounts.add(SandboxReadOnlyMount(Path(value.bridgeSocket).parent.toString()))
            case None => ()
        }
        if (request.displayServerAccess) {
            // Mount only the selected display socket tree and authority file read-only.
            // Do not expose the rest of host HOME or display state.
            match (getVariable("XDG_RUNTIME_DIR")) {
                case Some(value) =>
                    let runtimePath = value.trimAscii()
                    if (runtimePath != "") {
                        try {
                            let runtimeMount = SandboxReadOnlyMount(runtimePath)
                            var duplicate = false
                            for (existing in mounts where existing.path == runtimeMount.path) {
                                duplicate = true
                            }
                            if (!duplicate) {
                                mounts.add(runtimeMount)
                            }
                        } catch (_: Exception) {}
                    }
                case None => ()
            }
            match (displayServerAuthorityPath()) {
                case Some(authorityPath) =>
                    if (Path(authorityPath).isAbsolute() && exists(Path(authorityPath))) {
                        try {
                            let authorityMount = SandboxReadOnlyMount(authorityPath)
                            var duplicate = false
                            for (existing in mounts where existing.path == authorityMount.path) {
                                duplicate = true
                            }
                            if (!duplicate) { mounts.add(authorityMount) }
                        } catch (_: Exception) {}
                    }
                case None => ()
            }
        }
        WorkspaceSandbox(WorkspaceSandboxPolicy(
            filesystemRoot,
            filesystem: filesystem,
            process: ProcessIsolationMode.Isolated,
            network: match (request.networkPolicy.mode) {
                case NetworkPolicyMode.HostNetwork => NetworkIsolationMode.Allowed
                case NetworkPolicyMode.Mediated => NetworkIsolationMode.Mediated
                case NetworkPolicyMode.Denied => NetworkIsolationMode.Denied
            },
            environment: EnvironmentFilter(
                allowlist: allowed,
                allowedSecrets: request.secretEnvironmentAllowlist,
                secretValues: request.redactedValues
            ),
            resources: hostEffectiveProcessResources(
                sandboxResourcesValue, request.processLimits
            ),
            readOnlyMounts: mounts.toArray(),
            pathEntries: if (strictChannel) { [] } else { sandboxPathEntriesValue }
        ))
    }
    private func processRootsOverlap(first: String, second: String): Bool {
        first == second || first.startsWith(second + "/") || second.startsWith(first + "/")
    }







    // Caller holds activeLock; ModelAttempt cancellation uses its real token,
    // never the legacy Operation reservation table.
    private func resourceReservedCancelled(owner: ProcessResourceOwner): Bool {
        match (owner) { case ProcessResourceOwner.Operation(id) => hookCancelledLocked159h(id) ?? (reserved.get(id.value) ?? false)
            case ProcessResourceOwner.ModelAttempt(_, _) => false }
    }

    public func cancelResource(owner: ProcessResourceOwner): Result<Unit> {
        match (owner) { case ProcessResourceOwner.Operation(id) => cancel(id)
            case ProcessResourceOwner.ModelAttempt(_, _) => closeChannelResource(owner) }
    }

    public func hasActiveResource(resourceOwner: ProcessResourceOwner): Bool {
        activeLock.lock()
        try {
            match (resourceOwner.operation) { case Some(id) => if (hookActiveLocked159h(id)) { return true }; case None => () }
            for (owner in channelOwners where owner.resourceOwner.key == resourceOwner.key) { return true }
            for (item in active where ProcessResourceOwner.Operation(item.operationId).key == resourceOwner.key) { return true }
            false
        } finally { activeLock.unlock() }
    }

    public func reserveOperation(operationId: OperationId): Unit {
        activeLock.lock()
        try { reserved[operationId.value] = false } finally { activeLock.unlock() }
    }

    public func releaseOperation(operationId: OperationId): Unit {
        if (releaseHookOperation159h(operationId)) { return }
        activeLock.lock()
        try { reserved.remove(operationId.value) } finally { activeLock.unlock() }
    }

    public func reservedOperationCancelled(operationId: OperationId): Bool {
        activeLock.lock()
        try { hookCancelledLocked159h(operationId) ?? (reserved.get(operationId.value) ?? false) } finally { activeLock.unlock() }
    }

    public func cancel(operationId: OperationId): Result<Unit> {
        if (cancelHookOperation159h(operationId)) { return Result.Ok(()) }
        var wasReserved = false
        var selected: ?HostActiveNativeProcess = None
        var channelOwner: ?HostNativeProcessChannelOwner = None
        var channel: ?ProcessChannel = None
        activeLock.lock()
        try {
            wasReserved = reserved.contains(operationId.value)
            if (wasReserved) { reserved[operationId.value] = true }
            for (owner in channelOwners where owner.resourceOwner.key == ProcessResourceOwner.Operation(operationId).key) {
                owner.cancelled = true
                channelOwner = Some(owner)
                channel = owner.channel
                wasReserved = true
                break
            }
            for (index in 0..active.size) {
                if (active[index].operationId.value == operationId.value) {
                    selected = Some(active[index])
                    // Keep ownership until execute() reaches finish(), so a
                    // later close() can still enforce termination.
                    break
                }
            }
        } finally {
            activeLock.unlock()
        }
        match (channelOwner) {
            case Some(owner) => let _ = owner.cancellation.cancel()
            case None => ()
        }
        match (channel) {
            case Some(value) =>
                let _ = value.abort()
                // close starts bounded, retained cleanup and never refunds a
                // still-running channel's reservation.
                return value.close()
            case None => ()
        }
        match (selected) {
            case Some(item) =>
                try {
                    item.terminateOwned()
                } catch (_: Exception) {}
                Result.Ok(())
            case None =>
                if (wasReserved) {
                    Result.Ok(())
                } else {
                    Result.Err(
                        AgentError(
                            AgentErrorKind.InvalidInput,
                            "process.operation_not_running",
                            "process operation is not running",
                            fields: [
                                ErrorField(
                                    "operation_id",
                                    operationId.value
                                )
                            ]
                        )
                    )
                }
        }
    }

    public func hasActiveOperation(operationId: OperationId): Bool {
        activeLock.lock()
        try {
            if (hookActiveLocked159h(operationId)) { return true }
            for (owner in channelOwners where owner.resourceOwner.key == ProcessResourceOwner.Operation(operationId).key) { return true }
            for (item in active where
                item.operationId.value == operationId.value) {
                return true
            }
            false
        } finally {
            activeLock.unlock()
        }
    }

    private func register(
        operationId: OperationId,
        process: SubProcess
    ): Unit {
        registerActive(HostActiveNativeProcess(operationId, process))
    }

    private func register(
        operationId: OperationId,
        process: ManagedProcess
    ): Unit {
        if (registerHookProcess159h(operationId, process)) { return }
        registerActive(HostActiveNativeProcess(operationId, process))
    }

    private func registerActive(entry: HostActiveNativeProcess): Unit {
        var terminate = false
        activeLock.lock()
        try {
            active.add(entry)
            terminate = reserved.get(entry.operationId.value) ?? false
        } finally {
            activeLock.unlock()
        }
        if (terminate) {
            try {
                entry.terminateOwned()
            } catch (_: Exception) {}
        }
    }

    private func finish(operationId: OperationId): Unit {
        if (finishHookOperation159h(operationId)) { return }
        activeLock.lock()
        try {
            for (index in 0..active.size) {
                if (active[index].operationId.value == operationId.value) {
                    active.remove(at: index)
                    return
                }
            }
        } finally {
            activeLock.unlock()
        }
    }













    // Opt-in DATA reservation for the concrete hook caller. The original
    // Native bank funds the node, wrapper and independent identity copy.
    // The ordinary ProcessPort reservation table remains unchanged.
    public func reserveHookOperation159h(operationId: OperationId): Unit {
        let bytes = operationId.value.size
        if (bytes < 0 || bytes > (134217728 - 65536) / 64) {
            throw LogicalJsonPayloadError("hook process identity exceeds original aggregate")
        }
        let paid = reserveNativeControlMetadata(65536 + bytes * 64)
        installHookOperationFrame159h(operationId, paid)
    }
    private func installHookOperationFrame159h(operationId: OperationId,
        paid: LogicalJsonOwnerReservation): Unit {
        activeLock.lock()
        try {
            // Refusal happens before any input copy or carrier captures paid.
            var duplicate = reserved.contains(operationId.value) || findHookEntryLocked159h(operationId).isSome()
            for (item in active where item.operationId.value == operationId.value) { duplicate = true }
            for (owner in channelOwners where owner.resourceOwner.key == ProcessResourceOwner.Operation(operationId).key) { duplicate = true }
            if (channelsClosed || duplicate) {
                paid.close()
                throw IllegalStateException("hook process reservation is unavailable")
            }
            let entry = HostHookProcessEntry159h(paid)
            entry.next159h = hookEntries159h; hookEntries159h = Some(entry)
            entry.installIdentity159h(operationId)
        } finally { activeLock.unlock() }
    }
    // Caller holds activeLock. This reference never leaves a counted private
    // frame except for immediate locked scalar comparisons.
    private func findHookEntryLocked159h(operationId: OperationId): ?HostHookProcessEntry159h {
        var cursor = hookEntries159h
        while (cursor.isSome()) {
            let entry = cursor.getOrThrow()
            if (entry.matches159h(operationId)) { return Some(entry) }
            cursor = entry.next159h
        }
        None<HostHookProcessEntry159h>
    }
    private func hookCancelledLocked159h(operationId: OperationId): ?Bool {
        match (findHookEntryLocked159h(operationId)) {
            case Some(entry) => if (entry.reserved159h) { Some(entry.cancelled159h) } else { None<Bool> }
            case None => None<Bool>
        }
    }
    private func hookActiveLocked159h(operationId: OperationId): Bool {
        match (findHookEntryLocked159h(operationId)) {
            case Some(entry) => !entry.finished159h && entry.process159h.isSome()
            case None => false
        }
    }
    private func beginHookFrame159h(): Unit {
        activeLock.lock(); try { hookFrames159h += 1 } finally { activeLock.unlock() }
    }
    private func endHookFrame159h(): Unit {
        activeLock.lock()
        try {
            if (hookFrames159h <= 0) { throw IllegalStateException("hook process frame underflow") }
            hookFrames159h -= 1
        } finally { activeLock.unlock() }
        collectReturnedHookEntries159h()
    }
    private func collectReturnedHookEntries159h(): Unit {
        while (true) {
            // The complete unlink/clear helper must return first. Its local
            // entry/previous/cursor aliases have then physically left frame.
            let paid = detachReturnedHookEntryFrame159h()
            match (paid) { case Some(value) => value.close(); case None => return }
        }
    }
    private func detachReturnedHookEntryFrame159h(): ?LogicalJsonOwnerReservation {
        activeLock.lock()
        try {
            if (hookFrames159h != 0) { return None<LogicalJsonOwnerReservation> }
            var previous: ?HostHookProcessEntry159h = None<HostHookProcessEntry159h>
            var cursor = hookEntries159h
            while (cursor.isSome()) {
                let entry = cursor.getOrThrow()
                if (!entry.reserved159h && entry.finished159h) {
                    match (previous) {
                        case Some(value) => value.next159h = entry.next159h
                        case None => hookEntries159h = entry.next159h
                    }
                    return entry.clearPrivateFrame159h()
                }
                previous = cursor; cursor = entry.next159h
            }
            None<LogicalJsonOwnerReservation>
        } finally { activeLock.unlock() }
    }
    private func releaseHookOperation159h(operationId: OperationId): Bool {
        let released = releaseHookOperationFrame159h(operationId)
        collectReturnedHookEntries159h()
        released
    }
    private func releaseHookOperationFrame159h(operationId: OperationId): Bool {
        activeLock.lock()
        try {
            match (findHookEntryLocked159h(operationId)) {
                case Some(entry) => entry.reserved159h = false; true
                case None => false
            }
        } finally { activeLock.unlock() }
    }
    private func finishHookOperation159h(operationId: OperationId): Bool {
        let finished = finishHookOperationFrame159h(operationId)
        collectReturnedHookEntries159h()
        finished
    }
    private func finishHookOperationFrame159h(operationId: OperationId): Bool {
        activeLock.lock()
        try {
            match (findHookEntryLocked159h(operationId)) {
                case Some(entry) => entry.finished159h = true; true
                case None => false
            }
        } finally { activeLock.unlock() }
    }
    private func cancelHookOperation159h(operationId: OperationId): Bool {
        beginHookFrame159h()
        try { cancelHookOperationFrame159h(operationId) }
        finally { endHookFrame159h() }
    }
    private func cancelHookOperationFrame159h(operationId: OperationId): Bool {
        var selected: ?HostActiveNativeProcess = None<HostActiveNativeProcess>
        var found = false
        activeLock.lock()
        try {
            match (findHookEntryLocked159h(operationId)) {
                case Some(entry) =>
                    if (entry.reserved159h || !entry.finished159h) {
                        found = true; entry.cancelled159h = true
                        if (!entry.finished159h) { selected = entry.process159h }
                    }
                case None => ()
            }
        } finally { activeLock.unlock() }
        match (selected) {
            case Some(value) => try { value.terminateOwned() } catch (_: Exception) {}
            case None => ()
        }
        found
    }
    private func registerHookProcess159h(operationId: OperationId, process: ManagedProcess): Bool {
        beginHookFrame159h()
        try { registerHookProcessFrame159h(operationId, process) }
        finally { endHookFrame159h() }
    }
    private func registerHookProcessFrame159h(operationId: OperationId, process: ManagedProcess): Bool {
        var selected: ?HostActiveNativeProcess = None<HostActiveNativeProcess>
        var terminate = false
        activeLock.lock()
        try {
            match (findHookEntryLocked159h(operationId)) {
                case Some(entry) =>
                    if (!entry.reserved159h || entry.finished159h || entry.process159h.isSome()) {
                        throw IllegalStateException("hook process registration is unavailable")
                    }
                    // The independent copied identity belongs to the entry;
                    // no caller identity is placed in the kernel registry.
                    let actual = HostActiveNativeProcess(entry.identity159h.getOrThrow(), process)
                    entry.process159h = Some(actual); selected = Some(actual)
                    terminate = entry.cancelled159h || channelsClosed
                case None => return false
            }
        } finally { activeLock.unlock() }
        if (terminate) {
            try { selected.getOrThrow().terminateOwned() } catch (_: Exception) {}
        }
        true
    }
    private func closeHookProcesses159h(): String {
        beginHookFrame159h()
        try { closeHookProcessesFrame159h() }
        finally { endHookFrame159h() }
    }
    private func closeHookProcessesFrame159h(): String {
        var firstError = ""
        var cursor: ?HostHookProcessEntry159h = None<HostHookProcessEntry159h>
        activeLock.lock(); try { cursor = hookEntries159h } finally { activeLock.unlock() }
        while (cursor.isSome()) {
            var selected: ?HostActiveNativeProcess = None<HostActiveNativeProcess>
            activeLock.lock()
            try {
                let entry = cursor.getOrThrow(); entry.cancelled159h = true
                selected = entry.process159h; cursor = entry.next159h
            } finally { activeLock.unlock() }
            // Frame count prevents unlink while this local process is alive.
            // Never execute process cancellation callbacks under activeLock.
            match (selected) {
                case Some(value) => try { value.forceTerminateOwned() }
                    catch (error: Exception) { if (firstError == "") { firstError = error.message } }
                case None => ()
            }
        }
        // Termination is not finish/release. In-flight caller/monitor entries
        // remain owned until both actual paths return and clear their claims.
        firstError
    }

    // Trusted Product composition borrows the one frozen native configuration
    // and registration table. These are raw primitives, never admission ports.
    public func configuredCaBundle(): String { sandboxCaBundleValue }
    public func configuredCaBundleMount(): ?SandboxReadOnlyMount { sandboxCaBundleMountValue }
    public func sandboxForBusinessRequest(request: ProcessRequest,
        filesystem: FilesystemIsolationMode): WorkspaceSandbox {
        processSandbox(request, filesystem)
    }
    public func registerOperationProcess(operationId: OperationId, process: SubProcess): Unit {
        register(operationId, process)
    }
    public func registerOperationProcess(operationId: OperationId, process: ManagedProcess): Unit {
        register(operationId, process)
    }
    public func finishOperationProcess(operationId: OperationId): Unit { finish(operationId) }
}

public func defaultHostProcessSandboxResourceLimits(): SandboxResourceLimits {
    SandboxResourceLimits(
        maxOutputBytes: 16777216,
        addressSpaceBytes: 17179869184,
        fileSizeBytes: 4294967296,
        openFiles: 4096,
        processes: 1024,
        cpuSeconds: 3600
    )
}

public func hostIntersectProcessLimit(host: Int64, requested: Int64): Int64 {
    if (host == 0) {
        requested
    } else if (requested == 0) {
        host
    } else {
        min(host, requested)
    }
}

public func hostEffectiveProcessResources(
    host: SandboxResourceLimits,
    requested: ExecutionResourceLimits
): SandboxResourceLimits {
    SandboxResourceLimits(
        maxOutputBytes: hostIntersectProcessLimit(
            host.maxOutputBytes, requested.maxOutputBytes
        ),
        addressSpaceBytes: hostIntersectProcessLimit(
            host.addressSpaceBytes, requested.addressSpaceBytes
        ),
        fileSizeBytes: hostIntersectProcessLimit(
            host.fileSizeBytes, requested.fileSizeBytes
        ),
        openFiles: hostIntersectProcessLimit(host.openFiles, requested.openFiles),
        processes: hostIntersectProcessLimit(host.processes, requested.processes),
        cpuSeconds: hostIntersectProcessLimit(host.cpuSeconds, requested.cpuSeconds)
    )
}

public func hostSandboxRequired<T>(request: ProcessRequest): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.Configuration,
        "sandbox.required",
        "this process request requires an enabled workspace sandbox",
        fields: [
            ErrorField("process_resource", request.resourceOwner.key),
            ErrorField("executable", request.executable)
        ]
    ))
}

class HostActiveNativeProcess {
    let operationId: OperationId
    let process: ?SubProcess
    let managedProcess: ?ManagedProcess
    let pid: Int64
    let startTime: Int64

    init(operationId: OperationId, process: SubProcess) {
        this.operationId = operationId
        this.process = Some(process)
        this.managedProcess = None
        this.pid = process.pid
        this.startTime = processStartTime(process.pid)
    }

    init(operationId: OperationId, process: ManagedProcess) {
        this.operationId = operationId
        this.process = None
        this.managedProcess = Some(process)
        this.pid = process.pid
        this.startTime = processStartTime(process.pid)
    }

    func leaderMatches(): Bool {
        startTime > 0 && processStartTime(pid) == startTime
    }

    func terminateOwned(): Unit {
        // Cancellation is terminal. A graceful group signal can terminate the
        // current child while allowing its shell to continue with later commands.
        forceTerminateOwned()
        let deadline = MonoTime.now() + Duration.millisecond * 1000
        while (leaderMatches() && ownedIsAlive() && MonoTime.now() < deadline) {
            sleep(Duration.millisecond * 10)
        }
    }

    func forceTerminateOwned(): Unit {
        if (!leaderMatches()) { return }
        match (managedProcess) {
            case Some(value) => let _ = value.terminate(force: true)
            case None => let _ = terminateProcessTree(
                pid,
                expectedStartTime: startTime,
                gracefulMillis: 0
            )
        }
    }

    private func ownedIsAlive(): Bool {
        match (managedProcess) {
            case Some(value) => value.isAlive()
            case None => match (process) {
                case Some(value) => value.isAlive()
                case None => false
            }
        }
    }
}

public func hostNativeTimeoutSeconds(milliseconds: Int64): String {
    let seconds = milliseconds / 1000
    let remainder = milliseconds % 1000
    var fraction = remainder.toString()
    while (fraction.size < 3) {
        fraction = "0" + fraction
    }
    seconds.toString() + "." + fraction
}

class HostInteractiveProcessTerminationState {
    private let lock = Mutex()
    private var timedOutValue = false
    private var cancelledValue = false

    func stop(timedOut!: Bool = false, cancelled!: Bool = false): Unit {
        lock.lock()
        try {
            timedOutValue = timedOutValue || timedOut
            cancelledValue = cancelledValue || cancelled
        } finally { lock.unlock() }
    }

    func timedOut(): Bool {
        lock.lock(); try { timedOutValue } finally { lock.unlock() }
    }

    func cancelled(): Bool {
        lock.lock(); try { cancelledValue } finally { lock.unlock() }
    }
}

public func hostReadInteractiveProgramFrames(
    stdout: InputStream,
    stdin: OutputStream,
    budget: BoundedOutputBudget,
    onFrame: (String) -> Result<?String>,
    abort: () -> Unit
): Result<String> {
    let maximumFrameBytes: Int64 = 1048576
    let buffer = Array<Byte>(4096, repeat: 0)
    let line = ArrayList<Byte>()
    var finalOutput: ?String = None
    try {
        while (true) {
            let count = stdout.read(buffer)
            if (count <= 0) { break }
            for (index in 0..count) {
                if (budget.claim(1) != 1) {
                    abort()
                    return Result.Err(AgentError(
                        AgentErrorKind.Protocol,
                        "process.interactive_output_limit",
                        "interactive process exceeded its aggregate output limit"
                    ))
                }
                let byte = buffer[index]
                if (byte != b'\n') {
                    if (line.size >= maximumFrameBytes) {
                        abort()
                        return Result.Err(AgentError(
                            AgentErrorKind.Protocol,
                            "process.interactive_frame_limit",
                            "interactive process frame exceeded its byte limit"
                        ))
                    }
                    line.add(byte)
                    continue
                }
                if (!line.isEmpty() && line[line.size - 1] == b'\r') {
                    line.remove(at: line.size - 1)
                }
                let frame = try { String.fromUtf8(line.toArray()) } catch (_: Exception) {
                    abort()
                    return Result.Err(AgentError(
                        AgentErrorKind.Protocol,
                        "process.interactive_utf8_invalid",
                        "interactive process emitted an invalid UTF-8 frame"
                    ))
                }
                line.clear()
                if (finalOutput.isSome()) {
                    abort()
                    return Result.Err(AgentError(
                        AgentErrorKind.Protocol,
                        "process.interactive_after_final",
                        "interactive process emitted a frame after its terminal response"
                    ))
                }
                match (onFrame(frame)) {
                    case Result.Err(error) =>
                        abort()
                        return Result.Err(error)
                    case Result.Ok(Some(response)) =>
                        if (response.size > maximumFrameBytes) {
                            abort()
                            return Result.Err(AgentError(
                                AgentErrorKind.Protocol,
                                "process.interactive_response_limit",
                                "interactive response exceeded its byte limit"
                            ))
                        }
                        stdin.write(response.toArray())
                        stdin.write([b'\n'])
                        stdin.flush()
                    case Result.Ok(None) => finalOutput = Some(frame)
                }
            }
        }
        if (!line.isEmpty()) {
            return Result.Err(AgentError(
                AgentErrorKind.Protocol,
                "process.interactive_incomplete_frame",
                "interactive process ended inside a frame"
            ))
        }
        match (finalOutput) {
            case Some(value) => Result.Ok(value)
            case None => Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "process.interactive_final_missing",
                "interactive process exited without a terminal response"
            ))
        }
    } catch (error: Exception) {
        abort()
        Result.Err(AgentError(
            AgentErrorKind.Transport,
            "process.interactive_io",
            error.message
        ))
    }
}

public func hostSandboxAgentError(error: SandboxError): AgentError {
    let kind = match (error.kind) {
        case SandboxErrorKind.Configuration => AgentErrorKind.Configuration
        case SandboxErrorKind.InvalidInput => AgentErrorKind.InvalidInput
        case SandboxErrorKind.PermissionDenied => AgentErrorKind.PermissionDenied
        case SandboxErrorKind.Transport => AgentErrorKind.Transport
        case SandboxErrorKind.Cancelled => AgentErrorKind.Cancelled
        case SandboxErrorKind.Deadline => AgentErrorKind.Timeout
    }
    let fields = ArrayList<ErrorField>()
    for (field in error.fields) { fields.add(ErrorField(field.name, field.value)) }
    AgentError(kind, error.code, error.message, fields: fields.toArray())
}

func hostNativeModelAdmissionDenied<T>(): Result<T> {
    Result.Err(AgentError(AgentErrorKind.PermissionDenied, "model.process_admission_denied",
        "model process resource requires its current, host-held claimed Attempt"))
}
func hostNativeLifecycleGrantMismatch<T>(): Result<T> {
    Result.Err(hostNativeChannelFactoryError(AgentErrorKind.PermissionDenied,
        "process.channel_grant_mismatch", "process lifecycle grant is unavailable"))
}
func hostNativeHttpUnknown<T>(message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "http.outcome_unknown", message,
        retryable: false, fallbackAllowed: false))
}

// Only this private linked entry owns these copied reservation bytes. No
// entry, process wrapper, or copied identity is exported by the hook bridge.
class HostHookProcessEntry159h {
    var payment159h: ?LogicalJsonOwnerReservation
    var identity159h: ?OperationId = None<OperationId>
    var process159h: ?HostActiveNativeProcess = None<HostActiveNativeProcess>
    var next159h: ?HostHookProcessEntry159h = None<HostHookProcessEntry159h>
    var reserved159h = true
    var finished159h = false
    var cancelled159h = false
    init(paid: LogicalJsonOwnerReservation) { payment159h = Some(paid) }
    func matches159h(id: OperationId): Bool {
        match (identity159h) { case Some(value) => value.value == id.value; case None => false }
    }
    func installIdentity159h(id: OperationId): Unit {
        // reserveHookOperation159h paid the complete copy and node before
        // construction; publication precedes this possibly throwing copy.
        identity159h = Some(OperationId(String.fromUtf8(id.value.toArray())))
    }
    func clearPrivateFrame159h(): ?LogicalJsonOwnerReservation {
        identity159h = None<OperationId>
        process159h = None<HostActiveNativeProcess>
        next159h = None<HostHookProcessEntry159h>
        let paid = payment159h; payment159h = None<LogicalJsonOwnerReservation>
        paid
    }
}
