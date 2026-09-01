package agent_product

import yjson_support.*

import yjson.*

import agent_domain.*
import model_adapters.*
import std.collection.*
import std.convert.*
import std.fs.*

public class ProductSshHost {
    public let name: String
    public let host: String
    public let username: String
    public let port: ?Int64
    public let keyPath: String
    public let description: String
    public let compat: Bool

    public init(
        name: String,
        host: String,
        username!: String = "",
        port!: ?Int64 = None,
        keyPath!: String = "",
        description!: String = "",
        compat!: Bool = false
    ) {
        this.name = name
        this.host = host
        this.username = username
        this.port = port
        this.keyPath = keyPath
        this.description = description
        this.compat = compat
    }
}

public class ProductSshHosts {
    public let project: Array<ProductSshHost>
    public let user: Array<ProductSshHost>

    public init(
        project: Array<ProductSshHost>,
        user: Array<ProductSshHost>
    ) {
        this.project = project
        this.user = user
    }
}

class ProductSshRuntime {
    private let projectPath: String
    private let userPath: String

    init(workspaceRoot: String, settingsRoot: String) {
        this.projectPath = workspaceRoot + "/.axyndra/ssh.json"
        this.userPath = settingsRoot + "/ssh.json"
    }

    func list(): Result<ProductSshHosts> {
        let project = match (read(projectPath)) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                return Result<ProductSshHosts>.Err(error)
        }
        let user = match (read(userPath)) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                return Result<ProductSshHosts>.Err(error)
        }
        Result.Ok(ProductSshHosts(project, user))
    }

    func add(
        scope: String,
        value: ProductSshHost
    ): Result<Unit> {
        match (validateSshHostName(value.name)) {
            case Some(message) =>
                return sshConfigError<Unit>(
                    "ssh.invalid_name",
                    message,
                    pathFor(scope)
                )
            case None => ()
        }
        if (value.host == "") {
            return sshConfigError<Unit>(
                "ssh.host_required",
                "Host address cannot be empty",
                pathFor(scope)
            )
        }
        let path = pathFor(scope)
        let existing = match (read(path)) {
            case Result.Ok(hosts) => hosts
            case Result.Err(error) => return Result<Unit>.Err(error)
        }
        for (host in existing where host.name == value.name) {
            return sshConfigError<Unit>(
                "ssh.host_exists",
                "Host \"" + value.name +
                    "\" already exists in " + path,
                path
            )
        }
        let updated = ArrayList<ProductSshHost>()
        updated.add(all: existing)
        updated.add(value)
        write(path, updated.toArray())
    }

    func remove(scope: String, name: String): Result<Unit> {
        let path = pathFor(scope)
        let existing = match (read(path)) {
            case Result.Ok(hosts) => hosts
            case Result.Err(error) => return Result<Unit>.Err(error)
        }
        var found = false
        let updated = ArrayList<ProductSshHost>()
        for (host in existing) {
            if (host.name == name) {
                found = true
            } else {
                updated.add(host)
            }
        }
        if (!found) {
            return sshConfigError<Unit>(
                "ssh.host_not_found",
                "Host \"" + name + "\" not found in " + path,
                path
            )
        }
        write(path, updated.toArray())
    }

    private func pathFor(scope: String): String {
        if (scope == "user") { userPath } else { projectPath }
    }

    private func read(path: String): Result<Array<ProductSshHost>> {
        if (!exists(Path(path))) { return Result.Ok([]) }
        let root = match (decodeAgentValue(
            try {
                String.fromUtf8(File.readFrom(path))
            } catch (error: Exception) {
                return sshConfigError<Array<ProductSshHost>>(
                    "ssh.config_read_failed",
                    error.message,
                    path
                )
            },
            maxBytes: 1048576
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                return sshConfigError<Array<ProductSshHost>>(
                    "ssh.config_parse_failed",
                    "Failed to parse SSH config file " + path +
                        ": " + error.message,
                    path
                )
        }
        let hostsValue = match (root.field("hosts")) {
            case Some(value) => value
            case None => return Result.Ok([])
        }
        if (hostsValue.unifiedKind != ValueKind.Object) {
            return sshConfigError<Array<ProductSshHost>>(
                "ssh.config_invalid",
                "SSH config hosts must be an object",
                path
            )
        }
        let hosts = ArrayList<ProductSshHost>()
        for (field in hostsValue.fields) {
            let value = field.value
            if (value.unifiedKind != ValueKind.Object) {
                return sshConfigError<Array<ProductSshHost>>(
                    "ssh.config_invalid",
                    "SSH host \"" + field.name +
                        "\" must be an object",
                    path
                )
            }
            let address = sshTextField(value, "host")
            if (address == "") {
                return sshConfigError<Array<ProductSshHost>>(
                    "ssh.config_invalid",
                    "SSH host \"" + field.name +
                        "\" requires host",
                    path
                )
            }
            hosts.add(ProductSshHost(
                field.name,
                address,
                username: sshTextField(value, "username"),
                port: sshPortField(value),
                keyPath: sshTextField(value, "keyPath"),
                description: sshTextField(value, "description"),
                compat: sshBoolField(value, "compat")
            ))
        }
        Result.Ok(hosts.toArray())
    }

    private func write(
        path: String,
        hosts: Array<ProductSshHost>
    ): Result<Unit> {
        try {
            let parent = Path(path).parent
            if (!exists(parent)) {
                Directory.create(parent, recursive: true)
            }
            let fields = ArrayList<ValueField>()
            for (host in hosts) {
                fields.add(ValueField(
                    host.name,
                    sshHostValue(host)
                ))
            }
            let source = encodeAgentValue(objectValue([
                ValueField("hosts", objectValue(fields.toArray()))
            ]))
            let temporary = path + ".tmp"
            try {
                File.writeTo(temporary, source.toArray())
                rename(temporary, to: path, overwrite: true)
            } catch (error: Exception) {
                try {
                    let _ = removeIfExists(temporary)
                } catch (_: Exception) {}
                throw error
            }
            Result.Ok(())
        } catch (error: Exception) {
            sshConfigError<Unit>(
                "ssh.config_write_failed",
                error.message,
                path
            )
        }
    }
}

