package memory_legacy_oracle

import agent_domain.*
import agent_product.*
import std.collection.*
import std.fs.*
import yjson.*
import yjson_support.*

// A pinned operator choice, not a capability grant or a second registry.
class ProductPolicySelection {
    let namespace: String
    let provider: String
    let digest: String
    let configurationDigest: String
    let planTool: String
    private let settingsRoot: String
    init(settingsRoot: String, value: AgentValue, encoded: String) {
        this.settingsRoot = settingsRoot
        this.namespace = httpIntentText(value, "namespace")
        this.provider = httpIntentText(value, "provider")
        this.digest = httpIntentText(value, "package_digest")
        this.planTool = httpIntentText(value, "plan_tool")
        this.configurationDigest = modelPolicySha256Text(encoded)
    }
    func validateCurrent(): Result<Unit> {
        match (productPolicyConfigText(settingsRoot)) {
            case Result.Ok(value) => if (modelPolicySha256Text(value) == configurationDigest) { Result.Ok(()) }
                else { productPolicySelectionError("policy.configuration_changed") }
            case Result.Err(_) => productPolicySelectionError("policy.configuration_changed")
        }
    }
    // Local immutable-data work needs cancellation/configuration and the
    // exact mounted generation. It does not launch a worker or authorize a
    // consumer. queryProductPluginPolicy still verifies package bytes before
    // and after every actual pure invocation; final consumers use validateBinding.
    func validatePinnedGeneration(host: ProductJavaScriptPluginHost, binding: ProductPluginPolicyBinding): Result<Unit> {
        match (validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (binding.namespace != namespace || binding.contribution != provider || binding.digest != digest) {
            return productPolicySelectionError("policy.provider_changed") }
        let mounted = match (host.servicePackage(namespace, binding.generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        try {
            if (!mounted.textEquals(PluginDescriptorText.Namespace, namespace) ||
                !mounted.textEquals(PluginDescriptorText.ContentDigest, digest)) {
                return productPolicySelectionError("policy.provider_changed") }
            Result.Ok(())
        } finally { mounted.close() }
    }
    func validateBinding(host: ProductJavaScriptPluginHost, binding: ProductPluginPolicyBinding): Result<Unit> {
        match (validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let current = match (host.policyProviderBinding(namespace, provider)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (current.digest != digest || current.generation != binding.generation ||
            binding.namespace != namespace || binding.contribution != provider || binding.digest != digest) {
            return productPolicySelectionError("policy.provider_changed") }
        Result.Ok(())
    }
}

func productPolicyConfigText(settingsRoot: String): Result<String> {
    try {
        let root = canonicalize(Path(settingsRoot))
        let directory = root.join("plugins")
        let path = directory.join("policies.json")
        if (!exists(directory)) { return productPolicySelectionError("policy.not_configured") }
        if (!exists(directory)) { return productPolicySelectionError("policy.not_configured") }
        if (!exists(path)) {
            if (FileInfo(directory).isSymbolicLink()) { return productPolicySelectionError("policy.configuration_invalid") }
            return productPolicySelectionError("policy.not_configured")
        }
        if (FileInfo(directory).isSymbolicLink() || FileInfo(path).isSymbolicLink() ||
            !FileInfo(path).isRegular() || FileInfo(path).size > 65536) {
            return productPolicySelectionError("policy.configuration_invalid") }
        let file = File(path, OpenMode.Read)
        // Bound the actual read as well as stat: a concurrent growth cannot
        // turn this operator configuration into an unbounded allocation.
        let bytes = ArrayList<UInt8>()
        let buffer = Array<UInt8>(4096, repeat: 0)
        try {
            while (true) {
                let count = file.read(buffer)
                if (count == 0) { break }
                if (count < 0 || count > buffer.size || bytes.size + count > 65536) { return productPolicySelectionError("policy.configuration_invalid") }
                bytes.add(all: buffer[..count])
            }
        } finally { file.close() }
        let encoded = String.fromUtf8(bytes.toArray())
        if (encoded.size == 0) { return productPolicySelectionError("policy.configuration_invalid") }
        Result.Ok(encoded)
    } catch (_: Exception) { productPolicySelectionError("policy.configuration_invalid") }
}

func loadProductPolicySelection(settingsRoot: String, key: String): Result<ProductPolicySelection> {
    let encoded = match (productPolicyConfigText(settingsRoot)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    try {
        let value = parseUnifiedJson(encoded, maxBytes: 65536, maxDepth: 8)
        if (!httpIntentExactFields(value, ["version", "bindings"]) ||
            value.field("version").getOrThrow().unifiedKind != ValueKind.Number ||
            value.field("version").getOrThrow().asNumberText() != "1") {
            return productPolicySelectionError("policy.configuration_invalid") }
        let bindings = value.field("bindings").getOrThrow()
        if (bindings.unifiedKind != ValueKind.Object || bindings.fields.size > 32) {
            return productPolicySelectionError("policy.configuration_invalid") }
        // Validate the whole file; a malformed sibling never becomes ignored
        // configuration whose interpretation changes between consumers.
        for (field in bindings.fields) {
            if (field.name == "" || field.name.size > 64 || field.name.contains("\u{0000}")) {
                return productPolicySelectionError("policy.configuration_invalid") }
            let entry = field.value
            let workflowPlan = field.name == "workflow" && entry.field("plan_tool").isSome()
            if (!(if (workflowPlan) { httpIntentExactFields(entry, ["namespace", "provider", "package_digest", "plan_tool"]) }
                else { httpIntentExactFields(entry, ["namespace", "provider", "package_digest"]) })) {
                return productPolicySelectionError("policy.configuration_invalid") }
            if (workflowPlan) {
                let name = entry.field("plan_tool").getOrThrow()
                if (name.unifiedKind != ValueKind.Text || !memoryOracleDocumentLogicalName(name.text)) {
                    return productPolicySelectionError("policy.configuration_invalid") }
            }
            for (name in ["namespace", "provider", "package_digest"]) {
                let text = entry.field(name).getOrThrow()
                if (text.unifiedKind != ValueKind.Text || text.text == "" || text.text.size > 256 || text.text.contains("\u{0000}")) {
                    return productPolicySelectionError("policy.configuration_invalid") }
            }
            let digest = httpIntentText(entry, "package_digest")
            if (digest.size != 71 || !digest.startsWith("sha256:")) { return productPolicySelectionError("policy.configuration_invalid") }
            for (byte in digest[7..].toArray() where !((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) {
                return productPolicySelectionError("policy.configuration_invalid") }
        }
        match (bindings.field(key)) {
            case None => productPolicySelectionError("policy.not_configured")
            case Some(selected) => Result.Ok(ProductPolicySelection(settingsRoot, selected, encoded))
        }
    } catch (_: Exception) { productPolicySelectionError("policy.configuration_invalid") }
}

func productPolicySelectionError<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput, code,
        "the selected installed policy or its pinned configuration is unavailable"))
}
