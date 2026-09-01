package agent_product

import yjson_support.*

import yjson.*

import agent_domain.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.sync.*

public class ProductAskOption {
    public let label: String
    public let description: String
    public let preview: String

    public init(
        label: String,
        description!: String = "",
        preview!: String = ""
    ) {
        this.label = label
        this.description = description
        this.preview = preview
    }
}

public class ProductAskQuestion {
    public let id: String
    public let question: String
    public let header: String
    public let options: Array<ProductAskOption>
    public let multi: Bool
    public let recommended: ?Int64

    public init(
        id: String,
        question: String,
        options: Array<ProductAskOption>,
        header!: String = "",
        multi!: Bool = false,
        recommended!: ?Int64 = None
    ) {
        this.id = id
        this.question = question
        this.header = header
        this.options = options
        this.multi = multi
        this.recommended = recommended
    }
}

public class ProductAskRequest {
    public let requestId: String
    public let runId: RunId
    public let sessionId: SessionId
    public let callId: String
    public let questions: Array<ProductAskQuestion>

    public init(
        requestId: String,
        runId: RunId,
        sessionId: SessionId,
        callId: String,
        questions: Array<ProductAskQuestion>
    ) {
        this.requestId = requestId
        this.runId = runId
        this.sessionId = sessionId
        this.callId = callId
        this.questions = questions
    }
}

public class ProductAskAnswer {
    public let id: String
    public let selectedOptions: Array<String>
    public let customInput: ?String
    public let note: ?String
    public let timedOut: Bool

    public init(
        id: String,
        selectedOptions!: Array<String> = [],
        customInput!: ?String = None,
        note!: ?String = None,
        timedOut!: Bool = false
    ) {
        this.id = id
        this.selectedOptions = selectedOptions
        this.customInput = customInput
        this.note = note
        this.timedOut = timedOut
    }
}

public enum ProductAskResolution {
    Answers(Array<ProductAskAnswer>)
    | Chat
    | Cancelled
}

public type ProductAskEventSink = (ProductAskRequest) -> Unit

class PendingProductAsk {
    let request: ProductAskRequest
    var resolution: ?ProductAskResolution = None

    init(request: ProductAskRequest) {
        this.request = request
    }
}

public class AskRuntime {
    private let lock = Mutex()
    private let interactiveSessions = ArrayList<String>()
    private let pending = ArrayList<PendingProductAsk>()
    private let subscribers = ArrayList<ProductAskEventSink>()

    public init() {}

    public func setInteractive(
        sessionId: SessionId,
        enabled: Bool
    ): Unit {
        lock.lock()
        try {
            let index = stringIndex(
                interactiveSessions,
                sessionId.value
            )
            if (enabled && index < 0) {
                interactiveSessions.add(sessionId.value)
            } else if (!enabled && index >= 0) {
                interactiveSessions.remove(at: index)
            }
        } finally {
            lock.unlock()
        }
    }

    public func subscribe(sink: ProductAskEventSink): Unit {
        lock.lock()
        try {
            subscribers.add(sink)
        } finally {
            lock.unlock()
        }
    }

    public func current(sessionId: SessionId): ?ProductAskRequest {
        lock.lock()
        try {
            for (state in pending
                 where state.request.sessionId.value == sessionId.value) {
                return Some(state.request)
            }
            None
        } finally {
            lock.unlock()
        }
    }

