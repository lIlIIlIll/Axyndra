package agent_host_runtime

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Real same original Session/custody identity, private writer/output payment
// and physical close. Empty SQLite explicitly supplies no Known/Root claim.
@Test
class LivePolicyCapturedMetadataSuccessor291Tests {
    @TestCase
    func oldActualMetadataMustCloseBeforeSameCustodyCanAdoptSuccessor():Unit{
        let f=Metadata274Fixture();let old=f.artifacts.documentDataSession();let next=f.artifacts.documentDataSession()
        let original=metadata274Custody(old);let identity=original;let successor=metadata274Custody(next)
        try{
            metadata274Require(original.capturePaidMetadata({_=>Result<Unit>.Ok(())}))
            @Expect(original.adoptMetadataSuccessor291(successor).isError(),true)
            metadata274Require(original.withPaidMetadataOwner(nullValue(),{_,_=>
                @Expect(original.retireCapturedMetadataForSuccessor291().isError(),true)
                @Expect(old.livePolicyCapturedMetadataRetained(),true);@Expect(old.collect(),false)}))
            metadata274Require(original.retireCapturedMetadataForSuccessor291())
            @Expect(old.collect(),true);@Expect(next.livePolicyPrivateOutputRetained(),true)
            @Expect(original.withPaidMetadata({_=>Result<Unit>.Ok(())}).isError(),true)
            metadata274Require(original.adoptMetadataSuccessor291(successor))
            @Expect(refEq(identity,original),true)
            // Closing the transferred shell cannot refund its adopted Session.
            metadata274Require(successor.close());@Expect(next.collect(),false)
            metadata274Require(original.capturePaidMetadata({_=>Result<Unit>.Ok(())}))
            @Expect(next.livePolicyCapturedMetadataRetained(),true)
            @Expect(original.adoptMetadataSuccessor291(successor).isError(),true)
            metadata274Require(original.close());@Expect(next.collect(),true);f.noAuthority()
        }finally{
            metadata274Require(original.close());metadata274Require(successor.close())
            old.acknowledgeOutput();next.acknowledgeOutput()
            metadata274Require(old.closeExecutionDataOwner());metadata274Require(next.closeExecutionDataOwner());f.close()
        }
    }
    @TestCase
    func cancelledOrAlreadyCapturedSuccessorCannotReplaceRetiredOwner():Unit{
        let f=Metadata274Fixture();let old=f.artifacts.documentDataSession();let next=f.artifacts.documentDataSession()
        let original=metadata274Custody(old);let successor=metadata274Custody(next)
        try{
            metadata274Require(original.capturePaidMetadata({_=>Result<Unit>.Ok(())}))
            metadata274Require(successor.capturePaidMetadata({_=>Result<Unit>.Ok(())}))
            metadata274Require(original.retireCapturedMetadataForSuccessor291())
            @Expect(original.retireCapturedMetadataForSuccessor291().isError(),true)
            @Expect(original.adoptMetadataSuccessor291(successor).isError(),true)
            @Expect(next.livePolicyCapturedMetadataRetained(),true)
            metadata274Require(original.close())
            @Expect(original.adoptMetadataSuccessor291(successor).isError(),true)
            metadata274Require(successor.close());@Expect(old.collect(),true);@Expect(next.collect(),true);f.noAuthority()
        }finally{
            metadata274Require(original.close());metadata274Require(successor.close())
            old.acknowledgeOutput();next.acknowledgeOutput()
            metadata274Require(old.closeExecutionDataOwner());metadata274Require(next.closeExecutionDataOwner());f.close()
        }
    }
}
