package agent_product

import agent_plugin_registry.*

import agent_domain.*
import agent_sdk.*
import agent_extension_runtime.*
import std.collection.*
import std.fs.*
import std.io.*
import yjson.*
import yjson_support.*

// Distribution is an explicit host installation choice. It supplies package
// defaults, never capabilities, credentials, an approval or a second registry.
public func applyProductDistributionDefaults(product: ProductRuntime, directory: String): Result<Unit> {
    try {
        let root = canonicalize(Path(directory)).toString()
        if (FileInfo(Path(directory)).isSymbolicLink() || !FileInfo(Path(root)).isDirectory()) {
            return distributionError("distribution.root_invalid") }
        let manifest = parseUnifiedJson(distributionText(root, "distribution.json"), maxBytes: 65536, maxDepth: 16)
        if (manifest.unifiedKind != ValueKind.Object || httpIntentText(manifest, "schema") != "axyndra.distribution/v1" ||
            httpIntentText(manifest, "id") == "" || httpIntentText(manifest, "id").size > 64) {
            return distributionError("distribution.manifest_invalid") }
        for (name in ["schema", "id", "plugins", "context"] where manifest.field(name).isNone()) {
            return distributionError("distribution.manifest_invalid") }
        for (field in manifest.fields where !["schema", "id", "plugins", "context", "policies", "read_scopes", "workspace"].contains(field.name)) {
            return distributionError("distribution.manifest_invalid") }
        let readScopes = manifest.field("read_scopes")
        match (readScopes) { case Some(value) => if (!distributionReadScopesValid(value)) {
            return distributionError("distribution.read_scopes_invalid") }; case None => () }
        let entries = manifest.field("plugins").getOrThrow()
        if (entries.unifiedKind != ValueKind.List || entries.items.size > 32) {
            return distributionError("distribution.manifest_invalid") }
        let names = HashSet<String>(); let descriptors = ArrayList<OwnedPluginPackageDescriptor>()
        // Validate the complete manifest and actual packages before importing
        // any entry. Malformed defaults cannot partially install a prefix.
        for (entry in entries.items) {
            if (!httpIntentExactFields(entry, ["path", "namespace", "version", "package_digest", "enabled"]) ||
                entry.field("enabled").getOrThrow().unifiedKind != ValueKind.Boolean) {
                return distributionError("distribution.manifest_invalid") }
            let descriptor = match (product.inspectPlugin(distributionMember(root, httpIntentText(entry, "path"), true))) {
                case PluginRegistryResult.Ok(value) => value
                case PluginRegistryResult.Err(_) => return distributionError("distribution.package_invalid") }
            if (names.contains(productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Namespace))) || productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Namespace)) != httpIntentText(entry, "namespace") ||
                productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Version)) != httpIntentText(entry, "version") || productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.ContentDigest)) != httpIntentText(entry, "package_digest")) {
                return distributionError("distribution.package_changed") }
            productRegistryPrepayCells83(descriptor, entries.items.size * 4); names.add(productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Namespace))); descriptors.add(descriptor)
        }
        let workspaceDefault = manifest.field("workspace")
        match(workspaceDefault){
            case Some(value)=>
                if(!httpIntentExactFields(value,["namespace","package_digest"])){
                    return distributionError("distribution.workspace_invalid")}
                var matched=false
                for(index in 0..descriptors.size){
                    let descriptor=descriptors[index]
                    if(productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Namespace))==httpIntentText(value,"namespace") && productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.ContentDigest))==httpIntentText(value,"package_digest") &&
                        descriptor.entryKind==PluginEntryKind.NativeExecutable && productRegistryCapabilities83(descriptor).size==1 &&
                        productRegistryCapabilities83(descriptor)[0]=="process.readview" && entries.items[index].field("enabled").getOrThrow().asBool()){
                        var count:Int64=0
                        for(contribution in productRegistryContributions83(descriptor) where contribution.kind==PluginContributionKind.Tool &&
                            ["read","grep","glob","edit","write"].contains(productRegistryCopyText83(contribution.copyText(PluginContributionText.Name)))){count++}
                        matched=count==5 && productRegistryContributions83(descriptor).size==5
                    }
                }
                if(!matched){return distributionError("distribution.workspace_invalid")}
            case None=>()
        }
        let policies = manifest.field("policies") ?? objectValue([])
        if (policies.unifiedKind != ValueKind.Object || policies.fields.size > 32) { return distributionError("distribution.policy_invalid") }
        for (policy in policies.fields) {
            let workflowPlan=policy.name=="workflow" && policy.value.field("plan_tool").isSome()
            if(workflowPlan && (policy.value.field("plan_tool").getOrThrow().unifiedKind!=ValueKind.Text ||
                !productDocumentLogicalName(httpIntentText(policy.value,"plan_tool")))){
                return distributionError("distribution.policy_invalid")}
            if (policy.name == "" || policy.name.size > 64 || policy.name.contains("\u{0000}") ||
                !(if(workflowPlan){httpIntentExactFields(policy.value,["namespace","provider","plan_tool"])}
                    else{httpIntentExactFields(policy.value,["namespace","provider"])})) { return distributionError("distribution.policy_invalid") }
            let namespace = httpIntentText(policy.value, "namespace"); let name = httpIntentText(policy.value, "provider")
            if (!names.contains(namespace) || name == "" || name.size > 128 || name.contains("\u{0000}")) {
                return distributionError("distribution.policy_invalid") }
            var present = false
            for (descriptor in descriptors where productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Namespace)) == namespace) {
                for (contribution in productRegistryContributions83(descriptor) where contribution.kind == PluginContributionKind.Provider && productRegistryCopyText83(contribution.copyText(PluginContributionText.Name)) == name) {
                    present = true }
            }
            if (!present) { return distributionError("distribution.policy_invalid") }
            if(workflowPlan){
                var planPresent=false
                for(descriptor in descriptors where productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Namespace))==namespace){
                    for(contribution in productRegistryContributions83(descriptor) where contribution.kind==PluginContributionKind.Tool &&
                        productRegistryCopyText83(contribution.copyText(PluginContributionText.Name))==httpIntentText(policy.value,"plan_tool") &&
                        contribution.executionProfile==PluginToolExecutionProfile.DataOnly){planPresent=true}
                }
                if(!planPresent){return distributionError("distribution.policy_invalid")}
            }
        }
        let context = manifest.field("context").getOrThrow()
        var template: ?AgentValue = None
        var selectedNamespace = ""
        if (context.unifiedKind != ValueKind.Null) {
            if (!httpIntentExactFields(context, ["namespace", "recipe", "sha256"])) {
                return distributionError("distribution.context_invalid") }
            selectedNamespace = httpIntentText(context, "namespace")
            if (!names.contains(selectedNamespace)) { return distributionError("distribution.context_invalid") }
            let text = distributionText(root, httpIntentText(context, "recipe"))
            if (modelPolicySha256Text(text) != httpIntentText(context, "sha256")) {
                return distributionError("distribution.recipe_changed") }
            let recipe = parseUnifiedJson(text, maxBytes: 65536, maxDepth: 32)
            if (!httpIntentExactFields(recipe, ["schema", "id", "provider", "context"]) ||
                httpIntentText(recipe, "schema") != "axyndra.context-profile/v1" ||
                httpIntentText(recipe, "id") != httpIntentText(manifest, "id")) {
                return distributionError("distribution.context_invalid") }
            let provider = recipe.field("provider").getOrThrow(); let value = recipe.field("context").getOrThrow()
            if (!httpIntentExactFields(provider, ["package", "contribution", "enabled_by_distribution"]) ||
                !readViewRelativePath(httpIntentText(provider, "package")) ||
                provider.field("enabled_by_distribution").getOrThrow().unifiedKind != ValueKind.Boolean ||
                !provider.field("enabled_by_distribution").getOrThrow().asBool() ||
                value.unifiedKind != ValueKind.Object || httpIntentText(value, "namespace") != "$" + "{provider_namespace}" ||
                httpIntentText(value, "package_digest") != "$" + "{provider_package_digest}" ||
                httpIntentText(value, "provider") != httpIntentText(provider, "contribution") ||
                value.field("version").isNone() || value.field("version").getOrThrow().unifiedKind != ValueKind.Number ||
                value.field("version").getOrThrow().asNumberText() != "4") {
                return distributionError("distribution.context_invalid") }
            for (descriptor in descriptors where productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Namespace)) == selectedNamespace) {
                value.put("namespace", textValue(productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Namespace)))); value.put("package_digest", textValue(productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.ContentDigest))))
            }
            match (product.validateDistributionContext(stringifyUnifiedJson(value))) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            template = Some(value)
        }
        for (index in 0..descriptors.size) {
            let descriptor = descriptors[index]; let entry = entries.items[index]
            var existing: ?ProductPluginRecord = None
            for (record in productRegistryRecords83(product.pluginSnapshots()) where productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) == productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Namespace))) {
                if (existing.isNone() || distributionPluginScopeRank(record) > distributionPluginScopeRank(existing.getOrThrow())) { existing = Some(record) }
            }
            match (existing) {
                case Some(_) => () // Never update, re-enable or shadow an operator's record.
                case None =>
                    let installed = match (product.importLocalPlugin(productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Root)), PluginInstallScope.User)) {
                        case PluginRegistryResult.Ok(value) => value
                        case PluginRegistryResult.Err(error) => return distributionError(error.code) }
                    if (productRegistryCopyText83(installed.descriptor.copyText(PluginDescriptorText.ContentDigest)) != productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.ContentDigest)) || productRegistryCopyText83(installed.descriptor.copyText(PluginDescriptorText.Version)) != productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Version))) {
                        return distributionError("distribution.package_changed") }
                    if (entry.field("enabled").getOrThrow().asBool()) {
                        match (product.setPluginEnabled(productRegistryCopyText83(installed.descriptor.copyText(PluginDescriptorText.Namespace)), true, PluginInstallScope.User)) {
                            case PluginRegistryResult.Err(error) => return distributionError(error.code)
                            case PluginRegistryResult.Ok(_) => () }
                    }
            }
        }
        match(workspaceDefault){case Some(value)=>
            match(seedDistributionWorkspace(product,value)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            case None=>()}
        match (seedDistributionPolicies(product, policies)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (readScopes) { case Some(value) =>
            match (seedDistributionReadScopes(product, value)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            case None => () }
        // Existing operator context is never replaced, including malformed
        // selections: the ordinary loader will retain its explicit diagnostic.
        if (template.isNone() || hasInitialContextConfiguration(product.settingsRoot)) { return Result.Ok(()) }
        var selected: ?ProductPluginRecord = None
        for (record in productRegistryRecords83(product.pluginSnapshots()) where productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) == selectedNamespace) {
            if (selected.isNone() || distributionPluginScopeRank(record) > distributionPluginScopeRank(selected.getOrThrow())) { selected = Some(record) }
        }
        if (selected.isNone()) { return distributionError("distribution.provider_missing") }
        let actual = selected.getOrThrow()
        // Preserve the operator's effective record, including a disabled or
        // independently updated provider. Binding that exact record selects
        // the normal initial-context path; availability and typed contribution
        // compatibility are checked at inference, without legacy fallback.
        // A disabled optional provider must not disable host management.
        let value = template.getOrThrow()
        value.put("namespace", textValue(productRegistryCopyText83(actual.descriptor.copyText(PluginDescriptorText.Namespace)))); value.put("package_digest", textValue(productRegistryCopyText83(actual.copyText(PluginRecordText.ContentLock))))
        let encoded = stringifyUnifiedJson(value)
        if (encoded.size > 65536) { return distributionError("distribution.context_invalid") }
        // Validate with current registry facts before publishing the file. This
        // does not read Skill content or produce a Run/Operation/approval.
        match (product.validateDistributionContext(encoded)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let destination = Path(product.settingsRoot).join("plugins/context.json")
        let temporary = destination.toString() + ".distribution-" + ProductIds().nextInvocationId()
        try {
            File.writeTo(temporary, encoded.toArray())
            // Atomic no-replace publication preserves a concurrent explicit
            // operator choice. Imported plugins remain real registry records.
            try { rename(temporary, to: destination.toString(), overwrite: false) } catch (_: Exception) {
                if (!hasInitialContextConfiguration(product.settingsRoot)) { return distributionError("distribution.context_write_failed") }
            }
        } finally { if (exists(Path(temporary))) { remove(temporary) } }
        Result.Ok(())
    } catch (_: Exception) { distributionError("distribution.invalid") }
}

func distributionMember(root: String, relative: String, directory: Bool): String {
    if (!readViewRelativePath(relative)) { throw IllegalArgumentException("distribution member must be relative") }
    let path = Path(root).join(relative)
    // Every component is a real member, never a symlink trampoline.
    var current = Path(root)
    for (part in relative.split("/")) {
        current = current.join(part)
        if (FileInfo(current).isSymbolicLink()) { throw IllegalArgumentException("distribution member is symbolic") }
    }
    let info = FileInfo(path)
    if (canonicalize(path).toString() != path.toString() ||
        (directory && !info.isDirectory()) || (!directory && (!info.isRegular() || info.size > 65536))) {
        throw IllegalArgumentException("distribution member changed or exceeds its bound") }
    path.toString()
}
func distributionText(root: String, relative: String): String {
    let file = File(distributionMember(root, relative, false), OpenMode.Read)
    try {
        let bytes = ArrayList<Byte>(); let buffer = Array<Byte>(4096, repeat: 0)
        while (true) {
            let count = file.read(buffer)
            if (count == 0) { break }
            if (count > 65536 - bytes.size) { throw IllegalArgumentException("distribution text exceeds its bound") }
            for (index in 0..count) { bytes.add(buffer[index]) }
        }
        if (bytes.isEmpty()) { throw IllegalArgumentException("distribution text is empty") }
        String.fromUtf8(bytes.toArray())
    } finally { file.close() }
}
func distributionError<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Configuration, code, "bundled distribution defaults could not be applied; existing operator state was retained"))
}

