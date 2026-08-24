package agent_runtime

import std.collection.*
import std.deriving.*
import agent_domain.*

@Derive[Equatable]
public enum RealmKind {
    Host | Thread | Lane | Run | Extension | Invocation
}

public class ComponentScope {
    public let kind: RealmKind
    public let id: String
    public let parent: ?ComponentScope

    public init(kind: RealmKind, id: String, parent!: ?ComponentScope = None) {
        if (id.trimAscii() == "" || !validRealmParent(kind, parent)) {
            throw IllegalArgumentException("Component Realm scope is invalid")
        }
        this.kind = kind
        this.id = id.trimAscii()
        this.parent = parent
    }
}

public class ServiceKey<T> {
    public let name: String
    public let contractVersion: UInt32
    public let expectedScope: RealmKind

    public init(name: String, contractVersion: UInt32, expectedScope: RealmKind) {
        if (name.trimAscii() == "" || contractVersion == 0u32) {
            throw IllegalArgumentException("Service key is invalid")
        }
        this.name = name.trimAscii()
        this.contractVersion = contractVersion
        this.expectedScope = expectedScope
    }
}

public class ServiceLease<T> {
    public let value: T
    public let scope: ComponentScope
    private let releaseFn: () -> Unit
    private var released: Bool = false

    public init(value: T, scope: ComponentScope, releaseFn: () -> Unit) {
        this.value = value
        this.scope = scope
        this.releaseFn = releaseFn
    }

    public func release(): Unit {
        if (!released) {
            released = true
            releaseFn()
        }
    }
}

public interface ServiceProvider<T> {
    func acquire(scope: ComponentScope): Result<ServiceLease<T>>
}

public interface DisposableResource {
    func dispose(): Unit
}

public class ServiceRegistry<T> {
    public let key: ServiceKey<T>
    private var provider: ?ServiceProvider<T> = None
    private var bindingGeneration: UInt64 = 0u64

    public init(key: ServiceKey<T>) { this.key = key }

    public func bind(provider: ServiceProvider<T>): Result<Unit> {
        if (this.provider.isSome()) {
            return compositionError<Unit>(
                "service.already_bound", "Service key already has a provider"
            )
        }
        this.provider = Some(provider)
        bindingGeneration += 1u64
        Result.Ok(())
    }

    public func bindScoped(provider: ServiceProvider<T>): Result<DisposableResource> {
        match (bind(provider)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => Result.Ok(ScopedServiceBinding<T>(
                this, bindingGeneration
            ))
        }
    }

    public func acquire(scope: ComponentScope): Result<ServiceLease<T>> {
        if (scope.kind != key.expectedScope) {
            return compositionError<ServiceLease<T>>(
                "service.scope_mismatch", "Service requested from an illegal Realm"
            )
        }
        match (provider) {
            case Some(value) => value.acquire(scope)
            case None => compositionError<ServiceLease<T>>(
                "service.unbound", "Service key has no provider"
            )
        }
    }

    func releaseBinding(generation: UInt64): Unit {
        if (generation == bindingGeneration) {
            provider = None
            bindingGeneration += 1u64
        }
    }
}

class ScopedServiceBinding<T> <: DisposableResource {
    private let registry: ServiceRegistry<T>
    private let generation: UInt64
    private var disposed: Bool = false

    init(registry: ServiceRegistry<T>, generation: UInt64) {
        this.registry = registry
        this.generation = generation
    }

    public func dispose(): Unit {
        if (!disposed) {
            disposed = true
            registry.releaseBinding(generation)
        }
    }
}

public class ComponentInstanceRef {
    public let instanceId: String
    public let componentId: String
    public let componentVersion: String
    public let generation: Int64
    public let scope: ComponentScope

    public init(
        instanceId: String,
        componentId: String,
        componentVersion: String,
        generation: Int64,
        scope: ComponentScope
    ) {
        if (instanceId.trimAscii() == "" || componentId.trimAscii() == "" ||
            componentVersion.trimAscii() == "" || generation < 1) {
            throw IllegalArgumentException("Component instance reference is invalid")
        }
        this.instanceId = instanceId.trimAscii()
        this.componentId = componentId.trimAscii()
        this.componentVersion = componentVersion.trimAscii()
        this.generation = generation
        this.scope = scope
    }
}

