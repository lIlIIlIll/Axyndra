package agent_product

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_ports.*
import tool_runtime.*
import std.collection.*
import std.convert.*

import std.fs.*
import std.env.*

class GithubRemoteEndpoint {
    let scheme: String
    let host: String
    let port: UInt16

    init(scheme: String, host: String, port: UInt16) {
        this.scheme = scheme
        this.host = host
        this.port = port
    }
}

public class ProductGithubRuntime {
    private let processes: ProcessPort
    private let ghExecutable: String
    private let gitExecutable: String

    public init(
        processes: ProcessPort,
        ghExecutable!: String = "",
        gitExecutable!: String = ""
    ) {
        this.processes = processes
        this.ghExecutable = if (ghExecutable != "") {
            ghExecutable
        } else {
            resolveExecutable(["/usr/bin/gh", "/usr/local/bin/gh"], "gh")
        }
        this.gitExecutable = if (gitExecutable != "") {
            gitExecutable
        } else {
            resolveExecutable(
                ["/usr/bin/git", "/usr/local/bin/git"],
                "git"
            )
        }
    }

    public func execute(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolResult> {
        let call = ToolCall(
            prepared.call.callId,
            prepared.call.name,
            prepared.operationPlan.canonicalArguments
        )
        let op = match (requiredString(call, "op")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (op) {
            case "repo_view" => runGh(
                context, prepared, call, repoViewArguments(call)
            )
            case "file_read" => fileRead(context, prepared, call)
            case "pr_create" => runGh(
                context, prepared, call, prCreateArguments(call)
            )
            case "pr_checkout" => prCheckout(context, prepared, call)
            case "pr_push" => prPush(context, prepared, call)
            case "search_issues" => runGh(
                context, prepared, call, searchArguments(call, "issues")
            )
            case "search_prs" => runGh(
                context, prepared, call, searchArguments(call, "prs")
            )
            case "search_code" => runGh(
                context, prepared, call, searchArguments(call, "code")
            )
            case "search_commits" => runGh(
                context, prepared, call, searchArguments(call, "commits")
            )
            case "search_repos" => runGh(
                context, prepared, call, searchArguments(call, "repos")
            )
            case "run_watch" => runWatch(context, prepared, call)
            case _ => githubArgumentError<ToolResult>(
                call,
                "op",
                "unsupported github operation: " + op
            )
        }
    }

    private func fileRead(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation,
        call: ToolCall
    ): Result<ToolResult> {
        let path = match (requiredString(call, "path")) {
            case Result.Ok(value) => value.trimAscii()
            case Result.Err(error) => return Result.Err(error)
        }
        if (!safeRepositoryPath(path)) {
            return githubArgumentError<ToolResult>(
                call,
                "path",
                "path must be a safe repository-relative path"
            )
        }
        let repo = match (resolveRepo(context, prepared, call)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        var endpoint = "repos/" + repo + "/contents/" + path
        let branch = optionalString(call, "branch", "").trimAscii()
        if (branch != "") {
            endpoint += "?ref=" + branch
        }
        runGh(
            context,
            prepared,
            call,
            [
                "api",
                endpoint,
                "-H",
                "Accept: application/vnd.github.raw+json"
            ]
        )
    }

    private func prCheckout(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation,
        call: ToolCall
    ): Result<ToolResult> {
        let targets = match (githubPullRequests(call)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        var combined = ""
        for (target in targets) {
            let arguments = ArrayList<String>()
            arguments.add("pr")
            arguments.add("checkout")
            arguments.add(target)
            appendRepo(arguments, call)
            if (optionalBoolean(call, "force", false)) {
                arguments.add("--force")
            }
            let result = match (executeProcess(
                context,
                prepared,
                call,
                ghExecutable,
                arguments.toArray(),
                300000
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            if (result.exitCode != 0) {
                return githubProcessError<ToolResult>(
                    call,
                    result,
                    ghExecutable,
                    arguments.toArray()
                )
            }
            if (combined != "") { combined += "\n" }
            combined += result.stdout.trimAscii()
        }
        Result.Ok(githubResult(
            call,
            "pr_checkout",
            combined,
            0,
            "",
            targets
        ))
    }

    private func prPush(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation,
        call: ToolCall
    ): Result<ToolResult> {
        let remote = match (pushRemoteEndpoint(context, prepared, call)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (remote.scheme != "https") {
            return githubArgumentError<ToolResult>(
                call,
                "origin",
                "pr_push requires an HTTPS origin; SSH and non-HTTPS remotes have no approved proxy connector"
            )
        }
        if (!githubNetworkPolicyAllows(
            prepared.operationPlan.networkPolicy,
            remote.host,
            remote.port
        )) {
            return githubArgumentError<ToolResult>(
                call,
                "origin",
                "the actual HTTPS origin is not covered by the frozen GitHub egress policy"
            )
        }
        let arguments = ArrayList<String>()
        // Keep authentication inside the sandbox. The gh credential helper
        // consumes only the explicitly granted GH/GitHub token variables.
        arguments.add("-c")
        arguments.add(
            "credential.helper=!" + ghExecutable + " auth git-credential"
        )
        arguments.add("push")
        if (optionalBoolean(call, "forceWithLease", false)) {
            arguments.add("--force-with-lease")
        }
        arguments.add("--set-upstream")
        arguments.add("origin")
        let branch = optionalString(call, "branch", "").trimAscii()
        if (branch != "") { arguments.add(branch) }
        let result = match (executeProcess(
            context,
            prepared,
            call,
            gitExecutable,
            arguments.toArray(),
            300000
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (result.exitCode != 0) {
            return githubProcessError<ToolResult>(
                call,
                result,
                gitExecutable,
                arguments.toArray()
            )
        }
        Result.Ok(githubResult(
            call,
            "pr_push",
            result.stdout.trimAscii(),
            result.exitCode,
            result.stderr.trimAscii(),
            []
        ))
    }

    private func runWatch(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation,
        call: ToolCall
    ): Result<ToolResult> {
        let run = match (requiredString(call, "run")) {
            case Result.Ok(value) => value.trimAscii()
            case Result.Err(error) => return Result.Err(error)
        }
        if (run == "") {
            return githubArgumentError<ToolResult>(
                call,
                "run",
                "run id or URL must not be empty"
            )
        }
        let arguments = ArrayList<String>()
        arguments.add("run")
        arguments.add("watch")
        arguments.add(run)
        arguments.add("--exit-status")
        appendRepo(arguments, call)
        runGh(
            context,
            prepared,
            call,
            arguments.toArray(),
            timeoutMillis: 1800000
        )
    }

    private func resolveRepo(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation,
        call: ToolCall
    ): Result<String> {
        let explicit = optionalString(call, "repo", "").trimAscii()
        if (explicit != "") { return Result.Ok(explicit) }
        let result = match (executeProcess(
            context,
            prepared,
            call,
            ghExecutable,
            [
                "repo", "view",
                "--json", "nameWithOwner",
                "--jq", ".nameWithOwner"
            ],
            60000
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (result.exitCode != 0 ||
            result.stdout.trimAscii() == "") {
            return githubProcessError<String>(
                call,
                result,
                ghExecutable,
                ["repo", "view"]
            )
        }
        Result.Ok(result.stdout.trimAscii())
    }

    private func runGh(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation,
        call: ToolCall,
        arguments: Array<String>,
        timeoutMillis!: Int64 = 120000
    ): Result<ToolResult> {
        let result = match (executeProcess(
            context,
            prepared,
            call,
            ghExecutable,
            arguments,
            timeoutMillis
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (result.exitCode != 0) {
            return githubProcessError<ToolResult>(
                call,
                result,
                ghExecutable,
                arguments
            )
        }
        Result.Ok(githubResult(
            call,
            optionalString(call, "op", ""),
            result.stdout.trimAscii(),
            result.exitCode,
            result.stderr.trimAscii(),
            []
        ))
    }

    private func pushRemoteEndpoint(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation,
        call: ToolCall
    ): Result<GithubRemoteEndpoint> {
        let result = match (executeProcess(
            context,
            prepared,
            call,
            gitExecutable,
            ["remote", "get-url", "origin"],
            30000
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (result.exitCode != 0) {
            return githubProcessError<GithubRemoteEndpoint>(
                call,
                result,
                gitExecutable,
                ["remote", "get-url", "origin"]
            )
        }
        parseGithubRemoteEndpoint(result.stdout)
    }

    private func executeProcess(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation,
        call: ToolCall,
        executable: String,
        arguments: Array<String>,
        timeoutMillis: Int64
    ): Result<ProcessResult> {
        let _ = context
        let operation = optionalString(call, "op", "")
        processes.execute(ProcessRequest(
            executable,
            operationId: prepared.operationId,
            arguments: arguments,
            timeoutMillis: timeoutMillis,
            sandboxMode: if (githubWorkspaceWriteOperation(operation)) {
                ProcessSandboxMode.WorkspaceReadWrite
            } else {
                ProcessSandboxMode.WorkspaceReadOnly
            },
            networkPolicy: Some(prepared.operationPlan.networkPolicy),
            environmentAllowlist: ["GH_HOST"],
            secretEnvironmentAllowlist: githubSecretEnvironment()
        ))
    }
}

class GithubTool <: ToolExecutor {
    private let runtime: ProductGithubRuntime

    init(runtime: ProductGithubRuntime) { this.runtime = runtime }

    public func execute(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolResult> {
        runtime.execute(context, prepared)
    }
}

func githubToolDefinition(): ModelToolDefinition {
    ModelToolDefinition(
        "github",
        "Interact with GitHub repositories, files, pull requests, and Actions.",
        objectSchema([
            schemaEnumProperty(
                "op",
                [
                    "repo_view", "file_read", "pr_create",
                    "pr_checkout", "pr_push", "search_issues",
                    "search_prs", "search_code", "search_commits",
                    "search_repos", "run_watch"
                ]
            ),
            schemaProperty("repo", "string"),
            schemaProperty("branch", "string"),
            schemaProperty("path", "string"),
            githubPrSchemaProperty(),
            schemaProperty("force", "boolean"),
            schemaProperty("forceWithLease", "boolean"),
            schemaProperty("title", "string"),
            schemaProperty("body", "string"),
            schemaProperty("base", "string"),
            schemaProperty("head", "string"),
            schemaProperty("draft", "boolean"),
            schemaProperty("fill", "boolean"),
            schemaStringListProperty("reviewer"),
            schemaStringListProperty("assignee"),
            schemaStringListProperty("label"),
            schemaProperty("query", "string"),
            schemaProperty("since", "string"),
            schemaProperty("until", "string"),
            schemaEnumProperty("dateField", ["created", "updated"]),
            schemaProperty("limit", "number"),
            schemaProperty("run", "string"),
            schemaProperty("tail", "number")
        ], ["op"])
    )
}

func githubRemoteError<T>(message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput, "tool.github_remote_invalid", message))
}

func githubRemotePort(value: String, fallback: UInt16): Result<UInt16> {
    if (value == "") { return Result.Ok(fallback) }
    try {
        let parsed = Int64.parse(value)
        if (parsed < 1 || parsed > 65535 || parsed.toString() != value) {
            return githubRemoteError<UInt16>("Git remote has an invalid port")
        }
        Result.Ok(UInt16(parsed))
    } catch (_: Exception) {
        githubRemoteError<UInt16>("Git remote has an invalid port")
    }
}

func githubRemoteUrlEndpoint(
    scheme: String,
    authority: String,
    defaultPort: UInt16
): Result<GithubRemoteEndpoint> {
    let userHost = match (authority.indexOf("@")) {
        case Some(index) => authority[index + 1..]
        case None => authority
    }
    if (userHost == "") {
        return githubRemoteError<GithubRemoteEndpoint>("Git remote has an empty host")
    }
    let host: String
    let portText: String
    if (userHost.startsWith("[")) {
        let close = match (userHost.indexOf("]")) {
            case Some(index) => index
            case None => return githubRemoteError<GithubRemoteEndpoint>(
                "Git remote has an invalid IPv6 authority"
            )
        }
        if (close <= 1) {
            return githubRemoteError<GithubRemoteEndpoint>("Git remote has an empty host")
        }
        host = userHost[1..close]
        let suffix = userHost[close + 1..]
        if (suffix == "") {
            portText = ""
        } else if (suffix.startsWith(":")) {
            portText = suffix[1..]
        } else {
            return githubRemoteError<GithubRemoteEndpoint>("Git remote has an invalid authority")
        }
    } else {
        let parts = userHost.split(":")
        if (parts.isEmpty() || parts.size > 2 || parts[0] == "") {
            return githubRemoteError<GithubRemoteEndpoint>(
                "Git remote IPv6 hosts must use brackets"
            )
        }
        host = parts[0]
        portText = if (parts.size == 2) { parts[1] } else { "" }
    }
    let port = match (githubRemotePort(portText, defaultPort)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    try {
        let normalized = NetworkEgressRule(host, port)
        Result.Ok(GithubRemoteEndpoint(scheme, normalized.host, normalized.port))
    } catch (error: Exception) {
        githubRemoteError<GithubRemoteEndpoint>(error.message)
    }
}

func parseGithubRemoteEndpoint(remote: String): Result<GithubRemoteEndpoint> {
    let value = remote.trimAscii()
    if (value == "") {
        return githubRemoteError<GithubRemoteEndpoint>("Git remote must be a single endpoint")
    }
    var scheme = ""
    var schemeLength: Int64 = 0
    var defaultPort: UInt16 = 0u16
    if (value.startsWith("https://")) {
        scheme = "https"
        schemeLength = 8
        defaultPort = 443u16
    } else if (value.startsWith("http://")) {
        scheme = "http"
        schemeLength = 7
        defaultPort = 80u16
    } else if (value.startsWith("ssh://")) {
        scheme = "ssh"
        schemeLength = 6
        defaultPort = 22u16
    } else {
        match (value.indexOf(":")) {
            case Some(index) =>
                let left = value[..index]
                let path = value[index + 1..]
                let host = match (left.indexOf("@")) {
                    case Some(at) => left[at + 1..]
                    case None => left
                }
                if (host == "" || path == "" || host.contains("/")) {
                    return githubRemoteError<GithubRemoteEndpoint>(
                        "Git remote has an invalid SSH scp-style endpoint"
                    )
                }
                return githubRemoteUrlEndpoint("ssh", host + ":22", 22u16)
            case None => return githubRemoteError<GithubRemoteEndpoint>(
                "Git remote must use HTTPS or SSH"
            )
        }
    }
    var authorityEnd = value.size
    let remainder = value[schemeLength..]
    for (marker in ["/", "?", "#"]) {
        match (remainder.indexOf(marker)) {
            case Some(index) =>
                let absolute = schemeLength + index
                if (absolute < authorityEnd) { authorityEnd = absolute }
            case None => ()
        }
    }
    if (authorityEnd <= schemeLength) {
        return githubRemoteError<GithubRemoteEndpoint>("Git remote has an empty authority")
    }
    githubRemoteUrlEndpoint(
        scheme,
        value[schemeLength..authorityEnd],
        defaultPort
    )
}

func githubNetworkPolicyAllows(
    policy: NetworkPolicy,
    host: String,
    port: UInt16
): Bool {
    for (rule in policy.egress where rule.host == host && rule.port == port) {
        return true
    }
    false
}

func githubNetworkPolicy(operation: String, repo!: String = ""): NetworkPolicy {
    let apiOnly = match (operation) {
        case "repo_view" | "file_read" | "pr_create" | "search_issues" |
            "search_prs" | "search_code" | "search_commits" |
            "search_repos" | "run_watch" => true
        case _ => false
    }
    // gh accepts HOST/OWNER/REPO in --repo. owner/repo uses the public
    // forge, which is the only default available before execution.
    let host = githubRepositoryHost(repo)
    let apiHost = if (host == "github.com") { "api.github.com" } else { host }
    let egress = ArrayList<NetworkEgressRule>()
    egress.add(NetworkEgressRule(apiHost, 443u16))
    if (operation == "pr_push" || !apiOnly) {
        if (host != apiHost) { egress.add(NetworkEgressRule(host, 443u16)) }
    }
    if (!apiOnly && operation != "pr_push" && host == "github.com") {
        egress.add(NetworkEgressRule("raw.githubusercontent.com", 443u16))
        egress.add(NetworkEgressRule("objects.githubusercontent.com", 443u16))
    }
    NetworkPolicy(NetworkPolicyMode.Mediated, egress: egress.toArray())
}

func githubConfiguredForgeHost(): String {
    match (getVariable("GH_HOST")) {
        case Some(value) =>
            let host = value.trimAscii()
            if (host != "" && !host.contains("/") && !host.contains(" ")) {
                host
            } else {
                ""
            }
        case None => ""
    }
}

func githubRepositoryHost(repo: String): String {
    let parts = repo.trimAscii().split("/")
    if (parts.size >= 3 && parts[0].trimAscii() != "") {
        return parts[0].trimAscii()
    }
    let configured = githubConfiguredForgeHost()
    if (configured != "") { return configured }
    "github.com"
}
func githubCapabilityFor(call: ToolCall): Capability {
    let operation = optionalString(call, "op", "")
    let resources = networkPolicyCapabilityResources(githubNetworkPolicy(
        operation,
        repo: optionalString(call, "repo", "")
    ))
    Capability(
        CapabilityKind.NetworkAccess,
        resource: if (resources.isEmpty()) { "" } else { resources[0] }
    )
}

func githubAdditionalCapabilities(call: ToolCall): Array<Capability> {
    if (githubWorkspaceWriteOperation(optionalString(call, "op", ""))) {
        [Capability(CapabilityKind.WorkspaceWrite)]
    } else {
        []
    }
}

func githubSideEffecting(call: ToolCall): Bool {
    !githubReadOnlyOperation(optionalString(call, "op", ""))
}

func githubReadOnlyOperation(op: String): Bool {
    match (op) {
        case "repo_view" | "file_read" | "search_issues" |
            "search_prs" | "search_code" | "search_commits" |
            "search_repos" | "run_watch" => true
        case _ => false
    }
}

func githubWorkspaceWriteOperation(op: String): Bool {
    op == "pr_checkout" || op == "pr_push"
}

func githubSecretEnvironment(): Array<String> {
    [
        "GH_TOKEN",
        "GITHUB_TOKEN",
        "GH_ENTERPRISE_TOKEN",
        "GITHUB_ENTERPRISE_TOKEN"
    ]
}

func repoViewArguments(call: ToolCall): Array<String> {
    let arguments = ArrayList<String>()
    arguments.add("repo")
    arguments.add("view")
    let repo = optionalString(call, "repo", "").trimAscii()
    if (repo != "") { arguments.add(repo) }
    let branch = optionalString(call, "branch", "").trimAscii()
    if (branch != "") {
        arguments.add("--branch")
        arguments.add(branch)
    }
    arguments.add("--json")
    arguments.add(
        "nameWithOwner,description,url,defaultBranchRef,visibility," +
            "isPrivate,homepageUrl,owner"
    )
    arguments.toArray()
}

func prCreateArguments(call: ToolCall): Array<String> {
    let arguments = ArrayList<String>()
    arguments.add("pr")
    arguments.add("create")
    appendRepo(arguments, call)
    appendStringOption(arguments, call, "title", "--title")
    appendStringOption(arguments, call, "body", "--body")
    appendStringOption(arguments, call, "base", "--base")
    appendStringOption(arguments, call, "head", "--head")
    if (optionalBoolean(call, "draft", false)) {
        arguments.add("--draft")
    }
    if (optionalBoolean(call, "fill", false)) {
        arguments.add("--fill")
    }
    appendRepeatedOption(arguments, call, "reviewer", "--reviewer")
    appendRepeatedOption(arguments, call, "assignee", "--assignee")
    appendRepeatedOption(arguments, call, "label", "--label")
    arguments.toArray()
}

func searchArguments(call: ToolCall, kind: String): Array<String> {
    let arguments = ArrayList<String>()
    arguments.add("search")
    arguments.add(kind)
    var query = optionalString(call, "query", "").trimAscii()
    let dateField = optionalString(call, "dateField", "created")
    let since = optionalString(call, "since", "").trimAscii()
    let until = optionalString(call, "until", "").trimAscii()
    if (since != "") {
        query += " " + dateField + ":>=" + since
    }
    if (until != "") {
        query += " " + dateField + ":<=" + until
    }
    if (query != "") { arguments.add(query.trimAscii()) }
    appendRepo(arguments, call)
    arguments.add("--limit")
    arguments.add(optionalInteger(call, "limit", 30).toString())
    arguments.add("--json")
    arguments.add(githubSearchFields(kind))
    arguments.toArray()
}

func githubSearchFields(kind: String): String {
    match (kind) {
        case "issues" | "prs" =>
            "number,title,state,url,author,createdAt,updatedAt,repository"
        case "code" => "path,repository,sha,textMatches,url"
        case "commits" =>
            "sha,message,author,date,repository,url"
        case "repos" =>
            "nameWithOwner,description,url,visibility,updatedAt"
        case _ => "url"
    }
}

func githubPullRequests(call: ToolCall): Result<Array<String>> {
    match (call.arguments.field("pr")) {
        case Some(value) =>
            if (value.unifiedKind == ValueKind.Text &&
                value.text.trimAscii() != "") {
                Result.Ok([value.text.trimAscii()])
            } else if (value.unifiedKind == ValueKind.List &&
                value.items.size > 0) {
                let targets = ArrayList<String>()
                for (item in value.items) {
                    if (item.unifiedKind != ValueKind.Text ||
                        item.text.trimAscii() == "") {
                        return githubArgumentError<Array<String>>(
                            call,
                            "pr",
                            "pr list must contain non-empty strings"
                        )
                    }
                    targets.add(item.text.trimAscii())
                }
                Result.Ok(targets.toArray())
            } else {
                githubArgumentError<Array<String>>(
                    call,
                    "pr",
                    "pr must be a number, URL, branch, or non-empty list"
                )
            }
        case None => githubArgumentError<Array<String>>(
            call,
            "pr",
            "pr is required for pr_checkout"
        )
    }
}

func appendRepo(arguments: ArrayList<String>, call: ToolCall): Unit {
    appendStringOption(arguments, call, "repo", "--repo")
}

func appendStringOption(
    arguments: ArrayList<String>,
    call: ToolCall,
    name: String,
    option: String
): Unit {
    let value = optionalString(call, name, "").trimAscii()
    if (value != "") {
        arguments.add(option)
        arguments.add(value)
    }
}

func appendRepeatedOption(
    arguments: ArrayList<String>,
    call: ToolCall,
    name: String,
    option: String
): Unit {
    match (call.arguments.field(name)) {
        case Some(value) =>
            if (value.unifiedKind == ValueKind.List) {
                for (item in value.items where
                     item.unifiedKind == ValueKind.Text &&
                     item.text.trimAscii() != "") {
                    arguments.add(option)
                    arguments.add(item.text.trimAscii())
                }
            }
        case None => ()
    }
}

func githubPrSchemaProperty(): ValueField {
    ValueField("pr", objectValue([
        ValueField("anyOf", listValue([
            objectValue([
                ValueField("type", textValue("string"))
            ]),
            objectValue([
                ValueField("type", textValue("array")),
                ValueField("items", objectValue([
                    ValueField("type", textValue("string"))
                ]))
            ])
        ]))
    ]))
}

func githubResult(
    call: ToolCall,
    op: String,
    stdout: String,
    exitCode: Int64,
    stderr: String,
    targets: Array<String>
): ToolResult {
    let targetValues = ArrayList<AgentValue>()
    for (target in targets) { targetValues.add(textValue(target)) }
    ToolResult(
        call.callId,
        objectValue([
            ValueField(
                "content",
                textValue(
                    if (stdout == "") {
                        "GitHub operation completed."
                    } else {
                        stdout
                    }
                )
            ),
            ValueField("op", textValue(op)),
            ValueField("exitCode", integerValue(exitCode)),
            ValueField("stderr", textValue(stderr)),
            ValueField("targets", listValue(targetValues.toArray()))
        ])
    )
}

func githubProcessError<T>(
    call: ToolCall,
    result: ProcessResult,
    executable: String,
    arguments: Array<String>
): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.Transport,
        "tool.github_process_failed",
        if (result.stderr.trimAscii() == "") {
            "GitHub command failed with exit code " +
                result.exitCode.toString()
        } else {
            result.stderr.trimAscii()
        },
        fields: [
            ErrorField("tool", call.name),
            ErrorField("executable", executable),
            ErrorField("exitCode", result.exitCode.toString()),
            ErrorField("arguments", joinGithubArguments(arguments))
        ]
    ))
}

func githubArgumentError<T>(
    call: ToolCall,
    argument: String,
    message: String
): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.InvalidInput,
        "tool.github_invalid_argument",
        message,
        fields: [
            ErrorField("tool", call.name),
            ErrorField("argument", argument)
        ]
    ))
}

func joinGithubArguments(arguments: Array<String>): String {
    var text = ""
    for (argument in arguments) {
        if (text != "") { text += " " }
        text += argument
    }
    text
}

func safeRepositoryPath(path: String): Bool {
    if (path == "" || path.startsWith("/")) { return false }
    for (part in path.split("/") where
         part == "" || part == "." || part == "..") {
        return false
    }
    true
}

func safeOperationPart(value: String): String {
    let output = ArrayList<Byte>()
    for (byte in unsafe { value.rawData() }) {
        let allowed = (byte >= b'a' && byte <= b'z') ||
            (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') ||
            byte == b'-' || byte == b'_'
        output.add(if (allowed) { byte } else { b'_' })
    }
    if (output.isEmpty()) { "call" } else {
        String.fromUtf8(output.toArray())
    }
}

func resolveExecutable(paths: Array<String>, fallback: String): String {
    for (path in paths where exists(Path(path))) { return path }
    fallback
}
