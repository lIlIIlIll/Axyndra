package product_contract

import std.collection.*
import agent_domain.*
import agent_product.*
import workspace_legacy_oracle.*
import std.env.*
import std.fs.*
import yjson.*
import yjson_support.*

// Ordinary installed package and operator configuration. No Host role factory,
// fixture-only Runtime implementation or fabricated delegation authority.
func installWorkflowContractPolicy(product: ProductRuntime): ProductPluginRecord {
    let packagePath = getVariable("AXYNDRA_WORKFLOW_PLUGIN_PACKAGE").getOrThrow()
    let record = match (product.importLocalPlugin(packagePath)) {
        case PluginRegistryResult.Ok(value) => supportRegistryRecord96(value)
        case PluginRegistryResult.Err(error) => throw IllegalStateException("workflow fixture import: " + supportRegistryExclusiveErrorCode96(error))
    }
    configureTodoContractDocument(product,record)
    configureWorkflowYieldContract150(product,record)
    match (product.setPluginEnabled(supportRegistryDescriptor96(record,"namespace"), true)) {
        case PluginRegistryResult.Ok(discard96) => supportRegistryDiscard96(discard96)
        case PluginRegistryResult.Err(error) => throw IllegalStateException("workflow fixture enable: " + supportRegistryExclusiveErrorCode96(error))
    }
    let directory = product.settingsRoot + "/plugins"
    let path = directory + "/policies.json"
    let settings = if (exists(Path(path))) {
        parseUnifiedJson(String.fromUtf8(File.readFrom(path)), maxBytes: 65536)
    } else { objectValue([ValueField("version", integerValue(1)), ValueField("bindings", objectValue([]))]) }
    if (settings.field("version").isNone() || settings.field("version").getOrThrow().asNumberText() != "1" ||
        settings.field("bindings").isNone() || settings.field("bindings").getOrThrow().unifiedKind != ValueKind.Object) {
        throw IllegalStateException("workflow fixture refuses unexpected operator policy settings") }
    let expected = objectValue([ValueField("namespace", textValue(supportRegistryDescriptor96(record,"namespace"))),
        ValueField("provider", textValue("propose")), ValueField("package_digest", textValue(supportRegistryDescriptor96(record,"content_digest"))),
        ValueField("plan_tool", textValue("plan_write"))])
    let bindings = settings.field("bindings").getOrThrow()
    match (bindings.field("workflow")) {
        case Some(current) =>
            if (canonicalAgentValue(current) != canonicalAgentValue(expected)) {
                throw IllegalStateException("workflow fixture refuses to overwrite another selected provider") }
        case None =>
            bindings.put("workflow", expected)
            if (!exists(Path(directory))) { Directory.create(directory, recursive: true) }
            File.writeTo(path, stringifyUnifiedJson(settings).toArray())
    }
    record
}

// A second Product over this same settings root reuses only the original
// enabled local package and exact operator selection. A duplicate import is
// still an error; this check neither installs nor changes configuration.
func requireWorkflowContractPolicy(product: ProductRuntime, expected: ProductPluginRecord): Unit {
    var matches: Int64 = 0
    // The public snapshot list is index-addressed, not an iterator; walk it
    // explicitly and keep the same namespace filter.
    let snapshots = product.pluginSnapshots()
    for (index in 0..snapshots.size) {
        let current = snapshots.at(index)
        if (supportRegistryDescriptor96(current,"namespace") != supportRegistryDescriptor96(expected,"namespace")) { continue }
        expect(supportRegistryDescriptor96(current,"namespace") == "axyndra:workflow" &&
            supportRegistryDescriptor96(current,"root") == supportRegistryDescriptor96(expected,"root") &&
            supportRegistryDescriptor96(current,"id") == supportRegistryDescriptor96(expected,"id") && supportRegistryDescriptor96(current,"version") == supportRegistryDescriptor96(expected,"version") &&
            supportRegistryDescriptor96(current,"content_digest") == supportRegistryDescriptor96(expected,"content_digest") && supportRegistryField96(current,"content_digest") == supportRegistryField96(expected,"content_digest") &&
            supportRegistryField96(current,"locator") == supportRegistryField96(expected,"locator") && supportRegistryField96(current,"locator") == getVariable("AXYNDRA_WORKFLOW_PLUGIN_PACKAGE").getOrThrow() &&
            supportRegistryData96(current).enabled && !supportRegistryData96(current).explicitlyDisabled &&
            (match (supportRegistryData96(current).sourceKind) { case PluginSourceKind.Local => true; case _ => false }) &&
            (match (supportRegistryData96(current).scope) { case PluginInstallScope.User => true; case _ => false }),
            "workflow fixture reuses its original enabled local package")
        matches += 1
    }
    expect(matches == 1, "workflow fixture retains exactly one original package record")
    let settings = parseUnifiedJson(String.fromUtf8(File.readFrom(product.settingsRoot + "/plugins/policies.json")), maxBytes: 65536)
    expect(settings.field("version").getOrThrow().asNumberText() == "1",
        "workflow fixture preserves its versioned operator settings")
    let selected = settings.field("bindings").getOrThrow().field("workflow").getOrThrow()
    expect(canonicalAgentValue(selected) == canonicalAgentValue(objectValue([
        ValueField("namespace", textValue(supportRegistryDescriptor96(expected,"namespace"))), ValueField("provider", textValue("propose")),
        ValueField("package_digest", textValue(supportRegistryDescriptor96(expected,"content_digest"))),
        ValueField("plan_tool", textValue("plan_write"))])),
        "workflow fixture preserves the exact original provider selection")
}

