package tool_runtime

import agent_domain.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.deriving.*

@Derive[Equatable]
public enum ToolPresentationMode { Native | Programmatic | Auto }

@Derive[Equatable]
public enum ToolProgramStatus { Completed | Partial | Failed | RecoveryRequired }

public class ToolProgramLimits {
    public let maxInstructions: UInt64
    public let maxSubCalls: UInt64
    public let maxParallelCalls: UInt64
    public let maxDepth: UInt64
    public let maxWallTimeMillis: UInt64
    public let maxComputeTimeMillis: UInt64
    public let maxResultBytes: UInt64
    public let maxLogBytes: UInt64

    public init(
        maxInstructions!: UInt64 = 10000u64,
        maxSubCalls!: UInt64 = 128u64,
        maxParallelCalls!: UInt64 = 8u64,
        maxDepth!: UInt64 = 16u64,
        maxWallTimeMillis!: UInt64 = 30000u64,
        maxComputeTimeMillis!: UInt64 = 10000u64,
        maxResultBytes!: UInt64 = 1048576u64,
        maxLogBytes!: UInt64 = 65536u64
    ) {
        if (maxInstructions == 0u64 || maxSubCalls == 0u64 || maxParallelCalls == 0u64 ||
            maxDepth == 0u64 || maxWallTimeMillis == 0u64 || maxComputeTimeMillis == 0u64 ||
            maxResultBytes == 0u64 || maxLogBytes == 0u64) {
            throw IllegalArgumentException("tool program limits must be positive")
        }
        this.maxInstructions = maxInstructions
        this.maxSubCalls = maxSubCalls
        this.maxParallelCalls = maxParallelCalls
        this.maxDepth = maxDepth
        this.maxWallTimeMillis = maxWallTimeMillis
        this.maxComputeTimeMillis = maxComputeTimeMillis
        this.maxResultBytes = maxResultBytes
        this.maxLogBytes = maxLogBytes
    }
}

public class ProgramToolInvocation {
    public let toolName: String
    public let arguments: ToolProgramExpression
    public init(toolName: String, arguments: ToolProgramExpression) {
        if (toolName.trimAscii().isEmpty()) { throw IllegalArgumentException("program tool name is empty") }
        this.toolName = toolName
        this.arguments = arguments
    }
}

public enum ToolProgramExpression {
    Literal(AgentValue)
    | Variable(String)
    | Tool(ProgramToolInvocation)
    | Parallel(Array<ProgramToolInvocation>)
    | Field(String, String)
    | MapField(String, String)
    | FilterTruthyField(String, String)
    | ReduceCount(String)
}

public enum ToolProgramStatement {
    Let(String, ToolProgramExpression)
    | IfTruthy(String, Array<ToolProgramStatement>, Array<ToolProgramStatement>)
    | ForEach(String, String, UInt64, Array<ToolProgramStatement>)
    | TryCatch(Array<ToolProgramStatement>, Array<ToolProgramStatement>)
    | Return(ToolProgramExpression)
}

public class ToolProgramIR {
    public let programId: String
    public let source: String
    public let statements: Array<ToolProgramStatement>
    public let readOnly: Bool

    public init(programId: String, source: String, statements: Array<ToolProgramStatement>, readOnly!: Bool = true) {
        if (programId.trimAscii().isEmpty() || statements.isEmpty()) {
            throw IllegalArgumentException("tool program id and statements are required")
        }
        this.programId = programId.trimAscii()
        this.source = source
        this.statements = statements
        this.readOnly = readOnly
    }
}

public func validateRestrictedToolProgramSource(source: String): Result<Unit> {
    let lowered = source.toAsciiLower()
    let forbidden = [
        "import ", "eval(", "function ", "while (", "while(", "globalthis",
        "reflect.", "process.", "require(", "child_process", "xmlhttprequest",
        "websocket(", "new function", "tools["
    ]
    for (token in forbidden where lowered.contains(token)) {
        return programAgentError<Unit>("tool_program.forbidden_syntax", "restricted program contains forbidden syntax: ${token.trimAscii()}")
    }
    Result.Ok(())
}

