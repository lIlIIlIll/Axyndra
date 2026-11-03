"""Actual package metadata only; these tests do not claim native execution."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('workspace_distribution',ROOT/'scripts/package_distribution.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class WorkspaceDistributionTests(unittest.TestCase):
    def fixture(self,root):
        for identity,contributions in [('skills',[dict(kind='context_provider',name='skills')]),
            ('workspace',[dict(kind='tool',name=name) for name in ['read','grep','glob','edit','write']])]:
            target=root/'plugins'/identity;target.mkdir(parents=True)
            (target/'axyndra.plugin.json').write_text(json.dumps(dict(id=identity,version='1',entry_kind='native-executable',
                contributions=contributions,capabilities=['process.readview'] if identity=='workspace' else [])))
            (target/'immutable-input').write_bytes(b'metadata input; no execution or authority')
        profile=root/'profile.json';profile.write_text(json.dumps(dict(schema='axyndra.context-profile/v1',id='coding',
            provider=dict(package='plugins/skills',contribution='skills',enabled_by_distribution=True),context=dict(version=4))))
        recipe=root/'packages.json';body=dict(schema='axyndra.package-defaults/v1',workspace='plugins/workspace',
            plugins=[dict(package='plugins/workspace',enabled=True)])
        recipe.write_text(json.dumps(body));return profile,recipe,body
    def test_selected_actual_package_digest_is_data_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);profile,recipe,_=self.fixture(root)
            result=module.seal_distribution(root,profile,packages=recipe)
            self.assertEqual(result['workspace'],dict(namespace='axyndra:workspace',package_digest=module.package_digest(root/'plugins/workspace')))
            self.assertEqual(set(result['workspace']),{'namespace','package_digest'})
            self.assertFalse({'capabilities','grants','credentials','process','auto_start'} & set(result))
            old=(root/'distribution.json').read_bytes();(root/'plugins/workspace/immutable-input').write_bytes(b'changed')
            self.assertNotEqual(result['workspace']['package_digest'],module.package_digest(root/'plugins/workspace'))
            self.assertEqual(old,(root/'distribution.json').read_bytes())
    def test_disabled_missing_family_and_extra_requested_power_cannot_be_selected(self):
        for fault in ['disabled','missing','family','power']:
            with self.subTest(fault=fault),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);profile,recipe,body=self.fixture(root)
                if fault=='disabled':body['plugins'][0]['enabled']=False
                if fault=='missing':body['workspace']='plugins/absent'
                manifest=root/'plugins/workspace/axyndra.plugin.json';document=json.loads(manifest.read_text())
                if fault=='family':document['contributions'].pop()
                if fault=='power':document['capabilities'].append('process.start')
                recipe.write_text(json.dumps(body));manifest.write_text(json.dumps(document))
                with self.assertRaises(ValueError):module.seal_distribution(root,profile,packages=recipe)
                self.assertFalse((root/'distribution.json').exists())
    def test_selection_cannot_add_authority_fields_and_minimal_has_no_selection(self):
        for field in ['capabilities','grants','credentials','auto_start']:
            with self.subTest(field=field),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);profile,recipe,body=self.fixture(root);body[field]=True;recipe.write_text(json.dumps(body))
                with self.assertRaises(ValueError):module.seal_distribution(root,profile,packages=recipe)
                self.assertFalse((root/'distribution.json').exists())
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);profile=root/'minimal.json';profile.write_text(json.dumps(dict(schema='axyndra.minimal-profile/v1',id='minimal',plugins=[],context=None)))
            output=root/'distribution';output.mkdir();result=module.seal_distribution(output,profile)
            self.assertEqual(set(result),{'schema','id','plugins','context'})
            self.assertEqual(result['plugins'],[]);self.assertIsNone(result['context'])

if __name__=='__main__':unittest.main(verbosity=2)