func configureTodoContractDocument(product:ProductRuntime,record:ProductPluginRecord):Unit{
    let directory=product.settingsRoot+"/plugins"
    if(!exists(Path(directory))){Directory.create(directory,recursive:true)}
    File.writeTo(directory+"/todo-tools.json",stringifyUnifiedJson(objectValue([
        ValueField("schema",textValue("axyndra.todo-tools/v1")),ValueField("namespace",textValue(supportRegistryDescriptor96(record,"namespace"))),
        ValueField("package_digest",textValue(supportRegistryDescriptor96(record,"content_digest"))),ValueField("tool",textValue("todo")),ValueField("command",textValue("todo"))])).toArray())
    File.writeTo(directory+"/documents.json",stringifyUnifiedJson(objectValue([
        ValueField("version",integerValue(1)),ValueField("plugins",listValue([objectValue([
            ValueField("namespace",textValue(supportRegistryDescriptor96(record,"namespace"))),ValueField("package_digest",textValue(supportRegistryDescriptor96(record,"content_digest"))),
            ValueField("tools",listValue([objectValue([ValueField("name",textValue("todo")),ValueField("preparation_provider",textValue("prepare_document")),
                ValueField("documents",listValue([objectValue([ValueField("key",textValue("todo")),ValueField("read",boolValue(true)),ValueField("write",boolValue(true))])]))])]))])]))])).toArray())
}

// This is ordinary operator selection for the real package. There is no
// synthetic executor, bare alias or builtin Yield fallback in this fixture.
func configureWorkflowYieldContract150(product: ProductRuntime, record: ProductPluginRecord): Unit {
    let directory=product.settingsRoot+"/plugins"
    if(!exists(Path(directory))){Directory.create(directory,recursive:true)}
    let path=directory+"/primitives.json"
    let selected=objectValue([ValueField("namespace",textValue(supportRegistryDescriptor96(record,"namespace"))),
        ValueField("package_digest",textValue(supportRegistryDescriptor96(record,"content_digest"))),
        ValueField("tools",listValue([objectValue([ValueField("name",textValue("task")),
            ValueField("profile",textValue("frozen-primitives-v1")),
            ValueField("services",listValue([textValue("child.start"),textValue("child.wait")])),
            ValueField("preparation_provider",textValue("prepare_child"))]),
            objectValue([ValueField("name",textValue("yield")),
            ValueField("profile",textValue("frozen-primitives-v1")),ValueField("services",listValue([textValue("child.result.write")])),
            ValueField("preparation_provider",textValue("prepare_child")),ValueField("invocation_capability",textValue("workspace.read"))]),
            objectValue([ValueField("name",textValue("hub_peers")),
            ValueField("profile",textValue("frozen-primitives-v1")),ValueField("services",listValue([textValue("peer.list"),textValue("peer.receive")])),
            ValueField("preparation_provider",textValue("prepare_child")),ValueField("invocation_capability",textValue("workspace.read"))]),
            objectValue([ValueField("name",textValue("hub_messages")),
            ValueField("profile",textValue("frozen-primitives-v1")),ValueField("services",listValue([textValue("peer.send"),textValue("peer.wait")])),
            ValueField("preparation_provider",textValue("prepare_child")),ValueField("invocation_capability",objectValue([ValueField("catalog",textValue("workspace.read")),ValueField("services",objectValue([ValueField("peer.send",textValue("peer.message")),ValueField("peer.wait",textValue("workspace.read"))]))]))]),
            objectValue([ValueField("name",textValue("hub_jobs")),
            ValueField("profile",textValue("frozen-primitives-v1")),ValueField("services",listValue([textValue("job.list"),textValue("job.wait")])),
            ValueField("preparation_provider",textValue("prepare_child")),ValueField("invocation_capability",textValue("workspace.read"))]),
            objectValue([ValueField("name",textValue("hub_cancel")),
            ValueField("profile",textValue("frozen-primitives-v1")),ValueField("services",listValue([textValue("job.cancel")])),
            ValueField("preparation_provider",textValue("prepare_child")),ValueField("invocation_capability",textValue("delegate"))]),
            objectValue([ValueField("name",textValue("hub_process_read")),
            ValueField("profile",textValue("frozen-primitives-v1")),ValueField("services",listValue([textValue("process.observe")])),
            ValueField("preparation_provider",textValue("prepare_child")),ValueField("invocation_capability",textValue("workspace.read"))]),
            objectValue([ValueField("name",textValue("hub_process")),
            ValueField("profile",textValue("frozen-primitives-v1")),ValueField("services",listValue([textValue("process.service")])),
            ValueField("preparation_provider",textValue("prepare_child")),ValueField("invocation_capability",textValue("process.spawn"))])]))])
    let settings=if(exists(Path(path))){parseUnifiedJson(String.fromUtf8(File.readFrom(path)),maxBytes:65536)}else{
        objectValue([ValueField("version",integerValue(1)),ValueField("plugins",listValue([]))])}
    if(settings.field("version").getOrThrow().asNumberText()!="1" || settings.field("plugins").getOrThrow().unifiedKind!=ValueKind.List){
        throw IllegalStateException("workflow fixture refuses unexpected primitive selection")}
    let entries=ArrayList<AgentValue>();var matched=false
    for(entry in settings.field("plugins").getOrThrow().items){
        if(entry.field("namespace").getOrThrow().text==supportRegistryDescriptor96(record,"namespace")){
            if(matched || canonicalAgentValue(entry)!=canonicalAgentValue(selected)){
                throw IllegalStateException("workflow fixture refuses to overwrite another selected primitive")}
            matched=true
        }
        entries.add(entry)
    }
    if(!matched){entries.add(selected);settings.put("plugins",listValue(entries.toArray()));File.writeTo(path,stringifyUnifiedJson(settings).toArray())}
}
