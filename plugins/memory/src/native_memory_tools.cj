package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

class NativeMemoryTools {
    private let memories: NativeMemoryJournal
    private let skills: NativeManagedSkillProposals
    private let settingsRoot: String
    private let workspaceRoot: String
    private let authoredSkills: Array<String>
    private var contextCeiling: Int64 = 0
    private var retrievalCeiling: Int64 = 0
    public func retrievalValidUntilMillis():Int64{retrievalCeiling}
    private func rememberRetrievalValidity(hits:Array<MemoryV3SearchHit>):Unit{
        retrievalCeiling=0
        for(hit in hits where hit.memory.expiresAt>0){
            if(retrievalCeiling==0 || hit.memory.expiresAt<retrievalCeiling){retrievalCeiling=hit.memory.expiresAt}}
    }
    public func contextValidUntilMillis(): Int64 { contextCeiling }
    init(memories: NativeMemoryJournal, skills: NativeManagedSkillProposals,
        settingsRoot: String, workspaceRoot: String, authoredSkills: Array<String>) {
        this.memories = memories; this.skills = skills; this.settingsRoot = settingsRoot
        this.workspaceRoot = workspaceRoot; this.authoredSkills = authoredSkills
    }
    func policySession(sessionId: SessionId, cancellation: CancellationToken): Result<NativeMemoryBusinessPolicy> {
        let _ = sessionId; match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(NativeMemoryBusinessPolicy())
    }
    public func retain(
        context: NativeMemoryToolContext,
        call: ToolCall
    ): Result<ToolResult> {
        let drafts = match (memoryV3Drafts(
            call,
            context,
            workspaceRoot,
            "items",
            "retain",
            750
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let records = ArrayList<MemoryV3Record>()
        for (draft in drafts) {
            match (memories.retain(draft)) {
                case Result.Ok(value) => records.add(value)
                case Result.Err(error) => return Result.Err(error)
            }
        }
        let count = records.size
        let noun = if (count == 1) { "memory" } else { "memories" }
        Result.Ok(ToolResult(
            call.callId,
            objectValue([
                ValueField(
                    "content",
                    textValue(count.toString() + " " + noun + " stored.")
                ),
                ValueField("count", integerValue(count)),
                ValueField("ids", memoryV3Ids(records.toArray())),
                ValueField("memories", memoryV3RecordsValue(records.toArray()))
            ])
        ))
    }

    public func recall(
        context: NativeMemoryToolContext,
        call: ToolCall
    ): Result<ToolResult> {
        let query = match (requiredNonemptyMemoryString(call, "query")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let options = match (memoryV3SearchOptions(
            call,
            context,
            workspaceRoot
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let policy = match (policySession(context.sessionId, context.cancellation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let search = match (memories.search(query, options: options, policy: Some(policy))) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let hits = search.hits
        rememberRetrievalValidity(hits)
        if (hits.size == 0) {
            return Result.Ok(ToolResult(
                call.callId,
                objectValue([
                    ValueField(
                        "content",
                        textValue("No relevant memories found.")
                    ),
                    ValueField("count", integerValue(0)),
                    ValueField("memories", listValue([])),
                    ValueField(
                        "strategy",
                        textValue(memoryV3SearchStrategyName(search.strategy))
                    ),
                    ValueField("embeddingFallback", boolValue(search.embeddingFallback)),
                    ValueField("useless", boolValue(true))
                ])
            ))
        }
        let count = hits.size
        let noun = if (count == 1) { "memory" } else { "memories" }
        Result.Ok(ToolResult(
            call.callId,
            objectValue([
                ValueField(
                    "content",
                    textValue(
                        "Found " + count.toString() + " relevant " + noun +
                        " (as of " + DateTime.nowUTC().toString() +
                        " UTC):\n\n" + formatRecallHits(hits, true)
                    )
                    ),
                ValueField("count", integerValue(count)),
                ValueField("memories", memoryV3HitValues(hits)),
                ValueField(
                    "strategy",
                    textValue(memoryV3SearchStrategyName(search.strategy))
                ),
                ValueField("embeddingFallback", boolValue(search.embeddingFallback))
            ])
        ))
    }

    public func reflect(
        context: NativeMemoryToolContext,
        call: ToolCall
    ): Result<ToolResult> {
        let query = match (requiredNonemptyMemoryString(call, "query")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let authoredContext = optionalMemoryString(call, "context")
        let searchQuery = if (authoredContext.trimAscii() == "") {
            query
        } else {
            query + " " + authoredContext
        }
        let options = match (memoryV3SearchOptions(
            call,
            context,
            workspaceRoot
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let policy = match (policySession(context.sessionId, context.cancellation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let search = match (memories.search(searchQuery, options: options, policy: Some(policy))) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let hits = search.hits
        rememberRetrievalValidity(hits)
        let text = if (hits.size == 0) {
            "No relevant information found to reflect on."
        } else {
            "Based on recalled memories:\n\n" +
                formatRecallHits(hits, false)
        }
        Result.Ok(ToolResult(
            call.callId,
            objectValue([
                ValueField("content", textValue(text)),
                ValueField("count", integerValue(hits.size)),
                ValueField("memories", memoryV3HitValues(hits)),
                ValueField(
                    "strategy",
                    textValue(memoryV3SearchStrategyName(search.strategy))
                ),
                ValueField("embeddingFallback", boolValue(search.embeddingFallback))
            ])
        ))
    }

    public func edit(
        context: NativeMemoryToolContext,
        call: ToolCall
    ): Result<ToolResult> {
        let op = match (requiredNonemptyMemoryString(call, "op")) {
            case Result.Ok(value) => value.toAsciiLower()
            case Result.Err(error) => return Result.Err(error)
        }
        if (op != "correct" && op != "update" && op != "delete" &&
            op != "forget" && op != "invalidate" &&
            op != "mark_conflict" && op != "resolve_conflict") {
            return memoryToolError<ToolResult>(
                call,
                "op",
                "op must be correct, update, delete, forget, invalidate, " +
                    "mark_conflict, or resolve_conflict"
            )
        }
        let id = match (requiredNonemptyMemoryString(call, "id")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (op) {
            case "correct" | "update" => correctMemory(context, call, id)
            case "delete" | "forget" => deleteMemory(context, call, id)
            case "invalidate" => invalidateMemory(context, call, id)
            case "mark_conflict" => markMemoryConflict(context, call, id)
            case "resolve_conflict" => resolveMemoryConflict(context, call, id)
            case _ => memoryToolError<ToolResult>(call, "op", "unsupported memory operation")
        }
    }

    private func correctMemory(
        context: NativeMemoryToolContext,
        call: ToolCall,
        id: String
    ): Result<ToolResult> {
        if (!memoryV3HasCorrectionFields(call)) {
            return memoryToolError<ToolResult>(
                call,
                "content",
                "memory correction requires content, context, importance, " +
                    "kind, scope, scope_key, or expires_at"
            )
        }
        let current = match (memoryForMutation(context, call, id)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let changes = match (memoryV3CorrectionChanges(call, context, workspaceRoot, current)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let policy = match (policySession(context.sessionId, context.cancellation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let proposed = match (policy.correction(current, changes)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let replacement = match (memoryV3PolicyCorrectionDraft(call, context, workspaceRoot, current, proposed)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        match (policy.validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let corrected = match (memories.correct(id, replacement, expectedRevision: current.revision)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let responseStatus = if (
            optionalMemoryString(call, "op").trimAscii().toAsciiLower() == "update"
        ) {
            "updated"
        } else {
            "corrected"
        }
        Result.Ok(memoryV3MutationResult(
            call,
            responseStatus,
            corrected,
            "Memory " + id + " corrected by replacement " + corrected.id + "."
        ))
    }

    private func deleteMemory(
        context: NativeMemoryToolContext,
        call: ToolCall,
        id: String
    ): Result<ToolResult> {
        match (memoryForMutation(context, call, id)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let deleted = match (memories.delete(
            id,
            reason: optionalMemoryString(call, "reason")
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        Result.Ok(memoryV3MutationResult(
            call,
            "deleted",
            deleted,
            "Memory " + id + " deleted with a durable tombstone."
        ))
    }

    private func invalidateMemory(
        context: NativeMemoryToolContext,
        call: ToolCall,
        id: String
    ): Result<ToolResult> {
        let replacementId = match (requiredNonemptyMemoryString(call, "replacement_id")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        for (candidate in [id, replacementId]) {
            match (memoryForMutation(context, call, candidate)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        }
        let reason = if (optionalMemoryString(call, "reason").trimAscii() == "") {
            "memory invalidated in favor of " + replacementId
        } else {
            optionalMemoryString(call, "reason")
        }
        match (memories.markConflict([id, replacementId], reason)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let winner = match (memories.resolveConflict(replacementId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let invalidated = match (memories.get(id)) {
            case Result.Ok(Some(value)) => value
            case Result.Ok(None) => return memoryToolError<ToolResult>(
                call,
                "id",
                "invalidated memory disappeared from the durable journal"
            )
            case Result.Err(error) => return Result.Err(error)
        }
        Result.Ok(memoryV3MutationResultWithReplacement(
            call,
            "invalidated",
            invalidated,
            winner,
            "Memory " + id + " invalidated in favor of " + replacementId + "."
        ))
    }

    private func markMemoryConflict(
        context: NativeMemoryToolContext,
        call: ToolCall,
        id: String
    ): Result<ToolResult> {
        let ids = match (memoryV3ConflictIds(call, id)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        for (candidate in ids) {
            match (memoryForMutation(context, call, candidate)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        }
        let reason = match (requiredNonemptyMemoryString(call, "reason")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let records = match (memories.markConflict(ids, reason)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        Result.Ok(memoryV3ConflictResult(call, "conflicted", records, reason))
    }

    private func resolveMemoryConflict(
        context: NativeMemoryToolContext,
        call: ToolCall,
        id: String
    ): Result<ToolResult> {
        let pending = match (memoryForMutation(context, call, id)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        for (candidate in pending.conflictIds where candidate != id) {
            match (memoryForMutation(context, call, candidate)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        }
        let winner = match (memories.resolveConflict(id)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        Result.Ok(memoryV3MutationResult(
            call,
            "resolved",
            winner,
            "Memory conflict resolved in favor of " + id + "."
        ))
    }

    private func memoryForMutation(
        context: NativeMemoryToolContext,
        call: ToolCall,
        id: String
    ): Result<MemoryV3Record> {
        let record = match (memories.get(id)) {
            case Result.Ok(Some(value)) => value
            case Result.Ok(None) => return memoryToolError<MemoryV3Record>(
                call,
                "id",
                "memory does not exist"
            )
            case Result.Err(error) => return Result.Err(error)
        }
        if (!memoryV3ScopeAccessible(record.scope, context, workspaceRoot)) {
            return memoryToolError<MemoryV3Record>(
                call,
                "id",
                "memory is outside the active workspace or session scope"
            )
        }
        Result.Ok(record)
    }

    public func learn(
        context: NativeMemoryToolContext,
        call: ToolCall
    ): Result<ToolResult> {
        let lesson = match (
            requiredNonemptyMemoryString(call, "memory")
        ) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let draft = match (memoryV3LearnDraft(
            call,
            context,
            workspaceRoot,
            lesson
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let stored = match (memories.retain(draft)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let memoryId = stored.id
        match (call.arguments.field("skill")) {
            case None =>
                Result.Ok(learnResult(
                    call,
                    "Lesson stored.",
                    memoryId,
                    None
                ))
            case Some(raw) =>
                if (raw.unifiedKind != ValueKind.Object) {
                    return memoryToolError<ToolResult>(
                        call,
                        "skill",
                        "skill must be an object"
                    )
                }
                let skill = match (managedSkillInput(
                    call,
                    raw,
                    false
                )) {
                    case Result.Ok(value) => value
                    case Result.Err(error) =>
                        return Result.Err(AgentError(
                            error.kind,
                            error.code,
                            "Lesson stored, but the managed skill could " +
                                "not be written: " + error.message,
                            fields: error.fields
                        ))
                }
                if (skill.action == "create" &&
                    authoredSkillExists(skill.name)) {
                    return Result.Ok(ToolResult(
                        call.callId,
                        objectValue([
                            ValueField(
                                "content",
                                textValue(
                                    "Lesson stored. Did not create managed " +
                                    "skill \"" + skill.name + "\": an authored " +
                                    "skill of that name already exists, and " +
                                    "managed skills cannot override authored " +
                                    "ones. Choose a different name."
                                )
                            ),
                            ValueField("memoryId", textValue(memoryId)),
                            ValueField("skill", nullValue()),
                            ValueField("shadowed", boolValue(true))
                        ]),
                        isError: true
                    ))
                }
                match (skills.write(
                    skill.action,
                    skill.name,
                    skill.description,
                    skill.body
                )) {
                    case Result.Ok(_) =>
                        let verb = if (skill.action == "create") {
                            "Created"
                        } else {
                            "Updated"
                        }
                        Result.Ok(learnResult(
                            call,
                            "Lesson stored. " + verb +
                                " managed skill \"" + skill.name + "\".",
                            memoryId,
                            Some(skill.name)
                        ))
                    case Result.Err(error) =>
                        Result.Err(AgentError(
                            error.kind,
                            error.code,
                            "Lesson stored, but the managed skill could " +
                                "not be written: " + error.message,
                            fields: error.fields
                        ))
                }
        }
    }

    public func manageSkill(
        _context: NativeMemoryToolContext,
        call: ToolCall
    ): Result<ToolResult> {
        let _ = _context
        let input = match (managedSkillInput(
            call,
            call.arguments,
            true
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (input.action == "delete") {
            return match (skills.delete(input.name)) {
                case Result.Ok(_) =>
                    Result.Ok(manageSkillResult(
                        call,
                        input.action,
                        input.name,
                        "Deleted managed skill \"" + input.name + "\"."
                    ))
                case Result.Err(error) => Result.Err(error)
            }
        }
        if (input.action == "create" &&
            authoredSkillExists(input.name)) {
            return Result.Ok(ToolResult(
                call.callId,
                objectValue([
                    ValueField(
                        "content",
                        textValue(
                            "Cannot create managed skill \"" + input.name +
                            "\": an authored skill of that name already " +
                            "exists, and managed skills cannot override " +
                            "authored ones. Choose a different name."
                        )
                    ),
                    ValueField("action", textValue("create")),
                    ValueField("name", textValue(input.name)),
                    ValueField("shadowed", boolValue(true))
                ]),
                isError: true
            ))
        }
        match (skills.write(
            input.action,
            input.name,
            input.description,
            input.body
        )) {
            case Result.Ok(path) =>
                let verb = if (input.action == "create") {
                    "Created"
                } else {
                    "Updated"
                }
                Result.Ok(manageSkillResult(
                    call,
                    input.action,
                    input.name,
                    verb + " managed skill \"" + input.name +
                        "\" (" + path + ")."
                ))
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func repository(): NativeMemoryJournal { memories }

    // Read-only request-time retrieval. The returned text is already ranked,
    // deduplicated, lifecycle-filtered, and strictly bounded in UTF-8 bytes so
    // callers can place it in a turn-scoped, untrusted prompt section.
    public func contextFor(
        query: String,
        sessionId: SessionId,
        workspaceRoot: String,
        maxBytes: Int64,
        cancellation!: CancellationToken = CancellationSource().token
    ): Result<String> {
        if (maxBytes < 1 || maxBytes > 65536) {
            return Result.Err(AgentError(AgentErrorKind.InvalidInput,
                "memory_v3.context_budget_invalid", "memory context maxBytes must be between 1 and 65536")) }
        contextCeiling = 0
        let normalized = query.trimAscii()
        if (normalized == "") { return Result.Ok("") }
        let requestedWorkspace = workspaceRoot.trimAscii()
        if (this.workspaceRoot.trimAscii() != "" && requestedWorkspace != this.workspaceRoot.trimAscii()) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                "memory_v3.context_scope_denied", "memory context workspace must match the active product workspace")) }
        let policy = match (policySession(sessionId, cancellation)) {
            // Unselected automatic memory remains optional. A configured but
            // missing, disabled, changed or malformed provider is not ignored.
            case Result.Err(error) => if (error.code == "policy.not_configured") { return Result.Ok("") } else { return Result.Err(error) }
            case Result.Ok(value) => value }
        let hits = ArrayList<MemoryV3SearchHit>()
        if (requestedWorkspace != "") {
            let result = match (memories.search(normalized, options: MemoryV3SearchOptions(
                scope: Some(MemoryScope(MemoryScopeKind.Workspace, key: requestedWorkspace)), limit: 8), policy: Some(policy))) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            hits.add(all: result.hits)
        }
        let result = match (memories.search(normalized, options: MemoryV3SearchOptions(
            scope: Some(MemoryScope(MemoryScopeKind.Session, key: sessionId.value)), limit: 8), policy: Some(policy))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        hits.add(all: result.hits)
        let content = match (policy.renderContext(hits.toArray(), maxBytes, memories)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        match (policy.validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (memories.validateContextRecords(hits.toArray().map { hit => hit.memory })) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        contextCeiling = policy.contextValidUntilMillis()
        Result.Ok(content)
    }

    private func authoredSkillExists(name: String): Bool { authoredSkills.contains(name) }
}

func memoryRetainDefinition(): ModelToolDefinition {
    ModelToolDefinition(
        "retain",
        "Store important facts in long-term memory.",
        objectSchema([
            memoryItemsSchemaProperty()
        ], ["items"])
    )
}

func memoryRecallDefinition(): ModelToolDefinition {
    ModelToolDefinition(
        "recall",
        "Search memory for relevant prior context.",
        objectSchema([
            schemaProperty("query", "string"),
            schemaEnumProperty(
                "scope",
                ["global", "user", "workspace", "session"]
            ),
            schemaProperty("scope_key", "string"),
            memoryKindsSchemaProperty(),
            schemaProperty("limit", "integer")
        ], ["query"])
    )
}

func memoryReflectDefinition(): ModelToolDefinition {
    ModelToolDefinition(
        "reflect",
        "Synthesize an answer from long-term memory.",
        objectSchema([
            schemaProperty("query", "string"),
            schemaProperty("context", "string"),
            schemaEnumProperty(
                "scope",
                ["global", "user", "workspace", "session"]
            ),
            schemaProperty("scope_key", "string"),
            memoryKindsSchemaProperty(),
            schemaProperty("limit", "integer")
        ], ["query"])
    )
}

func memoryEditDefinition(): ModelToolDefinition {
    ModelToolDefinition(
        "memory_edit",
        "Correct, delete, invalidate, or resolve conflicts in durable memories.",
        objectSchema([
            schemaEnumProperty(
                "op",
                [
                    "correct", "update", "delete", "forget", "invalidate",
                    "mark_conflict", "resolve_conflict"
                ]
            ),
            schemaProperty("id", "string"),
            schemaProperty("content", "string"),
            schemaProperty("context", "string"),
            schemaProperty("importance", "number"),
            schemaEnumProperty(
                "kind",
                ["preference", "project_fact", "decision", "constraint", "observation"]
            ),
            schemaEnumProperty(
                "scope",
                ["global", "user", "workspace", "session"]
            ),
            schemaProperty("scope_key", "string"),
            schemaProperty("expires_at", "integer"),
            schemaProperty("replacement_id", "string"),
            memoryConflictIdsSchemaProperty(),
            schemaProperty("reason", "string")
        ], ["op", "id"])
    )
}

func learnDefinition(): ModelToolDefinition {
    ModelToolDefinition(
        "learn",
        "Capture a reusable lesson to memory and optionally a managed skill.",
        objectSchema([
            schemaProperty("memory", "string"),
            schemaProperty("context", "string"),
            schemaProperty("importance", "number"),
            schemaEnumProperty(
                "kind",
                ["preference", "project_fact", "decision", "constraint", "observation"]
            ),
            schemaEnumProperty(
                "scope",
                ["global", "user", "workspace", "session"]
            ),
            schemaProperty("scope_key", "string"),
            schemaProperty("expires_at", "integer"),
            learnSkillSchemaProperty()
        ], ["memory"])
    )
}

func manageSkillDefinition(): ModelToolDefinition {
    ModelToolDefinition(
        "manage_skill",
        "Create, update, or delete an isolated managed skill.",
        objectSchema([
            schemaEnumProperty(
                "action",
                ["create", "update", "delete"]
            ),
            schemaProperty("name", "string"),
            schemaProperty("description", "string"),
            schemaProperty("body", "string")
        ], ["action", "name"])
    )
}

func memoryItemsSchemaProperty(): ValueField {
    ValueField("items", objectValue([
        ValueField("type", textValue("array")),
        ValueField("minItems", integerValue(1)),
        ValueField("items", objectValue([
            ValueField("type", textValue("object")),
            ValueField("properties", objectValue([
                schemaProperty("content", "string"),
                schemaProperty("context", "string"),
                schemaProperty("importance", "number"),
                schemaEnumProperty(
                    "kind",
                    ["preference", "project_fact", "decision", "constraint", "observation"]
                ),
                schemaEnumProperty(
                    "scope",
                    ["global", "user", "workspace", "session"]
                ),
                schemaProperty("scope_key", "string"),
                schemaProperty("expires_at", "integer")
            ])),
            ValueField("required", listValue([
                textValue("content")
            ])),
            ValueField("additionalProperties", boolValue(false))
        ]))
    ]))
}

func memoryKindsSchemaProperty(): ValueField {
    ValueField("kinds", objectValue([
        ValueField("type", textValue("array")),
        ValueField("items", objectValue([
            ValueField("type", textValue("string")),
            ValueField("enum", listValue([
                textValue("preference"),
                textValue("project_fact"),
                textValue("decision"),
                textValue("constraint"),
                textValue("observation")
            ]))
        ]))
    ]))
}

func memoryConflictIdsSchemaProperty(): ValueField {
    ValueField("conflict_ids", objectValue([
        ValueField("type", textValue("array")),
        ValueField("minItems", integerValue(1)),
        ValueField("items", objectValue([
            ValueField("type", textValue("string"))
        ]))
    ]))
}

func learnSkillSchemaProperty(): ValueField {
    ValueField("skill", objectValue([
        ValueField("type", textValue("object")),
        ValueField("properties", objectValue([
            schemaEnumProperty("action", ["create", "update"]),
            schemaProperty("name", "string"),
            schemaProperty("description", "string"),
            schemaProperty("body", "string")
        ])),
        ValueField("required", listValue([
            textValue("action"),
            textValue("name"),
            textValue("description"),
            textValue("body")
        ])),
        ValueField("additionalProperties", boolValue(false))
    ]))
}

class ManagedSkillInput {
    let action: String
    let name: String
    let description: String
    let body: String

    init(
        action: String,
        name: String,
        description: String,
        body: String
    ) {
        this.action = action
        this.name = name
        this.description = description
        this.body = body
    }
}

func managedSkillInput(
    call: ToolCall,
    value: AgentValue,
    allowDelete: Bool
): Result<ManagedSkillInput> {
    if (value.unifiedKind != ValueKind.Object) {
        return memoryToolError<ManagedSkillInput>(
            call,
            "skill",
            "managed skill input must be an object"
        )
    }
    let action = memoryObjectString(value, "action")
    if (action != "create" && action != "update" &&
        (!allowDelete || action != "delete")) {
        return memoryToolError<ManagedSkillInput>(
            call,
            "action",
            if (allowDelete) {
                "action must be create, update, or delete"
            } else {
                "action must be create or update"
            }
        )
    }
    let rawName = memoryObjectString(value, "name")
    let name = match (sanitizeManagedSkillName(rawName)) {
        case Result.Ok(result) => result
        case Result.Err(error) => return Result.Err(error)
    }
    if (action == "delete") {
        return Result.Ok(ManagedSkillInput(action, name, "", ""))
    }
    let description = sanitizeManagedDescription(
        memoryObjectString(value, "description")
    )
    let body = memoryObjectString(value, "body").trimAscii()
    if (description == "" || body == "") {
        return memoryToolError<ManagedSkillInput>(
            call,
            "description",
            "\"" + action +
                "\" requires both \"description\" and \"body\"."
        )
    }
    Result.Ok(ManagedSkillInput(
        action,
        name,
        description,
        body
    ))
}

func sanitizeManagedSkillName(raw: String): Result<String> {
    let name = raw.trimAscii().toAsciiLower()
    let bytes = unsafe { name.rawData() }
    if (bytes.size < 1 || bytes.size > 64) {
        return managedSkillNameError(raw)
    }
    for (index in 0..bytes.size) {
        let byte = bytes[index]
        let allowed = (byte >= b'a' && byte <= b'z') ||
            (byte >= b'0' && byte <= b'9') ||
            byte == b'-'
        if (!allowed || (index == 0 && byte == b'-')) {
            return managedSkillNameError(raw)
        }
    }
    Result.Ok(name)
}

func managedSkillNameError(raw: String): Result<String> {
    Result.Err(AgentError(
        AgentErrorKind.InvalidInput,
        "skill.name_invalid",
        "Invalid skill name \"" + raw + "\". Use lowercase letters, " +
            "digits, and hyphens (1-64 chars, starting with a letter or digit)."
    ))
}

func sanitizeManagedDescription(raw: String): String {
    var value = raw
        .replace("<", "")
        .replace(">", "")
        .replace("`", "")
        .replace("\n", " ")
        .replace("\r", " ")
        .replace("\t", " ")
    while (value.contains("  ")) { value = value.replace("  ", " ") }
    while (value.contains("~~")) { value = value.replace("~~", "~") }
    value.trimAscii()
}

func memoryV3Drafts(
    call: ToolCall,
    context: NativeMemoryToolContext,
    workspaceRoot: String,
    fieldName: String,
    source: String,
    importance: Int64
): Result<Array<MemoryV3Draft>> {
    let raw = match (call.arguments.field(fieldName)) {
        case Some(value) => value
        case None =>
            return memoryToolError<Array<MemoryV3Draft>>(
                call,
                fieldName,
                "required argument is missing"
            )
    }
    if (raw.unifiedKind != ValueKind.List || raw.items.size == 0) {
        return memoryToolError<Array<MemoryV3Draft>>(
            call,
            fieldName,
            "items must be a non-empty array"
        )
    }
    let drafts = ArrayList<MemoryV3Draft>()
    for (item in raw.items) {
        if (item.unifiedKind != ValueKind.Object) {
            return memoryToolError<Array<MemoryV3Draft>>(
                call,
                fieldName,
                "each memory item must be an object"
            )
        }
        let content = memoryObjectString(item, "content").trimAscii()
        if (content == "") {
            return memoryToolError<Array<MemoryV3Draft>>(
                call,
                "content",
                "memory content must not be empty"
            )
        }
        let kind = match (memoryV3KindFromValue(
            call,
            item,
            MemoryKind.Observation
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let scope = match (memoryV3ScopeFromValue(
            call,
            item,
            context,
            workspaceRoot,
            memoryV3DefaultScope(context, workspaceRoot)
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let resolvedImportance = match (memoryV3ImportanceFromValue(
            call,
            item,
            importance
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let expiresAt = match (memoryV3ExpiresAtFromValue(call, item, 0)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        try {
            drafts.add(MemoryV3Draft(
                kind,
                scope,
                content,
                context: memoryObjectString(item, "context"),
                source: source,
                importancePermille: resolvedImportance,
                expiresAt: expiresAt
            ))
        } catch (error: IllegalArgumentException) {
            return memoryToolError<Array<MemoryV3Draft>>(
                call,
                "items",
                error.message
            )
        }
    }
    Result.Ok(drafts.toArray())
}

func memoryV3LearnDraft(
    call: ToolCall,
    context: NativeMemoryToolContext,
    workspaceRoot: String,
    lesson: String
): Result<MemoryV3Draft> {
    let kind = match (memoryV3KindFromValue(
        call,
        call.arguments,
        MemoryKind.Decision
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let scope = match (memoryV3ScopeFromValue(
        call,
        call.arguments,
        context,
        workspaceRoot,
        memoryV3DefaultScope(context, workspaceRoot)
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let importance = match (memoryV3ImportanceFromValue(
        call,
        call.arguments,
        800
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let expiresAt = match (memoryV3ExpiresAtFromValue(
        call,
        call.arguments,
        0
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    try {
        Result.Ok(MemoryV3Draft(
            kind,
            scope,
            lesson,
            context: optionalMemoryString(call, "context"),
            source: "coding-agent-learn",
            importancePermille: importance,
            expiresAt: expiresAt
        ))
    } catch (error: IllegalArgumentException) {
        memoryToolError<MemoryV3Draft>(call, "memory", error.message)
    }
}

// Host validates requested fields and scope only. Omitted-field policy is
// supplied by the installed provider and checked against the immutable record.
func memoryV3CorrectionChanges(call: ToolCall, context: NativeMemoryToolContext,
    workspaceRoot: String, current: MemoryV3Record): Result<AgentValue> {
    let fields = ArrayList<ValueField>()
    for (name in ["content", "context"]) {
        match (memoryV3OptionalText(call, call.arguments, name)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(Some(value)) => fields.add(ValueField(name, textValue(value)))
            case Result.Ok(None) => () }
    }
    if (call.arguments.field("kind").isSome()) {
        let kind = match (memoryV3KindFromValue(call, call.arguments, current.kind)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        fields.add(ValueField("kind", textValue(memoryV3KindName(kind)))) }
    if (call.arguments.field("scope").isSome() || call.arguments.field("scope_key").isSome()) {
        let scope = match (memoryV3ScopeFromValue(call, call.arguments, context, workspaceRoot, current.scope)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        fields.add(ValueField("scope", textValue(memoryV3ScopeName(scope.kind))))
        fields.add(ValueField("scope_key", textValue(scope.key))) }
    if (call.arguments.field("importance").isSome()) {
        let importance = match (memoryV3ImportanceFromValue(call, call.arguments, current.importancePermille)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        fields.add(ValueField("importance_permille", integerValue(importance))) }
    if (call.arguments.field("expires_at").isSome()) {
        let expires = match (memoryV3ExpiresAtFromValue(call, call.arguments, current.expiresAt)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        fields.add(ValueField("expires_at", integerValue(expires))) }
    Result.Ok(objectValue(fields.toArray()))
}
func memoryV3PolicyCorrectionDraft(call: ToolCall, context: NativeMemoryToolContext,
    workspaceRoot: String, current: MemoryV3Record, proposed: AgentValue): Result<MemoryV3Draft> {
    try {
        let kind = match (memoryV3KindFromText(call, httpIntentText(proposed, "kind"), "kind")) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        let scope = match (memoryV3ScopeFromValue(call, proposed, context, workspaceRoot, current.scope)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (!memoryV3ScopeAccessible(scope, context, workspaceRoot)) { return memoryNativeProposalError("memory.policy_scope_denied") }
        let importance = memoryNativePolicyInt(proposed, "importance_permille")
        let expires = memoryNativePolicyInt(proposed, "expires_at")
        if (importance < 0 || importance > 1000 || expires < 0) { return memoryNativeProposalError("memory.policy_result_invalid") }
        Result.Ok(MemoryV3Draft(kind, scope, httpIntentText(proposed, "content"), context: httpIntentText(proposed, "context"),
            source: current.source, importancePermille: importance, expiresAt: expires))
    } catch (_: Exception) { memoryNativeProposalError("memory.policy_result_invalid") }
}

func memoryV3HasCorrectionFields(call: ToolCall): Bool {
    for (name in [
        "content", "context", "importance", "kind", "scope", "scope_key", "expires_at"
    ]) {
        if (call.arguments.field(name).isSome()) { return true }
    }
    false
}

func memoryV3DefaultScope(
    context: NativeMemoryToolContext,
    workspaceRoot: String
): MemoryScope {
    let key = if (context.workspaceRoot.trimAscii() == "") {
        workspaceRoot.trimAscii()
    } else {
        context.workspaceRoot.trimAscii()
    }
    if (key == "") {
        MemoryScope(MemoryScopeKind.Session, key: context.sessionId.value)
    } else {
        MemoryScope(MemoryScopeKind.Workspace, key: key)
    }
}

func memoryV3ScopeAccessible(
    scope: MemoryScope,
    context: NativeMemoryToolContext,
    workspaceRoot: String
): Bool {
    let currentWorkspace = if (context.workspaceRoot.trimAscii() == "") {
        workspaceRoot.trimAscii()
    } else {
        context.workspaceRoot.trimAscii()
    }
    match (scope.kind) {
        case MemoryScopeKind.Global => true
        case MemoryScopeKind.User => true
        case MemoryScopeKind.Workspace => scope.key == currentWorkspace
        case MemoryScopeKind.Session => scope.key == context.sessionId.value
    }
}

func memoryV3ScopeFromValue(
    call: ToolCall,
    value: AgentValue,
    context: NativeMemoryToolContext,
    workspaceRoot: String,
    fallback: MemoryScope
): Result<MemoryScope> {
    let scopeName = match (memoryV3OptionalText(call, value, "scope")) {
        case Result.Ok(Some(raw)) => raw.trimAscii().toAsciiLower()
        case Result.Ok(None) => ""
        case Result.Err(error) => return Result.Err(error)
    }
    let authoredKey = match (memoryV3OptionalText(call, value, "scope_key")) {
        case Result.Ok(Some(raw)) => raw.trimAscii()
        case Result.Ok(None) => ""
        case Result.Err(error) => return Result.Err(error)
    }
    let kind = if (scopeName == "") {
        fallback.kind
    } else {
        match (scopeName) {
            case "global" => MemoryScopeKind.Global
            case "user" => MemoryScopeKind.User
            case "workspace" => MemoryScopeKind.Workspace
            case "session" => MemoryScopeKind.Session
            case _ => return memoryToolError<MemoryScope>(
                call,
                "scope",
                "scope must be global, user, workspace, or session"
            )
        }
    }
    let currentWorkspace = if (context.workspaceRoot.trimAscii() == "") {
        workspaceRoot.trimAscii()
    } else {
        context.workspaceRoot.trimAscii()
    }
    let key = match (kind) {
        case MemoryScopeKind.Global => authoredKey
        case MemoryScopeKind.User => if (authoredKey == "") {
            if (fallback.kind == MemoryScopeKind.User) { fallback.key } else { "local-user" }
        } else { authoredKey }
        case MemoryScopeKind.Workspace => if (authoredKey == "") {
            if (scopeName == "" && fallback.kind == MemoryScopeKind.Workspace) {
                fallback.key
            } else {
                currentWorkspace
            }
        } else { authoredKey }
        case MemoryScopeKind.Session => if (authoredKey == "") {
            if (scopeName == "" && fallback.kind == MemoryScopeKind.Session) {
                fallback.key
            } else {
                context.sessionId.value
            }
        } else { authoredKey }
    }
    if (kind == MemoryScopeKind.Workspace && key != currentWorkspace) {
        return memoryToolError<MemoryScope>(
            call,
            "scope_key",
            "workspace memory scope must match the active workspace"
        )
    }
    if (kind == MemoryScopeKind.Session && key != context.sessionId.value) {
        return memoryToolError<MemoryScope>(
            call,
            "scope_key",
            "session memory scope must match the active session"
        )
    }
    try {
        Result.Ok(MemoryScope(kind, key: key))
    } catch (error: IllegalArgumentException) {
        memoryToolError<MemoryScope>(call, "scope_key", error.message)
    }
}

func memoryV3KindFromValue(
    call: ToolCall,
    value: AgentValue,
    fallback: MemoryKind
): Result<MemoryKind> {
    let raw = match (memoryV3OptionalText(call, value, "kind")) {
        case Result.Ok(Some(text)) => text.trimAscii().toAsciiLower()
        case Result.Ok(None) => ""
        case Result.Err(error) => return Result.Err(error)
    }
    match (raw) {
        case "" => Result.Ok(fallback)
        case "preference" => Result.Ok(MemoryKind.Preference)
        case "project_fact" => Result.Ok(MemoryKind.ProjectFact)
        case "decision" => Result.Ok(MemoryKind.Decision)
        case "constraint" => Result.Ok(MemoryKind.Constraint)
        case "observation" => Result.Ok(MemoryKind.Observation)
        case _ => memoryToolError<MemoryKind>(
            call,
            "kind",
            "kind must be preference, project_fact, decision, constraint, or observation"
        )
    }
}

func memoryV3ImportanceFromValue(
    call: ToolCall,
    value: AgentValue,
    fallback: Int64
): Result<Int64> {
    match (value.field("importance")) {
        case None => Result.Ok(fallback)
        case Some(raw) =>
            if (raw.unifiedKind != ValueKind.Number) {
                return memoryToolError<Int64>(call, "importance", "importance must be a number")
            }
            try {
                let parsed = Float64.parse(raw.asNumberText())
                let clamped = if (parsed < 0.0) {
                    0.0
                } else if (parsed > 1.0) {
                    1.0
                } else {
                    parsed
                }
                Result.Ok(Int64(clamped * 1000.0))
            } catch (_: Exception) {
                memoryToolError<Int64>(call, "importance", "importance must be a number")
            }
    }
}

func memoryV3ExpiresAtFromValue(
    call: ToolCall,
    value: AgentValue,
    fallback: Int64
): Result<Int64> {
    match (value.field("expires_at")) {
        case None => Result.Ok(fallback)
        case Some(raw) =>
            if (raw.unifiedKind != ValueKind.Number) {
                return memoryToolError<Int64>(call, "expires_at", "expires_at must be an integer")
            }
            try {
                let parsed = Int64.parse(raw.asNumberText())
                if (parsed < 0) {
                    memoryToolError<Int64>(
                        call,
                        "expires_at",
                        "expires_at must be zero or a UTC Unix millisecond timestamp"
                    )
                } else {
                    Result.Ok(parsed)
                }
            } catch (_: Exception) {
                memoryToolError<Int64>(call, "expires_at", "expires_at must be an integer")
            }
    }
}

func memoryV3OptionalText(
    call: ToolCall,
    value: AgentValue,
    name: String
): Result<?String> {
    match (value.field(name)) {
        case None => Result.Ok(None)
        case Some(raw) =>
            if (raw.unifiedKind == ValueKind.Text) {
                Result.Ok(Some(raw.text))
            } else {
                memoryToolError<?String>(call, name, name + " must be a string")
            }
    }
}

func memoryV3SearchOptions(
    call: ToolCall,
    context: NativeMemoryToolContext,
    workspaceRoot: String
): Result<MemoryV3SearchOptions> {
    let scope = match (memoryV3ScopeFromValue(
        call,
        call.arguments,
        context,
        workspaceRoot,
        memoryV3DefaultScope(context, workspaceRoot)
    )) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let kinds = ArrayList<MemoryKind>()
    match (call.arguments.field("kinds")) {
        case None => ()
        case Some(raw) =>
            if (raw.unifiedKind != ValueKind.List) {
                return memoryToolError<MemoryV3SearchOptions>(
                    call,
                    "kinds",
                    "kinds must be an array"
                )
            }
            for (item in raw.items) {
                if (item.unifiedKind != ValueKind.Text) {
                    return memoryToolError<MemoryV3SearchOptions>(
                        call,
                        "kinds",
                        "each memory kind must be a string"
                    )
                }
                let kind = match (memoryV3KindFromText(call, item.text, "kinds")) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                if (!kinds.contains(kind)) { kinds.add(kind) }
            }
    }
    let limit = match (call.arguments.field("limit")) {
        case None => 10
        case Some(raw) =>
            if (raw.unifiedKind != ValueKind.Number) {
                return memoryToolError<MemoryV3SearchOptions>(
                    call,
                    "limit",
                    "limit must be an integer"
                )
            }
            try {
                Int64.parse(raw.asNumberText())
            } catch (_: Exception) {
                return memoryToolError<MemoryV3SearchOptions>(
                    call,
                    "limit",
                    "limit must be an integer"
                )
            }
    }
    try {
        Result.Ok(MemoryV3SearchOptions(
            scope: Some(scope),
            kinds: kinds.toArray(),
            limit: limit
        ))
    } catch (error: IllegalArgumentException) {
        memoryToolError<MemoryV3SearchOptions>(call, "limit", error.message)
    }
}

func memoryV3KindFromText(
    call: ToolCall,
    raw: String,
    field: String
): Result<MemoryKind> {
    match (raw.trimAscii().toAsciiLower()) {
        case "preference" => Result.Ok(MemoryKind.Preference)
        case "project_fact" => Result.Ok(MemoryKind.ProjectFact)
        case "decision" => Result.Ok(MemoryKind.Decision)
        case "constraint" => Result.Ok(MemoryKind.Constraint)
        case "observation" => Result.Ok(MemoryKind.Observation)
        case _ => memoryToolError<MemoryKind>(
            call,
            field,
            "kind must be preference, project_fact, decision, constraint, or observation"
        )
    }
}

func memoryV3ConflictIds(call: ToolCall, primaryId: String): Result<Array<String>> {
    let raw = match (call.arguments.field("conflict_ids")) {
        case Some(value) => value
        case None => return memoryToolError<Array<String>>(
            call,
            "conflict_ids",
            "mark_conflict requires at least one conflicting memory id"
        )
    }
    if (raw.unifiedKind != ValueKind.List || raw.items.isEmpty()) {
        return memoryToolError<Array<String>>(
            call,
            "conflict_ids",
            "conflict_ids must be a non-empty array"
        )
    }
    let ids = ArrayList<String>()
    ids.add(primaryId)
    for (item in raw.items) {
        if (item.unifiedKind != ValueKind.Text || item.text.trimAscii() == "") {
            return memoryToolError<Array<String>>(
                call,
                "conflict_ids",
                "each conflicting memory id must be a non-empty string"
            )
        }
        let id = item.text.trimAscii()
        if (ids.contains(id)) {
            return memoryToolError<Array<String>>(
                call,
                "conflict_ids",
                "conflicting memory ids must be unique"
            )
        }
        ids.add(id)
    }
    Result.Ok(ids.toArray())
}

// Original private parsing/error helpers now belong to the Native business package.
func memoryNativePolicyInt(value: AgentValue, name: String): Int64 {
    let field = value.field(name).getOrThrow()
    if (field.unifiedKind != ValueKind.Number) { throw IllegalArgumentException("integer required") }
    Int64.parse(field.asNumberText())
}

func memoryNativeRequiredString(call: ToolCall, name: String): Result<String> {
    match (call.arguments.field(name)) {
        case Some(value) =>
            if (value.unifiedKind == ValueKind.Text) {
                Result.Ok(value.text)
            } else {
                memoryNativeInvalidArgument(call, name, "argument must be a string")
            }
        case None => memoryNativeInvalidArgument(call, name, "required argument is missing")
    }
}

func memoryNativeInvalidArgument<T>(
    call: ToolCall,
    name: String,
    message: String
): Result<T> {
    Result.Err(
        AgentError(
            AgentErrorKind.InvalidInput,
            "tool.invalid_argument",
            message,
            fields: [
                ErrorField("tool", call.name),
                ErrorField("argument", name)
            ]
        )
    )
}

func requiredNonemptyMemoryString(
    call: ToolCall,
    name: String
): Result<String> {
    match (memoryNativeRequiredString(call, name)) {
        case Result.Ok(value) =>
            if (value.trimAscii() == "") {
                memoryToolError<String>(
                    call,
                    name,
                    name + " must not be empty"
                )
            } else {
                Result.Ok(value.trimAscii())
            }
        case Result.Err(error) => Result.Err(error)
    }
}

func optionalMemoryText(call: ToolCall, name: String): ?String {
    match (call.arguments.field(name)) {
        case Some(value) =>
            if (value.unifiedKind == ValueKind.Text) {
                Some(value.text)
            } else {
                None
            }
        case None => None
    }
}

func optionalMemoryString(call: ToolCall, name: String): String {
    match (optionalMemoryText(call, name)) {
        case Some(value) => value
        case None => ""
    }
}

func memoryObjectString(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(field) =>
            if (field.unifiedKind == ValueKind.Text) { field.text } else { "" }
        case None => ""
    }
}

func memoryV3Ids(records: Array<MemoryV3Record>): AgentValue {
    let ids = ArrayList<AgentValue>()
    for (record in records) { ids.add(textValue(record.id)) }
    listValue(ids.toArray())
}

func memoryV3RecordsValue(records: Array<MemoryV3Record>): AgentValue {
    let values = ArrayList<AgentValue>()
    for (record in records) { values.add(memoryToolRecordValue(record)) }
    listValue(values.toArray())
}

func memoryV3HitValues(hits: Array<MemoryV3SearchHit>): AgentValue {
    let values = ArrayList<AgentValue>()
    for (hit in hits) {
        values.add(objectValue([
            ValueField("id", textValue(hit.memory.id)),
            ValueField("kind", textValue(memoryV3KindName(hit.memory.kind))),
            ValueField("scope", textValue(memoryV3ScopeName(hit.memory.scope.kind))),
            ValueField("scopeKey", textValue(hit.memory.scope.key)),
            ValueField("content", textValue(hit.memory.content)),
            ValueField("context", textValue(hit.memory.context)),
            ValueField("source", textValue(hit.memory.source)),
            ValueField(
                "importance",
                numberValue(permilleNumber(hit.memory.importancePermille))
            ),
            ValueField(
                "score",
                numberValue(permilleNumber(hit.scorePermille))
            ),
            ValueField("status", textValue(memoryV3StatusName(hit.memory.status))),
            ValueField("expiresAt", integerValue(hit.memory.expiresAt)),
            ValueField("correctionOf", textValue(hit.memory.correctionOf)),
            ValueField("replacementId", textValue(hit.memory.replacementId)),
            ValueField("lexicalRank", integerValue(hit.lexicalRank)),
            ValueField("semanticRank", integerValue(hit.semanticRank))
        ]))
    }
    listValue(values.toArray())
}

func memoryToolRecordValue(record: MemoryV3Record): AgentValue {
    let conflicts = ArrayList<AgentValue>()
    for (id in record.conflictIds) { conflicts.add(textValue(id)) }
    objectValue([
        ValueField("id", textValue(record.id)),
        ValueField("kind", textValue(memoryV3KindName(record.kind))),
        ValueField("scope", textValue(memoryV3ScopeName(record.scope.kind))),
        ValueField("scopeKey", textValue(record.scope.key)),
        ValueField("content", textValue(record.content)),
        ValueField("context", textValue(record.context)),
        ValueField("source", textValue(record.source)),
        ValueField(
            "importance",
            numberValue(permilleNumber(record.importancePermille))
        ),
        ValueField("status", textValue(memoryV3StatusName(record.status))),
        ValueField("expiresAt", integerValue(record.expiresAt)),
        ValueField("correctionOf", textValue(record.correctionOf)),
        ValueField("replacementId", textValue(record.replacementId)),
        ValueField("conflictIds", listValue(conflicts.toArray())),
        ValueField("conflictReason", textValue(record.conflictReason)),
        ValueField("deletionReason", textValue(record.deletionReason)),
        ValueField("createdAt", integerValue(record.createdAt)),
        ValueField("updatedAt", integerValue(record.updatedAt)),
        ValueField("deletedAt", integerValue(record.deletedAt)),
        ValueField("revision", integerValue(record.revision))
    ])
}

func memoryV3MutationResult(
    call: ToolCall,
    status: String,
    record: MemoryV3Record,
    content: String
): ToolResult {
    ToolResult(
        call.callId,
        objectValue([
            ValueField("content", textValue(content)),
            ValueField("status", textValue(status)),
            ValueField("bank", textValue("local")),
            ValueField("store", textValue("working")),
            ValueField("memory", memoryToolRecordValue(record))
        ])
    )
}

func memoryV3MutationResultWithReplacement(
    call: ToolCall,
    status: String,
    record: MemoryV3Record,
    replacement: MemoryV3Record,
    content: String
): ToolResult {
    ToolResult(
        call.callId,
        objectValue([
            ValueField("content", textValue(content)),
            ValueField("status", textValue(status)),
            ValueField("bank", textValue("local")),
            ValueField("store", textValue("working")),
            ValueField("memory", memoryToolRecordValue(record)),
            ValueField("replacement", memoryToolRecordValue(replacement))
        ])
    )
}

func memoryV3ConflictResult(
    call: ToolCall,
    status: String,
    records: Array<MemoryV3Record>,
    reason: String
): ToolResult {
    ToolResult(
        call.callId,
        objectValue([
            ValueField(
                "content",
                textValue(records.size.toString() + " memories marked as conflicted.")
            ),
            ValueField("status", textValue(status)),
            ValueField("reason", textValue(reason)),
            ValueField("bank", textValue("local")),
            ValueField("store", textValue("working")),
            ValueField("memories", memoryV3RecordsValue(records))
        ])
    )
}







func memoryV3SearchStrategyName(value: MemorySearchStrategy): String {
    match (value) {
        case MemorySearchStrategy.Lexical => "lexical"
        case MemorySearchStrategy.Hybrid => "hybrid"
        case MemorySearchStrategy.LexicalFallback => "lexical_fallback"
    }
}

func formatRecallHits(
    hits: Array<MemoryV3SearchHit>,
    includeIds: Bool
): String {
    var text = ""
    for (index in 0..hits.size) {
        if (index > 0) { text += "\n\n" }
        let hit = hits[index]
        text += "- " + hit.memory.content
        if (includeIds) { text += " (id: " + hit.memory.id + ")" }
        if (hit.memory.source != "") {
            text += " [" + hit.memory.source + "]"
        }
        text += " c:" + confidenceOneDecimal(hit.scorePermille)
    }
    text
}

func confidenceOneDecimal(permille: Int64): String {
    let tenths = (permille + 50) / 100
    let bounded = if (tenths > 10) { 10 } else { tenths }
    (bounded / 10).toString() + "." + (bounded % 10).toString()
}

func permilleNumber(permille: Int64): String {
    (permille / 1000).toString() + "." +
        threeDigits(permille % 1000)
}

func threeDigits(value: Int64): String {
    if (value < 10) {
        "00" + value.toString()
    } else if (value < 100) {
        "0" + value.toString()
    } else {
        value.toString()
    }
}

func learnResult(
    call: ToolCall,
    text: String,
    memoryId: String,
    skill: ?String
): ToolResult {
    ToolResult(
        call.callId,
        objectValue([
            ValueField("content", textValue(text)),
            ValueField("memoryId", textValue(memoryId)),
            ValueField(
                "skill",
                match (skill) {
                    case Some(value) => textValue(value)
                    case None => nullValue()
                }
            )
        ])
    )
}

func manageSkillResult(
    call: ToolCall,
    action: String,
    name: String,
    text: String
): ToolResult {
    ToolResult(
        call.callId,
        objectValue([
            ValueField("content", textValue(text)),
            ValueField("action", textValue(action)),
            ValueField("name", textValue(name))
        ])
    )
}

func memoryToolError<T>(
    call: ToolCall,
    argument: String,
    message: String
): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.InvalidInput,
        "tool.memory_invalid_argument",
        message,
        fields: [
            ErrorField("tool", call.name),
            ErrorField("argument", argument)
        ]
    ))
}


func objectSchema(
    properties: Array<ValueField>,
    required: Array<String>
): AgentValue {
    let requiredValues = ArrayList<AgentValue>()
    for (name in required) {
        requiredValues.add(textValue(name))
    }
    objectValue(
        [
            ValueField("type", textValue("object")),
            ValueField("properties", objectValue(properties)),
            ValueField("required", listValue(requiredValues.toArray())),
            ValueField("additionalProperties", boolValue(false))
        ]
    )
}

func schemaProperty(name: String, kind: String): ValueField {
    ValueField(name, objectValue([ValueField("type", textValue(kind))]))
}

func schemaEnumProperty(
    name: String,
    values: Array<String>
): ValueField {
    let encoded = ArrayList<AgentValue>()
    for (value in values) {
        encoded.add(textValue(value))
    }
    ValueField(
        name,
        objectValue(
            [
                ValueField("type", textValue("string")),
                ValueField("enum", listValue(encoded.toArray()))
            ]
        )
    )
}

func memoryNativeProposalError<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput,code,"the selected Native memory proposal is invalid"))
}
