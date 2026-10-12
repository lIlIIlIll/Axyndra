package agent_store

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class ManagedChannelWholeTerminalIdentityTests{
    @TestCase
    func wholeLargeNulUnicodeResponseKeepsOriginalStoredFramingAndTail():Unit{
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(1)
        owner.ensureRetainedPeak(33554432)
        try{
            let text=String.fromUtf8(Array<Byte>(1572864,repeat:0))+"雪🙂actual last byte"
            let value=objectValue([ValueField("success",boolValue(false)),ValueField("body",textValue(text)),
                ValueField("message",textValue("full actual protocol error 雪\u{0}🙂"))])
            let original=encodeStoredValue(value)
            let identity=managedChannelTerminalValueIdentity(value,owner,2000000,{=>Result<Unit>.Ok(())})
            @Expect(identity.field("bytes").getOrThrow().asNumberText(),original.size.toString())
            @Expect(httpIntentText(identity,"sha256"),modelPolicySha256Text(original))
            @Expect(managedChannelKnownIdentityMatches(identity,value,owner,2000000,{=>Result<Unit>.Ok(())}),true)
            let changed=objectValue([ValueField("success",boolValue(false)),ValueField("body",textValue(text+"!")),
                ValueField("message",textValue("full actual protocol error 雪\u{0}🙂"))])
            @Expect(managedChannelKnownIdentityMatches(identity,changed,owner,2000000,{=>Result<Unit>.Ok(())}),false)
            @Expect(pool.usage()[0],1)
        }finally{owner.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func originalFullPoolRejectsWholeTraversalBeforeMetadataAndRestoresSameOwner():Unit{
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(1)
        let value=listValue(Array<AgentValue>(4096,{_=>textValue("雪\u{0}🙂")}))
        let pressure=Array<LogicalJsonOwnerReservation>(7,{_=>pool.acquire(1)})
        try{
            @Expect(pool.usage()[0],8);@Expect(pool.usage()[1],134217728)
            var rejected=false
            try{let _=managedChannelTerminalValueIdentity(value,owner,15000000,{=>Result<Unit>.Ok(())})}
            catch(_:LogicalJsonPayloadError){rejected=true}
            @Expect(rejected,true);@Expect(pool.usage()[0],8);@Expect(pool.usage()[1],134217728)
            for(held in pressure){held.close()}
            let identity=managedChannelTerminalValueIdentity(value,owner,15000000,{=>Result<Unit>.Ok(())})
            @Expect(managedChannelKnownIdentityMatches(identity,value,owner,15000000,{=>Result<Unit>.Ok(())}),true)
            @Expect(pool.usage()[0],1)
        }finally{for(held in pressure){held.close()};owner.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func ordinaryDeclaredOrPartialIdentityCannotReplaceWholeHeldOutput():Unit{
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(1)
        try{
            let value=objectValue([ValueField("body",textValue("whole 雪\u{0}🙂"))])
            let actual=managedChannelTerminalValueIdentity(value,owner,0,{=>Result<Unit>.Ok(())})
            let partial=objectValue([ValueField("bytes",actual.field("bytes").getOrThrow()),
                ValueField("sha256",textValue(modelPolicySha256Text("prefix")))])
            @Expect(managedChannelKnownIdentityMatches(partial,value,owner,0,{=>Result<Unit>.Ok(())}),false)
            @Expect(managedChannelKnownIdentityMatches(objectValue([ValueField("sha256",actual.field("sha256").getOrThrow())]),
                value,owner,0,{=>Result<Unit>.Ok(())}),false)
            var cancelled=false
            try{let _=managedChannelTerminalValueIdentity(value,owner,0,{=>Result<Unit>.Err(
                AgentError(AgentErrorKind.Cancelled,"test.actual_cancel","actual terminal consumer was cancelled"))})}
            catch(error:PluginDocumentGuardFailure){cancelled=error.failure.code=="test.actual_cancel"}
            @Expect(cancelled,true)
        }finally{owner.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }

    @TestCase
    func aliasedOutputAndResponseAboveSingleValueCodecBoundKeepEveryOriginalFrameByte():Unit{
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(1)
        owner.ensureRetainedPeak(100663296)
        try{
            let text=String.fromUtf8(Array<Byte>(4194304,repeat:b'x'))+"雪\u{0}🙂"
            let value=objectValue([ValueField("output",textValue(text)),ValueField("response",textValue(text))])
            let original=encodeStoredValue(value)
            @Expect(original.size>8388608,true)
            let identity=managedChannelTerminalValueIdentity(value,owner,40000000,{=>Result<Unit>.Ok(())})
            @Expect(identity.field("bytes").getOrThrow().asNumberText(),original.size.toString())
            @Expect(httpIntentText(identity,"sha256"),modelPolicySha256Text(original))
            @Expect(managedChannelKnownIdentityMatches(identity,value,owner,40000000,{=>Result<Unit>.Ok(())}),true)
            @Expect(pool.usage()[0],1)
        }finally{owner.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
}
