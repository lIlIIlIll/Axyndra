package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// A trusted assembly mapping, never an IPC request, table selector or read
// grant. The original document service proves its real Source and capability
// before calling any method on this opt-in data backend.
public interface PluginDocumentStorageBackend {
    prop identity: String
    func read(transaction: SqliteTransaction, thread: ThreadId, lane: LaneId,
        namespace: String, key: String): PluginDocumentSnapshot
    func recordRead(transaction: SqliteTransaction, source: DirectToolCallRef,
        plan: NormalizedOperationPlan, snapshot: PluginDocumentSnapshot): Unit
    func requireParentFence(transaction: SqliteTransaction, parent: OperationId,
        run: RunId, intent: PluginDocumentIntent): Unit
    func compareExchange(transaction: SqliteTransaction, expected: PluginDocumentSnapshot,
        encodedNext: String): PluginDocumentSnapshot
}

class RowJournalCurrent {
    let rows: Array<SqliteRow>
    let events: Array<SqliteRow>
    let nextEvent: Int64
    let chain: String
    let digest: String
    init(rows: Array<SqliteRow>, events: Array<SqliteRow>, nextEvent: Int64) {
        this.rows = rows; this.events = events; this.nextEvent = nextEvent
        var chained = modelPolicySha256Text("axyndra.opaque-row-journal/v1")
        for (event in events) { chained = modelPolicySha256Text(chained + canonicalAgentValue(rowJournalEvent(event))) }
        chain = chained
        digest = modelPolicySha256Text(canonicalAgentValue(objectValue([
            ValueField("rows", rowJournalRows(rows)), ValueField("events", listValue(events.map { row => rowJournalEvent(row) })),
            ValueField("next_event_id", integerValue(nextEvent))])))
    }
}

