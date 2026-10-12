import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('distribution_profiles', ROOT / 'scripts/package_distribution.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class DistributionProfileTests(unittest.TestCase):
    def stage_metadata_inputs(self, root, profile):
        context = json.loads((ROOT / 'profiles' / (profile + '-context.json')).read_bytes())
        policy = json.loads((ROOT / 'profiles/coding-policies.json').read_bytes())
        extras = json.loads((ROOT / 'profiles' / (profile + '-plugins.json')).read_bytes())
        members = {context['provider']['package']}
        members.update(binding['package'] for binding in policy['bindings'].values())
        members.update(member['package'] for member in extras['plugins'])
        for member in members:
            source_name = 'model_providers' if member == 'plugins/model-providers' else member.split('/')[-1]
            source = ROOT / 'plugins' / source_name / 'axyndra.plugin.json'
            package = root / member
            package.mkdir(parents=True)
            # Actual contribution manifests, explicitly no native execution claim.
            (package / 'axyndra.plugin.json').write_bytes(source.read_bytes())
            (package / 'metadata-test-input').write_bytes(b'packaging metadata validation only')
        return members

    def seal(self, root, profile):
        return module.seal_distribution(root, ROOT / 'profiles' / (profile + '-context.json'),
            ROOT / 'profiles/coding-policies.json', ROOT / 'profiles/coding-read-scopes.json',
            ROOT / 'profiles' / (profile + '-plugins.json'))

    def test_coding_and_full_resolve_actual_contributions_and_lock_every_member(self):
        packages = {}
        for profile, count in [('coding', 9), ('full', 17)]:
            with self.subTest(profile=profile), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                members = self.stage_metadata_inputs(root, profile)
                result = self.seal(root, profile)
                self.assertEqual(result['id'], profile)
                self.assertEqual(len(result['plugins']), count)
                self.assertEqual({row['path'] for row in result['plugins']}, members)
                packages[profile] = {row['namespace'] for row in result['plugins']}
                for row in result['plugins']:
                    self.assertEqual(row['package_digest'], module.package_digest(root / row['path']))
                    self.assertEqual(set(row), {'path', 'namespace', 'version', 'package_digest', 'enabled'})
                self.assertEqual(set(result['policies']), {'workflow', 'compaction', 'memory'})
                self.assertEqual(result['policies']['workflow'],dict(namespace='axyndra:workflow',provider='propose',plan_tool='plan_write'))
                workflow=next(row for row in result['plugins'] if row['namespace']=='axyndra:workflow')
                self.assertEqual(workflow['package_digest'],module.package_digest(root/workflow['path']))
                self.assertEqual(json.loads((root / 'distribution.json').read_bytes()), result)
        self.assertTrue(packages['coding'] < packages['full'])
        self.assertIn('axyndra:program', packages['coding'])
        self.assertIn('axyndra:mcp-server', packages['full'])

    def test_missing_last_full_member_never_publishes_partial_distribution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.stage_metadata_inputs(root, 'full')
            (root / 'plugins/mcp_server/axyndra.plugin.json').unlink()
            with self.assertRaises((ValueError, FileNotFoundError)):
                self.seal(root, 'full')
            self.assertFalse((root / 'distribution.json').exists())
            self.assertFalse((root / 'profiles/full-context.json').exists())

    def test_changed_member_bytes_invalidate_previously_sealed_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.stage_metadata_inputs(root, 'full')
            result = self.seal(root, 'full')
            original = (root / 'distribution.json').read_bytes()
            for row in result['plugins']:
                member = root / row['path'] / 'metadata-test-input'
                member.write_bytes(b'replacement')
                self.assertNotEqual(row['package_digest'], module.package_digest(member.parent))
            self.assertEqual((root / 'distribution.json').read_bytes(), original)


class ThreeProfileProvenanceTests(unittest.TestCase):
    def provenance_module(self):
        spec = importlib.util.spec_from_file_location('host_provenance', ROOT / 'scripts/package_host_provenance.py')
        loaded = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(loaded)
        return loaded

    def stage_minimal(self, root):
        (root / 'share/axyndra').mkdir(parents=True)
        module.seal_distribution(root / 'share/axyndra', ROOT / 'profiles/minimal-context.json')
        (root / 'bin').mkdir(); (root / 'lib').mkdir()
        # Metadata fixtures are regular bytes, explicitly no executable claim.
        (root / 'bin/axyndra').write_bytes(b'relocated test binary bytes')
        source = root / 'source-input'; source.write_bytes(b'original test binary bytes')
        return source

    def test_minimal_has_zero_optional_defaults_and_records_actual_input_output_bytes(self):
        provenance = self.provenance_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = self.stage_minimal(root)
            result = provenance.publish(root, source, ROOT / 'packaging/distributions.json', 'minimal', provenance.digest(source))
            self.assertEqual(result['expected_host_package'], 'agent_minimal')
            self.assertEqual(result['bundled'], [])
            self.assertEqual(result['default_enabled'], [])
            self.assertEqual(result['core_required'], [])
            self.assertFalse(result['proves_actual_build'])
            self.assertNotEqual(result['source_binary_sha256'], result['packaged_binary_sha256'])
            self.assertEqual(result['host_files']['bin/axyndra'], provenance.digest(root / 'bin/axyndra'))
            original = (root / 'package-provenance.json').read_bytes()
            with self.assertRaises(FileExistsError):
                provenance.publish(root, source, ROOT / 'packaging/distributions.json', 'minimal', provenance.digest(source))
            self.assertEqual((root / 'package-provenance.json').read_bytes(), original)

    def test_changed_source_and_unexpected_defaults_never_publish_provenance(self):
        provenance = self.provenance_module()
        for fault in ['source', 'defaults', 'core', 'authority', 'manifest-authority']:
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); source = self.stage_minimal(root)
                frozen = provenance.digest(source)
                recipe = ROOT / 'packaging/distributions.json'
                if fault == 'source': source.write_bytes(b'changed source after freeze')
                if fault == 'defaults':
                    manifest = root / 'share/axyndra/distribution.json'
                    body = json.loads(manifest.read_bytes()); body['plugins'] = [dict(path='plugins/unexpected', namespace='axyndra:unexpected', version='1', package_digest='sha256:unknown', enabled=True)]
                    manifest.write_text(json.dumps(body))
                if fault == 'manifest-authority':
                    manifest = root / 'share/axyndra/distribution.json'
                    body = json.loads(manifest.read_bytes()); body['capabilities'] = ['process.spawn']
                    manifest.write_text(json.dumps(body))
                if fault in ['core', 'authority']:
                    body = json.loads(recipe.read_bytes())
                    if fault == 'core': body['profiles']['minimal']['core_required'] = ['axyndra:optional']
                    else: body['profiles']['minimal']['capabilities'] = ['process.spawn']
                    recipe = root / 'invalid-recipe'; recipe.write_text(json.dumps(body))
                with self.assertRaises(ValueError):
                    provenance.publish(root, source, recipe, 'minimal', frozen)
                self.assertFalse((root / 'package-provenance.json').exists())

    def test_changed_bundled_bytes_never_publish_host_provenance(self):
        provenance = self.provenance_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); distribution = root / 'share/axyndra'; distribution.mkdir(parents=True)
            fixture = DistributionProfileTests()
            fixture.stage_metadata_inputs(distribution, 'coding'); fixture.seal(distribution, 'coding')
            (root / 'bin').mkdir(); (root / 'lib').mkdir()
            (root / 'bin/axyndra').write_bytes(b'relocated fixture bytes')
            source = root / 'source'; source.write_bytes(b'original fixture bytes')
            (distribution / 'plugins/shell/metadata-test-input').write_bytes(b'changed after sealing')
            with self.assertRaises(ValueError):
                provenance.publish(root, source, ROOT / 'packaging/distributions.json', 'coding', provenance.digest(source))
            self.assertFalse((root / 'package-provenance.json').exists())

    def test_minimal_recipe_rejects_optional_provider_and_existing_output_without_mutation(self):
        for fault in ['plugin', 'provider', 'authority', 'existing']:
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); output = root / 'distribution'; output.mkdir()
                body = json.loads((ROOT / 'profiles/minimal-context.json').read_bytes())
                if fault == 'plugin': body['plugins'] = ['axyndra:optional']
                if fault == 'provider': body['context'] = {'namespace': 'axyndra:optional'}
                if fault == 'authority': body['capabilities'] = ['process.spawn']
                if fault == 'existing': (output / 'existing').write_bytes(b'operator bytes')
                recipe = root / 'invalid-profile'; recipe.write_text(json.dumps(body))
                with self.assertRaises(ValueError): module.seal_distribution(output, recipe)
                self.assertFalse((output / 'distribution.json').exists())
                if fault == 'existing': self.assertEqual((output / 'existing').read_bytes(), b'operator bytes')


if __name__ == '__main__':
    unittest.main(verbosity=2)
