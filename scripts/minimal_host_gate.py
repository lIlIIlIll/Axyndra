#!/usr/bin/env python3
"""Build and execute the real isolated Minimal closure, never the full App."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile

from minimal_host_source import materialize,FORBIDDEN_NAMES


def run(command,log,cwd,env,timeout=1200):
    with log.open('w',encoding='utf-8') as out:
        proc=subprocess.Popen(command,cwd=cwd,env=env,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
        try:code=proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid,signal.SIGKILL);proc.wait();raise RuntimeError('bounded build/test deadline: '+str(log))
    if code:raise RuntimeError('command failed '+str(code)+': '+str(log))
    return log.read_text(encoding='utf-8')


# Required historical cases stay named; the complete expected inventory comes
# from the exact materialized source, then must equal real --dry-run and results.
REQUIRED_UNITS = {'agent_plugin_registry': ['installUpdateRollbackUninstallAndGcKeepTheSameDurableHistory', 'userDisableSuppressesWorkspaceAndFailedCommitCannotPublishTentativeState', 'installedTamperIsRejectedWithoutRewritingTheOriginalLock', 'staleObjectReloadsBeforeUpdateHistoryRollbackAndGc', 'staleImportPreservesAnotherNamespaceAndDisableWithoutRuntime', 'busyFenceRejectsBeforeMaterializationAndReleasesForNextMutation', 'uncertainPublicationKeepsOriginalBytesAndOnlyHidesWorkspaceScope', 'staleCompensatingRestoreCannotOverwriteOtherWriterGeneration', 'malformedStoredRowCannotBeSilentlyDroppedByNextWriter', 'userOnlyRegistryKeepsWorkspaceOptionalAndRejectsNulPaths', 'rawPublicPublisherCannotBypassReloadAndWriterFence', 'secondRealRegistryDisableInvalidatesHeldPinAndCannotBeRearmedByRecordData', 'disableEnableAbaKeepsOldGenerationRevokedEvenWhenFinalEnabledBytesMatch', 'activeShortLeaseBlocksActualWriterAndClosingPinDoesNotDropThatLease', 'writerBusyDoesNotPermanentlyRevokeAnUnchangedPin', 'exactContentAndRetainedInodeRejectUnchangedLengthRewriteAndPathReplacement', 'workspacePublicationMarkerAndGrantChangeNeverAuthorizeOldMountedGeneration', 'absentWorkspaceMetadataBecomingPresentRevokesUserPinConservatively', 'heldMetadataRejectsSymlinkSubstitutionAndDoesNotFollowExternalContent', 'seventeenActualInstalledPinsShareOneRealAllocationWithNearEightMibAndSessionOwners', 'lastClosedPinRetainsGenerationUntilActualSharedAdmissionLeaseCloses', 'changedMetadataCreatesDistinctGenerationAndOldPinsCannotBorrowItsAuthority', 'packageBytesAreStillFullyInspectedForEveryCaptureWithUnchangedRegistryFiles', 'denseActualManifestCannotDecodeBeyondSharedPoolAndFailedCaptureReleasesOwner', 'restoredCallerMetadataMustFitTheRealSharedPoolBeforeRegistryAdoptsItsGraph', 'publicInspectionAfterCapturePrepaysDenseDomAndKeepsSuccessfulResultPayment', 'actualCurrentRegistryStateRetainsTheSingleOriginalFloorAfterLastPinCloses', 'genuineConstructorMustReserveBeforeAnyInstalledMetadataCanBeDecoded', 'actualReloadAndCaptureShareOneCustodyButPreserveIndependentGenerationRevocation', 'closedRegistryCannotMintAnotherPinButActualOutstandingFenceKeepsItsPayment'], 'agent_history': ['readonlyConnectionObservesCurrentWalAndCannotMutateCanonicalFacts', 'historyOpenNeverCreatesMissingDatabaseOrItsParent', 'readonlyFutureSchemaLeavesItsBytesAndVersionUntouched', 'modelRequestLimitKeepsNewestAttemptsInDisplayOrder']}


def expected_units(tree, member):
    names=[]
    for path in sorted((tree/member/'src').rglob('*_test.cj')):
        source=path.read_text(encoding='utf-8')
        found=re.findall(r'@TestCase\s+func\s+(\w+)\s*\(',source)
        if len(found)!=source.count('@TestCase'):
            raise ValueError('unrecognized unit source shape: '+str(path))
        names.extend(found)
    if len(names)!=len(set(names)) or not set(REQUIRED_UNITS[member]).issubset(names):
        raise ValueError('required original/new unit source missing or duplicated: '+member)
    return names


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[1]);p.add_argument('--output',type=Path,required=True)
    args=p.parse_args();root=args.root.resolve(strict=True);out=args.output.resolve()
    if out.exists():raise ValueError('evidence output must not exist')
    out.mkdir(parents=True);tree=out/'source';report={'status':'INCOMPLETE','stages':[]}
    summary=out/'summary.json'
    runtime=None
    try:
        harness=out/'gate-source';harness.mkdir()
        report['harness']=[]
        for name in ['minimal_host_gate.py','minimal_host_source.py','minimal_host_source_test.py','minimal_host_blackbox.py']:
            origin=Path(__file__).resolve().parent/name;copied=harness/name
            shutil.copyfile(origin,copied)
            report['harness'].append({'path':name,'sha256':hashlib.sha256(copied.read_bytes()).hexdigest()})
        source=materialize(root,tree);report['source_manifest_sha256']=hashlib.sha256((tree/'minimal-source.json').read_bytes()).hexdigest()
        report['packages']=source['packages'];report['stages'].append('source_materialized_without_optional_business')
        driver=tree/'scripts/pinned_cangjie'
        if not driver.is_file():raise ValueError('isolated source lacks its pinned build driver')
        for helper in (tree/'scripts').iterdir():helper.chmod(helper.stat().st_mode|0o111)
        env=os.environ.copy()
        # Never reuse full-host native artifacts or target output overrides.
        for key in ['AXYNDRA_NATIVE_OUTPUT','AXYNDRA_NETWORK_BRIDGE_OUTPUT','AXYNDRA_CANONICAL_TARGET_ROOT']:
            env.pop(key,None)
        runtime=tempfile.TemporaryDirectory(prefix='axyndra-minimal-runtime-')
        env['XDG_RUNTIME_DIR']=runtime.name
        report['runtime_directory_scope']='Owned temporary runtime; the pinned driver still enforces exact UID and mode 0700.'
        target=out/'target'
        build=['bash',str(driver),'cjpm','build','-m','agent_minimal','--target-dir',str(target)]
        report['build_command']=build
        run(build,out/'build.log',tree,env)
        binaries=[x for x in target.rglob('agent_minimal') if x.is_file() and 'bin' in x.parts]
        if len(binaries)!=1:raise ValueError('expected exactly one fresh agent_minimal executable')
        binary=binaries[0];report['binary']=str(binary);report['binary_sha256']=hashlib.sha256(binary.read_bytes()).hexdigest()
        report['stages'].append('actual_minimal_executable_built')
        units=[]
        for member in ['agent_plugin_registry','agent_history']:
            expected=expected_units(tree,member);count=len(expected)
            command=['bash',str(driver),'cjpm','test','-m',member,'--target-dir',str(target),'--no-color','--no-progress']
            dry=run(command+['--dry-run'],out/(member+'-enumeration.log'),tree,env)
            enumerated=re.findall(r'\[\s*NORUN\s*\]\s+CASE:\s+(\w+)',dry)
            if len(enumerated)!=count or set(enumerated)!=set(expected):raise ValueError('unit enumeration drift: '+member)
            text=run(command,out/(member+'-tests.log'),tree,env)
            matches=re.findall(r'Summary: TOTAL:\s*(\d+)\s+PASSED:\s*(\d+),\s*SKIPPED:\s*(\d+),\s*ERROR:\s*(\d+)\s+FAILED:\s*(\d+)',text,re.I)
            if not matches or tuple(map(int,matches[-1]))!=(count,count,0,0,0):raise ValueError('real unit count/result mismatch: '+member)
            units.append({'package':member,'enumerated':enumerated,'passed':count})
        report['units']=units;report['unit_total']=sum(x['passed'] for x in units)
        report['stages'].append('actual_registry_and_sqlite_source_inventory_passed')
        # Driver establishes the exact SDK/native loader path without building
        # optional packages. The nested script executes the fixed binary only.
        script=harness/'minimal_host_blackbox.py'
        run(['bash',str(driver),sys.executable,str(script),'--binary',str(binary),'--work',str(out/'blackbox')],out/'blackbox.log',tree,env,180)
        bb=json.loads((out/'blackbox/summary.json').read_text(encoding='utf-8'))
        if bb['binary_sha256']!=report['binary_sha256'] or bb['checks']!=9:raise ValueError('blackbox binary identity/count drift')
        report['blackbox']=bb;report['stages'].append('fixed_binary_offline_cli_blackbox_passed')
        # Retain resolved lock bytes and actual dependency evidence. Merely
        # materializing source is never labeled a build or portable bundle.
        locks=[]
        for lock in tree.rglob('cjpm.lock'):
            raw=lock.read_bytes();locks.append({'path':str(lock.relative_to(tree)),'sha256':hashlib.sha256(raw).hexdigest()})
            for forbidden in FORBIDDEN_NAMES:
                if re.search(r'(?m)^\s*name\s*=\s*"'+re.escape(forbidden)+'"',raw.decode('utf-8')):
                    raise ValueError('resolved dependency lock includes optional business: '+forbidden)
        report['resolved_locks']=locks
        # SDK/system dynamic dependencies remain explicit; no portable bundle is claimed.
        deps=run(['bash',str(driver),'ldd',str(binary)],out/'dynamic-dependencies.log',tree,env,30)
        if 'not found' in deps:raise ValueError('minimal executable has unresolved runtime dependency')
        if hashlib.sha256(binary.read_bytes()).hexdigest()!=report['binary_sha256']:raise ValueError('binary changed during verification')
        report['status']='PASS';report['portable_distribution_bundle']=False
        print('minimal host gate passed')
    finally:
        try:
            if runtime is not None:runtime.cleanup()
        finally:summary.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')


if __name__=='__main__':main()
