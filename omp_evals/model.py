from __future__ import annotations

from dataclasses import asdict, dataclass, field
from enum import Enum
from typing import Any, Mapping, Optional, Tuple


class TrialState(str, Enum):
    CREATED = "Created"
    MATERIALIZING = "Materializing"
    PREFLIGHT = "Preflight"
    RUNNING_AGENT = "RunningAgent"
    QUIESCING = "Quiescing"
    SNAPSHOTTING = "Snapshotting"
    GRADING = "Grading"
    FINALIZING = "Finalizing"
    COMPLETED = "Completed"
    INVALID = "Invalid"
    ABORTED = "Aborted"
    INFRASTRUCTURE_FAILED = "InfrastructureFailed"


class TrialValidity(str, Enum):
    VALID = "Valid"
    INVALID_FIXTURE = "InvalidFixture"
    INVALID_ENVIRONMENT = "InvalidEnvironment"
    INVALID_INFRASTRUCTURE = "InvalidInfrastructure"
    INVALID_PROVIDER_INFRASTRUCTURE = "InvalidProviderInfrastructure"
    INVALID_RUNNER = "InvalidRunner"
    INVALID_GRADER_INFRASTRUCTURE = "InvalidGraderInfrastructure"
    INVALID_AGENT_INFRASTRUCTURE = "InvalidAgentInfrastructure"
    INVALID_ENVIRONMENT_INFRASTRUCTURE = "InvalidEnvironmentInfrastructure"


class AgentTermination(str, Enum):
    NOT_STARTED = "AgentNotStarted"
    COMPLETED = "AgentCompleted"
    FAILED = "AgentFailed"
    TIMED_OUT = "AgentTimedOut"
    BUDGET_EXCEEDED = "AgentBudgetExceeded"
    CANCELLED = "AgentCancelled"
    CRASHED = "AgentCrashed"
    QUIESCE_FAILED = "AgentQuiesceFailed"


class GraderStatus(str, Enum):
    PASS = "Pass"
    FAIL = "Fail"
    PARTIAL = "Partial"
    UNKNOWN = "Unknown"
    ERROR = "Error"
    SKIPPED = "Skipped"


class GraderSeverity(str, Enum):
    GATE = "Gate"
    REQUIRED = "Required"
    ADVISORY = "Advisory"
    DIAGNOSTIC = "Diagnostic"


class EvalVerdict(str, Enum):
    PASS = "Pass"
    FAIL = "Fail"
    INVALID = "Invalid"


class StrictEvalOutcome(str, Enum):
    PASS = "Pass"
    FAIL = "Fail"


class CandidateOutcome(str, Enum):
    CORRECT = "Correct"
    INCORRECT = "Incorrect"
    UNAVAILABLE = "Unavailable"
    UNGRADABLE = "Ungradable"


class RuntimeDependencyClassification(str, Enum):
    CONDITION_OWNED = "ConditionOwned"
    ENVIRONMENT_OWNED = "EnvironmentOwned"


class ConditionRuntimeReadiness(str, Enum):
    UNVERIFIED = "Unverified"
    READY = "Ready"
    INVALID = "Invalid"


class ModelPathDynamicLinkReadiness(str, Enum):
    PASS = "Pass"
    FAIL = "Fail"
    UNSUPPORTED = "Unsupported"


class ToolSandboxReadiness(str, Enum):
    UNVERIFIED = "Unverified"
    READY = "Ready"
    INVALID = "Invalid"


class CacheMode(str, Enum):
    COLD = "Cold"
    WARM_READ_ONLY = "WarmReadOnly"
    ISOLATED = "Isolated"


class TaskLifecycle(str, Enum):
    DRAFT = "Draft"
    QUALIFIED = "Qualified"
    PILOT = "Pilot"
    ACTIVE = "Active"
    RETIRED = "Retired"


