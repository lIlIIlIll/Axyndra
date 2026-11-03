package agent_host_runtime

import yjson_support.*
import yjson.*
import agent_domain.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.sync.*

// The trusted host owns frontend requests and their pending/cancelled state.
// Business Tool argument parsing and contribution registration stay with the caller.
public class HostAskOption {
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

public class HostAskQuestion {
    public let id: String
    public let question: String
    public let header: String
    public let options: Array<HostAskOption>
    public let multi: Bool
    public let recommended: ?Int64

    public init(
        id: String,
        question: String,
        options: Array<HostAskOption>,
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

public class HostAskRequest {
    public let requestId: String
    public let runId: String
    public let sessionId: SessionId
    public let callId: String
    public let questions: Array<HostAskQuestion>
    public let interactionKind: String
    public let operationId: String
    public let commandId: String
    public let epoch: Int64

    public init(
        requestId: String,
        runId: String,
        sessionId: SessionId,
        callId: String,
        questions: Array<HostAskQuestion>,
        interactionKind!: String = "ask",
        operationId!: String = "",
        commandId!: String = "",
        epoch!: Int64 = 0
    ) {
        this.requestId = requestId
        this.runId = runId
        this.sessionId = sessionId
        this.callId = callId
        this.questions = questions
        this.interactionKind = interactionKind
        this.operationId = operationId
        this.commandId = commandId
        this.epoch = epoch
    }
}

public class HostAskAnswer {
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

public enum HostAskResolution {
    Answers(Array<HostAskAnswer>)
    | Chat
    | Cancelled
}

public type HostAskEventSink = (HostAskRequest) -> Unit

class PendingHostAsk {
    let request: HostAskRequest
    var resolution: ?HostAskResolution = None

    init(request: HostAskRequest) {
        this.request = request
    }
}

class HostAskSubscriber180 {
    let id: Int64
    private let frameLock = Mutex()
    private var sink: ?HostAskEventSink
    private var activeFrames: Int64 = 0
    private var closing = false
    init(id: Int64, sink: HostAskEventSink) { this.id = id; this.sink = Some(sink) }
    func invoke180(event: HostAskRequest): Unit {
        frameLock.lock()
        try {
            if (closing) { return }
            if (activeFrames == Int64.Max) { throw IllegalStateException("control dispatch frame overflow") }
            activeFrames++
        } finally { frameLock.unlock() }
        try { invokeSinkHelper180(event) }
        finally { frameLock.lock(); try { activeFrames-- } finally { frameLock.unlock() } }
    }
    private func invokeSinkHelper180(event: HostAskRequest): Unit {
        frameLock.lock(); let actual = try { sink.getOrThrow() } finally { frameLock.unlock() }
        actual(event)
    }
    func closeReturnedFrames180(): Bool {
        frameLock.lock()
        try {
            closing = true
            if (activeFrames != 0) { return false }
            sink = None<HostAskEventSink>; true
        } finally { frameLock.unlock() }
    }
}
public class HostAskRuntime {
    private let lock = Mutex()
    private let interactiveSessions = ArrayList<String>()
    private let pending = ArrayList<PendingHostAsk>()
    private let subscribers = ArrayList<HostAskSubscriber180>()
    private var subscriberCounter180: Int64 = 0

    public init() {}

    public func setInteractive(
        sessionId: SessionId,
        enabled: Bool
    ): Unit {
        lock.lock()
        try {
            let index = stringIndex(interactiveSessions, sessionId.value)
            if (enabled && index < 0) {
                interactiveSessions.add(sessionId.value)
            } else if (!enabled) {
                if (index >= 0) { interactiveSessions.remove(at: index) }
                for (state in pending
                     where state.request.sessionId.value == sessionId.value) {
                    if (state.resolution.isNone()) {
                        state.resolution = Some(HostAskResolution.Cancelled)
                    }
                }
            }
        } finally {
            lock.unlock()
        }
    }

    public func hasInteractive(sessionId: SessionId): Bool {
        lock.lock()
        try {
            stringIndex(interactiveSessions, sessionId.value) >= 0
        } finally {
            lock.unlock()
        }
    }
    public func subscribe(sink: HostAskEventSink): Unit { let _ = subscribeOwnerAsks180(sink) }
    public func subscribeOwnerAsks180(sink: HostAskEventSink): Int64 {
        lock.lock()
        try {
            if (subscriberCounter180 == Int64.Max) { throw IllegalStateException("ask subscription id overflow") }
            subscriberCounter180++
            subscribers.add(HostAskSubscriber180(subscriberCounter180, sink)); subscriberCounter180
        } finally { lock.unlock() }
    }
    public func unsubscribeOwnerAsks180(id: Int64): Unit {
        while (true) {
            lock.lock()
            let returned = try {
                var complete = true
                for (index in 0..subscribers.size where subscribers[index].id == id) {
                    complete = subscribers[index].closeReturnedFrames180()
                    if (complete) { subscribers.remove(at: index) }; break
                }
                complete
            } finally { lock.unlock() }
            if (returned) { return }; sleep(Duration.millisecond)
        }
    }

    public func current(sessionId: SessionId): ?HostAskRequest {
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
        resolution: HostAskResolution
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
                 where state.request.runId == runId.value) {
                if (state.resolution.isNone()) {
                    state.resolution = Some(
                        HostAskResolution.Cancelled
                    )
                }
            }
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    public func ask(
        context: ToolInvocationContext,
        callId: String,
        questions: Array<HostAskQuestion>,
        interactionKind!: String = "ask",
        operationId!: String = "",
        timeoutMillis!: Int64 = 0
    ): Result<HostAskResolution> {
        let request = HostAskRequest(
            context.runId.value + ":" + operationId + ":" + callId,
            context.runId.value,
            context.sessionId,
            callId,
            questions,
            interactionKind: interactionKind,
            operationId: operationId,
            epoch: context.epoch
        )
        waitForRequest(request, context.cancellation, timeoutMillis)
    }

    public func askPluginCommand(
        sessionId: SessionId,
        commandId: String,
        serviceRequestId: String,
        cancellation: CancellationToken,
        questions: Array<HostAskQuestion>,
        interactionKind: String,
        timeoutMillis: Int64
    ): Result<HostAskResolution> {
        if (commandId.trimAscii() == "" || serviceRequestId.trimAscii() == "" ||
            (interactionKind != "select" && interactionKind != "confirm")) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "ask.command_identity_invalid",
                "Plugin command interaction identity is invalid"
            ))
        }
        let request = HostAskRequest(
            sessionId.value + ":plugin-command:" + commandId + ":" + serviceRequestId,
            "",
            sessionId,
            "",
            questions,
            interactionKind: interactionKind,
            commandId: commandId
        )
        waitForRequest(request, cancellation, timeoutMillis)
    }

