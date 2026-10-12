package agent_store

import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class SqliteColumnCopyTests {
    @TestCase
    func nullEmptyAndNumericValuesRemainDistinct(): Unit {
        let root=Directory.createTemp("/tmp").toString()
        let db=SqliteDatabase(root+"/copy.sqlite")
        try {
            let rows=db.query("SELECT NULL, '', 0, -9223372036854775808, 1.25")
            @Expect(rows.size,1);@Expect(rows[0].size,5)
            @Expect(rows[0][0].isNone());@Expect(rows[0][1].isSome())
            @Expect(rows[0].required(1),"");@Expect(rows[0].required(2),"0")
            @Expect(rows[0].required(3),"-9223372036854775808")
            @Expect(rows[0].required(4),"1.25")
        } finally {db.close();remove(root,recursive:true)}
    }

    @TestCase
    func embeddedZerosAndMultibyteTextKeepEveryByte(): Unit {
        let root=Directory.createTemp("/tmp").toString()
        let db=SqliteDatabase(root+"/copy.sqlite")
        let value=String.fromUtf8([UInt8(0)])+"雪🙂e"+
            String.fromUtf8([UInt8(204),UInt8(129),UInt8(0)])+"tail"+
            String.fromUtf8([UInt8(0)])
        try {
            db.execute("CREATE TABLE text_copy(value TEXT)")
            db.execute("INSERT INTO text_copy VALUES(?)",[SqlParameter.Text(value)])
            let rows=db.query("SELECT value, hex(value) FROM text_copy")
            @Expect(rows.size,1);@Expect(rows[0].required(0),value)
            @Expect(rows[0].required(0).toArray(),value.toArray())
            @Expect(rows[0].required(1),"00E99BAAF09F998265CC81007461696C00")
        } finally {db.close();remove(root,recursive:true)}
    }

    @TestCase
    func copiedRowsSurviveNextStepFinalizationAndConnectionClose(): Unit {
        let root=Directory.createTemp("/tmp").toString()
        let db=SqliteDatabase(root+"/copy.sqlite")
        try {
            db.execute("CREATE TABLE text_copy(ordinal INTEGER, value TEXT)")
            let values=["first雪",String.fromUtf8([UInt8(0),UInt8(65),UInt8(0)]),"last🙂"]
            for(index in 0..values.size) {
                db.execute("INSERT INTO text_copy VALUES(?,?)",[
                    SqlParameter.Int64Value(index),SqlParameter.Text(values[index])])
            }
            let rows=db.query("SELECT value FROM text_copy ORDER BY ordinal")
            @Expect(rows.size,3)
            let later=db.query("SELECT 'different allocation'")
            @Expect(later[0].required(0),"different allocation")
            db.close()
            for(index in 0..values.size){@Expect(rows[index].required(0),values[index])}
            let reopened=SqliteDatabase(root+"/copy.sqlite",readOnly:true)
            try {
                let restored=reopened.query("SELECT value FROM text_copy ORDER BY ordinal")
                for(index in 0..values.size){@Expect(restored[index].required(0),values[index])}
            } finally {reopened.close()}
        } finally {db.close();remove(root,recursive:true)}
    }

    @TestCase
    func threeMibColumnsAreCompleteAcrossRepeatedSqlQueries(): Unit {
        let root=Directory.createTemp("/tmp").toString()
        let db=SqliteDatabase(root+"/copy.sqlite")
        let value=String.fromUtf8(Array<UInt8>(3145728,repeat:b'x'))+
            String.fromUtf8([UInt8(0)])+"雪"
        try {
            db.execute("CREATE TABLE text_copy(value TEXT)")
            db.execute("INSERT INTO text_copy VALUES(?)",[SqlParameter.Text(value)])
            for(_ in 0..3) {
                let rows=db.query("SELECT value, value, length(CAST(value AS BLOB)) FROM text_copy")
                @Expect(rows.size,1);@Expect(rows[0].required(0),value)
                @Expect(rows[0].required(1),value);@Expect(rows[0].required(2),"3145732")
            }
        } finally {db.close();remove(root,recursive:true)}
    }

    @TestCase
    func invalidUtf8StillRejectsAndStatementCleanupKeepsConnectionUsable(): Unit {
        let root=Directory.createTemp("/tmp").toString()
        let db=SqliteDatabase(root+"/copy.sqlite")
        var rejected=false
        try {
            try {let _=db.query("SELECT CAST(X'FF' AS TEXT)")}
            catch(_:Exception){rejected=true}
            @Expect(rejected)
            let rows=db.query("SELECT 'valid after rejected conversion', NULL, ''")
            @Expect(rows.size,1);@Expect(rows[0].required(0),"valid after rejected conversion")
            @Expect(rows[0][1].isNone());@Expect(rows[0].required(2),"")
        } finally {db.close();remove(root,recursive:true)}
    }
}
