package agent_product

import agent_domain.*
import agent_ports.*

// The caller has installed and paid this launch owner before entry. This
// sibling preserves the original gateway/policy/operation semantics; only
// actual returned resources/errors are registered before wrapper allocation.
func acquireDirectOwnedNetworkLease180(policy:NetworkPolicy,operation:?OperationId,
    cell:DirectOwnedStartCell180):Result<?DirectNetworkLease>{
    if(!networkPolicyModeIsMediated(policy.mode)){
        cell.noteNetworkNotMediated180();return Result<?DirectNetworkLease>.Ok(None<DirectNetworkLease>)}
    let gateway:NetworkGatewayPort=LocalNetworkGatewayPort()
    cell.retainNetworkGatewayBeforeAcquire180(gateway)
    try{
        match(gateway.acquire(match(operation){case Some(value)=>value;case None=>OperationId("direct-process")},policy)){
            case Result.Err(error)=>cell.retainNetworkAcquireError180(error);Result<?DirectNetworkLease>.Err(error)
            case Result.Ok(lease)=>
                cell.retainActualNetworkLease180(lease)
                Result<?DirectNetworkLease>.Ok(Some(DirectNetworkLease(gateway,lease)))}
    }catch(error:Exception){cell.retainUnknownNetworkAcquire180(error);throw error}
}
