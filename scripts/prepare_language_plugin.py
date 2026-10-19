#!/usr/bin/env python3
"""Build and verify a fresh LSP/DAP package before real Product contracts."""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
from product_unit_gate import summary, has_compiler_error

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = {'lsp': (11, 19), 'dap': (32, 18)}
DAP_UNIT_METHODS = ('actionNamesMapToProtocolCommandsWithoutHiddenRequests', 'launchConfigurationBatchIsExplicitAndBounded', 'completeLegacySchemaContainsOutputSessionsAndAllOriginalOptions', 'oldOptionalIntegerDefaultingAndExplicitFrameSuppressionArePreserved', 'launchDefaultsAreOverriddenByActualLocationsAndAuthoredStringArguments', 'sourceAndFunctionBreakpointsKeepDistinctKeysUntilPolicyProjection', 'originalVariableReferencePrecedenceAndOptionalNegativeOffsetsRemainExact', 'cacheObservationsNeverProduceFakeWritesAndResumeNeedsLaterConcreteAdmission', 'unsupportedAdapterCapabilityRejectsBeforeAnyRequestExists', 'terminateSelectsAdapterCapabilityWithoutChangingRequestedEffect', 'debugProjectionKeepsExplicitFrameSuppressionAndRejectsStaleImplicitContext', 'debugOutputKeepsFullBoundedUtf8TailRatherThanSnapshotPreview', 'explicitIdentityFileTypeAndOrderedFallbackUseDifferentFixedPrograms', 'unknownExplicitMissingActualCeilingAndIncompatibleScopeNeverFallBack', 'snapshotReadsDrainBothCurrentStreamsAndRetainCompleteOutputEvents', 'currentSessionsSnapshotConsumesEventsBeforeItCompletes', 'allTwentyEightLegacyActionsRetainTheirIndependentCommandAndSchemaContract', 'concreteWriteProposalStaysFrozenAndUnsentResponseCannotBeAccepted', 'partialAckCannotAdvanceAndFullResponseIsDistinctFromTheWriteAck', 'actualAdapterErrorKeepsItsCompleteParsedResponseAndDoesNotBecomeAnAck', 'policyStopRetiresItsProposalWithoutWritingOrProducingProtocolProof', 'closeRequiresActualReleaseAckAndLateAckCannotRestartAClosedWorkflow', 'functionBreakpointRequiresNoFileObservationAndInvalidArgumentsStopInPurePrepare', 'sourceItemChangesArePureUntilAdoptAndDuplicateKeepsCondition', 'functionInstructionAndDataUseTheirOriginalDistinctKeys', 'rawFollowingRequestUpdatesSameCacheWithoutHiddenRequests', 'ambiguousRawListInvalidatesCacheButDoesNotRewriteProtocol', 'implicitFrameProjectionIsInvalidatedByAnotherStop', 'successfulResumeWithoutContinuedAndTerminalEventsRetireImplicitFrames', 'aliasesAreExactAndRelativeSourceNeedsSeparateMetadata', 'boundedOutputKeepsValidUtf8AndCumulativeObservedBytes', 'rawOversizeListStaysRawAndCannotAuthorizeLaterItemReplay')
LSP_UNIT_METHODS = ('utf16RangesKeepMultibyteTextAndRejectSurrogateInterior', 'descendingEditsRetainOriginalCoordinatesAndRejectOverlap', 'proposalUsesOnlyFrozenDocumentAndNormalizesEncodedRelativePath', 'uriTraversalForeignAuthorityAndUnfrozenEditFormsCannotMintProposal', 'equalPositionInsertsKeepArrayOrderBeforeOptionalReplacement', 'versionedDocumentChangesUseExactFrozenVersionAndTakePrecedence', 'staleVersionAliasedTargetsAndResourceOperationsCannotPropose', 'emptyAndIdentityEditsReturnNoApplicationPlan', 'originalDefaultHexShapeAndSixteenKibBoundaryRemainStrict', 'canonicalBase64RetainsBinaryAndSplitUtf8BeforeFraming', 'canonicalPaddingDecodedBoundAndExactResultShapeRejectMalformedReads')
LSP_PROTOCOL_CASES = ('check.py:test_actual_cancel_closes_window_and_emits_no_unapproved_cancel_frame', 'check.py:test_actual_initialization_documents_navigation_and_diagnostics', 'check.py:test_backend_known_error_is_complete_and_unapproved_reverse_reply_is_unknown', 'check.py:test_empty_rename_result_needs_no_plan_and_session_remains_usable', 'check.py:test_filepath_escape_and_changed_fact_are_rejected_without_backend_write', 'check.py:test_filepath_prepare_requests_read_without_io_then_freezes_same_identity', 'check.py:test_frozen_input_change_and_consumed_identity_cannot_write', 'check.py:test_multiple_versioned_and_null_version_documents_share_one_plan', 'check.py:test_rename_proposes_plan_without_workspace_apply', 'check.py:test_stale_version_and_resource_edit_cannot_reach_plan_service', 'check.py:test_versioned_rename_uses_frozen_content_and_advertises_text_support', 'check_channel.py:test_explicit_compact_reads_preserve_real_backend_controls_and_unicode', 'check_channel.py:test_noncanonical_base64_is_rejected_by_the_actual_native_reader', 'check_channel.py:test_wrong_representation_or_oversized_decoded_chunk_cannot_fall_back_or_replay', 'check_payload.py:test_actual_hanging_request_is_unknown_without_replay_or_cancel_write', 'check_payload.py:test_dense_physical_input_is_bounded_before_parse_and_releases_each_rejected_consumer', 'check_payload.py:test_incomplete_actual_call_transfer_expires_before_any_backend_write', 'check_payload.py:test_original_three_hundred_second_configuration_performs_actual_quick_call', 'check_payload.py:test_three_mib_documents_and_real_backend_result_survive_repeated_consumers')

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def files(directory):
    return {path.relative_to(directory).as_posix(): digest(path)
            for path in sorted(directory.rglob('*')) if path.is_file()}

