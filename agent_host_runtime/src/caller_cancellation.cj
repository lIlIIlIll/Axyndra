package agent_host_runtime

import agent_domain.*

public class HostCallerCancellation {
    public let token: CancellationToken
    private let source: ?CancellationSource
    private let registration: ?CancellationRegistration
    private let frontendRegistration180: ?CancellationRegistration
    public init(runToken: CancellationToken, caller: ?CancellationToken,
        frontendCancellation180!: ?CancellationToken = None<CancellationToken>) {
        if (caller.isNone() && frontendCancellation180.isNone()) {
            token = runToken; source = None; registration = None; frontendRegistration180 = None
        } else {
            var deadline: Int64 = 0
            match (caller) { case Some(value) => deadline = value.deadlineMillis; case None => () }
            match (frontendCancellation180) { case Some(value) =>
                if (value.deadlineMillis > 0 && (deadline == 0 || value.deadlineMillis < deadline)) { deadline = value.deadlineMillis }
                case None => () }
            let linked = CancellationSource(parent: Some(runToken), deadlineMillis: deadline)
            source = Some(linked); token = linked.token
            registration = match (caller) { case Some(value) => Some(value.onCancel({ reason => let _ = linked.cancel(reason: Some(reason)) })); case None => None }
            frontendRegistration180 = match (frontendCancellation180) { case Some(value) => Some(value.onCancel({ reason => let _ = linked.cancel(reason: Some(reason)) })); case None => None }
        }
    }
    public func close(): Unit {
        match (registration) { case Some(value) => value.dispose(); case None => () }
        match (frontendRegistration180) { case Some(value) => value.dispose(); case None => () }
        match (source) { case Some(value) => value.close(); case None => () }
    }
}

