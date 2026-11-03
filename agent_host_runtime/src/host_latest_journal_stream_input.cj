package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import agent_store.*
import std.sync.*
import stdx.crypto.digest.SHA256

// Adopt this inert owner in the actual Session before read(). Its path is
// selected only by the actual ArtifactStore and a private Store input proof.
// No constructor opens an fd or accepts a worker-selected filename/grant.
public class HostLatestJournalStreamInputReader {
    private let invoke:(HostLatestJournalStreamInputReader)->Result<Unit>
    private let path:(String)->String
    private let localCurrent:()->Result<Unit>
    private let consume:(Int64,Array<Byte>)->Result<Unit>
    private let end:(Int64)->Result<Bool>
    private let lock=Mutex()
    private var input:?HostVerifiedArtifactInput=None
    private var fixed:?LogicalJsonFixedBufferReservation=None
    private var overlap:?LogicalJsonFixedBufferReservation=None
    private var started=false
    private var inRead=false
    private var completed=false
    private var closed=false
    init(invoke:(HostLatestJournalStreamInputReader)->Result<Unit>,path:(String)->String,
        current:()->Result<Unit>,consume:(Int64,Array<Byte>)->Result<Unit>,end:(Int64)->Result<Bool>){
        this.invoke=invoke;this.path=path;this.localCurrent=current;this.consume=consume;this.end=end}
    private func cleanup():Result<Unit>{
        match(input){case Some(actual)=>match(actual.close()){
            case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>input=None};case None=>()}
        // FD ACK precedes both real buffer releases. A failed close preserves
        // the same handle and both reservations in this adopted Session owner.
        match(overlap){case Some(actual)=>actual.close();overlap=None;case None=>()}
        match(fixed){case Some(actual)=>actual.close();fixed=None;case None=>()}
        Result<Unit>.Ok(())}
    public func close():Result<Unit>{lock.lock();try{closed=true;cleanup()}finally{lock.unlock()}}
    public func read():Result<Unit>{
        lock.lock()
        try{
            if(closed || started){return hostPluginResourceError<Unit>("plugin.latest_input_closed","actual stream input is one-shot")}
            started=true;inRead=true
            let result=try{invoke(this)}catch(_:Exception){hostPluginResourceError<Unit>("plugin.latest_input_failed","actual completed input failed")}
                finally{inRead=false}
            match(cleanup()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            if(result.isOk() && !completed){return hostPluginResourceError<Unit>("plugin.latest_input_unconsumed","actual private Store proof was not consumed")}
            result
        }finally{lock.unlock()}}
    public func materialize(proof:SqlitePluginDocumentLatestJournalInputProof):Result<Unit>{
        if(!inRead || closed || input.isSome() || fixed.isSome() || completed){
            return hostPluginResourceError<Unit>("plugin.latest_input_window_closed","actual input materialization window is closed")}
        match(localCurrent()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
        // Prepay buffer and sliced-byte overlap before either Array exists.
        // Actual aggregate file length is not a whole JSON/String allocation.
        fixed=Some(reserveNativeObservationBuffer());overlap=Some(reserveNativeObservationBuffer())
        let consumeInput:(PluginDocumentLatestJournalStreamReference,()->Result<Unit>)->Result<(Int64,String)>={reference:PluginDocumentLatestJournalStreamReference,current:()->Result<Unit>=>
            let actualCurrent={=>
                match(localCurrent()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                current()}
            match(actualCurrent()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
            let selected=path(reference.digest)
            let witness=match(hostReadResourceWitness(selected)){
                case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(value)=>value}
            let file=HostVerifiedArtifactInput(witness,reference.bytes);input=Some(file)
            match(file.open(selected)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
            let buffer=Array<Byte>(65536,repeat:0);var pass:Int64=0
            while(true){
                let hash=SHA256();var offset:Int64=0
                while(true){
                    match(actualCurrent()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    let count=match(file.read(buffer)){
                        case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(value)=>value}
                    if(count==0){break}
                    if(count>reference.bytes-offset){return hostPluginResourceError<(Int64,String)>("plugin.latest_input_file_changed","actual stream exceeds its complete extent")}
                    let part=buffer[..count];hash.write(part)
                    match(actualCurrent()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    // This is a direct captured zero-services worker bridge.
                    // It may inspect only the bytes authorized by this proof.
                    match(consume(offset,part)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    offset+=count
                    match(actualCurrent()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                }
                let digest=hostArtifactHex(hash.finish())
                if(offset!=reference.bytes || digest!=reference.digest){return hostPluginResourceError<(Int64,String)>(
                    "plugin.latest_input_file_changed","complete actual stream EOF hash or bytes changed")}
                match(actualCurrent()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                // The native codec must validate every frame/version through
                // EOF. A Ready response is only a protocol ACK, not authority.
                // Any final output is downloaded to a preadopted writer here;
                // its metadata/DOM cannot outlive a closed reply reservation.
                let ready=match(end(pass)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(value)=>value}
                match(actualCurrent()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                if(ready){
                    match(file.close()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>input=None}
                    match(actualCurrent()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    return Result<(Int64,String)>.Ok((offset,digest))}
                // A replay grants nothing new: same fd/witness, same full
                // fact/reference/private fence/TX, every byte and full hash.
                if(pass==Int64.Max){return hostPluginResourceError<(Int64,String)>("plugin.latest_input_pass_overflow","actual replay index overflow")}
                match(file.rewind()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                pass+=1
            }
            hostPluginResourceError<(Int64,String)>("plugin.latest_input_unconsumed","actual private Store proof was not consumed")
        }
        let result:Result<Unit>=proof.materialize(consumeInput)
        if(result.isOk()){completed=true}
        result
    }
    public func materialize(proof:SqlitePluginLivePolicyBaseJournalInputProof):Result<Unit>{
        if(!inRead || closed || input.isSome() || fixed.isSome() || completed){
            return hostPluginResourceError<Unit>("plugin.latest_input_window_closed","actual input materialization window is closed")}
        match(localCurrent()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
        // Prepay buffer and sliced-byte overlap before either Array exists.
        // Actual aggregate file length is not a whole JSON/String allocation.
        fixed=Some(reserveNativeObservationBuffer());overlap=Some(reserveNativeObservationBuffer())
        let consumeInput:(PluginDocumentLatestJournalStreamReference,()->Result<Unit>)->Result<(Int64,String)>={reference:PluginDocumentLatestJournalStreamReference,current:()->Result<Unit>=>
            let actualCurrent={=>
                match(localCurrent()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
                current()}
            match(actualCurrent()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
            let selected=path(reference.digest)
            let witness=match(hostReadResourceWitness(selected)){
                case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(value)=>value}
            let file=HostVerifiedArtifactInput(witness,reference.bytes);input=Some(file)
            match(file.open(selected)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
            let buffer=Array<Byte>(65536,repeat:0);var pass:Int64=0
            while(true){
                let hash=SHA256();var offset:Int64=0
                while(true){
                    match(actualCurrent()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    let count=match(file.read(buffer)){
                        case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(value)=>value}
                    if(count==0){break}
                    if(count>reference.bytes-offset){return hostPluginResourceError<(Int64,String)>("plugin.latest_input_file_changed","actual stream exceeds its complete extent")}
                    let part=buffer[..count];hash.write(part)
                    match(actualCurrent()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    // This is a direct captured zero-services worker bridge.
                    // It may inspect only the bytes authorized by this proof.
                    match(consume(offset,part)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    offset+=count
                    match(actualCurrent()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                }
                let digest=hostArtifactHex(hash.finish())
                if(offset!=reference.bytes || digest!=reference.digest){return hostPluginResourceError<(Int64,String)>(
                    "plugin.latest_input_file_changed","complete actual stream EOF hash or bytes changed")}
                match(actualCurrent()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                // The native codec must validate every frame/version through
                // EOF. A Ready response is only a protocol ACK, not authority.
                // Any final output is downloaded to a preadopted writer here;
                // its metadata/DOM cannot outlive a closed reply reservation.
                let ready=match(end(pass)){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(value)=>value}
                match(actualCurrent()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                if(ready){
                    match(file.close()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>input=None}
                    match(actualCurrent()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                    return Result<(Int64,String)>.Ok((offset,digest))}
                // A replay grants nothing new: same fd/witness, same full
                // fact/reference/private fence/TX, every byte and full hash.
                if(pass==Int64.Max){return hostPluginResourceError<(Int64,String)>("plugin.latest_input_pass_overflow","actual replay index overflow")}
                match(file.rewind()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
                pass+=1
            }
            hostPluginResourceError<(Int64,String)>("plugin.latest_input_unconsumed","actual private Store proof was not consumed")
        }
        let result:Result<Unit>=proof.materialize(consumeInput)
        if(result.isOk()){completed=true}
        result
    }
}