    public func resolve(
        sessionId: SessionId,
        requestId: String,
        resolution: ProductAskResolution
    ): Result<Unit> {
        lock.lock()
        try {
            for (state in pending
                 where state.request.requestId == requestId &&
                     state.request.sessionId.value == sessionId.value) {
                if (state.resolution.isSome()) {
                    return Result.Err(AgentError(
                        AgentErrorKind.Conflict,
                        "ask.already_resolved",
                        "Ask request has already been resolved"
                    ))
                }
                match (validateAskResolution(
                    state.request,
                    resolution
                )) {
                    case Result.Ok(_) =>
                        state.resolution = Some(resolution)
                        return Result.Ok(())
                    case Result.Err(error) => return Result.Err(error)
                }
            }
            Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "ask.request_not_found",
                "No pending ask request matches the supplied request ID",
                fields: [ErrorField("request_id", requestId)]
            ))
        } finally {
            lock.unlock()
        }
    }

    public func cancel(runId: RunId): Result<Unit> {
        lock.lock()
        try {
            for (state in pending
                 where state.request.runId.value == runId.value) {
                if (state.resolution.isNone()) {
                    state.resolution = Some(
                        ProductAskResolution.Cancelled
                    )
                }
            }
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    func ask(
        context: ToolInvocationContext,
        callId: String,
        questions: Array<ProductAskQuestion>
    ): Result<ProductAskResolution> {
        let request = ProductAskRequest(
            context.runId.value + ":" + callId,
            context.runId,
            context.sessionId,
            callId,
            questions
        )
        let sinks = ArrayList<ProductAskEventSink>()
        lock.lock()
        try {
            if (stringIndex(
                interactiveSessions,
                context.sessionId.value
            ) < 0) {
                return Result.Err(AgentError(
                    AgentErrorKind.Cancelled,
                    "ask.interactive_required",
                    "Ask tool requires interactive mode"
                ))
            }
            for (state in pending
                 where state.request.sessionId.value ==
                     context.sessionId.value) {
                return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "ask.already_pending",
                    "Another ask request is already waiting for input"
                ))
            }
            pending.add(PendingProductAsk(request))
            for (sink in subscribers) { sinks.add(sink) }
        } finally {
            lock.unlock()
        }
        for (sink in sinks) { sink(request) }

        while (true) {
            lock.lock()
            try {
                for (index in 0..pending.size) {
                    let state = pending[index]
                    if (state.request.requestId != request.requestId) {
                        continue
                    }
                    match (state.resolution) {
                        case Some(value) =>
                            pending.remove(at: index)
                            return match (value) {
                                case ProductAskResolution.Cancelled =>
                                    Result.Err(AgentError(
                                        AgentErrorKind.Cancelled,
                                        "ask.cancelled",
                                        "Ask tool was cancelled by the user"
                                    ))
                                case _ => Result.Ok(value)
                            }
                        case None => ()
                    }
                    break
                }
            } finally {
                lock.unlock()
            }
            sleep(Duration.millisecond * 10)
        }
        Result.Err(AgentError(
            AgentErrorKind.Internal,
            "ask.wait_terminated",
            "Ask wait loop terminated unexpectedly"
        ))
    }
}

public class AskTool <: ToolExecutor {
    private let runtime: AskRuntime

