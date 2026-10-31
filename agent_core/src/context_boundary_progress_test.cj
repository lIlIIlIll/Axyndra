package agent_core

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Carrier tests only; physical restart acceptance is the separate actual
// SQLite/Core SIGKILL controller, never a synthesized Source or Receipt.
@Test
class ContextBoundaryCounterCarrierTests {
    @TestCase
    func allFourteenCountersAndUnknownCostRoundTrip(): Unit {
        let before = BudgetCounter(modelRequests: 5, workModelRequests: 3, drainModelRequests: 2,
            inputTokens: 7, outputTokens: 11, reasoningTokens: 13, cacheReadTokens: 17,
            cacheWriteTokens: 19, costMicros: None, lastInputTokens: 23, lastOutputTokens: 29,
            lastRequestDurationMillis: 31, toolCalls: 37, turns: 41)
        let encoded = coreContextBoundaryCounterValue(before)
        let restored = coreContextBoundaryCounter(encoded)
        @Expect(canonicalAgentValue(coreContextBoundaryCounterValue(restored)), canonicalAgentValue(encoded))
        @Expect(restored.costMicros.isNone())
        @Expect(restored.reasoningTokens, 13)
        @Expect(restored.cacheWriteTokens, 19)
        @Expect(restored.lastRequestDurationMillis, 31)
    }

    @TestCase
    func MismatchedSemanticTotalsAndNoncanonicalNumbersAreRejected(): Unit {
        let value = coreContextBoundaryCounterValue(BudgetCounter(modelRequests: 1, workModelRequests: 1))
        for (bad in [integerValue(2), numberValue("1.0"), integerValue(-1)]) {
            let changed = parseUnifiedJson(stringifyUnifiedJson(value), maxBytes: 8388608)
            changed.put("model_requests", bad)
            var rejected = false
            try { let _ = coreContextBoundaryCounter(changed) } catch (_: Exception) { rejected = true }
            @Expect(rejected)
        }
        let changed = parseUnifiedJson(stringifyUnifiedJson(value), maxBytes: 8388608)
        changed.put("unpaid_extra_counter", integerValue(1))
        var rejected = false
        try { let _ = coreContextBoundaryCounter(changed) } catch (_: Exception) { rejected = true }
        @Expect(rejected)
    }
}
