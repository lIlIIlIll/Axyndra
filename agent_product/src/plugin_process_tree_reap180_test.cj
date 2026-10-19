package agent_product

import agent_domain.*
import agent_store.*
import std.fs.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class InstalledWorkflowActualTreeReap180Tests {
    @TestCase
    func escapedDoubleForkIsActuallyReapedBeforeCanonicalStopReturns180():Unit{
        let f=WorkflowChildFixture111()
        try{
            actualProcessSelection180(f)
            // The installed original Native process route starts this real
            // command. Its double-forked child changes session and is truly
            // reparented to the private supervisor; a process-group kill or
            // killing that supervisor cannot serve as this absence oracle.
            File.writeTo(f.root+"/actual-process180.py",("import os,time\n"+
                "from pathlib import Path\n"+
                "if os.fork()==0:\n os.setsid()\n"+
                " if os.fork()>0: os._exit(0)\n"+
                " Path('actual-descendant180.pid').write_text(str(os.getpid()))\n"+
                " print('READY180',flush=True)\n"+
                "while True: time.sleep(1)\n").toArray())
            let start=actualProcessRun180(f,"process-tree-start-180","start",actualProcessStartFields180(f,"tree180"))
            try{@Expect(!start.output.field("readyTimedOut").getOrThrow().asBool())}
            finally{start.releasePayload()}
            let descendant=String.fromUtf8(File.readFrom(f.root+"/actual-descendant180.pid"))
            @Expect(exists(Path("/proc/"+descendant)))
            let stop=actualProcessRun180(f,"process-tree-stop-180","stop",[
                ValueField("name",textValue("tree180")),ValueField("timeout",integerValue(1))])
            try{@Expect(stop.output.field("daemon").getOrThrow().field("pid").getOrThrow().unifiedKind,ValueKind.Null)}
            finally{stop.releasePayload()}
            // No grace loop turns eventual init reaping into Native evidence:
            // the actual canonical stop must already have consumed the
            // supervisor ECHILD receipt and parent waitpid before returning.
            @Expect(!exists(Path("/proc/"+descendant)))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='hub_process_service_reserved'"),2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),2)
            actualProcessExpectNoModel180(f)
        }finally{f.close()}
    }
}