class TaskCategory(str, Enum):
    BUG_FIX = "BugFix"
    FEATURE = "Feature"
    REFACTOR = "Refactor"
    INVESTIGATION = "Investigation"
    PERFORMANCE = "Performance"


class CapabilityTag(str, Enum):
    REPO_EXPLORATION = "RepoExploration"
    LOCAL_CODE_UNDERSTANDING = "LocalCodeUnderstanding"
    CROSS_FILE_REASONING = "CrossFileReasoning"
    CALL_SITE_DISCOVERY = "CallSiteDiscovery"
    EXISTING_CODE_EDIT = "ExistingCodeEdit"
    NEW_CODE_CREATION = "NewCodeCreation"
    COMPILER_DIAGNOSTICS = "CompilerDiagnostics"
    TEST_INTERPRETATION = "TestInterpretation"
    REGRESSION_REASONING = "RegressionReasoning"
    MULTI_STEP_REPAIR = "MultiStepRepair"
    SCOPE_CONTROL = "ScopeControl"
    API_REASONING = "APIReasoning"
    PERFORMANCE_DIAGNOSIS = "PerformanceDiagnosis"


class SuiteKind(str, Enum):
    SMOKE = "Smoke"
    GOLDEN = "Golden"
    CAPABILITY = "Capability"
    REGRESSION = "Regression"
    RESEARCH = "Research"


class OutcomeRequirement(str, Enum):
    TARGETED_BEHAVIOR = "TargetedBehavior"
    REGRESSION = "Regression"
    HARD_CONSTRAINTS = "HardConstraints"
    ARTIFACT_INTEGRITY = "ArtifactIntegrity"


class FailureClassification(str, Enum):
    WRONG_DIAGNOSIS = "WrongDiagnosis"
    CORRECT_DIAGNOSIS_WRONG_EDIT = "CorrectDiagnosisWrongEdit"
    EDIT_APPLICATION_FAILURE = "EditApplicationFailure"
    INCOMPLETE_IMPLEMENTATION = "IncompleteImplementation"
    REGRESSION_INTRODUCED = "RegressionIntroduced"
    VERIFICATION_FAILURE = "VerificationFailure"
    STUCK_LOOP = "StuckLoop"
    AGENT_TERMINATION_FAILURE = "AgentTerminationFailure"
    BUDGET_EXHAUSTED = "BudgetExhausted"
    TOOL_USE_FAILURE = "ToolUseFailure"
    UNCLASSIFIED_VALID_FAILURE = "UnclassifiedValidFailure"
    # Historical v0.2 values remain readable. New v1 attributions should use
    # the classifications above rather than rewriting stored history.
    WRONG_EDIT = "WrongEdit"
    VERIFICATION_MISSING = "VerificationMissing"
    CONTEXT_FAILURE = "ContextFailure"
    TIMEOUT = "Timeout"
    AGENT_GAVE_UP = "AgentGaveUp"


class ClassificationSource(str, Enum):
    MANUAL = "Manual"
    DETERMINISTIC_RULE = "DeterministicRule"
    MODEL_ASSISTED = "ModelAssisted"


FAILURE_TAXONOMY_VERSION = "failure-taxonomy-v1"


class PilotSuggestion(str, Enum):
    TOO_EASY = "TooEasy"
    USEFUL = "Useful"
    TOO_HARD = "TooHard"
    SUSPICIOUS = "Suspicious"
    INSUFFICIENT_DATA = "InsufficientData"


@dataclass(frozen=True)
class CachePolicy:
    dependency_cache: CacheMode = CacheMode.ISOLATED
    build_cache: CacheMode = CacheMode.ISOLATED
    agent_cache: CacheMode = CacheMode.COLD


