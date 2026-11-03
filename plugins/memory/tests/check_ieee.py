"""Exact float data and actual native whole/paged legacy oracle comparisons."""
import copy
import struct
import unittest
from check_fragments import FragmentDriver


def binary64(number):
    return {'binary64': struct.pack('>d', number).hex()}


def cases(peer_factory, value_reader, record_factory, retrieve_factory, paged_retrieve):
    class MemoryIeeeProtocolTests(unittest.TestCase):
        peer = peer_factory
        value = value_reader

        def test_infinity_overflow_and_nan_barriers_match_actual_native_legacy_top_k(self):
            values = [record_factory(f'{i:04}-雪', 'concise 文档' if i % 3 else 'other', context='concise') for i in range(257)]
            vectors = {}
            for i, record in enumerate(values):
                vector = ([float('inf'), -float('inf')] if i in [0, 127, 128, 255, 256] else
                          [1e308, 1e308] if i % 7 == 0 else [-float('inf'), -float('inf')] if i % 5 == 0 else
                          [-0.0, 0.0] if i % 3 == 0 else [i % 11 - 5, 1])
                vectors[record['id']] = list(map(binary64, vector))
            for raw, page_size in [([1, 1], 128), ([1e308, 1e308], 31), ([float('inf'), 1], 127)]:
                query = list(map(binary64, raw))
                original = retrieve_factory(values, query='concise 文档', limit=100)
                original['embeddings'] = dict(state='ready', query=query, records=[
                    dict(id=r['id'], revision=r['revision'], vector=vectors[r['id']]) for r in values])
                with self.peer() as p:
                    expected = self.value(p, original)
                    actual = paged_retrieve(p, values, 'concise 文档', limit=100, embeddings=vectors,
                                            page_size=page_size, query_vector=query)
                    self.assertEqual(actual['hits'], expected['hits'])
                    self.assertEqual((actual['strategy'], actual['embedding_fallback']), ('hybrid', False))

        def test_nan_input_retains_whole_query_fallback_even_after_prior_pages(self):
            values = [record_factory(f'{i:04}') for i in range(257)]
            for failing_query in [True, False]:
                vectors = {r['id']: [binary64(1), binary64(0)] for r in values}
                query = [binary64(float('nan') if failing_query else 1), binary64(0)]
                if not failing_query:
                    vectors[values[200]['id']][0] = binary64(float('nan'))
                original = retrieve_factory(values, limit=100)
                original['embeddings'] = dict(state='ready', query=query, records=[
                    dict(id=r['id'], revision=1, vector=vectors[r['id']]) for r in values])
                with self.peer() as p:
                    expected = self.value(p, original)
                    actual = paged_retrieve(p, values, limit=100, embeddings=vectors, page_size=128, query_vector=query)
                    self.assertEqual(actual['hits'], expected['hits'])
                    self.assertEqual((actual['strategy'], actual['embedding_fallback']), ('lexical_fallback', True))

        def test_exact_dot_carry_does_not_reject_or_round_nonfinite_intermediate_values(self):
            patterns = [([1e308, 1e308, 1], [1e308, 1e308, 1]),
                        ([1, 1, 1], [float('inf'), -float('inf'), 1]),
                        ([float('inf'), 1, 1], [0.0, float('inf'), -0.0]),
                        ([1, 1, 1], [1e16, 1, -1e16])]
            with self.peer() as p:
                driver = FragmentDriver(p)
                for left, right in patterns:
                    args = dict(record_digest='r', index=0, revision=1, dimension=3)
                    original = driver.call('dot_fragment', **args, offset=0,
                                           query=list(map(binary64, left)), vector=list(map(binary64, right)), sum=binary64(0))['sum']
                    for width in [1, 2]:
                        carry = binary64(0)
                        for offset in range(0, 3, width):
                            carry = driver.call('dot_fragment', **args, offset=offset,
                                query=list(map(binary64, left[offset:offset+width])),
                                vector=list(map(binary64, right[offset:offset+width])), sum=carry)['sum']
                        self.assertEqual(carry, original)
                self.assertEqual(p.ready['capabilities'], [])
                self.assertEqual([item['name'] for item in p.ready['tools']], ['retain','recall','reflect','memory_edit','learn','manage_skill','memory_context'])

        def test_float_envelope_and_unpartitioned_nan_merges_fail_closed(self):
            with self.peer() as p:
                args = dict(schema='axyndra.memory-policy/v1', action='dot_fragment', snapshot_digest='s', page_id='p',
                            record_digest='r', index=0, revision=1, dimension=1, offset=0, query=[binary64(1)], vector=[binary64(1)], sum=binary64(0))
                for bad in [dict(binary64='7FF0000000000000'), dict(binary64='7ff000000000000'),
                            dict(binary64='7ff000000000000g'), dict(binary64='3ff0000000000000', authority=True), 'inf']:
                    self.assertFalse(p.invoke(dict(args, query=[bad]))['ok'])
                self.assertFalse(p.invoke(dict(args, query=[binary64(float('nan'))]))['ok'])
                self.assertFalse(p.invoke(dict(args, sum=binary64(-0.0)))['ok'])
                driver = FragmentDriver(p)
                rows = driver.call('score_page', offset=0, query='concise', records=[record_factory('a'), record_factory('b')],
                                   now_millis=1700000000000, embeddings=dict(state='absent', query=[], records=[]))['rows']
                rows[0]['semantic'] = binary64(float('nan'))
                base = dict(schema='axyndra.memory-policy/v1', snapshot_digest='s', page_id='p', mode='semantic')
                self.assertFalse(p.invoke(dict(base, action='sort_page', rows=rows))['ok'])
                self.assertFalse(p.invoke(dict(base, action='merge_page', left=rows[:1], right=rows[1:], left_eof=True, right_eof=True))['ok'])
                parts = driver.call('partition_semantic_page', rows=rows)['groups']
                self.assertEqual([r for part in parts for r in part['rows']], rows)
                self.assertEqual([part['sortable'] for part in parts], [False, True])
                duplicate = copy.deepcopy(rows); duplicate[1] = duplicate[0]
                self.assertFalse(p.invoke(dict(schema='axyndra.memory-policy/v1', snapshot_digest='s', page_id='p',
                                              action='partition_semantic_page', rows=duplicate))['ok'])
    return MemoryIeeeProtocolTests
