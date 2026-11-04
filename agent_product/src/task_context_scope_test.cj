package agent_product

import agent_core.*
import agent_cli.*
import agent_domain.*
import agent_runtime.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class ProductTaskContextScopeTests {
    @TestCase
    func contextFactsPreserveTheActualOpaqueReviewIdentity(): Unit {
        let root = contextScopeTestRoot()
        try {
            let identity = planReviewHash("approved immutable plan")
            @Expect(identity, modelPolicySha256Text("approved immutable plan"))
            @Expect(identity.size, 64)
            let scope = TaskContextScope(identity, [root])
            @Expect(scope.approvalHash, identity)
            @Expect(buildProductTaskContextFacts(root, scope).field("approval_hash").getOrThrow().text,
                identity)
        } finally { let _ = removeIfExists(root, recursive: true) }
    }

    @TestCase
    func externalTargetExcludesWorkspaceInstructionsAndPreservesUserGuide(): Unit {
        let root = contextScopeTestRoot()
        try {
            let repo = root + "/repo"
            let external = root + "/external"
            Directory.create(repo + "/.git", recursive: true)
            Directory.create(external, recursive: true)
            File.writeTo(repo + "/AGENTS.md", "REPOSITORY_ONLY_GUIDANCE".toArray())
            let scope = TaskContextScope(contextScopeTestHash(), [external])
            let context = loadProductProjectContext(repo, taskScope: Some(scope))
            @Expect(context.instructions.isEmpty())
            let prompt = buildProductPrompt(repo, "", "EXPLICIT_USER_INSTRUCTION", "",
                taskScope: Some(scope))
            @Expect(prompt.text.contains("EXPLICIT_USER_INSTRUCTION"))
            @Expect(!prompt.text.contains("REPOSITORY_ONLY_GUIDANCE"))
            @Expect(prompt.text.contains("capabilities granted to this run"))
            let selection = loadProductScopedInstructions(repo, scope)
            @Expect(selection.sources.items.size, 1)
            @Expect(selection.sources.items[0].field("reason").getOrThrow().text,
                "repository_outside_approved_scope")
            @Expect(selection.sources.items[0].field("hash").getOrThrow().text, "")
            @Expect(!selection.sources.items[0].field("selected").getOrThrow().asBool())
        } finally { let _ = removeIfExists(root, recursive: true) }
    }

    @TestCase
    func declaredRepositoryReadRetainsWholeInstructions(): Unit {
        let root = contextScopeTestRoot()
        try {
            let repo = root + "/repo"
            Directory.create(repo + "/.git", recursive: true)
            Directory.create(root + "/external", recursive: true)
            let content = "Commit rules\nPrivacy rules\nIssue rules"
            File.writeTo(repo + "/AGENTS.md", content.toArray())
            let scope = TaskContextScope(contextScopeTestHash(), [root + "/external"],
                participatingRepositories: [repo])
            @Expect(scope.includesPath(repo + "/source.cj"))
            let context = loadProductProjectContext(repo, taskScope: Some(scope))
            @Expect(context.instructions.size, 1)
            @Expect(context.instructions[0].content, content)
        } finally { let _ = removeIfExists(root, recursive: true) }
    }

    @TestCase
    func symlinkCrossingUsesDestinationScopeForNewTargets(): Unit {
        let root = contextScopeTestRoot()
        try {
            let repo = root + "/repo"
            let external = root + "/external"
            Directory.create(repo + "/.git", recursive: true)
            Directory.create(external, recursive: true)
            File.writeTo(repo + "/AGENTS.md", "REPO".toArray())
            SymbolicLink.create(repo + "/link", to: external)
            let scope = TaskContextScope(contextScopeTestHash(), [repo + "/link/new-app"])
            @Expect(scope.targetRoots[0], external + "/new-app")
            @Expect(!scope.includesRepository(repo))
            @Expect(!scope.includesPath(repo + "/source.cj"))
            @Expect(scope.includesPath(external + "/new-app/index.js"))
            @Expect(loadProductProjectContext(repo, taskScope: Some(scope)).instructions.isEmpty())
            @Expect(canonicalTaskPath(repo + "/link/../sibling"), root + "/sibling")
        } finally { let _ = removeIfExists(root, recursive: true) }
    }

    @TestCase
    func instructionDirectorySymlinkCannotImportUndeclaredRepositoryGuidance(): Unit {
        let root = contextScopeTestRoot()
        try {
            let repo = root + "/repo"
            let external = root + "/external"
            Directory.create(repo + "/.git", recursive: true)
            Directory.create(external, recursive: true)
            File.writeTo(external + "/instructions.md", "OUTSIDE_INSTRUCTION".toArray())
            SymbolicLink.create(repo + "/.codex", to: external)
            let scope = TaskContextScope(contextScopeTestHash(), [repo])
            let selection = loadProductScopedInstructions(repo, scope)
            @Expect(selection.instructions.isEmpty())
            @Expect(selection.sources.items.size, 1)
            @Expect(selection.sources.items[0].field("reason").getOrThrow().text,
                "source_crosses_repository_boundary")
        } finally { let _ = removeIfExists(root, recursive: true) }
    }

    @TestCase
    func toolViewCannotBroadenFrozenCapabilitiesOrChangeSchemas(): Unit {
        let schema = objectValue([ValueField("type", textValue("object"))])
        let entry = ToolSnapshotEntry("read", "Read a file", schema, "1",
            [Capability(CapabilityKind.WorkspaceRead)])
        let frozen = ToolSetSnapshot("frozen", [entry])
        match (selectRequestToolSet(frozen, ["read"])) {
            case Result.Ok(view) =>
                @Expect(view.entries.size, 1)
                @Expect(view.entries[0].requiredCapabilities[0].kind == CapabilityKind.WorkspaceRead)
                @Expect(frozen.entries.size, 1)
            case Result.Err(_) => @Expect(false)
        }
        @Expect(match (selectRequestToolSet(frozen, ["host_network"])) {
            case Result.Err(_) => true
            case _ => false
        })
        let changed = objectValue([ValueField("tools", listValue([objectValue([
            ValueField("name", textValue("read")),
            ValueField("description", textValue("Read a file")),
            ValueField("input_schema", objectValue([]))
        ])]))])
        @Expect(match (validateRenderedRequestToolView(frozen, changed)) {
            case Result.Err(_) => true
            case _ => false
        })
    }

    @TestCase
    func mathAndLifecycleWarningsNeverClaimExecutedProof(): Unit {
        let source = "quarterTurns = (-Math.sign(layer) * 4) % 4; " +
            "rotVec(v, axis, quarterTurns); rotVec(startPos, axis, angle); " +
            "reset(){ queue.clear(); state.reset(); } animateMove(); state.applyMove(move)"
        let advisories = productPlanReviewAdvisoriesValue(source)
        @Expect(advisories.items.size, 3)
        for (item in advisories.items) {
            @Expect(item.field("kind").getOrThrow().text, "advisory")
            @Expect(!item.field("executed").getOrThrow().asBool())
        }
        @Expect(reviewProductPlanAdvisories("quarterTurns = -Math.sign(layer)").isEmpty())
    }
}

func contextScopeTestRoot(): String {
    let parent = getVariable("TMPDIR").getOrDefault({ =>
        getVariable("HOME").getOrThrow() + "/.cache/agent-tmp"
    })
    if (!exists(Path(parent))) { Directory.create(parent, recursive: true) }
    let root = canonicalize(Directory.createTemp(parent)).toString()
    // Stop ancestor discovery at the fixture boundary rather than inheriting
    // the checkout containing the test executable.
    Directory.create(root + "/.git", recursive: true)
    root
}

func contextScopeTestHash(): String {
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
}
