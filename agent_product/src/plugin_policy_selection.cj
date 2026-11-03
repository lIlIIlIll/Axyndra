package agent_product

import agent_plugin_registry.*

import agent_domain.*
import agent_host_runtime.HostCanonicalProjectionSelection173
import agent_host_runtime.HostOwnedCanonicalProjectionSelection186
import agent_host_runtime.{HostPolicyScalarResult193, hostQueryPluginPolicyScalars193}
import std.collection.*
import std.fs.*
import yjson.*
import yjson_support.*

// A pinned operator choice, not a capability grant or a second registry.
class ProductPolicySelection {
    private var namespaceValue186: String
    prop namespace: String { get() { match (owned186) { case Some(value) => value.namespace; case None => namespaceValue186 } } }
    private var providerValue186: String
    prop provider: String { get() { match (owned186) { case Some(value) => value.provider; case None => providerValue186 } } }
    private var digestValue186: String
    prop digest: String { get() { match (owned186) { case Some(value) => value.packageDigest; case None => digestValue186 } } }
    private var configurationDigestValue186: String
    prop configurationDigest: String { get() { match (owned186) { case Some(value) => value.configurationDigest; case None => configurationDigestValue186 } } }
    private var planToolValue186: String
    prop planTool: String { get() { planToolValue186 } }
    private var settingsRootValue186: String
    private let canonicalSelection173: ?HostCanonicalProjectionSelection173
    private var ownedReturned186 = false
    private var owned186: ?HostOwnedCanonicalProjectionSelection186 = None<HostOwnedCanonicalProjectionSelection186>
    private var metadataPayment186: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    init(selection: HostOwnedCanonicalProjectionSelection186, payment: LogicalJsonOwnerReservation) {
        this.settingsRootValue186 = ""
        this.canonicalSelection173 = None<HostCanonicalProjectionSelection173>
        this.owned186 = Some(selection); this.metadataPayment186 = Some(payment)
        // Owned production uses closed Host operations; raw properties remain
        // explicit independently paid compatibility exports when requested.
        this.namespaceValue186 = ""; this.providerValue186 = ""; this.digestValue186 = ""
        this.planToolValue186 = ""; this.configurationDigestValue186 = ""
    }
    func hasOwnedPolicy193(): Bool { owned186.isSome() }
    func policyBinding193(host: ProductJavaScriptPluginHost): Result<ProductPluginPolicyBinding> {
        match (owned186) {
            case Some(value) => match (value.policyGeneration193(host)) {
                case Result.Err(error) => Result.Err(error)
                // Private Product transport of a checked generation only.
                // No empty text is used as an authority or persisted identity.
                case Result.Ok(generation) => Result.Ok(ProductPluginPolicyBinding("", "", "", generation)) }
            case None => host.policyProviderBinding(namespaceValue186, providerValue186)
        }
    }
    func consumeCurrent193(host: ProductJavaScriptPluginHost, binding: ProductPluginPolicyBinding,
        action: () -> Result<Unit>): Result<Unit> {
        match (owned186) {
            case Some(value) => value.consumeCurrentPolicy193(host, binding.generation, action)
            case None => host.withCurrentPolicyData(binding.namespace, binding.contribution, binding.generation, binding.digest, action)
        }
    }
    func queryPolicy193(host: ProductJavaScriptPluginHost, input: AgentValue, thread: ThreadId,
        token: CancellationToken, requestId: String, provenance: ?String): Result<HostPolicyScalarResult193> {
        match (owned186) {
            case Some(value) => value.queryPolicy193(host, input, thread, token, requestId, provenance)
            case None =>
                if (provenance.isSome()) { throw IllegalStateException("raw policy cannot request private owned provenance") }
                hostQueryPluginPolicyScalars193(host, namespaceValue186, providerValue186, digestValue186, input, thread, token, requestId)
        }
    }
    func returnOwnedPolicy186(): Unit {
        let actual = takeOwnedPolicyFrame186()
        // The full query/Store/callback frame and this clearing helper returned.
        match (actual[0]) { case Some(value) => value.returnOwnedConfiguration186(); case None => () }
        match (actual[1]) { case Some(value) => value.close(); case None => () }
    }
    private func takeOwnedPolicyFrame186(): (?HostOwnedCanonicalProjectionSelection186, ?LogicalJsonOwnerReservation) {
        if (owned186.isNone()) { return (None<HostOwnedCanonicalProjectionSelection186>, None<LogicalJsonOwnerReservation>) }
        ownedReturned186 = true
        namespaceValue186 = ""; providerValue186 = ""; digestValue186 = ""
        configurationDigestValue186 = ""; planToolValue186 = ""; settingsRootValue186 = ""
        let actual = owned186; owned186 = None<HostOwnedCanonicalProjectionSelection186>
        let paid = metadataPayment186; metadataPayment186 = None<LogicalJsonOwnerReservation>
        (actual, paid)
    }
    init(settingsRoot: String, value: AgentValue, encoded: String) {
        this.settingsRootValue186 = settingsRoot
        this.canonicalSelection173 = None<HostCanonicalProjectionSelection173>
        this.namespaceValue186 = httpIntentText(value, "namespace")
        this.providerValue186 = httpIntentText(value, "provider")
        this.digestValue186 = httpIntentText(value, "package_digest")
        this.planToolValue186 = httpIntentText(value, "plan_tool")
        this.configurationDigestValue186 = modelPolicySha256Text(encoded)
    }
    init(selection: HostCanonicalProjectionSelection173) {
        this.settingsRootValue186 = ""
        this.canonicalSelection173 = Some(selection)
        this.namespaceValue186 = selection.namespace; this.providerValue186 = selection.provider
        this.digestValue186 = selection.packageDigest; this.planToolValue186 = ""
        this.configurationDigestValue186 = selection.configurationDigest
    }
    func validateCurrent(): Result<Unit> {
        if (ownedReturned186) { return productPolicySelectionError("policy.configuration_changed") }
        match (owned186) { case Some(actual) => return actual.validateCurrent173(); case None => () }
        match (canonicalSelection173) { case Some(actual) => return actual.validateCurrent173(); case None => () }
        match (productPolicyConfigText(settingsRootValue186)) {
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
        match (owned186) { case Some(value) => return value.validatePolicyGeneration193(host, binding.generation, true); case None => () }
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
        match (owned186) { case Some(value) => return value.validatePolicyGeneration193(host, binding.generation, false); case None => () }
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
        let requestedRoot = Path(settingsRoot)
        if (!exists(requestedRoot)) { return productPolicySelectionError("policy.not_configured") }
        let root = canonicalize(requestedRoot)
        let directory = root.join("plugins")
        let path = directory.join("policies.json")
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
                if (name.unifiedKind != ValueKind.Text || !productDocumentLogicalName(name.text)) {
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

func productOwnedCanonicalPolicySelection186(selected: HostOwnedCanonicalProjectionSelection186): ProductPolicySelection {
    var bytes: Int64 = 0
    for (size in [selected.textSize186(0), selected.textSize186(3), selected.textSize186(1), selected.textSize186(7)]) {
        if (bytes > Int64.Max - size) { throw LogicalJsonPayloadError("canonical Product policy metadata overflow") }
        bytes += size
    }
    if (bytes > (Int64.Max - 32768) / 8) { throw LogicalJsonPayloadError("canonical Product policy metadata overflow") }
    selected.constructCopiedConsumer186<ProductPolicySelection>(32768 + bytes * 8,
        { payment, view => ProductPolicySelection(view, payment) })
}