    public init(runtime: AskRuntime) {
        this.runtime = runtime
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let questions = match (parseAskQuestions(call)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (runtime.ask(context, call.callId, questions)) {
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
                    askAnswerOutput(
                        questions,
                        normalizeTimedOutAskAnswers(
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
            let description = match (optionalAskText(
                rawOption,
                "description"
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            let preview = match (optionalAskText(
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
        let header = match (optionalAskText(
            rawQuestion,
            "header"
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let multi = match (optionalAskBoolean(
            rawQuestion,
            "multi"
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let recommended = match (optionalAskInteger(
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

func validateAskResolution(
    request: ProductAskRequest,
    resolution: ProductAskResolution
): Result<Unit> {
    let answers = match (resolution) {
        case ProductAskResolution.Answers(values) => values
        case _ => return Result.Ok(())
    }
    if (answers.size != request.questions.size) {
        return invalidAskAnswer(
            "answer count does not match question count"
        )
    }
    for (index in 0..request.questions.size) {
        let question = request.questions[index]
        let answer = answers[index]
        if (answer.id != question.id) {
            return invalidAskAnswer(
                "answer IDs must match question order"
            )
        }
        if (!question.multi && answer.selectedOptions.size > 1) {
            return invalidAskAnswer(
                "single-select question has multiple answers"
            )
        }
        if (!question.multi && answer.selectedOptions.size > 0 &&
            answer.customInput.isSome()) {
            return invalidAskAnswer(
                "single-select answer cannot contain an option and custom input"
            )
        }
        if (answer.selectedOptions.isEmpty() &&
            answer.customInput.isNone() && !answer.timedOut) {
            return invalidAskAnswer(
                "answer must select an option or provide custom input"
            )
        }
        for (selected in answer.selectedOptions) {
            var found = false
            for (option in question.options) {
                if (option.label == selected) {
                    found = true
                }
            }
            if (!found) {
                return invalidAskAnswer(
                    "selected option is not present in the question: " +
                        selected
                )
            }
        }
        for (left in 0..answer.selectedOptions.size) {
            for (right in (left + 1)..answer.selectedOptions.size) {
                if (answer.selectedOptions[left] ==
                    answer.selectedOptions[right]) {
                    return invalidAskAnswer(
                        "selected options must not contain duplicates"
                    )
                }
            }
        }
    }
    Result.Ok(())
}

func normalizeTimedOutAskAnswers(
    questions: Array<ProductAskQuestion>,
    answers: Array<ProductAskAnswer>
): Array<ProductAskAnswer> {
    let normalized = ArrayList<ProductAskAnswer>()
    for (index in 0..answers.size) {
        let answer = answers[index]
        let question = questions[index]
        if (answer.timedOut && answer.selectedOptions.isEmpty() &&
            answer.customInput.isNone() && !question.options.isEmpty()) {
            let selectedIndex = match (question.recommended) {
                case Some(value) =>
                    if (value >= 0 && value < question.options.size) {
                        value
                    } else {
                        0
                    }
                case None => 0
            }
            normalized.add(ProductAskAnswer(
                answer.id,
                selectedOptions: [
                    question.options[selectedIndex].label
                ],
                note: answer.note,
                timedOut: true
            ))
        } else {
            normalized.add(answer)
        }
    }
    normalized.toArray()
}

func askAnswerOutput(
    questions: Array<ProductAskQuestion>,
    answers: Array<ProductAskAnswer>
): AgentValue {
    if (questions.size == 1) {
        let question = questions[0]
        let answer = answers[0]
        let fields = ArrayList<ValueField>()
        fields.add(ValueField(
            "content",
            textValue(formatSingleAskAnswer(question, answer))
        ))
        fields.add(ValueField(
            "question",
            textValue(question.question)
        ))
        fields.add(ValueField(
            "options",
            askStringList(questionOptionLabels(question))
        ))
        fields.add(ValueField("multi", boolValue(question.multi)))
        fields.add(ValueField(
            "selectedOptions",
            askStringList(answer.selectedOptions)
        ))
        match (answer.customInput) {
            case Some(value) =>
                fields.add(ValueField("customInput", textValue(value)))
            case None => ()
        }
        match (answer.note) {
            case Some(value) =>
                fields.add(ValueField("note", textValue(value)))
            case None => ()
        }
        if (answer.timedOut) {
            fields.add(ValueField("timedOut", boolValue(true)))
        }
        return objectValue(fields.toArray())
    }

    let encoded = ArrayList<AgentValue>()
    var content = "User answers:"
    for (index in 0..questions.size) {
        let question = questions[index]
        let answer = answers[index]
        content += "\n" + formatAskQuestionResult(question, answer)
        encoded.add(askQuestionResultValue(question, answer))
    }
    objectValue([
        ValueField("content", textValue(content)),
        ValueField("results", listValue(encoded.toArray()))
    ])
}

func formatSingleAskAnswer(
    question: ProductAskQuestion,
    answer: ProductAskAnswer
): String {
    let parts = ArrayList<String>()
    if (!answer.selectedOptions.isEmpty()) {
        var selected = if (question.multi) {
            joinAskStrings(answer.selectedOptions, ", ")
        } else {
            answer.selectedOptions[0]
        }
        selected = "User selected: " + selected
        if (answer.timedOut) {
            selected += " (auto-selected after timeout)"
        }
        parts.add(selected)
    }
    match (answer.customInput) {
        case Some(value) =>
            parts.add(if (value.contains("\n")) {
                "User provided custom input:\n" + indentAskText(value)
            } else {
                "User provided custom input: " + value
            })
        case None => ()
    }
    match (answer.note) {
        case Some(value) =>
            parts.add(if (value.contains("\n")) {
                "User added note:\n" + indentAskText(value)
            } else {
                "User added note: " + value
            })
        case None => ()
    }
    if (parts.isEmpty()) { return "User cancelled the selection" }
    joinAskStrings(parts.toArray(), "\n")
}

func formatAskQuestionResult(
    question: ProductAskQuestion,
    answer: ProductAskAnswer
): String {
    var noteSuffix = ""
    match (answer.note) {
        case Some(value) => noteSuffix = " (note: " + value + ")"
        case None => ()
    }
    match (answer.customInput) {
        case Some(value) =>
            return question.id + ": \"" + value + "\"" + noteSuffix
        case None => ()
    }
    if (!answer.selectedOptions.isEmpty()) {
        let timeoutSuffix = if (answer.timedOut) {
            " (auto-selected after timeout)"
        } else {
            ""
        }
        if (question.multi) {
            return question.id + ": [" +
                joinAskStrings(answer.selectedOptions, ", ") + "]" +
                timeoutSuffix + noteSuffix
        }
        return question.id + ": " + answer.selectedOptions[0] +
            timeoutSuffix + noteSuffix
    }
    question.id + ": (cancelled)" + noteSuffix
}

func askQuestionResultValue(
    question: ProductAskQuestion,
    answer: ProductAskAnswer
): AgentValue {
    let fields = ArrayList<ValueField>()
    fields.add(ValueField("id", textValue(question.id)))
    fields.add(ValueField("question", textValue(question.question)))
    fields.add(ValueField(
        "options",
        askStringList(questionOptionLabels(question))
    ))
    fields.add(ValueField("multi", boolValue(question.multi)))
    fields.add(ValueField(
        "selectedOptions",
        askStringList(answer.selectedOptions)
    ))
    match (answer.customInput) {
        case Some(value) =>
            fields.add(ValueField("customInput", textValue(value)))
        case None => ()
    }
    match (answer.note) {
        case Some(value) =>
            fields.add(ValueField("note", textValue(value)))
        case None => ()
    }
    if (answer.timedOut) {
        fields.add(ValueField("timedOut", boolValue(true)))
    }
    objectValue(fields.toArray())
}

func requiredAskText(value: AgentValue, name: String): ?String {
    match (value.field(name)) {
        case Some(field) =>
            if (field.unifiedKind == ValueKind.Text) {
                Some(field.text)
            } else {
                None
            }
        case None => None
    }
}

func optionalAskText(
    value: AgentValue,
    name: String
): Result<String> {
    match (value.field(name)) {
        case Some(field) =>
            if (field.unifiedKind == ValueKind.Text) {
                Result.Ok(field.text)
            } else {
                invalidAskAnswer(name + " must be a string")
            }
        case None => Result.Ok("")
    }
}

func optionalAskBoolean(
    value: AgentValue,
    name: String
): Result<Bool> {
    match (value.field(name)) {
        case Some(field) =>
            if (field.unifiedKind == ValueKind.Boolean) {
                Result.Ok(field.boolean)
            } else {
                invalidAskAnswer(name + " must be a boolean")
            }
        case None => Result.Ok(false)
    }
}

func optionalAskInteger(
    value: AgentValue,
    name: String
): Result<?Int64> {
    match (value.field(name)) {
        case Some(field) =>
            if (field.unifiedKind != ValueKind.Number) {
                return invalidAskAnswer(name + " must be a number")
            }
            try {
                Result.Ok(Some(Int64.parse(field.number)))
            } catch (_: Exception) {
                invalidAskAnswer(name + " must be an integer index")
            }
        case None => Result.Ok(None)
    }
}

func invalidAskAnswer<T>(message: String): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.InvalidInput,
        "ask.invalid_answer",
        message
    ))
}

func reservedAskLabel(value: String): Bool {
    value == "Other (type your own)" ||
        value == "Chat about this" ||
        value == "Next →"
}

func questionOptionLabels(
    question: ProductAskQuestion
): Array<String> {
    let labels = ArrayList<String>()
    for (option in question.options) { labels.add(option.label) }
    labels.toArray()
}

func askStringList(values: Array<String>): AgentValue {
    let encoded = ArrayList<AgentValue>()
    for (value in values) { encoded.add(textValue(value)) }
    listValue(encoded.toArray())
}

func joinAskStrings(values: Array<String>, separator: String): String {
    var result = ""
    for (value in values) {
        if (result != "") { result += separator }
        result += value
    }
    result
}

func indentAskText(value: String): String {
    var result = ""
    for (line in value.split("\n")) {
        if (result != "") { result += "\n" }
        result += "  " + line
    }
    result
}

func stringIndex(values: ArrayList<String>, target: String): Int64 {
    for (index in 0..values.size) {
        if (values[index] == target) { return index }
    }
    -1
}