// The first source compiler is intentionally small: it accepts straight-line
// TS-like const tool calls and a return. Rich control flow is represented by
// the same closed IR after a trusted parser/compiler has validated it.
public func compileRestrictedToolProgram(programId: String, source: String): Result<ToolProgramIR> {
    match (validateRestrictedToolProgramSource(source)) {
        case Result.Err(error) => return Result.Err(error)
        case Result.Ok(_) => ()
    }
    let statements = ArrayList<ToolProgramStatement>()
    var sawReturn = false
    for (raw in source.replace("\n", ";").split(";")) {
        let line = raw.trimAscii()
        if (line.isEmpty()) { continue }
        if (sawReturn) {
            return programAgentError<ToolProgramIR>("tool_program.after_return", "statements after return are forbidden")
        }
        if (line.startsWith("const ")) {
            let remainder = line[6..]
            let marker = " = await "
            let separator = match (remainder.indexOf(marker)) {
                case Some(value) => value
                case None => return programAgentError<ToolProgramIR>("tool_program.parse", "const statement must await a tool call")
            }
            let name = remainder[..separator].trimAscii()
            if (!validProgramIdentifier(name)) {
                return programAgentError<ToolProgramIR>("tool_program.binding", "invalid program binding: ${name}")
            }
            let invocation = match (parseProgramToolInvocation(remainder[separator + marker.size..])) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            statements.add(ToolProgramStatement.Let(name, ToolProgramExpression.Tool(invocation)))
        } else if (line.startsWith("return ")) {
            let returned = line[7..].trimAscii()
            if (returned.startsWith("await ")) {
                let invocation = match (parseProgramToolInvocation(returned[6..])) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                statements.add(ToolProgramStatement.Return(ToolProgramExpression.Tool(invocation)))
            } else if (validProgramIdentifier(returned)) {
                statements.add(ToolProgramStatement.Return(ToolProgramExpression.Variable(returned)))
            } else {
                return programAgentError<ToolProgramIR>("tool_program.parse", "return must name a binding or await a tool call")
            }
            sawReturn = true
        } else {
            return programAgentError<ToolProgramIR>("tool_program.parse", "statement is outside the restricted TS-like subset")
        }
    }
    if (!sawReturn) { return programAgentError<ToolProgramIR>("tool_program.return_missing", "program source must return a value") }
    try {
        Result.Ok(ToolProgramIR(programId, source, statements.toArray()))
    } catch (error: IllegalArgumentException) {
        programAgentError<ToolProgramIR>("tool_program.parse", error.message)
    }
}

func parseProgramToolInvocation(source: String): Result<ProgramToolInvocation> {
    let value = source.trimAscii()
    if (!value.startsWith("tools.") || !value.endsWith(")")) {
        return programAgentError<ProgramToolInvocation>("tool_program.parse", "only static tools.name(...) calls are allowed")
    }
    let open = match (value.indexOf("(")) {
        case Some(index) => index
        case None => return programAgentError<ProgramToolInvocation>("tool_program.parse", "tool call is missing arguments")
    }
    let toolName = value[6..open].trimAscii()
    if (!validProgramIdentifier(toolName)) {
        return programAgentError<ProgramToolInvocation>("tool_program.tool_name", "tool name must be static")
    }
    let argumentsText = value[open + 1..value.size - 1].trimAscii()
    let arguments = try {
        parseUnifiedJson(argumentsText, maxBytes: 262144, maxDepth: 16)
    } catch (error: JsonException) {
        return programAgentError<ProgramToolInvocation>("tool_program.arguments", error.message)
    }
    if (arguments.unifiedKind != UnifiedJsonKind.Object) {
        return programAgentError<ProgramToolInvocation>("tool_program.arguments", "tool arguments must be a JSON object")
    }
    Result.Ok(ProgramToolInvocation(toolName, ToolProgramExpression.Literal(arguments)))
}

func validProgramIdentifier(value: String): Bool {
    if (value.isEmpty()) { return false }
    for (index in 0..value.size) {
        let byte = value.toArray()[index]
        let lower = byte >= UInt8(97) && byte <= UInt8(122)
        let upper = byte >= UInt8(65) && byte <= UInt8(90)
        let digit = byte >= UInt8(48) && byte <= UInt8(57)
        let underscore = byte == UInt8(95)
        if ((!lower && !upper && !underscore) && (index == 0 || !digit)) { return false }
    }
    true
}

