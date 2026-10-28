package agent_store

import std.env.getVariable
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class SqliteColumnCopyTests {
    @TestCase
    func nullEmptyAndNumericValuesRemainDistinct(): Unit {
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
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
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
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
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
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
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
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
    func largeNulFreeColumnRemainsOwnedAndPreservesTheCompleteUtf8Tail(): Unit {
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        let db=SqliteDatabase(root+"/copy.sqlite")
        let value=String.fromUtf8(Array<UInt8>(3145728,repeat:b'x'))+"雪🙂whole-tail"
        try {
            db.execute("CREATE TABLE text_copy(value TEXT)")
            db.execute("INSERT INTO text_copy VALUES(?)",[SqlParameter.Text(value)])
            let rows=db.query("SELECT value FROM text_copy")
            db.execute("UPDATE text_copy SET value='replacement'")
            db.close()
            @Expect(rows.size,1);@Expect(rows[0].required(0),value)
        } finally {db.close();remove(root,recursive:true)}
    }

    @TestCase
    func boundTextKeepsSubstringBytesEmptyTypeAndNullDistinctAfterBindFailure(): Unit {
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        let db=SqliteDatabase(root+"/copy.sqlite")
        let source="prefix雪\u{0}ésuffix"
        let value=source[6..12]
        try {
            db.execute("CREATE TABLE text_copy(value TEXT, empty_value TEXT, null_value TEXT)")
            db.execute("INSERT INTO text_copy VALUES(?,?,?)",[
                SqlParameter.Text(value),SqlParameter.Text(""),SqlParameter.Null])
            var rejected=false
            try {
                db.execute("INSERT INTO text_copy(value) VALUES(?)",[
                    SqlParameter.Text("must not be inserted"),SqlParameter.Text(value)])
            } catch(_:IllegalStateException) {rejected=true}
            @Expect(rejected)
            let rows=db.query("SELECT value,hex(value),typeof(empty_value),empty_value,null_value FROM text_copy")
            @Expect(rows.size,1);@Expect(rows[0].required(0),value)
            @Expect(rows[0].required(1),"E99BAA00C3A9")
            @Expect(rows[0].required(2),"text");@Expect(rows[0].required(3),"")
            @Expect(rows[0][4].isNone());@Expect(source,"prefix雪\u{0}ésuffix")
        } finally {db.close();remove(root,recursive:true)}
    }

    @TestCase
    func invalidUtf8StillRejectsAndStatementCleanupKeepsConnectionUsable(): Unit {
        let root=Directory.createTemp(getVariable("TMPDIR") ?? "/tmp").toString()
        let db=SqliteDatabase(root+"/copy.sqlite")
        var rejected=false
        try {
            for (sql in ["SELECT CAST(X'FF' AS TEXT)", "SELECT CAST(X'6100FF' AS TEXT)"]) {
                rejected=false
                try {let _=db.query(sql)}
                catch(_:Exception){rejected=true}
                @Expect(rejected)
                let rows=db.query("SELECT 'valid after rejected conversion', NULL, ''")
                @Expect(rows.size,1);@Expect(rows[0].required(0),"valid after rejected conversion")
                @Expect(rows[0][1].isNone());@Expect(rows[0].required(2),"")
            }
        } finally {db.close();remove(root,recursive:true)}
    }
}
