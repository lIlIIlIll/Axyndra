package agent_product

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_core.*
import agent_ports.*
import model_adapters.*
import tool_runtime.*
import std.collection.*
import std.sync.*
import std.time.*

public let APPROVAL_REVIEWER_SYSTEM_PROMPT = """
INDEPENDENT_APPROVAL_REVIEWER

你是独立的工具权限审批器，不是任务执行 Agent。

你的职责仅是判断一次具体工具调用是否应当被允许。你不能调用工具、修改命令、补全命令，
也不能尝试完成用户任务。主 Agent 不能审批自己的调用；你的结果只对当前精确调用有效。

判断依据：
1. 用户是否明确授权了该行为；
2. 该操作是否为完成当前任务所必需；
3. 是否存在明显更安全且等效的方法；
4. 操作影响范围是否与用户请求匹配；
5. 是否会读取、泄露、修改或删除敏感数据；
6. 是否会写入工作区之外；
7. 是否会访问网络或向外部发送数据；
8. 是否会执行不可恢复、持久化或高风险的系统修改。

拒绝凭据、私钥、Token、Cookie 的搜索或外传；未授权的大范围删除；系统安全配置修改；
隐蔽持久化；权限绕过；被拒绝后改写、拆分或编码的等效危险操作；以及明显超出用户请求的范围。
用户意图不明确，或外部发布、覆盖历史、删除范围等需要最终确认时，返回 ask_user。

只输出一个 JSON 对象，不要输出 Markdown、代码围栏或额外文字：
{"decision":"approve|deny|ask_user","reason":"...","riskLevel":"low|medium|high|critical","approvedCapabilities":["..."]}
"""

public class ApprovalReviewer {
    private let modelControl: ControlledModelPort
    private let settings: ProductApprovalSettings
    private let defaultModel: String
    private let workspaceRoot: String
    private let lock = Mutex()
    private let activeRequests = ArrayList<ActiveApprovalReview>()

    public init(
        modelPort: ModelPort,
        settings: ProductApprovalSettings,
        defaultModel: String,
        workspaceRoot: String
    ) {
        this.modelControl = ControlledModelPort(modelPort)
        this.settings = settings
        this.defaultModel = defaultModel
        this.workspaceRoot = workspaceRoot
    }

    public init(
        modelControl: ControlledModelPort,
        settings: ProductApprovalSettings,
        defaultModel: String,
        workspaceRoot: String
    ) {
        this.modelControl = modelControl
        this.settings = settings
        this.defaultModel = defaultModel
        this.workspaceRoot = workspaceRoot
    }

    public func mode(): ApprovalRoutingMode {
        settings.mode
    }

