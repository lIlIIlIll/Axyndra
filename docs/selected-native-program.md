# Selected Native Program

Program composition runs in the installed Native `axyndra:program` package.
The Product does not register `run_program`, compile its DSL, or launch a
Product Program worker. Configure `plugins/program-tools.json` to select the
actual installed package digest; missing or stale selection fails closed.
The convenience `invokeProgramTool` still uses the sole canonical pipeline,
actual Root, ordinary approval, cancellation and cleanup acknowledgement.

The existing `tool_delegations` operator configuration freezes the exact
read-only contribution aliases. Programs cannot select arbitrary catalog
tools, raw host services, process launch or workspace writes.

File previews require explicit `file_plan_proposals: true` in that exact
contribution's operator grant. The default is false. This flag permits only
the existing read-only `host.file.plan.propose` Derived child under the same
current Root and WorkspaceRead/ExtensionInvoke ceiling. Its original durable
Receipt and host-owned origin back the returned immutable plan. A returned
JSON source claim cannot create an origin. Applying the plan requires a new,
separately authorized `apply_file_plan` Root and its own user decision.

The caller must explicitly provide a sufficient finite budget. For example,
one Program Root, one selected Workspace read, its read-view child and one
preview require four calls. No preview configuration expands a caller's
budget automatically. The frontend's default three-call budget remains
three; the fourth call is refused when the caller has not budgeted it.

The Program DSL remains bounded to 262144 source bytes. Neutral logical
request framing is a separately reviewed transport component, not permission
to enlarge that source bound or to execute code returned by a peer.

Source-only migration status: legacy Product/Thread whole-main tool inventory,
Program SDK inspection and application-plan assertions still require their
explicit Native fixture migration and real execution. Historical v1 plan
evidence is retained only for verified durable migration/recovery; it does
not restore the removed Product executor or worker.
