package agent_product

import yjson_support.*
import yjson.*
import agent_domain.*
import tool_runtime.*
import agent_host_runtime
import std.collection.*

// Compatibility names refer to the one shared host interaction owner.
public type ProductAskOption = agent_host_runtime.HostAskOption
public type ProductAskQuestion = agent_host_runtime.HostAskQuestion
public type ProductAskRequest = agent_host_runtime.HostAskRequest
public type ProductAskAnswer = agent_host_runtime.HostAskAnswer
public type ProductAskResolution = agent_host_runtime.HostAskResolution
public type ProductAskEventSink = agent_host_runtime.HostAskEventSink
public type AskRuntime = agent_host_runtime.HostAskRuntime

public class AskTool <: ToolExecutor {
    private let runtime: AskRuntime

    public init(runtime: AskRuntime) {
        this.runtime = runtime
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
        let questions = match (parseAskQuestions(call)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (runtime.ask(
            context, call.callId, questions,
            operationId: prepared.operationId.value
        )) {
            case Result.Ok(ProductAskResolution.Chat) =>
                let questionTexts = ArrayList<AgentValue>()
                var joined = ""
                for (question in questions) {
                    questionTexts.add(textValue(question.question))
                    if (joined != "") { joined += "\n" }
                    joined += question.question
                }
                Result.Ok(ToolResult(
                    call.callId,
                    objectValue([
                        ValueField(
                            "content",
                            textValue(
                                "User chose to chat about this instead of " +
                                "answering.\n\nQuestions asked:\n" + joined
                            )
                        ),
                        ValueField("chatRedirect", boolValue(true)),
                        ValueField(
                            "questions",
                            listValue(questionTexts.toArray())
                        )
                    ])
                ))
            case Result.Ok(ProductAskResolution.Answers(answers)) =>
                Result.Ok(ToolResult(
                    call.callId,
                    agent_host_runtime.askAnswerOutput(
                        questions,
                        agent_host_runtime.normalizeTimedOutAskAnswers(
                            questions,
                            answers
                        )
                    )
                ))
            case Result.Ok(ProductAskResolution.Cancelled) =>
                Result.Err(AgentError(
                    AgentErrorKind.Cancelled,
                    "ask.cancelled",
                    "Ask tool was cancelled by the user"
                ))
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func cancel(runId: RunId): Result<Unit> {
        runtime.cancel(runId)
    }
}

func parseAskQuestions(
    call: ToolCall
): Result<Array<ProductAskQuestion>> {
    let raw = match (call.arguments.field("questions")) {
        case Some(value) => value
        case None =>
            return invalidArgument(
                call,
                "questions",
                "required argument is missing"
            )
    }
    if (raw.unifiedKind != ValueKind.List || raw.items.isEmpty()) {
        return invalidArgument(
            call,
            "questions",
            "questions must be a non-empty array"
        )
    }
    let questions = ArrayList<ProductAskQuestion>()
    for (rawQuestion in raw.items) {
        if (rawQuestion.unifiedKind != ValueKind.Object) {
            return invalidArgument(
                call,
                "questions",
                "each question must be an object"
            )
        }
        let id = match (requiredAskText(rawQuestion, "id")) {
            case Some(value) => value
            case None =>
                return invalidArgument(
                    call,
                    "questions",
                    "each question requires a string id"
                )
        }
        let question = match (
            requiredAskText(rawQuestion, "question")
        ) {
            case Some(value) => value
            case None =>
                return invalidArgument(
                    call,
                    "questions",
                    "each question requires question text"
                )
        }
        let rawOptions = match (rawQuestion.field("options")) {
            case Some(value) => value
            case None =>
                return invalidArgument(
                    call,
                    "questions",
                    "each question requires an options array"
                )
        }
        if (rawOptions.unifiedKind != ValueKind.List) {
            return invalidArgument(
                call,
                "questions",
                "question options must be an array"
            )
        }
        let options = ArrayList<ProductAskOption>()
        for (rawOption in rawOptions.items) {
            if (rawOption.unifiedKind != ValueKind.Object) {
                return invalidArgument(
                    call,
                    "questions",
                    "each option must be an object"
                )
            }
            let label = match (requiredAskText(
                rawOption,
                "label"
            )) {
                case Some(value) => value
                case None =>
                    return invalidArgument(
                        call,
                        "questions",
                        "each option requires a string label"
                    )
            }
            if (reservedAskLabel(label)) {
                return invalidArgument(
                    call,
                    "questions",
                    "option label is reserved by the ask runtime: " +
                        label
                )
            }
            let description = match (agent_host_runtime.optionalAskText(
                rawOption,
                "description"
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            let preview = match (agent_host_runtime.optionalAskText(
                rawOption,
                "preview"
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            options.add(ProductAskOption(
                label,
                description: description,
                preview: preview
            ))
        }
        let header = match (agent_host_runtime.optionalAskText(
            rawQuestion,
            "header"
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let multi = match (agent_host_runtime.optionalAskBoolean(
            rawQuestion,
            "multi"
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let recommended = match (agent_host_runtime.optionalAskInteger(
            rawQuestion,
            "recommended"
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        questions.add(ProductAskQuestion(
            id,
            question,
            options.toArray(),
            header: header,
            multi: multi,
            recommended: recommended
        ))
    }
    Result.Ok(questions.toArray())
}

func requiredAskText(value: AgentValue, name: String): ?String {
    agent_host_runtime.requiredAskText(value, name)
}

func reservedAskLabel(value: String): Bool {
    agent_host_runtime.reservedAskLabel(value)
}