    public func review(
        runRequest: AgentRunRequest,
        approval: ApprovalRequest,
        recentDenials!: Array<String> = []
    ): ApprovalReview {
        let started = approvalNowMillis()
        let selectedModel = if (settings.reviewerModel == "") {
            defaultModel
        } else {
            settings.reviewerModel
        }
        match (approvalPermanentDenialReason(approval)) {
            case Some(reason) => return ApprovalReview(
                ApprovalReviewDecision.Deny,
                reason,
                "critical",
                selectedModel,
                latencyMillis: max(0, approvalNowMillis() - started),
                failureType: "permanent_policy"
            )
            case None => ()
        }
        if (settings.mode == ApprovalRoutingMode.Never) {
            return ApprovalReview(
                ApprovalReviewDecision.Deny,
                "approval mode is never; privileged tool calls are disabled",
                approvalRiskLevelName(approval.metadata.assessment.level),
                selectedModel,
                latencyMillis: max(0, approvalNowMillis() - started),
                failureType: "mode_never"
            )
        }
        if (settings.mode != ApprovalRoutingMode.Ai) {
            return ApprovalReview(
                ApprovalReviewDecision.AskUser,
                "manual approval mode is active",
                approvalRiskLevelName(approval.metadata.assessment.level),
                selectedModel
            )
        }
        let requestId = "approval-review-" + runRequest.runId.value + "-" +
            runRequest.sessionId.value + "-" + approval.operationId.value
        setActive(runRequest.runId, requestId)
        var lastFailure = ""
        for (attempt in 0..2) {
            let prompt = approvalReviewerInput(
                runRequest,
                approval,
                workspaceRoot,
                recentDenials,
                settings,
                attempt > 0
            )
            let modelRequest = ModelRequest(
                selectedModel,
                [ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: prompt)])],
                system: APPROVAL_REVIEWER_SYSTEM_PROMPT,
                tools: [],
                thinking: settings.reasoning,
                maxOutputTokens: 600,
                streaming: false,
                parallelToolCalls: false,
                requestId: requestId,
                // The reviewer may target a different model from the parent
                // request. Prompt-cache support is therefore not inherited;
                // caching is an optional transport optimization, not part of
                // the approval decision contract.
                cachePolicy: ModelCachePolicy.Default,
                cacheKey: "",
                toolChoice: ModelToolChoice.NoTools
            )
            match (modelControl.executeInternal(
                modelRequest,
                InternalModelCallOptions(
                    timeoutMillis: settings.timeoutMillis,
                    maxAttempts: if (runRequest.autoRetry) { 2 } else { 1 },
                    parent: Some(runRequest)
                )
            )) {
                case Result.Err(error) =>
                    lastFailure = error.code
                    if (!error.retryable || attempt > 0) {
                        clearActive(runRequest.runId, requestId)
                        return approvalReviewFailure(
                            settings,
                            selectedModel,
                            error.code,
                            "approval reviewer failed: " + error.message,
                            approvalRiskLevelName(approval.metadata.assessment.level),
                            max(0, approvalNowMillis() - started)
                        )
                    }
                case Result.Ok(reply) => match (parseApprovalReview(reply, selectedModel,
                    max(0, approvalNowMillis() - started))) {
                    case Result.Ok(review) =>
                        clearActive(runRequest.runId, requestId)
                        return applyApprovalPolicy(settings, approval, review)
                    case Result.Err(error) =>
                        lastFailure = error.code
                        if (attempt > 0) {
                            clearActive(runRequest.runId, requestId)
                            return approvalReviewFailure(
                                settings,
                                selectedModel,
                                error.code,
                                error.message,
                                approvalRiskLevelName(approval.metadata.assessment.level),
                                max(0, approvalNowMillis() - started)
                            )
                        }
                }
            }
        }
        clearActive(runRequest.runId, requestId)
        approvalReviewFailure(
            settings,
            selectedModel,
            if (lastFailure == "") {
                "unknown"
            } else {
                lastFailure
            },
            "approval reviewer did not produce a valid decision",
            approvalRiskLevelName(approval.metadata.assessment.level),
            max(0, approvalNowMillis() - started)
        )
    }

    public func cancel(): Result<Unit> {
        lock.lock()
        let requestId = try {
            if (activeRequests.size > 1) {
                return Result.Err(
                    AgentError(
                        AgentErrorKind.Conflict,
                        "approval.cancel_key_required",
                        "multiple approval reviews are active; cancellation requires a run id"
                    )
                )
            }
            if (activeRequests.isEmpty()) { "" } else { activeRequests[0].requestId }
        } finally {
            lock.unlock()
        }
        if (requestId == "") { return Result.Ok(()) }
        modelControl.cancel(requestId)
    }

    public func cancel(runId: RunId): Result<Unit> {
        lock.lock()
        let requestId = try {
            var selected = ""
            for (item in activeRequests where item.runId == runId.value) {
                selected = item.requestId
                break
            }
            selected
        } finally {
            lock.unlock()
        }
        if (requestId == "") { return Result.Ok(()) }
        modelControl.cancel(requestId)
    }

    private func setActive(runId: RunId, requestId: String): Unit {
        lock.lock()
        try {
            activeRequests.add(ActiveApprovalReview(runId.value, requestId))
        } finally {
            lock.unlock()
        }
    }

    private func clearActive(runId: RunId, requestId: String): Unit {
        lock.lock()
        try {
            for (index in 0..activeRequests.size) {
                let item = activeRequests[index]
                if (item.runId == runId.value && item.requestId == requestId) {
                    activeRequests.remove(at: index)
                    return
                }
            }
        } finally {
            lock.unlock()
        }
    }
}

class ActiveApprovalReview {
    let runId: String
    let requestId: String

