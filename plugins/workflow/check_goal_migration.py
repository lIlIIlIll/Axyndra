#!/usr/bin/env python3
"""Installed Native Goal migration wire tests; no canonical Host authority claim.

The existing wire fixture supplies data and service-response DTOs. Actual Source,
Root approval, CAS, cancellation and continuation gates execute in Product/Store.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest
import check as workflow


def history():
    return dict(id='historical-goal', objective='preserve history 雪', status='active',
                tokenBudget=1000, tokensUsed=123, timeUsedSeconds=8,
                createdAt=1000, updatedAt=2000, enabled=True,
                baselineTokens=400, accountedAt=2000)


def migration(document):
    encoded = json.dumps(document, ensure_ascii=False, separators=(',', ':'))
    return dict(op='migrate_legacy', legacy_document=encoded,
                legacy_sha256=hashlib.sha256(encoded.encode('utf-8')).hexdigest())


def command(p, text):
    frame = workflow.document_frame(p, 'command', {'command_args': text}, name='goal')
    p.send(frame)
    return p.next()


class GoalLegacyMigrationProtocolTests(unittest.TestCase):
    def test_migration_first_prepare_requests_only_the_logical_goal_document(self):
        with workflow.peer() as p:
            frame = workflow.document_frame(p, 'prepare', {'input': migration(history())}, name='goal')
            p.send(frame)
            response = p.next()
            self.assertTrue(response['ok'], response)
            self.assertEqual(response['result'], {'document_read': {'keys': ['goal']}})

    def test_exact_eleven_field_history_is_preserved_without_usage_or_control(self):
        original = history()
        with workflow.peer() as p:
            prepared, response = workflow.goal_prepare(p, migration(original), observation=False)
            self.assertTrue(response['ok'], response)
            self.assertNotIn('user_control', response['result'])
            self.assertNotIn('continuation', response['result'])
            intent = prepared['host_plan']['intents'][0]
            self.assertEqual(intent['mode'], 'compare_exchange')
            self.assertEqual(json.loads(intent['next_json']), original)
            result = workflow.goal_execute(p, prepared)
            self.assertTrue(result['ok'], result)
            self.assertEqual(result['result'], 'Legacy goal imported. Use /goal resume to approve continuation.')
            self.assertEqual(original, history())

    def test_existing_canonical_document_is_rejected_before_a_service_request(self):
        with workflow.peer() as p:
            prepared, response = workflow.goal_prepare(p, migration(history()), history(), observation=False)
            self.assertIsNone(prepared)
            self.assertFalse(response['ok'])
            self.assertEqual(response['type'], 'result')
            self.assertEqual(response['result']['code'], 'workflow.goal_migration_conflict')

    def test_wrong_exact_legacy_digest_is_rejected_without_a_proposal(self):
        arguments = migration(history())
        arguments['legacy_sha256'] = '0' * 64
        with workflow.peer() as p:
            prepared, response = workflow.goal_prepare(p, arguments, observation=False)
            self.assertIsNone(prepared)
            self.assertFalse(response['ok'])
            self.assertEqual(response['result']['code'], 'workflow.goal_legacy_invalid')

    def test_unsupported_fields_types_and_budget_preserve_the_supplied_history(self):
        documents = [dict(history(), formatVersion=2), dict(history(), tokensUsed='123'),
                     dict(history(), tokenBudget=0), dict(history(), enabled='true')]
        for document in documents:
            original = copy.deepcopy(document)
            with self.subTest(document=document), workflow.peer() as p:
                prepared, response = workflow.goal_prepare(p, migration(document), observation=False)
                self.assertIsNone(prepared)
                self.assertFalse(response['ok'])
                self.assertEqual(response['type'], 'result')
                self.assertEqual(document, original)

    def test_command_forwards_only_frozen_data_and_requires_an_explicit_payload(self):
        arguments = migration(history())
        payload = {key: arguments[key] for key in ['legacy_document', 'legacy_sha256']}
        with workflow.peer() as p:
            response = command(p, 'migrate ' + json.dumps(payload, separators=(',', ':')))
            self.assertTrue(response['ok'], response)
            self.assertEqual(response['result'], dict(schema='axyndra.command-proposal/v1',
                                                     local_tool='goal', input=arguments))
            bare = command(p, 'migrate')
            self.assertFalse(bare['ok'])
            self.assertEqual(bare['result']['code'], 'goal.legacy_payload_required')
            payload['legacy_sha256'] = '0' * 64
            changed = command(p, 'migrate ' + json.dumps(payload, separators=(',', ':')))
            self.assertFalse(changed['ok'])
            self.assertEqual(changed['result']['code'], 'goal.legacy_digest_invalid')

    def test_changed_frozen_migration_intent_is_rejected_before_child_io(self):
        with workflow.peer() as p:
            prepared, response = workflow.goal_prepare(p, migration(history()), observation=False)
            self.assertTrue(response['ok'], response)
            prepared['host_plan']['intents'][0]['next_json'] = 'null'
            frame = workflow.document_frame(p, 'tool', prepared, name='goal')
            p.send(frame)
            changed = p.next()
            self.assertFalse(changed['ok'])
            self.assertEqual(changed['type'], 'result')
            self.assertEqual(changed['result']['code'], 'workflow.document_plan_changed')

    def test_imported_enabled_data_requires_a_separate_resume_control_proposal(self):
        original = history()
        with workflow.peer() as p:
            imported, response = workflow.goal_prepare(p, migration(original), observation=False)
            self.assertTrue(response['ok'], response)
            self.assertNotIn('user_control', response['result'])
            self.assertTrue(workflow.goal_execute(p, imported)['ok'])
            proposal = command(p, 'resume')
            self.assertTrue(proposal['ok'], proposal)
            self.assertNotIn('user_control', proposal['result'])
            resumed, response = workflow.goal_prepare(p, proposal['result']['input'], original)
            self.assertTrue(response['ok'], response)
            self.assertEqual(response['result']['user_control']['action'], 'resume_or_create')
            self.assertEqual(response['result']['user_control']['document_key'], 'goal')
            document = json.loads(resumed['host_plan']['intents'][0]['next_json'])
            self.assertEqual(document['tokensUsed'], original['tokensUsed'])
            self.assertEqual(document['timeUsedSeconds'], original['timeUsedSeconds'])
            self.assertEqual(document['baselineTokens'], 22)
            self.assertTrue(workflow.goal_execute(p, resumed)['ok'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--package', type=Path, required=True)
    arguments = parser.parse_args()
    package = arguments.package.resolve(strict=True)
    manifest = json.loads((package / 'axyndra.plugin.json').read_text(encoding='utf-8'))
    workflow.BINARY = (package / manifest['entrypoint']).resolve(strict=True)
    if not workflow.BINARY.is_relative_to(package):
        raise SystemExit('entrypoint escapes package')
    unittest.main(argv=[sys.argv[0]], verbosity=2)
