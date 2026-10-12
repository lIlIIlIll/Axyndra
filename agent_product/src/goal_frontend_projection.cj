package agent_product

import agent_domain.*
import std.convert.*
import yjson.*
import yjson_support.*

// Immutable UI data from the one canonical plugin document repository.
// No presentation field can create, approve, resume or admit a Run. Current
// execution accounting and continuation authority stay with actual Host owners.
public class ProductGoalState {
    public let id: String
    public let objective: String
    public let status: String
    public let tokenBudget: ?Int64
    public let tokensUsed: Int64
    public let timeUsedSeconds: Int64
    public let createdAt: Int64
    public let updatedAt: Int64
    public let enabled: Bool
    public let documentDigest: String
    public let namespace: String
    public let packageDigest: String
    init(value: AgentValue, digest: String, selection: ProductGoalSelection) {
        // This is schema decoding only. There is no business-state transition,
        // refresh, budget arithmetic, permission or metadata write here.
        if(!httpIntentExactFields(value,["id","objective","status","tokenBudget","tokensUsed",
            "timeUsedSeconds","createdAt","updatedAt","enabled","baselineTokens","accountedAt"])){
            throw IllegalArgumentException("unsupported canonical goal presentation schema")}
        id=productGoalPresentationText(value,"id");objective=productGoalPresentationText(value,"objective")
        status=productGoalPresentationText(value,"status")
        let budget=value.field("tokenBudget").getOrThrow()
        tokenBudget=if(budget.unifiedKind==ValueKind.Null){None}else{Some(productGoalPresentationInteger(value,"tokenBudget"))}
        tokensUsed=productGoalPresentationInteger(value,"tokensUsed")
        timeUsedSeconds=productGoalPresentationInteger(value,"timeUsedSeconds")
        createdAt=productGoalPresentationInteger(value,"createdAt");updatedAt=productGoalPresentationInteger(value,"updatedAt")
        let flag=value.field("enabled").getOrThrow()
        if(flag.unifiedKind!=ValueKind.Boolean){throw IllegalArgumentException("invalid presentation boolean")}
        enabled=flag.asBool();documentDigest=digest;namespace=selection.namespace;packageDigest=selection.packageDigest
        let _=productGoalPresentationInteger(value,"baselineTokens")
        let _=productGoalPresentationInteger(value,"accountedAt")
    }
}

func productGoalPresentationText(value: AgentValue, name: String): String {
    let field=value.field(name).getOrThrow()
    if(field.unifiedKind!=ValueKind.Text){throw IllegalArgumentException("invalid presentation text")}
    field.text
}
func productGoalPresentationInteger(value: AgentValue, name: String): Int64 {
    let field=value.field(name).getOrThrow()
    if(field.unifiedKind!=ValueKind.Number){throw IllegalArgumentException("invalid presentation integer")}
    let parsed=Int64.parse(field.asNumberText())
    if(parsed<0 || parsed.toString()!=field.asNumberText()){throw IllegalArgumentException("invalid presentation integer")}
    parsed
}
