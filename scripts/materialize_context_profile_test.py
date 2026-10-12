import copy
import json
from pathlib import Path
import tempfile
import unittest

from materialize_context_profile import materialize


class ContextProfileTests(unittest.TestCase):
    def profile(self):
        return json.loads((Path(__file__).resolve().parents[1] / 'profiles/coding-context.json').read_text())

    def test_coding_roots_and_exact_binding_are_declarative(self):
        with tempfile.TemporaryDirectory() as root:
            value = json.loads(materialize(self.profile(), settings_root=Path(root) / 'settings',
                workspace_root=root, namespace='axyndra:skills', package_digest='sha256:' + 'a' * 64))
            self.assertEqual(value['version'], 4)
            self.assertEqual(value['package_digest'], 'sha256:' + 'a' * 64)
            self.assertEqual([x['path'] for x in value['resources']], ['managed', 'user', 'workspace'])
            self.assertTrue(value['resources'][0]['source'].endswith('/settings/managed-skills'))
            self.assertTrue(value['resources'][2]['source'].endswith('/.omp/skills'))
            self.assertEqual(value['component_sources']['index']['max_directories'], 1024)
            self.assertNotIn('capabilities', value)

    def test_unknown_profile_variable_and_noncanonical_digest_fail(self):
        profile = self.profile()
        for digest in ['a' * 64, 'sha256:*', 'sha256:' + 'A' * 64]:
            with self.subTest(digest=digest), self.assertRaises(ValueError):
                materialize(profile, settings_root='.', workspace_root='.', namespace='p', package_digest=digest)
        changed = copy.deepcopy(profile)
        changed['context']['resources'][0]['source'] = '${ambient_home}/skills'
        with self.assertRaises(ValueError):
            materialize(changed, settings_root='.', workspace_root='.', namespace='p', package_digest='sha256:' + 'a' * 64)


if __name__ == '__main__':
    unittest.main()