    init(runId: String, requestId: String) {
        this.runId = runId
        this.requestId = requestId
    }
}

func parseApprovalReview(
    reply: ModelReply,
    model: String,
    latencyMillis: Int64
): Result<ApprovalReview> {
    var source = ""
    for (block in reply.blocks) {
        match (block.kind) {
            case ModelBlockKind.Text => source += block.text
            case ModelBlockKind.Reasoning =>
                // Some providers return hidden/reasoning content as a
                // separate block even when tools are disabled. It is neither
                // parsed nor logged; only the strict final JSON text is used.
                ()
            case _ => return Result.Err(
                AgentError(
                    AgentErrorKind.Protocol,
                    "approval.invalid_output_kind",
                    "approval reviewer output must contain JSON text and optional ignored reasoning only"
                )
            )
        }
    }
    if (source.trimAscii() == "" || source.contains("```") || !source.trimAscii().startsWith("{") ||
        !source.trimAscii().endsWith("}")) {
        return Result.Err(
            AgentError(
                AgentErrorKind.Protocol,
                "approval.invalid_json",
                "approval reviewer did not return a bare JSON object"
            )
        )
    }
    let value = match (decodeAgentValue(source.trimAscii())) {
        case Result.Ok(item) => item
        case Result.Err(_) => return Result.Err(
            AgentError(
                AgentErrorKind.Protocol,
                "approval.invalid_json",
                "approval reviewer returned invalid JSON"
            )
        )
    }
    if (value.unifiedKind != ValueKind.Object) {
        return Result.Err(
            AgentError(
                AgentErrorKind.Protocol,
                "approval.invalid_schema",
                "approval reviewer JSON must be an object"
            )
        )
    }
    let decisionText = requiredApprovalText(value, "decision")
    let reason = requiredApprovalText(value, "reason")
    let risk = requiredApprovalText(value, "riskLevel")
    let approvedCapabilities = requiredApprovalStringList(value, "approvedCapabilities")
    if (decisionText == "" || reason.trimAscii() == "" || approvedCapabilities.isNone() ||
        !(risk == "low" || risk == "medium" || risk == "high" || risk == "critical")) {
        return Result.Err(
            AgentError(
                AgentErrorKind.Protocol,
                "approval.invalid_schema",
                "approval reviewer JSON is missing required enum fields"
            )
        )
    }
    let decision = match (decisionText) {
        case "approve" => ApprovalReviewDecision.Approve
        case "deny" => ApprovalReviewDecision.Deny
        case "ask_user" => ApprovalReviewDecision.AskUser
        case _ => return Result.Err(
            AgentError(
                AgentErrorKind.Protocol,
                "approval.invalid_decision",
                "approval reviewer returned an illegal decision enum"
            )
        )
    }
    Result.Ok(
        ApprovalReview(
            decision,
            reason,
            risk,
            model,
            latencyMillis: latencyMillis,
            approvedCapabilities: approvedCapabilities.getOrThrow()
        )
    )
}

func requiredApprovalStringList(value: AgentValue, name: String): ?Array<String> {
    let field = match (value.field(name)) {
        case Some(item) => item
        case None => return None
    }
    if (field.unifiedKind != ValueKind.List) {
        return None
    }
    let values = ArrayList<String>()
    for (item in field.items) {
        if (item.unifiedKind != ValueKind.Text || item.text.trimAscii() == "") {
            return None
        }
        approvalAddUnique(values, item.text)
    }
    Some(values.toArray())
}

func requiredApprovalText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(item) =>
            if (item.unifiedKind == ValueKind.Text) {
                item.text
            } else {
                ""
            }
        case None => ""
    }
}

