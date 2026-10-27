package agent_product

import agent_plugin_registry

import agent_core.*
import agent_domain.*
import agent_domain.CancellationSource as CompactionTestCancellationSource
import agent_store.*
import std.collection.*
import std.env.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.*
import yjson.*
import yjson_support.*

class CompactionPolicyFixture {
    let root: String
    let product: ProductRuntime
    let database: SqliteDatabase
    let record: ?agent_plugin_registry.ProductPluginRecord
    private let registryOwners = ProductRegistryTestOwners()
    private let registry: ?agent_plugin_registry.PluginRegistry
    let session = SessionId("installed-compaction")
    init(install!: Bool = true, hybrid!: Bool = true, failure!: Bool = false, seedDefaultHistory!: Bool = true) {
        let root = pluginContractTemp("compaction-policy")
        let opened = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: root,
            settingsRoot: root + "/settings", stateRoot: root + "/state", fixture: true, asyncEnabled: false,
            compactionOverride: Some(ProductCompactionSettings(keepRecentMessages: 6,
                summaryStrategy: if (hybrid) { "hybrid" } else { "structured" }, summaryModel: "fixture",
                summaryMaxOutputTokens: 200)))))
        let selected: ?agent_plugin_registry.ProductPluginRecord = if (install) {
            let value = match (opened.importLocalPlugin(getVariable("AXYNDRA_COMPACTION_PLUGIN_PACKAGE").getOrThrow())) {
                case PluginRegistryResult.Ok(value) => value
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message)) }
            @Expect(opened.setPluginEnabled(productRegistryCopyText83(value.descriptor.copyText(PluginDescriptorText.Namespace)), true).isOk())
            let actualRegistry = registryOwners.openRegistry(root + "/settings", root)
            registry = Some(actualRegistry)
            let actual = match (actualRegistry.resolveForMutation(productRegistryCopyText83(value.descriptor.copyText(PluginDescriptorText.Namespace)))) {
                case PluginRegistryResult.Ok(result) => result
                case PluginRegistryResult.Err(error) => throw IllegalStateException(error.code)
            }
            value.close()
            Some(actual)
        } else { registry = None; None }
        this.root = root; this.product = opened; this.record = selected
        this.database = SqliteDatabase(root + "/state/state.db")
        if (install) { writeSelection(productRegistryCopyText83(selected.getOrThrow().descriptor.copyText(PluginDescriptorText.ContentDigest))) }
        let messages = ArrayList<ModelMessage>()
        messages.add(ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text,
            text: if (failure) { "FIXTURE-COMPACTION-SUMMARY-FAILURE preserve this fact" } else { "AUTHORITATIVE-ORIGINAL-FACT" })]))
        for (index in 0..14) { messages.add(ModelMessage(if (index % 2 == 0) { ModelRole.Assistant } else { ModelRole.User },
            [ModelBlock(ModelBlockKind.Text, text: "retained original history " + index.toString())])) }
        if (seedDefaultHistory) { lifecycleTestRequire(opened.replaceMessages(session, messages.toArray())) }
    }
    func writeSelection(digest: String): Unit {
        if (!exists(Path(root + "/settings/plugins"))) { Directory.create(root + "/settings/plugins", recursive: true) }
        File.writeTo(root + "/settings/plugins/policies.json", stringifyUnifiedJson(objectValue([
            ValueField("version", integerValue(1)), ValueField("bindings", objectValue([ValueField("compaction", objectValue([
                ValueField("namespace", textValue(productRegistryCopyText83(record.getOrThrow().descriptor.copyText(PluginDescriptorText.Namespace)))),
                ValueField("provider", textValue("summarize")), ValueField("package_digest", textValue(digest))]))]))])).toArray())
        File.writeTo(root + "/settings/plugins/canonical-data.json", encodeAgentValue(objectValue([
            ValueField("version", integerValue(1)), ValueField("plugins", listValue([objectValue([
                ValueField("namespace", textValue("axyndra:compaction")), ValueField("package_digest", textValue(digest)),
                ValueField("tools", listValue([canonicalCheckpointFixtureGrant173("checkpoint"),
                    canonicalCheckpointFixtureGrant173("rewind")]))])]))])).toArray())
        // The exact configuration is captured by the actual mount, rather
        // than an already-published old executor silently learning a grant.
        let ns = productRegistryCopyText83(record.getOrThrow().descriptor.copyText(PluginDescriptorText.Namespace))
        @Expect(product.setPluginEnabled(ns, false).isOk())
        @Expect(product.setPluginEnabled(ns, true).isOk())
    }
    func checkpoint(): AgentValue {
        let rows = database.query("SELECT payload FROM context_checkpoints WHERE thread_id=?", [SqlParameter.Text(session.value)])
        @Expect(rows.size, 1)
        decodeStoredValue(rows[0].required(0))
    }
    func originalItems(): String {
        // Hash the exact same ordered id:payload\n bytes incrementally.
        // Avoid holding a second complete history plus StringBuilder growth
        // and the final UTF8 copy before the actual maintenance begins.
        let result = SHA256()
        for (row in database.query("SELECT id,payload FROM items WHERE kind IN ('user_message','assistant_message') ORDER BY ordinal")) {
            result.write(row.required(0).toArray()); result.write(":".toArray())
            result.write(row.required(1).toArray()); result.write("\n".toArray())
        }
        serviceObservationHex(result.finish())
    }
    func noExecutionOrCheckpoint(): Unit {
        @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM context_checkpoints"), 0)
    }
    func host(): ProductJavaScriptPluginHost {
        let result = ProductJavaScriptPluginHost(settingsRoot: root + "/settings")
        lifecycleTestRequire(result.ownRegistry(registry.getOrThrow()))
        result
    }
    func close(): Unit { let _ = product.close(); database.close(); registryOwners.close(); remove(root, recursive: true) }
}