    private func waitForRequest(
        request: HostAskRequest,
        cancellation: CancellationToken,
        timeoutMillis: Int64
    ): Result<HostAskResolution> {
        if (timeoutMillis < 0 || timeoutMillis > 600000) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "ask.timeout_invalid",
                "Ask timeout must be between 1 and 600000 milliseconds"
            ))
        }
        if (cancellation.isCancelled()) {
            return Result.Err(AgentError(
                AgentErrorKind.Cancelled,
                "ask.cancelled",
                "Ask request was cancelled before frontend delivery"
            ))
        }
        let sinks = ArrayList<HostAskSubscriber180>()
        lock.lock()
        try {
            if (stringIndex(interactiveSessions, request.sessionId.value) < 0) {
                return Result.Err(AgentError(
                    AgentErrorKind.Cancelled,
                    "ask.interactive_required",
                    "Ask request requires an interactive frontend"
                ))
            }
            for (state in pending
                 where state.request.sessionId.value == request.sessionId.value) {
                return Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "ask.already_pending",
                    "Another ask request is already waiting for input"
                ))
            }
            pending.add(PendingHostAsk(request))
            for (sink in subscribers) { sinks.add(sink) }
        } finally {
            lock.unlock()
        }
        for (sink in sinks) { sink.invoke180(request) }

        var waitedMillis: Int64 = 0
        while (true) {
            let cancelled = cancellation.isCancelled()
            let timedOut = timeoutMillis > 0 && waitedMillis >= timeoutMillis
            lock.lock()
            try {
                for (index in 0..pending.size) {
                    let state = pending[index]
                    if (state.request.requestId != request.requestId) { continue }
                    if (cancelled || timedOut) {
                        pending.remove(at: index)
                        if (cancelled) {
                            return Result.Err(AgentError(
                                AgentErrorKind.Cancelled,
                                "ask.cancelled",
                                "Ask request was cancelled while waiting for frontend input"
                            ))
                        }
                        return Result.Err(AgentError(
                            AgentErrorKind.Timeout,
                            "ask.timeout",
                            "Ask request timed out while waiting for frontend input"
                        ))
                    }
                    match (state.resolution) {
                        case Some(HostAskResolution.Cancelled) =>
                            pending.remove(at: index)
                            return Result.Err(AgentError(
                                AgentErrorKind.Cancelled,
                                "ask.cancelled",
                                "Ask request was cancelled by the user"
                            ))
                        case Some(value) =>
                            pending.remove(at: index)
                            return Result.Ok(value)
                        case None => ()
                    }
                    break
                }
            } finally {
                lock.unlock()
            }
            sleep(Duration.millisecond * 10)
            waitedMillis += 10
        }
        Result.Err(AgentError(
            AgentErrorKind.Internal,
            "ask.wait_terminated",
            "Ask wait loop terminated unexpectedly"
        ))
    }
}

