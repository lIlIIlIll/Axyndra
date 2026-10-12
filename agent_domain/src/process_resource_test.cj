package agent_domain

import std.unittest.*
import std.unittest.testmacro.*

@Test
class ProcessResourceIdentityTests {
    @TestCase
    func kindsAndSubresourcesNeverAlias(): Unit {
        let first = ProcessResourceOwner.ModelAttempt(ModelAttemptId("same"), "worker")
        let second = ProcessResourceOwner.ModelAttempt(ModelAttemptId("same"), "http-1")
        @Expect(first.key != second.key)
        @Expect(first.key != ProcessResourceOwner.Operation(OperationId("same")).key)
        @Expect(first.key != ProcessResourceOwner.Operation(OperationId(first.key)).key)
        @Expect(ProcessResourceOwner.ModelAttempt(ModelAttemptId("a:b"), "c").key !=
            ProcessResourceOwner.ModelAttempt(ModelAttemptId("a"), "b:c").key)
    }
    @TestCase
    func legacyRequestCannotProduceAnOperationForModel(): Unit {
        let operation = ProcessRequest("/usr/bin/true", operationId: OperationId("legacy"))
        @Expect(operation.operationId.value == "legacy")
        let model = ProcessRequest("/usr/bin/true",
            resourceOwner: Some(ProcessResourceOwner.ModelAttempt(ModelAttemptId("real"), "worker")))
        @Expect(model.resourceOwner.operation.isNone())
        var rejected = false
        try { let _ = model.operationId } catch (_: Exception) { rejected = true }
        @Expect(rejected)
    }
    @TestCase
    func ambiguousOrUnboundedResourceIsRejected(): Unit {
        var ambiguous = false
        try { let _ = ProcessRequest("/usr/bin/true", operationId: OperationId("other"),
            resourceOwner: Some(ProcessResourceOwner.ModelAttempt(ModelAttemptId("real"), "worker"))) }
        catch (_: Exception) { ambiguous = true }
        @Expect(ambiguous)
        for (name in ["", "bad\nidentity", "bad\u{0}identity"]) {
            var rejected = false
            try { let _ = ProcessRequest("/usr/bin/true",
                resourceOwner: Some(ProcessResourceOwner.ModelAttempt(ModelAttemptId("real"), name))) }
            catch (_: Exception) { rejected = true }
            @Expect(rejected)
        }
    }

    @TestCase
    func onlyTypedModelRequestsCanDescribeAttemptOwnedZeroTimeout(): Unit {
        let model = ProcessResourceOwner.ModelAttempt(ModelAttemptId("actual-deadline"), "worker")
        let zero = ProcessRequest("/usr/bin/true", resourceOwner: Some(model), timeoutMillis: 0)
        @Expect(zero.timeoutMillis, 0)
        @Expect(zero.resourceOwner.key, model.key)
        for (owner in [ProcessResourceOwner.Operation(OperationId("ordinary")), model]) {
            for (timeout in [-1, -3600000]) {
                var rejected = false
                try { let _ = ProcessRequest("/usr/bin/true", resourceOwner: Some(owner), timeoutMillis: timeout) }
                catch (_: IllegalArgumentException) { rejected = true }
                @Expect(rejected)
            }
        }
        var defaultRejected = false
        try { let _ = ProcessRequest("/usr/bin/true", timeoutMillis: 0) }
        catch (_: IllegalArgumentException) { defaultRejected = true }
        @Expect(defaultRejected)
        var operationRejected = false
        try { let _ = ProcessRequest("/usr/bin/true", timeoutMillis: 0,
            resourceOwner: Some(ProcessResourceOwner.Operation(OperationId("explicit")))) }
        catch (_: IllegalArgumentException) { operationRejected = true }
        @Expect(operationRejected)
    }
}