public class ResolvedServiceBinding {
    public let serviceName: String
    public let contractVersion: UInt32
    public let providerInstanceId: String
    public let scope: RealmKind

    public init(
        serviceName: String,
        contractVersion: UInt32,
        providerInstanceId: String,
        scope: RealmKind
    ) {
        if (serviceName.trimAscii() == "" || providerInstanceId.trimAscii() == "" ||
            contractVersion == 0u32) {
            throw IllegalArgumentException("resolved Service binding is invalid")
        }
        this.serviceName = serviceName.trimAscii()
        this.contractVersion = contractVersion
        this.providerInstanceId = providerInstanceId.trimAscii()
        this.scope = scope
    }
}

public class AgentProfile {
    public let id: String
    public let version: String
    public let baseProfile: String
    public let componentInstances: Array<ComponentInstanceRef>
    public let serviceBindings: Array<ResolvedServiceBinding>
    public let modelRoles: AgentValue
    public let toolVisibility: AgentValue
    public let capabilityCeiling: CapabilitySet
    public let contextPolicy: AgentValue
    public let compactionPolicy: AgentValue
    public let skillSources: Array<String>

    public init(
        id: String,
        version: String,
        componentInstances: Array<ComponentInstanceRef>,
        serviceBindings: Array<ResolvedServiceBinding>,
        modelRoles: AgentValue,
        toolVisibility: AgentValue,
        capabilityCeiling: CapabilitySet,
        contextPolicy: AgentValue,
        compactionPolicy: AgentValue,
        skillSources: Array<String>,
        baseProfile!: String = ""
    ) {
        if (id.trimAscii() == "" || version.trimAscii() == "" ||
            modelRoles.kind != ValueKind.Object || toolVisibility.kind != ValueKind.Object ||
            contextPolicy.kind != ValueKind.Object || compactionPolicy.kind != ValueKind.Object ||
            !uniqueComponentInstances(componentInstances) ||
            !uniqueServiceBindings(serviceBindings)) {
            throw IllegalArgumentException("Agent Profile is invalid")
        }
        this.id = id.trimAscii()
        this.version = version.trimAscii()
        this.baseProfile = baseProfile.trimAscii()
        this.componentInstances = componentInstances
        this.serviceBindings = serviceBindings
        this.modelRoles = modelRoles
        this.toolVisibility = toolVisibility
        this.capabilityCeiling = capabilityCeiling
        this.contextPolicy = contextPolicy
        this.compactionPolicy = compactionPolicy
        this.skillSources = skillSources
    }
}

public class ResolvedAgentCompositionSnapshot {
    public let id: CompositionSnapshotId
    public let profileId: String
    public let profileVersion: String
    public let componentInstances: Array<ComponentInstanceRef>
    public let serviceBindings: Array<ResolvedServiceBinding>
    public let capabilityCeiling: CapabilitySet
    public let toolVisibilityDigest: String
    public let promptGraphDigest: String
    public let resolverVersion: UInt32
    public let digest: String

    public init(
        id: CompositionSnapshotId,
        profileId: String,
        profileVersion: String,
        componentInstances: Array<ComponentInstanceRef>,
        serviceBindings: Array<ResolvedServiceBinding>,
        capabilityCeiling: CapabilitySet,
        toolVisibilityDigest: String,
        promptGraphDigest: String,
        resolverVersion: UInt32,
        digest!: String = ""
    ) {
        if (profileId.trimAscii() == "" || profileVersion.trimAscii() == "" ||
            toolVisibilityDigest.trimAscii() == "" || promptGraphDigest.trimAscii() == "" ||
            resolverVersion == 0u32 || !uniqueComponentInstances(componentInstances) ||
            !uniqueServiceBindings(serviceBindings) || (digest != "" && digest.size != 64)) {
            throw IllegalArgumentException("resolved Agent composition is invalid")
        }
        this.id = id
        this.profileId = profileId.trimAscii()
        this.profileVersion = profileVersion.trimAscii()
        this.componentInstances = componentInstances
        this.serviceBindings = serviceBindings
        this.capabilityCeiling = capabilityCeiling
        this.toolVisibilityDigest = toolVisibilityDigest.trimAscii()
        this.promptGraphDigest = promptGraphDigest.trimAscii()
        this.resolverVersion = resolverVersion
        this.digest = digest
    }

