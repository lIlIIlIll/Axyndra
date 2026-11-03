package agent_host_runtime

import agent_domain.*
import sandbox4cj.*
import std.collection.*
import std.env.*
import std.sync.*
import yjson.*
import yjson_support.*

// Operator-owned source descriptions. Neither these values nor their serialized
// form authorize a launch. Secret material is first read after actual handoff.
class HostProcessCredentialSource {
    let ref: String
    let environment: String
    let file: String
    init(ref: String, environment: String, file: String) {
        this.ref = ref; this.environment = environment; this.file = file
    }
}

func hostProcessEnvironmentName(value: String): Bool {
    if (value == "" || value.size > 128) { return false }
    let bytes = value.toArray()
    for (index in 0..bytes.size) {
        let byte = bytes[index]
        if (!((byte >= b'A' && byte <= b'Z') || (byte >= b'a' && byte <= b'z') ||
            byte == b'_' || (index > 0 && byte >= b'0' && byte <= b'9'))) { return false }
    }
    true
}
func hostProcessEnvironmentSecretName(value: String): Bool {
    let name = value.toAsciiUpper()
    name.contains("SECRET") || name.contains("TOKEN") || name.contains("PASSWORD") ||
        name.contains("PASSWD") || name.contains("CREDENTIAL") || name.endsWith("_KEY") ||
        name.contains("API_KEY") || name == "SSH_AUTH_SOCK" || name.contains("COOKIE")
}
func hostProcessEnvironmentTarget(value: String): Bool {
    let name = value.toAsciiUpper()
    hostProcessEnvironmentName(value) && !name.startsWith("LD_") && !name.startsWith("DYLD_") &&
        !["PATH", "HOME", "LANG", "TMPDIR", "TMP", "TEMP", "PYTHONPATH", "PYTHONHOME", "BASH_ENV", "ENV",
            "NODE_OPTIONS", "SSL_CERT_FILE", "CURL_CA_BUNDLE", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
            "NO_PROXY", "AXYNDRA_NETWORK_GATEWAY_TOKEN"].contains(name)
}

func hostParseProcessCredentialSources(value: AgentValue): Array<HostProcessCredentialSource> {
    hostLifecycleRequire(value.unifiedKind == ValueKind.List && value.items.size <= 4)
    let sources = ArrayList<HostProcessCredentialSource>()
    let refs = HashSet<String>()
    for (item in value.items) {
        hostLifecycleExact(item, ["ref", "source"])
        let ref = hostLifecycleText(item, "ref")
        hostLifecycleRequire(hostLifecycleIdentifier(ref, 128) && !refs.contains(ref)); refs.add(ref)
        let source = item.field("source").getOrThrow()
        hostLifecycleRequire(source.unifiedKind == ValueKind.Object && source.fields.size == 1)
        let environment = if (source.field("environment").isSome()) { hostLifecycleText(source, "environment") } else { "" }
        let file = if (source.field("file").isSome()) { hostLifecycleText(source, "file") } else { "" }
        if (environment != "") { hostLifecycleExact(source, ["environment"]); hostLifecycleRequire(hostProcessEnvironmentName(environment)) }
        else { hostLifecycleExact(source, ["file"]); hostLifecycleRequire(hostPluginHttpRelativePath(file)) }
        sources.add(HostProcessCredentialSource(ref, environment, file))
    }
    sources.toArray()
}

func hostValidateProcessEnvironmentBindings(service: AgentValue,
    credentials: Array<HostProcessCredentialSource>): Unit {
    let ordinary = service.field("environment").getOrThrow()
    let secrets = match (service.field("secret_env")) { case Some(value) => value; case None => objectValue([]) }
    hostLifecycleRequire(ordinary.unifiedKind == ValueKind.Object && ordinary.fields.size <= 64 &&
        secrets.unifiedKind == ValueKind.Object && secrets.fields.size <= 4)
    let targets = HashSet<String>()
    for (entry in ordinary.fields) {
        hostLifecycleRequire(hostProcessEnvironmentTarget(entry.name) && !hostProcessEnvironmentSecretName(entry.name) &&
            entry.value.unifiedKind == ValueKind.Text && hostProcessEnvironmentName(entry.value.text) &&
            !hostProcessEnvironmentSecretName(entry.value.text) && !targets.contains(entry.name),
            "plugin.lifecycle_environment_invalid")
        targets.add(entry.name)
    }
    let selected = HashSet<String>()
    for (entry in secrets.fields) {
        hostLifecycleRequire(hostProcessEnvironmentTarget(entry.name) && !targets.contains(entry.name) &&
            entry.value.unifiedKind == ValueKind.Text, "plugin.lifecycle_environment_invalid")
        targets.add(entry.name)
        var found = false
        for (source in credentials where source.ref == entry.value.text) { found = true }
        hostLifecycleRequire(found, "plugin.lifecycle_credential_denied")
        selected.add(entry.value.text)
    }
    let refs = hostLifecycleStrings(service.field("credential_refs").getOrThrow(), 4, true)
    hostLifecycleRequire(refs.size == selected.size, "plugin.lifecycle_credential_denied")
    for (ref in refs) { hostLifecycleRequire(selected.contains(ref), "plugin.lifecycle_credential_denied") }
}

