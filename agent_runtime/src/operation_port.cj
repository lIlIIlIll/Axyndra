package agent_runtime

import std.collection.*
import std.sync.*
import agent_domain.*

public interface OperationRuntimePort {
    // Read-only verification of an already admitted, handed-off exact child.
    // This method does not start a Run or construct a live child owner.
    func verifyPluginChildExecution111(source: OperationRootSource, parent: OperationId,
        child: OperationId, run: RunId, thread: ThreadId, epoch: Int64,
        plan: NormalizedOperationPlan): Result<Unit> {
        Result.Err(AgentError(AgentErrorKind.PermissionDenied, "child.execution_port_unavailable",
            "this operation port cannot prove exact child-start execution"))
    }

    // Returns only the completed launch fact selected by this exact, currently
    // handed-off wait intent. It neither restores a child owner nor starts it.
    func pluginChildStartReceipt111(source: OperationRootSource, parent: OperationId,
        child: OperationId, run: RunId, thread: ThreadId, epoch: Int64,
        plan: NormalizedOperationPlan): Result<VNextOperationReceipt> {
        Result.Err(AgentError(AgentErrorKind.PermissionDenied, "child.wait_port_unavailable",
            "this operation port cannot prove the exact completed launch"))
    }

    func reserveManagedJobLaunch(source: OperationRootSource, operationId: OperationId, runId: RunId,
        threadId: ThreadId, epoch: Int64, plan: NormalizedOperationPlan): Result<ManagedJobLaunchBinding> {
        managedJobDenied("task.managed_job_store_unsupported")
    }
    func claimManagedJobLaunch(binding: ManagedJobLaunchBinding): Result<Unit> {
        managedJobDenied("task.managed_job_store_unsupported")
    }
    func verifyManagedJobLaunch(binding: ManagedJobLaunchBinding): Result<Unit> {
        managedJobDenied("task.managed_job_store_unsupported")
    }
    func verifyManagedJobPlan(binding: ManagedJobLaunchBinding, plan: NormalizedOperationPlan): Result<Unit> {
        managedJobDenied("task.managed_job_store_unsupported")
    }

    // Read-only proof of the original waiting Operation. This cannot approve,
    // execute or mint a recovered source; unsupported ports fail closed.
    func verifyContextReadApprovalPending(source: DirectToolCallRef, plan: NormalizedOperationPlan): Result<Unit> {
        Result.Err(AgentError(AgentErrorKind.PermissionDenied, "context.read_approval_unsupported",
            "this Operation port cannot verify a retained pending context read"))
    }

    func verifyContextReadExecuting(source: DirectToolCallRef, plan: NormalizedOperationPlan): Result<Unit> {
        Result.Err(AgentError(AgentErrorKind.PermissionDenied, "context.read_execution_unsupported",
            "this Operation port cannot verify actual resource-read execution"))
    }

