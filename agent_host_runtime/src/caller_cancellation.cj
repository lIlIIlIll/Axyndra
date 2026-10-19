package agent_host_runtime

import agent_domain.*

public class HostCallerCancellation {
    public let token: CancellationToken
    private let source: ?CancellationSource
    private let registration: ?CancellationRegistration
    public init(runToken: CancellationToken, caller: ?CancellationToken) {
        match (caller) {
            case Some(value) =>
                let linked = CancellationSource(parent: Some(runToken), deadlineMillis: value.deadlineMillis)
                source = Some(linked); token = linked.token
                registration = Some(value.onCancel({ reason => let _ = linked.cancel(reason: Some(reason)) }))
            case None => token = runToken; source = None; registration = None
        }
    }
    public func close(): Unit {
        match (registration) { case Some(value) => value.dispose(); case None => () }
        match (source) { case Some(value) => value.close(); case None => () }
    }
}

