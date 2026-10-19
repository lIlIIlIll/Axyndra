package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import agent_domain.LogicalJsonOwnerReservation as ProcessCurrentOwner180
import std.collection.*
import std.net.*
import std.sync.*
import yjson.*
import yjson_support.*

// This endpoint is registered in an actual admission-created Host lease
// BEFORE its one-use Store ticket is issued. It lends that existing Host's
// original registry window; decoded DATA never creates a Source or grant.
class HostHubProcessCurrentBridge180 {
    private let lock=Mutex()
    private let lease:HostHubDerivedProcessLease180
    private let path:String
    private let nonce:String
    private let pid:Int64
    private let start:String
    private let producer:HostHubProcessProducerCell
    private var server:?UnixServerSocket=None<UnixServerSocket>
    private var current:?UnixSocket=None<UnixSocket>
    private var closing=false
    private var opened=false
    init(lease:HostHubDerivedProcessLease180,path:String,nonce:String,pid:Int64,start:String,
        producer:HostHubProcessProducerCell){
        this.lease=lease;this.path=path;this.nonce=nonce;this.pid=pid;this.start=start;this.producer=producer
    }
    func bindActualServer180():Unit{
        let actual=UnixServerSocket(bindAt:path)
        lock.lock();try{server=Some(actual)}finally{lock.unlock()}
        actual.backlogSize=32;actual.bind()
        lock.lock();try{opened=true}finally{lock.unlock()}
    }
    func startAfterPrivatePermissions180():Unit{producer.start({=>serveActualCurrent180()})}
    func matchesActualBinding180(nonce:String,pid:Int64,start:String):Bool{
        lock.lock();try{opened && !closing && this.nonce==nonce && this.pid==pid && this.start==start}
        finally{lock.unlock()}
    }
    func endpoint180():String{path}
    private func acceptWholeHelper180():UnixSocket{server.getOrThrow().accept()}
    private func serveActualCurrent180():Unit{
        while(true){
            lock.lock();let stop=try{closing}finally{lock.unlock()};if(stop){return}
            // Independent command custody exists before accepting, parsing or
            // allocating the original Host registry-window helper closure.
            let frame=lease.reserveControlBeforeClosure180()
            frame.fundProducerFrameBeforeEffect180(131072)
            let client=try{acceptWholeHelper180()}catch(error:Exception){
                lock.lock();let explicitClose=try{closing}finally{lock.unlock()}
                if(explicitClose){
                    // acceptWholeHelper180 has actually thrown and returned;
                    // this EXACT independent frame never received an action.
                    // Unknown accept errors and other producers are not ACKed.
                    if(!frame.retireNeverStartedAfterWholeCaller180()){
                        throw HostHubProcessHeldProducerFailure180(frame)}
                    return}
                throw error}
            lock.lock();try{current=Some(client)}finally{lock.unlock()}
            client.readTimeout=Some(Duration.second*5);client.writeTimeout=Some(Duration.second*5)
            frame.invokeSynchronousHelper180({=>serveCurrentFrameHelper180(client,frame)})
            frame.noteSynchronousHelperReturned180()
            if(frame.hasOriginalFailure180()){
                let _=frame.admitOriginalFailure180({consumer=>
                    if(!writeCurrentFailureWholeHelper180(client,consumer)){return false}
                    consumer.acknowledgeAfterConsumption().isOk()})
            }else{client.write("returned\n".toArray())}
            try{client.close()}
            catch(error:Exception){frame.retainActualCleanupFailure180(error);throw HostHubProcessHeldProducerFailure180(frame)}
            lock.lock();try{current=None<UnixSocket>}finally{lock.unlock()}
            if(!frame.retireObservedReturn()){throw HostHubProcessHeldProducerFailure180(frame)}
        }
    }
    private func serveCurrentFrameHelper180(client:UnixSocket,frame:HostHubProcessProducerCell):Unit{
        let line=readCurrentLine180(client,256,{bytes=>frame.fundProducerFrameBeforeEffect180(bytes)})
        let expected=nonce+" "+pid.toString()+" "+start
        if(line!=expected){throw OwnedCanonicalDataFailure113(AgentError(AgentErrorKind.Authentication,
            "hub.process_current_identity_changed","current window does not belong to the Store-bound Root"))}
        let window=match(lease.acquireOriginCurrentWindow180()){
            case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(value)=>value}
        // The caller's actual Source/generation window remains held across
        // only this short physical operation. It is never a process wait.
        try{
            client.write("ok\n".toArray())
            if(readCurrentLine180(client,16,{bytes=>frame.fundProducerFrameBeforeEffect180(bytes)})!="done"){
                throw IllegalStateException("actual Root window did not return its completion delimiter")}
        }finally{window.close()}
        // This entire window-owning helper returns before the outer receipt.
    }
    func closeActualServerHelper180():Unit{
        let actual:UnixServerSocket
        lock.lock();try{closing=true;actual=server.getOrThrow()}finally{lock.unlock()}
        actual.close()
    }
    func observeActualProducerReturn180():Bool{producer.collectReturned()}
    func clearAfterActualProducerReturn180():Bool{
        if(!producer.retireObservedReturn()){return false}
        lock.lock();try{
            if(current.isSome()){return false}
            server=None<UnixServerSocket>;opened=false;true
        }finally{lock.unlock()}
    }
}