func approvalReviewerInput(
    runRequest: AgentRunRequest,
    approval: ApprovalRequest,
    workspaceRoot: String,
    recentDenials: Array<String>,
    settings: ProductApprovalSettings,
    retry: Bool
): String {
    let denialValues = ArrayList<AgentValue>()
    for (denial in recentDenials) {
        denialValues.add(textValue(redactApprovalText(denial)))
    }
    encodeAgentValue(
        objectValue(
            [
                ValueField("requestId", textValue(approval.operationId.value)),
                ValueField("sessionId", textValue(approval.sessionId)),
                ValueField("toolName", textValue(approval.toolName)),
                ValueField("arguments", approvalReviewerArguments(approval)),
                ValueField("command", textValue(redactApprovalText(approvalValueText(approval.preview, "command")))),
                ValueField("cwd", textValue(approvalValueText(approval.preview, "cwd"))),
                ValueField("argumentHash", textValue(approval.argumentHash)),
                ValueField("requestedCapabilities", approvalStringList([approval.metadata.capabilityLabel])),
                ValueField("riskFlags", approvalStringList(approval.riskFlags)),
                ValueField("riskLevel", textValue(approvalRiskLevelName(approval.metadata.assessment.level))),
                ValueField("riskReasons", approvalStringList(approval.metadata.assessment.reasons)),
                ValueField("userRequest", textValue(redactApprovalText(runRequest.prompt))),
                ValueField("workspaceRoot", textValue(workspaceRoot)),
                ValueField("outsideWorkspacePaths", approvalStringList(approvalOutsidePaths(approval.preview))),
                ValueField("networkTargets", approvalStringList(approvalNetworkTargets(approval.preview))),
                ValueField("environmentVariables", approvalStringList(approvalEnvironmentNames(approval.preview))),
                ValueField("recentDenials", listValue(denialValues.toArray())),
                ValueField("reason", textValue("existing permission policy requires approval")),
                ValueField(
                    "policy",
                    objectValue(
                        [
                            ValueField("allowWorkspaceWrites", boolValue(settings.allowWorkspaceWrites)),
                            ValueField("askOnNetwork", boolValue(settings.askOnNetwork)),
                            ValueField("askOnOutsideWorkspaceWrite", boolValue(settings.askOnOutsideWorkspaceWrite)),
                            ValueField("askOnDestructiveCommands", boolValue(settings.askOnDestructiveCommands))
                        ]
                    )
                ),
                ValueField("parseCorrection", boolValue(retry))
            ]
        )
    )
}

func applyApprovalPolicy(
    settings: ProductApprovalSettings,
    approval: ApprovalRequest,
    review: ApprovalReview
): ApprovalReview {
    if (review.decision == ApprovalReviewDecision.Approve &&
        !approvalCapabilitiesMatch(review.approvedCapabilities, approval.metadata.capabilityLabel)) {
        return approvalReviewFailure(
            settings,
            review.reviewerModel,
            "approval.invalid_capabilities",
            "approval reviewer did not approve exactly the requested capability",
            higherReviewerRisk(review.riskLevel, approvalRiskLevelName(approval.metadata.assessment.level)),
            review.latencyMillis
        )
    }
    if (review.decision != ApprovalReviewDecision.Approve && !review.approvedCapabilities.isEmpty()) {
        return approvalReviewFailure(
            settings,
            review.reviewerModel,
            "approval.invalid_capabilities",
            "approval reviewer returned capabilities for a non-approval decision",
            higherReviewerRisk(review.riskLevel, approvalRiskLevelName(approval.metadata.assessment.level)),
            review.latencyMillis
        )
    }
    if (review.decision != ApprovalReviewDecision.Approve) {
        return review
    }
    let requiresUser = (!settings.allowWorkspaceWrites && approval.metadata.capabilityLabel == "workspace.write") || (settings
        .askOnNetwork && hasApprovalRisk(approval.riskFlags, "network")) || (settings.askOnOutsideWorkspaceWrite &&
        approval.metadata.capabilityLabel != "workspace.write" && approval.metadata.capabilityLabel.endsWith(".write")) ||
        (settings.askOnDestructiveCommands && (hasApprovalRisk(approval.riskFlags, "destructive") || hasApprovalRisk(
        approval.riskFlags, "git_destructive")))
    let riskLevel = higherReviewerRisk(
        review.riskLevel,
        approvalRiskLevelName(approval.metadata.assessment.level)
    )
    if (!requiresUser) {
        return ApprovalReview(
            review.decision,
            review.reason,
            riskLevel,
            review.reviewerModel,
            latencyMillis: review.latencyMillis,
            failureType: review.failureType,
            approvedCapabilities: review.approvedCapabilities
        )
    }
    ApprovalReview(
        ApprovalReviewDecision.AskUser,
        "configured approval policy requires explicit user confirmation: " + review.reason,
        riskLevel,
        review.reviewerModel,
        latencyMillis: review.latencyMillis,
        failureType: review.failureType,
        approvedCapabilities: review.approvedCapabilities
    )
}

