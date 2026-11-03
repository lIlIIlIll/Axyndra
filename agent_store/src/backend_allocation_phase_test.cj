package agent_store

import agent_domain.*
import std.env.getVariable
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

class BackendPhaseTestWitness {var called:Bool=false}

private func backendPhaseTestJournal(owner:LogicalJsonOwnerBudget):SqliteOpaqueRowJournal{
    SqliteOpaqueRowJournal("axyndra:memory","journal","/workspace","/settings",
        {bytes=>owner.acquire(max(1,bytes))},modelPolicySha256Text("phase-test-configuration"),
        {=>Result<Unit>.Ok(())})
}

// Real SQLite/backend allocation controls, not Source, admission or Root tests.
@Test
class BackendAllocationPhaseTests {
    @TestCase
    func sequentialCompleteBackendReadsReleaseOnlyAtUnitPhaseExit():Unit{
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(root+"/phase.db")
        let owner=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let hostMetadata=owner.acquire(65536)
        let fixed=owner.acquireFixedBuffer(65536);let backend=backendPhaseTestJournal(owner)
        try{
            db.readTransaction<Unit>({tx=>
                for(_ in 0..16){
                    tx.withBackendAllocationPhase({=>
                        let snapshot=backend.read(tx,ThreadId("phase-thread"),LaneId("main"),"axyndra:memory","journal")
                        @Expect(snapshot.revision,1);@Expect(snapshot.encoded.size>0)
                        @Expect(owner.usage()[0],3);@Expect(owner.usage()[1],33554432+65536)
                    })
                    @Expect(owner.usage()[0],2);@Expect(owner.usage()[1],16777216+65536)
                }
            })
            @Expect(owner.usage()[0],2)
        }finally{hostMetadata.close();fixed.close();db.close();remove(root,recursive:true)}
        @Expect(owner.usage()[0],0);@Expect(owner.usage()[1],0)
    }

    @TestCase
    func defaultEscapingSnapshotStillHoldsFullPaymentUntilTransactionEnd():Unit{
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(root+"/default.db")
        let owner=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let backend=backendPhaseTestJournal(owner)
        try{
            db.readTransaction<Unit>({tx=>
                let first=backend.read(tx,ThreadId("phase-thread"),LaneId("main"),"axyndra:memory","journal")
                @Expect(owner.usage()[0],1);@Expect(owner.usage()[1],16777216)
                let second=backend.read(tx,ThreadId("phase-thread"),LaneId("main"),"axyndra:memory","journal")
                @Expect(first.encoded,second.encoded);@Expect(owner.usage()[0],2)
            })
            @Expect(owner.usage()[0],0);@Expect(owner.usage()[1],0)
        }finally{db.close();remove(root,recursive:true)}
    }