func validateSshHostName(name: String): ?String {
    if (name == "") { return Some("Host name cannot be empty") }
    if (name.size > 100) {
        return Some("Host name is too long (max 100 characters)")
    }
    for (rune in name.runes()) {
        if (!(
            (rune >= r'a' && rune <= r'z') ||
            (rune >= r'A' && rune <= r'Z') ||
            (rune >= r'0' && rune <= r'9') ||
            rune == r'_' || rune == r'.' || rune == r'-'
        )) {
            return Some(
                "Host name can only contain letters, numbers, " +
                    "dash, underscore, and dot"
            )
        }
    }
    None
}

func sshHostValue(host: ProductSshHost): AgentValue {
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("host", textValue(host.host)))
    if (host.username != "") {
        fields.add(ValueField("username", textValue(host.username)))
    }
    match (host.port) {
        case Some(value) =>
            fields.add(ValueField("port", integerValue(value)))
        case None => ()
    }
    if (host.keyPath != "") {
        fields.add(ValueField("keyPath", textValue(host.keyPath)))
    }
    if (host.description != "") {
        fields.add(ValueField(
            "description",
            textValue(host.description)
        ))
    }
    if (host.compat) {
        fields.add(ValueField("compat", boolValue(true)))
    }
    objectValue(fields.toArray())
}

func sshTextField(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(item) =>
            if (item.unifiedKind == ValueKind.Text) { item.text } else { "" }
        case None => ""
    }
}

func sshBoolField(value: AgentValue, name: String): Bool {
    match (value.field(name)) {
        case Some(item) =>
            item.unifiedKind == ValueKind.Boolean && item.boolean
        case None => false
    }
}

func sshPortField(value: AgentValue): ?Int64 {
    match (value.field("port")) {
        case Some(item) =>
            if (item.unifiedKind != ValueKind.Number) { return None }
            try {
                Some(Int64.parse(item.number))
            } catch (_: Exception) {
                None
            }
        case None => None
    }
}

func sshConfigError<T>(
    code: String,
    message: String,
    path: String
): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.InvalidInput,
        code,
        message,
        fields: [ErrorField("path", path)]
    ))
}