func approvalCapabilitiesMatch(values: Array<String>, requested: String): Bool {
    values.size == 1 && values[0] == requested
}

public func approvalReviewerArguments(approval: ApprovalRequest): AgentValue {
    match (approval.metadata.writeSummary) {
        case None => redactApprovalValue(approval.preview, "")
        case Some(summary) =>
            let preview = ArrayList<AgentValue>()
            for (line in summary.preview) {
                preview.add(textValue(line))
            }
            objectValue(
                [
                    ValueField("path", textValue(summary.path)),
                    ValueField("action", textValue(summary.action)),
                    ValueField("exists", boolValue(summary.exists)),
                    ValueField("bytes", integerValue(summary.bytes)),
                    ValueField("lines", integerValue(summary.lines)),
                    ValueField("language", textValue(summary.language)),
                    ValueField("preview", listValue(preview.toArray())),
                    ValueField("truncated", boolValue(summary.truncated)),
                    ValueField("contentHash", textValue(summary.contentHash))
                ]
            )
    }
}

func higherReviewerRisk(left: String, right: String): String {
    if (reviewerRiskRank(left) >= reviewerRiskRank(right)) {
        left
    } else {
        right
    }
}

func reviewerRiskRank(value: String): Int64 {
    match (value.toAsciiLower()) {
        case "low" => 0
        case "medium" => 1
        case "high" => 2
        case "critical" => 3
        case _ => 3
    }
}

func approvalValueText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(item) =>
            if (item.unifiedKind == ValueKind.Text) {
                item.text
            } else {
                ""
            }
        case None => ""
    }
}

func approvalNetworkTargets(value: AgentValue): Array<String> {
    let result = ArrayList<String>()
    let command = approvalValueText(value, "command")
    for (word in command.replace("'", " ").replace("\"", " ").split(" ")) {
        let candidate = word.trimAscii()
        if (candidate.startsWith("http://") || candidate.startsWith("https://") || candidate.startsWith("ssh://")) {
            approvalAddUnique(result, redactApprovalText(candidate))
        }
    }
    result.toArray()
}

func approvalOutsidePaths(value: AgentValue): Array<String> {
    let result = ArrayList<String>()
    for (name in ["path", "cwd", "destination", "target"]) {
        let candidate = approvalValueText(value, name).trimAscii()
        if (candidate.startsWith("/") || candidate.startsWith("../") || candidate.startsWith("~/")) {
            approvalAddUnique(result, candidate)
        }
    }
    result.toArray()
}

func approvalEnvironmentNames(value: AgentValue): Array<String> {
    let result = ArrayList<String>()
    match (value.field("env")) {
        case Some(environment) =>
            if (environment.unifiedKind == ValueKind.Object) {
                for (field in environment.fields) {
                    result.add(field.name)
                }
            }
        case None => ()
    }
    result.toArray()
}

func approvalAddUnique(values: ArrayList<String>, value: String): Unit {
    for (existing in values where existing == value) {
        return
    }
    values.add(value)
}

func approvalStringList(values: Array<String>): AgentValue {
    let result = ArrayList<AgentValue>()
    for (value in values) {
        result.add(textValue(value))
    }
    listValue(result.toArray())
}

public func redactApprovalValue(value: AgentValue, fieldName: String): AgentValue {
    if (approvalSensitiveName(fieldName)) {
        return textValue("[REDACTED]")
    }
    match (value.unifiedKind) {
        case ValueKind.Text => textValue(redactApprovalText(value.text))
        case ValueKind.List =>
            let items = ArrayList<AgentValue>()
            for (item in value.items) {
                items.add(redactApprovalValue(item, fieldName))
            }
            listValue(items.toArray())
        case ValueKind.Object =>
            let fields = ArrayList<ValueField>()
            for (field in value.fields) {
                fields.add(ValueField(field.name, redactApprovalValue(field.value, field.name)))
            }
            objectValue(fields.toArray())
        case _ => value
    }
}

