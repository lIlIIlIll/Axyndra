package agent_runtime

import agent_domain.*

// These values are DATA. Constructing/deserializing one grants nothing. The
// actual Store must issue it from the still-current original Derived Source,
// then atomically claim its nonce once for the authenticated physical Root.
public class HubProcessRootHandoff180 {
    public let nonce: String
    public let parent: OperationId
    public let child: OperationId
    public let run: RunId
    public let thread: ThreadId
    public let epoch: Int64
    public let sourceItem: ItemId
    public let sourceCall: String
    public let sourceTool: String
    public let brokerPid: Int64
    public let brokerStartIdentity: String
    public let plan: NormalizedOperationPlan
    public let configuration: AgentValue
    public let currentEndpoint:String
    public init(nonce: String, parent: OperationId, child: OperationId, run: RunId,
        thread: ThreadId, epoch: Int64, sourceItem: ItemId, sourceCall: String,
        sourceTool: String, brokerPid: Int64, brokerStartIdentity: String,
        plan: NormalizedOperationPlan, configuration: AgentValue,currentEndpoint:String) {
        if (nonce.size != 64 || brokerPid <= 0 || brokerStartIdentity == "" || epoch <= 0 || currentEndpoint=="") {
            throw IllegalArgumentException("actual process Root handoff is incomplete") }
        this.nonce = nonce; this.parent = parent; this.child = child; this.run = run
        this.thread = thread; this.epoch = epoch; this.sourceItem = sourceItem
        this.sourceCall = sourceCall; this.sourceTool = sourceTool
        this.brokerPid = brokerPid; this.brokerStartIdentity = brokerStartIdentity
        this.plan = plan; this.configuration = configuration;this.currentEndpoint=currentEndpoint
    }
}

public interface HubDerivedProcessRootPort180 {
    func issueHubProcessRootHandoff180(source: OperationRootSource,
        value: HubProcessRootHandoff180): Result<Unit>
    func claimHubProcessRootHandoff180(value: HubProcessRootHandoff180): Result<Unit>
    func verifyHubProcessRootHandoff180(value: HubProcessRootHandoff180): Result<Unit>
    // The transaction encloses ONLY the actual short physical effect. It must
    // return before stream pumps, readiness, process waits or Future joins.
    func withHubProcessRootEffect180(value: HubProcessRootHandoff180,
        action: () -> Result<Unit>): Result<Unit>
    func revokeHubProcessRootHandoff180(value: HubProcessRootHandoff180): Result<Unit>
}