    // Metadata only; the read below still requires its private ContextRead source.
    func pluginDocumentLane(thread: ThreadId, run: RunId, epoch: Int64): Result<LaneId> {
        Result.Err(AgentError(AgentErrorKind.PermissionDenied, "plugin.document_lane_unsupported", "canonical document lane is unavailable"))
    }
    func readPluginDocumentJournalStream(source:DirectToolCallRef,plan:NormalizedOperationPlan,
        guard:()->Result<Unit>,materializer:PluginDocumentPayloadMaterializer):Result<AgentValue>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.document_journal_stream_unavailable",
            "actual opt-in journal stream read port is unavailable"))
    }

    func readPluginDocumentLatestJournalStream(source:DirectToolCallRef,plan:NormalizedOperationPlan,
        guard:()->Result<Unit>,materializer:PluginDocumentPayloadMaterializer):Result<AgentValue>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.document_journal_stream_unavailable",
            "actual opt-in journal stream read port is unavailable"))
    }

    func readPluginDocumentWindows(source:DirectToolCallRef,plan:NormalizedOperationPlan,
        guard:()->Result<Unit>,materializer:PluginDocumentPayloadMaterializer):Result<AgentValue>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.document_windows_unavailable","actual opt-in window read port is unavailable"))
    }

    func readPluginDocuments(source: DirectToolCallRef, plan: NormalizedOperationPlan,
        guard: () -> Result<Unit>, observer: ?PluginDocumentReadObserver,
        materializer: ?PluginDocumentPayloadMaterializer): Result<AgentValue> {
        if (materializer.isSome() || httpIntentText(plan.canonicalArguments, "schema") == PLUGIN_DOCUMENT_PAYLOAD_READ_SCHEMA) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "plugin.document_payload_port_unavailable",
                "this operation port does not implement canonical document payload materialization")) }
        readPluginDocuments(source, plan, guard, observer)
    }

    func readPluginDocuments(source: DirectToolCallRef, plan: NormalizedOperationPlan,
        guard: () -> Result<Unit>): Result<AgentValue> {
        Result.Err(AgentError(AgentErrorKind.PermissionDenied, "plugin.document_read_unsupported", "canonical document read is unavailable"))
    }

    func readPluginDocuments(source: DirectToolCallRef, plan: NormalizedOperationPlan,
        guard: () -> Result<Unit>, observer: ?PluginDocumentReadObserver): Result<AgentValue> {
        if (observer.isSome()) { return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
            "plugin.document_observation_unsupported", "this Operation port cannot bind canonical read observations")) }
        readPluginDocuments(source, plan, guard)
    }

    // History inspection does not mint a live read source or replay a read.
    func loadContextReadFact(operationId: OperationId, runId: RunId): Result<ContextReadFact> {
        Result.Err(AgentError(AgentErrorKind.PermissionDenied, "context.read_facts_unsupported",
            "this Operation port cannot verify canonical context read facts"))
    }

    func prepare(
        operationId: OperationId,
        runId: RunId,
        toolCall: CommittedToolCallRef,
        plan: NormalizedOperationPlan
    ): Result<Unit>
    // This records a pending canonical ToolCall's rejection while its actual
    // Run is cancelling. It is never an execution admission; legacy ports
    // must explicitly implement the durable no-handoff proof.
    func prepareCancellationSettlement(operationId: OperationId, runId: RunId,
        toolCall: CommittedToolCallRef, expectedEpoch: Int64): Result<NormalizedOperationPlan> {
        Result.Err(AgentError(AgentErrorKind.PermissionDenied, "operation.cancellation_settlement_unsupported",
            "this Operation port cannot persist cancellation-only settlement"))
    }
    func prepareTrustedControlOperation(
        operationId: OperationId,
        runId: RunId,
        toolCallItemId: ItemId,
        plan: NormalizedOperationPlan
    ): Result<Unit>
    // Legacy ports do not implicitly gain ingress authority. Implementations
    // must explicitly support the sealed source and its durable origin chain.
    func prepareDirectOperation(source: DirectToolCallRef, plan: NormalizedOperationPlan): Result<Unit> {
        match (source.origin) {
            case DirectCallOrigin.ManagedJob(_) => managedJobDenied("operation.managed_job_source_unsupported")
            case DirectCallOrigin.ContextRead(_) => contextReadDenied("operation.context_read_source_unsupported")
            case DirectCallOrigin.External(_) => Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                "operation.external_source_unsupported", "this Operation port cannot admit an External source"))
            case _ => prepareTrustedControlOperation(source.operationId, source.runId, source.canonicalItemId, plan)
        }
    }
    // Settlement-only: closes a canonical UserDirect call whose preparation
    // failed before any plan, approval or executor was admitted.
    func prepareDirectRejection(source: DirectToolCallRef): Result<NormalizedOperationPlan> {
        Result.Err(AgentError(AgentErrorKind.PermissionDenied, "operation.direct_rejection_unsupported",
            "this port cannot prove an unexecuted Direct preparation rejection"))
    }
    func prepareDerivedOperation(
        operationId: OperationId,
        parentOperationId: OperationId,
        runId: RunId,
        rootToolCall: CommittedToolCallRef,
        requestKey: String,
        plan: NormalizedOperationPlan
    ): Result<OperationId>
    func prepareDerivedOperation(
        operationId: OperationId,
        parentOperationId: OperationId,
        runId: RunId,
        rootSource: OperationRootSource,
        requestKey: String,
        plan: NormalizedOperationPlan
    ): Result<OperationId> {
        match (rootSource) {
            case OperationRootSource.Committed(value) => prepareDerivedOperation(
                operationId, parentOperationId, runId, value, requestKey, plan
            )
            case OperationRootSource.Direct(_) => Result.Err(AgentError(
                AgentErrorKind.PermissionDenied, "operation.direct_source_unsupported",
                "this Operation runtime cannot verify a direct root source"
            ))
        }
    }
    // Called with the actual host-prepared child call, not the transport key.
    // This is provenance, not permission to admit another nesting level.
    func prepareDerivedInvocation(operationId: OperationId, parentOperationId: OperationId,
        runId: RunId, rootSource: OperationRootSource, requestKey: String,
        call: ToolCall, plan: NormalizedOperationPlan): Result<OperationId> {
        Result.Err(AgentError(AgentErrorKind.PermissionDenied, "operation.derived_identity_unsupported",
            "this Operation port cannot preserve the actual derived call identity"))
    }
    // Routing only. It cannot recover a Source, Prepared invocation or debt.
    // A Store with no opt-in family cannot ever execute the new descriptor.
    func requiresOwnedPluginLivePolicyApprovalOwner(operation:OperationId,run:RunId):Result<Bool>{Result.Ok(false)}

    func preparePluginLivePolicyParent(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        plan:NormalizedOperationPlan,approval:?ApprovalRequest,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.live_parent_prepare_unavailable","Store has no paid live parent preparation"))}
    // Independent live-family ports. Defaults are closed until the Store
    // implements the complete paid Source/prefix/terminal proof. They never
    // delegate into ordinary derived admission or generic approval methods.
    func recordPluginLivePolicyChildApproval(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:ApprovalRequest,approvalId:String,ceiling:CapabilitySet,approved:Bool,
        source:String,expires:?Int64,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.live_child_approval_unavailable",
            "Store has no complete independent exact live child approval"))}
    func recordPluginLivePolicyChildApprovalWithRejectionError(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:ApprovalRequest,approvalId:String,ceiling:CapabilitySet,approved:Bool,
        source:String,expires:?Int64,guard:()->Result<Unit>,rejectionError:?AgentError):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.live_child_approval_unavailable",
            "Store has no complete independent exact live child approval"))}
    func markPluginLivePolicyChildExecuting(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,nowMillis:Int64,approvalRequired:Bool,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.live_child_execution_unavailable",
            "Store has no complete independent exact live child execution"))}
    func markPluginLivePolicyChildHandoff(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,nowMillis:Int64,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.live_child_handoff_unavailable",
            "Store has no complete independent exact live child handoff"))}
    func verifyPluginLivePolicyChildTerminal(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,result:ToolResult,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.live_child_terminal_unavailable",
            "Store has no actual known child Receipt and complete same-parent causal witness"))}
    // Closed until the actual Store implements the entire paid native-abort
    // canonical Receipt/prefix proof. Caller-visible isError is never proof.
    func verifyPluginLivePolicyChildTerminalNativeAbort340(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,result:ToolResult,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.live_native_abort_terminal_unavailable",
            "Store has no complete actual native-abort child Receipt witness"))}
    func verifyPluginLivePolicyParentTerminal(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,
        epoch:Int64,plan:NormalizedOperationPlan,result:ToolResult,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.live_parent_terminal_unavailable",
            "Store has no exclusive actual known-ledger parent finalization witness"))}

    // Opt-in physical owner callback. Ordinary Completed/default ports stay
    // closed; no decoded descriptor or boolean is a completion authority.
    // Closed by default. The Product's actual Store performs the complete
    // same-TX live effect proof, original CAS and genuine reserved settlement.
    func settlePluginLivePolicyJournalNativeAbortChild328(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,guard:()->Result<Unit>,
        committer:PluginDocumentPayloadCommitter,loan:LogicalJsonOwnerReservation,loanPeak:Int64,
        consumeTip:(AgentValue)->Unit):PluginLivePolicyJournalSettlementProgress326{
        PluginLivePolicyJournalSettlementProgress326(Result<Unit>.Err(AgentError(AgentErrorKind.PermissionDenied,
            "operation.live_native_abort_settlement_unavailable","actual native-abort settlement requires its independent paid Store implementation")))
    }
    func settlePluginLivePolicyJournalNativeAbortChild334(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,guard:()->Result<Unit>,
        committer:PluginDocumentPayloadCommitter,loan:LogicalJsonOwnerReservation,loanPeak:Int64,
        consumeTip:(AgentValue)->Unit,frame:PluginLivePolicyOuterErrorFrame334):PluginLivePolicyJournalSettlementProgress326{
        PluginLivePolicyJournalSettlementProgress326(Result<Unit>.Err(AgentError(AgentErrorKind.PermissionDenied,
            "operation.live_native_abort_settlement_unavailable","actual native-abort settlement requires its independent paid Store implementation")))
    }

    func settlePluginLivePolicyJournalChild307(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,guard:()->Result<Unit>,
        committer:PluginDocumentPayloadCommitter,consumeTip:(AgentValue)->Unit):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"operation.live_journal_settlement_unavailable",
            "actual live journal settlement requires its independent Store implementation"))
    }

    func verifyPluginLivePolicyOwnedParentTerminal(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,
        epoch:Int64,plan:NormalizedOperationPlan,expected:?ApprovalRequest,result:ToolResult,
        dataOwner:OperationTerminalDataOwner,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.live_owned_terminal_unavailable",
            "Store has no actual same-owner terminal proof"))}

    func recordPluginLivePolicyParentApproval(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        plan:NormalizedOperationPlan,expected:ApprovalRequest,approvalId:String,ceiling:CapabilitySet,approved:Bool,
        source:String,expires:?Int64,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.live_parent_approval_unavailable","Store has no independent exact live parent approval"))}
    func markPluginLivePolicyParentExecuting(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        plan:NormalizedOperationPlan,nowMillis:Int64,approvalRequired:Bool,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.live_parent_execution_unavailable","Store has no paid live parent execution"))}
    func markPluginLivePolicyParentHandoff(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        plan:NormalizedOperationPlan,nowMillis:Int64,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.live_parent_handoff_unavailable","Store has no exact live parent handoff"))}

    // New default-closed precise preparation. No effect handoff or approval
    // is minted by a parent ceiling or Native receipt-prefix description.
    func preparePluginLivePolicyInvocation(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,call:ToolCall,approval:?ApprovalRequest,guard:()->Result<Unit>):Result<OperationId>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.live_prepare_unavailable",
            "this Store does not implement exact independent live child preparation"))
    }

    // Read-only proof for this NEW default-closed live family. The concrete
    // Store must verify the actual canonical parent Source/handoff/current
    // lane/epoch and exact pending child/approval/prior durable ledger in one
    // paid transaction. A descriptor or a caller-supplied Bool is insufficient.
    func verifyPluginLivePolicyPending(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,childCallId:String,approval:ApprovalRequest,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.live_pending_proof_unavailable",
            "this Store cannot prove the same actual live parent and prepared child"))
    }

    // Separate default-closed ordinary-policy managed channel family.
    func prepareManagedChannelOwnedParent(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        plan:NormalizedOperationPlan,approval:?ApprovalRequest,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"managed_channel.parent_prepare_unavailable","Store has no paid live parent preparation"))}
    func recordManagedChannelOwnedParentApproval(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        plan:NormalizedOperationPlan,expected:ApprovalRequest,approvalId:String,ceiling:CapabilitySet,approved:Bool,
        source:String,expires:?Int64,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"managed_channel.parent_approval_unavailable","Store has no independent exact live parent approval"))}
    func markManagedChannelOwnedParentExecuting(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        plan:NormalizedOperationPlan,nowMillis:Int64,approvalRequired:Bool,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"managed_channel.parent_execution_unavailable","Store has no paid live parent execution"))}
    func markManagedChannelOwnedParentHandoff(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        plan:NormalizedOperationPlan,nowMillis:Int64,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"managed_channel.parent_handoff_unavailable","Store has no exact live parent handoff"))}
    func recordManagedChannelOwnedChildApproval(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:ApprovalRequest,approvalId:String,ceiling:CapabilitySet,approved:Bool,
        source:String,expires:?Int64,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"managed_channel.child_approval_unavailable",
            "Store has no complete independent exact live child approval"))}
    func recordManagedChannelOwnedChildApprovalWithRejectionError(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:ApprovalRequest,approvalId:String,ceiling:CapabilitySet,approved:Bool,
        source:String,expires:?Int64,guard:()->Result<Unit>,rejectionError:?AgentError):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"managed_channel.child_approval_unavailable",
            "Store has no complete independent exact live child approval"))}
    func markManagedChannelOwnedChildExecuting(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,nowMillis:Int64,approvalRequired:Bool,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"managed_channel.child_execution_unavailable",
            "Store has no complete independent exact live child execution"))}
    func markManagedChannelOwnedChildHandoff(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,nowMillis:Int64,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"managed_channel.child_handoff_unavailable",
            "Store has no complete independent exact live child handoff"))}
    func prepareManagedChannelOwnedInvocation(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,call:ToolCall,approval:?ApprovalRequest,guard:()->Result<Unit>):Result<OperationId>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"managed_channel.prepare_unavailable",
            "this Store does not implement exact independent live child preparation"))
    }
    func verifyManagedChannelOwnedPending(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,childCallId:String,approval:ApprovalRequest,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"managed_channel.pending_proof_unavailable",
            "this Store cannot prove the same actual live parent and prepared child"))
    }
    func verifyManagedChannelOwnedChildTerminal(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,result:ToolResult,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"managed_channel.child_terminal_unavailable",
            "Store has no actual known child Receipt and complete same-parent causal witness"))}
    func verifyManagedChannelOwnedParentTerminal(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,
        epoch:Int64,plan:NormalizedOperationPlan,result:ToolResult,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"managed_channel.parent_terminal_unavailable",
            "Store has no exclusive actual known-ledger parent finalization witness"))}
    func settleManagedChannelOwnedChild(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,receipt:VNextOperationReceipt,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"managed_channel.settlement_unavailable","Store cannot settle an actual managed child"))}
    func recordManagedChannelOwnedStop(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        plan:NormalizedOperationPlan,call:ToolCall,requestKey:String,reason:String,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"managed_channel.stop_unavailable","Store cannot prove actual policy preparation stopped without handoff"))}
    func requiresOwnedManagedChannelApprovalOwner(operation:OperationId,run:RunId):Result<Bool>{Result.Ok(false)}
    func verifyManagedChannelOwnedEffectExecuting(root:OperationRootSource,parent:OperationId,child:OperationId,
        run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
        requestKey:String,callId:String,expected:?ApprovalRequest,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"managed_channel.effect_unavailable","Store cannot prove this actual executing child"))}
    func verifyManagedChannelOwnedResource(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        parentPlan:NormalizedOperationPlan,binding:AgentValue,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"managed_channel.resource_unavailable","Store cannot prove this actual active resource"))}

    // Only the actual invocation-private terminal carrier and fixed-file
    // owner can enter this path. An ordinary Completed DTO stays closed.
    func verifyManagedChannelOwnedActualParentTerminal(root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,
        epoch:Int64,plan:NormalizedOperationPlan,expected:?ApprovalRequest,result:ToolResult,
        dataOwner:OperationTerminalDataOwner,guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"managed_channel.actual_terminal_unavailable",
            "Store cannot verify the actual retained managed protocol terminal"))}

    func waitForApproval(operationId: OperationId, runId: RunId): Result<Unit>
    func recordApproval(
        approvalId: String,
        operationId: OperationId,
        runId: RunId,
        reviewedPlan: NormalizedOperationPlan,
        capabilityCeiling: CapabilitySet,
        approved: Bool,
        source: String,
        expiresAtMillis: ?Int64
    ): Result<Unit>
    func markExecuting(
        operationId: OperationId,
        runId: RunId,
        executionPlan: NormalizedOperationPlan,
        nowMillis: Int64,
        approvalRequired: Bool
    ): Result<Unit>
    func markExecutionHandoff(
        operationId: OperationId,
        runId: RunId,
        threadId: ThreadId,
        observedAtMillis: Int64
    ): Result<Unit>
    func markExecutingWithSource(source: ?OperationRootSource, operationId: OperationId, runId: RunId,
        executionPlan: NormalizedOperationPlan, nowMillis: Int64, approvalRequired: Bool): Result<Unit> {
        match (rejectUnsupportedExternalOperationSource(source)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        markExecuting(operationId, runId, executionPlan, nowMillis, approvalRequired)
    }
    func markExecutionHandoffWithSource(source: ?OperationRootSource, operationId: OperationId,
        runId: RunId, threadId: ThreadId, observedAtMillis: Int64): Result<Unit> {
        match (rejectUnsupportedExternalOperationSource(source)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        markExecutionHandoff(operationId, runId, threadId, observedAtMillis)
    }
    // Trusted read-only provenance lookup. An observed owner is not an
    // execution grant and must not mint a recovered invocation source.
    func operationRunId(operationId: OperationId): Result<RunId> {
        let _ = operationId
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
            "operation.owner_unsupported", "this Operation runtime cannot inspect canonical Run ownership"))
    }
    func loadPlan(operationId: OperationId, runId: RunId): Result<NormalizedOperationPlan>
    func loadCall(operationId: OperationId, runId: RunId): Result<ToolCall>
    func loadCommittedToolResult(
        operationId: OperationId,
        runId: RunId
    ): Result<?ToolResult>
    // The trusted host supplies a current invocation guard. A serialized
    // plan is insufficient to commit a plugin document. Implementations must
    // run it before the CAS and after Receipt/state writes in the same Tx.
    func settlePluginRowJournalOperation(runId:RunId,parentOperationId:OperationId,receipt:VNextOperationReceipt,
        guard:()->Result<Unit>):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.row_journal_settle_unavailable","actual row journal settlement unavailable"))}
    func settlePluginRowJournalOperation(runId:RunId,parentOperationId:OperationId,receipt:VNextOperationReceipt,
        guard:()->Result<Unit>,participant:?PluginDocumentCommitParticipant,committer:PluginDocumentPayloadCommitter):Result<Unit>{
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,"plugin.row_journal_settle_unavailable","actual row journal append settlement unavailable"))}

    func settlePluginDocumentOperation(runId: RunId, parentOperationId: OperationId,
        receipt: VNextOperationReceipt, guard: () -> Result<Unit>): Result<Unit> {
        let _ = runId; let _ = parentOperationId; let _ = receipt; let _ = guard
        Result.Err(AgentError(AgentErrorKind.PermissionDenied,
            "plugin.document_commit_unsupported", "document settlement requires the supplied transaction guard"))
    }
    func settleDerivedOperation(
        runId: RunId,
        parentOperationId: OperationId,
        receipt: VNextOperationReceipt
    ): Result<Unit> {
        let _ = runId
        let _ = parentOperationId
        let _ = receipt
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "operation.derived_settlement_unavailable",
            "the Operation runtime cannot persist derived receipts"
        ))
    }
    func settlePluginDocumentOperation(runId: RunId, parentOperationId: OperationId,
        receipt: VNextOperationReceipt, guard: () -> Result<Unit>, participant: PluginDocumentCommitParticipant): Result<Unit> {
        Result.Err(AgentError(AgentErrorKind.PermissionDenied, "plugin.document_participant_unsupported",
            "this Operation port cannot consume a host control participant in the canonical document transaction"))
    }
    // Reference-bearing replacement needs its actual Host content reader in
    // addition to the live guard and optional user-control participant. The
    // default port cannot consume it or treat a descriptor as content proof.
    func settlePluginDocumentOperation(runId: RunId, parentOperationId: OperationId,
        receipt: VNextOperationReceipt, guard: () -> Result<Unit>,
        participant: ?PluginDocumentCommitParticipant, committer: PluginDocumentPayloadCommitter): Result<Unit> {
        Result.Err(AgentError(AgentErrorKind.PermissionDenied, "plugin.document_payload_commit_unsupported",
            "this Operation port cannot consume the retained document payload in its canonical transaction"))
    }
    func loadDerivedOperationReceipt(
        operationId: OperationId,
        runId: RunId
    ): Result<?VNextOperationReceipt> {
        let _ = operationId
        let _ = runId
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "operation.derived_receipt_unavailable",
            "the Operation runtime cannot load derived receipts"
        ))
    }
    func loadDerivedOperationState(
        operationId: OperationId,
        runId: RunId
    ): Result<String> {
        let _ = operationId
        let _ = runId
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "operation.derived_state_unavailable",
            "the Operation runtime cannot inspect derived handoff state"
        ))
    }
}
class MemoryOperationPlanEntry {
    let operationId: OperationId
    let runId: RunId
    let plan: NormalizedOperationPlan
    var call: ?ToolCall
    var toolCallItemId: ?ItemId
    let rootToolCall: ?CommittedToolCallRef
    let parentOperationId: ?OperationId
    let requestKey: ?String
    let callSequence: Int64
    let boundDerivedCall: Bool
    var handoffCommitted: Bool = false
    var state: String = "prepared"