public func redactApprovalText(value: String): String {
    var result = value
    for (prefix in [
        "Authorization: Bearer ",
        "authorization: bearer ",
        "api_key=",
        "API_KEY=",
        "access_token=",
        "refresh_token=",
        "password=",
        "cookie=",
        "X-Api-Key: ",
        "x-api-key: ",
        "AWS_ACCESS_KEY_ID=",
        "AWS_SECRET_ACCESS_KEY="
    ]) {
        var offset: Int64 = 0
        while (offset < result.size) {
            let found = result.indexOf(prefix, offset)
            match (found) {
                case Some(index) =>
                    let start = index + prefix.size
                    var end = start
                    while (end < result.size && result[end] != b' ' && result[end] != b'\n' && result[end] != b'\r' &&
                            result[end] != b'&') {
                        end += 1
                    }
                    result = result[..start] + "[REDACTED]" + result[end..]
                    offset = start + "[REDACTED]".size
                case None => break
            }
        }
    }
    for (prefix in ["sk-", "ghp_", "github_pat_"]) {
        result = redactApprovalPrefixedToken(result, prefix)
    }
    result = redactApprovalPem(result)
    result = redactApprovalUrlCredentials(result)
    result
}

func redactApprovalPrefixedToken(value: String, prefix: String): String {
    var result = value
    var offset: Int64 = 0
    while (offset < result.size) {
        match (result[offset..].indexOf(prefix)) {
            case None => break
            case Some(relative) =>
                let start = offset + relative
                var end = start + prefix.size
                while (end < result.size && !approvalSecretDelimiter(result[end])) {
                    end++
                }
                if (end - start > prefix.size + 3) {
                    result = result[..start] + "[REDACTED]" + result[end..]
                    offset = start + 10
                } else {
                    offset = end
                }
        }
    }
    result
}

func approvalSecretDelimiter(value: Byte): Bool {
    value == b' ' || value == b'\t' || value == b'\n' || value == b'\r' || value == b'"' || value == b'\'' || value ==
        b',' || value == b'}' || value == b']' || value == b'&'
}

func redactApprovalPem(value: String): String {
    match (value.indexOf("-----BEGIN ")) {
        case None => value
        case Some(start) => match (value[start..].indexOf("-----END ")) {
            case None => value[..start] + "[REDACTED PRIVATE KEY]"
            case Some(relative) =>
                let endStart = start + relative
                match (value[endStart + 9..].indexOf("-----")) {
                    case None => value[..start] + "[REDACTED PRIVATE KEY]"
                    case Some(endRelative) =>
                        let end = endStart + 9 + endRelative + 5
                        value[..start] + "[REDACTED PRIVATE KEY]" + redactApprovalPem(value[end..])
                }
        }
    }
}

func redactApprovalUrlCredentials(value: String): String {
    match (value.indexOf("://")) {
        case None => value
        case Some(scheme) =>
            let start = scheme + 3
            match (value[start..].indexOf("@")) {
                case None => value
                case Some(relative) =>
                    let at = start + relative
                    if (!value[start..at].contains(":")) {
                        return value
                    }
                    value[..start] + "[REDACTED]@" + value[at + 1..]
            }
    }
}

func approvalSensitiveName(value: String): Bool {
    let name = value.toAsciiLower().replace("-", "_")
    name.contains("api_key") || name.contains("token") || name.contains("authorization") || name.contains("cookie") ||
        name.contains("password") || name.contains("secret") || name.contains("private_key") || name.contains(
        "credential")
}

func hasApprovalRisk(flags: Array<String>, expected: String): Bool {
    for (flag in flags where flag == expected) {
        return true
    }
    false
}

func approvalReviewFailure(
    settings: ProductApprovalSettings,
    model: String,
    failureType: String,
    reason: String,
    risk: String,
    latencyMillis: Int64
): ApprovalReview {
    ApprovalReview(
        if (settings.failurePolicy == ApprovalFailurePolicy.Deny) {
            ApprovalReviewDecision.Deny
        } else {
            ApprovalReviewDecision.AskUser
        },
        reason,
        risk,
        model,
        latencyMillis: latencyMillis,
        failureType: failureType
    )
}

func approvalNowMillis(): Int64 {
    DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
}
