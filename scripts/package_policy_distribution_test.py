import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('distribution_under_test', Path(__file__).with_name('package_distribution.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class PolicyDistributionTests(unittest.TestCase):
    def fixture(self, root):
        for identity, kind, name in [('skills','context_provider','skills'),('memory','provider','memory'),('compaction','provider','summarize')]:
            package = root/'plugins'/identity; package.mkdir(parents=True)
            (package/'axyndra.plugin.json').write_text(json.dumps(dict(id=identity, version='1.0.0', entry_kind='native-executable',
                contributions=[dict(kind=kind,name=name)])))
            (package/'native-fixture').write_bytes(b'actual immutable packaging input')
        profile = root/'context-source.json'
        profile.write_text(json.dumps(dict(schema='axyndra.context-profile/v1',id='coding',
            provider=dict(package='plugins/skills',contribution='skills',enabled_by_distribution=True),context=dict(version=4))))
        policies = root/'policy-source.json'
        policies.write_text(json.dumps(dict(schema='axyndra.policy-defaults/v1',bindings=dict(
            memory=dict(package='plugins/memory',provider='memory'),compaction=dict(package='plugins/compaction',provider='summarize')))))
        return profile,policies

    def test_complete_bundle_pins_actual_package_bytes_and_both_policy_contributions(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);profile,policies=self.fixture(root)
            value=module.seal_distribution(root,profile,policies)
            self.assertEqual(len(value['plugins']),3)
            self.assertEqual(value['policies'],{'memory':{'namespace':'axyndra:memory','provider':'memory'},
                'compaction':{'namespace':'axyndra:compaction','provider':'summarize'}})
            for package in value['plugins']:
                self.assertEqual(package['package_digest'],module.package_digest(root/package['path']))
            self.assertEqual(json.loads((root/'distribution.json').read_text()),value)

    def test_bad_policy_member_and_unknown_shape_never_publish_a_prefix(self):
        for change in ['../outside','/absolute','plugins//memory','plugins\\memory','unknown-field']:
            with self.subTest(change=change),tempfile.TemporaryDirectory() as d:
                root=Path(d);profile,policies=self.fixture(root)
                document=json.loads(policies.read_text())
                if change=='unknown-field':document['bindings']['memory']['credential']='not-a-grant'
                else:document['bindings']['memory']['package']=change
                policies.write_text(json.dumps(document))
                with self.assertRaises(ValueError):module.seal_distribution(root,profile,policies)
                self.assertFalse((root/'distribution.json').exists())
                self.assertFalse((root/'profiles/coding-context.json').exists())

    def test_missing_actual_contribution_is_not_a_policy(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);profile,policies=self.fixture(root)
            path=root/'plugins/memory/axyndra.plugin.json';document=json.loads(path.read_text())
            document['contributions']=[dict(kind='tool',name='memory')];path.write_text(json.dumps(document))
            with self.assertRaises(ValueError):module.seal_distribution(root,profile,policies)
            self.assertFalse((root/'distribution.json').exists())

    def test_namespace_aliases_cannot_make_two_conflicting_defaults(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);profile,policies=self.fixture(root)
            path=root/'plugins/compaction/axyndra.plugin.json';document=json.loads(path.read_text());document['id']='memory';path.write_text(json.dumps(document))
            with self.assertRaises(ValueError):module.seal_distribution(root,profile,policies)
            self.assertFalse((root/'distribution.json').exists())

    def test_existing_distribution_cannot_be_overwritten(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);profile,policies=self.fixture(root)
            module.seal_distribution(root,profile,policies)
            original=(root/'distribution.json').read_bytes()
            with self.assertRaises(ValueError):module.seal_distribution(root,profile,policies)
            self.assertEqual((root/'distribution.json').read_bytes(),original)

    def test_portable_read_scopes_are_explicit_manifest_data(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);profile,policies=self.fixture(root)
            source=root/'read-scopes.json';expected=dict(version=1,roots=['${settings_root}/managed-skills','${settings_root}/skills'])
            source.write_text(json.dumps(expected))
            value=module.seal_distribution(root,profile,policies,source)
            self.assertEqual(value['read_scopes'],expected)
            self.assertEqual(json.loads((root/'distribution.json').read_text())['read_scopes'],expected)
            self.assertEqual(len(value['plugins']),3)

    def test_unsafe_read_scope_templates_never_publish_defaults(self):
        bad=['${settings_root}','${settings_root}/plugins','${settings_root}/../state','${HOME}/skills',
             '${settings_root}/x/$HOME','${settings_root}/credentials','${settings_root}/x/.git','/absolute']
        for item in bad:
            with self.subTest(item=item),tempfile.TemporaryDirectory() as d:
                root=Path(d);profile,policies=self.fixture(root)
                source=root/'read-scopes.json';source.write_text(json.dumps(dict(version=1,roots=[item])))
                with self.assertRaises(ValueError):module.seal_distribution(root,profile,policies,source)
                self.assertFalse((root/'distribution.json').exists())
                self.assertFalse((root/'profiles/coding-context.json').exists())

    def test_workflow_plan_selection_is_bound_to_actual_pure_tool_and_package_bytes(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);profile,policies=self.fixture(root)
            package=root/'plugins/workflow';package.mkdir()
            (package/'axyndra.plugin.json').write_text(json.dumps(dict(id='workflow',version='2.1.0',entry_kind='native-executable',contributions=[
                dict(kind='provider',name='propose'),dict(kind='tool',name='plan_write',execution_profile='data_only')])))
            (package/'native-fixture').write_bytes(b'packaging metadata only; no execution claim')
            value=json.loads(policies.read_text());value['bindings']['workflow']=dict(package='plugins/workflow',provider='propose',plan_tool='plan_write')
            policies.write_text(json.dumps(value))
            actual=module.seal_distribution(root,profile,policies)
            self.assertEqual(actual['policies']['workflow'],dict(namespace='axyndra:workflow',provider='propose',plan_tool='plan_write'))
            selected=next(row for row in actual['plugins'] if row['namespace']=='axyndra:workflow')
            self.assertEqual(selected['package_digest'],module.package_digest(package))

    def test_invalid_plan_selection_or_unrestricted_contribution_never_publishes_defaults(self):
        for bad in ['missing','brokered','unknown_profile','non_text','foreign_binding']:
            with self.subTest(bad=bad),tempfile.TemporaryDirectory() as d:
                root=Path(d);profile,policies=self.fixture(root)
                package=root/'plugins/workflow';package.mkdir()
                tools=[] if bad=='missing' else [dict(kind='tool',name='plan_write',**({} if bad=='brokered' else dict(execution_profile='arbitrary' if bad=='unknown_profile' else 'data_only')))]
                (package/'axyndra.plugin.json').write_text(json.dumps(dict(id='workflow',version='2.1.0',entry_kind='native-executable',contributions=[dict(kind='provider',name='propose'),*tools])))
                value=json.loads(policies.read_text());value['bindings']['workflow']=dict(package='plugins/workflow',provider='propose',plan_tool=17 if bad=='non_text' else 'plan_write')
                if bad=='foreign_binding':value['bindings']['memory']['plan_tool']='plan_write'
                policies.write_text(json.dumps(value))
                with self.assertRaises(ValueError):module.seal_distribution(root,profile,policies)
                self.assertFalse((root/'distribution.json').exists())
                self.assertFalse((root/'profiles/coding-context.json').exists())

if __name__=='__main__': unittest.main(verbosity=2)
