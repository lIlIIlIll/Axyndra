package approval_reviewer_contract

import yjson_support.*

import yjson.*

import agent_core.*
import agent_domain.*
import agent_ports.*
import agent_product.*
import std.collection.*
import std.sync.*

main(): Int64 {
    let port = ConcurrentApprovalPort()
    let reviewer = ApprovalReviewer(
        port,
        ProductApprovalSettings(
            mode: ApprovalRoutingMode.Ai,
            failurePolicy: ApprovalFailurePolicy.Deny,
            timeoutMillis: 2000,
            askOnNetwork: false,
            askOnOutsideWorkspaceWrite: false,
            askOnDestructiveCommands: false
        ),
        "fixture",
        "/workspace"
    )
    let runA = runRequest("run-a", "session-a")
    let runB = runRequest("run-b", "session-b")
    let futureA = spawn { reviewer.review(runA, approval("operation-a", runA.sessionId)) }
    let futureB = spawn { reviewer.review(runB, approval("operation-b", runB.sessionId)) }
    var waited: Int64 = 0
    while (port.activeCount() < 2 && waited < 1000) {
        sleep(Duration.millisecond * 10)
        waited += 10
    }
    expect(port.activeCount() == 2, "both approval requests reached the model port")
    match (reviewer.cancel()) {
        case Result.Err(error) => expect(
            error.code == "approval.cancel_key_required",
            "legacy cancellation fails closed when more than one review is active"
        )
        case _ => throw IllegalStateException("legacy cancellation selected an arbitrary concurrent review")
    }
    expect(reviewer.cancel(runA.runId).isOk(), "keyed cancellation accepts the target run")
    port.releaseSuccessfulRequests()
    let reviewA = futureA.get()
    let reviewB = futureB.get()
    expect(
        reviewA.decision == ApprovalReviewDecision.Deny &&
            reviewB.decision == ApprovalReviewDecision.Approve &&
            port.cancelledRequest().contains("run-a") &&
            !port.cancelledRequest().contains("run-b"),
        "cancelling run A cannot cancel or clear run B"
    )
    println("approval_reviewer contract passed")
    0
}

func runRequest(runId: String, sessionId: String): AgentRunRequest {
    AgentRunRequest(
        RunId(runId),
        SessionId(sessionId),
        "fixture",
        "review a safe read",
        capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])
    )
}

func approval(operationId: String, sessionId: SessionId): ApprovalRequest {
    ApprovalRequest(
        OperationId(operationId),
        "call-" + operationId,
        "read",
        Capability(CapabilityKind.WorkspaceRead),
        preview: objectValue([ValueField("path", textValue("README.md"))]),
        sessionId: sessionId.value,
        argumentHash: "hash-" + operationId
    )
}

class ConcurrentApprovalPort <: ModelPort {
    private let lock = Mutex()
    private let active = ArrayList<String>()
    private var cancelled = ""
    private var released = false

    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        let _ = events
        match (request.cachePolicy) {
            case ModelCachePolicy.StablePrefix => return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "model.capability_unsupported",
                "review fixture does not support prompt caching",
                fields: [ErrorField("feature", "prompt_cache")]
            ))
            case ModelCachePolicy.Default => ()
        }
        lock.lock()
        try {
            active.add(request.requestId)
        } finally {
            lock.unlock()
        }
        while (true) {
            lock.lock()
            let state = try {
                (cancelled == request.requestId, released)
            } finally {
                lock.unlock()
            }
            if (state[0]) {
                return Result.Err(
                    AgentError(
                        AgentErrorKind.Cancelled,
                        "fixture.cancelled",
                        "approval request was cancelled"
                    )
                )
            }
            if (state[1]) {
                return Result.Ok(
                    ModelReply(
                        [ModelBlock(
                            ModelBlockKind.Text,
                            text: "{\"decision\":\"approve\",\"reason\":\"safe read\",\"riskLevel\":\"low\",\"approvedCapabilities\":[\"workspace.read\"]}"
                        )],
                        stopReason: "end_turn"
                    )
                )
            }
            sleep(Duration.millisecond * 5)
        }
        Result.Err(AgentError(AgentErrorKind.Internal, "fixture.unreachable", "unreachable approval fixture"))
    }

    public func cancel(requestId: String): Result<Unit> {
        lock.lock()
        try {
            cancelled = requestId
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    func activeCount(): Int64 {
        lock.lock()
        try {
            active.size
        } finally {
            lock.unlock()
        }
    }

    func cancelledRequest(): String {
        lock.lock()
        try {
            cancelled
        } finally {
            lock.unlock()
        }
    }

    func releaseSuccessfulRequests(): Unit {
        lock.lock()
        try {
            released = true
        } finally {
            lock.unlock()
        }
    }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) {
        throw IllegalStateException("contract failed: ${message}")
    }
}
