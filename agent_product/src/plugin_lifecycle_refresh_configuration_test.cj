package agent_product

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class PluginLifecycleRefreshConfigurationTests {
    @TestCase
    func optionalRefreshIsExplicitBoundedImmutableAndSubjectToHostCeiling(): Unit {
        let fixture = LifecycleConfigurationFixture()
        try {
            fixture.write(fixture.document())
            let missing = lifecycleTestRequire(fixture.bind(lifecycleTestRequire(fixture.load())))
            @Expect(missing.launchPlan.field("refresh").getOrThrow().unifiedKind, ValueKind.Null)
            let service = fixture.service()
            let refresh = objectValue([ValueField("timeout_ms", integerValue(2000)),
                ValueField("max_input_bytes", integerValue(2048)), ValueField("max_output_bytes", integerValue(8192)),
                ValueField("max_writes", integerValue(8))])
            service.put("refresh", refresh)
            fixture.write(fixture.document(service: Some(service)))
            let config = lifecycleTestRequire(fixture.load())
            let granted = lifecycleTestRequire(fixture.bind(config))
            let digest = granted.digest
            @Expect(lifecycleInt(granted.launchPlan.field("refresh").getOrThrow(), "max_writes", 256), 8)
            let view = granted.launchPlan
            view.field("refresh").getOrThrow().put("max_writes", integerValue(100))
            @Expect(granted.digest, digest)
            @Expect(lifecycleInt(granted.launchPlan.field("refresh").getOrThrow(), "max_writes", 256), 8)
            @Expect(fixture.bind(config, limits: ExecutionResourceLimits(maxOutputBytes: 4096)).isError())
            for ((key, value) in [("timeout_ms", 0), ("timeout_ms", 10001), ("max_input_bytes", 8193),
                ("max_output_bytes", 1048577), ("max_writes", 0), ("max_writes", 257)]) {
                let invalid = parseUnifiedJson(stringifyUnifiedJson(service))
                invalid.field("refresh").getOrThrow().put(key, integerValue(value))
                fixture.write(fixture.document(service: Some(invalid)))
                @Expect(fixture.load().isError())
            }
            let invalid = parseUnifiedJson(stringifyUnifiedJson(service))
            invalid.field("refresh").getOrThrow().put("credential_refs", listValue([]))
            fixture.write(fixture.document(service: Some(invalid)))
            @Expect(fixture.load().isError())
            @Expect(granted.stillCurrent().isError())
        } finally { fixture.close() }
    }
}