def run(command, log, cwd, environment=None, timeout=900):
    with log.open('w', encoding='utf-8') as output:
        process = subprocess.Popen(command, cwd=cwd, env=environment, stdout=output,
            stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
            code = 124
    text = log.read_text(encoding='utf-8', errors='replace')
    sys.stderr.write(text)
    if code != 0:
        raise ValueError(f'command failed ({code}); see {log}')
    return text

def prepare(name, output=None):
    if sys.platform != 'linux':
        raise ValueError('actual language packages require Linux')
    plugin = ROOT / 'plugins' / name
    unit_expected, protocol_expected = EXPECTED[name]
    if output is None:
        parent = ROOT / 'target/plugin-contract-fixtures'
        parent.mkdir(parents=True, exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix=name + '-plugin-', dir=parent)) / 'package'
    package = output.resolve()
    if package.exists():
        raise ValueError('package output must be a new directory')
    evidence = package.parent / (package.name + '-validation')
    evidence.mkdir(parents=True, exist_ok=False)
    record = dict(status='FAIL', package=str(package), plugin=name,
        scope='Actual compiler unit cases and packaged process protocol; Product authority separately verified.')
    try:
        cases = []
        for path in sorted(plugin.glob('check*.py')):
            tree = ast.parse(path.read_text(encoding='utf-8'))
            cases += [path.name + ':' + node.name for node in ast.walk(tree)
                      if isinstance(node, ast.FunctionDef) and node.name.startswith('test_')]
        if name == 'lsp':
            expected_cases = LSP_PROTOCOL_CASES
            actual_units = [method for path in sorted((plugin / 'src').glob('*.cj'))
                for method in re.findall(r'@TestCase\s+func\s+(\w+)\s*\(', path.read_text(encoding='utf-8'))]
            if set(cases) != set(expected_cases) or len(cases) != len(expected_cases) or \
                    set(actual_units) != set(LSP_UNIT_METHODS) or len(actual_units) != len(LSP_UNIT_METHODS):
                raise ValueError('every original and additional compact LSP case is required')
        if name == 'dap':
            actual_units = [method for path in sorted((plugin / 'src').glob('*.cj'))
                for method in re.findall(r'@TestCase\s+func\s+(\w+)\s*\(', path.read_text(encoding='utf-8'))]
            if set(actual_units) != set(DAP_UNIT_METHODS) or len(actual_units) != len(DAP_UNIT_METHODS):
                raise ValueError('every original and additional DAP case is required')
        if len(cases) != protocol_expected or len(set(cases)) != protocol_expected:
            raise ValueError('review actual language protocol case inventory')
        record['protocol_cases'] = cases
        build = run(['bash', str(plugin / 'build-package.sh'), '--output', str(package)], evidence / 'build.log', ROOT)
        if 'cjpm build success' not in build or has_compiler_error(build):
            raise ValueError('actual compiler success is missing')
        unit = summary(run([str(ROOT / 'scripts/pinned_cangjie'), 'cjpm', 'test'], evidence / 'unit.log', plugin))
        if unit != dict(total=unit_expected, passed=unit_expected, failed=0, skipped=0, errors=0):
            raise ValueError('every authored plugin unit case must pass without skip')
        record['unit_counts'] = unit
        manifest = json.loads((package / 'axyndra.plugin.json').read_text(encoding='utf-8'))
        if manifest != json.loads((plugin / 'axyndra.plugin.json').read_text(encoding='utf-8')):
            raise ValueError('manifest differs from source')
        entry = (package / manifest['entrypoint']).resolve(strict=True)
        if not entry.is_file() or not entry.is_relative_to(package):
            raise ValueError('entrypoint escaped package')
        provenance = json.loads((package / 'package-provenance.json').read_text(encoding='utf-8'))
        if provenance['plugin_sha256'] != digest(entry):
            raise ValueError('binary differs from provenance')
        for directory, field in [('lib', 'bundled_libraries_sha256'), ('licenses', 'bundled_licenses_sha256')]:
            actual = {path.name: digest(path) for path in sorted((package / directory).iterdir()) if path.is_file()}
            if actual != provenance[field]:
                raise ValueError(f'packaged {directory} differs from provenance')
        before = files(package)
        clean = dict(os.environ)
        for key in ['LD_LIBRARY_PATH', 'CANGJIE_HOME', 'CANGJIE_SDK_ROOT', 'CANGJIE_STDX_PATH']:
            clean.pop(key, None)
        text = run([sys.executable, str(plugin / 'check.py'), '--package', str(package)],
            evidence / 'protocol.log', ROOT, clean, timeout=300)
        observed = re.findall(r'^test_\w+ .*? \.\.\. (ok|skipped.*?)$', text, re.M)
        if len(observed) != protocol_expected or any(value != 'ok' for value in observed) or \
                not re.search(rf'^Ran {protocol_expected} tests in [0-9.]+s$', text, re.M) or \
                not re.search(r'^OK$', text, re.M) or 'FAILED' in text or 'ERROR:' in text or 'skipped' in text.lower():
            raise ValueError('every packaged protocol case must pass without skip')
        if files(package) != before:
            raise ValueError('package bytes changed during tests')
        record.update(status='PASS', protocol_counts=dict(total=protocol_expected, passed=protocol_expected,
            failed=0, errors=0, skipped=0), package_files=before, entrypoint_sha256=digest(entry),
            package_provenance=provenance, loader_environment_removed=True)
    except Exception as error:
        record['error'] = str(error)
        raise
    finally:
        (evidence / 'summary.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
    return package

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plugin', choices=sorted(EXPECTED), required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    try:
        print(prepare(args.plugin, args.output))
    except (OSError, ValueError, KeyError) as error:
        print(f'language package preparation failed: {error}', file=sys.stderr)
        raise SystemExit(1)
