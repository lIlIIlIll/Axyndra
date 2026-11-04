package agent_product

import agent_core.*
import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.env.*
import std.convert.*
import std.fs.*
import yjson.*
import yjson_support.*

// This is approved, structured scope, never an inference from user prose. It
// selects project guidance; it does not grant filesystem or tool capability.
public class TaskContextScope {
    public let approvalHash: String
    public let targetRoots: Array<String>
    public let participatingRepositories: Array<String>

    public init(
        approvalHash: String,
        targetRoots: Array<String>,
        participatingRepositories!: Array<String> = []
    ) {
        // Preserve the actual review protocol identity verbatim. Scope
        // selection does not reinterpret or truncate the approval digest.
        if (approvalHash.trimAscii() == "" || approvalHash != approvalHash.trimAscii() || targetRoots.isEmpty()) {
            throw IllegalArgumentException("Task context requires approved target roots")
        }
        this.approvalHash = approvalHash
        this.targetRoots = canonicalTaskRoots(targetRoots)
        this.participatingRepositories = canonicalTaskRoots(participatingRepositories)
    }

    public func includesRepository(root: String): Bool {
        let canonical = canonicalTaskPath(root)
        for (repository in participatingRepositories where repository == canonical) { return true }
        for (target in targetRoots where taskPathWithin(target, canonical) || taskPathWithin(canonical, target)) {
            return true
        }
        false
    }

    // Call before reading outside declared scope. Discovering new repository
    // participation requires revising the approved contract, not silently
    // discarding that repository's guidance.
    public func includesPath(path: String): Bool {
        let canonical = canonicalTaskPath(path)
        for (root in targetRoots where taskPathWithin(canonical, root)) { return true }
        for (root in participatingRepositories where taskPathWithin(canonical, root)) { return true }
        false
    }
}

public class TaskInstructionSelection {
    public let instructions: Array<ProjectInstruction>
    public let sources: AgentValue

    public init(instructions: Array<ProjectInstruction>, sources: AgentValue) {
        this.instructions = instructions
        this.sources = sources
    }
}

// Resolve existing ancestors as well as existing targets. normalize() alone
// would permit a symlinked, not-yet-created target to retain the wrong scope.
public func canonicalTaskPath(value: String): String {
    if (!Path(value).isAbsolute() || value.contains("\u{0000}")) {
        throw IllegalArgumentException("Task context paths must be absolute")
    }
    var current = Path(value)
    let suffix = ArrayList<String>()
    while (!exists(current)) {
        let parent = current.parent
        if (parent.toString() == current.toString() || parent.toString() == "") {
            throw IllegalArgumentException("Task context path has no resolvable ancestor")
        }
        suffix.add(current.fileName)
        current = parent
    }
    var resolved = canonicalize(current)
    var index = suffix.size
    while (index > 0) {
        index -= 1
        resolved = resolved.join(suffix[index])
    }
    resolved.normalize().toString()
}

func canonicalTaskRoots(values: Array<String>): Array<String> {
    let result = ArrayList<String>()
    for (value in values) { productPromptAddUnique(result, canonicalTaskPath(value)) }
    result.toArray()
}

func taskPathWithin(path: String, root: String): Bool {
    path == root || path.startsWith(if (root.endsWith("/")) { root } else { root + "/" })
}

public func loadProductScopedInstructions(
    workspaceRoot: String,
    scope: TaskContextScope,
    budget!: ProjectPreloadBudget = ProjectPreloadBudget()
): TaskInstructionSelection {
    loadProductScopedInstructionsFrame204(workspaceRoot, scope, budget, None<TaskInstructionDataMeter204>)
}