public interface ToolProgramClock {
    func wallElapsedMillis(): UInt64
    func computeElapsedMillis(): UInt64
}

public class ZeroToolProgramClock <: ToolProgramClock {
    public init() {}
    public func wallElapsedMillis(): UInt64 { 0u64 }
    public func computeElapsedMillis(): UInt64 { 0u64 }
}

public interface ProgramSubOperationExecutor {
    func isReadOnly(call: ToolCall): Bool
    func invoke(context: ToolInvocationContext, call: ToolCall): Result<ToolInvocationResult>
}

public class PipelineProgramSubOperationExecutor <: ProgramSubOperationExecutor {
    private let catalog: ToolCatalog
    private let pipeline: ToolPipeline
    public init(catalog: ToolCatalog, pipeline: ToolPipeline) {
        this.catalog = catalog
        this.pipeline = pipeline
    }
    public func isReadOnly(call: ToolCall): Bool { catalog.isReadOnly(call) }
    public func invoke(context: ToolInvocationContext, call: ToolCall): Result<ToolInvocationResult> {
        pipeline.invoke(context, call)
    }
}

public class ProgramSubOperationTrace {
    public let index: UInt64
    public let call: ToolCall
    public let outcome: ToolInvocationResult
    public init(index: UInt64, call: ToolCall, outcome: ToolInvocationResult) {
        this.index = index; this.call = call; this.outcome = outcome
    }
}

public class ToolProgramResult {
    public let status: ToolProgramStatus
    public let value: AgentValue
    public let subOperations: Array<ProgramSubOperationTrace>
    public let instructions: UInt64
    public let errorCode: String
    public let errorMessage: String

    public init(
        status: ToolProgramStatus,
        value: AgentValue,
        subOperations: Array<ProgramSubOperationTrace>,
        instructions: UInt64,
        errorCode!: String = "",
        errorMessage!: String = ""
    ) {
        this.status = status; this.value = value; this.subOperations = subOperations
        this.instructions = instructions; this.errorCode = errorCode; this.errorMessage = errorMessage
    }
}

class ProgramBinding {
    let name: String
    var value: AgentValue
    init(name: String, value: AgentValue) { this.name = name; this.value = value }
}

class ProgramFailure {
    let code: String
    let message: String
    init(code: String, message: String) { this.code = code; this.message = message }
}

enum ProgramEvalResult<T> { Ok(T) | Err(ProgramFailure) }
enum ProgramFlow { Continue | Returned(AgentValue) | Failed(ProgramFailure) }

class ToolProgramExecutionState {
    let program: ToolProgramIR
    let context: ToolInvocationContext
    let executor: ProgramSubOperationExecutor
    let limits: ToolProgramLimits
    let clock: ToolProgramClock
    let bindings = ArrayList<ProgramBinding>()
    let traces = ArrayList<ProgramSubOperationTrace>()
    var instructions: UInt64 = 0u64
    var subCalls: UInt64 = 0u64

    init(program: ToolProgramIR, context: ToolInvocationContext, executor: ProgramSubOperationExecutor, limits: ToolProgramLimits, clock: ToolProgramClock) {
        this.program = program; this.context = context; this.executor = executor
        this.limits = limits; this.clock = clock
    }
}

public class ToolProgramRuntime {
    private let executor: ProgramSubOperationExecutor
    private let clock: ToolProgramClock
    public init(executor: ProgramSubOperationExecutor, clock!: ToolProgramClock = ZeroToolProgramClock()) {
        this.executor = executor; this.clock = clock
    }

