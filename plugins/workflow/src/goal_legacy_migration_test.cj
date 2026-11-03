package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func goalLegacyMigrationFixture(): AgentValue {
    objectValue([ValueField("id",textValue("historical-goal")),ValueField("objective",textValue("preserve history")),
        ValueField("status",textValue("active")),ValueField("tokenBudget",integerValue(1000)),
        ValueField("tokensUsed",integerValue(123)),ValueField("timeUsedSeconds",integerValue(8)),
        ValueField("createdAt",integerValue(1000)),ValueField("updatedAt",integerValue(2000)),
        ValueField("enabled",boolValue(true)),ValueField("baselineTokens",integerValue(400)),
        ValueField("accountedAt",integerValue(2000))])
}
func goalLegacyMigrationInput(document: AgentValue): AgentValue {
    let encoded=stringifyUnifiedJson(document)
    // Policy-unit input is data only. It constructs no Source or Host control;
    // the public document provider separately validates actual ContextRead data.
    objectValue([ValueField("op",textValue("migrate_legacy")),ValueField("legacy_document",textValue(encoded)),
        ValueField("legacy_sha256",textValue(modelPolicySha256Text(encoded))),
        ValueField(CONTEXT_READ_INPUT_FIELD,nullValue())])
}
func goalLegacyMigrationDenied(input: AgentValue, current: String): Bool {
    try { let _=workflowGoalLegacyMigration(input,current);false }
    catch(_:PureProviderError){true}
}

@Test
class GoalLegacyMigrationTests {
    @TestCase
    func exactColdHistoryIsPreservedWithoutContinuationOrControlProposal() {
        let old=goalLegacyMigrationFixture()
        let encoded=stringifyUnifiedJson(old)
        let result=workflowGoalLegacyMigration(goalLegacyMigrationInput(old),"null")
        @Expect(canonicalAgentValue(result.field("document").getOrThrow()),canonicalAgentValue(old))
        @Expect(result.field("changed").getOrThrow().asBool())
        @Expect(!result.field("is_error").getOrThrow().asBool())
        @Expect(result.field("user_control").isNone())
        @Expect(result.field("continuation").isNone())
        @Expect(stringifyUnifiedJson(old),encoded)
    }

    @TestCase
    func existingDocumentAndMismatchedLegacyBytesCannotBeOverwritten() {
        let original=goalLegacyMigrationFixture()
        let input=goalLegacyMigrationInput(original)
        @Expect(goalLegacyMigrationDenied(input,stringifyUnifiedJson(original)))
        input.put("legacy_document",textValue("null"))
        @Expect(goalLegacyMigrationDenied(input,"null"))
        let same=goalLegacyMigrationInput(original)
        same.put("legacy_sha256",textValue("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
        @Expect(goalLegacyMigrationDenied(same,"null"))
    }

    @TestCase
    func unsupportedFormatAndMutableControlFieldsAreRejectedBeforeAnyProposal() {
        let extra=goalLegacyMigrationFixture();extra.put("formatVersion",integerValue(2))
        @Expect(goalLegacyMigrationDenied(goalLegacyMigrationInput(extra),"null"))
        let budget=goalLegacyMigrationFixture();budget.put("tokenBudget",integerValue(0))
        @Expect(goalLegacyMigrationDenied(goalLegacyMigrationInput(budget),"null"))
        let malformed=goalLegacyMigrationFixture();malformed.put("tokensUsed",textValue("123"))
        @Expect(goalLegacyMigrationDenied(goalLegacyMigrationInput(malformed),"null"))
        let forbidden=goalLegacyMigrationInput(goalLegacyMigrationFixture())
        forbidden.put("user_control",objectValue([ValueField("action",textValue("resume"))]))
        @Expect(goalLegacyMigrationDenied(forbidden,"null"))
    }
}
