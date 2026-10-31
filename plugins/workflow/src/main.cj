package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*

main(): Int64 {
    let payload = WorkflowDocumentData()
    try { runDocumentPolicyProvider("workflow", "1.0.0", ["propose", "prepare_document", "prepare_child"], workflowPrimitiveTools111(), ["todo", "goal", "plan_review"],
        { name, input => if(name=="prepare_child"){workflowChildPolicy111(name,input)}else if((name == "prepare_document" || name == "propose") &&
            httpIntentText(input,"schema") == WORKFLOW_DOCUMENT_QUERY) {
            payload.query(input)
        } else { workflowDocumentPolicy(name, input) } }, { name, input => if (name == "task" || workflowHubContribution196(name) || name == "yield") { workflowChildPrepare111(name,input) } else if (name == "plan_write") { workflowPlanPrepare(input) } else { workflowDocumentPrepare(name, input) } },
        { name, input, broker => if (name == "plan_write") { workflowPlanExecute(input) } else { workflowDocumentExecute(name, input, broker) } },
        { name, input => workflowDocumentCommand(name, input) }, contextProviders: ["goal_context"],
        views: ["plan_review"], viewHandler: Some({ name, query => workflowPlanReviewView(name, query) }),
        primitiveTools: ["task", "hub", "yield", "hub_peers", "hub_messages", "hub_jobs", "hub_cancel", "hub_process", "hub_process_read"], primitiveExecute: Some({ name, input, broker => workflowChildExecute111(name,input,broker) }),
        contextHandler: Some({ name, input =>
            if(name!="goal_context"){throw PureProviderError("workflow.context_unknown","no exact document context implementation")}
            workflowGoalContext(input) })) } finally { payload.close() }
}
