package agent_store

import std.collection.*

// Immutable data only. A successful full validator may retain one transcript;
// every reuse re-executes every original SQL query and compares every exact row.
// Duplicate text shares immutable String storage, never a digest or a prefix.
class ChannelWriteMemoRead {
    let sql: String
    let parameters: Array<SqlParameter>
    private let rows: Array<Array<?String>>

    init(sql: String, parameters: Array<SqlParameter>, rows: Array<Array<?String>>) {
        this.sql=sql
        this.parameters=parameters.clone()
        this.rows=Array<Array<?String>>(rows.size,{ row=>rows[row].clone() })
    }

    // Package-private immutable cell access for the actual connection-owned
    // equality check. No mutable row array or validation authority is returned.
    func expectedRowCount(): Int64 { rows.size }
    func expectedColumnCount(row: Int64): Int64 { rows[row].size }
    func expectedValue(row: Int64, column: Int64): ?String { rows[row][column] }

    func matches(actual: Array<SqliteRow>): Bool {
        if(actual.size!=rows.size){return false}
        for(row in 0..rows.size){
            if(actual[row].size!=rows[row].size){return false}
            for(column in 0..rows[row].size){
                if(actual[row][column]!=rows[row][column]){return false}
            }
        }
        true
    }
}

// The existing startup/invocation recorders and their original limits remain
// unchanged. Only the ordinary channel-write transcript opts into sharing.
class ChannelWriteMemoRecording {
    private let reads=ArrayList<ChannelWriteMemoRead>()
    private let texts=HashMap<String,String>()
    private var retained: Int64=0
    private var bounded=true
    private let maximumBytes: Int64
    private let maximumReads: Int64

    init(planBytes: Int64,bindingBytes: Int64,maximumBytes!: Int64=33554432,maximumReads!: Int64=128){
        this.maximumBytes=maximumBytes;this.maximumReads=maximumReads
        this.bounded=planBytes>=0 && bindingBytes>=0 && maximumBytes>0 && maximumReads>0 &&
            planBytes<=maximumBytes && bindingBytes<=maximumBytes-planBytes
        if(bounded){retained=planBytes+bindingBytes}
    }

    private func invalidate(): Unit {bounded=false;reads.clear();texts.clear()}
    private func charge(bytes: Int64): Unit {
        if(!bounded){return}
        if(bytes<0 || bytes>maximumBytes-retained){invalidate()}
        else{retained+=bytes}
    }
    private func intern(value: String): String {
        if(!bounded){return value}
        match(texts.get(value)){case Some(existing)=>return existing;case None=>()}
        // Charge immutable bytes once plus conservative map/key/value overhead.
        // Both map slots and each memo cell refer to the same immutable String.
        charge(128)
        charge(value.size)
        if(bounded){texts[value]=value}
        value
    }

    func record(sql: String,parameters: Array<SqlParameter>,rows: Array<SqliteRow>): Array<SqliteRow> {
        if(!bounded){return rows}
        if(reads.size>=maximumReads || parameters.size>32 || rows.size>256){invalidate();return rows}
        for(row in rows){if(row.size>32){invalidate();return rows}}
        for(parameter in parameters){
            match(parameter){case SqlParameter.Blob(_)=>invalidate();return rows;case _=>()}}
        charge(256)
        let frozenSql=intern(sql)
        let frozenParameters=Array<SqlParameter>(parameters.size,{ index=>
            charge(64)
            match(parameters[index]){
                case SqlParameter.Text(value)=>SqlParameter.Text(intern(value))
                case value=>value
            }})
        let frozenRows=Array<Array<?String>>(rows.size,{ row=>
            charge(64)
            Array<?String>(rows[row].size,{ column=>
                charge(32)
                match(rows[row][column]){case Some(value)=>Some(intern(value));case None=>None}
            })})
        if(bounded){reads.add(ChannelWriteMemoRead(frozenSql,frozenParameters,frozenRows))}
        // Return the current actual SQLite result without mutation or filtering.
        rows
    }

    func reusable(): Bool {bounded && !reads.isEmpty()}
    func takeReads(): Array<ChannelWriteMemoRead> {reads.toArray()}
    func retainedBytes(): Int64 {retained}
}
