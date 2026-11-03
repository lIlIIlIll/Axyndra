package agent_extension_runtime

import std.collection.*
import std.deriving.*

@Derive[Equatable]
public enum ExtensionExecutionKind {
    BuiltIn | TrustedNative | ProcessPlugin | WasmComponent | Mcp | Skill
}

public class SignedExtensionPackageManifest {
    public let id: String
    public let version: String
    public let sdkRange: String
    public let protocolRange: String
    public let entrypoint: String
    public let contributions: Array<String>
    public let requiredServices: Array<String>
    public let requestedCapabilities: Array<String>
    public let stateSchemaVersion: UInt32
    public let recoveryCompatibility: String
    public let contentDigest: String
    public let signature: String

    public init(
        id: String,
        version: String,
        sdkRange: String,
        protocolRange: String,
        entrypoint: String,
        contributions: Array<String>,
        requiredServices: Array<String>,
        requestedCapabilities: Array<String>,
        stateSchemaVersion: UInt32,
        recoveryCompatibility: String,
        contentDigest: String,
        signature: String
    ) {
        this.id = id.trimAscii()
        this.version = version.trimAscii()
        this.sdkRange = sdkRange.trimAscii()
        this.protocolRange = protocolRange.trimAscii()
        this.entrypoint = entrypoint.trimAscii()
        this.contributions = contributions
        this.requiredServices = requiredServices
        this.requestedCapabilities = requestedCapabilities
        this.stateSchemaVersion = stateSchemaVersion
        this.recoveryCompatibility = recoveryCompatibility.trimAscii()
        this.contentDigest = contentDigest.trimAscii()
        this.signature = signature.trimAscii()
    }
}

public interface ExtensionPackageSignatureVerifier {
    func verify(manifest: SignedExtensionPackageManifest): Bool
}

public enum SafeLifecycleResult<T> {
    Ok(T) | Err(String)

    public func isOk(): Bool {
        match (this) { case Ok(_) => true; case Err(_) => false }
    }
}

public class IsolatedPluginLaunchRequest {
    public let manifest: SignedExtensionPackageManifest
    public let executionKind: ExtensionExecutionKind
    public let generation: UInt64
    public let grantedCapabilities: Array<String>
    public let packageRoot: String
    public let ambientAuthority: Bool

    init(
        manifest: SignedExtensionPackageManifest,
        executionKind: ExtensionExecutionKind,
        generation: UInt64,
        grantedCapabilities: Array<String>,
        packageRoot!: String = ""
    ) {
        this.manifest = manifest
        this.executionKind = executionKind
        this.generation = generation
        this.grantedCapabilities = grantedCapabilities
        this.packageRoot = packageRoot.trimAscii()
        // Process and WASM plugins receive only explicit host capabilities.
        this.ambientAuthority = false
    }
}

public func validateIsolatedPluginPackage(
    manifest: SignedExtensionPackageManifest,
    executionKind: ExtensionExecutionKind,
    generation: UInt64,
    capabilityCeiling: Array<String>,
    verifier: ExtensionPackageSignatureVerifier,
    packageRoot!: String = ""
): SafeLifecycleResult<IsolatedPluginLaunchRequest> {
    if (executionKind != ExtensionExecutionKind.ProcessPlugin &&
        executionKind != ExtensionExecutionKind.WasmComponent) {
        return SafeLifecycleResult.Err("only process and WASM plugins use the isolated plugin host")
    }
    if (generation == 0u64 || manifest.id.isEmpty() || manifest.version.isEmpty() ||
        manifest.entrypoint.isEmpty() || manifest.contentDigest.isEmpty() ||
        manifest.signature.isEmpty()) {
        return SafeLifecycleResult.Err("isolated plugin manifest is incomplete")
    }
    if (!validIsolatedPluginEntrypoint(manifest.entrypoint)) {
        return SafeLifecycleResult.Err(
            "isolated plugin entrypoint must be a package-relative path"
        )
    }
    for (capability in manifest.requestedCapabilities) {
        if (!capabilityCeiling.contains(capability)) {
            return SafeLifecycleResult.Err("requested capability exceeds the profile ceiling: ${capability}")
        }
    }
    if (!verifier.verify(manifest)) {
        return SafeLifecycleResult.Err("extension package signature verification failed")
    }
    SafeLifecycleResult.Ok(IsolatedPluginLaunchRequest(
        manifest, executionKind, generation, manifest.requestedCapabilities,
        packageRoot: packageRoot
    ))
}

func validIsolatedPluginEntrypoint(value: String): Bool {
    if (value.startsWith("/") || value.contains("\\") || value.contains("\u{0000}") ||
        value.contains(":")) {
        return false
    }
    let parts = value.split("/")
    if (parts.isEmpty()) { return false }
    for (part in parts where part == "" || part == "." || part == "..") {
        return false
    }
    true
}

public class ExtensionGenerationDiagnostic {
    public let extensionId: String
    public let generation: UInt64
    public let state: ExtensionLifecycleState
    public let inFlight: UInt64
    public let accepting: Bool
    public let error: String

    public init(extensionId: String, generation: UInt64, state: ExtensionLifecycleState, inFlight: UInt64, accepting: Bool, error!: String = "") {
        this.extensionId = extensionId
        this.generation = generation
        this.state = state
        this.inFlight = inFlight
        this.accepting = accepting
        this.error = error
    }
}
