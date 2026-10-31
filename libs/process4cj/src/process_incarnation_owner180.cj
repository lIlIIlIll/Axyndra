package process4cj

import std.sync.*

foreign func process4cj_open_incarnation180(pid:Int64,started:Int64,fd:CPointer<Int32>):Int32
foreign func process4cj_incarnation_exit180(fd:Int32):Int32
foreign func process4cj_close_once180(fd:Int32):Int32

// No authority is carried here. The production caller holds the original
// current/effect window around every signal and registers this paid DATA
// object before open. Only a real pidfd poll witnesses this OS incarnation.
public class ProcessIncarnationOwner180 {
    private let lock=Mutex()
    private let pid:Int64
    private let started:Int64
    private var descriptor:Int32 = -1
    private var attempted=false
    private var exact=false
    private var missing=false
    private var closeAttempted=false
    private var closeReturned=false
    private var original:?Exception=None<Exception>
    public init(pid:Int64,started:Int64){this.pid=pid;this.started=started}
    public func openExact180(fund:(Int64)->Unit):Bool {
        lock.lock();try{
            if(attempted){throw ProcessError(ProcessErrorKind.Io,"incarnation open already attempted")}
            fund(65536);attempted=true
            try{openExactWholeHelper180()}catch(error:Exception){original=Some(error);throw error}
            exact
        }finally{lock.unlock()}
    }
    private func openExactWholeHelper180():Unit {
        unsafe {
            let out=LibC.malloc<Int32>()
            try{
                out.write(-1)
                let result=process4cj_open_incarnation180(pid,started,out)
                // Publish before inspecting an error or constructing its text.
                descriptor=out.read()
                if(result<0){throw ProcessError(ProcessErrorKind.Io,"incarnation open failed errno="+(-result).toString())}
                missing=result==1;exact=result==0
            }finally{LibC.free(out)}
        }
    }
    public func expectedIncarnationMissing180():Bool {
        lock.lock();try{attempted && missing && original.isNone()}finally{lock.unlock()}
    }
    public func exited180():Bool {
        lock.lock();try{
            if(closeReturned){return true}
            if(!exact || descriptor<0){throw ProcessError(ProcessErrorKind.Io,"exact incarnation is not observed")}
            let result=unsafe{process4cj_incarnation_exit180(descriptor)}
            if(result<0){throw ProcessError(ProcessErrorKind.Io,"incarnation poll failed errno="+(-result).toString())}
            result==1
        }finally{lock.unlock()}
    }
    public func signalTree180(signal:Int32,fund:(Int64)->Unit):Unit {
        lock.lock();try{
            if(!exact || descriptor<0 || closeAttempted){throw ProcessError(ProcessErrorKind.Io,"incarnation signal owner is unavailable")}
            let alive=unsafe{process4cj_incarnation_exit180(descriptor)}
            if(alive<0){throw ProcessError(ProcessErrorKind.Io,"incarnation poll failed errno="+(-alive).toString())}
            if(alive==1){return}
            let bytes=unsafe{process4cj_signal_frame_bytes180()}
            if(bytes<1){throw ProcessError(ProcessErrorKind.Io,"incarnation signal invoice is unavailable")}
            fund(bytes)
            let result=unsafe{process4cj_signal_owned_tree180(pid,started,signal)}
            if(result!=0){throw ProcessError(ProcessErrorKind.Io,"incarnation tree signal failed errno="+result.toString())}
        }finally{lock.unlock()}
    }
    public func closeAfterObservedExit180():Unit {
        lock.lock();try{
            if(closeReturned){return}
            if(closeAttempted || original.isSome()){throw ProcessError(ProcessErrorKind.Io,"incarnation close remains unobserved")}
            if(!missing){
                if(!exact || descriptor<0){throw ProcessError(ProcessErrorKind.Io,"incarnation identity is not observed")}
                let observed=unsafe{process4cj_incarnation_exit180(descriptor)}
                if(observed!=1){throw ProcessError(ProcessErrorKind.Io,"incarnation has not physically exited")}
            }
            closeAttempted=true
            try{closeDescriptorWholeHelper180()}catch(error:Exception){original=Some(error);throw error}
            descriptor=-1;closeReturned=true
        }finally{lock.unlock()}
    }
    private func closeDescriptorWholeHelper180():Unit {
        if(descriptor<0){return}
        let result=unsafe{process4cj_close_once180(descriptor)}
        if(result!=0){throw ProcessError(ProcessErrorKind.Io,"incarnation close failed errno="+result.toString())}
    }
    public func descriptorReturned180():Bool {
        lock.lock();try{closeReturned && descriptor<0 && original.isNone()}finally{lock.unlock()}
    }
}
