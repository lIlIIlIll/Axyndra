package agent_store

func v1Schema(): Array<String> {
    [
        "CREATE TABLE threads (id TEXT PRIMARY KEY, revision INTEGER NOT NULL, workspace_id TEXT NOT NULL, status TEXT NOT NULL, next_item_ordinal INTEGER NOT NULL, active_turn_id TEXT)",
        "CREATE TABLE turns (id TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL, state TEXT NOT NULL, user_item_id TEXT NOT NULL, active_run_id TEXT, UNIQUE(thread_id, ordinal))",
        "CREATE TABLE items (id TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE, turn_id TEXT NOT NULL REFERENCES turns(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL, provenance TEXT NOT NULL, created_at_millis INTEGER NOT NULL, UNIQUE(thread_id, ordinal))",
        "CREATE TABLE runs (id TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE, turn_id TEXT NOT NULL REFERENCES turns(id) ON DELETE CASCADE, epoch INTEGER NOT NULL, state TEXT NOT NULL, lane_snapshot TEXT NOT NULL, skill_snapshot TEXT NOT NULL, budget TEXT NOT NULL, usage TEXT NOT NULL, started_at_millis INTEGER NOT NULL, finished_at_millis INTEGER, cancellation_reason TEXT, app_snapshot TEXT, continuation TEXT)",
        "CREATE TABLE run_journal (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE, sequence INTEGER NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL, created_at_millis INTEGER NOT NULL, UNIQUE(run_id, sequence))",
        "CREATE TABLE app_run_events (run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE, sequence INTEGER NOT NULL, sequence_start INTEGER NOT NULL, sequence_end INTEGER NOT NULL, payload TEXT NOT NULL, accounting INTEGER NOT NULL, event_class TEXT NOT NULL, stream_key TEXT NOT NULL, delta_count INTEGER NOT NULL, char_count INTEGER NOT NULL, created_at_millis INTEGER NOT NULL, PRIMARY KEY(run_id, sequence))",
        "CREATE TABLE app_run_event_heads (run_id TEXT PRIMARY KEY REFERENCES runs(id) ON DELETE CASCADE, last_sequence INTEGER NOT NULL)",
        "CREATE TABLE approval_decisions (operation_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE, payload TEXT NOT NULL, created_at_millis INTEGER NOT NULL)",
        "CREATE TABLE tool_operation_intents (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, state TEXT NOT NULL, payload TEXT NOT NULL, revision INTEGER NOT NULL)",
        "CREATE TABLE tool_operation_intent_receipts (operation_id TEXT PRIMARY KEY REFERENCES tool_operation_intents(id) ON DELETE CASCADE, payload TEXT NOT NULL, created_at_millis INTEGER NOT NULL)",
        "CREATE TABLE session_permission_grants (thread_id TEXT NOT NULL, digest TEXT NOT NULL, payload TEXT NOT NULL, created_at_millis INTEGER NOT NULL, PRIMARY KEY(thread_id,digest))",
        "CREATE TABLE thread_metadata (thread_id TEXT PRIMARY KEY, name TEXT NOT NULL, summary TEXT NOT NULL, updated_at_millis INTEGER NOT NULL, model TEXT NOT NULL, workspace_root TEXT NOT NULL, cwd TEXT NOT NULL, fast_mode INTEGER NOT NULL, parent_thread_ref TEXT NOT NULL, work_mode TEXT NOT NULL, draft TEXT NOT NULL, todo_payload TEXT NOT NULL, goal_payload TEXT NOT NULL)",
        "CREATE TABLE run_model_usage (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE, request_sequence INTEGER NOT NULL, role TEXT NOT NULL, estimated_input_tokens INTEGER NOT NULL, actual_input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL, reasoning_tokens INTEGER NOT NULL, cache_read_tokens INTEGER NOT NULL, cache_write_tokens INTEGER NOT NULL, cost_micros INTEGER, created_at_millis INTEGER NOT NULL, UNIQUE(run_id, request_sequence))",
        "CREATE TABLE model_attempts (id TEXT PRIMARY KEY, semantic_request_id TEXT NOT NULL, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE, parent_attempt_id TEXT REFERENCES model_attempts(id), attempt_no INTEGER NOT NULL, lifecycle TEXT NOT NULL, policy TEXT NOT NULL, policy_reason TEXT NOT NULL, started_at_millis INTEGER NOT NULL, last_activity_at_millis INTEGER NOT NULL, completed_at_millis INTEGER, provider_request_id TEXT NOT NULL, provider_response_id TEXT NOT NULL, failure_kind TEXT NOT NULL, semantic_request_digest TEXT NOT NULL, wire_policy_digest TEXT NOT NULL, dispatch_state TEXT NOT NULL, replay_barrier TEXT NOT NULL, dispatch_started_at_millis INTEGER, provider_terminal_at_millis INTEGER, UNIQUE(semantic_request_id,attempt_no))",
        "CREATE TABLE model_decisions (id TEXT PRIMARY KEY, attempt_id TEXT NOT NULL UNIQUE REFERENCES model_attempts(id) ON DELETE CASCADE, semantic_request_id TEXT NOT NULL, validation_status TEXT NOT NULL, completion_disposition TEXT NOT NULL, decision_outcome TEXT NOT NULL, content_hash TEXT NOT NULL, replay_hash TEXT NOT NULL, provider_id TEXT NOT NULL, provider_response_id TEXT NOT NULL, terminal_evidence TEXT NOT NULL, validator_version INTEGER NOT NULL, created_at_millis INTEGER NOT NULL, canonical_committed_at_millis INTEGER)",
        "CREATE TABLE model_decision_blocks (id TEXT PRIMARY KEY, decision_id TEXT NOT NULL REFERENCES model_decisions(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL, scoped_tool_call_id TEXT, UNIQUE(decision_id,ordinal), UNIQUE(decision_id,scoped_tool_call_id))",
        "CREATE TABLE model_decision_usage (decision_id TEXT PRIMARY KEY REFERENCES model_decisions(id) ON DELETE CASCADE, payload TEXT NOT NULL, finalized_at_millis INTEGER NOT NULL)",
        "CREATE TABLE canonical_decision_items (decision_id TEXT NOT NULL REFERENCES model_decisions(id) ON DELETE CASCADE, decision_block_id TEXT NOT NULL UNIQUE REFERENCES model_decision_blocks(id) ON DELETE CASCADE, item_id TEXT NOT NULL UNIQUE REFERENCES items(id) ON DELETE CASCADE, PRIMARY KEY(decision_id,decision_block_id))",
        "CREATE TABLE decision_operations (decision_id TEXT NOT NULL REFERENCES model_decisions(id) ON DELETE CASCADE, scoped_tool_call_id TEXT NOT NULL, operation_id TEXT NOT NULL UNIQUE REFERENCES operations(id) ON DELETE CASCADE, PRIMARY KEY(decision_id,scoped_tool_call_id))",
        "CREATE TABLE operations (id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE, tool_call_item_id TEXT NOT NULL REFERENCES items(id), normalized_plan TEXT NOT NULL, capability_requirement TEXT NOT NULL, resource_scope TEXT NOT NULL, effect_class TEXT NOT NULL, retry_disposition TEXT NOT NULL, idempotency_key TEXT, state TEXT NOT NULL, revision INTEGER NOT NULL)",
        "CREATE TABLE operation_receipts (id TEXT PRIMARY KEY, operation_id TEXT NOT NULL UNIQUE REFERENCES operations(id) ON DELETE CASCADE, outcome TEXT NOT NULL, detail TEXT NOT NULL, verification TEXT NOT NULL, created_at_millis INTEGER NOT NULL)",
        "CREATE TABLE approvals (id TEXT PRIMARY KEY, operation_id TEXT NOT NULL REFERENCES operations(id) ON DELETE CASCADE, operation_digest TEXT NOT NULL, capability_ceiling TEXT NOT NULL, decision TEXT NOT NULL, source TEXT NOT NULL, expires_at_millis INTEGER)",
        "CREATE TABLE capability_grants (id TEXT PRIMARY KEY, thread_id TEXT REFERENCES threads(id) ON DELETE CASCADE, payload TEXT NOT NULL, expires_at_millis INTEGER)",
        "CREATE TABLE audit_events (id INTEGER PRIMARY KEY AUTOINCREMENT, thread_id TEXT, run_id TEXT, operation_id TEXT, kind TEXT NOT NULL, payload TEXT NOT NULL, created_at_millis INTEGER NOT NULL, commit_sequence INTEGER NOT NULL DEFAULT 0)",
        "CREATE TABLE context_checkpoints (id TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE, covers_through_item_ordinal INTEGER NOT NULL, projector_version TEXT NOT NULL, lane_compatibility TEXT NOT NULL, source_digest TEXT NOT NULL, payload TEXT NOT NULL, created_at_millis INTEGER NOT NULL)",
        "CREATE TABLE memories (id TEXT PRIMARY KEY, thread_id TEXT REFERENCES threads(id) ON DELETE CASCADE, kind TEXT NOT NULL, payload TEXT NOT NULL, revision INTEGER NOT NULL)",
        "CREATE TABLE memory_events (id INTEGER PRIMARY KEY AUTOINCREMENT, memory_id TEXT NOT NULL, revision INTEGER NOT NULL, operation TEXT NOT NULL, payload TEXT NOT NULL, created_at_millis INTEGER NOT NULL, UNIQUE(memory_id,revision))",
        "CREATE TABLE task_snapshots (root_thread_id TEXT PRIMARY KEY, revision INTEGER NOT NULL, payload TEXT NOT NULL, updated_at_millis INTEGER NOT NULL)",
        "CREATE TABLE artifacts (hash TEXT PRIMARY KEY, mime TEXT NOT NULL, size INTEGER NOT NULL, metadata TEXT NOT NULL, relative_path TEXT NOT NULL)",
        "CREATE TABLE thread_commit_heads (thread_id TEXT PRIMARY KEY REFERENCES threads(id) ON DELETE CASCADE, last_sequence INTEGER NOT NULL)",
        "CREATE TABLE run_continuations (run_id TEXT PRIMARY KEY REFERENCES runs(id) ON DELETE CASCADE, schema_version INTEGER NOT NULL, revision INTEGER NOT NULL, phase TEXT NOT NULL, payload TEXT NOT NULL, digest TEXT NOT NULL, updated_commit_sequence INTEGER NOT NULL)",
        "CREATE TABLE run_continuation_facts (run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE, thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE, revision INTEGER NOT NULL, commit_sequence INTEGER NOT NULL, phase TEXT NOT NULL, payload TEXT NOT NULL, digest TEXT NOT NULL, created_at_millis INTEGER NOT NULL, PRIMARY KEY(run_id,revision), UNIQUE(thread_id,commit_sequence))",
        "CREATE TABLE app_event_outbox (event_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE, commit_sequence INTEGER NOT NULL, ordinal INTEGER NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL, created_at_millis INTEGER NOT NULL, published INTEGER NOT NULL DEFAULT 0, UNIQUE(thread_id,commit_sequence,ordinal))",
        "CREATE TABLE operation_effect_records (operation_id TEXT PRIMARY KEY REFERENCES operations(id) ON DELETE CASCADE, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE, tool_call_item_id TEXT NOT NULL REFERENCES items(id), normalized_plan TEXT NOT NULL, tool_id TEXT NOT NULL, tool_version TEXT NOT NULL, implementation_fingerprint TEXT NOT NULL, schema_digest TEXT NOT NULL, effective_arguments_digest TEXT NOT NULL, replay_contract_version INTEGER NOT NULL, replay_disposition TEXT NOT NULL, reserved_receipt_id TEXT NOT NULL UNIQUE, reserved_result_item_id TEXT NOT NULL UNIQUE, created_at_millis INTEGER NOT NULL)",
        "CREATE TABLE operation_state_registers (operation_id TEXT PRIMARY KEY REFERENCES operation_effect_records(operation_id) ON DELETE CASCADE, state TEXT NOT NULL, revision INTEGER NOT NULL)",
        "CREATE TABLE lane_inbox_entries (id TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE, lane_id TEXT NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL, status TEXT NOT NULL, created_at_millis INTEGER NOT NULL, claimed_step_id TEXT, revision INTEGER NOT NULL)",
        "CREATE TABLE step_records (id TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE, lane_id TEXT NOT NULL, turn_id TEXT NOT NULL REFERENCES turns(id) ON DELETE CASCADE, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL, input_entry_id TEXT UNIQUE REFERENCES lane_inbox_entries(id), accepted_item_id TEXT UNIQUE REFERENCES items(id), status TEXT NOT NULL, opened_at_millis INTEGER NOT NULL, settled_at_millis INTEGER, revision INTEGER NOT NULL, UNIQUE(run_id,ordinal))",
        "CREATE TABLE prompt_contribution_artifacts (hash TEXT PRIMARY KEY, content TEXT NOT NULL, created_at_millis INTEGER NOT NULL)",
        "CREATE TABLE context_manifests (id TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE, lane_id TEXT NOT NULL, turn_id TEXT NOT NULL REFERENCES turns(id) ON DELETE CASCADE, step_id TEXT NOT NULL REFERENCES step_records(id) ON DELETE CASCADE, digest TEXT NOT NULL, payload TEXT NOT NULL, created_at_millis INTEGER NOT NULL)",
        "CREATE TABLE lanes (thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE, lane_id TEXT NOT NULL, kind TEXT NOT NULL, parent_lane_id TEXT, fork_item_id TEXT REFERENCES items(id), config TEXT NOT NULL, status TEXT NOT NULL, created_at_millis INTEGER NOT NULL, PRIMARY KEY(thread_id,lane_id), FOREIGN KEY(thread_id,parent_lane_id) REFERENCES lanes(thread_id,lane_id))",
        "CREATE TABLE item_tree_edges (item_id TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE, thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE, lane_id TEXT NOT NULL, parent_item_id TEXT REFERENCES items(id), depth INTEGER NOT NULL, FOREIGN KEY(thread_id,lane_id) REFERENCES lanes(thread_id,lane_id))",
        "CREATE TABLE run_lane_bindings (run_id TEXT PRIMARY KEY REFERENCES runs(id) ON DELETE CASCADE, thread_id TEXT NOT NULL, lane_id TEXT NOT NULL, FOREIGN KEY(thread_id,lane_id) REFERENCES lanes(thread_id,lane_id))",
        "CREATE TABLE composition_snapshots (id TEXT PRIMARY KEY, digest TEXT NOT NULL, payload TEXT NOT NULL, created_at_millis INTEGER NOT NULL)",
        "CREATE TABLE run_composition_bindings (run_id TEXT PRIMARY KEY REFERENCES runs(id) ON DELETE CASCADE, snapshot_id TEXT NOT NULL REFERENCES composition_snapshots(id))",
        "CREATE TABLE teams (id TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE, coordinator_lane_id TEXT NOT NULL, title TEXT NOT NULL, status TEXT NOT NULL, created_at_millis INTEGER NOT NULL, revision INTEGER NOT NULL, FOREIGN KEY(thread_id,coordinator_lane_id) REFERENCES lanes(thread_id,lane_id))",
        "CREATE TABLE team_members (team_id TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE, member_id TEXT NOT NULL, thread_id TEXT NOT NULL, lane_id TEXT NOT NULL, role TEXT NOT NULL, status TEXT NOT NULL, joined_at_millis INTEGER NOT NULL, PRIMARY KEY(team_id,member_id), UNIQUE(team_id,lane_id), FOREIGN KEY(thread_id,lane_id) REFERENCES lanes(thread_id,lane_id))",
        "CREATE TABLE team_tasks (id TEXT PRIMARY KEY, team_id TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE, title TEXT NOT NULL, payload TEXT NOT NULL, status TEXT NOT NULL, assignee_member_id TEXT, item_reference TEXT REFERENCES items(id), work_debt_id TEXT NOT NULL, revision INTEGER NOT NULL, created_at_millis INTEGER NOT NULL, updated_at_millis INTEGER NOT NULL, FOREIGN KEY(team_id,assignee_member_id) REFERENCES team_members(team_id,member_id))",
        "CREATE TABLE team_messages (id TEXT PRIMARY KEY, team_id TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE, sender_member_id TEXT NOT NULL, recipient_member_id TEXT NOT NULL, item_reference TEXT REFERENCES items(id), payload TEXT NOT NULL, created_at_millis INTEGER NOT NULL, acknowledged INTEGER NOT NULL, revision INTEGER NOT NULL, FOREIGN KEY(team_id,sender_member_id) REFERENCES team_members(team_id,member_id), FOREIGN KEY(team_id,recipient_member_id) REFERENCES team_members(team_id,member_id))",
        "CREATE INDEX turns_thread_ordinal ON turns(thread_id, ordinal)",
        "CREATE INDEX items_thread_ordinal ON items(thread_id, ordinal)",
        "CREATE INDEX runs_thread_turn ON runs(thread_id, turn_id)",
        "CREATE INDEX app_run_events_run ON app_run_events(run_id, sequence)",
        "CREATE INDEX app_run_events_class ON app_run_events(run_id,event_class,sequence)",
        "CREATE INDEX approval_decisions_run ON approval_decisions(run_id)",
        "CREATE INDEX tool_operation_intents_run ON tool_operation_intents(run_id)",
        "CREATE INDEX operations_run ON operations(run_id)",
        "CREATE INDEX run_model_usage_run ON run_model_usage(run_id, request_sequence)",
        "CREATE INDEX operations_tool_call ON operations(tool_call_item_id)",
        "CREATE INDEX model_attempts_run ON model_attempts(run_id,attempt_no)",
        "CREATE INDEX model_decisions_request ON model_decisions(semantic_request_id)",
        "CREATE INDEX audit_thread_id ON audit_events(thread_id, id)",
        "CREATE INDEX checkpoints_thread_cover ON context_checkpoints(thread_id, covers_through_item_ordinal DESC)",
        "CREATE INDEX memory_events_memory ON memory_events(memory_id, revision)",
        "CREATE INDEX run_continuation_facts_thread ON run_continuation_facts(thread_id,commit_sequence)",
        "CREATE INDEX app_event_outbox_pending ON app_event_outbox(thread_id,published,commit_sequence,ordinal)",
        "CREATE INDEX lane_inbox_queue ON lane_inbox_entries(thread_id,lane_id,status,created_at_millis,id)",
        "CREATE INDEX step_records_run ON step_records(run_id,ordinal)"
        ,"CREATE INDEX team_tasks_board ON team_tasks(team_id,status,created_at_millis,id)"
        ,"CREATE INDEX team_messages_mailbox ON team_messages(team_id,recipient_member_id,acknowledged,created_at_millis,id)"
        ,"CREATE TRIGGER threads_create_main_lane AFTER INSERT ON threads BEGIN INSERT INTO lanes(thread_id,lane_id,kind,parent_lane_id,fork_item_id,config,status,created_at_millis) VALUES (NEW.id,'main','main',NULL,NULL,'o1:0','open',0); END"
        ,"CREATE TRIGGER items_create_main_edge AFTER INSERT ON items BEGIN INSERT INTO item_tree_edges(item_id,thread_id,lane_id,parent_item_id,depth) VALUES (NEW.id,NEW.thread_id,'main',(SELECT id FROM items WHERE thread_id=NEW.thread_id AND ordinal<NEW.ordinal ORDER BY ordinal DESC LIMIT 1),COALESCE((SELECT edge.depth+1 FROM item_tree_edges edge JOIN items prior ON prior.id=edge.item_id WHERE prior.thread_id=NEW.thread_id AND prior.ordinal<NEW.ordinal ORDER BY prior.ordinal DESC LIMIT 1),0)); END"
        ,"CREATE TRIGGER runs_bind_main_lane AFTER INSERT ON runs BEGIN INSERT INTO run_lane_bindings(run_id,thread_id,lane_id) VALUES (NEW.id,NEW.thread_id,'main'); END"
    ]
}