class TaskInstructionDataMeter204 {
    let payment: LogicalJsonOwnerReservation
    private var peak: Int64
    init(payment: LogicalJsonOwnerReservation, peak: Int64) { this.payment = payment; this.peak = peak }
    private func add204(bytes: Int64): Unit {
        if (bytes < 0 || bytes > 1073741824 - peak) {
            throw LogicalJsonPayloadError("approved context copy extent exceeds its bound") }
        payment.ensureRetainedPeak(peak + bytes)
        peak += bytes
    }
    func path204(parent: String, suffix: String): Unit {
        add204((parent.size + suffix.size + 1) * 256 + 4096)
    }
    func source204(path: String, root: String): Unit {
        add204((path.size + root.size + 256) * 256 + 32768)
    }
    func text204(bytes: Int64): Unit { add204(bytes * 256 + 16384) }
}

func loadProductScopedInstructionsFrame204(workspaceRoot: String, scope: TaskContextScope,
    budget: ProjectPreloadBudget, meter: ?TaskInstructionDataMeter204): TaskInstructionSelection {
    let workspace = canonicalTaskPath(workspaceRoot)
    let roots = ArrayList<String>()
    productPromptAddUnique(roots, productPromptRepositoryRoot(workspace))
    for (root in scope.participatingRepositories) { productPromptAddUnique(roots, root) }
    for (target in scope.targetRoots) {
        productPromptAddUnique(roots, productPromptRepositoryRoot(target))
    }
    let instructions = ArrayList<ProjectInstruction>()
    let sources = ArrayList<AgentValue>()
    let seen = ArrayList<String>()
    var bytes: Int64 = 0
    for (root in roots) {
        let candidates = ArrayList<String>()
        for (relative in ["AGENTS.md", "CLAUDE.md", ".codex/instructions.md",
            ".github/copilot-instructions.md"]) {
            match (meter) { case Some(value) => value.path204(root, relative); case None => () }
            productPromptAddUnique(candidates, Path(root).join(relative).toString())
        }
        for (target in scope.targetRoots where taskPathWithin(target, root)) {
            var current = target
            let ancestors = ArrayList<String>()
            var remaining: Int64 = 64
            while (current != root && taskPathWithin(current, root) && remaining > 0) {
                ancestors.add(current)
                current = Path(current).parent.toString()
                remaining -= 1
            }
            var index = ancestors.size
            while (index > 0) {
                index -= 1
                for (name in ["AGENTS.md", "CLAUDE.md"]) {
                    match (meter) { case Some(value) => value.path204(ancestors[index], name); case None => () }
                    productPromptAddUnique(candidates, Path(ancestors[index]).join(name).toString())
                }
            }
        }
        for (candidate in candidates) {
            if (seen.contains(candidate)) { continue }
            seen.add(candidate)
            if (!exists(Path(candidate))) { continue }
            match (meter) { case Some(value) => value.source204(candidate, root); case None => () }
            var hash = ""
            var selected = false
            var reason = "repository_outside_approved_scope"
            let applicable = scope.includesRepository(root)
            let resolvedSource = try { canonicalTaskPath(candidate) } catch (_: Exception) { "" }
            // Exclusion is decided before opening content. An empty hash with
            // this reason records that the unrelated instruction was not read.
            if (!applicable) {
                reason = "repository_outside_approved_scope"
            } else if (resolvedSource == "" || !taskPathWithin(resolvedSource, root)) {
                reason = "source_crosses_repository_boundary"
            } else if (instructions.size >= budget.maxFiles ||
                bytes >= min(budget.maxBytes, budget.maxInstructionBytes)) {
                reason = "preload_budget_exhausted"
            } else if (!productPromptBoundedRegularFile(Path(candidate), 1048576)) {
                reason = "source_not_bounded_regular_file"
            } else {
                let observed = readProductTaskInstruction204(candidate,
                    min(budget.maxBytes, budget.maxInstructionBytes) - bytes, meter)
                let readable = observed.isSome()
                let content = observed ?? ""
                if (readable) { hash = modelPolicySha256Text(content) }
                if (content.trimAscii() == "") {
                    reason = if (readable) { "source_empty" } else { "source_unreadable" }
                } else if (applicable) {
                    if (instructions.size >= budget.maxFiles ||
                        bytes + content.toArray().size > min(budget.maxBytes, budget.maxInstructionBytes)) {
                        reason = "preload_budget_exhausted"
                    } else {
                        instructions.add(ProjectInstruction(candidate, content))
                        bytes += content.toArray().size
                        selected = true
                        reason = "approved_repository_participation"
                    }
                }
            }
            sources.add(objectValue([
                ValueField("source", textValue(candidate)),
                ValueField("scope", textValue(root)),
                ValueField("hash", textValue(hash)),
                ValueField("selected", boolValue(selected)),
                ValueField("reason", textValue(reason))
            ]))
        }
    }
    TaskInstructionSelection(instructions.toArray(), listValue(sources.toArray()))
}

