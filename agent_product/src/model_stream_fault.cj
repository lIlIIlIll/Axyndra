package agent_product

import agent_domain.*
import agent_ports.*
import std.collection.*
import std.sync.*

// An explicit, deterministic transport-boundary fault used by controlled
// mechanism experiments. It changes the environment seen by ModelPort, never
// model-visible input or AgentCore recovery decisions.
public class ModelStreamFaultProfile {
    public let id: String
    public let triggerAttemptOrdinal: Int64
    public let partialText: String
    public let faultDelayMillis: Int64

    public init(
        id: String,
        triggerAttemptOrdinal!: Int64 = 1,
        partialText!: String = "controlled incomplete stream",
        faultDelayMillis!: Int64 = 50
    ) {
        if (id.trimAscii() == "" || triggerAttemptOrdinal < 1 || partialText == "" ||
            faultDelayMillis < 1) {
            throw IllegalArgumentException("model stream fault profile is invalid")
        }
        this.id = id.trimAscii()
        this.triggerAttemptOrdinal = triggerAttemptOrdinal
        this.partialText = partialText
        this.faultDelayMillis = faultDelayMillis
    }
}

public class FaultInjectingModelPort <: ModelPort {
    private let inner: ModelPort
    private let profile: ModelStreamFaultProfile
    private let lock = Mutex()
    private let cancelled = ArrayList<String>()
    private let observedRequests = ArrayList<ModelRequest>()
    private var ordinal: Int64 = 0
    private var injected: Int64 = 0

    public init(inner: ModelPort, profile: ModelStreamFaultProfile) {
        this.inner = inner
        this.profile = profile
    }

    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        lock.lock()
        let current = try {
            ordinal += 1
            observedRequests.add(request)
            ordinal
        } finally { lock.unlock() }
        if (current != profile.triggerAttemptOrdinal) {
            return inner.execute(request, events)
        }
        lock.lock()
        try { injected += 1 } finally { lock.unlock() }
        events(ModelEvent.ProviderProgress(
            ProviderStreamEvent.ControlledFaultInjected(profile.id, current)
        ))
        events(ModelEvent.TextDelta(profile.partialText))
        var waited: Int64 = 0
        while (!wasCancelled(request.requestId) && waited < profile.faultDelayMillis) {
            sleep(Duration.millisecond)
            waited += 1
        }
        if (wasCancelled(request.requestId)) {
            return Result.Err(AgentError(
                AgentErrorKind.Cancelled,
                "model.controlled_fault_cancelled",
                "controlled incomplete stream was cancelled",
                attemptFailure: Some(AttemptFailure(AttemptFailureKind.UserCancelled))
            ))
        }
        Result.Err(AgentError(
            AgentErrorKind.Timeout,
            "model.stream_idle_timeout",
            "controlled stream became incomplete at the deterministic fault boundary",
            retryable: true,
            fields: [ErrorField("fault_profile_id", profile.id)],
            attemptFailure: Some(AttemptFailure(
                AttemptFailureKind.StreamIdleTimeout,
                diagnostics: AttemptFailureDiagnostics(
                    elapsedMillis: profile.faultDelayMillis,
                    lastProgressKind: AttemptProgressKind.TextProgress,
                    lastProgressAgeMillis: profile.faultDelayMillis
                )
            ))
        ))
    }

    public func cancel(requestId: String): Result<Unit> {
        lock.lock()
        try {
            if (!contains(cancelled, requestId)) { cancelled.add(requestId) }
        } finally { lock.unlock() }
        inner.cancel(requestId)
    }

    public func requests(): Array<ModelRequest> {
        lock.lock()
        try { observedRequests.toArray() } finally { lock.unlock() }
    }

    public func faultCount(): Int64 {
        lock.lock()
        try { injected } finally { lock.unlock() }
    }

    private func wasCancelled(requestId: String): Bool {
        lock.lock()
        try { contains(cancelled, requestId) } finally { lock.unlock() }
    }
}

func contains(values: ArrayList<String>, target: String): Bool {
    for (value in values where value == target) { return true }
    false
}