class HostResolvedProcessEnvironment {
    private let values: Array<SandboxEnvironmentEntry>
    private let privateValues: Array<String>
    private let privateNames: Array<String>
    prop entries: Array<SandboxEnvironmentEntry> { get() { values.clone() } }
    prop secrets: Array<String> { get() { privateValues.clone() } }
    prop secretNames: Array<String> { get() { privateNames.clone() } }
    prop names: Array<String> { get() { values.map { entry => entry.name } } }
    init(values: Array<SandboxEnvironmentEntry>, secrets: Array<String>, names: Array<String>) {
        this.values = values.clone(); this.privateValues = secrets.clone(); this.privateNames = names.clone()
    }
}

// This private object freezes ordinary values and source identities, then owns
// the first post-handoff secret snapshot. The public launch plan contains only
// target/source names and opaque refs, never these values or their hashes.
class HostLifecycleEnvironment {
    private let settingsRoot: String
    private let ordinary: Array<SandboxEnvironmentEntry>
    private let sources: Array<HostProcessCredentialSource>
    private let bindingsText: String
    private let secretBindingsText: String
    private let lock = Mutex()
    private var resolved: ?HostResolvedProcessEnvironment = None
    init(settingsRoot: String, service: AgentValue, sources: Array<HostProcessCredentialSource>) {
        hostValidateProcessEnvironmentBindings(service, sources)
        this.settingsRoot = settingsRoot; this.sources = sources.clone()
        bindingsText = stringifyUnifiedJson(service.field("environment").getOrThrow())
        secretBindingsText = stringifyUnifiedJson(match (service.field("secret_env")) {
            case Some(value) => value; case None => objectValue([]) })
        ordinary = hostReadProcessOrdinaryBindings(bindingsText)
    }
    func stillCurrent(): Result<Unit> {
        try {
            hostLifecycleRequire(sameEntries(ordinary, readOrdinary()), "plugin.lifecycle_environment_changed")
            lock.lock()
            let selected = try { resolved } finally { lock.unlock() }
            match (selected) {
                case Some(value) => hostLifecycleRequire(sameEntries(value.entries, readResolved().entries),
                    "plugin.lifecycle_environment_changed")
                case None => () // inspection, preparation and approval never read credentials
            }
            Result.Ok(())
        } catch (_: Exception) { hostLifecycleError("plugin.lifecycle_environment_changed", "configured process environment changed or is unavailable") }
    }
    func resolveAfterHandoff(): Result<HostResolvedProcessEnvironment> {
        try {
            hostLifecycleRequire(sameEntries(ordinary, readOrdinary()), "plugin.lifecycle_environment_changed")
            let value = readResolved()
            lock.lock()
            try {
                match (resolved) {
                    case Some(previous) => hostLifecycleRequire(sameEntries(previous.entries, value.entries),
                        "plugin.lifecycle_environment_changed")
                    case None => resolved = Some(value)
                }
                Result.Ok(value)
            } finally { lock.unlock() }
        } catch (_: Exception) { hostLifecycleError("plugin.lifecycle_credential_unavailable", "configured process environment cannot be resolved at launch") }
    }
    private func readOrdinary(): Array<SandboxEnvironmentEntry> {
        hostReadProcessOrdinaryBindings(bindingsText)
    }
    private func readResolved(): HostResolvedProcessEnvironment {
        let entries = ArrayList<SandboxEnvironmentEntry>(); entries.add(all: ordinary)
        let secrets = ArrayList<String>(); let names = ArrayList<String>()
        for (entry in parseUnifiedJson(secretBindingsText).fields) {
            var source: ?HostProcessCredentialSource = None
            for (candidate in sources where candidate.ref == entry.value.text) { source = Some(candidate) }
            let selected = source.getOrThrow()
            let secret = if (selected.environment != "") { getVariable(selected.environment).getOrThrow() }
                else {
                    let path = hostPluginHttpCredentialFile(settingsRoot, selected.file).value().getOrThrow()
                    readHostPluginHttpBoundedText(path, 8192).value().getOrThrow()
                }
            hostLifecycleRequire(secret != "" && secret.size <= 8192 && !secret.contains("\u{0000}"))
            entries.add(SandboxEnvironmentEntry(entry.name, secret)); secrets.add(secret); names.add(entry.name)
        }
        HostResolvedProcessEnvironment(entries.toArray(), secrets.toArray(), names.toArray())
    }
    private func sameEntries(first: Array<SandboxEnvironmentEntry>, second: Array<SandboxEnvironmentEntry>): Bool {
        if (first.size != second.size) { return false }
        for (index in 0..first.size) {
            if (first[index].name != second[index].name || first[index].value != second[index].value) { return false }
        }
        true
    }
}

func hostReadProcessOrdinaryBindings(bindingsText: String): Array<SandboxEnvironmentEntry> {
    let result = ArrayList<SandboxEnvironmentEntry>()
    var size: Int64 = 0
    for (entry in parseUnifiedJson(bindingsText).fields) {
        let value = getVariable(entry.value.text).getOrThrow()
        size += value.size
        hostLifecycleRequire(value.size <= 8192 && size <= 16384 && !value.contains("\u{0000}"),
            "plugin.lifecycle_environment_invalid")
        result.add(SandboxEnvironmentEntry(entry.name, value))
    }
    result.toArray()
}