func v2Migration(): Array<String> {
    [
        "ALTER TABLE runs ADD COLUMN app_snapshot TEXT",
        "ALTER TABLE runs ADD COLUMN continuation TEXT",
        "CREATE TABLE app_run_events (run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE, sequence INTEGER NOT NULL, payload TEXT NOT NULL, accounting INTEGER NOT NULL, created_at_millis INTEGER NOT NULL, PRIMARY KEY(run_id, sequence))",
        "CREATE TABLE approval_decisions (operation_id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE, payload TEXT NOT NULL, created_at_millis INTEGER NOT NULL)",
        "CREATE INDEX app_run_events_run ON app_run_events(run_id, sequence)",
        "CREATE INDEX approval_decisions_run ON approval_decisions(run_id)"
    ]
}

func v3Migration(): Array<String> {
    [
        "CREATE TABLE tool_operation_intents (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, state TEXT NOT NULL, payload TEXT NOT NULL, revision INTEGER NOT NULL)",
        "CREATE TABLE tool_operation_intent_receipts (operation_id TEXT PRIMARY KEY REFERENCES tool_operation_intents(id) ON DELETE CASCADE, payload TEXT NOT NULL, created_at_millis INTEGER NOT NULL)",
        "CREATE TABLE session_permission_grants (thread_id TEXT NOT NULL, digest TEXT NOT NULL, payload TEXT NOT NULL, created_at_millis INTEGER NOT NULL, PRIMARY KEY(thread_id,digest))",
        "CREATE INDEX tool_operation_intents_run ON tool_operation_intents(run_id)"
    ]
}

