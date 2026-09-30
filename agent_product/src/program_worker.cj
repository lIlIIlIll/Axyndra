package agent_product

import yjson_support.*
import yjson_support.UnifiedJsonAccess
import yjson.*
import agent_domain.*
import tool_runtime.*
import model_adapters.*
import std.convert.*
import std.env.*
import std.fs.*
import std.time.*
import process4cj.*

let PRODUCT_TOOL_PROGRAM_WORKER_PROTOCOL: Int64 = 1
let PRODUCT_TOOL_PROGRAM_MAX_SOURCE_BYTES: Int64 = 262144

// The worker uses elapsed monotonic time as a conservative compute upper bound
// because the supported SDK does not expose process CPU time.
class ProductToolProgramClock <: ToolProgramClock {
    private let origin = MonoTime.now()

    public init() {}

    private func elapsedMillis(): UInt64 {
        let elapsed = (MonoTime.now() - origin).toMilliseconds()
        if (elapsed <= 0) { 0u64 } else { UInt64(elapsed) }
    }

    public func wallElapsedMillis(): UInt64 { elapsedMillis() }
    public func computeElapsedMillis(): UInt64 { elapsedMillis() }
}

class StdioProgramBridge <: ProgramSubOperationExecutor {
    private let programId: String
    private var sequence: UInt64 = 0u64

    init(programId: String) { this.programId = programId }

    // The worker has no tool catalog. Host admission is the authority check;
    // returning true here only lets the closed IR reach that host check.
    public func isReadOnly(_call: ToolCall): Bool { true }

    public func invoke(
        _context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolInvocationResult> {
        sequence += 1u64
        if (call.callId != programId + "-sub-" + sequence.toString()) {
            return workerBridgeError<ToolInvocationResult>(
                AgentErrorKind.Protocol,
                "tool_program.request_identity_invalid",
                "worker tool request sequence did not match the Program interpreter"
            )
        }
        let request = objectValue([
            ValueField("protocol", integerValue(PRODUCT_TOOL_PROGRAM_WORKER_PROTOCOL)),
            ValueField("kind", textValue("tool_call")),
            ValueField("sequence", integerValue(workerInt64(sequence))),
            ValueField("call_id", textValue(call.callId)),
            ValueField("tool", textValue(call.name)),
            ValueField("arguments", call.arguments)
        ])
        try {
            let output = getStdOut()
            output.write((encodeAgentValue(request) + "\n").toArray())
            output.flush()
            let response = match (readLineBounded(
                getStdIn(), 1048576, allowPartialAtEof: false
            )) {
                case Some(value) => value
                case None => return workerBridgeError<ToolInvocationResult>(
                    AgentErrorKind.RecoveryRequired,
                    "tool_program.bridge_response_missing",
                    "host ended the Program bridge before answering a tool request"
                )
            }
            decodeWorkerBridgeResponse(response, sequence, call)
        } catch (error: Exception) {
            workerBridgeError<ToolInvocationResult>(
                AgentErrorKind.Protocol,
                "tool_program.bridge_io",
                error.message
            )
        }
    }
}

func decodeWorkerBridgeResponse(
    source: String,
    sequence: UInt64,
    call: ToolCall
): Result<ToolInvocationResult> {
    let response = try {
        parseUnifiedJson(source, maxBytes: 1048576, maxDepth: 16)
    } catch (_: JsonException) {
        return workerBridgeError<ToolInvocationResult>(
            AgentErrorKind.Protocol,
            "tool_program.bridge_response_invalid",
            "host returned an invalid Program bridge response"
        )
    }
    if (response.unifiedKind != ValueKind.Object ||
        workerTextField(response, "kind") != "tool_result" ||
        workerTextField(response, "protocol") != PRODUCT_TOOL_PROGRAM_WORKER_PROTOCOL.toString() ||
        workerTextField(response, "sequence") != workerInt64(sequence).toString() ||
        workerTextField(response, "call_id") != call.callId) {
        return workerBridgeError<ToolInvocationResult>(
            AgentErrorKind.Protocol,
            "tool_program.bridge_response_identity_mismatch",
            "host response did not match the outstanding Program tool request"
        )
    }
    match (workerTextField(response, "outcome")) {
        case "completed" =>
            let output = match (response.field("output")) {
                case Some(value) => value
                case None => return workerBridgeError<ToolInvocationResult>(
                    AgentErrorKind.Protocol,
                    "tool_program.bridge_result_missing",
                    "host omitted the child tool result"
                )
            }
            let isError = match (response.field("is_error")) {
                case Some(value) => value.asBool()
                case None => false
            }
            Result.Ok(ToolInvocationResult.Completed(ToolResult(
                call.callId,
                output,
                isError: isError,
                receiptId: workerTextField(response, "receipt_id")
            )))
        case "denied" => Result.Ok(ToolInvocationResult.Denied(ToolDenial(
            call.callId,
            call.name,
            AgentError(
                AgentErrorKind.PermissionDenied,
                workerTextField(response, "error_code"),
                workerTextField(response, "error_message")
            )
        )))
        case _ => workerBridgeError<ToolInvocationResult>(
            AgentErrorKind.Protocol,
            "tool_program.bridge_outcome_invalid",
            "host returned an unsupported Program bridge outcome"
        )
    }
}

func workerTextField(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(node) => node.text
        case None => ""
    }
}