// This fixed storage dialect hosts the already existing opaque fact/event
// tables. It knows no retain/correct/conflict policy or tool name. Native code
// owns those decisions. No caller can substitute another table, SQL or path.
public class SqliteOpaqueRowJournal <: PluginDocumentStorageBackend {
    private let namespace: String
    private let key: String
    private let workspace: String
    private let settings: String
    private let allocate: (Int64) -> LogicalJsonOwnerReservation
    private let configurationDigest: String
    private let configurationCurrent: () -> Result<Unit>
    private let contextReadConfiguration: ?(NormalizedOperationPlan)->Result<Unit>
    public prop identity: String { get() { "opaque-fact-events-v3:" + namespace + ":" + key } }
    public init(namespace: String, key: String, workspace: String, settings: String,
        allocate: (Int64) -> LogicalJsonOwnerReservation,
        configurationDigest: String, configurationCurrent: () -> Result<Unit>,
        contextReadConfiguration!: ?(NormalizedOperationPlan)->Result<Unit> = None) {
        if (!httpServicePluginNamespace(namespace) || !documentIdentity(ThreadId("journal"), LaneId("main"), namespace, key)) {
            throw IllegalArgumentException("invalid trusted row-journal binding") }
        if(!httpIntentDigest(configurationDigest)){throw IllegalArgumentException("exact trusted configuration digest required")}
        this.namespace = namespace; this.key = key; this.workspace = workspace; this.settings = settings; this.allocate = allocate
        this.configurationDigest=configurationDigest;this.configurationCurrent=configurationCurrent
        this.contextReadConfiguration=contextReadConfiguration
    }
    private func selected(namespace: String, key: String): Unit {
        if (namespace != this.namespace || key != this.key) { throw IllegalStateException("journal binding changed") }
    }
    private func full(transaction: SqliteTransaction): RowJournalCurrent {
        match(configurationCurrent()){case Result.Err(error)=>throw PluginDocumentGuardFailure(error);case Result.Ok(_)=>()}
        // Bound every byte and row before SELECT payload. The lease remains
        // attached to the actual transaction until all consumers and checks end.
        let limits = transaction.query("SELECT (SELECT COUNT(*) FROM memories),(SELECT COUNT(*) FROM memory_events)," +
            "COALESCE((SELECT SUM(length(CAST(payload AS BLOB))) FROM memories),0)+" +
            "COALESCE((SELECT SUM(length(CAST(payload AS BLOB))) FROM memory_events),0)")
        if (limits.size != 1) { throw IllegalStateException("row journal bounds unavailable") }
        let rows = Int64.parse(limits[0].required(0)); let events = Int64.parse(limits[0].required(1))
        let bytes = Int64.parse(limits[0].required(2))
        if (rows < 0 || events < 0 || rows > 4096 || events > 8192 || bytes < 0 || bytes > 16777216) {
            throw PluginDocumentGuardFailure(AgentError(AgentErrorKind.RecoveryRequired,
                "journal.version_readonly", "existing journal exceeds this version's bounded format; history was not changed")) }
        let charge = allocate(max(1, bytes))
        transaction.retainBackendAllocation(charge)
        // SQL already stores the current payload and its latest event.
        // Their raw strings, one canonical hash representation and one
        // projection coexist; reserve those four extents before SELECT.
        charge.ensureRetainedPeak(bytes*4+min(65536,(rows+events)*8)*512+2097152)
        let current = transaction.query("SELECT id,thread_id,kind,payload,revision FROM memories ORDER BY id")
        let history = transaction.query("SELECT id,memory_id,revision,operation,payload,created_at_millis FROM memory_events ORDER BY id")
        let sequences = transaction.query("SELECT seq FROM sqlite_sequence WHERE name='memory_events'")
        if (current.size != rows || history.size != events || sequences.size > 1) { throw IllegalStateException("journal changed within transaction") }
        var nodes: Int64 = (rows + events) * 8
        for (row in current) {
            if (row[1].isSome()) { throw IllegalStateException("journal row has unsupported tenant layout") }
            nodes += logicalJsonNodeCount(row.required(3)); if (nodes > 65536) { throw IllegalStateException("journal decoder bound exceeded") }
        }
        for (row in history) { nodes += logicalJsonNodeCount(row.required(4)); if (nodes > 65536) { throw IllegalStateException("journal decoder bound exceeded") } }
        charge.ensureRetainedPeak(bytes*4+nodes*512+2097152)
        let next = if (sequences.isEmpty()) { 1 } else { Int64.parse(sequences[0].required(0)) + 1 }
        if (next < 1 || next == Int64.Max) { throw IllegalStateException("journal sequence exhausted") }
        RowJournalCurrent(current, history, next)
    }
    private func revision(transaction: SqliteTransaction): Int64 {
        let rows = transaction.query("SELECT revision,payload FROM plugin_documents WHERE thread_id='$row-journal' " +
            "AND lane_id='canonical' AND namespace=? AND document_key=?", [SqlParameter.Text(namespace), SqlParameter.Text(key)])
        if (rows.isEmpty()) { return 1 }
        if (rows.size != 1 || rows[0].required(1) != "opaque-fact-events-v3" || Int64.parse(rows[0].required(0)) < 2) {
            throw IllegalStateException("journal revision metadata changed") }
        Int64.parse(rows[0].required(0))
    }
    private func allowed(payload: String, thread: ThreadId): Bool {
        let event = decodeAgentValue(payload, maxBytes: 8388608).value().getOrThrow()
        let record = event.field("record").getOrThrow()
        let label = httpIntentText(record,"scopeKind"); let value = httpIntentText(record,"scopeKey")
        // Data labels in the fixed imported codec are ACL values, never a
        // business status evaluator or a permission supplied by plugin output.
        if (label == "global") { return value == "" }
        if (label == "user") { return value != "" }
        if (label == "workspace") { return workspace != "" && value == workspace }
        if (label == "session") { return value == thread.value }
        throw IllegalStateException("journal contains an unknown access label")
    }
    private func snapshot(current: RowJournalCurrent, thread: ThreadId, lane: LaneId): AgentValue {
        let visible = HashSet<String>(); let rows = ArrayList<AgentValue>()
        let first = HashMap<String,Int64>()
        for(event in current.events where !first.contains(event.required(1))){first[event.required(1)]=Int64.parse(event.required(0))}
        let ordered=current.rows.clone();var position:Int64=1
        for(row in ordered where !first.contains(row.required(0))){throw IllegalStateException("journal current row has no event history")}
        // Generic event-backed row order preserves the original journal's
        // first appearance without exposing an inaccessible old payload.
        while(position<ordered.size){var index=position
            while(index>0 && first[ordered[index].required(0)]<first[ordered[index-1].required(0)]){
                let saved=ordered[index-1];ordered[index-1]=ordered[index];ordered[index]=saved;index--};position++}
        for (row in ordered where allowed(row.required(3),thread)) {
            visible.add(row.required(0)); rows.add(rowJournalRow(row))
        }
        let events = ArrayList<AgentValue>()
        for (row in current.events where visible.contains(row.required(1)) && allowed(row.required(4),thread)) {
            events.add(rowJournalEvent(row))
        }
        objectValue([ValueField("schema",textValue("axyndra.opaque-row-journal/v1")),ValueField("layout",textValue("opaque-fact-events-v3")),
            ValueField("rows",listValue(rows.toArray())),ValueField("events",listValue(events.toArray())),
            ValueField("journal_chain_sha256",textValue(current.chain)),ValueField("next_event_id",integerValue(current.nextEvent)),
            ValueField("annotations",objectValue([ValueField("workspace_root",textValue(workspace)),ValueField("settings_root",textValue(settings)),
                ValueField("thread_id",textValue(thread.value)),ValueField("lane_id",textValue(lane.value))]))])
    }
    public func read(transaction: SqliteTransaction, thread: ThreadId, lane: LaneId, namespace: String, key: String): PluginDocumentSnapshot {
        selected(namespace,key)
        let current = full(transaction); let raw = encodeAgentValue(snapshot(current,thread,lane))
        if (raw.size > PLUGIN_DOCUMENT_MAX_BYTES) { throw IllegalStateException("journal snapshot exceeds its unchanged document bound") }
        PluginDocumentSnapshot(thread,lane,namespace,key,revision(transaction),raw)
    }
    public func recordRead(transaction: SqliteTransaction, source: DirectToolCallRef,
        plan: NormalizedOperationPlan, observed: PluginDocumentSnapshot): Unit {
        selected(observed.namespace,observed.key)
        requireContextReadExecutingInTransaction(transaction,source,plan)
        let contextRead=pluginDocumentContextReadRequestValid(plan.canonicalArguments)
        if(contextRead){
            let validate=match(contextReadConfiguration){case Some(value)=>value
                case None=>throw IllegalStateException("journal has no exact opt-in context read profile")}
            match(validate(plan)){case Result.Err(error)=>throw PluginDocumentGuardFailure(error);case Result.Ok(_)=>()}
        }else if(httpIntentText(plan.canonicalArguments.field("binding").getOrThrow(),"configuration_digest")!=configurationDigest){
            throw IllegalStateException("journal observation has another exact operator configuration")}
        let lane = if(contextRead){requirePluginDocumentContextReadScope(transaction,source,plan)}
            else{requirePluginDocumentReadScope(transaction,source,plan)}
        if (source.threadId.value != observed.threadId.value || lane.value != observed.laneId.value) {
            throw IllegalStateException("journal read has another actual source") }
        let current = full(transaction)
        if (encodeAgentValue(snapshot(current,source.threadId,lane)) != observed.encoded || revision(transaction) != observed.revision) {
            throw IllegalStateException("journal changed before its read observation") }
        if(contextRead){match(contextReadConfiguration.getOrThrow()(plan)){
            case Result.Err(error)=>throw PluginDocumentGuardFailure(error);case Result.Ok(_)=>()}}
        let value = objectValue([ValueField("schema",textValue("axyndra.row-journal-fence/v1")),
            ValueField("backend",textValue(identity)),ValueField("key",textValue(key)),ValueField("revision",integerValue(observed.revision)),
            ValueField("snapshot_sha256",textValue(modelPolicySha256Text(observed.encoded))),ValueField("full_state_sha256",textValue(current.digest)),
            ValueField("read_plan_sha256",textValue(modelPolicySha256Text(encodeOperationPlan(plan)))),
            ValueField("read_item_id",textValue(source.canonicalItemId.value)),ValueField("epoch",integerValue(source.epoch))])
        let old = transaction.query("SELECT payload FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? " +
            "AND kind='row_journal_observed'",[SqlParameter.Text(source.operationId.value),SqlParameter.Text(source.runId.value),SqlParameter.Text(source.threadId.value)])
        let encoded = encodeStoredValue(value)
        if (old.size > 1 || (old.size == 1 && old[0].required(0) != encoded)) { throw IllegalStateException("journal read fence is ambiguous") }
        if (old.isEmpty()) { transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
            "VALUES(?,?,?,'row_journal_observed',?,?)",[SqlParameter.Text(source.threadId.value),SqlParameter.Text(source.runId.value),
            SqlParameter.Text(source.operationId.value),SqlParameter.Text(encoded),SqlParameter.Int64Value(agentUtcMillis())]) }
    }
    public func requireParentFence(transaction: SqliteTransaction, parent: OperationId, run: RunId, intent: PluginDocumentIntent): Unit {
        let binding = intent.binding(); selected(httpIntentText(binding,"namespace"),intent.key)
        if(httpIntentText(binding,"configuration_digest")!=configurationDigest){
            throw IllegalStateException("journal child has another exact current operator configuration")}
        let parents = transaction.query("SELECT o.normalized_plan,r.thread_id FROM operations o JOIN runs r ON r.id=o.run_id WHERE o.id=? AND o.run_id=?",[SqlParameter.Text(parent.value),SqlParameter.Text(run.value)])
        if (parents.size != 1 || parents[0].required(1) != httpIntentText(binding,"thread_id")) { throw IllegalStateException("journal has no actual canonical parent") }
        let actualThread = parents[0].required(1)
        let plan = decodeOperationPlan(parents[0].required(0)); let input = plan.canonicalArguments.field("input").getOrThrow()
        let envelope = input.field(CONTEXT_READ_INPUT_FIELD).getOrThrow()
        let links = contextReadFactLinksFromValue(envelope.field("facts").getOrThrow())
        if (links.size != 1 || validateContextReadInputProjection(input,links).isError()) { throw IllegalStateException("journal lost its exact read fact") }
        let fact = requireContextReadFact(transaction,links[0].operationId,run)
        requireContextReadFactConsumptionFields(transaction,parent,run,ItemId(fact.origin.parentCallItemId),httpIntentText(binding,"contribution"),links)
        if (fact.runId.value != run.value ||
            canonicalAgentValue(fact.reference()) != canonicalAgentValue(links[0].toValue()) ||
            canonicalAgentValue(fact.output()) != canonicalAgentValue(envelope.field("data").getOrThrow())) {
            throw IllegalStateException("journal source fact changed") }
        let observations = transaction.query("SELECT payload FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? " +
            "AND kind='row_journal_observed'",[SqlParameter.Text(links[0].operationId.value),SqlParameter.Text(run.value),SqlParameter.Text(actualThread)])
        if (observations.size != 1) { throw IllegalStateException("journal source has no unique actual read fence") }
        let witness = decodeStoredValue(observations[0].required(0)); let current = full(transaction)
        let originalRead = transaction.query("SELECT normalized_plan,tool_call_item_id FROM operations WHERE id=? AND run_id=?",
            [SqlParameter.Text(links[0].operationId.value),SqlParameter.Text(run.value)])
        if (originalRead.size != 1 || httpIntentText(witness,"schema") != "axyndra.row-journal-fence/v1" ||
            httpIntentText(witness,"backend") != identity || httpIntentText(witness,"key") != key ||
            integerOrJournal(witness,"revision") != intent.expectedRevision || httpIntentText(witness,"full_state_sha256") != current.digest ||
            httpIntentText(witness,"read_plan_sha256") != modelPolicySha256Text(originalRead[0].required(0)) ||
            httpIntentText(witness,"read_item_id") != originalRead[0].required(1) || integerOrJournal(witness,"epoch") != integerOrJournal(binding,"epoch")) {
            throw IllegalStateException("complete journal rows, revisions, absence or event chain changed") }
        let digest = if (intent.referencesPayload) { intent.expectedPayload.getOrThrow().digest } else { modelPolicySha256Text(intent.expectedJson) }
        if (httpIntentText(witness,"snapshot_sha256") != digest) { throw IllegalStateException("journal parent does not consume its observed bytes") }
    }
    public func compareExchange(transaction: SqliteTransaction, expected: PluginDocumentSnapshot, encodedNext: String): PluginDocumentSnapshot {
        selected(expected.namespace,expected.key)
        if (!transaction.backendCommitAuthorized(namespace,key)) { throw IllegalStateException("journal mutation lacks its actual derived settlement") }
        let before = full(transaction); let beforeValue = snapshot(before,expected.threadId,expected.laneId)
        if (revision(transaction) != expected.revision || encodeAgentValue(beforeValue) != expected.encoded || expected.revision == Int64.Max) {
            throw IllegalStateException("journal CAS lost its exact current bytes") }
        let next = decodeAgentValue(encodedNext,maxBytes:8388608).value().getOrThrow()
        if (!httpIntentExactFields(next,["schema","layout","rows","events","journal_chain_sha256","next_event_id","annotations"]) ||
            httpIntentText(next,"schema") != "axyndra.opaque-row-journal/v1" || httpIntentText(next,"layout") != "opaque-fact-events-v3" ||
            canonicalAgentValue(next.field("annotations").getOrThrow()) != canonicalAgentValue(beforeValue.field("annotations").getOrThrow())) {
            throw IllegalStateException("journal replacement layout or data scope changed") }
        let oldEvents = beforeValue.field("events").getOrThrow().items; let events = next.field("events").getOrThrow().items
        if (events.size <= oldEvents.size || events.size - oldEvents.size > 128) { throw IllegalStateException("journal must append a bounded nonempty event batch") }
        for (index in 0..oldEvents.size where canonicalAgentValue(events[index]) != canonicalAgentValue(oldEvents[index])) {
            throw IllegalStateException("journal history prefix changed") }
        let expectedRows = ArrayList<SqliteRow>(before.rows); let expectedEvents = ArrayList<SqliteRow>(before.events)
        var eventId = before.nextEvent
        for (index in oldEvents.size..events.size) {
            let event = events[index]
            if (!httpIntentExactFields(event,["id","key","revision","operation","payload","created_at_millis"]) ||
                integerOrJournal(event,"id") != eventId || integerOrJournal(event,"revision") < 1 ||
                integerOrJournal(event,"created_at_millis") < 1 || httpIntentText(event,"key") == "" ||
                httpIntentText(event,"key").size > 1024 || httpIntentText(event,"operation") == "" || httpIntentText(event,"operation").size > 128) {
                throw IllegalStateException("journal append metadata is not exact") }
            let payload = httpIntentText(event,"payload"); let decoded = decodeAgentValue(payload,maxBytes:8388608).value().getOrThrow()
            let row = decoded.field("record").getOrThrow(); let id = httpIntentText(event,"key"); let revision = integerOrJournal(event,"revision")
            if (httpIntentText(row,"id") != id || integerOrJournal(row,"revision") != revision ||
                httpIntentText(decoded,"operation") != httpIntentText(event,"operation") || !allowed(payload,expected.threadId)) {
                throw IllegalStateException("journal row metadata or actual-thread data ACL differs from its event") }
            var existing: ?SqliteRow = None; var position: Int64 = -1
            for (at in 0..expectedRows.size where expectedRows[at].required(0) == id) { existing = Some(expectedRows[at]); position = at }
            if ((existing.isNone() && revision != 1) || (existing.isSome() &&
                (Int64.parse(existing.getOrThrow().required(4)) == Int64.Max || revision != Int64.parse(existing.getOrThrow().required(4)) + 1 ||
                    !allowed(existing.getOrThrow().required(3),expected.threadId)))) { throw IllegalStateException("journal row revision or absence changed") }
            let kind = httpIntentText(row,"kind"); if (kind == "" || kind.size > 128) { throw IllegalStateException("journal index value invalid") }
            transaction.execute("INSERT INTO memory_events(id,memory_id,revision,operation,payload,created_at_millis) VALUES(?,?,?,?,?,?)",
                [SqlParameter.Int64Value(eventId),SqlParameter.Text(id),SqlParameter.Int64Value(revision),SqlParameter.Text(httpIntentText(event,"operation")),
                    SqlParameter.Text(payload),SqlParameter.Int64Value(integerOrJournal(event,"created_at_millis"))])
            if (existing.isNone()) { transaction.execute("INSERT INTO memories(id,thread_id,kind,payload,revision) VALUES(?,NULL,?,?,?)",
                [SqlParameter.Text(id),SqlParameter.Text(kind),SqlParameter.Text(payload),SqlParameter.Int64Value(revision)]) }
            else { transaction.execute("UPDATE memories SET kind=?,payload=?,revision=? WHERE id=? AND revision=? AND payload=? AND thread_id IS NULL",
                [SqlParameter.Text(kind),SqlParameter.Text(payload),SqlParameter.Int64Value(revision),SqlParameter.Text(id),
                    SqlParameter.Int64Value(revision-1),SqlParameter.Text(existing.getOrThrow().required(3))]); requireStoreChanged(transaction,"journal row CAS changed") }
            let updated = SqliteRow([Some(id),None,Some(kind),Some(payload),Some(revision.toString())])
            if (position < 0) { expectedRows.add(updated) } else { expectedRows[position] = updated }
            expectedEvents.add(SqliteRow([Some(eventId.toString()),Some(id),Some(revision.toString()),Some(httpIntentText(event,"operation")),
                Some(payload),Some(integerOrJournal(event,"created_at_millis").toString())])); eventId++
        }
        // Sort only the storage index, never a business retrieval/ranking.
        let sortedRows = expectedRows.toArray(); var at: Int64 = 1
        while (at < sortedRows.size) { var index = at
            while (index > 0 && sortedRows[index].required(0) < sortedRows[index-1].required(0)) {
                let previous = sortedRows[index-1]; sortedRows[index-1] = sortedRows[index]; sortedRows[index] = previous; index-- }; at++ }
        let resulting = RowJournalCurrent(sortedRows,expectedEvents.toArray(),eventId)
        if (encodeAgentValue(snapshot(resulting,expected.threadId,expected.laneId)) != encodedNext) {
            throw IllegalStateException("journal proposal omitted, reordered or invented resulting rows") }
        transaction.execute("INSERT INTO plugin_documents(thread_id,lane_id,namespace,document_key,revision,payload) " +
            "VALUES('$row-journal','canonical',?,?,?,'opaque-fact-events-v3') ON CONFLICT(thread_id,lane_id,namespace,document_key) DO UPDATE SET revision=excluded.revision",
            [SqlParameter.Text(namespace),SqlParameter.Text(key),SqlParameter.Int64Value(expected.revision+1)])
        let expectedDigest = resulting.digest
        let expectedRevision = expected.revision+1
        transaction.retainBackendPostCheck({ =>
            if (full(transaction).digest != expectedDigest || revision(transaction) != expectedRevision) {
                throw IllegalStateException("journal rows, event history or metadata changed before Receipt commit") } })
        if (full(transaction).digest != expectedDigest) { throw IllegalStateException("journal commit trigger changed an unrelated row") }
        PluginDocumentSnapshot(expected.threadId,expected.laneId,namespace,key,expected.revision+1,encodedNext)
    }
}

