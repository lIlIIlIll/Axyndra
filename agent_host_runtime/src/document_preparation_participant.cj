package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import yjson_support.*

// Trusted host composition only. The existing root context retains this same
// participant; no plugin/SDK/JS decoder can construct or obtain it. Concrete
// implementations own their actual scope/proposal/control validation and the
// inherited consume(proof). A preparation read has no participant. These two
// methods neither mint a source nor commit a canonical operation themselves.
public interface HostDocumentPreparationParticipant <: PluginDocumentCommitParticipant {
    func freeze(context: ToolInvocationContext, call: ToolCall,
        arguments: AgentValue, control: ?AgentValue): Result<Unit>
    func forCommit(context: ToolInvocationContext,
        root: PreparedToolInvocation): Result<?PluginDocumentCommitParticipant>
}

public func freezeHostDocumentPreparation(context: ToolInvocationContext, call: ToolCall,
    arguments: AgentValue, control: ?AgentValue): Result<Unit> {
    let actual = match (context.hostDocumentCommitParticipant) {
        case Some(value) => value as HostDocumentPreparationParticipant
        case None => Option<HostDocumentPreparationParticipant>.None }
    match (actual) {
        case Some(value) => value.freeze(context, call, arguments, control)
        case None => if (control.isSome()) { hostDocumentPreparationScopeError("plugin.command_user_scope_required") } else { Result.Ok(()) } }
}

public func selectHostDocumentCommitParticipant(context: ToolInvocationContext,
    root: PreparedToolInvocation): Result<?PluginDocumentCommitParticipant> {
    match (context.hostDocumentCommitParticipant) {
        case Some(value) => match (value as HostDocumentPreparationParticipant) {
            case Some(actual) => actual.forCommit(context, root)
            case None => Result.Ok(Some(value)) }
        case None => Result.Ok(Option<PluginDocumentCommitParticipant>.None) }
}

func hostDocumentPreparationScopeError<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.PermissionDenied, code,
        "plugin command requires its actual user scope, exact frozen proposal and current installed contribution"))
}