// The delimiter receipt is sent only after the whole window helper returns.
// Error frames use the existing complete eight-field neutral paid encoder.
func writeCurrentFailureWholeHelper180(client:UnixSocket,consumer:OwnedFailureDataConsumer113):Bool{
    let result=CurrentFailureWriteState180()
    let loan=consumer.withError({error,fund=>
        let encoded=match(encodeOwnedFailureError113(error,fund)){
            case Result.Err(failure)=>throw OwnedCanonicalDataFailure113(failure);case Result.Ok(value)=>value}
        match(fund(encoded.size*2+2)){case Result.Err(failure)=>throw OwnedCanonicalDataFailure113(failure);case Result.Ok(_)=>()}
        client.write((encoded+"\n").toArray());result.written=true})
    loan.isOk() && result.written
}
class CurrentFailureWriteState180{var written=false;init(){}}

func readCurrentLine180(client:UnixSocket,limit:Int64,fund:(Int64)->Unit):String{
    fund(65536)
    let bytes=ArrayList<Byte>();let one=Array<Byte>(1,repeat:0)
    while(true){
        if(client.read(one)!=1){throw IllegalStateException("actual Host current window was not observed")}
        if(one[0]==b'\n'){fund(65536+bytes.size*8);return String.fromUtf8(bytes.toArray())}
        if(bytes.size>=limit){throw IllegalStateException("current control frame exceeds its existing invoice")}
        fund(65536+(bytes.size+1)*8);bytes.add(one[0])
    }
    throw IllegalStateException("current control frame loop returned without its completion delimiter")
}

// Registered in the private Root lease before any socket/codec construction.
// It uses an independent share of the same original bank; a thrown close or
// missing receipt retains the concrete frame and payment, never a false ACK.
class HostHubProcessRemoteCurrent180 {
    private let owner:ProcessCurrentOwner180
    private var socket:?UnixSocket=None<UnixSocket>
    private var peak:Int64=65536
    private var returned=false
    private var retirementFailure180:?Exception=None<Exception>
    init(owner:ProcessCurrentOwner180){this.owner=owner}
    private func fund180(bytes:Int64):Unit{
        if(bytes<0){throw IllegalStateException("current response invoice overflow")}
        owner.ensureRetainedPeak(max(peak,bytes));peak=max(peak,bytes)
    }
    func beginWholeHelper180(ticket:HubProcessRootHandoff180,
        decodeFailure:(AgentValue)->Result<AgentError>):Unit{
        fund180(65536+ticket.currentEndpoint.size+ticket.nonce.size+ticket.brokerStartIdentity.size)
        let actual=UnixSocket(ticket.currentEndpoint);socket=Some(actual)
        actual.readTimeout=Some(Duration.second*5);actual.writeTimeout=Some(Duration.second*5)
        actual.connect(timeout:Some(Duration.millisecond*500))
        actual.write((ticket.nonce+" "+ticket.brokerPid.toString()+" "+ticket.brokerStartIdentity+"\n").toArray())
        requireCurrentReceipt180(readCurrentLine180(actual,8388608,{bytes=>fund180(bytes)}),"ok",decodeFailure)
    }
    private func requireCurrentReceipt180(line:String,expected:String,
        decodeFailure:(AgentValue)->Result<AgentError>):Unit{
        if(line==expected){return}
        // Decode the actual Host's full original codec, not error.message or
        // a new grant reconstructed from the private control response.
        if(line.size>(Int64.Max-65536)/8){throw IllegalStateException("current error codec invoice overflow")}
        fund180(65536+line.size*8)
        let lexical=hostProjectionLexicalInvoice151(line)
        if(lexical.nodes>(Int64.Max-65536-line.size*8)/512 ||
            lexical.nameBytes>(Int64.Max-65536-line.size*8-lexical.nodes*512)/2){
            throw IllegalStateException("current complete error DOM invoice overflow")}
        fund180(65536+line.size*8+lexical.nodes*512+lexical.nameBytes*2)
        let value=match(decodeAgentValue(line,maxBytes:8388608)){
            case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error);case Result.Ok(value)=>value}
        match(decodeFailure(value)){case Result.Err(error)=>throw OwnedCanonicalDataFailure113(error)
            case Result.Ok(error)=>throw OwnedCanonicalDataFailure113(error)}
    }
    func closeWholeHelper180(decodeFailure:(AgentValue)->Result<AgentError>):Unit{
        let actual=socket.getOrThrow()
        actual.write("done\n".toArray())
        requireCurrentReceipt180(readCurrentLine180(actual,8388608,{bytes=>fund180(bytes)}),"returned",decodeFailure)
        actual.close()
        socket=None<UnixSocket>;returned=true
    }
    private func closeAbandonedSocketWholeHelper180():Unit{
        match(socket){case Some(actual)=>actual.close();case None=>()}
    }
    // Only the private Root request entry invokes this after its actual
    // Future/handler observation returned and every exact output/error loan
    // is retired. This retires local DATA, never the original Host's window:
    // an unknown Host close remains in that Host's registered paid custody.
    func retireAfterWholeFailedRequest180():Bool{
        if(retirementFailure180.isSome()){return false}
        try{closeAbandonedSocketWholeHelper180()}
        catch(error:Exception){retirementFailure180=Some(error);return false}
        socket=None<UnixSocket>
        try{owner.close()}
        catch(error:Exception){retirementFailure180=Some(error);return false}
        true
    }
    func retireAfterWholeHelper180():Bool{
        if(!returned || socket.isSome()){return false}
        owner.close();true
    }
}