@Test
class InstalledCompactionPolicyTests {
    @TestCase
    func installedAlgorithmUsesActualMaintenanceAttemptAndPreservesCanonicalHistory(): Unit {
        let f = CompactionPolicyFixture()
        try {
            let before = f.originalItems()
            @Expect(lifecycleTestRequire(f.product.compactSession(f.session, force: true)) > 0)
            @Expect(f.originalItems(), before)
            let summary = f.checkpoint().field("structured_summary").getOrThrow()
            @Expect(httpIntentText(summary, "deterministic_summary").contains("AUTHORITATIVE-ORIGINAL-FACT"))
            @Expect(httpIntentText(summary, "deterministic_summary").contains("model-generated overview (non-authoritative):"))
            let provenance = summary.field("overview_policy").getOrThrow()
            @Expect(httpIntentText(provenance, "package_digest"), productRegistryCopyText83(f.record.getOrThrow().descriptor.copyText(PluginDescriptorText.ContentDigest)))
            @Expect(!provenance.field("authoritative").getOrThrow().asBool())
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE policy_reason='internal_context_compaction' AND lifecycle='completed'"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs r JOIN model_attempts a ON a.run_id=r.id WHERE r.state='completed' AND a.policy_reason='internal_context_compaction'"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
            @Expect(f.database.scalarInt("SELECT SUM(output_tokens) FROM run_model_usage WHERE role='compactor'"), 18)
            let model = f.product.fixtureProbe.getOrThrow().lastRequest.getOrThrow()
            @Expect(model.tools.isEmpty() && !model.parallelToolCalls)
        } finally { f.close() }
    }
    @TestCase
    func ordinaryModelFailureKeepsStructuredFactsWithActualFailedAttempt(): Unit {
        let f = CompactionPolicyFixture(failure: true)
        try {
            let before = f.originalItems()
            @Expect(lifecycleTestRequire(f.product.compactSession(f.session)) > 0)
            @Expect(f.originalItems(), before)
            let summary = f.checkpoint().field("structured_summary").getOrThrow()
            @Expect(httpIntentText(summary, "deterministic_summary").contains("FIXTURE-COMPACTION-SUMMARY-FAILURE"))
            @Expect(summary.field("overview_policy").isNone())
            @Expect(!httpIntentText(summary, "deterministic_summary").contains("model-generated overview"))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE policy_reason='internal_context_compaction'"), 1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
        } finally { f.close() }
    }
    @TestCase
    func missingSelectedPolicyFailsExplicitlyBeforeModelAndCheckpoint(): Unit {
        let f = CompactionPolicyFixture(install: false)
        try {
            let before = f.originalItems()
            let result = f.product.compactSession(f.session)
            @Expect(result.isError()); @Expect(result.error().getOrThrow().code, "policy.not_configured")
            @Expect(f.originalItems(), before); f.noExecutionOrCheckpoint()
        } finally { f.close() }
    }
    @TestCase
    func missingSettingsIsUnconfiguredButDanglingSettingsIsInvalid(): Unit {
        let root = pluginContractTemp("policy-root-boundary")
        let target = root + "/target"
        let dangling = root + "/dangling"
        // pluginContractTemp only mints a unique path; the boundary fixture must
        // create its own root before creating target or the dangling link. The
        // asserted facts are unchanged: settings is still absent, and the link
        // is still present while its target is gone.
        Directory.create(root, recursive: true)
        try {
            let missing = root + "/settings"
            Directory.create(target)
            SymbolicLink.create(dangling, to: target)
            remove(target)
            @Expect(loadProductPolicySelection(missing, "compaction").error().getOrThrow().code, "policy.not_configured")
            @Expect(!exists(Path(missing)))
            @Expect(loadProductPolicySelection(dangling, "compaction").error().getOrThrow().code, "policy.configuration_invalid")
        } finally {
            Directory.create(target)
            remove(dangling)
            remove(root, recursive: true)
        }
    }

