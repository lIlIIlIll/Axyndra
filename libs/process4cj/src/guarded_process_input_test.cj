package process4cj

import std.collection.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

private class GuardedInputDenied <: Exception { init(){super("actual test admission revoked")} }
private class GuardedInputAdmission <: ProcessWriteAdmission {
    let denied=AtomicBool(false)
    let checks=AtomicInt64(0)
    let entered=AtomicInt64(0)
    let closed=AtomicInt64(0)
    let maximum:Int64
    init(maximum!:Int64=Int64.Max){this.maximum=maximum}
    public func check():Unit {
        checks.fetchAdd(1)
        if(denied.load() || entered.load()>=maximum){throw GuardedInputDenied()}
    }
    public func enter():ProcessWriteLease {
        check();entered.fetchAdd(1);GuardedInputLease(this)
    }
}
private class GuardedInputLease <: ProcessWriteLease {
    let owner:GuardedInputAdmission
    let lock=Mutex()
    var released=false
    init(owner:GuardedInputAdmission){this.owner=owner}
    public func close():Unit {lock.lock();try{if(!released){released=true;owner.closed.fetchAdd(1)}}finally{lock.unlock()}}
}
private func guardedPipe():(Int32,Int32) {
    let fds=unsafe{LibC.malloc<Int32>(count:2)}
    unsafe{try{if(pipe(fds)!=0){throw IllegalStateException("real pipe creation failed")};(fds.read(0),fds.read(1))}
        finally{LibC.free(fds)}}
}
private func guardedDrain(input:NativeProcessInput):Array<Byte> {
    let result=ArrayList<Byte>();let buffer=Array<Byte>(8192,repeat:0)
    while(true){let count=input.read(buffer);if(count==0){break};result.add(all:buffer[..count])}
    result.toArray()
}

@Test
class GuardedProcessInputTests {
    @TestCase
    func realPipePreservesBinaryBytesAndClosesEveryPhysicalWriteLease():Unit {
        let (reader,writer)=guardedPipe();let input=NativeProcessInput(reader);let admission=GuardedInputAdmission()
        var writerClosed=false
        try{let bytes=[0u8,255u8,65u8,10u8,0u8]
            nativeProcessWriteAdmitted(writer,bytes,admission,{=>false})
            let _=unsafe{process4cj_close(writer)};writerClosed=true
            @Expect(guardedDrain(input),bytes)
            @Expect(admission.entered.load(),1);@Expect(admission.closed.load(),1)
            @Expect(input.isClosed());input.close()
        }finally{input.close();if(!writerClosed){let _=unsafe{process4cj_close(writer)}}}
    }
    @TestCase
    func revocationAfterActualFirstChunkKeepsOnlyThatPrefixAndAllOwnershipIsReleased():Unit {
        let (reader,writer)=guardedPipe();let input=NativeProcessInput(reader);let admission=GuardedInputAdmission(maximum:1)
        var writerClosed=false
        try{var denied=false
            try{nativeProcessWriteAdmitted(writer,Array<Byte>(8192,repeat:65),admission,{=>false})}
                catch(_:GuardedInputDenied){denied=true}
            @Expect(denied);@Expect(admission.entered.load(),1);@Expect(admission.closed.load(),1)
            let _=unsafe{process4cj_close(writer)};writerClosed=true
            let received=guardedDrain(input);@Expect(received.size,4096)
            @Expect(received,Array<Byte>(4096,repeat:65))
        }finally{input.close();if(!writerClosed){let _=unsafe{process4cj_close(writer)}}}
    }
    @TestCase
    func fullActualPipeWaitRemainsRevocableWithoutAResponseOrReader():Unit {
        let (reader,writer)=guardedPipe();let input=NativeProcessInput(reader);let admission=GuardedInputAdmission()
        let outcome=AtomicBool(false);var writerClosed=false
        let pending=spawn{try{nativeProcessWriteAdmitted(writer,Array<Byte>(1048576,repeat:66),admission,{=>false})}
            catch(_:GuardedInputDenied){outcome.store(true)}}
        try{let deadline=MonoTime.now()+Duration.second*3
            while(admission.checks.load()-2*admission.entered.load()<3 && MonoTime.now()<deadline){sleep(Duration.millisecond*5)}
            @Expect(admission.checks.load()-2*admission.entered.load()>=3)
            admission.denied.store(true);pending.get()
            @Expect(outcome.load());@Expect(admission.entered.load()>0)
            @Expect(admission.entered.load(),admission.closed.load())
            let _=unsafe{process4cj_close(writer)};writerClosed=true
            let received=guardedDrain(input);@Expect(received.size>0 && received.size<1048576)
        }finally{admission.denied.store(true);pending.get();input.close();if(!writerClosed){let _=unsafe{process4cj_close(writer)}}}
    }
}