func bindInitialContextRootTemplates(value: AgentValue, settings: String, workspace: String): Result<Unit> {
    let resources = value.field("resources") ?? nullValue()
    if (resources.unifiedKind != ValueKind.List || resources.items.size > 64) { return initialContextError("context.initial_configuration_invalid") }
    let settingsRoot = canonicalize(Path(settings)).toString(); let workspaceRoot = canonicalize(Path(workspace)).toString()
    for (resource in resources.items) {
        let source = httpIntentText(resource, "source")
        var root = ""; var suffix = ""
        if (source.startsWith("$" + "{settings_root}/")) { root = settingsRoot; suffix = source[17..] }
        else if (source.startsWith("$" + "{workspace_root}/")) { root = workspaceRoot; suffix = source[18..] }
        else if (source.contains("$") || !readViewAbsolutePath(source)) { return initialContextError("context.initial_root_template_invalid") }
        if (root != "") {
            if (!readViewRelativePath(suffix) || suffix.contains("$")) { return initialContextError("context.initial_root_template_invalid") }
            resource.put("source", textValue(Path(root).join(suffix).toString()))
        }
    }
    Result.Ok(())
}

func seedDistributionPolicies(product: ProductRuntime, policies: AgentValue): Result<Unit> {
    let destination = Path(product.settingsRoot).join("plugins/policies.json")
    // The entire operator file wins, including an explicitly absent binding.
    if (policies.fields.isEmpty() || exists(destination)) { return Result.Ok(()) }
    let bindings = ArrayList<ValueField>()
    for (policy in policies.fields) {
        var chosen: ?ProductPluginRecord = None
        for (record in productRegistryRecords83(product.pluginSnapshots()) where productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) == httpIntentText(policy.value, "namespace")) {
            if (chosen.isNone() || distributionPluginScopeRank(record) > distributionPluginScopeRank(chosen.getOrThrow())) { chosen = Some(record) }
        }
        let record = match (chosen) { case Some(value) => value; case None => return distributionError("distribution.policy_missing") }
        let fields=ArrayList<ValueField>([ValueField("namespace",textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))),
            ValueField("provider",textValue(httpIntentText(policy.value,"provider"))),ValueField("package_digest",textValue(productRegistryCopyText83(record.copyText(PluginRecordText.ContentLock))))])
        if(policy.name=="workflow" && policy.value.field("plan_tool").isSome()){
            fields.add(ValueField("plan_tool",textValue(httpIntentText(policy.value,"plan_tool"))))}
        bindings.add(ValueField(policy.name,objectValue(fields.toArray())))
    }
    let encoded = stringifyUnifiedJson(objectValue([ValueField("version", integerValue(1)), ValueField("bindings", objectValue(bindings.toArray()))]))
    if (encoded.size > 65536) { return distributionError("distribution.policy_invalid") }
    let temporary = destination.toString() + ".distribution-" + ProductIds().nextInvocationId()
    try {
        File.writeTo(temporary, encoded.toArray())
        try { rename(temporary, to: destination.toString(), overwrite: false) }
        catch (_: Exception) { if (!exists(destination)) { return distributionError("distribution.policy_write_failed") } }
    } finally { if (exists(Path(temporary))) { remove(temporary) } }
    Result.Ok(())
}