func v4Migration(): Array<String> {
    [
        "CREATE TABLE thread_metadata (thread_id TEXT PRIMARY KEY, name TEXT NOT NULL, summary TEXT NOT NULL, updated_at_millis INTEGER NOT NULL, model TEXT NOT NULL, workspace_root TEXT NOT NULL, cwd TEXT NOT NULL, fast_mode INTEGER NOT NULL, parent_thread_ref TEXT NOT NULL, work_mode TEXT NOT NULL, draft TEXT NOT NULL, todo_payload TEXT NOT NULL, goal_payload TEXT NOT NULL)"
    ]
}

func v5Migration(): Array<String> {
    [
        "CREATE TABLE memory_events (id INTEGER PRIMARY KEY AUTOINCREMENT, memory_id TEXT NOT NULL, revision INTEGER NOT NULL, operation TEXT NOT NULL, payload TEXT NOT NULL, created_at_millis INTEGER NOT NULL, UNIQUE(memory_id,revision))",
        "CREATE INDEX memory_events_memory ON memory_events(memory_id, revision)"
    ]
}

func v6Migration(): Array<String> {
    [
        "CREATE TABLE task_snapshots (root_thread_id TEXT PRIMARY KEY, revision INTEGER NOT NULL, payload TEXT NOT NULL, updated_at_millis INTEGER NOT NULL)"
    ]
}