    init(
        operationId: OperationId,
        runId: RunId,
        plan: NormalizedOperationPlan,
        call!: ?ToolCall = None,
        toolCallItemId!: ?ItemId = None,
        rootToolCall!: ?CommittedToolCallRef = None,
        parentOperationId!: ?OperationId = None,
        requestKey!: ?String = None,
        callSequence!: Int64 = 0,
        boundDerivedCall!: Bool = false
    ) {
        this.operationId = operationId
        this.runId = runId
        this.plan = plan
        this.call = call
        this.toolCallItemId = toolCallItemId
        this.rootToolCall = rootToolCall
        this.parentOperationId = parentOperationId
        this.requestKey = requestKey
        this.callSequence = callSequence
        this.boundDerivedCall = boundDerivedCall
    }
}

class MemoryCommittedToolResultEntry {
    let operationId: OperationId
    let runId: RunId
    var result: ToolResult

    init(operationId: OperationId, runId: RunId, result: ToolResult) {
        this.operationId = operationId
        this.runId = runId
        this.result = result
    }
}

class MemoryDerivedOperationReceiptEntry {
    let operationId: OperationId
    let runId: RunId
    let parentOperationId: OperationId
    let receipt: VNextOperationReceipt

    init(
        operationId: OperationId,
        runId: RunId,
        parentOperationId: OperationId,
        receipt: VNextOperationReceipt
    ) {
        this.operationId = operationId
        this.runId = runId
        this.parentOperationId = parentOperationId
        this.receipt = receipt
    }
}

