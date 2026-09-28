package agent_product

import yjson.*
import yjson_support.*
import agent_domain.*
import model_adapters.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
let PRODUCT_FILE_APPLICATION_PROPOSAL_SCHEMA = "axyndra.file-change-proposal/v1"
let PRODUCT_FILE_APPLICATION_PLAN_SCHEMA = "axyndra.file-application-plan/v1"
let PRODUCT_FILE_PATCH_SCHEMA = "axyndra.file-patch/v1"
let PRODUCT_FILE_APPLICATION_MAX_OPERATIONS: Int64 = 32
let PRODUCT_FILE_APPLICATION_MAX_BYTES: Int64 = 1048576
let PRODUCT_FILE_APPLICATION_MAX_PATH_BYTES: Int64 = 4096
let PRODUCT_FILE_APPLICATION_PREVIEW_BYTES: Int64 = 8192

class ProductFileApplicationOperation {
    let ordinal: Int64
    let kind: String
    let path: String
    let expectedContent: String
    let content: String
    let precondition: AgentValue
    let contentSha256: String
    let contentBytes: Int64

    init(
        ordinal: Int64,
        kind: String,
        path: String,
        expectedContent: String,
        content: String,
        precondition: AgentValue,
        contentSha256: String,
        contentBytes: Int64
    ) {
        this.ordinal = ordinal
        this.kind = kind
        this.path = path
        this.expectedContent = expectedContent
        this.content = content
        this.precondition = precondition
        this.contentSha256 = contentSha256
        this.contentBytes = contentBytes
    }
}
class ProductStoredFileApplicationPlan {
    let planRef: String
    let planDigest: String
    let plan: AgentValue
    let patchText: String
    let planOperations: AgentValue
    let patchOperations: AgentValue

    init(
        planRef: String,
        planDigest: String,
        plan: AgentValue,
        patchText: String,
        planOperations: AgentValue,
        patchOperations: AgentValue
    ) {
        this.planRef = planRef
        this.planDigest = planDigest
        this.plan = plan
        this.patchText = patchText
        this.planOperations = planOperations
        this.patchOperations = patchOperations
    }
}

class ProductFileApplicationPreviewBuilder {
    private let output = StringBuilder()
    private var bytes: Int64 = 0
    private var didTruncate = false
    private let marker = "\n[preview truncated]"

    public func append(value: String): Unit {
        if (didTruncate) { return }
        let encoded = value.toArray()
        let markerBytes = marker.toArray().size
        let contentLimit = PRODUCT_FILE_APPLICATION_PREVIEW_BYTES - markerBytes
        if (bytes + encoded.size <= contentLimit) {
            output.append(value)
            bytes += encoded.size
            return
        }
        let available = if (contentLimit > bytes) {
            contentLimit - bytes
        } else {
            0
        }
        if (available > 0) {
            let prefix = safeUtf8(encoded[..available])
            output.append(prefix)
            bytes += prefix.toArray().size
        }
        output.append(marker)
        bytes += markerBytes
        didTruncate = true
    }

    public func text(): String { output.toString() }
    public func truncated(): Bool { didTruncate }
}

class ProductPlanGeneratingRunProgramExecutor <: ToolExecutor {
    private let delegate: ProductRunProgramExecutor
    private let workspace: LocalWorkspace
    private let artifacts: ProductArtifactStore

    init(
        delegate: ProductRunProgramExecutor,
        workspace: LocalWorkspace,
        artifacts: ProductArtifactStore
    ) {
        this.delegate = delegate
        this.workspace = workspace
        this.artifacts = artifacts
    }

