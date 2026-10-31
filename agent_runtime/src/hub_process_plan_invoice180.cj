package agent_runtime

import agent_domain.*
import std.io.*
import yjson.*
import yjson_support.*

// A conservative allocation invoice, not an encoded-size proof or permission.
// Callers pay the fixed scanner/control frame BEFORE constructing this object.
// It walks all original metadata; the original bank still decides admission.
public class HubProcessPlanInvoice180 {
    // Complete fixed plan/approval/replay/wire field names and framing fit
    // within 4 KiB (including all optional fixed fields). Variable graph,
    // text, collection members and fact occurrences are added below. The
    // 128 KiB scanner/control allocation belongs to retainedPeak, not to the
    // serialized extent: multiplying that scratch by 64 invented 8 MiB of
    // codec DATA before the original writer had emitted even one field.
    private var extent: Int64 = 4096
    private var entries: Int64 = 128
    private let fundScalar:(Int64)->Unit
    private var graphNodes:Int64=0
    public init(fundScalar:(Int64)->Unit) {this.fundScalar=fundScalar}
    private func text(value: String): Unit { add(value.size, 1) }
    private func add(bytes: Int64, nodes: Int64): Unit {
        if (bytes < 0 || nodes < 0 || extent > Int64.Max - bytes || entries > Int64.Max - nodes) {
            throw LogicalJsonPayloadError("complete process plan invoice overflow") }
        extent += bytes; entries += nodes
    }
    private func graph(value: AgentValue): Unit {
        graphNodes=0;borrowGraph180(value,0)
    }
    private func borrowGraph180(value:AgentValue,depth:Int64):Unit{
        graphNodes+=1
        if(depth>64 || graphNodes>65536){throw LogicalJsonPayloadError("original process plan JSON shape exceeds its bound")}
        if(value.unifiedKind==ValueKind.Text){
            if(value.text.size>(Int64.Max-2)/6){throw LogicalJsonPayloadError("process plan string invoice overflow")}
            add(value.text.size*6+2,1)
        }else if(value.unifiedKind==ValueKind.Number){
            // Only the original numeric writer is used. Scalar temporaries
            // are prepaid in this already registered same-bank phase.
            fundScalar(1048576)
            let estimate=max(40,value.asNumberText().size)
            if(estimate>(Int64.Max-1048576)/2){throw LogicalJsonPayloadError("process plan numeric invoice overflow")}
            fundScalar(1048576+estimate*2)
            let scalar=HubProcessPlanScalar180()
            value.writeJson(scalar,options:JsonWriteOptions.defaults)
            add(max(estimate,scalar.bytes),1)
        }else if(value.unifiedKind==ValueKind.Null){add(4,1)}
        else if(value.unifiedKind==ValueKind.Boolean){add(5,1)}
        else if(value.unifiedKind==ValueKind.List){
            add(2,1);let values=value.asArray()
            for(index in 0..values.size()){add(1,0);borrowGraph180(values.get(index).getOrThrow(),depth+1)}
        }else if(value.unifiedKind==ValueKind.Object){
            add(2,1);let fields=value.asObject()
            for(index in 0..fields.size()){
                graphNodes+=1;let name=fields.nameAt(index)
                if(name.size>(Int64.Max-4)/6){throw LogicalJsonPayloadError("process plan field invoice overflow")}
                add(name.size*6+4,1);borrowGraph180(fields.valueAt(index),depth+1)}
        }else{throw LogicalJsonPayloadError("unsupported original process plan value")}
    }
    public func includePlan(plan: NormalizedOperationPlan): Unit {
        text(plan.toolName); graph(plan.canonicalArguments); text(plan.cwd)
        text(plan.idempotencyKey); text(plan.bindingDigest)
        text(plan.implementation.toolId); text(plan.implementation.toolVersion)
        text(plan.implementation.implementationFingerprint); text(plan.implementation.schemaDigest)
        text(plan.implementation.effectiveArgumentsDigest)
        for (value in plan.resolvedPaths) { text(value) }
        for (value in plan.resolvedHosts) { text(value) }
        for (value in plan.requiredCapabilities) { text(value.resource); add(128, 4) }
        for (value in plan.relevantEnvironment) { text(value.name); graph(value.value) }
        for (value in plan.networkPolicy.egress) {
            text(value.host); add(128, 4)
            for (address in value.privateAddresses) { text(address) }
        }
        let ports=plan.networkPolicy.publish.size
        if(ports>Int64.Max/128){throw LogicalJsonPayloadError("process publish invoice overflow")}
        add(ports * 128, ports * 4)
        let approval = plan.approvalMetadata
        text(approval.capabilityLabel)
        for (value in approval.assessment.flags) { text(value) }
        for (value in approval.assessment.reasons) { text(value) }
        text(approval.grantScope.capability); text(approval.grantScope.pathPrefix)
        text(approval.grantScope.toolName); text(approval.grantScope.host)
        match (approval.writeSummary) { case Some(value) =>
            text(value.path); text(value.action); text(value.language); text(value.contentHash)
            for (line in value.preview) { text(line) }
            add(1024, 32)
            case None => () }
        match (plan.replayDisposition) {
            case ReplayDisposition.Idempotent(value) => text(value)
            case ReplayDisposition.RecoverByProbe(value) => text(value.value)
            case ReplayDisposition.Compensatable(value) => text(value.value)
            case _ => () }
        // Measure actual immutable field occurrences BEFORE the original
        // getter clones its array. Charge worst-case JSON escaping for those
        // bytes, plus every fixed field/schema and the existing node invoice.
        // A nonexistent 64 KiB payload per fact must not be multiplied into
        // the codec peak. No fact count, field limit or bank capacity changes.
        let facts = plan.contextReadFactCount180()
        let factBytes = plan.contextReadFactTextBytes180()
        if (facts > Int64.Max / 1024 || factBytes > (Int64.Max - facts * 1024) / 6) {
            throw LogicalJsonPayloadError("process fact invoice overflow") }
        add(facts * 1024 + factBytes * 6, facts * 128)
    }
    public func includeRequest180(request:AgentValue):Unit{graph(request)}
    public func includeRoot(value: HubProcessRootHandoff180): Unit {
        includePlan(value.plan)
        for (scalar in [value.nonce, value.parent.value, value.child.value, value.run.value,
            value.thread.value, value.sourceItem.value, value.sourceCall, value.sourceTool,
            value.brokerStartIdentity,value.currentEndpoint]) { text(scalar) }
        graph(value.configuration)
    }
    public func retainedPeak(): Int64 {
        if (extent > (Int64.Max - 131072) / 64 || entries >
            (Int64.Max - 131072 - extent * 64) / 2048) {
            throw LogicalJsonPayloadError("process complete codec SUM overflow") }
        131072 + extent * 64 + entries * 2048
    }
}
class HubProcessPlanScalar180 <: OutputStream{
    var bytes:Int64=0
    init(){}
    public func write(value:Array<Byte>):Unit{
        if(bytes>LOGICAL_JSON_HARD_BYTES-value.size){throw LogicalJsonPayloadError("original process plan scalar exceeds its bound")}
        bytes+=value.size
    }
    public func flush():Unit{()}
}