// Portable operator data only. The Context reader still normalizes the actual
// roots, excludes credentials/state, and applies current capabilities/approval.
func distributionReadScopesValid(value: AgentValue): Bool {
    if (!httpIntentExactFields(value, ["version", "roots"]) || value.field("version").getOrThrow().unifiedKind != ValueKind.Number ||
        value.field("version").getOrThrow().asNumberText() != "1" || value.field("roots").getOrThrow().unifiedKind != ValueKind.List ||
        value.field("roots").getOrThrow().items.size > 64) { return false }
    let seen = HashSet<String>()
    for (root in value.field("roots").getOrThrow().items) {
        if (root.unifiedKind != ValueKind.Text || !root.text.startsWith("$" + "{settings_root}/") || root.text.size > 4096 || seen.contains(root.text)) { return false }
        let suffix = root.text[17..]
        if (!readViewRelativePath(suffix) || suffix.contains("$") || suffix.split("/")[0] == "plugins" || sensitiveReadPath("/" + suffix)) { return false }
        for (part in suffix.split("/") where [".git", ".hg", ".svn", ".ssh", ".gnupg", ".aws", ".kube"].contains(part.toAsciiLower())) { return false }
        seen.add(root.text)
    }
    true
}
func seedDistributionReadScopes(product: ProductRuntime, value: AgentValue): Result<Unit> {
    let destination = Path(product.settingsRoot).join("plugins/read-scopes.json")
    // Even an invalid operator file is an explicit choice, never overwritten.
    if (exists(destination)) { return Result.Ok(()) }
    if (!exists(destination.parent)) { Directory.create(destination.parent, recursive: true) }
    let encoded = stringifyUnifiedJson(value)
    if (encoded.size > 65536) { return distributionError("distribution.read_scopes_invalid") }
    let temporary = destination.toString() + ".distribution-" + ProductIds().nextInvocationId()
    try {
        File.writeTo(temporary, encoded.toArray())
        try { rename(temporary, to: destination.toString(), overwrite: false) }
        catch (_: Exception) { if (!exists(destination)) { return distributionError("distribution.read_scopes_write_failed") } }
    } finally { if (exists(Path(temporary))) { remove(temporary) } }
    Result.Ok(())
}