func v7Migration(): Array<String> {
    [
        "CREATE TABLE model_attempts (id TEXT PRIMARY KEY, semantic_request_id TEXT NOT NULL, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE, parent_attempt_id TEXT REFERENCES model_attempts(id), attempt_no INTEGER NOT NULL, lifecycle TEXT NOT NULL, policy TEXT NOT NULL, policy_reason TEXT NOT NULL, started_at_millis INTEGER NOT NULL, last_activity_at_millis INTEGER NOT NULL, completed_at_millis INTEGER, provider_request_id TEXT NOT NULL, provider_response_id TEXT NOT NULL, failure_kind TEXT NOT NULL, UNIQUE(semantic_request_id,attempt_no))",
        "CREATE TABLE model_decisions (id TEXT PRIMARY KEY, attempt_id TEXT NOT NULL UNIQUE REFERENCES model_attempts(id) ON DELETE CASCADE, semantic_request_id TEXT NOT NULL, validation_status TEXT NOT NULL, completion_disposition TEXT NOT NULL, decision_outcome TEXT NOT NULL, content_hash TEXT NOT NULL, replay_hash TEXT NOT NULL, provider_id TEXT NOT NULL, provider_response_id TEXT NOT NULL, terminal_evidence TEXT NOT NULL, validator_version INTEGER NOT NULL, created_at_millis INTEGER NOT NULL, canonical_committed_at_millis INTEGER)",
        "CREATE TABLE model_decision_blocks (id TEXT PRIMARY KEY, decision_id TEXT NOT NULL REFERENCES model_decisions(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL, scoped_tool_call_id TEXT, UNIQUE(decision_id,ordinal), UNIQUE(decision_id,scoped_tool_call_id))",
        "CREATE TABLE model_decision_usage (decision_id TEXT PRIMARY KEY REFERENCES model_decisions(id) ON DELETE CASCADE, payload TEXT NOT NULL, finalized_at_millis INTEGER NOT NULL)",
        "CREATE TABLE canonical_decision_items (decision_id TEXT NOT NULL REFERENCES model_decisions(id) ON DELETE CASCADE, decision_block_id TEXT NOT NULL UNIQUE REFERENCES model_decision_blocks(id) ON DELETE CASCADE, item_id TEXT NOT NULL UNIQUE REFERENCES items(id) ON DELETE CASCADE, PRIMARY KEY(decision_id,decision_block_id))",
        "CREATE TABLE decision_operations (decision_id TEXT NOT NULL REFERENCES model_decisions(id) ON DELETE CASCADE, scoped_tool_call_id TEXT NOT NULL, operation_id TEXT NOT NULL UNIQUE REFERENCES operations(id) ON DELETE CASCADE, PRIMARY KEY(decision_id,scoped_tool_call_id))",
        "CREATE INDEX model_attempts_run ON model_attempts(run_id,attempt_no)",
        "CREATE INDEX model_decisions_request ON model_decisions(semantic_request_id)"
    ]
}