public func buildProductTaskContextFacts(workspaceRoot: String, scope: TaskContextScope): AgentValue {
    productTaskContextFacts(scope, loadProductScopedInstructions(workspaceRoot, scope,
        budget: ProjectPreloadBudget(maxFiles: 6, maxBytes: 32768, maxInstructionBytes: 32768)))
}

func productTaskContextFacts(scope: TaskContextScope, selection: TaskInstructionSelection): AgentValue {
    let targets = ArrayList<AgentValue>()
    let repositories = ArrayList<AgentValue>()
    for (root in scope.targetRoots) { targets.add(textValue(root)) }
    for (root in scope.participatingRepositories) { repositories.add(textValue(root)) }
    objectValue([
        ValueField("approval_hash", textValue(scope.approvalHash)),
        ValueField("target_roots", listValue(targets.toArray())),
        ValueField("participating_repositories", listValue(repositories.toArray())),
        ValueField("instruction_sources", selection.sources)
    ])
}

public class ProductScopedPrompt {
    private var promptData204: ?PromptBuild
    private var factsData204: ?AgentValue
    private var retainedAllocation204: ?LogicalJsonOwnerReservation
    private var buildingRequestCustody204: ?PlanRequestCustody204 = None<PlanRequestCustody204>
    public prop prompt: PromptBuild { get() { promptData204.getOrThrow() } }
    public prop contextFacts: AgentValue { get() { factsData204.getOrThrow() } }

    public init(prompt: PromptBuild, contextFacts: AgentValue,
        retainedAllocation204!: ?LogicalJsonOwnerReservation = None) {
        this.promptData204 = Some(prompt)
        this.factsData204 = Some(contextFacts)
        this.retainedAllocation204 = retainedAllocation204
    }
    public func takeRequestCustody204(): ?PlanRequestCustody204 {
        match (retainedAllocation204) {
            case Some(payment) =>
                let custody = PlanRequestCustody204(payment)
                retainedAllocation204 = None<LogicalJsonOwnerReservation>
                buildingRequestCustody204 = Some(custody)
                Some(custody)
            case None => None<PlanRequestCustody204>
        }
    }
    // The complete Product constructor returned a request to its caller. Its
    // actual custody, rather than this short preparation wrapper, now pays.
    public func deliveredRequestAfterBuilder204(): Unit {
        promptData204 = None<PromptBuild>; factsData204 = None<AgentValue>
        buildingRequestCustody204 = None<PlanRequestCustody204>
    }
    // Only after the whole private constructor frame unwinds without publishing
    // any request. Core's typed guard refuses this proof after any real visit.
    public func closeUnsubmittedAfterRequestBuilder204(): Unit {
        promptData204 = None<PromptBuild>; factsData204 = None<AgentValue>
        let unpublished = buildingRequestCustody204
        buildingRequestCustody204 = None<PlanRequestCustody204>
        closeAfterPromptConsumer204()
        match (unpublished) {
            case Some(custody) => match (custody.returnUnsubmittedApplicationFrame204()) {
                case Result.Ok(_) => ()
                case Result.Err(_) => throw IllegalStateException("request builder cannot retire a submitted custody")
            }
            case None => ()
        }
    }
    // Only for a complete non-Run consumer such as request-dump serialization.
    // A request transfers payment to its actual PlanRequestCustody instead.
    public func closeAfterPromptConsumer204(): Unit {
        promptData204 = None<PromptBuild>; factsData204 = None<AgentValue>
        let returned = retainedAllocation204; retainedAllocation204 = None<LogicalJsonOwnerReservation>
        match (returned) { case Some(value) => value.close(); case None => () }
    }
}

