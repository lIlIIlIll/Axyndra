package agent_store

import std.unittest.*
import std.unittest.testmacro.*

@Test
class ChannelWriteMemoRecordingTests {
    @TestCase
    func repeatedThreeMibTextFitsTheOriginalBoundAndStillComparesEveryByte() {
        let bytes=String.fromUtf8(Array<UInt8>(3145728,repeat:b'a'))
        let recording=ChannelWriteMemoRecording(6291456,0)
        let actual=[SqliteRow([Some(bytes),None])]
        for(_ in 0..12){let result=recording.record("SELECT payload,nullable FROM actual_proof",[],actual)
            @Expect(result[0].required(0),bytes)}
        @Expect(recording.reusable())
        @Expect(recording.retainedBytes()<=33554432)
        @Expect(recording.retainedBytes()<12582912)
        let reads=recording.takeReads();@Expect(reads.size,12)
        let changed=String.fromUtf8(Array<UInt8>(3145727,repeat:b'a'))+"b"
        for(read in reads){
            @Expect(read.matches(actual))
            @Expect(!read.matches([SqliteRow([Some(changed),None])]))
            @Expect(!read.matches([SqliteRow([Some(bytes),Some("")])]))
        }
    }

    @TestCase
    func uniqueOversizeEvidenceKeepsTheActualRowsAndIsNeverRetained() {
        let recording=ChannelWriteMemoRecording(0,0,maximumBytes:2048)
        let first=[SqliteRow([Some("first")])]
        let _=recording.record("SELECT value FROM actual_proof",[],first)
        @Expect(recording.reusable())
        let huge=String.fromUtf8(Array<UInt8>(4096,repeat:b'z'))
        let current=[SqliteRow([Some(huge)])]
        let result=recording.record("SELECT value FROM actual_proof",[],current)
        @Expect(result[0].required(0),huge)
        @Expect(!recording.reusable())
        @Expect(recording.takeReads().isEmpty())
        @Expect(recording.retainedBytes()<=2048)
        let badKey=ChannelWriteMemoRecording(33554432,1)
        @Expect(!badKey.reusable())
    }

    @TestCase
    func originalQueryParameterColumnRowAndMutableBlobLimitsStayClosed() {
        let actual=[SqliteRow([Some("same")])]
        let recording=ChannelWriteMemoRecording(0,0)
        for(_ in 0..128){let _=recording.record("SELECT value FROM actual_proof",[],actual)}
        @Expect(recording.reusable());@Expect(recording.takeReads().size,128)
        let _=recording.record("SELECT value FROM actual_proof",[],actual)
        @Expect(!recording.reusable());@Expect(recording.takeReads().isEmpty())
        let parameters=ChannelWriteMemoRecording(0,0)
        let _=parameters.record("SELECT value FROM actual_proof",Array<SqlParameter>(33,repeat:SqlParameter.Null),actual)
        @Expect(!parameters.reusable())
        let columns=ChannelWriteMemoRecording(0,0)
        let _=columns.record("SELECT value FROM actual_proof",[],[SqliteRow(Array<?String>(33,repeat:None))])
        @Expect(!columns.reusable())
        let rows=ChannelWriteMemoRecording(0,0)
        let _=rows.record("SELECT value FROM actual_proof",[],Array<SqliteRow>(257,repeat:actual[0]))
        @Expect(!rows.reusable())
        let blob=ChannelWriteMemoRecording(0,0)
        let _=blob.record("SELECT value FROM actual_proof",[SqlParameter.Blob([1u8])],actual)
        @Expect(!blob.reusable())
    }

    @TestCase
    func frozenArraysRetainAbsenceNullOrderingAndImmutableParameters() {
        let recording=ChannelWriteMemoRecording(0,0)
        let columns: Array<?String>=[Some("original"),None]
        let parameters=[SqlParameter.Text("original")]
        let observed=[SqliteRow(columns),SqliteRow([Some("second"),Some("")])]
        let _=recording.record("SELECT name,value FROM actual_proof WHERE key=?",parameters,observed)
        let read=recording.takeReads()[0]
        columns[0]=Some("changed");parameters[0]=SqlParameter.Text("changed")
        @Expect(!read.matches(observed))
        let original=[SqliteRow([Some("original"),None]),observed[1]]
        @Expect(read.matches(original));@Expect(!read.matches([original[1],original[0]]))
        @Expect(!read.matches([original[0]]))
        @Expect(match(read.parameters[0]){case SqlParameter.Text(value)=>value=="original";case _=>false})
        let absent=ChannelWriteMemoRecording(0,0)
        let _=absent.record("SELECT value FROM absent_proof",[],[])
        @Expect(absent.takeReads()[0].matches([]))
        @Expect(!absent.takeReads()[0].matches([SqliteRow([None])]))
    }
}