    public func execute(program: ToolProgramIR, context: ToolInvocationContext, limits!: ToolProgramLimits = ToolProgramLimits()): ToolProgramResult {
        match (validateRestrictedToolProgramSource(program.source)) {
            case Result.Err(error) => return failedProgram([], 0u64, error.code, error.message)
            case Result.Ok(_) => ()
        }
        if (!program.readOnly) {
            return failedProgram([], 0u64, "tool_program.read_only_required", "the first Tool Program runtime accepts read-only programs only")
        }
        let state = ToolProgramExecutionState(program, context, executor, limits, clock)
        match (executeStatements(state, program.statements, 1u64)) {
            case ProgramFlow.Returned(value) =>
                if (programValueBytes(value) > limits.maxResultBytes) {
                    failedFromState(state, "tool_program.result_limit", "program result exceeds maxResultBytes")
                } else {
                    ToolProgramResult(ToolProgramStatus.Completed, value, state.traces.toArray(), state.instructions)
                }
            case ProgramFlow.Continue => failedFromState(state, "tool_program.return_missing", "program completed without return")
            case ProgramFlow.Failed(error) => failedFromState(state, error.code, error.message)
        }
    }
}

func executeStatements(state: ToolProgramExecutionState, statements: Array<ToolProgramStatement>, depth: UInt64): ProgramFlow {
    if (depth > state.limits.maxDepth) { return ProgramFlow.Failed(ProgramFailure("tool_program.depth_limit", "program exceeded maxDepth")) }
    for (statement in statements) {
        match (consumeInstruction(state)) {
            case Some(error) => return ProgramFlow.Failed(error)
            case None => ()
        }
        match (statement) {
            case ToolProgramStatement.Let(name, expression) =>
                let value = match (evaluate(state, expression, depth + 1u64)) {
                    case ProgramEvalResult.Ok(value) => value
                    case ProgramEvalResult.Err(error) => return ProgramFlow.Failed(error)
                }
                setBinding(state.bindings, name, value)
            case ToolProgramStatement.IfTruthy(name, yes, no) =>
                let value = match (binding(state.bindings, name)) {
                    case Some(value) => value
                    case None => return ProgramFlow.Failed(ProgramFailure("tool_program.binding_missing", "unknown binding: ${name}"))
                }
                let flow = executeStatements(state, if (truthy(value)) { yes } else { no }, depth + 1u64)
                match (flow) { case ProgramFlow.Continue => (); case _ => return flow }
            case ToolProgramStatement.ForEach(itemName, sourceName, maxItems, body) =>
                let source = match (binding(state.bindings, sourceName)) {
                    case Some(value) => value
                    case None => return ProgramFlow.Failed(ProgramFailure("tool_program.binding_missing", "unknown binding: ${sourceName}"))
                }
                if (source.unifiedKind != ValueKind.List || maxItems == 0u64 || UInt64(source.items.size) > maxItems) {
                    return ProgramFlow.Failed(ProgramFailure("tool_program.loop_bound", "for-each input exceeds its declared bound"))
                }
                for (item in source.items) {
                    setBinding(state.bindings, itemName, item)
                    let flow = executeStatements(state, body, depth + 1u64)
                    match (flow) { case ProgramFlow.Continue => (); case _ => return flow }
                }
            case ToolProgramStatement.TryCatch(body, recovery) =>
                match (executeStatements(state, body, depth + 1u64)) {
                    case ProgramFlow.Failed(_) =>
                        let flow = executeStatements(state, recovery, depth + 1u64)
                        match (flow) { case ProgramFlow.Continue => (); case _ => return flow }
                    case ProgramFlow.Continue => ()
                    case value => return value
                }
            case ToolProgramStatement.Return(expression) =>
                match (evaluate(state, expression, depth + 1u64)) {
                    case ProgramEvalResult.Ok(value) => return ProgramFlow.Returned(value)
                    case ProgramEvalResult.Err(error) => return ProgramFlow.Failed(error)
                }
        }
    }
    ProgramFlow.Continue
}