func v8Migration(): Array<String> {
    [
        "ALTER TABLE app_run_events ADD COLUMN sequence_start INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE app_run_events ADD COLUMN sequence_end INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE app_run_events ADD COLUMN event_class TEXT NOT NULL DEFAULT 'lifecycle'",
        "ALTER TABLE app_run_events ADD COLUMN stream_key TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE app_run_events ADD COLUMN delta_count INTEGER NOT NULL DEFAULT 1",
        "ALTER TABLE app_run_events ADD COLUMN char_count INTEGER NOT NULL DEFAULT 0",
        "UPDATE app_run_events SET sequence_start=sequence,sequence_end=sequence WHERE sequence_start=0 OR sequence_end=0",
        "CREATE TABLE app_run_event_heads (run_id TEXT PRIMARY KEY REFERENCES runs(id) ON DELETE CASCADE, last_sequence INTEGER NOT NULL)",
        "INSERT INTO app_run_event_heads(run_id,last_sequence) SELECT run_id,MAX(sequence) FROM app_run_events GROUP BY run_id",
        "CREATE INDEX app_run_events_class ON app_run_events(run_id,event_class,sequence)"
    ]
}

func v9Migration(): Array<String> {
    [
        "ALTER TABLE model_attempts ADD COLUMN semantic_request_digest TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE model_attempts ADD COLUMN wire_policy_digest TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE model_attempts ADD COLUMN dispatch_state TEXT NOT NULL DEFAULT 'dispatch_claimed'",
        "ALTER TABLE model_attempts ADD COLUMN replay_barrier TEXT NOT NULL DEFAULT 'none'",
        "ALTER TABLE model_attempts ADD COLUMN dispatch_started_at_millis INTEGER",
        "ALTER TABLE model_attempts ADD COLUMN provider_terminal_at_millis INTEGER"
    ]
}

