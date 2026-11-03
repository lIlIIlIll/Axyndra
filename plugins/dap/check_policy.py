"""Real packaged session policy -> exact frozen DAP bytes -> actual peer."""
import unittest
from check import Peer, input_value


class DapSessionPolicyPackageTests(unittest.TestCase):
    def setUp(self):
        self.peer = Peer()
        self.addCleanup(self.peer.close)
        self.assertTrue(self.peer.start()['ok'])

    def call(self, action, arguments=None, command='', following=None):
        prepared, intents = self.peer.prepare(action, input_value(arguments, command, following))
        before = len(self.peer.writes)
        result = self.peer.execute(prepared, intents)
        self.assertEqual(len(self.peer.writes), before + 1, result)
        self.assertEqual(self.peer.writes[-1].hex(), intents[0]['bytes_hex'])
        return result

    def test_source_item_cache_is_pure_and_duplicate_preserves_old_options(self):
        p = self.peer
        before = len(p.writes)
        p.prepare('set_breakpoint', input_value(dict(file='/fixture/main.py', line=99)))
        self.assertEqual(len(p.writes), before)
        for action, args in [
            ('set_breakpoint', dict(file='/fixture/main.py', line=2, condition='original', hit_condition='4')),
            ('set_breakpoint', dict(file='/fixture/main.py', line=2, condition='ignored')),
            ('set_breakpoint', dict(file='/fixture/main.py', line=3)),
            ('remove_breakpoint', dict(file='/fixture/main.py', line=2)),
        ]:
            self.assertTrue(self.call(action, args)['ok'])
        messages = [v['arguments'] for v in p.messages() if v['command'] == 'setBreakpoints']
        self.assertEqual(messages[0]['breakpoints'], [dict(line=2, condition='original', hitCondition='4')])
        self.assertEqual(messages[1], messages[0])
        self.assertEqual(messages[2]['breakpoints'], messages[0]['breakpoints'] + [dict(line=3)])
        self.assertEqual(messages[3], dict(source=dict(path='/fixture/main.py'), breakpoints=[dict(line=3)], sourceModified=False))

    def test_function_instruction_data_have_independent_complete_lists(self):
        calls = [
            ('set_breakpoint', dict(function='main', condition='x')),
            ('set_breakpoint', dict(function='other')),
            ('remove_breakpoint', dict(function='main')),
            ('set_instruction_breakpoint', dict(instruction_reference='0x40', offset=0)),
            ('set_instruction_breakpoint', dict(instruction_reference='0x40', offset=4, hit_condition='2')),
            ('remove_instruction_breakpoint', dict(instruction_reference='0x40', offset=0)),
            ('set_data_breakpoint', dict(data_id='first', access_type='read')),
            ('set_data_breakpoint', dict(data_id='second', access_type='write')),
            ('remove_data_breakpoint', dict(data_id='first')),
        ]
        for action, args in calls:
            self.assertTrue(self.call(action, args)['ok'])
        for command, expected in [
            ('setFunctionBreakpoints', [dict(name='other')]),
            ('setInstructionBreakpoints', [dict(instructionReference='0x40', offset=4, hitCondition='2')]),
            ('setDataBreakpoints', [dict(dataId='second', accessType='write')]),
        ]:
            rows = [v for v in self.peer.messages() if v['command'] == command]
            self.assertEqual(len(rows), 3)
            self.assertEqual(rows[-1]['arguments']['breakpoints'], expected)

    def test_raw_following_batch_and_legacy_item_mutation_share_one_cache(self):
        self.assertTrue(self.call('threads', following=[dict(command='setBreakpoints', arguments=dict(
            source=dict(path='/fixture/main.py'), breakpoints=[dict(line=7, column=2)]))])['ok'])
        self.assertTrue(self.call('set_breakpoint', dict(file='/fixture/main.py', line=8))['ok'])
        rows = [v for v in self.peer.messages() if v['command'] == 'setBreakpoints']
        self.assertEqual(rows[-1]['arguments']['breakpoints'], [dict(line=7, column=2), dict(line=8)])
        self.assertEqual([v['command'] for v in self.peer.messages()], ['initialize', 'threads', 'setBreakpoints', 'setBreakpoints'])

    def test_actual_stop_frame_output_and_explicit_legacy_aliases(self):
        stopped = self.call('custom_request', dict(output='safe 雪\n'), command='fixture/observedStop')
        snapshot = stopped['result']['result']['snapshot']
        self.assertEqual((snapshot['status'], snapshot['threadId'], snapshot['stopReason']), ('stopped', 11, 'breakpoint'))
        self.assertEqual(snapshot['outputPreview'], 'safe 雪\n')
        self.assertEqual(snapshot['outputBytes'], len('safe 雪\n'.encode()))
        stack = self.call('stack_trace')
        self.assertEqual(stack['result']['result']['snapshot']['frameId'], 2)
        self.assertTrue(self.call('scopes')['ok'])
        self.assertTrue(self.call('evaluate', dict(expression='answer'))['ok'])
        self.assertTrue(self.call('variables', dict(scope_id=3))['ok'])
        self.assertTrue(self.call('read_memory', dict(memory_reference='0x40', count=0, offset=2))['ok'])
        rows = {v['command']: v['arguments'] for v in self.peer.messages()}
        self.assertEqual(rows['stackTrace']['threadId'], 11)
        self.assertEqual(rows['scopes']['frameId'], 2)
        self.assertEqual(rows['evaluate'], dict(expression='answer', frameId=2, context='repl'))
        self.assertEqual(rows['variables'], dict(variablesReference=3))
        self.assertEqual(rows['readMemory'], dict(memoryReference='0x40', count=0, offset=2))

    def test_known_adapter_error_keeps_dispatched_legacy_cache(self):
        failed = self.call('set_breakpoint', dict(file='/fixture/main.py', line=13))
        self.assertFalse(failed['ok'])
        self.assertEqual(failed['result']['status'], 'complete')
        self.assertTrue(self.call('remove_breakpoint', dict(file='/fixture/main.py', line=13))['ok'])
        rows = [v for v in self.peer.messages() if v['command'] == 'setBreakpoints']
        self.assertEqual(rows[0]['arguments']['breakpoints'], [dict(line=13)])
        self.assertEqual(rows[1]['arguments']['breakpoints'], [])

    def test_optional_snapshot_never_displaces_supported_terminal_bytes(self):
        result = self.call('custom_request', command='fixture/nearResult')
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['result']['result']['responses'][0]['data'], 'x' * 65300)
        self.assertNotIn('snapshot', result['result']['result'])

    def test_ambiguous_alias_or_unproven_relative_source_has_zero_broker_writes(self):
        p = self.peer
        before = len(p.writes)
        for action, args in [
            ('set_breakpoint', dict(file='relative.py', line=1)),
            ('set_breakpoint', dict(function='main', breakpoints=[])),
            ('variables', dict(scope_id=3, variablesReference=4)),
            ('variables', dict(variable_ref='3')),
        ]:
            frame = p.frame(dict(action='call', tool=action, input=input_value(args)), prepare=True)
            self.assertFalse(p.invoke(frame, pure=True)['ok'])
        self.assertEqual(len(p.writes), before)
        self.assertEqual([v['command'] for v in p.messages()], ['initialize'])


    def test_successful_resume_without_continued_cannot_reuse_the_old_implicit_frame(self):
        self.assertTrue(self.call('custom_request', command='fixture/observedStop')['ok'])
        stack = self.call('stack_trace')
        self.assertEqual(stack['result']['result']['snapshot']['frameId'], 2)
        resumed = self.call('continue', dict(thread_id=11, fixture_no_continued=True))
        snapshot = resumed['result']['result']['snapshot']
        self.assertEqual(snapshot['status'], 'running')
        self.assertEqual(snapshot['frameId'], 0)
        self.assertEqual(snapshot['instructionPointerReference'], '')
        observed = resumed['result']['result']['events']
        self.assertEqual(set(observed), {'events', 'omitted'})
        self.assertEqual(observed['omitted'], 0)
        self.assertIsInstance(observed['events'], list)
        for event in observed['events']:
            self.assertEqual(set(event), {'method', 'params'})
        self.assertNotIn('continued', [event['method'] for event in observed['events']])
        before = len(self.peer.writes)
        for action, args in [('scopes', {}), ('disassemble', dict(instructionCount=1))]:
            frame = self.peer.frame(dict(action='call', tool=action, input=input_value(args)), prepare=True)
            self.assertFalse(self.peer.invoke(frame, pure=True)['ok'])
        self.assertEqual(len(self.peer.writes), before)
        evaluated = self.call('evaluate', dict(expression='global'))
        self.assertTrue(evaluated['ok'])
        request = [value for value in self.peer.messages() if value['command'] == 'evaluate'][-1]
        self.assertNotIn('frameId', request['arguments'])