func integerOrJournal(value: AgentValue, name: String): Int64 {
    let field = value.field(name).getOrThrow()
    if (field.unifiedKind != ValueKind.Number) { throw IllegalStateException("journal integer required") }
    let parsed = Int64.parse(field.asNumberText())
    if (parsed.toString() != field.asNumberText()) { throw IllegalStateException("canonical journal integer required") }; parsed
}
func rowJournalRow(row: SqliteRow): AgentValue {
    objectValue([ValueField("key",textValue(row.required(0))),ValueField("kind",textValue(row.required(2))),
        ValueField("payload_sha256",textValue(modelPolicySha256Text(row.required(3)))),ValueField("revision",integerValue(Int64.parse(row.required(4))))])
}
func rowJournalEvent(row: SqliteRow): AgentValue {
    objectValue([ValueField("id",integerValue(Int64.parse(row.required(0)))),ValueField("key",textValue(row.required(1))),
        ValueField("revision",integerValue(Int64.parse(row.required(2)))),ValueField("operation",textValue(row.required(3))),
        ValueField("payload",textValue(row.required(4))),ValueField("created_at_millis",integerValue(Int64.parse(row.required(5))))])
}
func rowJournalRows(rows: Array<SqliteRow>): AgentValue { listValue(rows.map { row => rowJournalRow(row) }) }