func v10Migration(): Array<String> {
    [
        "ALTER TABLE audit_events ADD COLUMN commit_sequence INTEGER NOT NULL DEFAULT 0",
        "CREATE TABLE thread_commit_heads (thread_id TEXT PRIMARY KEY REFERENCES threads(id) ON DELETE CASCADE, last_sequence INTEGER NOT NULL)",
        "CREATE TABLE run_continuations (run_id TEXT PRIMARY KEY REFERENCES runs(id) ON DELETE CASCADE, schema_version INTEGER NOT NULL, revision INTEGER NOT NULL, phase TEXT NOT NULL, payload TEXT NOT NULL, digest TEXT NOT NULL, updated_commit_sequence INTEGER NOT NULL)",
        "CREATE TABLE run_continuation_facts (run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE, thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE, revision INTEGER NOT NULL, commit_sequence INTEGER NOT NULL, phase TEXT NOT NULL, payload TEXT NOT NULL, digest TEXT NOT NULL, created_at_millis INTEGER NOT NULL, PRIMARY KEY(run_id,revision), UNIQUE(thread_id,commit_sequence))",
        "CREATE TABLE app_event_outbox (event_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE, commit_sequence INTEGER NOT NULL, ordinal INTEGER NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL, created_at_millis INTEGER NOT NULL, published INTEGER NOT NULL DEFAULT 0, UNIQUE(thread_id,commit_sequence,ordinal))",
        "CREATE INDEX run_continuation_facts_thread ON run_continuation_facts(thread_id,commit_sequence)",
        "CREATE INDEX app_event_outbox_pending ON app_event_outbox(thread_id,published,commit_sequence,ordinal)"
    ]
}