// Build prompt text and its audit facts from the same reads. Computing them
// independently would let an intervening instruction edit invalidate hashes.
public func buildProductScopedPrompt(
    workspaceRoot: String,
    activeGoal: String,
    guide: String,
    modeSystem: String,
    scope: TaskContextScope,
    memoryContext!: String = ""
): ProductScopedPrompt {
    buildProductScopedPromptFrame204(workspaceRoot, activeGoal, guide, modeSystem, scope,
        memoryContext, None<TaskInstructionDataMeter204>)
}

private func buildProductScopedPromptFrame204(workspaceRoot: String, activeGoal: String,
    guide: String, modeSystem: String, scope: TaskContextScope, memoryContext: String,
    meter: ?TaskInstructionDataMeter204): ProductScopedPrompt {
    let base = productPromptProjectFacts(workspaceRoot, meter: meter)
    let selection = loadProductScopedInstructionsFrame204(workspaceRoot, scope, base.preloadBudget, meter)
    let context = ProjectContext(base.repositoryRoot, base.cwd, base.branch, base.dirty,
        base.buildSystem, base.language, instructions: selection.instructions,
        preloadBudget: base.preloadBudget, version: base.version)
    ProductScopedPrompt(buildProductPromptFromContext(context, activeGoal, guide, modeSystem,
        memoryContext), productTaskContextFacts(scope, selection))
}

// Frozen entries are reused verbatim. A request view cannot add a new tool,
// alter a schema, strip capability requirements, or change executor identity.
public func selectProductRequestTools(
    frozen: ToolSetSnapshot,
    allowedNames: Array<String>
): Result<ToolSetSnapshot> {
    selectRequestToolSet(frozen, allowedNames)
}

// Minimal approved scope is read under the original Registry/request bank.
// Independent prompt/facts copies remain paid by the actual request custody;
// returning the short Store consumer never refunds those retained copies.
public func buildProductScopedPromptFromRead204(workspaceRoot: String, guide: String, modeSystem: String,
    prompt: String, owner: PlanExecutionReadOwner204): Result<ProductScopedPrompt> {
    let consumer = owner.beginConsumer204()
    let unpublished = ProductScopeUnpublishedPayment204()
    let copied = try {
        productScopedPromptCopyFrame204(workspaceRoot, guide, modeSystem, prompt, owner, consumer, unpublished)
    } catch (_: LogicalJsonPayloadError) {
        unpublished.closeAfterBuilderReturned204()
        consumer.returnConsumerFrame204(); owner.closeAfterCaller204()
        return planExecutionError("plan.scope_copy_capacity", "Approved task context cannot fit the original caller DATA budget")
    } catch (_: Exception) {
        unpublished.closeAfterBuilderReturned204()
        consumer.returnConsumerFrame204(); owner.closeAfterCaller204()
        return planExecutionError("plan.scope_copy_failed", "Approved task context could not be copied from its immutable scope")
    }
    unpublished.transferred204()
    consumer.returnConsumerFrame204()
    owner.closeAfterCaller204()
    Result.Ok(copied)
}

private class ProductScopeUnpublishedPayment204 {
    var payment: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    func transferred204(): Unit { payment = None<LogicalJsonOwnerReservation> }
    func closeAfterBuilderReturned204(): Unit {
        let returned = payment; payment = None<LogicalJsonOwnerReservation>
        match (returned) { case Some(value) => value.close(); case None => () }
    }
}

