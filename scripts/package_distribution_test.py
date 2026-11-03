import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest

from package_distribution import package_digest, seal_distribution


class DistributionTests(unittest.TestCase):
    def test_v2_tree_framing_includes_utf8_path_and_executable_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / '雪.txt'
            path.write_bytes(b'known bytes')
            executable = 'true' if os.access(path, os.X_OK) else 'false'
            framing = (f'axyndra-package-tree-v2\n{len(path.name.encode())}:{path.name}:'
                       f'{executable}:11:{hashlib.sha256(b"known bytes").hexdigest()}\n')
            self.assertEqual(package_digest(root), 'sha256:' + hashlib.sha256(framing.encode()).hexdigest())
            old = package_digest(root)
            path.write_bytes(b'changed')
            self.assertNotEqual(package_digest(root), old)

    def test_real_files_manifest_binds_exact_package_recipe_and_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / 'plugins/skills'
            package.mkdir(parents=True)
            (package / 'axyndra.plugin.json').write_text(json.dumps({
                'id': 'skills', 'version': '1.0.0', 'entry_kind': 'native-executable',
                'contributions': [{'kind': 'context_provider', 'name': 'skills'}]}))
            source = Path(__file__).resolve().parents[1] / 'profiles/coding-context.json'
            manifest = seal_distribution(root, source)
            self.assertEqual(manifest['plugins'][0]['package_digest'], package_digest(package))
            self.assertEqual(manifest['plugins'][0]['namespace'], 'axyndra:skills')
            self.assertTrue(manifest['plugins'][0]['enabled'])
            recipe = (root / manifest['context']['recipe']).read_bytes()
            self.assertEqual(manifest['context']['sha256'], hashlib.sha256(recipe).hexdigest())
            self.assertIn('${workspace_root}', recipe.decode())
            self.assertNotIn('capabilities', manifest)
            original = (root / 'distribution.json').read_bytes()
            with self.assertRaises(ValueError):
                seal_distribution(root, source)
            self.assertEqual((root / 'distribution.json').read_bytes(), original)

    def test_unknown_profile_and_path_escape_never_publish_manifest(self):
        original = json.loads((Path(__file__).resolve().parents[1] / 'profiles/coding-context.json').read_text())
        for path in ['../skills', '/tmp/skills', 'plugins\\skills']:
            with self.subTest(path=path), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                changed = json.loads(json.dumps(original))
                changed['provider']['package'] = path
                recipe = root / 'input.json'
                recipe.write_text(json.dumps(changed))
                with self.assertRaises(ValueError):
                    seal_distribution(root, recipe)
                self.assertFalse((root / 'distribution.json').exists())


if __name__ == '__main__':
    unittest.main()