func v11Migration(): Array<String> {
    [
        "CREATE TABLE operation_effect_records (operation_id TEXT PRIMARY KEY REFERENCES operations(id) ON DELETE CASCADE, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE, tool_call_item_id TEXT NOT NULL REFERENCES items(id), normalized_plan TEXT NOT NULL, tool_id TEXT NOT NULL, tool_version TEXT NOT NULL, implementation_fingerprint TEXT NOT NULL, schema_digest TEXT NOT NULL, effective_arguments_digest TEXT NOT NULL, replay_contract_version INTEGER NOT NULL, replay_disposition TEXT NOT NULL, reserved_receipt_id TEXT NOT NULL UNIQUE, reserved_result_item_id TEXT NOT NULL UNIQUE, created_at_millis INTEGER NOT NULL)",
        "CREATE TABLE operation_state_registers (operation_id TEXT PRIMARY KEY REFERENCES operation_effect_records(operation_id) ON DELETE CASCADE, state TEXT NOT NULL, revision INTEGER NOT NULL)",
        "INSERT INTO operation_effect_records(operation_id,run_id,tool_call_item_id,normalized_plan,tool_id,tool_version,implementation_fingerprint,schema_digest,effective_arguments_digest,replay_contract_version,replay_disposition,reserved_receipt_id,reserved_result_item_id,created_at_millis) SELECT id,run_id,tool_call_item_id,normalized_plan,'legacy','legacy-v1',normalized_plan,normalized_plan,normalized_plan,1,CASE retry_disposition WHEN 'safe' THEN 'safe_replay' WHEN 'by_idempotency_key' THEN 'idempotent' WHEN 'verify_then_retry' THEN 'recover_by_probe' ELSE 'never_replay' END,'legacy-receipt-'||id,'legacy-result-'||id,0 FROM operations",
        "INSERT INTO operation_state_registers(operation_id,state,revision) SELECT id,state,revision FROM operations"
    ]
}

func v12Migration(): Array<String> {
    [
        "CREATE TABLE lane_inbox_entries (id TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE, lane_id TEXT NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL, status TEXT NOT NULL, created_at_millis INTEGER NOT NULL, claimed_step_id TEXT, revision INTEGER NOT NULL)",
        "CREATE TABLE step_records (id TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE, lane_id TEXT NOT NULL, turn_id TEXT NOT NULL REFERENCES turns(id) ON DELETE CASCADE, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL, input_entry_id TEXT NOT NULL UNIQUE REFERENCES lane_inbox_entries(id), accepted_item_id TEXT NOT NULL UNIQUE REFERENCES items(id), status TEXT NOT NULL, opened_at_millis INTEGER NOT NULL, settled_at_millis INTEGER, revision INTEGER NOT NULL, UNIQUE(run_id,ordinal))",
        "CREATE INDEX lane_inbox_queue ON lane_inbox_entries(thread_id,lane_id,status,created_at_millis,id)",
        "CREATE INDEX step_records_run ON step_records(run_id,ordinal)"
    ]
}

func v13Migration(): Array<String> {
    [
        "CREATE TABLE prompt_contribution_artifacts (hash TEXT PRIMARY KEY, content TEXT NOT NULL, created_at_millis INTEGER NOT NULL)",
        "CREATE TABLE context_manifests (id TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE, lane_id TEXT NOT NULL, turn_id TEXT NOT NULL REFERENCES turns(id) ON DELETE CASCADE, step_id TEXT NOT NULL REFERENCES step_records(id) ON DELETE CASCADE, digest TEXT NOT NULL, payload TEXT NOT NULL, created_at_millis INTEGER NOT NULL)"
    ]
}

func v14Migration(): Array<String> {
    [
        "CREATE TABLE lanes (thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE, lane_id TEXT NOT NULL, kind TEXT NOT NULL, parent_lane_id TEXT, fork_item_id TEXT REFERENCES items(id), config TEXT NOT NULL, status TEXT NOT NULL, created_at_millis INTEGER NOT NULL, PRIMARY KEY(thread_id,lane_id), FOREIGN KEY(thread_id,parent_lane_id) REFERENCES lanes(thread_id,lane_id))",
        "CREATE TABLE item_tree_edges (item_id TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE, thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE, lane_id TEXT NOT NULL, parent_item_id TEXT REFERENCES items(id), depth INTEGER NOT NULL, FOREIGN KEY(thread_id,lane_id) REFERENCES lanes(thread_id,lane_id))",
        "CREATE TABLE run_lane_bindings (run_id TEXT PRIMARY KEY REFERENCES runs(id) ON DELETE CASCADE, thread_id TEXT NOT NULL, lane_id TEXT NOT NULL, FOREIGN KEY(thread_id,lane_id) REFERENCES lanes(thread_id,lane_id))",
        "INSERT INTO lanes(thread_id,lane_id,kind,parent_lane_id,fork_item_id,config,status,created_at_millis) SELECT id,'main','main',NULL,NULL,'o1:0','open',0 FROM threads",
        "INSERT INTO item_tree_edges(item_id,thread_id,lane_id,parent_item_id,depth) SELECT item.id,item.thread_id,'main',(SELECT prior.id FROM items prior WHERE prior.thread_id=item.thread_id AND prior.ordinal<item.ordinal ORDER BY prior.ordinal DESC LIMIT 1),item.ordinal-1 FROM items item",
        "INSERT INTO run_lane_bindings(run_id,thread_id,lane_id) SELECT id,thread_id,'main' FROM runs",
        "CREATE TRIGGER threads_create_main_lane AFTER INSERT ON threads BEGIN INSERT INTO lanes(thread_id,lane_id,kind,parent_lane_id,fork_item_id,config,status,created_at_millis) VALUES (NEW.id,'main','main',NULL,NULL,'o1:0','open',0); END",
        "CREATE TRIGGER items_create_main_edge AFTER INSERT ON items BEGIN INSERT INTO item_tree_edges(item_id,thread_id,lane_id,parent_item_id,depth) VALUES (NEW.id,NEW.thread_id,'main',(SELECT id FROM items WHERE thread_id=NEW.thread_id AND ordinal<NEW.ordinal ORDER BY ordinal DESC LIMIT 1),COALESCE((SELECT edge.depth+1 FROM item_tree_edges edge JOIN items prior ON prior.id=edge.item_id WHERE prior.thread_id=NEW.thread_id AND prior.ordinal<NEW.ordinal ORDER BY prior.ordinal DESC LIMIT 1),0)); END",
        "CREATE TRIGGER runs_bind_main_lane AFTER INSERT ON runs BEGIN INSERT INTO run_lane_bindings(run_id,thread_id,lane_id) VALUES (NEW.id,NEW.thread_id,'main'); END"
    ]
}