// Trusted fixed document SQL only. The default repository executes precisely
// its original SQL. Only an assembly-registered logical key opts in.
func queryPluginDocumentRows(transaction: SqliteTransaction, sql: String,
    parameters: Array<SqlParameter>): Array<SqliteRow> {
    if (parameters.size != 4) { throw IllegalStateException("document address must be exact") }
    let text={ value: SqlParameter => match(value){case SqlParameter.Text(item)=>item
        case _=>throw IllegalStateException("document address must contain exact text fields")} }
    let thread=ThreadId(text(parameters[0]));let lane=LaneId(text(parameters[1]));let namespace=text(parameters[2]);let key=text(parameters[3])
    let selected=transaction.documentStorageBackend(namespace,key)
    if(selected.isNone()){return transaction.query(sql,parameters)}
    let current=selected.getOrThrow().read(transaction,thread,lane,namespace,key)
    let raw=current.encoded;let revision=current.revision.toString();let bytes=raw.size.toString()
    let columns=if(sql.startsWith("SELECT ") && sql.contains(" FROM plugin_documents ")){
        sql[7..sql.indexOf(" FROM plugin_documents ").getOrThrow()]
    }else{throw IllegalStateException("unsupported trusted document backend query")}
    match(columns){
        case "revision,payload"=>[SqliteRow([Some(revision),Some(raw)])]
        case "length(CAST(payload AS BLOB)),revision"=>[SqliteRow([Some(bytes),Some(revision)])]
        case "revision,payload,length(CAST(payload AS BLOB))"=>[SqliteRow([Some(revision),Some(raw),Some(bytes)])]
        case "revision,length(CAST(payload AS BLOB))"=>[SqliteRow([Some(revision),Some(bytes)])]
        case _=>throw IllegalStateException("unsupported trusted document backend columns")}
}