// Selection is data only. Existing operator choices, including disabled or
// malformed choices, win. IO still needs the actual selected Root and approval.
func seedDistributionWorkspace(product: ProductRuntime, value: AgentValue): Result<Unit> {
    let destination=Path(product.settingsRoot).join("plugins/workspace-tools.json")
    if(exists(destination)){return Result.Ok(())}
    var chosen: ?ProductPluginRecord=None
    for(record in productRegistryRecords83(product.pluginSnapshots()) where productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace))==httpIntentText(value,"namespace")){
        if(chosen.isNone() || distributionPluginScopeRank(record)>distributionPluginScopeRank(chosen.getOrThrow())){chosen=Some(record)}
    }
    let record=match(chosen){case None=>return distributionError("distribution.workspace_missing");case Some(actual)=>actual}
    let encoded=stringifyUnifiedJson(objectValue([ValueField("schema",textValue("axyndra.workspace-tools/v1")),
        ValueField("namespace",textValue(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))),ValueField("package_digest",textValue(productRegistryCopyText83(record.copyText(PluginRecordText.ContentLock))))]))
    if(encoded.size>16384){return distributionError("distribution.workspace_invalid")}
    if(!exists(destination.parent)){Directory.create(destination.parent,recursive:true)}
    let temporary=destination.toString()+".distribution-"+ProductIds().nextInvocationId()
    try{
        File.writeTo(temporary,encoded.toArray())
        try{rename(temporary,to:destination.toString(),overwrite:false)}
        catch(_:Exception){if(!exists(destination)){return distributionError("distribution.workspace_write_failed")}}
    }finally{if(exists(Path(temporary))){remove(temporary)}}
    Result.Ok(())
}

private func distributionPluginScopeRank(record: ProductPluginRecord): Int64 {
    if (pluginScopeEquals(record.scope, PluginInstallScope.User) && record.explicitlyDisabled) { return 2 }
    if (pluginScopeEquals(record.scope, PluginInstallScope.Workspace)) { return 1 }
    0
}