func evaluate(state: ToolProgramExecutionState, expression: ToolProgramExpression, depth: UInt64): ProgramEvalResult<AgentValue> {
    if (depth > state.limits.maxDepth) { return ProgramEvalResult.Err(ProgramFailure("tool_program.depth_limit", "program exceeded maxDepth")) }
    match (consumeInstruction(state)) {
        case Some(error) => return ProgramEvalResult.Err(error)
        case None => ()
    }
    match (expression) {
        case ToolProgramExpression.Literal(value) => ProgramEvalResult.Ok(value)
        case ToolProgramExpression.Variable(name) => match (binding(state.bindings, name)) {
            case Some(value) => ProgramEvalResult.Ok(value)
            case None => ProgramEvalResult.Err(ProgramFailure("tool_program.binding_missing", "unknown binding: ${name}"))
        }
        case ToolProgramExpression.Tool(invocation) => invokeProgramTool(state, invocation, depth + 1u64)
        case ToolProgramExpression.Parallel(invocations) =>
            if (invocations.isEmpty() || UInt64(invocations.size) > state.limits.maxParallelCalls) {
                return ProgramEvalResult.Err(ProgramFailure("tool_program.parallel_limit", "parallel group exceeds maxParallelCalls"))
            }
            let values = ArrayList<AgentValue>()
            for (invocation in invocations) {
                match (invokeProgramTool(state, invocation, depth + 1u64)) {
                    case ProgramEvalResult.Ok(value) => values.add(value)
                    case ProgramEvalResult.Err(error) => return ProgramEvalResult.Err(error)
                }
            }
            ProgramEvalResult.Ok(listValue(values.toArray()))
        case ToolProgramExpression.Field(sourceName, fieldName) =>
            let source = match (binding(state.bindings, sourceName)) {
                case Some(value) => value
                case None => return ProgramEvalResult.Err(ProgramFailure("tool_program.binding_missing", "unknown binding: ${sourceName}"))
            }
            match (source.field(fieldName)) {
                case Some(value) => ProgramEvalResult.Ok(value)
                case None => ProgramEvalResult.Err(ProgramFailure("tool_program.field_missing", "object field is missing: ${fieldName}"))
            }
        case ToolProgramExpression.MapField(sourceName, fieldName) => mapField(state, sourceName, fieldName)
        case ToolProgramExpression.FilterTruthyField(sourceName, fieldName) => filterTruthyField(state, sourceName, fieldName)
        case ToolProgramExpression.ReduceCount(sourceName) =>
            match (binding(state.bindings, sourceName)) {
                case Some(value) => if (value.unifiedKind == ValueKind.List) {
                    ProgramEvalResult.Ok(integerValue(Int64(value.items.size)))
                } else { ProgramEvalResult.Err(ProgramFailure("tool_program.type", "reduce count requires a list")) }
                case None => ProgramEvalResult.Err(ProgramFailure("tool_program.binding_missing", "unknown binding: ${sourceName}"))
            }
    }
}

func invokeProgramTool(state: ToolProgramExecutionState, invocation: ProgramToolInvocation, depth: UInt64): ProgramEvalResult<AgentValue> {
    if (state.subCalls >= state.limits.maxSubCalls) {
        return ProgramEvalResult.Err(ProgramFailure("tool_program.subcall_limit", "program exceeded maxSubCalls"))
    }
    let arguments = match (evaluate(state, invocation.arguments, depth + 1u64)) {
        case ProgramEvalResult.Ok(value) => value
        case ProgramEvalResult.Err(error) => return ProgramEvalResult.Err(error)
    }
    state.subCalls += 1u64
    let call = ToolCall("${state.program.programId}-sub-${state.subCalls}", invocation.toolName, arguments)
    if (!state.executor.isReadOnly(call)) {
        return ProgramEvalResult.Err(ProgramFailure("tool_program.side_effect_denied", "read-only program cannot invoke side-effecting or unknown tool: ${invocation.toolName}"))
    }
    match (state.executor.invoke(state.context, call)) {
        case Result.Err(error) => ProgramEvalResult.Err(ProgramFailure(error.code, error.message))
        case Result.Ok(outcome) =>
            state.traces.add(ProgramSubOperationTrace(state.subCalls, call, outcome))
            match (outcome) {
                case ToolInvocationResult.Completed(result) =>
                    if (result.isError) { ProgramEvalResult.Err(ProgramFailure("tool_program.subcall_failed", "sub-operation returned an error")) }
                    else { ProgramEvalResult.Ok(result.output) }
                case ToolInvocationResult.NeedsApproval(_) => ProgramEvalResult.Err(ProgramFailure("tool_program.approval_required", "read-only sub-operation unexpectedly requires approval"))
                case ToolInvocationResult.Denied(denial) => ProgramEvalResult.Err(ProgramFailure(denial.reason.code, denial.reason.message))
            }
    }
}