private func productScopedPromptCopyFrame204(workspaceRoot: String, guide: String, modeSystem: String,
    prompt: String, owner: PlanExecutionReadOwner204, consumer: PlanExecutionReadConsumer204,
    unpublished: ProductScopeUnpublishedPayment204): ProductScopedPrompt {
    let source = consumer.value204()
    let targets = source.field("target_roots").getOrThrow()
    let repositories = source.field("participating_repositories").getOrThrow()
    let execution = source.field("execution_id").getOrThrow().text
    // Fund canonical root/prompt metadata first. Candidate paths are charged
    // individually before construction, existing audit sources before their
    // facts, and each actual bounded text read before bytes are copied. Missing
    // hypothetical ancestors do not reserve a 32 KiB content allowance.
    var longest = workspaceRoot.size
    var rootBytes: Int64 = 0
    for (values in [targets, repositories]) {
        for (root in values.items) { longest = max(longest, root.text.size); rootBytes += root.text.size }
    }
    let rootCount = targets.items.size + repositories.items.size + 1
    if (longest > 4096 || rootCount > 129) {
        throw LogicalJsonPayloadError("approved context roots exceed the original resource envelope") }
    let rootScratch = rootCount * (longest * 32 + 1024) * 64
    let retained = 131072 + rootScratch +
        (rootBytes + execution.size + prompt.size + guide.size + modeSystem.size + workspaceRoot.size) * 256
    if (retained > 1073741824) { throw LogicalJsonPayloadError("approved context copy extent exceeds its bound") }
    let payment = owner.deriveRetainedAllocation204(retained)
    unpublished.payment = Some(payment)
    let meter = TaskInstructionDataMeter204(payment, retained)
    let roots = ArrayList<String>(); let participating = ArrayList<String>()
    for (root in targets.items) {
        if (canonicalTaskPath(root.text) != root.text) { throw IllegalStateException("approved target identity changed") }
        roots.add(String.fromUtf8(root.text.toArray()))
    }
    for (root in repositories.items) {
        if (canonicalTaskPath(root.text) != root.text) { throw IllegalStateException("approved repository identity changed") }
        participating.add(String.fromUtf8(root.text.toArray()))
    }
    let identity = execution.split("-")
    if (identity.size < 4 || identity[0] != "plan" || identity[1] == "" || identity[2] != "operation") {
        throw IllegalStateException("approved scope has no exact review identity") }
    let scope = TaskContextScope(String.fromUtf8(identity[1].toArray()), roots.toArray(),
        participatingRepositories: participating.toArray())
    let built = buildProductScopedPromptFrame204(workspaceRoot, "", guide, modeSystem, scope, "", Some(meter))
    ProductScopedPrompt(built.prompt, built.contextFacts, retainedAllocation204: Some(payment))
}

// Reuse the existing verified-handle reader. Canonical/stat checks decide
// scope, while the native witness/copy prevents a subsequent path swap from
// widening the actual content read. Only this private disk child is removed.
func readProductTaskInstruction204(source: String, maximum: Int64,
    meter: ?TaskInstructionDataMeter204): ?String {
    if (maximum < 1 || maximum > 32768) { return None<String> }
    let witness = match (readViewWitness(source)) {
        case Result.Ok(value) => value
        case Result.Err(_) => return None<String>
    }
    let parts = witness.split(":")
    let size = try { if (parts.size > 4) { Int64.parse(parts[4]) } else { -1 } } catch (_: Exception) { -1 }
    if (!witness.startsWith("f:") || size < 1 || size > maximum) { return None<String> }
    match (meter) { case Some(value) => value.text204(size); case None => () }
    let parent = getVariable("TMPDIR").getOrDefault({ => getVariable("HOME").getOrThrow() + "/.cache/agent-tmp" })
    var temporary: ?Path = None<Path>
    try {
        if (!exists(Path(parent))) { Directory.create(parent, recursive: true) }
        let directory = Directory.createTemp(parent); temporary = Some(directory)
        let target = directory.join("instruction")
        match (readViewCopy(source, witness, target.toString(), maximum)) {
            case Result.Err(_) => None<String>
            case Result.Ok(copied) => if (copied == size) {
                let data = File.readFrom(target)
                if (data.size == size) { Some(String.fromUtf8(data)) } else { None<String> }
            } else { None<String> }
        }
    } catch (_: Exception) { None<String> }
    finally { match (temporary) { case Some(value) => remove(value, recursive: true); case None => () } }
}