    @TestCase
    func nestedPhaseFailureReleasesInnerPaymentAndPreservesOuterAndDefaultOwners():Unit{
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(root+"/nested.db")
        let owner=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY)
        try{
            db.readTransaction<Unit>({tx=>
                tx.retainBackendAllocation(owner.acquire(1))
                tx.withBackendAllocationPhase({=>
                    tx.retainBackendAllocation(owner.acquire(1))
                    var denied=false
                    try{tx.withBackendAllocationPhase({=>
                        tx.retainBackendAllocation(owner.acquire(1))
                        @Expect(owner.usage()[0],3);@Expect(tx.query("SELECT '雪'")[0].required(0),"雪")
                        throw IllegalStateException("phase-test-inner-failure")
                    })}catch(_:Exception){denied=true}
                    @Expect(denied);@Expect(owner.usage()[0],2);@Expect(owner.usage()[1],33554432)
                })
                @Expect(owner.usage()[0],1);@Expect(owner.usage()[1],16777216)
            })
            @Expect(owner.usage()[0],0);@Expect(owner.usage()[1],0)
        }finally{db.close();remove(root,recursive:true)}
    }

    @TestCase
    func delegatedTransactionSharesActualPhaseAndCannotCloseAnUnrelatedLiveOwner():Unit{
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(root+"/delegated.db")
        let owner=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let unrelated=owner.acquire(1)
        try{
            db.readTransaction<Unit>({tx=>
                let proxy=SqliteTransaction({sql=>tx.execute(sql)},{sql=>tx.query(sql)},
                    {sql,values=>tx.execute(sql,values)},{sql,values=>tx.query(sql,values)},backendOwner:Some(tx))
                proxy.withBackendAllocationPhase({=>
                    proxy.retainBackendAllocation(owner.acquire(1))
                    @Expect(owner.usage()[0],2)
                    proxy.withBackendAllocationPhase({=>
                        tx.retainBackendAllocation(owner.acquire(1));@Expect(owner.usage()[0],3)
                    })
                    @Expect(owner.usage()[0],2)
                })
                @Expect(owner.usage()[0],1);@Expect(owner.usage()[1],16777216)
            })
            @Expect(owner.usage()[0],1)
        }finally{unrelated.close();db.close();remove(root,recursive:true)}
        @Expect(owner.usage()[0],0);@Expect(owner.usage()[1],0)
    }

    @TestCase
    func cancelledPhaseAndFailingFinalCheckStillRollbackSqlAndReleaseOnlyBackendCopies():Unit{
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(root+"/rollback.db")
        let owner=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let unrelated=owner.acquireFixedBuffer(65536)
        try{
            db.execute("CREATE TABLE phase_fixture(id INTEGER PRIMARY KEY,value TEXT NOT NULL)")
            var cancelled=false
            try{db.transaction<Unit>({tx=>
                tx.withBackendAllocationPhase({=>
                    tx.retainBackendAllocation(owner.acquire(1));tx.execute("INSERT INTO phase_fixture VALUES(1,'not-committed')")
                    throw PluginDocumentGuardFailure(AgentError(AgentErrorKind.Cancelled,"fixture.phase_cancelled","cancelled within original transaction"))
                })
            })}catch(_:PluginDocumentGuardFailure){cancelled=true}
            @Expect(cancelled);@Expect(db.scalarInt("SELECT COUNT(*) FROM phase_fixture"),0)
            @Expect(owner.usage()[0],1);@Expect(owner.usage()[1],65536)
            var refused=false
            try{db.transaction<Unit>({tx=>
                tx.execute("INSERT INTO phase_fixture VALUES(2,'not-committed')")
                tx.retainBackendPostCheck({=>
                    tx.retainBackendAllocation(owner.acquire(1))
                    @Expect(tx.query("SELECT value FROM phase_fixture WHERE id=2")[0].required(0),"not-committed")
                    throw IllegalStateException("phase-test-final-check-failed")
                })
            })}catch(_:Exception){refused=true}
            @Expect(refused);@Expect(db.scalarInt("SELECT COUNT(*) FROM phase_fixture"),0)
            @Expect(owner.usage()[0],1);@Expect(owner.usage()[1],65536)
        }finally{unrelated.close();db.close();remove(root,recursive:true)}
        @Expect(owner.usage()[0],0);@Expect(owner.usage()[1],0)
    }

    @TestCase
    func fullQuotaRefusalLeavesOtherOwnersChargedAndPostChecksRunSequentially():Unit{
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString();let db=SqliteDatabase(root+"/limits.db")
        let owner=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let backend=backendPhaseTestJournal(owner);let witness=BackendPhaseTestWitness()
        let first=owner.acquire(8388608);let second=owner.acquire(8388608)
        try{
            var refused=false
            try{db.readTransaction<Unit>({tx=>tx.withBackendAllocationPhase({=>
                let _=backend.read(tx,ThreadId("phase-thread"),LaneId("main"),"axyndra:memory","journal")
                witness.called=true
            })})}catch(_:LogicalJsonPayloadError){refused=true}
            @Expect(refused);@Expect(!witness.called);@Expect(owner.usage()[0],2);@Expect(owner.usage()[1],134217728)
        }finally{first.close();second.close()}
        try{
            db.transaction<Unit>({tx=>
                let retained=backend.read(tx,ThreadId("phase-thread"),LaneId("main"),"axyndra:memory","journal")
                @Expect(retained.encoded.size>0);@Expect(owner.usage()[0],1)
                for(_ in 0..12){tx.retainBackendPostCheck({=>
                    let current=backend.read(tx,ThreadId("phase-thread"),LaneId("main"),"axyndra:memory","journal")
                    @Expect(current.revision,1);@Expect(current.encoded.size>0)
                    @Expect(owner.usage()[0],2);@Expect(owner.usage()[1],33554432)
                })}
            })
            @Expect(owner.usage()[0],0);@Expect(owner.usage()[1],0)
        }finally{db.close();remove(root,recursive:true)}
    }
}