func validateAskResolution(
    request: HostAskRequest,
    resolution: HostAskResolution
): Result<Unit> {
    let answers = match (resolution) {
        case HostAskResolution.Answers(values) => values
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

public func normalizeTimedOutAskAnswers(
    questions: Array<HostAskQuestion>,
    answers: Array<HostAskAnswer>
): Array<HostAskAnswer> {
    let normalized = ArrayList<HostAskAnswer>()
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
            normalized.add(HostAskAnswer(
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

public func askAnswerOutput(
    questions: Array<HostAskQuestion>,
    answers: Array<HostAskAnswer>
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
    question: HostAskQuestion,
    answer: HostAskAnswer
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
    question: HostAskQuestion,
    answer: HostAskAnswer
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
    question: HostAskQuestion,
    answer: HostAskAnswer
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

public func requiredAskText(value: AgentValue, name: String): ?String {
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

public func optionalAskText(
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

public func optionalAskBoolean(
    value: AgentValue,
    name: String
): Result<Bool> {
    match (value.field(name)) {
        case Some(field) =>
            if (field.unifiedKind == ValueKind.Boolean) {
                Result.Ok(field.asBool())
            } else {
                invalidAskAnswer(name + " must be a boolean")
            }
        case None => Result.Ok(false)
    }
}

public func optionalAskInteger(
    value: AgentValue,
    name: String
): Result<?Int64> {
    match (value.field(name)) {
        case Some(field) =>
            if (field.unifiedKind != ValueKind.Number) {
                return invalidAskAnswer(name + " must be a number")
            }
            try {
                Result.Ok(Some(Int64.parse(field.asNumberText())))
            } catch (_: Exception) {
                invalidAskAnswer(name + " must be an integer index")
            }
        case None => Result.Ok(None<Int64>)
    }
}

func invalidAskAnswer<T>(message: String): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.InvalidInput,
        "ask.invalid_answer",
        message
    ))
}

public func reservedAskLabel(value: String): Bool {
    value == "Other (type your own)" ||
        value == "Chat about this" ||
        value == "Next →"
}

func questionOptionLabels(
    question: HostAskQuestion
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
