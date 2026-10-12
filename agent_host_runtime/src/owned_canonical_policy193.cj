package agent_host_runtime

import agent_domain.*
import agent_plugin_registry.*
import std.collection.*
import yjson.*
import yjson_support.*

func hostCanonicalPolicyChanged193(): Result<Unit> {
    Result<Unit>.Err(AgentError(AgentErrorKind.InvalidInput, "policy.provider_changed",
        "the selected installed policy or its pinned configuration is unavailable"))
}
func hostCanonicalPolicyValidate193(host: HostJavaScriptPluginHost,
    selection: HostCanonicalProjectionSelection173, binding: HostPluginPolicyBinding, pinned: Bool): Result<Unit> {
    match (selection.validateCurrent173()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    if (pinned) {
        if (binding.namespace != selection.namespace || binding.contribution != selection.provider || binding.digest != selection.packageDigest) {
            return hostCanonicalPolicyChanged193() }
        let mounted = match (host.servicePackage(selection.namespace, binding.generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        try {
            if (!mounted.textEquals(PluginDescriptorText.Namespace, selection.namespace) ||
                !mounted.textEquals(PluginDescriptorText.ContentDigest, selection.packageDigest)) {
                return hostCanonicalPolicyChanged193() }
            Result<Unit>.Ok(())
        } finally { mounted.close() }
    } else {
        let current = match (host.policyProviderBinding(selection.namespace, selection.provider)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (current.digest != selection.packageDigest || current.generation != binding.generation ||
            binding.namespace != selection.namespace || binding.contribution != selection.provider || binding.digest != selection.packageDigest) {
            return hostCanonicalPolicyChanged193() }
        Result<Unit>.Ok(())
    }
}
func hostCanonicalPolicyQuery193(host: HostJavaScriptPluginHost, selection: HostCanonicalProjectionSelection173,
    input: AgentValue, thread: ThreadId, cancellation: CancellationToken, requestId: String,
    provenance: ?String): Result<HostPolicyScalarResult193> {
    match (provenance) {
        case None => hostQueryPluginPolicyScalars193(host, selection.namespace, selection.provider,
            selection.packageDigest, input, thread, cancellation, requestId)
        case Some(digest) =>
            let count = input.asObject().size()
            if (count < 0 || count > (134217728 - 32768) / 128) {
                throw LogicalJsonPayloadError("canonical policy input metadata exceeds the original bank") }
            let paid = selection.deriveDataPayment173(32768 + count * 128)
            try { hostCanonicalPolicyProvenanceFrame193(host, selection, input, thread, cancellation, requestId, digest) }
            finally { paid.close() }
    }
}
private func hostCanonicalPolicyProvenanceFrame193(host: HostJavaScriptPluginHost,
    selection: HostCanonicalProjectionSelection173, input: AgentValue, thread: ThreadId,
    cancellation: CancellationToken, requestId: String, digest: String): Result<HostPolicyScalarResult193> {
    // Private borrowed metadata is inserted into a private input container.
    // The original HostFrozenPluginContentQuery encodes/parses an independent
    // graph; neither the caller's input nor the returned response binds names.
    let provenance = objectValue([ValueField("namespace", textValue(selection.namespace)),
        ValueField("provider", textValue(selection.provider)), ValueField("package_digest", textValue(selection.packageDigest)),
        ValueField("configuration_digest", textValue(selection.configurationDigest)),
        ValueField("source_projection_digest", textValue(digest)), ValueField("authoritative", boolValue(false))])
    let fields = ArrayList<ValueField>()
    let source = input.asObject()
    var found = false
    for (index in 0..source.size()) {
        let name = source.nameAt(index)
        if (name == "provenance") {
            if (found || source.valueAt(index).unifiedKind != ValueKind.Null) {
                throw IllegalStateException("canonical policy provenance placeholder changed") }
            found = true; fields.add(ValueField(name, provenance))
        } else { fields.add(ValueField(name, source.valueAt(index))) }
    }
    if (!found) { throw IllegalStateException("canonical policy provenance placeholder is missing") }
    hostQueryPluginPolicyScalars193(host, selection.namespace, selection.provider, selection.packageDigest,
        objectValue(fields.toArray()), thread, cancellation, requestId)
}