func workerBridgeError<T>(kind: AgentErrorKind, code: String, message: String): Result<T> {
    Result.Err(AgentError(kind, code, message))
}

public func isProductToolProgramWorker(arguments: Array<String>): Bool {
    arguments.size > 1 && arguments[1] == "__tool-program-worker-v1"
}

// The worker accepts only a content-addressed, host-staged source file and
// bounded interpreter limits. It has no provider, workspace, or tool authority.
public func runProductToolProgramWorker(arguments: Array<String>): Int64 {
    if (arguments.size != 12) { return 2 }
    let expectedDigest = arguments[2].trimAscii().toAsciiLower()
    let sourcePath = arguments[3]
    if (expectedDigest.size != 64 || !Path(sourcePath).isAbsolute()) { return 2 }

    let limits = match (workerLimits(arguments)) {
        case Some(value) => value
        case None => return 2
    }
    let sourceBytes = try {
        let info = FileInfo(Path(sourcePath))
        if (!info.isRegular() || info.isSymbolicLink() ||
            info.size < 0 || info.size > PRODUCT_TOOL_PROGRAM_MAX_SOURCE_BYTES) {
            return 2
        }
        File.readFrom(Path(sourcePath))
    } catch (_: Exception) {
        return 2
    }
    if (artifactSha256(sourceBytes) != expectedDigest) { return 2 }

    let source = try {
        String.fromUtf8(sourceBytes)
    } catch (_: Exception) {
        return 2
    }
    let program = match (compileRestrictedToolProgram(expectedDigest, source)) {
        case Result.Ok(value) => value
        case Result.Err(error) =>
            return emitProductToolProgramWorkerResult(
                ToolProgramResult(
                    ToolProgramStatus.Failed,
                    nullValue(),
                    [],
                    0u64,
                    errorCode: error.code,
                    errorMessage: error.message
                ),
                expectedDigest
            )
    }
    let result = ToolProgramRuntime(
        StdioProgramBridge(expectedDigest),
        clock: ProductToolProgramClock()
    ).execute(
        program,
        ToolInvocationContext(
            RunId("isolated-program-worker"),
            SessionId("isolated-program-worker"),
            CapabilitySet(values: [])
        ),
        limits: limits
    )
    emitProductToolProgramWorkerResult(result, expectedDigest)
}

func workerLimits(arguments: Array<String>): ?ToolProgramLimits {
    let maxInstructions = workerUnsigned(arguments[4])
    let maxSubCalls = workerUnsigned(arguments[5])
    let maxParallelCalls = workerUnsigned(arguments[6])
    let maxDepth = workerUnsigned(arguments[7])
    let maxWallTimeMillis = workerUnsigned(arguments[8])
    let maxComputeTimeMillis = workerUnsigned(arguments[9])
    let maxResultBytes = workerUnsigned(arguments[10])
    let maxLogBytes = workerUnsigned(arguments[11])
    if (maxInstructions.isNone() || maxSubCalls.isNone() || maxParallelCalls.isNone() ||
        maxDepth.isNone() || maxWallTimeMillis.isNone() || maxComputeTimeMillis.isNone() ||
        maxResultBytes.isNone() || maxLogBytes.isNone()) {
        return None
    }
    try {
        Some(ToolProgramLimits(
            maxInstructions: maxInstructions.getOrThrow(),
            maxSubCalls: maxSubCalls.getOrThrow(),
            maxParallelCalls: maxParallelCalls.getOrThrow(),
            maxDepth: maxDepth.getOrThrow(),
            maxWallTimeMillis: maxWallTimeMillis.getOrThrow(),
            maxComputeTimeMillis: maxComputeTimeMillis.getOrThrow(),
            maxResultBytes: maxResultBytes.getOrThrow(),
            maxLogBytes: maxLogBytes.getOrThrow()
        ))
    } catch (_: IllegalArgumentException) {
        None
    }
}

func workerUnsigned(value: String): ?UInt64 {
    try { Some(UInt64.parse(value)) } catch (_: Exception) { None }
}

func emitProductToolProgramWorkerResult(
    result: ToolProgramResult,
    artifactDigest: String
): Int64 {
    let status = match (result.status) {
        case ToolProgramStatus.Completed => "completed"
        case ToolProgramStatus.Partial => "partial"
        case ToolProgramStatus.Failed => "failed"
        case ToolProgramStatus.RecoveryRequired => "recovery_required"
    }
    let output = objectValue([
        ValueField("protocol", integerValue(PRODUCT_TOOL_PROGRAM_WORKER_PROTOCOL)),
        ValueField("kind", textValue("complete")),
        ValueField("worker_process_id", integerValue(getProcessId())),
        ValueField("program_artifact_sha256", textValue(artifactDigest)),
        ValueField("status", textValue(status)),
        ValueField("value", result.value),
        ValueField("instructions", integerValue(workerInt64(result.instructions))),
        ValueField("sub_operation_count", integerValue(result.subOperations.size)),
        ValueField("error_code", textValue(result.errorCode)),
        ValueField("error_message", textValue(result.errorMessage))
    ])
    let writer = getStdOut()
    writer.write((encodeAgentValue(output) + "\n").toArray())
    writer.flush()
    0
}

func workerInt64(value: UInt64): Int64 {
    if (value > UInt64(Int64.Max)) { Int64.Max } else { Int64(value) }
}
