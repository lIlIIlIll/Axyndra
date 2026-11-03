import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('distribution_members', Path(__file__).with_name('package_distribution.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PackageMembersDistributionTests(unittest.TestCase):
    def fixture(self, root):
        for identity, kind in [('skills', 'context_provider'), ('workspace', 'tool'), ('shell', 'service'), ('models', 'model_provider')]:
            package = root / 'plugins' / identity
            package.mkdir(parents=True)
            (package / 'axyndra.plugin.json').write_text(json.dumps(dict(id=identity, version='1.0.0',
                entry_kind='native-executable', contributions=[dict(kind=kind, name=identity)])))
            (package / 'member.bin').write_bytes(b'packaging input only; no runtime execution assertion')
        context = root / 'context-recipe.json'
        context.write_text(json.dumps(dict(schema='axyndra.context-profile/v1', id='coding',
            provider=dict(package='plugins/skills', contribution='skills', enabled_by_distribution=True),
            context=dict(version=4))))
        recipe = root / 'package-recipe.json'
        document = dict(schema='axyndra.package-defaults/v1', plugins=[
            dict(package='plugins/workspace', enabled=True),
            dict(package='plugins/shell', enabled=False),
            dict(package='plugins/models', enabled=True),
        ])
        recipe.write_text(json.dumps(document))
        return context, recipe, document

    def assert_unpublished(self, root):
        self.assertFalse((root / 'distribution.json').exists())
        self.assertFalse((root / 'profiles/coding-context.json').exists())

    def test_independent_package_bytes_and_enabled_choices_are_sealed_without_authority(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            context, recipe, _ = self.fixture(root)
            result = module.seal_distribution(root, context, packages=recipe)
            self.assertEqual(len(result['plugins']), 4)
            self.assertEqual([p['enabled'] for p in result['plugins']], [True, True, False, True])
            self.assertEqual(set(result), {'schema', 'id', 'plugins', 'context'})
            for member in result['plugins']:
                self.assertEqual(set(member), {'path', 'namespace', 'version', 'package_digest', 'enabled'})
                self.assertEqual(member['package_digest'], module.package_digest(root / member['path']))
            self.assertEqual(json.loads((root / 'distribution.json').read_text()), result)
            original = (root / 'distribution.json').read_bytes()
            (root / 'plugins/workspace/member.bin').write_bytes(b'changed package content')
            self.assertNotEqual(result['plugins'][1]['package_digest'], module.package_digest(root / 'plugins/workspace'))
            self.assertEqual((root / 'distribution.json').read_bytes(), original)

    def test_paths_and_nonboolean_enabling_are_rejected_before_publication(self):
        for path in ['../workspace', '/workspace', 'plugins//workspace', 'plugins/./workspace', 'plugins\\workspace', 'plugins/$WORKSPACE']:
            with self.subTest(path=path), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                context, recipe, document = self.fixture(root)
                document['plugins'][0]['package'] = path
                recipe.write_text(json.dumps(document))
                with self.assertRaises(ValueError):
                    module.seal_distribution(root, context, packages=recipe)
                self.assert_unpublished(root)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            context, recipe, document = self.fixture(root)
            document['plugins'][0]['enabled'] = 1
            recipe.write_text(json.dumps(document))
            with self.assertRaises(ValueError):
                module.seal_distribution(root, context, packages=recipe)
            self.assert_unpublished(root)

    def test_credentials_permissions_and_autostart_are_not_package_recipe_fields(self):
        for field in ['capabilities', 'environment', 'credential', 'auto_start', 'process', 'network']:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                context, recipe, document = self.fixture(root)
                document['plugins'][1][field] = True
                recipe.write_text(json.dumps(document))
                with self.assertRaises(ValueError):
                    module.seal_distribution(root, context, packages=recipe)
                self.assert_unpublished(root)

    def test_duplicate_context_namespace_or_package_cannot_shadow_defaults(self):
        for scenario in ['namespace', 'path']:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                context, recipe, document = self.fixture(root)
                if scenario == 'namespace':
                    path = root / 'plugins/workspace/axyndra.plugin.json'
                    manifest = json.loads(path.read_text())
                    manifest['id'] = 'skills'
                    path.write_text(json.dumps(manifest))
                else:
                    document['plugins'].append(copy.deepcopy(document['plugins'][0]))
                    recipe.write_text(json.dumps(document))
                with self.assertRaises(ValueError):
                    module.seal_distribution(root, context, packages=recipe)
                self.assert_unpublished(root)

    def test_native_contribution_and_combined_host_count_are_required(self):
        for scenario in ['not-native', 'no-contribution', 'too-many']:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                context, recipe, document = self.fixture(root)
                if scenario == 'too-many':
                    document['plugins'] = [dict(package='plugins/member-' + str(i), enabled=True) for i in range(32)]
                    recipe.write_text(json.dumps(document))
                else:
                    path = root / 'plugins/models/axyndra.plugin.json'
                    manifest = json.loads(path.read_text())
                    if scenario == 'not-native':
                        manifest['entry_kind'] = 'javascript'
                    else:
                        manifest['contributions'] = []
                    path.write_text(json.dumps(manifest))
                with self.assertRaises(ValueError):
                    module.seal_distribution(root, context, packages=recipe)
                self.assert_unpublished(root)


if __name__ == '__main__':
    unittest.main(verbosity=2)