    public func isSealed(): Bool {
        digest.size == 64 && digest == compositionDigest(this)
    }
}

public class CompositionResolver {
    public let version: UInt32
    public init(version!: UInt32 = 1u32) {
        if (version == 0u32) { throw IllegalArgumentException("resolver version is invalid") }
        this.version = version
    }

    public func resolve(
        id: CompositionSnapshotId,
        profile: AgentProfile,
        toolVisibilityDigest: String,
        promptGraphDigest: String
    ): ResolvedAgentCompositionSnapshot {
        let base = ResolvedAgentCompositionSnapshot(
            id, profile.id, profile.version, profile.componentInstances,
            profile.serviceBindings, profile.capabilityCeiling,
            toolVisibilityDigest, promptGraphDigest, version
        )
        copyComposition(base, compositionDigest(base))
    }
}

public class EffectRegistration <: DisposableResource {
    public let id: String
    private let disposeFn: () -> Unit
    private var disposed: Bool = false

    public init(id: String, disposeFn: () -> Unit) {
        if (id.trimAscii() == "") {
            throw IllegalArgumentException("effect registration id must not be empty")
        }
        this.id = id.trimAscii()
        this.disposeFn = disposeFn
    }

    public func dispose(): Unit {
        if (!disposed) {
            disposed = true
            disposeFn()
        }
    }
}

class DeferredDisposal <: DisposableResource {
    private let action: () -> Unit
    private var disposed: Bool = false
    init(action: () -> Unit) { this.action = action }
    public func dispose(): Unit {
        if (!disposed) { disposed = true; action() }
    }
}

public class EffectScope {
    public let owner: ComponentInstanceRef
    private let resources = ArrayList<DisposableResource>()
    private let prompts = ArrayList<PromptContribution>()
    private let tools = ArrayList<String>()
    private let hooks = ArrayList<String>()
    private let skills = ArrayList<String>()
    private var admitting: Bool = true

    public init(owner: ComponentInstanceRef) { this.owner = owner }

    public func registerPrompt(value: PromptContribution): Result<Unit> {
        if (!admitting) { return compositionError<Unit>("effect_scope.closed", "EffectScope stopped admission") }
        prompts.add(value)
        Result.Ok(())
    }