public class InMemoryOperationRuntimePort <: OperationRuntimePort {
    private let lock = Mutex()
    public var executions: Int64 = 0
    private let executedOperationIds = ArrayList<String>()
    private let committedResults = ArrayList<MemoryCommittedToolResultEntry>()
    private let derivedReceipts = ArrayList<MemoryDerivedOperationReceiptEntry>()
    // Test and diagnostics surface: counts canonical prepared Operations.
    public func preparedOperationCount(): Int64 {
        lock.lock()
        try { entries.size }
        finally { lock.unlock() }
    }
    private let entries = ArrayList<MemoryOperationPlanEntry>()

    public init() {}

    public func prepare(
        operationId: OperationId,
        runId: RunId,
        toolCall: CommittedToolCallRef,
        plan: NormalizedOperationPlan
    ): Result<Unit> {
        if (!plan.contextReadFacts.isEmpty()) { return contextReadUnsupportedFacts() }
        lock.lock()
        try {
            for (entry in entries where entry.operationId.value == operationId.value) {
                if (entry.runId.value == runId.value &&
                    entry.plan.bindingDigest == plan.bindingDigest) {
                    return Result.Ok(())
                }
                return operationPortConflict(
                    "operation.prepare_conflict", "Operation already has another plan"
                )
            }
            entries.add(MemoryOperationPlanEntry(
                operationId,
                runId,
                plan,
                call: Some(ToolCall(
                    toolCall.block.callId,
                    plan.toolName,
                    plan.canonicalArguments
                )),
                toolCallItemId: Some(toolCall.canonicalItemId),
                rootToolCall: Some(toolCall)
            ))
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }
    public func prepareTrustedControlOperation(
        operationId: OperationId,
        runId: RunId,
        toolCallItemId: ItemId,
        plan: NormalizedOperationPlan
    ): Result<Unit> {
        if (!plan.contextReadFacts.isEmpty()) { return contextReadUnsupportedFacts() }
        lock.lock()
        try {
            for (entry in entries where entry.operationId.value == operationId.value) {
                if (entry.runId.value == runId.value &&
                    entry.plan.bindingDigest == plan.bindingDigest) {
                    match (entry.toolCallItemId) {
                        case Some(value) =>
                            if (value.value != toolCallItemId.value) {
                                return operationPortConflict(
                                    "operation.tool_call_item_conflict",
                                    "Operation is bound to another canonical ToolCall Item"
                                )
                            }
                        case None =>
                            entry.toolCallItemId = Some(toolCallItemId)
                            entry.call = Some(ToolCall(
                                operationId.value,
                                plan.toolName,
                                plan.canonicalArguments
                            ))
                    }
                    return Result.Ok(())
                }
                return operationPortConflict(
                    "operation.prepare_conflict", "Operation already has another plan"
                )
            }
            entries.add(MemoryOperationPlanEntry(
                operationId,
                runId,
                plan,
                call: Some(ToolCall(
                    operationId.value,
                    plan.toolName,
                    plan.canonicalArguments
                )),
                toolCallItemId: Some(toolCallItemId)
            ))
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    public func prepareDerivedOperation(
        operationId: OperationId,
        parentOperationId: OperationId,
        runId: RunId,
        rootToolCall: CommittedToolCallRef,
        requestKey: String,
        plan: NormalizedOperationPlan
    ): Result<OperationId> {
        prepareDerivedInvocationLocked(operationId, parentOperationId, runId,
            rootToolCall, requestKey, plan, None)
    }

    public func prepareDerivedInvocation(operationId: OperationId, parentOperationId: OperationId,
        runId: RunId, rootSource: OperationRootSource, requestKey: String,
        call: ToolCall, plan: NormalizedOperationPlan): Result<OperationId> {
        match (validateDerivedInvocationCall(call, plan)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let source = match (rootSource) {
            case OperationRootSource.Committed(value) => value
            case _ => return operationPortConflict("operation.direct_source_unsupported",
                "this in-memory port cannot verify a direct root source") }
        prepareDerivedInvocationLocked(operationId, parentOperationId, runId, source,
            requestKey, plan, Some(call))
    }

    private func prepareDerivedInvocationLocked(operationId: OperationId, parentOperationId: OperationId,
        runId: RunId, rootToolCall: CommittedToolCallRef, requestKey: String,
        plan: NormalizedOperationPlan, boundCall: ?ToolCall): Result<OperationId> {
        if (requestKey.trimAscii() == "" || operationId.value == parentOperationId.value ||
            rootToolCall.block.name != "run_program" || plan.toolName == "run_program" || !plan.contextReadFacts.isEmpty() ||
            plan.effectClass != OperationEffectClass.ReadOnly) {
            return operationPortConflict(
                "operation.derived_admission_invalid",
                "derived Operation admission is invalid"
            )
        }
        lock.lock()
        try {
            var activeRoot = false
            for (entry in entries where
                entry.operationId.value == parentOperationId.value &&
                entry.runId.value == runId.value) {
                let topLevel = match (entry.parentOperationId) {
                    case Some(_) => false
                    case None => true
                }
                match (entry.rootToolCall) {
                    case Some(source) =>
                        if (topLevel && entry.handoffCommitted &&
                            entry.plan.toolName == "run_program" &&
                            source.decisionId.value == rootToolCall.decisionId.value &&
                            source.scopedToolCallId.value == rootToolCall.scopedToolCallId.value &&
                            source.canonicalItemId.value == rootToolCall.canonicalItemId.value) {
                            activeRoot = true
                        }
                    case None => ()
                }
            }
            if (!activeRoot) {
                return operationPortConflict(
                    "operation.derived_parent_invalid",
                    "derived Operation parent is not an active committed run_program root"
                )
            }
            for (entry in entries) {
                let sameParent = match (entry.parentOperationId) {
                    case Some(parent) => parent.value == parentOperationId.value
                    case None => false
                }
                let sameKey = match (entry.requestKey) {
                    case Some(value) => value == requestKey
                    case None => false
                }
                if (sameParent && boundCall.isSome() && entry.boundDerivedCall &&
                    entry.call.getOrThrow().callId == boundCall.getOrThrow().callId && !sameKey) {
                    return operationPortConflict("operation.derived_call_conflict",
                        "the actual derived call identity already belongs to another request")
                }
                if (sameParent && sameKey) {
                    if (entry.boundDerivedCall != boundCall.isSome() ||
                        (boundCall.isSome() && (entry.call.getOrThrow().callId != boundCall.getOrThrow().callId ||
                            canonicalAgentValue(entry.call.getOrThrow().arguments) != canonicalAgentValue(boundCall.getOrThrow().arguments)))) {
                        return operationPortConflict("operation.derived_call_conflict",
                            "derived replay must retain the actual admitted child call")
                    }
                    if (entry.runId.value == runId.value &&
                        entry.toolCallItemId.getOrThrow().value == rootToolCall.canonicalItemId.value &&
                        entry.plan.bindingDigest == plan.bindingDigest) {
                        return Result.Ok(entry.operationId)
                    }
                    return operationPortConflict(
                        "operation.derived_request_conflict",
                        "derived request key is already bound to another plan"
                    )
                }
                if (entry.operationId.value == operationId.value) {
                    return operationPortConflict(
                        "operation.derived_identity_conflict",
                        "derived Operation ID is already in use"
                    )
                }
            }
            var nextSequence: Int64 = 1
            for (entry in entries) {
                match (entry.parentOperationId) {
                    case Some(parent) =>
                        if (parent.value == parentOperationId.value &&
                            entry.callSequence >= nextSequence) {
                            nextSequence = entry.callSequence + 1
                        }
                    case None => ()
                }
            }
            entries.add(MemoryOperationPlanEntry(
                operationId,
                runId,
                plan,
                call: Some(ToolCall(match (boundCall) { case Some(value) => value.callId; case None => requestKey },
                    plan.toolName, plan.canonicalArguments)),
                toolCallItemId: Some(rootToolCall.canonicalItemId),
                parentOperationId: Some(parentOperationId),
                requestKey: Some(requestKey),
                callSequence: nextSequence,
                boundDerivedCall: boundCall.isSome()
            ))
            Result.Ok(operationId)
        } finally {
            lock.unlock()
        }
    }

    public func waitForApproval(operationId: OperationId, runId: RunId): Result<Unit> {
        require(operationId, runId)
    }

    public func recordApproval(
        approvalId: String,
        operationId: OperationId,
        runId: RunId,
        reviewedPlan: NormalizedOperationPlan,
        capabilityCeiling: CapabilitySet,
        approved: Bool,
        source: String,
        expiresAtMillis: ?Int64
    ): Result<Unit> {
        let _ = approvalId
        let _ = capabilityCeiling.values
        let _ = approved
        let _ = source
        let _ = expiresAtMillis
        match (loadPlan(operationId, runId)) {
            case Result.Ok(plan) => if (plan.bindingDigest == reviewedPlan.bindingDigest) {
                Result.Ok(())
            } else {
                operationPortConflict(
                    "operation.approval_plan_drift", "approved Operation plan changed"
                )
            }
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func markExecuting(
        operationId: OperationId,
        runId: RunId,
        executionPlan: NormalizedOperationPlan,
        nowMillis: Int64,
        approvalRequired: Bool
    ): Result<Unit> {
        match (loadPlan(operationId, runId)) {
            case Result.Ok(plan) => if (plan.bindingDigest == executionPlan.bindingDigest) {
                lock.lock()
                try {
                    var seen = false
                    for (value in executedOperationIds where value == operationId.value) {
                        let _ = value
                        seen = true
                        break
                    }
                    if (!seen) {
                        executedOperationIds.add(operationId.value)
                        executions += 1
                    }
                    for (entry in entries where entry.operationId.value == operationId.value &&
                        entry.runId.value == runId.value) {
                        entry.state = "executing"
                    }
                    Result.Ok(())
                } finally {
                    lock.unlock()
                }
            } else {
                operationPortConflict(
                    "operation.execution_plan_drift", "executed Operation plan changed"
                )
            }
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func markExecutionHandoff(
        operationId: OperationId,
        runId: RunId,
        threadId: ThreadId,
        observedAtMillis: Int64
    ): Result<Unit> {
        let _ = threadId.value
        let _ = observedAtMillis
        lock.lock()
        try {
            var isExecuting = false
            for (executedId in executedOperationIds where executedId == operationId.value) {
                isExecuting = true
            }
            if (!isExecuting) {
                return operationPortConflict(
                    "operation.handoff_without_execution",
                    "Operation cannot hand off before execution preparation"
                )
            }
            for (entry in entries where entry.operationId.value == operationId.value) {
                if (entry.runId.value != runId.value) {
                    return operationPortConflict(
                        "operation.handoff_run_mismatch",
                        "Operation belongs to another Run"
                    )
                }
                entry.handoffCommitted = true
                return Result.Ok(())
            }
            operationPortConflict("operation.not_found", "Operation plan was not prepared")
        } finally {
            lock.unlock()
        }
    }
    public func recordCommittedToolResult(
        operationId: OperationId,
        runId: RunId,
        result: ToolResult
    ): Result<Unit> {
        match (loadPlan(operationId, runId)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        lock.lock()
        try {
            for (entry in committedResults where
                entry.operationId.value == operationId.value &&
                entry.runId.value == runId.value) {
                entry.result = result
                return Result.Ok(())
            }
            committedResults.add(MemoryCommittedToolResultEntry(operationId, runId, result))
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    public func loadCommittedToolResult(
        operationId: OperationId,
        runId: RunId
    ): Result<?ToolResult> {
        lock.lock()
        try {
            for (entry in committedResults where
                entry.operationId.value == operationId.value && entry.runId.value == runId.value) {
                return Result.Ok(Some(entry.result))
            }
            Result.Ok(None)
        } finally {
            lock.unlock()
        }
    }
    public func settleDerivedOperation(
        runId: RunId,
        parentOperationId: OperationId,
        receipt: VNextOperationReceipt
    ): Result<Unit> {
        lock.lock()
        try {
            var child: ?MemoryOperationPlanEntry = None
            var parentActive = false
            for (entry in entries) {
                if (entry.operationId.value == receipt.operationId.value &&
                    entry.runId.value == runId.value) {
                    match (entry.parentOperationId) {
                        case Some(parent) => if (parent.value == parentOperationId.value) {
                            child = Some(entry)
                        }
                        case None => ()
                    }
                }
                if (entry.operationId.value == parentOperationId.value &&
                    entry.runId.value == runId.value && entry.state == "executing") {
                    parentActive = true
                }
            }
            let selected = match (child) {
                case Some(value) => value
                case None => return operationPortConflict(
                    "operation.derived_settlement_owner_invalid",
                    "derived receipt does not belong to this parent Operation"
                )
            }
            for (existing in derivedReceipts where
                existing.operationId.value == receipt.operationId.value &&
                existing.runId.value == runId.value) {
                if (existing.parentOperationId.value == parentOperationId.value &&
                    existing.receipt.receiptId == receipt.receiptId &&
                    existing.receipt.outcome == receipt.outcome &&
                    canonicalAgentValue(existing.receipt.detail) == canonicalAgentValue(receipt.detail) &&
                    canonicalAgentValue(existing.receipt.verification) == canonicalAgentValue(receipt.verification)) {
                    return Result.Ok(())
                }
                return operationPortConflict(
                    "operation.derived_receipt_conflict",
                    "derived Operation already has another Receipt"
                )
            }
            if (!parentActive || !selected.handoffCommitted ||
                selected.state != "executing" || receipt.operationId.value != selected.operationId.value) {
                return operationPortConflict(
                    "operation.derived_settlement_state_invalid",
                    "derived Operation did not reach a live execution handoff"
                )
            }
            if (selected.plan.toolName == HOST_PLUGIN_DOCUMENT_TOOL && receipt.outcome == OperationOutcome.Completed) {
                return operationPortConflict("plugin.document_commit_unsupported", "memory Operation runtime cannot commit durable documents")
            }
            selected.state = match (receipt.outcome) {
                case OperationOutcome.Completed => "committed"
                case OperationOutcome.Rejected => "rejected"
                case OperationOutcome.Cancelled => "cancelled"
                case OperationOutcome.TimedOut => "timed_out"
                case OperationOutcome.Failed => "failed"
                case OperationOutcome.Unknown => "recovery_required"
            }
            derivedReceipts.add(MemoryDerivedOperationReceiptEntry(
                selected.operationId, runId, parentOperationId, receipt
            ))
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    public func loadDerivedOperationReceipt(
        operationId: OperationId,
        runId: RunId
    ): Result<?VNextOperationReceipt> {
        lock.lock()
        try {
            for (entry in derivedReceipts where
                entry.operationId.value == operationId.value) {
                if (entry.runId.value == runId.value) {
                    return Result.Ok(Some(entry.receipt))
                }
                return operationPortConflict(
                    "tool.approval_run_mismatch",
                    "derived Receipt belongs to another Run"
                )
            }
            Result.Ok(None)
        } finally {
            lock.unlock()
        }
    }


    public func loadDerivedOperationState(
        operationId: OperationId,
        runId: RunId
    ): Result<String> {
        lock.lock()
        try {
            for (entry in entries where entry.operationId.value == operationId.value) {
                if (entry.runId.value != runId.value) {
                    return operationPortConflict(
                        "tool.approval_run_mismatch",
                        "derived Operation belongs to another Run"
                    )
                }
                if (entry.parentOperationId.isNone()) {
                    return operationPortConflict(
                        "operation.not_derived",
                        "Operation is not a derived child"
                    )
                }
                return Result.Ok(entry.state)
            }
            operationPortConflict(
                "operation.not_found",
                "derived Operation was not prepared"
            )
        } finally {
            lock.unlock()
        }
    }

    public func operationRunId(operationId: OperationId): Result<RunId> {
        lock.lock()
        try {
            var owner: ?RunId = None
            for (entry in entries where entry.operationId.value == operationId.value) {
                if (owner.isSome()) {
                    return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                        "operation.owner_ambiguous", "Operation has more than one canonical owner"))
                }
                owner = Some(entry.runId)
            }
            match (owner) {
                case Some(value) => Result.Ok(value)
                case None => Result.Err(AgentError(AgentErrorKind.InvalidInput,
                    "operation.not_found", "Operation owner was not found"))
            }
        } finally { lock.unlock() }
    }

    public func loadPlan(
        operationId: OperationId,
        runId: RunId
    ): Result<NormalizedOperationPlan> {
        lock.lock()
        var foundOperation = false
        try {
            for (entry in entries where entry.operationId.value == operationId.value) {
                foundOperation = true
                if (entry.runId.value == runId.value) {
                    return Result.Ok(entry.plan)
                }
            }
            operationPortConflict(
                if (foundOperation) { "tool.approval_run_mismatch" } else { "operation.not_found" },
                if (foundOperation) {
                    "Operation belongs to another Run"
                } else {
                    "Operation plan was not prepared"
                }
            )
        } finally {
            lock.unlock()
        }
    }
    public func loadCall(
        operationId: OperationId,
        runId: RunId
    ): Result<ToolCall> {
        lock.lock()
        var foundOperation = false
        try {
            for (entry in entries where entry.operationId.value == operationId.value) {
                foundOperation = true
                if (entry.runId.value != runId.value) {
                    continue
                }
                match (entry.call) {
                    case Some(value) => return Result.Ok(value)
                    case None => return operationPortConflict(
                        "operation.call_not_found",
                        "canonical ToolCall is not available for this Operation"
                    )
                }
            }
            operationPortConflict(
                if (foundOperation) { "tool.approval_run_mismatch" } else { "operation.not_found" },
                if (foundOperation) {
                    "Operation belongs to another Run"
                } else {
                    "Operation plan was not prepared"
                }
            )
        } finally {
            lock.unlock()
        }
    }

    private func require(operationId: OperationId, runId: RunId): Result<Unit> {
        match (loadPlan(operationId, runId)) {
            case Result.Ok(_) => Result.Ok(())
            case Result.Err(error) => Result.Err(error)
        }
    }
}

func operationPortConflict<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Conflict, code, message))
}

func contextReadUnsupportedFacts(): Result<Unit> {
    Result.Err(AgentError(AgentErrorKind.PermissionDenied, "operation.context_read_facts_unsupported",
        "this Operation port cannot verify canonical context read facts"))
}