    public func execute(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolResult> {
        let executed = match (delegate.execute(context, prepared)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (executed.isError) { return Result.Ok(executed) }
        match (materializeProductApplicationPlan(
            executed.output, prepared, workspace, artifacts
        )) {
            case Result.Ok(None) => Result.Ok(executed)
            case Result.Ok(Some(programValue)) => Result.Ok(
                productToolResultWithProgramValue(executed, programValue)
            )
            case Result.Err(error) => Result.Ok(
                productApplicationPlanFailure(executed, error)
            )
        }
    }

    public func cancel(runId: RunId): Result<Unit> {
        delegate.cancel(runId)
    }
}

func materializeProductApplicationPlan(
    toolOutput: AgentValue,
    prepared: PreparedToolInvocation,
    workspace: LocalWorkspace,
    artifacts: ProductArtifactStore
): Result<?AgentValue> {
    let value = match (toolOutput.field("value")) {
        case Some(item) => item
        case None => return applicationPlanError<?AgentValue>(
            AgentErrorKind.Protocol,
            "application_plan.program_result_missing",
            "completed Program result omitted its value"
        )
    }
    if (value.unifiedKind != ValueKind.Object) { return Result.Ok(None) }
    var proposalCount: Int64 = 0
    for (field in value.fields where field.name == "application_plan") {
        proposalCount += 1
    }
    if (proposalCount == 0) { return Result.Ok(None) }
    if (proposalCount != 1) {
        return applicationPlanError<?AgentValue>(
            AgentErrorKind.InvalidInput,
            "application_plan.structure_invalid",
            "Program result must contain exactly one application_plan proposal"
        )
    }
    let proposal = match (value.field("application_plan")) {
        case Some(item) => item
        case None => return applicationPlanError<?AgentValue>(
            AgentErrorKind.InvalidInput,
            "application_plan.structure_invalid",
            "Program application_plan proposal is invalid"
        )
    }
    let summary = match (generateProductApplicationPlan(
        proposal, toolOutput, prepared, workspace, artifacts
    )) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let sanitizedFields = ArrayList<ValueField>()
    for (field in value.fields) {
        if (field.name == "application_plan") {
            sanitizedFields.add(ValueField("application_plan", summary))
        } else {
            sanitizedFields.add(field)
        }
    }
    Result.Ok(Some(objectValue(sanitizedFields.toArray())))
}

func generateProductApplicationPlan(
    proposal: AgentValue,
    toolOutput: AgentValue,
    prepared: PreparedToolInvocation,
    workspace: LocalWorkspace,
    artifacts: ProductArtifactStore
): Result<AgentValue> {
    if (!applicationPlanObjectShape(
        proposal,
        ["schema", "source", "operations"],
        ["schema", "operations"]
    )) {
        return applicationPlanError<AgentValue>(
            AgentErrorKind.InvalidInput,
            "application_plan.structure_invalid",
            "application_plan must contain only its version, source claim, and operations"
        )
    }
    let schema = match (applicationPlanRequiredText(proposal, "schema")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    if (schema != PRODUCT_FILE_APPLICATION_PROPOSAL_SCHEMA) {
        return applicationPlanError<AgentValue>(
            AgentErrorKind.InvalidInput,
            "application_plan.schema_unsupported",
            "application_plan proposal schema is unsupported"
        )
    }
    let operationsValue = match (proposal.field("operations")) {
        case Some(item) => item
        case None => return applicationPlanError<AgentValue>(
            AgentErrorKind.InvalidInput,
            "application_plan.structure_invalid",
            "application_plan operations are required"
        )
    }
    if (operationsValue.unifiedKind != ValueKind.List) {
        return applicationPlanError<AgentValue>(
            AgentErrorKind.InvalidInput,
            "application_plan.structure_invalid",
            "application_plan operations must be a list"
        )
    }
    if (operationsValue.items.isEmpty() ||
        operationsValue.items.size > PRODUCT_FILE_APPLICATION_MAX_OPERATIONS) {
        return applicationPlanError<AgentValue>(
            AgentErrorKind.InvalidInput,
            "application_plan.limit_exceeded",
            "application_plan must contain between one and 32 operations"
        )
    }
    let source = match (productApplicationPlanSource(toolOutput, prepared, workspace)) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    match (validateProductApplicationSourceClaim(proposal, source)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }

    let operations = ArrayList<ProductFileApplicationOperation>()
    var totalContentBytes: Int64 = 0
    for (index in 0..operationsValue.items.size) {
        let operation = match (parseProductApplicationOperation(
            operationsValue.items[index], index, workspace, totalContentBytes
        )) {
            case Result.Ok(item) => item
            case Result.Err(error) => return Result.Err(error)
        }
        for (previous in operations) {
            if (applicationPlanPathsConflict(previous.path, operation.path)) {
                return applicationPlanError<AgentValue>(
                    AgentErrorKind.InvalidInput,
                    "application_plan.targets_conflict",
                    "application_plan targets must be unique and non-ancestor paths"
                )
            }
        }
        totalContentBytes += operation.contentBytes
        if (totalContentBytes > PRODUCT_FILE_APPLICATION_MAX_BYTES) {
            return applicationPlanError<AgentValue>(
                AgentErrorKind.InvalidInput,
                "application_plan.limit_exceeded",
                "application_plan replacement content exceeds the one MiB limit"
            )
        }
        operations.add(operation)
    }

    persistProductApplicationPlan(source, operations.toArray(), artifacts)
}

func persistProductApplicationPlan(
    source: AgentValue,
    operations: Array<ProductFileApplicationOperation>,
    artifacts: ProductArtifactStore
): Result<AgentValue> {
    let patchText = encodeAgentValue(productFilePatchValue(operations))
    let patchBytes = patchText.toArray()
    if (patchBytes.size > PRODUCT_FILE_APPLICATION_MAX_BYTES) {
        return applicationPlanError<AgentValue>(
            AgentErrorKind.InvalidInput,
            "application_plan.limit_exceeded",
            "serialized application patch exceeds the one MiB limit"
        )
    }
    let patchArtifact = match (artifacts.persistText(patchText)) {
        case Result.Ok(item) => item
        case Result.Err(_) => return applicationPlanError<AgentValue>(
            AgentErrorKind.Internal,
            "application_plan.artifact_store_unavailable",
            "the immutable application patch could not be stored"
        )
    }
    if (patchArtifact.sha256 != artifactSha256(patchBytes) ||
        patchArtifact.bytes != patchBytes.size) {
        return applicationPlanError<AgentValue>(
            AgentErrorKind.Conflict,
            "application_plan.patch_artifact_invalid",
            "the stored application patch metadata did not match its content"
        )
    }
    match (verifyProductApplicationArtifact(
        artifacts, patchArtifact, patchText, "patch"
    )) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    let preview = productApplicationPlanPreview(operations)
    let plan = productFileApplicationPlanValue(
        source, patchArtifact, operations, preview[0], preview[1]
    )
    let planText = encodeAgentValue(plan)
    let planBytes = planText.toArray()
    if (planBytes.size > PRODUCT_FILE_APPLICATION_MAX_BYTES) {
        return applicationPlanError<AgentValue>(
            AgentErrorKind.InvalidInput,
            "application_plan.limit_exceeded",
            "serialized application plan exceeds the one MiB limit"
        )
    }
    let planArtifact = match (artifacts.persistText(planText)) {
        case Result.Ok(item) => item
        case Result.Err(_) => return applicationPlanError<AgentValue>(
            AgentErrorKind.Internal,
            "application_plan.artifact_store_unavailable",
            "the immutable application plan could not be stored"
        )
    }
    if (planArtifact.sha256 != artifactSha256(planBytes) ||
        planArtifact.bytes != planBytes.size) {
        return applicationPlanError<AgentValue>(
            AgentErrorKind.Conflict,
            "application_plan.plan_artifact_invalid",
            "the stored application plan metadata did not match its content"
        )
    }
    match (verifyProductApplicationArtifact(
        artifacts, planArtifact, planText, "plan"
    )) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    let summaryFields = ArrayList<ValueField>()
    for (field in plan.fields) { summaryFields.add(field) }
    summaryFields.add(ValueField("plan_ref", textValue(planArtifact.reference)))
    summaryFields.add(ValueField("plan_digest", textValue(planArtifact.sha256)))
    Result.Ok(objectValue(summaryFields.toArray()))
}

func productApplicationPlanSource(
    toolOutput: AgentValue,
    prepared: PreparedToolInvocation,
    workspace: LocalWorkspace
): Result<AgentValue> {
    let sourceValue = match (prepared.operationPlan.canonicalArguments.field("source")) {
        case Some(item) => item
        case None => return applicationPlanError<AgentValue>(
            AgentErrorKind.Conflict,
            "application_plan.source_mismatch",
            "application plan source is not bound to the prepared Program"
        )
    }
    if (sourceValue.unifiedKind != ValueKind.Text) {
        return applicationPlanError<AgentValue>(
            AgentErrorKind.Conflict,
            "application_plan.source_mismatch",
            "application plan source is not bound to the prepared Program"
        )
    }
    let digest = artifactSha256(sourceValue.text.toArray())
    let reference = PRODUCT_ARTIFACT_PREFIX + digest
    let resultReference = match (applicationPlanRequiredText(toolOutput, "program_artifact")) {
        case Result.Ok(item) => item
        case Result.Err(_) => return applicationPlanError<AgentValue>(
            AgentErrorKind.Conflict,
            "application_plan.source_mismatch",
            "Program result source identity is missing"
        )
    }
    let resultDigest = match (applicationPlanRequiredText(toolOutput, "program_sha256")) {
        case Result.Ok(item) => item
        case Result.Err(_) => return applicationPlanError<AgentValue>(
            AgentErrorKind.Conflict,
            "application_plan.source_mismatch",
            "Program result source identity is missing"
        )
    }
    if (resultReference != reference || resultDigest != digest) {
        return applicationPlanError<AgentValue>(
            AgentErrorKind.Conflict,
            "application_plan.source_mismatch",
            "Program result source identity does not match the prepared Program"
        )
    }
    Result.Ok(objectValue([
        ValueField("root_operation_id", textValue(prepared.operationId.value)),
        ValueField("program_id", textValue(reference)),
        ValueField("program_digest", textValue(digest)),
        ValueField(
            "workspace_id",
            textValue("workspace:sha256:" + artifactSha256(workspace.rootPath().toArray()))
        )
    ]))
}

func validateProductApplicationSourceClaim(
    proposal: AgentValue,
    expectedSource: AgentValue
): Result<Unit> {
    let sourceClaim = match (proposal.field("source")) {
        case Some(item) => item
        case None => return Result.Ok(())
    }
    if (!applicationPlanObjectShape(
        sourceClaim,
        ["root_operation_id", "program_id", "program_digest", "workspace_id"],
        []
    )) {
        return applicationPlanError<Unit>(
            AgentErrorKind.InvalidInput,
            "application_plan.source_invalid",
            "application_plan source claim has an invalid structure"
        )
    }
    for (name in ["root_operation_id", "program_id", "program_digest", "workspace_id"]) {
        let claimed = match (applicationPlanOptionalText(sourceClaim, name)) {
            case Result.Ok(item) => item
            case Result.Err(error) => return Result.Err(error)
        }
        match (claimed) {
            case Some(value) =>
                let expected = match (expectedSource.field(name)) {
                    case Some(item) => item.text
                    case None => ""
                }
                if (value != expected) {
                    return applicationPlanError<Unit>(
                        AgentErrorKind.Conflict,
                        "application_plan.source_mismatch",
                        "application_plan source claim does not match this Program execution"
                    )
                }
            case None => ()
        }
    }
    Result.Ok(())
}

func parseProductApplicationOperation(
    value: AgentValue,
    ordinal: Int64,
    workspace: LocalWorkspace,
    totalContentBytes: Int64
): Result<ProductFileApplicationOperation> {
    if (value.unifiedKind != ValueKind.Object) {
        return applicationPlanError<ProductFileApplicationOperation>(
            AgentErrorKind.InvalidInput,
            "application_plan.structure_invalid",
            "application_plan operations must be objects"
        )
    }
    let kind = match (applicationPlanRequiredText(value, "kind")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let allowedFields = if (kind == "create") {
        ["kind", "path", "content"]
    } else if (kind == "replace") {
        ["kind", "path", "expected_content", "content"]
    } else {
        return applicationPlanError<ProductFileApplicationOperation>(
            AgentErrorKind.InvalidInput,
            "application_plan.operation_unsupported",
            "application_plan supports only create and replace operations"
        )
    }
    if (!applicationPlanObjectShape(value, allowedFields, allowedFields)) {
        return applicationPlanError<ProductFileApplicationOperation>(
            AgentErrorKind.InvalidInput,
            "application_plan.structure_invalid",
            "application_plan operation fields do not match its operation kind"
        )
    }
    let path = match (applicationPlanRequiredText(value, "path")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    if (!productApplicationPathIsCanonical(path)) {
        return applicationPlanError<ProductFileApplicationOperation>(
            AgentErrorKind.InvalidInput,
            "application_plan.path_invalid",
            "application_plan target must be a canonical workspace-relative path"
        )
    }
    let content = match (applicationPlanRequiredText(value, "content")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    if (content.contains("\u{0000}")) {
        return applicationPlanError<ProductFileApplicationOperation>(
            AgentErrorKind.InvalidInput,
            "application_plan.content_invalid",
            "application_plan content must be UTF-8 text without NUL bytes"
        )
    }
    let contentBytes = content.toArray()
    if (contentBytes.size > PRODUCT_FILE_APPLICATION_MAX_BYTES ||
        totalContentBytes > PRODUCT_FILE_APPLICATION_MAX_BYTES - contentBytes.size) {
        return applicationPlanError<ProductFileApplicationOperation>(
            AgentErrorKind.InvalidInput,
            "application_plan.limit_exceeded",
            "application_plan replacement content exceeds the one MiB limit"
        )
    }
    let expectedContent = if (kind == "replace") {
        match (applicationPlanRequiredText(value, "expected_content")) {
            case Result.Ok(item) => item
            case Result.Err(error) => return Result.Err(error)
        }
    } else {
        ""
    }
    if (expectedContent.contains("\u{0000}")) {
        return applicationPlanError<ProductFileApplicationOperation>(
            AgentErrorKind.InvalidInput,
            "application_plan.content_invalid",
            "replacement precondition must be UTF-8 text without NUL bytes"
        )
    }
    let expectedBytes = expectedContent.toArray()
    if (expectedBytes.size > PRODUCT_FILE_APPLICATION_MAX_BYTES) {
        return applicationPlanError<ProductFileApplicationOperation>(
            AgentErrorKind.InvalidInput,
            "application_plan.limit_exceeded",
            "replacement precondition exceeds the one MiB limit"
        )
    }
    let target = match (workspace.inspectWriteTarget(path)) {
        case Result.Ok(item) => item
        case Result.Err(_) => return applicationPlanError<ProductFileApplicationOperation>(
            AgentErrorKind.PermissionDenied,
            "application_plan.target_invalid",
            "application_plan target is not safely resolvable inside the workspace"
        )
    }
    if (target.permissionClass != "workspace.write" || target.sensitive) {
        return applicationPlanError<ProductFileApplicationOperation>(
            AgentErrorKind.PermissionDenied,
            "application_plan.target_denied",
            "application_plan target is outside the allowed workspace scope"
        )
    }
    let readTarget = match (workspace.inspectReadTarget(path)) {
        case Result.Ok(item) => item
        case Result.Err(_) => return applicationPlanError<ProductFileApplicationOperation>(
            AgentErrorKind.PermissionDenied,
            "application_plan.target_invalid",
            "application_plan target is not safely resolvable inside the workspace"
        )
    }
    if (readTarget.sensitive) {
        return applicationPlanError<ProductFileApplicationOperation>(
            AgentErrorKind.PermissionDenied,
            "application_plan.target_denied",
            "sensitive workspace targets cannot appear in an application plan"
        )
    }
    let lexicalPath = Path(workspace.rootPath()).join(Path(path)).normalize().toString()
    if (target.normalizedPath != lexicalPath ||
        productApplicationPathContainsSymlink(workspace.rootPath(), path)) {
        return applicationPlanError<ProductFileApplicationOperation>(
            AgentErrorKind.PermissionDenied,
            "application_plan.symlink_denied",
            "application_plan targets cannot traverse symbolic links"
        )
    }
    let parentInfo = try {
        FileInfo(Path(target.realParentPath))
    } catch (_: Exception) {
        return applicationPlanError<ProductFileApplicationOperation>(
            AgentErrorKind.InvalidInput,
            "application_plan.parent_missing",
            "application_plan target parent directory must already exist"
        )
    }
    if (!parentInfo.isDirectory() || parentInfo.isSymbolicLink()) {
        return applicationPlanError<ProductFileApplicationOperation>(
            AgentErrorKind.PermissionDenied,
            "application_plan.parent_invalid",
            "application_plan target parent must be a real workspace directory"
        )
    }

    let precondition = if (kind == "create") {
        if (target.exists) {
            return applicationPlanError<ProductFileApplicationOperation>(
                AgentErrorKind.Conflict,
                "application_plan.create_target_exists",
                "create target already exists"
            )
        }
        objectValue([ValueField("state", textValue("absent"))])
    } else {
        if (!target.exists || target.beforeBytes > PRODUCT_FILE_APPLICATION_MAX_BYTES) {
            return applicationPlanError<ProductFileApplicationOperation>(
                AgentErrorKind.Conflict,
                "application_plan.replace_target_invalid",
                "replace target must be an existing bounded regular text file"
            )
        }
        let fileInfo = try {
            FileInfo(Path(target.normalizedPath))
        } catch (_: Exception) {
            return applicationPlanError<ProductFileApplicationOperation>(
                AgentErrorKind.Conflict,
                "application_plan.replace_target_invalid",
                "replace target must be an existing bounded regular text file"
            )
        }
        if (!fileInfo.isRegular() || fileInfo.isSymbolicLink()) {
            return applicationPlanError<ProductFileApplicationOperation>(
                AgentErrorKind.PermissionDenied,
                "application_plan.target_invalid",
                "replace target must be a regular non-symlink file"
            )
        }
        let current = match (workspace.read(WorkspaceReadRequest(path))) {
            case Result.Ok(item) => item.content
            case Result.Err(_) => return applicationPlanError<ProductFileApplicationOperation>(
                AgentErrorKind.InvalidInput,
                "application_plan.replace_target_unreadable",
                "replace target must be a complete UTF-8 text file within the read limit"
            )
        }
        let currentBytes = current.toArray()
        if (current != expectedContent || currentBytes.size != target.beforeBytes ||
            currentBytes.size != expectedBytes.size) {
            return applicationPlanError<ProductFileApplicationOperation>(
                AgentErrorKind.Conflict,
                "application_plan.precondition_conflict",
                "replace target no longer matches the Program-provided expected content"
            )
        }
        objectValue([
            ValueField("state", textValue("regular_file")),
            ValueField("sha256", textValue(artifactSha256(currentBytes))),
            ValueField("bytes", integerValue(currentBytes.size))
        ])
    }
    Result.Ok(ProductFileApplicationOperation(
        ordinal,
        kind,
        path,
        expectedContent,
        content,
        precondition,
        artifactSha256(contentBytes),
        contentBytes.size
    ))
}

func productFilePatchValue(
    operations: Array<ProductFileApplicationOperation>
): AgentValue {
    let entries = ArrayList<AgentValue>()
    for (operation in operations) {
        entries.add(objectValue([
            ValueField("ordinal", integerValue(operation.ordinal)),
            ValueField("utf8_content", textValue(operation.content))
        ]))
    }
    objectValue([
        ValueField("schema", textValue(PRODUCT_FILE_PATCH_SCHEMA)),
        ValueField("operations", listValue(entries.toArray()))
    ])
}

func productFileApplicationPlanValue(
    source: AgentValue,
    patchArtifact: ProductArtifact,
    operations: Array<ProductFileApplicationOperation>,
    previewText: String,
    previewTruncated: Bool
): AgentValue {
    let planOperations = ArrayList<AgentValue>()
    for (operation in operations) {
        planOperations.add(objectValue([
            ValueField("ordinal", integerValue(operation.ordinal)),
            ValueField("kind", textValue(operation.kind)),
            ValueField("path", textValue(operation.path)),
            ValueField("precondition", operation.precondition),
            ValueField("content", objectValue([
                ValueField("encoding", textValue("utf-8")),
                ValueField("sha256", textValue(operation.contentSha256)),
                ValueField("bytes", integerValue(operation.contentBytes))
            ]))
        ]))
    }
    objectValue([
        ValueField("schema", textValue(PRODUCT_FILE_APPLICATION_PLAN_SCHEMA)),
        ValueField("workspace_id", source.field("workspace_id").getOrThrow()),
        ValueField("source", objectValue([
            ValueField("root_operation_id", source.field("root_operation_id").getOrThrow()),
            ValueField("program_id", source.field("program_id").getOrThrow()),
            ValueField("program_digest", source.field("program_digest").getOrThrow())
        ])),
        ValueField("patch_artifact", objectValue([
            ValueField("ref", textValue(patchArtifact.reference)),
            ValueField("sha256", textValue(patchArtifact.sha256)),
            ValueField("bytes", integerValue(patchArtifact.bytes))
        ])),
        ValueField("operations", listValue(planOperations.toArray())),
        ValueField("preview", objectValue([
            ValueField("format", textValue("unified_diff")),
            ValueField("text", textValue(previewText)),
            ValueField("truncated", boolValue(previewTruncated))
        ]))
    ])
}

func productApplicationPlanPreview(
    operations: Array<ProductFileApplicationOperation>
): (String, Bool) {
    let preview = ProductFileApplicationPreviewBuilder()
    for (operation in operations) {
        preview.append(if (operation.kind == "create") {
            "--- /dev/null\n+++ b/" + operation.path + "\n"
        } else {
            "--- a/" + operation.path + "\n+++ b/" + operation.path + "\n"
        })
        let oldLines: Array<String> = if (operation.kind == "create") {
            []
        } else {
            productApplicationDiffLines(operation.expectedContent)
        }
        let newLines = productApplicationDiffLines(operation.content)
        let oldStart: Int64 = if (oldLines.isEmpty()) { 0 } else { 1 }
        let newStart: Int64 = if (newLines.isEmpty()) { 0 } else { 1 }
        preview.append("@@ -${oldStart},${oldLines.size} +${newStart},${newLines.size} @@\n")
        for (line in oldLines) { preview.append("-" + line + "\n") }
        if (operation.kind == "replace" && operation.expectedContent != "" &&
            !operation.expectedContent.endsWith("\n")) {
            preview.append("\\ No newline at end of file\n")
        }
        for (line in newLines) { preview.append("+" + line + "\n") }
        if (operation.content != "" && !operation.content.endsWith("\n")) {
            preview.append("\\ No newline at end of file\n")
        }
    }
    (preview.text(), preview.truncated())
}

func productApplicationDiffLines(content: String): Array<String> {
    if (content == "") { return [] }
    let raw = content.split("\n")
    let length = if (content.endsWith("\n")) { raw.size - 1 } else { raw.size }
    let lines = ArrayList<String>()
    for (index in 0..length) { lines.add(raw[index]) }
    lines.toArray()
}

func verifyProductApplicationArtifact(
    artifacts: ProductArtifactStore,
    artifact: ProductArtifact,
    expectedContent: String,
    kind: String
): Result<Unit> {
    let read = match (artifacts.read(
        artifact.reference,
        limit: PRODUCT_FILE_APPLICATION_MAX_BYTES
    )) {
        case Result.Ok(item) => item
        case Result.Err(_) => return applicationPlanError<Unit>(
            AgentErrorKind.Conflict,
            "application_plan." + kind + "_artifact_missing",
            "the immutable application " + kind + " artifact is missing or unreadable"
        )
    }
    if (read.reference != artifact.reference || read.content != expectedContent ||
        read.bytes != artifact.bytes || read.returnedBytes != artifact.bytes || read.truncated) {
        return applicationPlanError<Unit>(
            AgentErrorKind.Conflict,
            "application_plan." + kind + "_artifact_invalid",
            "the immutable application " + kind + " artifact failed read-back verification"
        )
    }
    Result.Ok(())
}


func productApplicationPathIsCanonical(path: String): Bool {
    if (path == "" || path.size > PRODUCT_FILE_APPLICATION_MAX_PATH_BYTES ||
        path.startsWith("/") || path.contains("\\") || path.contains(":") ||
        path.contains("\u{0000}")) {
        return false
    }
    let pathBytes = path.toArray()
    if (pathBytes.size > PRODUCT_FILE_APPLICATION_MAX_PATH_BYTES) { return false }
    for (byte in pathBytes) {
        if (byte < 32u8 || byte == 127u8) { return false }
    }
    for (part in path.split("/")) {
        if (part == "" || part == "." || part == "..") { return false }
    }
    true
}

func productApplicationPathContainsSymlink(root: String, path: String): Bool {
    var current = Path(root)
    let parts = path.split("/")
    for (part in parts) {
        current = current.join(part)
        let info: ?FileInfo = try {
            Some(FileInfo(current))
        } catch (_: Exception) {
            None
        }
        match (info) {
            case Some(value) =>
                if (value.isSymbolicLink()) { return true }
            case None => return false
        }
    }
    false
}

func applicationPlanPathsConflict(left: String, right: String): Bool {
    left == right || left.startsWith(right + "/") || right.startsWith(left + "/")
}

func applicationPlanObjectShape(
    value: AgentValue,
    allowed: Array<String>,
    required: Array<String>
): Bool {
    if (value.unifiedKind != ValueKind.Object) { return false }
    let seen = ArrayList<String>()
    for (field in value.fields) {
        if (!allowed.contains(field.name) || seen.contains(field.name)) { return false }
        seen.add(field.name)
    }
    for (name in required) {
        if (!seen.contains(name)) { return false }
    }
    true
}

func applicationPlanRequiredText(value: AgentValue, name: String): Result<String> {
    let field = match (value.field(name)) {
        case Some(item) => item
        case None => return applicationPlanError<String>(
            AgentErrorKind.InvalidInput,
            "application_plan.structure_invalid",
            "application_plan is missing a required text field"
        )
    }
    if (field.unifiedKind != ValueKind.Text) {
        return applicationPlanError<String>(
            AgentErrorKind.InvalidInput,
            "application_plan.structure_invalid",
            "application_plan field must be text"
        )
    }
    Result.Ok(field.text)
}

func applicationPlanOptionalText(value: AgentValue, name: String): Result<?String> {
    let field = match (value.field(name)) {
        case Some(item) => item
        case None => return Result.Ok(None)
    }
    if (field.unifiedKind != ValueKind.Text) {
        return applicationPlanError<?String>(
            AgentErrorKind.InvalidInput,
            "application_plan.source_invalid",
            "application_plan source claim fields must be text"
        )
    }
    Result.Ok(Some(field.text))
}

func applicationPlanError<T>(
    kind: AgentErrorKind,
    code: String,
    message: String
): Result<T> {
    Result.Err(AgentError(kind, code, message))
}

func canonicalizeProductFileApplicationPlan(
    context: ToolInvocationContext,
    call: ToolCall,
    workspace: LocalWorkspace,
    artifacts: ProductArtifactStore
): Result<AgentValue> {
    let _ = context
    let rawArgumentShape = applicationPlanObjectShape(
        call.arguments,
        ["plan_ref", "plan_digest"],
        ["plan_ref", "plan_digest"]
    )
    let canonicalArgumentFields = [
        "schema", "workspace_id", "source", "patch_artifact", "operations",
        "preview", "plan_ref", "plan_digest", "approval_targets"
    ]
    let canonicalReplay = applicationPlanObjectShape(
        call.arguments, canonicalArgumentFields, canonicalArgumentFields
    )
    if (!rawArgumentShape && !canonicalReplay) {
        return applicationPlanError<AgentValue>(
            AgentErrorKind.InvalidInput,
            "application_plan.arguments_invalid",
            "apply_file_plan requires exactly plan_ref and plan_digest"
        )
    }
    let stored = match (loadProductStoredFileApplicationPlan(
        call.arguments, workspace, artifacts
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let operations = ArrayList<ProductFileApplicationOperation>()
    var totalContentBytes: Int64 = 0
    for (index in 0..stored.planOperations.items.size) {
        let operation = match (revalidateProductApplicationOperation(
            stored.planOperations.items[index], stored.patchOperations.items[index],
            index, totalContentBytes, workspace
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        totalContentBytes += operation.contentBytes
        operations.add(operation)
    }
    let previewValue = stored.plan.field("preview").getOrThrow()
    let previewText = match (applicationPlanRequiredText(previewValue, "text")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let previewTruncated = match (applicationPlanRequiredBool(previewValue, "truncated")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let expectedPreview = productApplicationPlanPreview(operations.toArray())
    if (previewText != expectedPreview[0] || previewTruncated != expectedPreview[1]) {
        return applicationPlanError<AgentValue>(
            AgentErrorKind.Conflict,
            "application_plan.preview_changed",
            "the bounded application preview does not match the current plan"
        )
    }
    let approvalTargets = ArrayList<AgentValue>()
    for (operation in operations) {
        let metadata = workspace.writeApprovalMetadata(operation.path, operation.content)
        if (metadata.capabilityLabel != "workspace.write") {
            return applicationPlanError<AgentValue>(
                AgentErrorKind.PermissionDenied,
                "application_plan.target_denied",
                "application plan target is not authorized for workspace writes"
            )
        }
        let summary = match (metadata.writeSummary) {
            case Some(value) => value
            case None => return applicationPlanError<AgentValue>(
                AgentErrorKind.PermissionDenied,
                "application_plan.target_invalid",
                "application plan target has no complete approval summary"
            )
        }
        if (summary.path == "") {
            return applicationPlanError<AgentValue>(
                AgentErrorKind.PermissionDenied,
                "application_plan.target_invalid",
                "application plan target has no canonical workspace path"
            )
        }
        approvalTargets.add(productApplicationApprovalTarget(operation, metadata, summary))
    }
    let canonicalFields = ArrayList<ValueField>()
    for (field in stored.plan.fields) { canonicalFields.add(field) }
    canonicalFields.add(ValueField("plan_ref", textValue(stored.planRef)))
    canonicalFields.add(ValueField("plan_digest", textValue(stored.planDigest)))
    canonicalFields.add(ValueField("approval_targets", listValue(approvalTargets.toArray())))
    let canonicalArguments = objectValue(canonicalFields.toArray())
    if (canonicalReplay &&
        encodeAgentValue(call.arguments) != encodeAgentValue(canonicalArguments)) {
        return applicationPlanError<AgentValue>(
            AgentErrorKind.Conflict,
            "application_plan.canonical_arguments_changed",
            "the canonical application arguments no longer match the immutable plan"
        )
    }
    Result.Ok(canonicalArguments)
}

func loadProductStoredFileApplicationPlan(
    arguments: AgentValue,
    workspace: LocalWorkspace,
    artifacts: ProductArtifactStore
): Result<ProductStoredFileApplicationPlan> {
    let planRef = match (applicationPlanRequiredText(arguments, "plan_ref")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let planDigest = match (applicationPlanRequiredText(arguments, "plan_digest")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let planText = match (readProductApplicationArtifact(
        artifacts, planRef, planDigest, -1, "plan"
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let plan = match (decodeAgentValue(
        planText, maxBytes: PRODUCT_FILE_APPLICATION_MAX_BYTES
    )) {
        case Result.Ok(value) => value
        case Result.Err(_) => return applicationPlanError<ProductStoredFileApplicationPlan>(
            AgentErrorKind.Conflict,
            "application_plan.plan_artifact_invalid",
            "the immutable application plan is not valid JSON"
        )
    }
    if (!applicationPlanObjectShape(
        plan,
        ["schema", "workspace_id", "source", "patch_artifact", "operations", "preview"],
        ["schema", "workspace_id", "source", "patch_artifact", "operations", "preview"]
    ) || encodeAgentValue(plan) != planText) {
        return applicationPlanError<ProductStoredFileApplicationPlan>(
            AgentErrorKind.Conflict,
            "application_plan.plan_artifact_invalid",
            "the immutable application plan has an invalid structure"
        )
    }
    let schema = match (applicationPlanRequiredText(plan, "schema")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    if (schema != PRODUCT_FILE_APPLICATION_PLAN_SCHEMA ||
        planRef != PRODUCT_ARTIFACT_PREFIX + planDigest) {
        return applicationPlanError<ProductStoredFileApplicationPlan>(
            AgentErrorKind.Conflict,
            "application_plan.plan_reference_invalid",
            "the application plan schema or reference is inconsistent"
        )
    }
    let workspaceId = match (applicationPlanRequiredText(plan, "workspace_id")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let expectedWorkspaceId = "workspace:sha256:" + artifactSha256(workspace.rootPath().toArray())
    if (workspaceId != expectedWorkspaceId) {
        return applicationPlanError<ProductStoredFileApplicationPlan>(
            AgentErrorKind.Conflict,
            "application_plan.workspace_mismatch",
            "the application plan belongs to a different workspace"
        )
    }
    let source = match (plan.field("source")) {
        case Some(value) => value
        case None => return applicationPlanError<ProductStoredFileApplicationPlan>(
            AgentErrorKind.Conflict, "application_plan.source_invalid",
            "the application plan source is missing"
        )
    }
    if (!applicationPlanObjectShape(
        source,
        ["root_operation_id", "program_id", "program_digest"],
        ["root_operation_id", "program_id", "program_digest"]
    )) {
        return applicationPlanError<ProductStoredFileApplicationPlan>(
            AgentErrorKind.Conflict, "application_plan.source_invalid",
            "the application plan source has an invalid structure"
        )
    }
    let rootOperationId = match (applicationPlanRequiredText(source, "root_operation_id")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let programRef = match (applicationPlanRequiredText(source, "program_id")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let programDigest = match (applicationPlanRequiredText(source, "program_digest")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    if (rootOperationId == "" || programDigest == "" ||
        programRef != PRODUCT_ARTIFACT_PREFIX + programDigest) {
        return applicationPlanError<ProductStoredFileApplicationPlan>(
            AgentErrorKind.Conflict, "application_plan.source_invalid",
            "the application plan source identity is incomplete or inconsistent"
        )
    }
    let patchArtifact = match (plan.field("patch_artifact")) {
        case Some(value) => value
        case None => return applicationPlanError<ProductStoredFileApplicationPlan>(
            AgentErrorKind.Conflict, "application_plan.patch_artifact_invalid",
            "the immutable application patch reference is missing"
        )
    }
    if (!applicationPlanObjectShape(
        patchArtifact, ["ref", "sha256", "bytes"], ["ref", "sha256", "bytes"]
    )) {
        return applicationPlanError<ProductStoredFileApplicationPlan>(
            AgentErrorKind.Conflict, "application_plan.patch_artifact_invalid",
            "the immutable application patch metadata is invalid"
        )
    }
    let patchRef = match (applicationPlanRequiredText(patchArtifact, "ref")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let patchDigest = match (applicationPlanRequiredText(patchArtifact, "sha256")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let patchBytes = match (applicationPlanRequiredInt(patchArtifact, "bytes")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let patchText = match (readProductApplicationArtifact(
        artifacts, patchRef, patchDigest, patchBytes, "patch"
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let patch = match (decodeAgentValue(
        patchText, maxBytes: PRODUCT_FILE_APPLICATION_MAX_BYTES
    )) {
        case Result.Ok(value) => value
        case Result.Err(_) => return applicationPlanError<ProductStoredFileApplicationPlan>(
            AgentErrorKind.Conflict, "application_plan.patch_artifact_invalid",
            "the immutable application patch is not valid JSON"
        )
    }
    if (!applicationPlanObjectShape(
        patch, ["schema", "operations"], ["schema", "operations"]
    ) || encodeAgentValue(patch) != patchText) {
        return applicationPlanError<ProductStoredFileApplicationPlan>(
            AgentErrorKind.Conflict, "application_plan.patch_artifact_invalid",
            "the immutable application patch has an invalid structure"
        )
    }
    let patchSchema = match (applicationPlanRequiredText(patch, "schema")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let planOperations = plan.field("operations").getOrThrow()
    let patchOperations = patch.field("operations").getOrThrow()
    if (patchSchema != PRODUCT_FILE_PATCH_SCHEMA ||
        planOperations.unifiedKind != ValueKind.List ||
        patchOperations.unifiedKind != ValueKind.List ||
        planOperations.items.isEmpty() ||
        planOperations.items.size > PRODUCT_FILE_APPLICATION_MAX_OPERATIONS ||
        planOperations.items.size != patchOperations.items.size) {
        return applicationPlanError<ProductStoredFileApplicationPlan>(
            AgentErrorKind.Conflict, "application_plan.operation_list_invalid",
            "the immutable application plan and patch operation lists do not match"
        )
    }
    let operations = ArrayList<ProductFileApplicationOperation>()
    var totalContentBytes: Int64 = 0
    for (index in 0..planOperations.items.size) {
        let operation = match (parseStoredProductApplicationOperation(
            planOperations.items[index], patchOperations.items[index],
            index, totalContentBytes
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        for (previous in operations) {
            if (applicationPlanPathsConflict(previous.path, operation.path)) {
                return applicationPlanError<ProductStoredFileApplicationPlan>(
                    AgentErrorKind.Conflict, "application_plan.targets_changed",
                    "application plan targets are no longer a unique safe set"
                )
            }
        }
        totalContentBytes += operation.contentBytes
        operations.add(operation)
    }
    if (encodeAgentValue(productFilePatchValue(operations.toArray())) != patchText) {
        return applicationPlanError<ProductStoredFileApplicationPlan>(
            AgentErrorKind.Conflict, "application_plan.patch_artifact_invalid",
            "the immutable patch payloads do not match their operation metadata"
        )
    }
    let preview = plan.field("preview").getOrThrow()
    if (!applicationPlanObjectShape(
        preview, ["format", "text", "truncated"], ["format", "text", "truncated"]
    )) {
        return applicationPlanError<ProductStoredFileApplicationPlan>(
            AgentErrorKind.Conflict, "application_plan.preview_invalid",
            "the application plan preview has an invalid structure"
        )
    }
    let previewFormat = match (applicationPlanRequiredText(preview, "format")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let previewText = match (applicationPlanRequiredText(preview, "text")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    match (applicationPlanRequiredBool(preview, "truncated")) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    if (previewFormat != "unified_diff" ||
        previewText.toArray().size > PRODUCT_FILE_APPLICATION_PREVIEW_BYTES) {
        return applicationPlanError<ProductStoredFileApplicationPlan>(
            AgentErrorKind.Conflict, "application_plan.preview_invalid",
            "the bounded application preview metadata is invalid"
        )
    }
    Result.Ok(ProductStoredFileApplicationPlan(
        planRef, planDigest, plan, patchText, planOperations, patchOperations
    ))
}
func canonicalizeProductFileRecoveryPlan(
    context: ToolInvocationContext,
    call: ToolCall,
    workspace: LocalWorkspace,
    artifacts: ProductArtifactStore
): Result<AgentValue> {
    let _ = context
    let rawFields = ["plan_ref", "plan_digest"]
    let canonicalFields = [
        "schema", "workspace_id", "source", "patch_artifact", "operations",
        "preview", "plan_ref", "plan_digest"
    ]
    let raw = applicationPlanObjectShape(call.arguments, rawFields, rawFields)
    let replay = applicationPlanObjectShape(
        call.arguments, canonicalFields, canonicalFields
    )
    if (!raw && !replay) {
        return applicationPlanError<AgentValue>(
            AgentErrorKind.InvalidInput,
            "application_plan.recovery_arguments_invalid",
            "recover_file_plan requires exactly plan_ref and plan_digest"
        )
    }
    let stored = match (loadProductStoredFileApplicationPlan(
        call.arguments, workspace, artifacts
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let fields = ArrayList<ValueField>()
    for (field in stored.plan.fields) { fields.add(field) }
    fields.add(ValueField("plan_ref", textValue(stored.planRef)))
    fields.add(ValueField("plan_digest", textValue(stored.planDigest)))
    let canonical = objectValue(fields.toArray())
    if (replay && encodeAgentValue(call.arguments) != encodeAgentValue(canonical)) {
        return applicationPlanError<AgentValue>(
            AgentErrorKind.Conflict,
            "application_plan.recovery_arguments_changed",
            "the canonical recovery arguments no longer match the immutable plan"
        )
    }
    Result.Ok(canonical)
}

func readProductApplicationArtifact(
    artifacts: ProductArtifactStore,
    reference: String,
    digest: String,
    expectedBytes: Int64,
    kind: String
): Result<String> {
    if (reference != PRODUCT_ARTIFACT_PREFIX + digest) {
        return applicationPlanError<String>(
            AgentErrorKind.Conflict,
            "application_plan." + kind + "_artifact_invalid",
            "the immutable application " + kind + " reference does not match its digest"
        )
    }
    let read = match (artifacts.read(
        reference,
        limit: PRODUCT_FILE_APPLICATION_MAX_BYTES
    )) {
        case Result.Ok(value) => value
        case Result.Err(_) => return applicationPlanError<String>(
            AgentErrorKind.Conflict,
            "application_plan." + kind + "_artifact_missing",
            "the immutable application " + kind + " artifact is missing or unreadable"
        )
    }
    let bytes = read.content.toArray()
    if (read.reference != reference || read.truncated ||
        read.bytes != read.returnedBytes || read.bytes != bytes.size ||
        (expectedBytes >= 0 && read.bytes != expectedBytes) ||
        artifactSha256(bytes) != digest) {
        return applicationPlanError<String>(
            AgentErrorKind.Conflict,
            "application_plan." + kind + "_artifact_invalid",
            "the immutable application " + kind + " artifact failed digest and length verification"
        )
    }
    Result.Ok(read.content)
}

func parseStoredProductApplicationOperation(
    planOperation: AgentValue,
    patchOperation: AgentValue,
    ordinal: Int64,
    totalContentBytes: Int64
): Result<ProductFileApplicationOperation> {
    if (!applicationPlanObjectShape(
        planOperation,
        ["ordinal", "kind", "path", "precondition", "content"],
        ["ordinal", "kind", "path", "precondition", "content"]
    ) || !applicationPlanObjectShape(
        patchOperation,
        ["ordinal", "utf8_content"],
        ["ordinal", "utf8_content"]
    )) {
        return applicationPlanError<ProductFileApplicationOperation>(
            AgentErrorKind.Conflict,
            "application_plan.operation_invalid",
            "the immutable application operation has an invalid structure"
        )
    }
    let planOrdinal = match (applicationPlanRequiredInt(planOperation, "ordinal")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let patchOrdinal = match (applicationPlanRequiredInt(patchOperation, "ordinal")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    if (planOrdinal != ordinal || patchOrdinal != ordinal) {
        return applicationPlanError<ProductFileApplicationOperation>(
            AgentErrorKind.Conflict,
            "application_plan.operation_order_changed",
            "the immutable application operation order is inconsistent"
        )
    }
    let kind = match (applicationPlanRequiredText(planOperation, "kind")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let path = match (applicationPlanRequiredText(planOperation, "path")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let payload = match (applicationPlanRequiredText(patchOperation, "utf8_content")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    if ((kind != "create" && kind != "replace") ||
        !productApplicationPathIsCanonical(path) ||
        path.toArray().size > PRODUCT_FILE_APPLICATION_MAX_PATH_BYTES) {
        return applicationPlanError<ProductFileApplicationOperation>(
            AgentErrorKind.Conflict,
            "application_plan.operation_unsupported",
            "the immutable application operation kind or path is unsupported"
        )
    }
    let contentMetadata = match (planOperation.field("content")) {
        case Some(value) => value
        case None => return applicationPlanError<ProductFileApplicationOperation>(
            AgentErrorKind.Conflict,
            "application_plan.content_metadata_invalid",
            "the immutable application content metadata is missing"
        )
    }
    if (!applicationPlanObjectShape(
        contentMetadata,
        ["encoding", "sha256", "bytes"],
        ["encoding", "sha256", "bytes"]
    )) {
        return applicationPlanError<ProductFileApplicationOperation>(
            AgentErrorKind.Conflict,
            "application_plan.content_metadata_invalid",
            "the immutable application content metadata is invalid"
        )
    }
    let encoding = match (applicationPlanRequiredText(contentMetadata, "encoding")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let digest = match (applicationPlanRequiredText(contentMetadata, "sha256")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let byteCount = match (applicationPlanRequiredInt(contentMetadata, "bytes")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let payloadBytes = payload.toArray()
    if (encoding != "utf-8" || byteCount != payloadBytes.size ||
        digest != artifactSha256(payloadBytes) ||
        totalContentBytes + byteCount > PRODUCT_FILE_APPLICATION_MAX_BYTES) {
        return applicationPlanError<ProductFileApplicationOperation>(
            AgentErrorKind.Conflict,
            "application_plan.content_changed",
            "the immutable application payload does not match its digest or limits"
        )
    }
    let storedPrecondition = match (planOperation.field("precondition")) {
        case Some(value) => value
        case None => return applicationPlanError<ProductFileApplicationOperation>(
            AgentErrorKind.Conflict,
            "application_plan.precondition_invalid",
            "the immutable application precondition is missing"
        )
    }
    if (!productApplicationPreconditionMatches(
        storedPrecondition, storedPrecondition, kind
    )) {
        return applicationPlanError<ProductFileApplicationOperation>(
            AgentErrorKind.Conflict,
            "application_plan.precondition_invalid",
            "the immutable application precondition is invalid"
        )
    }
    Result.Ok(ProductFileApplicationOperation(
        ordinal, kind, path, "", payload, storedPrecondition, digest, byteCount
    ))
}

func revalidateProductApplicationOperation(
    planOperation: AgentValue,
    patchOperation: AgentValue,
    ordinal: Int64,
    totalContentBytes: Int64,
    workspace: LocalWorkspace
): Result<ProductFileApplicationOperation> {
    let stored = match (parseStoredProductApplicationOperation(
        planOperation, patchOperation, ordinal, totalContentBytes
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let inputFields = ArrayList<ValueField>()
    inputFields.add(ValueField("kind", textValue(stored.kind)))
    inputFields.add(ValueField("path", textValue(stored.path)))
    if (stored.kind == "replace") {
        let current = match (productApplicationCurrentContent(stored.path, workspace)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        inputFields.add(ValueField("expected_content", textValue(current)))
    }
    inputFields.add(ValueField("content", textValue(stored.content)))
    let parsed = match (parseProductApplicationOperation(
        objectValue(inputFields.toArray()), ordinal, workspace, totalContentBytes
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    if (parsed.kind != stored.kind || parsed.path != stored.path ||
        parsed.contentSha256 != stored.contentSha256 ||
        parsed.contentBytes != stored.contentBytes ||
        !productApplicationPreconditionMatches(
            stored.precondition, parsed.precondition, stored.kind
        )) {
        return applicationPlanError<ProductFileApplicationOperation>(
            AgentErrorKind.Conflict,
            "application_plan.precondition_conflict",
            "an application target changed after the plan was generated"
        )
    }
    Result.Ok(parsed)
}

func productApplicationCurrentContent(
    path: String,
    workspace: LocalWorkspace
): Result<String> {
    if (!productApplicationPathIsCanonical(path)) {
        return applicationPlanError<String>(
            AgentErrorKind.PermissionDenied,
            "application_plan.path_invalid",
            "application plan target must be a canonical workspace-relative path"
        )
    }
    let target = match (workspace.inspectWriteTarget(path)) {
        case Result.Ok(value) => value
        case Result.Err(_) => return applicationPlanError<String>(
            AgentErrorKind.PermissionDenied,
            "application_plan.target_invalid",
            "application plan target is not safely resolvable inside the workspace"
        )
    }
    let readTarget = match (workspace.inspectReadTarget(path)) {
        case Result.Ok(value) => value
        case Result.Err(_) => return applicationPlanError<String>(
            AgentErrorKind.PermissionDenied,
            "application_plan.target_invalid",
            "application plan target is not safely readable inside the workspace"
        )
    }
    let lexicalPath = Path(workspace.rootPath()).join(Path(path)).normalize().toString()
    if (target.permissionClass != "workspace.write" || target.sensitive ||
        readTarget.sensitive || target.normalizedPath != lexicalPath ||
        productApplicationPathContainsSymlink(workspace.rootPath(), path)) {
        return applicationPlanError<String>(
            AgentErrorKind.PermissionDenied,
            "application_plan.target_denied",
            "application plan target is outside the safe workspace write boundary"
        )
    }
    let info = try {
        FileInfo(Path(target.normalizedPath))
    } catch (_: Exception) {
        return applicationPlanError<String>(
            AgentErrorKind.Conflict,
            "application_plan.replace_target_invalid",
            "replace target is no longer an existing regular file"
        )
    }
    if (!info.isRegular() || info.isSymbolicLink() ||
        info.size > PRODUCT_FILE_APPLICATION_MAX_BYTES) {
        return applicationPlanError<String>(
            AgentErrorKind.Conflict,
            "application_plan.replace_target_invalid",
            "replace target is no longer a bounded regular file"
        )
    }
    match (workspace.read(WorkspaceReadRequest(path))) {
        case Result.Ok(value) => Result.Ok(value.content)
        case Result.Err(_) => applicationPlanError<String>(
            AgentErrorKind.Conflict,
            "application_plan.replace_target_unreadable",
            "replace target is no longer a complete UTF-8 text file"
        )
    }
}

func productApplicationPreconditionMatches(
    expected: AgentValue,
    actual: AgentValue,
    kind: String
): Bool {
    if (kind == "create") {
        if (!applicationPlanObjectShape(expected, ["state"], ["state"]) ||
            !applicationPlanObjectShape(actual, ["state"], ["state"])) {
            return false
        }
        match ((applicationPlanRequiredText(expected, "state"),
            applicationPlanRequiredText(actual, "state"))) {
            case (Result.Ok(left), Result.Ok(right)) => left == "absent" && right == "absent"
            case _ => false
        }
    } else {
        if (!applicationPlanObjectShape(
            expected,
            ["state", "sha256", "bytes"],
            ["state", "sha256", "bytes"]
        ) || !applicationPlanObjectShape(
            actual,
            ["state", "sha256", "bytes"],
            ["state", "sha256", "bytes"]
        )) {
            return false
        }
        match ((
            applicationPlanRequiredText(expected, "state"),
            applicationPlanRequiredText(actual, "state"),
            applicationPlanRequiredText(expected, "sha256"),
            applicationPlanRequiredText(actual, "sha256"),
            applicationPlanRequiredInt(expected, "bytes"),
            applicationPlanRequiredInt(actual, "bytes")
        )) {
            case (Result.Ok(leftState), Result.Ok(rightState),
                Result.Ok(leftHash), Result.Ok(rightHash),
                Result.Ok(leftBytes), Result.Ok(rightBytes)) =>
                leftState == "regular_file" && rightState == "regular_file" &&
                    leftHash == rightHash && leftBytes == rightBytes
            case _ => false
        }
    }
}

func productApplicationApprovalTarget(
    operation: ProductFileApplicationOperation,
    metadata: ToolApprovalMetadata,
    summary: WriteApprovalSummary
): AgentValue {
    let flags = ArrayList<AgentValue>()
    for (flag in metadata.assessment.flags) { flags.add(textValue(flag)) }
    let reasons = ArrayList<AgentValue>()
    for (reason in metadata.assessment.reasons) { reasons.add(textValue(reason)) }
    objectValue([
        ValueField("path", textValue(summary.path)),
        ValueField("operation", textValue(operation.kind)),
        ValueField("action", textValue(summary.action)),
        ValueField("exists", boolValue(summary.exists)),
        ValueField("bytes", integerValue(summary.bytes)),
        ValueField("lines", integerValue(summary.lines)),
        ValueField("language", textValue(summary.language)),
        ValueField("truncated", boolValue(summary.truncated)),
        ValueField("content_sha256", textValue(summary.contentHash)),
        ValueField("before_bytes", integerValue(summary.beforeBytes)),
        ValueField("added_lines", integerValue(summary.addedLines)),
        ValueField("removed_lines", integerValue(summary.removedLines)),
        ValueField("capability", textValue(metadata.capabilityLabel)),
        ValueField("risk", textValue(approvalRiskLevelName(metadata.assessment.level))),
        ValueField("flags", listValue(flags.toArray())),
        ValueField("reasons", listValue(reasons.toArray()))
    ])
}

func applicationPlanRequiredInt(value: AgentValue, name: String): Result<Int64> {
    let field = match (value.field(name)) {
        case Some(item) => item
        case None => return applicationPlanError<Int64>(
            AgentErrorKind.InvalidInput,
            "application_plan.structure_invalid",
            "application plan is missing an integer field"
        )
    }
    if (field.unifiedKind != ValueKind.Number) {
        return applicationPlanError<Int64>(
            AgentErrorKind.InvalidInput,
            "application_plan.structure_invalid",
            "application plan field must be an integer"
        )
    }
    let parsed = try {
        Int64.parse(field.asNumberText())
    } catch (_: Exception) {
        return applicationPlanError<Int64>(
            AgentErrorKind.InvalidInput,
            "application_plan.structure_invalid",
            "application plan field must be a non-negative integer"
        )
    }
    if (parsed < 0) {
        return applicationPlanError<Int64>(
            AgentErrorKind.InvalidInput,
            "application_plan.structure_invalid",
            "application plan field must be a non-negative integer"
        )
    }
    Result.Ok(parsed)
}

func applicationPlanRequiredBool(value: AgentValue, name: String): Result<Bool> {
    let field = match (value.field(name)) {
        case Some(item) => item
        case None => return applicationPlanError<Bool>(
            AgentErrorKind.InvalidInput,
            "application_plan.structure_invalid",
            "application plan is missing a boolean field"
        )
    }
    if (field.unifiedKind != ValueKind.Boolean) {
        return applicationPlanError<Bool>(
            AgentErrorKind.InvalidInput,
            "application_plan.structure_invalid",
            "application plan field must be boolean"
        )
    }
    Result.Ok(field.asBool())
}

func productFilePlanOperationPaths(arguments: AgentValue): Array<String> {
    let operations = match (arguments.field("operations")) {
        case Some(value) => value
        case None => return []
    }
    if (operations.unifiedKind != ValueKind.List) { return [] }
    let paths = ArrayList<String>()
    for (operation in operations.items) {
        match (applicationPlanRequiredText(operation, "path")) {
            case Result.Ok(path) => paths.add(path)
            case Result.Err(_) => ()
        }
    }
    paths.toArray()
}

func productFileApplicationPrimaryCapability(
    call: ToolCall,
    workspace: LocalWorkspace
): Capability {
    let paths = productFilePlanOperationPaths(call.arguments)
    if (paths.isEmpty()) {
        Capability(CapabilityKind.WorkspaceWrite, resource: workspace.rootPath())
    } else {
        workspace.writeCapability(paths[0])
    }
}

func productFileApplicationAdditionalCapabilities(
    call: ToolCall,
    workspace: LocalWorkspace
): Array<Capability> {
    let capabilities = ArrayList<Capability>()
    let paths = productFilePlanOperationPaths(call.arguments)
    for (index in 1..paths.size) {
        capabilities.add(workspace.writeCapability(paths[index]))
    }
    capabilities.toArray()
}
func productFileRecoveryPrimaryCapability(
    call: ToolCall,
    workspace: LocalWorkspace
): Capability {
    let paths = productFilePlanOperationPaths(call.arguments)
    if (paths.isEmpty()) {
        Capability(CapabilityKind.WorkspaceRead, resource: workspace.rootPath())
    } else {
        workspace.readCapability(paths[0])
    }
}

func productFileRecoveryAdditionalCapabilities(
    call: ToolCall,
    workspace: LocalWorkspace
): Array<Capability> {
    let capabilities = ArrayList<Capability>()
    let paths = productFilePlanOperationPaths(call.arguments)
    for (index in 1..paths.size) {
        capabilities.add(workspace.readCapability(paths[index]))
    }
    capabilities.toArray()
}

func productFilePlanApprovalMetadata(
    arguments: AgentValue,
    workspaceRoot: String
): ToolApprovalMetadata {
    var level = ApprovalRiskLevel.Low
    let flags = ArrayList<String>()
    let reasons = ArrayList<String>()
    let targets = match (arguments.field("approval_targets")) {
        case Some(value) => value
        case None => nullValue()
    }
    if (targets.unifiedKind != ValueKind.List || targets.items.isEmpty()) {
        level = ApprovalRiskLevel.Critical
        flags.add("invalid_plan_summary")
        reasons.add("Application plan approval metadata is incomplete")
    } else {
        for (target in targets.items) {
            let targetRisk = match (applicationPlanRequiredText(target, "risk")) {
                case Result.Ok(value) => productApplicationRiskLevel(value)
                case Result.Err(_) => ApprovalRiskLevel.Critical
            }
            if (productApplicationRiskRank(targetRisk) > productApplicationRiskRank(level)) {
                level = targetRisk
            }
            for (flag in productApplicationTextItems(target.field("flags"))) {
                if (!flags.contains(flag)) { flags.add(flag) }
            }
            for (reason in productApplicationTextItems(target.field("reasons"))) {
                if (!reasons.contains(reason)) { reasons.add(reason) }
            }
        }
    }
    ToolApprovalMetadata(
        "workspace.write",
        RiskAssessment(level, flags: flags.toArray(), reasons: reasons.toArray()),
        ApprovalGrantScope(
            "workspace.write",
            pathPrefix: workspaceRoot,
            toolName: "apply_file_plan"
        ),
        sessionApprovalAllowed: false
    )
}

func productApplicationTextItems(value: ?AgentValue): Array<String> {
    let list = match (value) {
        case Some(item) => item
        case None => return []
    }
    if (list.unifiedKind != ValueKind.List) { return [] }
    let values = ArrayList<String>()
    for (item in list.items where item.unifiedKind == ValueKind.Text) {
        values.add(item.text)
    }
    values.toArray()
}

func productApplicationRiskLevel(value: String): ApprovalRiskLevel {
    match (value) {
        case "low" => ApprovalRiskLevel.Low
        case "medium" => ApprovalRiskLevel.Medium
        case "high" => ApprovalRiskLevel.High
        case "critical" => ApprovalRiskLevel.Critical
        case _ => ApprovalRiskLevel.Critical
    }
}

func productApplicationRiskRank(value: ApprovalRiskLevel): Int64 {
    match (value) {
        case ApprovalRiskLevel.Low => 0
        case ApprovalRiskLevel.Medium => 1
        case ApprovalRiskLevel.High => 2
        case ApprovalRiskLevel.Critical => 3
    }
}

class ProductFilePlanApplicationExecutor <: ToolExecutor {
    private let workspace: LocalWorkspace
    private let artifacts: ProductArtifactStore

    init(workspace: LocalWorkspace, artifacts: ProductArtifactStore) {
        this.workspace = workspace
        this.artifacts = artifacts
    }

    public func execute(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolResult> {
        let arguments = prepared.operationPlan.canonicalArguments
        let planRef = match (applicationPlanRequiredText(arguments, "plan_ref")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let planDigest = match (applicationPlanRequiredText(arguments, "plan_digest")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let planOperations = match (arguments.field("operations")) {
            case Some(value) => if (value.unifiedKind == ValueKind.List) { value } else {
                return applicationPlanError<ToolResult>(
                    AgentErrorKind.Conflict, "application_plan.operation_list_invalid",
                    "the prepared application operation list is missing"
                )
            }
            case None => return applicationPlanError<ToolResult>(
                AgentErrorKind.Conflict, "application_plan.operation_list_invalid",
                "the prepared application operation list is missing"
            )
        }
        let patchOperations = match (loadProductApplicationPatchOperations(
            arguments, planOperations.items.size, artifacts
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }

        let results = ArrayList<AgentValue>()
        let preflightOperations = ArrayList<ProductFileApplicationOperation>()
        var preflightContentBytes: Int64 = 0
        for (index in 0..planOperations.items.size) {
            if (context.cancellation.isCancelled()) {
                appendProductApplicationUnexecuted(
                    results, planOperations, 0, "not_started"
                )
                return Result.Ok(ToolResult(
                    prepared.call.callId,
                    productApplicationExecutionOutput(
                        "cancellation", planRef, planDigest, results.toArray()
                    ),
                    isError: true
                ))
            }
            let operation = match (revalidateProductApplicationOperation(
                planOperations.items[index], patchOperations.items[index], index,
                preflightContentBytes, workspace
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) =>
                    appendProductApplicationUnexecutedRange(
                        results, planOperations, 0, index, "not_started"
                    )
                    results.add(productApplicationFailedItem(
                        planOperations.items[index], index, "conflict", error
                    ))
                    appendProductApplicationUnexecuted(
                        results, planOperations, index + 1, "not_started"
                    )
                    return Result.Ok(ToolResult(
                        prepared.call.callId,
                        productApplicationExecutionOutput(
                            "conflict", planRef, planDigest, results.toArray()
                        ),
                        isError: true
                    ))
            }
            preflightContentBytes += operation.contentBytes
            preflightOperations.add(operation)
        }

        var totalContentBytes: Int64 = 0
        for (index in 0..preflightOperations.size) {
            if (context.cancellation.isCancelled()) {
                appendProductApplicationUnexecuted(
                    results, planOperations, index, "not_started"
                )
                return Result.Ok(ToolResult(
                    prepared.call.callId,
                    productApplicationExecutionOutput(
                        "cancellation", planRef, planDigest, results.toArray()
                    ),
                    isError: true
                ))
            }
            let operation = match (revalidateProductApplicationOperation(
                planOperations.items[index], patchOperations.items[index], index,
                totalContentBytes, workspace
            )) {
                case Result.Ok(_) => preflightOperations[index]
                case Result.Err(error) =>
                    results.add(productApplicationFailedItem(
                        planOperations.items[index], index, "conflict", error
                    ))
                    appendProductApplicationUnexecuted(
                        results, planOperations, index + 1, "not_started"
                    )
                    return Result.Ok(ToolResult(
                        prepared.call.callId,
                        productApplicationExecutionOutput(
                            "conflict", planRef, planDigest, results.toArray()
                        ),
                        isError: true
                    ))
            }
            totalContentBytes += operation.contentBytes
            let expectedContent: ?String = if (operation.kind == "replace") {
                Some(operation.expectedContent)
            } else {
                None
            }
            let written = match (workspace.writeFileIfCurrent(
                operation.path,
                expectedContent,
                operation.content
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) =>
                    let itemStatus = if (error.kind == AgentErrorKind.RecoveryRequired) {
                        "unknown"
                    } else if (error.kind == AgentErrorKind.Conflict) {
                        "conflict"
                    } else {
                        "failed_no_effect"
                    }
                    results.add(productApplicationFailedItem(
                        planOperations.items[index], index, itemStatus, error
                    ))
                    appendProductApplicationUnexecuted(
                        results, planOperations, index + 1, "not_started"
                    )
                    let output = productApplicationExecutionOutput(
                        if (itemStatus == "unknown") {
                            "unknown"
                        } else if (itemStatus == "conflict") {
                            "conflict"
                        } else {
                            "failure"
                        },
                        planRef, planDigest, results.toArray()
                    )
                    if (itemStatus == "unknown") {
                        return Result.Err(productApplicationUnknownOutcome(error, output))
                    }
                    return Result.Ok(ToolResult(
                        prepared.call.callId, output, isError: true
                    ))
            }
            let confirmed = match (productApplicationCurrentContent(
                operation.path, workspace
            )) {
                case Result.Ok(value) => value == operation.content
                case Result.Err(_) => false
            }
            if (!confirmed) {
                let error = AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "application_plan.write_unconfirmed",
                    "the published application target could not be verified",
                    fields: [
                        ErrorField("ordinal", index.toString()),
                        ErrorField("path", operation.path)
                    ]
                )
                results.add(productApplicationFailedItem(
                    planOperations.items[index], index, "unknown", error
                ))
                appendProductApplicationUnexecuted(
                    results, planOperations, index + 1, "not_started"
                )
                return Result.Err(productApplicationUnknownOutcome(
                    error,
                    productApplicationExecutionOutput(
                        "unknown", planRef, planDigest, results.toArray()
                    )
                ))
            }
            results.add(objectValue([
                ValueField("ordinal", integerValue(operation.ordinal)),
                ValueField("operation", textValue(operation.kind)),
                ValueField("path", textValue(operation.path)),
                ValueField("status", textValue("applied")),
                ValueField("write", written)
            ]))
        }
        Result.Ok(ToolResult(
            prepared.call.callId,
            productApplicationExecutionOutput(
                "complete", planRef, planDigest, results.toArray()
            )
        ))
    }
}
class ProductFilePlanRecoveryExecutor <: ToolExecutor {
    private let workspace: LocalWorkspace
    private let artifacts: ProductArtifactStore

    init(workspace: LocalWorkspace, artifacts: ProductArtifactStore) {
        this.workspace = workspace
        this.artifacts = artifacts
    }

    public func execute(
        context: ToolInvocationContext,
        prepared: PreparedToolInvocation
    ): Result<ToolResult> {
        let stored = match (loadProductStoredFileApplicationPlan(
            prepared.operationPlan.canonicalArguments, workspace, artifacts
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let results = ArrayList<AgentValue>()
        let pending = ArrayList<ProductFileApplicationOperation>()
        var totalContentBytes: Int64 = 0
        var conflicts: Int64 = 0
        var unknowns: Int64 = 0
        for (index in 0..stored.planOperations.items.size) {
            if (context.cancellation.isCancelled()) {
                appendProductApplicationRecoveryUnknown(
                    results, stored.planOperations, index
                )
                return Result.Ok(ToolResult(
                    prepared.call.callId,
                    productApplicationRecoveryOutput(
                        "cancellation", stored, results.toArray(), None
                    ),
                    isError: true
                ))
            }
            let immutable = match (parseStoredProductApplicationOperation(
                stored.planOperations.items[index],
                stored.patchOperations.items[index],
                index,
                totalContentBytes
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            totalContentBytes += immutable.contentBytes
            match (revalidateProductApplicationOperation(
                stored.planOperations.items[index],
                stored.patchOperations.items[index],
                index,
                totalContentBytes - immutable.contentBytes,
                workspace
            )) {
                case Result.Ok(value) =>
                    let continuationOrdinal = pending.size
                    pending.add(ProductFileApplicationOperation(
                        continuationOrdinal,
                        value.kind,
                        value.path,
                        value.expectedContent,
                        value.content,
                        value.precondition,
                        value.contentSha256,
                        value.contentBytes
                    ))
                    results.add(productApplicationRecoveryItem(
                        immutable, "not_started", None
                    ))
                case Result.Err(error) =>
                    match (productApplicationCurrentContent(
                        immutable.path, workspace
                    )) {
                        case Result.Ok(current) =>
                            if (current == immutable.content) {
                                results.add(productApplicationRecoveryItem(
                                    immutable, "applied", None
                                ))
                            } else {
                                conflicts += 1
                                results.add(productApplicationRecoveryItem(
                                    immutable, "conflict", Some(error)
                                ))
                            }
                        case Result.Err(observationError) =>
                            if (observationError.kind == AgentErrorKind.PermissionDenied) {
                                unknowns += 1
                                results.add(productApplicationRecoveryItem(
                                    immutable, "unknown", Some(observationError)
                                ))
                            } else {
                                conflicts += 1
                                results.add(productApplicationRecoveryItem(
                                    immutable, "conflict", Some(error)
                                ))
                            }
                    }
            }
        }
        if (unknowns > 0) {
            return Result.Ok(ToolResult(
                prepared.call.callId,
                productApplicationRecoveryOutput(
                    "unknown", stored, results.toArray(), None
                ),
                isError: true
            ))
        }
        if (conflicts > 0) {
            return Result.Ok(ToolResult(
                prepared.call.callId,
                productApplicationRecoveryOutput(
                    "conflict", stored, results.toArray(), None
                ),
                isError: true
            ))
        }
        let continuation: ?AgentValue = if (pending.isEmpty()) {
            None
        } else {
            let originalSource = stored.plan.field("source").getOrThrow()
            let source = objectValue([
                ValueField("root_operation_id", textValue(prepared.operationId.value)),
                ValueField("program_id", originalSource.field("program_id").getOrThrow()),
                ValueField("program_digest", originalSource.field("program_digest").getOrThrow()),
                ValueField("workspace_id", stored.plan.field("workspace_id").getOrThrow())
            ])
            match (persistProductApplicationPlan(
                source, pending.toArray(), artifacts
            )) {
                case Result.Ok(value) => Some(value)
                case Result.Err(error) => return Result.Err(error)
            }
        }
        Result.Ok(ToolResult(
            prepared.call.callId,
            productApplicationRecoveryOutput(
                if (pending.isEmpty()) { "reconciled_complete" } else { "continuation_ready" },
                stored,
                results.toArray(),
                continuation
            )
        ))
    }
}

func productApplicationRecoveryItem(
    operation: ProductFileApplicationOperation,
    status: String,
    error: ?AgentError
): AgentValue {
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("ordinal", integerValue(operation.ordinal)))
    fields.add(ValueField("operation", textValue(operation.kind)))
    fields.add(ValueField("path", textValue(operation.path)))
    fields.add(ValueField("status", textValue(status)))
    match (error) {
        case Some(value) =>
            fields.add(ValueField("error_code", textValue(value.code)))
            fields.add(ValueField("error_message", textValue(value.message)))
        case None => ()
    }
    objectValue(fields.toArray())
}

func appendProductApplicationRecoveryUnknown(
    results: ArrayList<AgentValue>,
    operations: AgentValue,
    start: Int64
): Unit {
    for (index in start..operations.items.size) {
        let operation = operations.items[index]
        results.add(objectValue([
            ValueField("ordinal", integerValue(index)),
            ValueField("operation", operation.field("kind").getOrThrow()),
            ValueField("path", operation.field("path").getOrThrow()),
            ValueField("status", textValue("unknown")),
            ValueField("error_code", textValue("application_plan.recovery_cancelled")),
            ValueField("error_message", textValue("recovery inspection was cancelled before this item was observed"))
        ]))
    }
}

func productApplicationRecoveryOutput(
    status: String,
    stored: ProductStoredFileApplicationPlan,
    results: Array<AgentValue>,
    continuation: ?AgentValue
): AgentValue {
    var applied: Int64 = 0
    var notStarted: Int64 = 0
    var conflict: Int64 = 0
    var unknown: Int64 = 0
    for (result in results) {
        match (result.field("status").getOrThrow().text) {
            case "applied" => applied += 1
            case "not_started" => notStarted += 1
            case "conflict" => conflict += 1
            case _ => unknown += 1
        }
    }
    objectValue([
        ValueField("status", textValue(status)),
        ValueField("original_plan_ref", textValue(stored.planRef)),
        ValueField("original_plan_digest", textValue(stored.planDigest)),
        ValueField("applied_count", integerValue(applied)),
        ValueField("not_started_count", integerValue(notStarted)),
        ValueField("conflict_count", integerValue(conflict)),
        ValueField("unknown_count", integerValue(unknown)),
        ValueField("requires_new_authorization", boolValue(
            continuation.isSome()
        )),
        ValueField("automatic_rollback", boolValue(false)),
        ValueField("compensation_requires_new_plan", boolValue(true)),
        ValueField("continuation_plan", match (continuation) {
            case Some(value) => value
            case None => nullValue()
        }),
        ValueField("results", listValue(results))
    ])
}

func loadProductApplicationPatchOperations(
    arguments: AgentValue,
    expectedCount: Int64,
    artifacts: ProductArtifactStore
): Result<AgentValue> {
    let metadata = match (arguments.field("patch_artifact")) {
        case Some(value) => value
        case None => return applicationPlanError<AgentValue>(
            AgentErrorKind.Conflict, "application_plan.patch_artifact_invalid",
            "the prepared application patch reference is missing"
        )
    }
    if (!applicationPlanObjectShape(
        metadata, ["ref", "sha256", "bytes"], ["ref", "sha256", "bytes"]
    )) {
        return applicationPlanError<AgentValue>(
            AgentErrorKind.Conflict, "application_plan.patch_artifact_invalid",
            "the prepared application patch metadata is invalid"
        )
    }
    let reference = match (applicationPlanRequiredText(metadata, "ref")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let digest = match (applicationPlanRequiredText(metadata, "sha256")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let bytes = match (applicationPlanRequiredInt(metadata, "bytes")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let text = match (readProductApplicationArtifact(
        artifacts, reference, digest, bytes, "patch"
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let patch = match (decodeAgentValue(
        text, maxBytes: PRODUCT_FILE_APPLICATION_MAX_BYTES
    )) {
        case Result.Ok(value) => value
        case Result.Err(_) => return applicationPlanError<AgentValue>(
            AgentErrorKind.Conflict, "application_plan.patch_artifact_invalid",
            "the immutable application patch is not valid JSON"
        )
    }
    if (!applicationPlanObjectShape(
        patch, ["schema", "operations"], ["schema", "operations"]
    ) || encodeAgentValue(patch) != text) {
        return applicationPlanError<AgentValue>(
            AgentErrorKind.Conflict, "application_plan.patch_artifact_invalid",
            "the immutable application patch has an invalid structure"
        )
    }
    let schema = match (applicationPlanRequiredText(patch, "schema")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let operations = match (patch.field("operations")) {
        case Some(value) => value
        case None => return applicationPlanError<AgentValue>(
            AgentErrorKind.Conflict, "application_plan.patch_artifact_invalid",
            "the immutable application patch operation list is missing"
        )
    }
    if (schema != PRODUCT_FILE_PATCH_SCHEMA ||
        operations.unifiedKind != ValueKind.List ||
        operations.items.size != expectedCount) {
        return applicationPlanError<AgentValue>(
            AgentErrorKind.Conflict, "application_plan.patch_artifact_invalid",
            "the immutable application patch does not match the prepared plan"
        )
    }
    Result.Ok(operations)
}

func appendProductApplicationUnexecuted(
    results: ArrayList<AgentValue>,
    operations: AgentValue,
    start: Int64,
    status: String
): Unit {
    appendProductApplicationUnexecutedRange(
        results, operations, start, operations.items.size, status
    )
}

func appendProductApplicationUnexecutedRange(
    results: ArrayList<AgentValue>,
    operations: AgentValue,
    start: Int64,
    end: Int64,
    status: String
): Unit {
    for (index in start..end) {
        let operation = operations.items[index]
        results.add(objectValue([
            ValueField("ordinal", integerValue(index)),
            ValueField("operation", match (operation.field("kind")) {
                case Some(value) => value
                case None => textValue("unknown")
            }),
            ValueField("path", match (operation.field("path")) {
                case Some(value) => value
                case None => textValue("")
            }),
            ValueField("status", textValue(status))
        ]))
    }
}

func productApplicationFailedItem(
    operation: AgentValue,
    ordinal: Int64,
    status: String,
    error: AgentError
): AgentValue {
    objectValue([
        ValueField("ordinal", integerValue(ordinal)),
        ValueField("operation", match (operation.field("kind")) {
            case Some(value) => value
            case None => textValue("unknown")
        }),
        ValueField("path", match (operation.field("path")) {
            case Some(value) => value
            case None => textValue("")
        }),
        ValueField("status", textValue(status)),
        ValueField("error_code", textValue(error.code)),
        ValueField("error_message", textValue(error.message))
    ])
}

func productApplicationExecutionOutput(
    stopReason: String,
    planRef: String,
    planDigest: String,
    results: Array<AgentValue>
): AgentValue {
    var applied: Int64 = 0
    var conflict: Int64 = 0
    var failedNoEffect: Int64 = 0
    var notStarted: Int64 = 0
    var unknown: Int64 = 0
    for (result in results) {
        let itemStatus = match (result.field("status")) {
            case Some(value) => value.text
            case None => "unknown"
        }
        match (itemStatus) {
            case "applied" => applied += 1
            case "conflict" => conflict += 1
            case "failed_no_effect" => failedNoEffect += 1
            case "unknown" => unknown += 1
            case _ => notStarted += 1
        }
    }
    let status = if (unknown > 0) {
        "unknown"
    } else if (applied == results.size) {
        "complete"
    } else if (applied == 0) {
        "no_effect"
    } else {
        "partial"
    }
    objectValue([
        ValueField("status", textValue(status)),
        ValueField("stop_reason", textValue(stopReason)),
        ValueField("applied", boolValue(status == "complete")),
        ValueField("plan_ref", textValue(planRef)),
        ValueField("plan_digest", textValue(planDigest)),
        ValueField("applied_count", integerValue(applied)),
        ValueField("conflict_count", integerValue(conflict)),
        ValueField("failed_no_effect_count", integerValue(failedNoEffect)),
        ValueField("not_started_count", integerValue(notStarted)),
        ValueField("unknown_count", integerValue(unknown)),
        ValueField("reconciliation_required", boolValue(unknown > 0)),
        ValueField("results", listValue(results))
    ])
}

func productApplicationUnknownOutcome(
    error: AgentError,
    output: AgentValue
): AgentError {
    let fields = ArrayList<ErrorField>()
    for (field in error.fields) { fields.add(field) }
    fields.add(ErrorField("application_result", encodeAgentValue(output)))
    AgentError(
        AgentErrorKind.RecoveryRequired,
        error.code,
        error.message,
        fields: fields.toArray()
    )
}

func productToolResultWithProgramValue(
    original: ToolResult,
    programValue: AgentValue
): ToolResult {
    let fields = ArrayList<ValueField>()
    for (field in original.output.fields) {
        if (field.name == "value") {
            fields.add(ValueField("value", programValue))
        } else {
            fields.add(field)
        }
    }
    ToolResult(
        original.callId,
        objectValue(fields.toArray()),
        isError: original.isError,
        receiptId: original.receiptId
    )
}

func productApplicationPlanFailure(
    original: ToolResult,
    error: AgentError
): ToolResult {
    let fields = ArrayList<ValueField>()
    var hasStatus = false
    var hasValue = false
    var hasCode = false
    var hasMessage = false
    if (original.output.unifiedKind == ValueKind.Object) {
        for (field in original.output.fields) {
            match (field.name) {
                case "status" =>
                    fields.add(ValueField("status", textValue("failed")))
                    hasStatus = true
                case "value" =>
                    fields.add(ValueField("value", nullValue()))
                    hasValue = true
                case "error_code" =>
                    fields.add(ValueField("error_code", textValue(error.code)))
                    hasCode = true
                case "error_message" =>
                    fields.add(ValueField("error_message", textValue(error.message)))
                    hasMessage = true
                case _ => fields.add(field)
            }
        }
    }
    if (!hasStatus) { fields.add(ValueField("status", textValue("failed"))) }
    if (!hasValue) { fields.add(ValueField("value", nullValue())) }
    if (!hasCode) { fields.add(ValueField("error_code", textValue(error.code))) }
    if (!hasMessage) { fields.add(ValueField("error_message", textValue(error.message))) }
    ToolResult(
        original.callId,
        objectValue(fields.toArray()),
        isError: true,
        receiptId: original.receiptId
    )
}