func v15Migration(): Array<String> {
    [
        "CREATE TABLE composition_snapshots (id TEXT PRIMARY KEY, digest TEXT NOT NULL, payload TEXT NOT NULL, created_at_millis INTEGER NOT NULL)",
        "CREATE TABLE run_composition_bindings (run_id TEXT PRIMARY KEY REFERENCES runs(id) ON DELETE CASCADE, snapshot_id TEXT NOT NULL REFERENCES composition_snapshots(id))"
    ]
}

func v16Migration(): Array<String> {
    [
        "CREATE TABLE teams (id TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE, coordinator_lane_id TEXT NOT NULL, title TEXT NOT NULL, status TEXT NOT NULL, created_at_millis INTEGER NOT NULL, revision INTEGER NOT NULL, FOREIGN KEY(thread_id,coordinator_lane_id) REFERENCES lanes(thread_id,lane_id))",
        "CREATE TABLE team_members (team_id TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE, member_id TEXT NOT NULL, thread_id TEXT NOT NULL, lane_id TEXT NOT NULL, role TEXT NOT NULL, status TEXT NOT NULL, joined_at_millis INTEGER NOT NULL, PRIMARY KEY(team_id,member_id), UNIQUE(team_id,lane_id), FOREIGN KEY(thread_id,lane_id) REFERENCES lanes(thread_id,lane_id))",
        "CREATE TABLE team_tasks (id TEXT PRIMARY KEY, team_id TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE, title TEXT NOT NULL, payload TEXT NOT NULL, status TEXT NOT NULL, assignee_member_id TEXT, item_reference TEXT REFERENCES items(id), work_debt_id TEXT NOT NULL, revision INTEGER NOT NULL, created_at_millis INTEGER NOT NULL, updated_at_millis INTEGER NOT NULL, FOREIGN KEY(team_id,assignee_member_id) REFERENCES team_members(team_id,member_id))",
        "CREATE TABLE team_messages (id TEXT PRIMARY KEY, team_id TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE, sender_member_id TEXT NOT NULL, recipient_member_id TEXT NOT NULL, item_reference TEXT REFERENCES items(id), payload TEXT NOT NULL, created_at_millis INTEGER NOT NULL, acknowledged INTEGER NOT NULL, revision INTEGER NOT NULL, FOREIGN KEY(team_id,sender_member_id) REFERENCES team_members(team_id,member_id), FOREIGN KEY(team_id,recipient_member_id) REFERENCES team_members(team_id,member_id))",
        "CREATE INDEX team_tasks_board ON team_tasks(team_id,status,created_at_millis,id)",
        "CREATE INDEX team_messages_mailbox ON team_messages(team_id,recipient_member_id,acknowledged,created_at_millis,id)"
    ]
}

func v17Migration(): Array<String> {
    [
        "DROP INDEX step_records_run",
        "ALTER TABLE context_manifests RENAME TO context_manifests_v16",
        "ALTER TABLE step_records RENAME TO step_records_v16",
        "CREATE TABLE step_records (id TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE, lane_id TEXT NOT NULL, turn_id TEXT NOT NULL REFERENCES turns(id) ON DELETE CASCADE, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL, input_entry_id TEXT UNIQUE REFERENCES lane_inbox_entries(id), accepted_item_id TEXT UNIQUE REFERENCES items(id), status TEXT NOT NULL, opened_at_millis INTEGER NOT NULL, settled_at_millis INTEGER, revision INTEGER NOT NULL, UNIQUE(run_id,ordinal))",
        "INSERT INTO step_records SELECT * FROM step_records_v16",
        "CREATE INDEX step_records_run ON step_records(run_id,ordinal)",
        "CREATE TABLE context_manifests (id TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE, lane_id TEXT NOT NULL, turn_id TEXT NOT NULL REFERENCES turns(id) ON DELETE CASCADE, step_id TEXT NOT NULL REFERENCES step_records(id) ON DELETE CASCADE, digest TEXT NOT NULL, payload TEXT NOT NULL, created_at_millis INTEGER NOT NULL)",
        "INSERT INTO context_manifests SELECT * FROM context_manifests_v16",
        "DROP TABLE context_manifests_v16",
        "DROP TABLE step_records_v16"
    ]
}