    @TestCase
    func disabledPolicyCannotUseHostSummaryFallback(): Unit {
        let f = CompactionPolicyFixture()
        try {
            @Expect(f.product.setPluginEnabled(productRegistryCopyText83(f.record.getOrThrow().descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk())
            @Expect(f.product.compactSession(f.session).isError()); f.noExecutionOrCheckpoint()
        } finally { f.close() }
    }
    @TestCase
    func changedPackageOrPinnedDigestCannotDispatchSummaryModel(): Unit {
        for (change in ["digest", "package"]) {
            let f = CompactionPolicyFixture()
            try {
                if (change == "digest") { f.writeSelection("sha256:" + modelPolicySha256Text("wrong package")) }
                else { File.writeTo(productRegistryCopyText83(f.record.getOrThrow().descriptor.copyText(PluginDescriptorText.Root)) + "/README.md", "changed package bytes".toArray()) }
                @Expect(f.product.compactSession(f.session).isError()); f.noExecutionOrCheckpoint()
            } finally { f.close() }
        }
    }
    @TestCase
    func wholePolicyConfigurationIsFrozenAndMalformedSiblingCannotBeIgnored(): Unit {
        let f = CompactionPolicyFixture()
        try {
            let selection = lifecycleTestRequire(loadProductPolicySelection(f.root + "/settings", "compaction"))
            @Expect(selection.validateCurrent().isOk())
            let path = f.root + "/settings/plugins/policies.json"
            let prior = String.fromUtf8(File.readFrom(path))
            File.writeTo(path, (prior + "\n").toArray())
            @Expect(selection.validateCurrent().error().getOrThrow().code, "policy.configuration_changed")
            let changed = parseUnifiedJson(prior)
            changed.field("bindings").getOrThrow().put("memory", objectValue([]))
            File.writeTo(path, stringifyUnifiedJson(changed).toArray())
            @Expect(f.product.compactSession(f.session).error().getOrThrow().code, "policy.configuration_invalid")
            f.noExecutionOrCheckpoint()
        } finally { f.close() }
    }
    @TestCase
    func explicitlyStructuredCheckpointUsesInstalledPolicyWithoutAModel(): Unit {
        let f = CompactionPolicyFixture(hybrid: false)
        try {
            let before = f.originalItems()
            @Expect(lifecycleTestRequire(f.product.compactSession(f.session)) > 0)
            @Expect(f.originalItems(), before)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(f.checkpoint().field("structured_summary").getOrThrow().field("overview_policy").isNone())
            let provenance = f.checkpoint().field("structured_summary").getOrThrow().field("structured_policy").getOrThrow()
            @Expect(httpIntentText(provenance, "package_digest"), productRegistryCopyText83(f.record.getOrThrow().descriptor.copyText(PluginDescriptorText.ContentDigest)))
            @Expect(!provenance.field("authoritative").getOrThrow().asBool())
        } finally { f.close() }
    }
    @TestCase
    func cancelledTokenBeforeCanonicalAdmissionCreatesNoRunAttemptOrEffect(): Unit {
        let f = InternalModelFixture(); let source = CompactionTestCancellationSource()
        try {
            source.cancel()
            let result = f.control.executeInternal(f.request(), InternalModelCallOptions(parent: Some(f.parent),
                purpose: Some(InternalModelPurpose.ContextCompaction), cancellation: Some(source.token)))
            @Expect(result.error().getOrThrow().kind, AgentErrorKind.Cancelled)
            @Expect(f.provider.factory.count(), 0)
            @Expect(f.provider.database.scalarInt("SELECT COUNT(*) FROM runs"), 0)
            @Expect(f.provider.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
        } finally { source.close(); f.close() }
    }
    @TestCase
    func sameTokenCancelsActualInFlightMaintenanceAndJoinsItsProvider(): Unit {
        let f = InternalModelFixture(mode: "hang"); let source = CompactionTestCancellationSource()
        let pending = spawn { f.control.executeInternal(f.request(), InternalModelCallOptions(parent: Some(f.parent),
            purpose: Some(InternalModelPurpose.ContextCompaction), timeoutMillis: 10000, cancellation: Some(source.token))) }
        try {
            let deadline = MonoTime.now() + Duration.second * 10
            while (f.provider.factory.count() == 0 && pending.tryGet().isNone() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
            @Expect(f.provider.factory.count(), 1); source.cancel()
            @Expect(pending.get().isError()); @Expect(f.provider.factory.allClosed())
            @Expect(f.provider.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='cancelled'"), 1)
            @Expect(f.provider.database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE lifecycle='cancelled'"), 1)
            @Expect(f.provider.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
            @Expect(f.provider.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
        } finally { source.cancel(); let _ = pending.get(); source.close(); f.close() }
    }
    @TestCase
    func tokenCancellationBetweenClaimAndProviderOpenCannotDispatchOrRetry(): Unit {
        let f = InternalModelFixture(); let source = CompactionTestCancellationSource()
        try {
            f.provider.factory.beforeOpen = { _ => let _ = source.cancel() }
            let result = f.control.executeInternal(f.request(), InternalModelCallOptions(parent: Some(f.parent),
                purpose: Some(InternalModelPurpose.ContextCompaction), maxAttempts: 2, cancellation: Some(source.token)))
            @Expect(result.isError()); @Expect(f.provider.factory.count(), 0)
            @Expect(f.provider.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 1)
            @Expect(f.provider.database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE lifecycle='completed'"), 0)
            @Expect(f.provider.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
        } finally { source.close(); f.close() }
    }

    @TestCase
    func structuredPolicyMissingOrDisabledCannotUseRemovedHostAlgorithm(): Unit {
        for (installed in [false, true]) {
            let f = CompactionPolicyFixture(install: installed, hybrid: false)
            try {
                if (installed) { @Expect(f.product.setPluginEnabled(productRegistryCopyText83(f.record.getOrThrow().descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk()) }
                let before = f.originalItems()
                @Expect(f.product.compactSession(f.session).isError())
                @Expect(f.originalItems(), before)
                f.noExecutionOrCheckpoint()
            } finally { f.close() }
        }
    }
    @TestCase
    func structuredPolicyUsesCanonicalTodoFactsAndKeepsOriginalMessages(): Unit {
        let f = CompactionPolicyFixture(hybrid: false)
        try {
            let installedTodo=todoTestInstallNative(f.product);installedTodo.close()
            let todo=f.product.applicationSession(sessionId:Some(f.session))
            var setup=todo.replaceTodoPhases([ProductTodoPhase("Review", [
                ProductTodoItem("waiting approval", status: ProductTodoStatus.Blocked, blocker: "operator"),
                ProductTodoItem("already done", status: ProductTodoStatus.Completed)])]).value().getOrThrow()
            var reviews:Int64=0
            while(setup.approval.isSome()){
                @Expect(reviews<2)
                setup=todo.decide(setup.approval.getOrThrow().operationId.value,ApprovalDecision.Approve).value().getOrThrow()
                reviews++}
            @Expect(reviews,2)
            @Expect(todo.todoPhases().value().getOrThrow().size,1)
            let before = f.originalItems()
            @Expect(lifecycleTestRequire(f.product.compactSession(f.session)) > 0)
            let summary = f.checkpoint().field("structured_summary").getOrThrow()
            @Expect(httpIntentText(summary, "deterministic_summary").contains("Review: waiting approval [blocked: operator]"))
            @Expect(!httpIntentText(summary, "deterministic_summary").contains("already done"))
            @Expect(f.originalItems(), before)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(lifecycleTestRequire(f.product.todoPhases(f.session))[0].tasks.size, 2)
        } finally { f.close() }
    }

    @TestCase
    func actualNativeStructuredResultRemainsBoundToCallerCancellationBeforeConsumption(): Unit {
        let f = CompactionPolicyFixture(hybrid: false)
        let source = CompactionTestCancellationSource()
        let proposals = ArrayList<ProductCompactionStructure>()
        try {
            let before = f.originalItems()
            let result = lifecycleTestRequire(f.product.proposeContextSummary(f.session,
                [ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: "actual-native-summary")])],
                cancellation: Some(source.token)))
            proposals.add(result)
            @Expect(result.text.contains("actual-native-summary"))
            @Expect(result.validate().isOk())
            source.cancel()
            @Expect(result.validate().error().getOrThrow().kind, AgentErrorKind.Cancelled)
            @Expect(f.originalItems(), before)
            result.close(); result.close()
            @Expect(result.validate().error().getOrThrow().code, "compaction.result_released")
            f.noExecutionOrCheckpoint()
        } finally { for (proposal in proposals) { proposal.close() }; source.close(); f.close() }
    }

    @TestCase
    func scopeCancellationInTheGapBetweenNativeProposalAndModelStopsAdmission(): Unit {
        let policy = CompactionPolicyFixture(hybrid: false)
        let model = InternalModelFixture()
        let host = policy.host()
        let owner = InstalledCompactionSummarizer(model.control, host, policy.root + "/settings")
        let scope = owner.openScope(model.parent.sessionId)
        let proposals = ArrayList<ProductCompactionStructure>()
        try {
            lifecycleTestRequire(host.mount(policy.record.getOrThrow()))
            let proposal = lifecycleTestRequire(owner.structure(model.parent.sessionId,
                [ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: "phase-gap-fact")])],
                nullValue(), listValue([]), 5000, Some(scope.token)))
            proposals.add(proposal)
            @Expect(proposal.text.contains("phase-gap-fact")); @Expect(proposal.validate().isOk())
            lifecycleTestRequire(owner.cancel(model.parent.sessionId))
            @Expect(proposal.validate().error().getOrThrow().kind, AgentErrorKind.Cancelled)
            let denied = owner.summarize(model.parent, proposal.text, 5000, 200, Some(scope.token))
            try { @Expect(denied.isError()) } finally { closeCompactionTestOverview(denied) }
            @Expect(model.provider.factory.count(), 0)
            @Expect(model.provider.database.scalarInt("SELECT COUNT(*) FROM runs"), 0)
            @Expect(model.provider.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            scope.close(); scope.close()
            let next = owner.openScope(model.parent.sessionId)
            try {
                @Expect(next.token.check().isOk())
                let fresh = lifecycleTestRequire(owner.structure(model.parent.sessionId,
                    [ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: "fresh-owner")])],
                    nullValue(), listValue([]), 5000, Some(next.token)))
                proposals.add(fresh)
                @Expect(fresh.validate().isOk()); @Expect(fresh.text.contains("fresh-owner"))
            } finally { next.close() }
            policy.noExecutionOrCheckpoint()
        } finally { for (proposal in proposals) { proposal.close() }; scope.close(); let _ = host.close(); model.close(); policy.close() }
    }
    @TestCase
    func localRecipesStillRejectChangedConfigurationGenerationAndPackageBeforeTheNextInvocation(): Unit {
        for (change in ["configuration", "generation", "package"]) {
            let f = CompactionPolicyFixture(hybrid: false)
            let host = f.host()
            let cancellation = CompactionTestCancellationSource()
            var owned: ?ProductCompactionReferenceQuery = None
            try {
                lifecycleTestRequire(host.mount(f.record.getOrThrow()))
                let selection = lifecycleTestRequire(loadProductPolicySelection(f.root + "/settings", "compaction"))
                let binding = lifecycleTestRequire(host.policyProviderBinding(selection.namespace, selection.provider))
                let query = ProductCompactionReferenceQuery(host, selection, "local-recipe-regression", ThreadId(f.session.value),
                    cancellation.token, "local-recipe-regression", binding)
                owned = Some(query)
                let first = query.query("reference_layout", [])
                @Expect(httpIntentExactFields(first, ["arguments", "state", "event_batch"]))
                if (change == "configuration") {
                    let path = f.root + "/settings/plugins/policies.json"
                    File.writeTo(path, (String.fromUtf8(File.readFrom(path)) + "\n").toArray())
                } else if (change == "generation") {
                    lifecycleTestRequire(host.unmount(selection.namespace))
                } else {
                    File.writeTo(productRegistryCopyText83(f.record.getOrThrow().descriptor.copyText(PluginDescriptorText.Root)) + "/README.md", "changed bytes after a completed pure query".toArray())
                }
                let rejected = try { let _ = query.query("reference_layout", []); false }
                    catch (_: Exception) { true }
                @Expect(rejected)
                let finalRejected = try { query.check(); false } catch (_: Exception) { true }
                @Expect(finalRejected)
                f.noExecutionOrCheckpoint()
            } finally {
                match (owned) { case Some(value) => value.close(); case None => () }
                cancellation.close(); let _ = host.close(); f.close()
            }
        }
    }
    @TestCase
    func nativeProposalAndActualMaintenanceShareTheSameCancellableScope(): Unit {
        let policy = CompactionPolicyFixture(hybrid: false)
        let model = InternalModelFixture(mode: "hang", thinkingCapabilities: Some(ThinkingCapabilities(
            ThinkingControlMode.Effort, supportedLevels: [ThinkingLevel.Low])))
        let host = policy.host()
        let owner = InstalledCompactionSummarizer(model.control, host, policy.root + "/settings")
        let scope = owner.openScope(model.parent.sessionId)
        let proposals = ArrayList<ProductCompactionStructure>()
        try {
            lifecycleTestRequire(host.mount(policy.record.getOrThrow()))
            let proposal = lifecycleTestRequire(owner.structure(model.parent.sessionId,
                [ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: "actual-phase-chain")])],
                nullValue(), listValue([]), 5000, Some(scope.token)))
            proposals.add(proposal)
            let pending = spawn { owner.summarize(model.parent, proposal.text, 10000, 200, Some(scope.token)) }
            try {
                let deadline = MonoTime.now() + Duration.second * 10
                while (model.provider.factory.count() == 0 && pending.tryGet().isNone() && MonoTime.now() < deadline) {
                    sleep(Duration.millisecond * 5)
                }
                @Expect(model.provider.factory.count(), 1)
                lifecycleTestRequire(owner.cancel(model.parent.sessionId))
                @Expect(pending.get().isError()); @Expect(model.provider.factory.allClosed())
                @Expect(proposal.validate().error().getOrThrow().kind, AgentErrorKind.Cancelled)
                @Expect(model.provider.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='cancelled'"), 1)
                @Expect(model.provider.database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE lifecycle='cancelled'"), 1)
                @Expect(model.provider.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
                @Expect(model.provider.database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
                policy.noExecutionOrCheckpoint()
            } finally { let _ = owner.cancel(model.parent.sessionId); closeCompactionTestOverview(pending.get()) }
        } finally { for (proposal in proposals) { proposal.close() }; scope.close(); let _ = host.close(); model.close(); policy.close() }
    }

    @TestCase
    func installedPolicyCompactsHistoryBeyondOneLogicalInputWithoutDeletingItems(): Unit {
        let f = CompactionPolicyFixture(hybrid: false, seedDefaultHistory: false)
        try {
            let messages = ArrayList<ModelMessage>()
            let text = String.fromUtf8(Array<UInt8>(65536, repeat: 65))
            for (index in 0..130) {
                messages.add(ModelMessage(if (index % 2 == 0) { ModelRole.User } else { ModelRole.Assistant },
                    [ModelBlock(ModelBlockKind.Text, text: text)]))
            }
            lifecycleTestRequire(f.product.replaceMessages(f.session, messages.toArray()))
            let before = f.originalItems()
            @Expect(lifecycleTestRequire(f.product.compactSession(f.session)) > 0)
            @Expect(f.originalItems(), before)
            let summary = f.checkpoint().field("structured_summary").getOrThrow()
            @Expect(httpIntentText(summary, "deterministic_summary").contains("user: " + text[..240] + "..."))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_decisions"), 0)
        } finally { f.close() }
    }
    @TestCase
    func installedPolicyCompactsOneFiveMiBMessageThroughCanonicalCheckpoint(): Unit {
        let f = CompactionPolicyFixture(hybrid: false, seedDefaultHistory: false)
        try {
            let huge = String.fromUtf8(Array<Byte>(5 * 1024 * 1024, repeat: 65))
            let messages = ArrayList<ModelMessage>([ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: huge)])])
            for (index in 0..14) { messages.add(ModelMessage(if (index % 2 == 0) { ModelRole.Assistant } else { ModelRole.User },
                [ModelBlock(ModelBlockKind.Text, text: "recent " + index.toString())])) }
            lifecycleTestRequire(f.product.replaceMessages(f.session, messages.toArray()))
            let before = f.originalItems()
            @Expect(lifecycleTestRequire(f.product.compactSession(f.session, force: true)) > 0)
            @Expect(f.originalItems(), before)
            @Expect(httpIntentText(f.checkpoint().field("structured_summary").getOrThrow(), "deterministic_summary").contains(huge[..240] + "..."))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
        } finally { f.close() }
    }
    @TestCase
    func actualInstalledReferenceRecipesKeepOversizedPathNamesAndCurrentBinding(): Unit {
        let f = CompactionPolicyFixture(hybrid: false)
        let proposals = ArrayList<ProductCompactionStructure>()
        try {
            let path = String.fromUtf8(Array<Byte>(2300000, repeat: 112))
            let messages = [ModelMessage(ModelRole.Assistant, [ModelBlock(ModelBlockKind.ToolCall, name: "read",
                arguments: objectValue([ValueField("path", textValue(path + "a"))])),
                ModelBlock(ModelBlockKind.ToolCall, name: "edit", arguments: objectValue([ValueField("input", textValue("[" + path + "b#2]"))]))])]
            let result = lifecycleTestRequire(f.product.proposeContextSummary(f.session, messages))
            proposals.add(result)
            @Expect(result.text.size > 4194304)
            @Expect(result.text, "[Compacted session history]\nmessages: 1 (user 0, assistant 1)\ntools: read, edit\nfiles:\n- " + path + "a (Read)\n- " + path + "b (Write)")
            @Expect(result.validate().isOk())
            @Expect(f.product.setPluginEnabled(productRegistryCopyText83(f.record.getOrThrow().descriptor.copyText(PluginDescriptorText.Namespace)), false).isOk())
            @Expect(result.validate().isError())
            f.noExecutionOrCheckpoint()
        } finally { for (proposal in proposals) { proposal.close() }; f.close() }
    }

}

func closeCompactionTestOverview(result: Result<?ProductCompactionOverview>): Unit {
    match (result) { case Result.Ok(Some(value)) => value.close(); case _ => () }
}

private func canonicalCheckpointFixtureGrant173(name: String): AgentValue {
    objectValue([ValueField("name", textValue(name)), ValueField("provider", textValue("summarize")),
        ValueField("action", textValue("canonical.context.project")), ValueField("capability", textValue("workspace.read")),
        ValueField("effect", textValue("read_only"))])
}

@Test
class OptionalCompactionAdmission203Tests {
    @TestCase
    func shortHistoryNeedsNoInstalledPolicyForAutomaticOrForcedNoOp203(): Unit {
        let f = CompactionPolicyFixture(install: false, seedDefaultHistory: false)
        try {
            lifecycleTestRequire(f.product.replaceMessages(f.session, [
                ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: "hello actual first turn")]),
                ModelMessage(ModelRole.Assistant, [ModelBlock(ModelBlockKind.Text, text: "fixture response")])]))
            let before = f.originalItems()
            @Expect(lifecycleTestRequire(f.product.compactSession(f.session, force: false)), 0)
            @Expect(lifecycleTestRequire(f.product.compactSession(f.session, force: true)), 0)
            @Expect(f.originalItems(), before)
            @Expect(!exists(Path(f.root + "/settings/plugins/policies.json")))
            f.noExecutionOrCheckpoint()
        } finally { f.close() }
    }

    @TestCase
    func belowAutomaticThresholdNoOpDoesNotSuppressRequiredPolicyFailure203(): Unit {
        let f = CompactionPolicyFixture(install: false)
        try {
            let before = f.originalItems()
            @Expect(lifecycleTestRequire(f.product.compactSession(f.session, force: false)), 0)
            @Expect(f.originalItems(), before)
            f.noExecutionOrCheckpoint()
            let required = f.product.compactSession(f.session, force: true)
            @Expect(required.isError())
            @Expect(required.error().getOrThrow().code, "policy.not_configured")
            @Expect(f.originalItems(), before)
            f.noExecutionOrCheckpoint()
        } finally { f.close() }
    }
}