    public func provideService<T>(
        registry: ServiceRegistry<T>,
        provider: ServiceProvider<T>
    ): Result<Unit> {
        if (!admitting) {
            return compositionError<Unit>(
                "effect_scope.closed", "EffectScope stopped admission"
            )
        }
        match (registry.bindScoped(provider)) {
            case Result.Ok(binding) =>
                resources.add(binding)
                Result.Ok(())
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func registerTool(value: EffectRegistration): Result<Unit> {
        registerEffect(value, tools)
    }

    public func registerHook(value: EffectRegistration): Result<Unit> {
        registerEffect(value, hooks)
    }

    public func registerSkill(value: EffectRegistration): Result<Unit> {
        registerEffect(value, skills)
    }

    public func ownResource(value: DisposableResource): Result<Unit> {
        if (!admitting) { return compositionError<Unit>("effect_scope.closed", "EffectScope stopped admission") }
        resources.add(value)
        Result.Ok(())
    }

    public func ownTask(value: DisposableResource): Result<Unit> {
        ownResource(value)
    }

    public func ownProcess(value: DisposableResource): Result<Unit> {
        ownResource(value)
    }

    public func deferDispose(action: () -> Unit): Result<Unit> {
        ownResource(DeferredDisposal(action))
    }

    public func stopAdmitting(): Unit { admitting = false }

    public func dispose(): Unit {
        admitting = false
        var index = resources.size
        while (index > 0) {
            index -= 1
            resources[index].dispose()
        }
        resources.clear()
        prompts.clear()
        tools.clear()
        hooks.clear()
        skills.clear()
    }

    public func promptContributions(): Array<PromptContribution> { prompts.toArray() }
    public func toolContributions(): Array<String> { tools.toArray() }
    public func hookContributions(): Array<String> { hooks.toArray() }
    public func skillContributions(): Array<String> { skills.toArray() }

    private func registerEffect(
        value: EffectRegistration,
        ids: ArrayList<String>
    ): Result<Unit> {
        if (!admitting) {
            return compositionError<Unit>(
                "effect_scope.closed", "EffectScope stopped admission"
            )
        }
        if (ids.contains(value.id)) {
            return compositionError<Unit>(
                "effect_scope.duplicate", "Effect contribution id is already registered"
            )
        }
        ids.add(value.id)
        resources.add(value)
        Result.Ok(())
    }
}

public func compositionDigest(value: ResolvedAgentCompositionSnapshot): String {
    var source = "composition-v1" + compositionFrame(value.id.value) +
        compositionFrame(value.profileId) + compositionFrame(value.profileVersion) +
        compositionFrame(value.toolVisibilityDigest) + compositionFrame(value.promptGraphDigest) +
        compositionFrame(value.resolverVersion.toString())
    for (item in value.componentInstances) {
        source += compositionFrame(item.instanceId) + compositionFrame(item.componentId) +
            compositionFrame(item.componentVersion) + compositionFrame(item.generation.toString()) +
            compositionFrame(realmName(item.scope.kind)) + compositionFrame(item.scope.id)
    }
    for (item in value.serviceBindings) {
        source += compositionFrame(item.serviceName) +
            compositionFrame(item.contractVersion.toString()) +
            compositionFrame(item.providerInstanceId) + compositionFrame(realmName(item.scope))
    }
    for (capability in value.capabilityCeiling.values) {
        source += compositionFrame(compositionCapabilityName(capability.kind)) +
            compositionFrame(capability.resource)
    }
    modelPolicySha256Text(source)
}

func copyComposition(
    value: ResolvedAgentCompositionSnapshot,
    digest: String
): ResolvedAgentCompositionSnapshot {
    ResolvedAgentCompositionSnapshot(
        value.id, value.profileId, value.profileVersion, value.componentInstances,
        value.serviceBindings, value.capabilityCeiling, value.toolVisibilityDigest,
        value.promptGraphDigest, value.resolverVersion, digest: digest
    )
}

func validRealmParent(kind: RealmKind, parent: ?ComponentScope): Bool {
    match ((kind, parent)) {
        case (RealmKind.Host, None) => true
        case (RealmKind.Thread, Some(value)) => value.kind == RealmKind.Host
        case (RealmKind.Lane, Some(value)) => value.kind == RealmKind.Thread
        case (RealmKind.Run, Some(value)) => value.kind == RealmKind.Lane
        case (RealmKind.Extension, Some(value)) => value.kind == RealmKind.Host || value.kind == RealmKind.Thread
        case (RealmKind.Invocation, Some(value)) => value.kind == RealmKind.Run || value.kind == RealmKind.Extension
        case _ => false
    }
}

func uniqueComponentInstances(values: Array<ComponentInstanceRef>): Bool {
    for (index in 0..values.size) {
        for (other in index + 1..values.size where
            values[index].instanceId == values[other].instanceId) { return false }
    }
    true
}

func uniqueServiceBindings(values: Array<ResolvedServiceBinding>): Bool {
    for (index in 0..values.size) {
        for (other in index + 1..values.size where
            values[index].serviceName == values[other].serviceName &&
            values[index].contractVersion == values[other].contractVersion) { return false }
    }
    true
}

func realmName(value: RealmKind): String {
    match (value) {
        case RealmKind.Host => "host"
        case RealmKind.Thread => "thread"
        case RealmKind.Lane => "lane"
        case RealmKind.Run => "run"
        case RealmKind.Extension => "extension"
        case RealmKind.Invocation => "invocation"
    }
}

func compositionCapabilityName(value: CapabilityKind): String {
    match (value) {
        case CapabilityKind.WorkspaceRead => "workspace_read"
        case CapabilityKind.WorkspaceWrite => "workspace_write"
        case CapabilityKind.ProcessSpawn => "process_spawn"
        case CapabilityKind.PeerMessage => "peer_message"
        case CapabilityKind.NetworkAccess => "network_access"
        case CapabilityKind.Delegate => "delegate"
        case CapabilityKind.ExtensionInvoke => "extension_invoke"
    }
}

func compositionFrame(value: String): String { value.toArray().size.toString() + ":" + value }

func compositionError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput, code, message))
}