@dataclass(frozen=True)
class ResourcePolicy:
    cpu_guaranteed: Optional[float] = None
    cpu_limit: Optional[float] = None
    memory_guaranteed_bytes: Optional[int] = None
    memory_limit_bytes: Optional[int] = None
    disk_limit_bytes: Optional[int] = None
    process_limit: int = 128
    agent_wall_time_seconds: float = 900.0
    quiesce_time_seconds: float = 10.0
    grader_time_seconds: float = 300.0
    cleanup_time_seconds: float = 10.0
    model_call_limit: Optional[int] = None
    tool_call_limit: Optional[int] = None
    input_token_limit: Optional[int] = None
    cost_limit_micros: Optional[int] = None
    cpu_enforcement: str = "unsupported"
    memory_enforcement: str = "unsupported"
    model_call_enforcement: str = "unsupported"
    tool_call_enforcement: str = "unsupported"
    token_enforcement: str = "unsupported"
    cost_enforcement: str = "unsupported"


@dataclass(frozen=True)
class AgentTaskView:
    prompt: str
    visible_constraints: Tuple[str, ...]
    metadata: Mapping[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class PrivateTaskSpec:
    fixture: str
    reference_patch: str
    grader_bundle: str
    semantic_equivalent_grader_bundle: Optional[str]
    graders: Tuple[Mapping[str, Any], ...]


@dataclass(frozen=True)
class QualifiedEvalTask:
    id: str
    version: str
    category: str
    prompt: str
    fixture: str
    fixture_digest: str
    base_revision: str
    visible_constraints: Tuple[str, ...]
    resource_policy: ResourcePolicy
    cache_policy: CachePolicy
    network_policy: str
    graders: Tuple[Mapping[str, Any], ...]
    grader_bundle: str
    task_fingerprint: str
    qualification_fingerprint: str
    bundle_root: str
    agent: Mapping[str, Any] = field(default_factory=dict)
    lifecycle: TaskLifecycle = TaskLifecycle.QUALIFIED
    capabilities: Tuple[CapabilityTag, ...] = ()
    benchmark_kind: SuiteKind = SuiteKind.CAPABILITY
    semantic_equivalent_grader_bundle: Optional[str] = None

    def agent_view(self) -> AgentTaskView:
        return AgentTaskView(
            prompt=self.prompt,
            visible_constraints=self.visible_constraints,
            metadata={"id": self.id, "version": self.version, "category": self.category},
        )


@dataclass(frozen=True)
class TrialPlan:
    trial_id: str
    task_fingerprint: str
    agent_fingerprint: str
    environment_fingerprint: str
    repetition_index: int
    resource_policy: ResourcePolicy
    cache_policy: CachePolicy
    network_policy: str
    timeout_policy: Mapping[str, Any]
    capture_policy: Mapping[str, Any]
    created_at: str
    condition_id: str = "default"
    condition_fingerprint: str = ""
    experiment_id: Optional[str] = None
    condition_manifest_ref: Optional[str] = None


@dataclass(frozen=True)
class AgentTrial:
    id: str
    plan: TrialPlan
    state: TrialState
    started_at: str
    finished_at: str
    termination: AgentTermination
    validity: TrialValidity
    candidate_snapshot_id: Optional[str]
    diagnostics: Tuple[str, ...]
    worker_pid: Optional[int] = None


@dataclass(frozen=True)
class CandidateSnapshot:
    id: str
    trial_id: str
    base_fixture_digest: str
    final_workspace_digest: str
    workspace_artifact_ref: str
    diff_ref: str
    filesystem_manifest_ref: str
    transcript_ref: str
    trajectory_ref: str
    operation_refs: Tuple[str, ...]
    final_answer_ref: str
    runtime_log_ref: str
    usage: Mapping[str, Any]
    agent_termination: AgentTermination
    runtime_diagnostics: Tuple[str, ...]
    created_at: str


@dataclass(frozen=True)
class AssertionResult:
    name: str
    passed: bool
    detail: str = ""


@dataclass(frozen=True)
class GraderResult:
    grader_id: str
    status: GraderStatus
    severity: GraderSeverity
    score: Optional[float]
    assertions: Tuple[AssertionResult, ...]
    evidence: Mapping[str, Any]
    grader_version: str
    duration_millis: int
    outcome_requirement: OutcomeRequirement = OutcomeRequirement.HARD_CONSTRAINTS


@dataclass(frozen=True)
class GradingRun:
    id: str
    candidate_snapshot_id: str
    grader_bundle_fingerprint: str
    grader_results: Tuple[GraderResult, ...]
    started_at: str
    finished_at: str


@dataclass(frozen=True)
class EvalResult:
    trial_id: str
    candidate_snapshot_id: str
    verdict: EvalVerdict
    validity: TrialValidity
    grader_results: Tuple[GraderResult, ...]
    usage: Mapping[str, Any]
    timing: Mapping[str, Any]
    task_fingerprint: str = ""
    condition_fingerprint: str = ""
    failure_classification: Optional[FailureClassification] = None
    trajectory_metrics: Mapping[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class EvalSuiteTask:
    task_id: str
    version: str
    task_fingerprint: str
    qualified_task: str


@dataclass(frozen=True)
class EvalSuite:
    id: str
    version: str
    kind: SuiteKind
    tasks: Tuple[EvalSuiteTask, ...]
    metadata: Mapping[str, Any]
    fingerprint: str
    root: str


@dataclass(frozen=True)
class ExperimentalCondition:
    id: str
    version: str
    fingerprint: str
    manifest: Mapping[str, Any]
    agent: Mapping[str, Any]
    agent_binary: Optional[str] = None
    runtime_closure: Optional[Mapping[str, Any]] = None
    runtime_closure_ref: Optional[str] = None
    provider_execution_spec: Optional[Mapping[str, Any]] = None
    provider_execution_digest: Optional[str] = None
    provider_settings_closure: Optional[Mapping[str, Any]] = None
    provider_settings_closure_ref: Optional[str] = None
    provider_settings_closure_digest: Optional[str] = None


@dataclass(frozen=True)
class RuntimeDependency:
    soname: str
    resolved_path: str
    digest: str
    size: int
    classification: RuntimeDependencyClassification
    source_class: str
    required_by: Tuple[str, ...]
    bundle_path: Optional[str] = None
    artifact_ref: Optional[str] = None
    environment_requirement: Optional[str] = None


@dataclass(frozen=True)
class RuntimeClosureManifest:
    version: str
    executable: Mapping[str, Any]
    interpreter: Mapping[str, Any]
    dependencies: Tuple[RuntimeDependency, ...]
    loader: Mapping[str, Any]
    mounts: Tuple[Mapping[str, Any], ...]
    environment_class: Mapping[str, Any]
    closure_digest: str
    target: Mapping[str, Any] = field(default_factory=dict)
    sdk_identity: Mapping[str, Any] = field(default_factory=dict)
    dependency_graph: Tuple[Mapping[str, Any], ...] = ()
    linkage_validation: Mapping[str, Any] = field(default_factory=dict)
    executable_runtime_compatibility_digest: Optional[str] = None


@dataclass(frozen=True)
class RuntimeClosureRef:
    manifest_ref: str
    closure_digest: str


@dataclass(frozen=True)
class RuntimeReadinessResult:
    readiness: ConditionRuntimeReadiness
    closure_digest: str
    process_started: bool
    protocol_ready: bool
    clean_shutdown: bool
    residual_process: bool
    model_calls: int
    provider_requests: int
    diagnostics: Tuple[str, ...] = ()
    protocol_facts: Mapping[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class ModelPathDynamicLinkReadinessResult:
    readiness: ModelPathDynamicLinkReadiness
    runtime_closure_digest: str
    executable_digest: str
    executable_runtime_compatibility_digest: Optional[str]
    static_dependency_closure: bool
    symbol_version_validation: bool
    sandbox_process_started: bool
    model_path_initialized: bool
    protocol_ready: bool
    clean_shutdown: bool
    residual_process: bool
    provider_requests: int
    model_calls: int
    credential_reads: int
    diagnostics: Tuple[str, ...] = ()
    evidence: Mapping[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class ToolExecutionPlaneReadinessResult:
    readiness: ToolSandboxReadiness
    process_started: bool
    protocol_ready: bool
    workspace_process_ready: bool
    readonly_shell_ready: bool
    clean_shutdown: bool
    residual_process: bool
    model_calls: int
    provider_requests: int
    diagnostics: Tuple[str, ...] = ()
    probe_facts: Mapping[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class ProviderSettingsCompatibilityResult:
    readiness: ConditionRuntimeReadiness
    provider_execution_digest: str
    provider_settings_closure_digest: str
    settings_materialized: bool
    referential_integrity: bool
    process_started: bool
    protocol_ready: bool
    get_state_ready: bool
    clean_shutdown: bool
    residual_process: bool
    model_calls: int
    provider_requests: int
    diagnostics: Tuple[str, ...] = ()
    probe_facts: Mapping[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class ExperimentTrial:
    ordinal: int
    task_fingerprint: str
    condition_fingerprint: str
    repetition_index: int
    trial_id: Optional[str] = None
    grading_run_id: Optional[str] = None


@dataclass(frozen=True)
class ExperimentConditionInvariant:
    condition_fingerprint: str
    provider: str
    model: str
    settings_manifest_digest: str
    system_prompt_digest: str
    general_prompt_digest: str
    context_policy_digest: str
    compaction_policy_digest: str
    permission_profile_digest: str
    non_edit_tool_set_digest: str
    tool_set_digest: str
    runtime_closure_digest: str
    runtime_closure_ref: str
    environment_fingerprint: str
    tool_execution_plane_digest: str
    sandbox_policy_digest: str
    provider_execution_digest: str = "legacy-unfrozen"
    provider_settings_closure_digest: str = "legacy-unfrozen"
    provider_settings_closure_ref: str = "legacy-unfrozen"
    provider_settings_materializer_version: str = "legacy-unfrozen"


@dataclass(frozen=True)
class ExperimentInvariantSnapshot:
    schema_version: str
    paired_by_task: bool
    condition_scope: str
    task_fingerprints: Tuple[str, ...]
    condition_fingerprints: Tuple[str, ...]
    fixture_digests: Mapping[str, str]
    task_prompt_digests: Mapping[str, str]
    grader_spec_digests: Mapping[str, str]
    budget_digests: Mapping[str, str]
    environment_class: str
    tool_execution_plane_digest: str
    conditions: Tuple[ExperimentConditionInvariant, ...]


@dataclass(frozen=True)
class ExperimentPlan:
    id: str
    kind: str
    suite_fingerprint: str
    condition_fingerprints: Tuple[str, ...]
    trials_per_task: int
    seed: int
    order: Tuple[ExperimentTrial, ...]
    created_at: str
    invariants: Mapping[str, Any] = field(default_factory=dict)
    invariant_schema_version: Optional[str] = None
    invariant_snapshot: Optional[ExperimentInvariantSnapshot] = None
    invariant_snapshot_digest: Optional[str] = None


@dataclass(frozen=True)
class TrajectoryMetrics:
    model_calls: int
    tool_calls: int
    read_calls: int
    search_calls: int
    edit_calls: int
    shell_calls: int
    failed_tool_calls: int
    compaction_count: int
    input_tokens: Optional[int]
    cached_tokens: Optional[int]
    output_tokens: Optional[int]
    cost_micros: Optional[int]
    last_mutation_sequence: Optional[int]
    verified_final_state: Optional[bool]
    unsupported: Tuple[str, ...]
    tool_calls_by_tool: Mapping[str, int] = field(default_factory=dict)
    failed_operations: int = 0
    candidate_mutation_count: int = 0
    first_candidate_mutation_sequence: Optional[int] = None
    last_candidate_mutation_sequence: Optional[int] = None
    last_operation_sequence: Optional[int] = None
    last_model_completion_sequence: Optional[int] = None
    final_candidate_outcome: Optional[CandidateOutcome] = None
    termination: Optional[AgentTermination] = None


@dataclass(frozen=True)
class CandidateDiagnostic:
    outcome: CandidateOutcome
    required_graders_passed: Tuple[str, ...]
    required_graders_failed: Tuple[str, ...]
    targeted_passed: Optional[bool]
    regression_passed: Optional[bool]
    hard_constraints_passed: Optional[bool]
    artifact_integrity_passed: Optional[bool]


@dataclass(frozen=True)
class FailureEvidenceRef:
    kind: str
    reference: str
    detail: str = ""


@dataclass(frozen=True)
class FailureAttribution:
    id: str
    trial_id: str
    taxonomy_version: str
    primary: FailureClassification
    contributing: Tuple[FailureClassification, ...]
    confidence: float
    evidence_refs: Tuple[FailureEvidenceRef, ...]
    source: ClassificationSource
    created_at: str
    supersedes_id: Optional[str] = None


@dataclass(frozen=True)
class TrialTimelineEvent:
    sequence: Optional[int]
    relative_millis: Optional[int]
    event_type: str
    detail: Mapping[str, Any]


@dataclass(frozen=True)
class TrialTimeline:
    trial_id: str
    events: Tuple[TrialTimelineEvent, ...]
    wall_duration_millis: Optional[int]
    timing_support: str


@dataclass(frozen=True)
class TrialFailureAnalysis:
    trial_id: str
    candidate_snapshot_id: Optional[str]
    strict_outcome: Optional[StrictEvalOutcome]
    candidate_diagnostic: CandidateDiagnostic
    termination: AgentTermination
    validity: TrialValidity
    failure_attribution: Optional[FailureAttribution]
    timeline: TrialTimeline
    diff_diagnostic: Mapping[str, Any]
    usage: Mapping[str, Any]
    duration_millis: Optional[int]


@dataclass(frozen=True)
class FailureAnalysisReport:
    id: str
    target_id: str
    taxonomy_version: str
    analyses: Tuple[TrialFailureAnalysis, ...]
    summary: Mapping[str, Any]
    created_at: str


@dataclass(frozen=True)
class PilotResult:
    task_fingerprint: str
    experiment_id: str
    requested_trials: int
    valid_trials: int
    invalid_trials: int
    passed_trials: int
    failed_trials: int
    timeout_trials: int
    median_usage: Mapping[str, Any]
    median_duration_millis: Optional[float]
    failure_categories: Mapping[str, int]
    suggestion: PilotSuggestion


@dataclass(frozen=True)
class SuiteResult:
    id: str
    experiment_id: str
    suite_fingerprint: str
    grader_version_set: Mapping[str, Any]
    overall: Mapping[str, Any]
    by_task: Mapping[str, Any]
    by_category: Mapping[str, Any]
    by_capability: Mapping[str, Any]
    by_termination: Mapping[str, Any]
    by_failure_classification: Mapping[str, Any]
    by_condition: Mapping[str, Any]
    created_at: str


@dataclass(frozen=True)
class ComparisonResult:
    experiment_id: str
    condition_a: str
    condition_b: str
    condition_results: Mapping[str, Any]
    task_deltas: Mapping[str, Any]


@dataclass(frozen=True)
class ExperimentDecision:
    id: str
    experiment_id: str
    version: str
    decision: str
    reason: str
    evidence_refs: Tuple[str, ...]
    limitations: Tuple[str, ...]
    next_experiment: Optional[str]
    created_at: str


def jsonable(value: Any) -> Any:
    if isinstance(value, Enum):
        return value.value
    if hasattr(value, "__dataclass_fields__"):
        return {key: jsonable(item) for key, item in asdict(value).items()}
    if isinstance(value, Mapping):
        return {str(key): jsonable(item) for key, item in value.items()}
    if isinstance(value, (tuple, list)):
        return [jsonable(item) for item in value]
    return value