func mapField(state: ToolProgramExecutionState, sourceName: String, fieldName: String): ProgramEvalResult<AgentValue> {
    let source = match (binding(state.bindings, sourceName)) {
        case Some(value) => value
        case None => return ProgramEvalResult.Err(ProgramFailure("tool_program.binding_missing", "unknown binding: ${sourceName}"))
    }
    if (source.unifiedKind != ValueKind.List) { return ProgramEvalResult.Err(ProgramFailure("tool_program.type", "map requires a list")) }
    let values = ArrayList<AgentValue>()
    for (item in source.items) {
        match (item.field(fieldName)) {
            case Some(value) => values.add(value)
            case None => return ProgramEvalResult.Err(ProgramFailure("tool_program.field_missing", "mapped field is missing: ${fieldName}"))
        }
    }
    ProgramEvalResult.Ok(listValue(values.toArray()))
}

func filterTruthyField(state: ToolProgramExecutionState, sourceName: String, fieldName: String): ProgramEvalResult<AgentValue> {
    let source = match (binding(state.bindings, sourceName)) {
        case Some(value) => value
        case None => return ProgramEvalResult.Err(ProgramFailure("tool_program.binding_missing", "unknown binding: ${sourceName}"))
    }
    if (source.unifiedKind != ValueKind.List) { return ProgramEvalResult.Err(ProgramFailure("tool_program.type", "filter requires a list")) }
    let values = ArrayList<AgentValue>()
    for (item in source.items) {
        match (item.field(fieldName)) {
            case Some(value) => if (truthy(value)) { values.add(item) }
            case None => ()
        }
    }
    ProgramEvalResult.Ok(listValue(values.toArray()))
}

func consumeInstruction(state: ToolProgramExecutionState): ?ProgramFailure {
    state.instructions += 1u64
    if (state.instructions > state.limits.maxInstructions) { return Some(ProgramFailure("tool_program.instruction_limit", "program exceeded maxInstructions")) }
    if (state.clock.wallElapsedMillis() > state.limits.maxWallTimeMillis) { return Some(ProgramFailure("tool_program.wall_time_limit", "program exceeded maxWallTime")) }
    if (state.clock.computeElapsedMillis() > state.limits.maxComputeTimeMillis) { return Some(ProgramFailure("tool_program.compute_time_limit", "program exceeded maxComputeTime")) }
    None
}

func binding(values: ArrayList<ProgramBinding>, name: String): ?AgentValue {
    for (item in values where item.name == name) { return Some(item.value) }
    None
}

func setBinding(values: ArrayList<ProgramBinding>, name: String, value: AgentValue): Unit {
    if (name.trimAscii().isEmpty()) { throw IllegalArgumentException("program binding name is empty") }
    for (item in values where item.name == name) { item.value = value; return }
    values.add(ProgramBinding(name, value))
}

func truthy(value: AgentValue): Bool {
    match (value.unifiedKind) {
        case ValueKind.Null => false
        case ValueKind.Boolean => value.boolean
        case ValueKind.Text | ValueKind.Number => !value.text.isEmpty() && value.text != "0"
        case ValueKind.List => !value.items.isEmpty()
        case ValueKind.Object => !value.fields.isEmpty()
    }
}

func programValueBytes(value: AgentValue): UInt64 {
    var size: UInt64 = 8u64 + UInt64(value.text.size)
    for (item in value.items) { size += programValueBytes(item) }
    for (field in value.fields) { size += UInt64(field.name.size) + programValueBytes(field.value) }
    size
}

func failedFromState(state: ToolProgramExecutionState, code: String, message: String): ToolProgramResult {
    let status = if (state.traces.isEmpty()) { ToolProgramStatus.Failed } else { ToolProgramStatus.Partial }
    ToolProgramResult(status, nullValue(), state.traces.toArray(), state.instructions, errorCode: code, errorMessage: message)
}

func failedProgram(traces: Array<ProgramSubOperationTrace>, instructions: UInt64, code: String, message: String): ToolProgramResult {
    ToolProgramResult(ToolProgramStatus.Failed, nullValue(), traces, instructions, errorCode: code, errorMessage: message)
}

func programAgentError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput, code, message))
}
