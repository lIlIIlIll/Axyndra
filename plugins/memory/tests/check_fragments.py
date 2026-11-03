"""Native protocol fragment regressions, imported by the formal package gate.

The driver only slices immutable bytes and carries actual policy responses.
It has no lexical/ranking/normalization reimplementation.
"""
import copy
import hashlib
import struct
import unittest

NOW = 1700000000000


class FragmentDriver:
    def __init__(self, peer):
        self.peer, self.sequence = peer, 0

    def call(self, action, **fields):
        self.sequence += 1
        query = dict(schema='axyndra.memory-policy/v1', action=action, snapshot_digest='record-snapshot',
                     page_id=str(self.sequence), **fields)
        reply = self.peer.invoke(query)
        assert reply['ok'], reply
        value = reply['result']['value']
        assert value['snapshot_digest'] == query['snapshot_digest'] and value['page_id'] == query['page_id']
        return value

    @staticmethod
    def chunks(text, width):
        raw = text.encode()
        if not raw:
            yield 0, ''
        at = 0
        while at < len(raw):
            end = min(len(raw), at + width)
            while end < len(raw) and raw[end] & 0xc0 == 0x80:
                end -= 1
            yield at, raw[at:end].decode()
            at = end

    def lexical(self, record, query, width=262144):
        cursor, score = -1, 0
        while cursor < len(query.strip().encode()):
            carry = None
            for field in ['content', 'context']:
                for offset, text in self.chunks(record[field], width):
                    value = self.call('lexical_fragment', record_digest='frozen-record', index=0,
                                      id=record['id'], revision=record['revision'], updated_at=record['updated_at'],
                                      importance_permille=record['importance_permille'], query=query, query_cursor=cursor,
                                      content_bytes=len(record['content'].encode()), context_bytes=len(record['context'].encode()),
                                      field=field, offset=offset, text=text, base_score=score, carry=carry)
                    assert value['next_offset'] == offset + len(text.encode())
                    carry = value['carry']
                    if value['batch_complete']:
                        score = value['raw_score']
            cursor = value['next_query_cursor']
        return value['lexical']

    def inline(self, text, bound=65536, width=262144):
        carry = None
        for offset, part in self.chunks(text, width):
            value = self.call('inline_fragment', record_digest='frozen-record', field='content',
                              offset=offset, total=len(text.encode()), text=part, max_bytes=bound, carry=carry)
            assert value['next_offset'] == offset + len(part.encode())
            carry = value['carry']
            if value['complete']:
                return carry['prefix']
        raise AssertionError('incomplete actual inline response')


def cases(peer_factory, value_reader, record_factory, retrieve_factory):
    class MemoryFragmentProtocolTests(unittest.TestCase):
        peer = peer_factory
        value = value_reader

        def test_correction_large_defaults_are_returned_as_exact_host_data_selectors(self):
            body = ' ' * (5 * 1024 * 1024) + 'new text'
            def ref(source, field, text):
                return dict(source=source, field=field, sha256=hashlib.sha256(text.encode()).hexdigest(), bytes=len(text.encode()))
            current = dict(kind='preference',scope='global',scope_key=ref('current','scope_key',''),
                           content=ref('current','content','before'),context=ref('current','context','old'),importance_permille=750,expires_at=0)
            changes = dict(content=ref('changes','content',body))
            with self.peer() as p:
                driver = FragmentDriver(p)
                nonblank = False
                for offset, part in driver.chunks(body, 262144):
                    value = driver.call('text_nonblank_fragment',field_digest=changes['content']['sha256'],
                                        offset=offset,total=len(body.encode()),text=part)
                    self.assertEqual(value['next_offset'], offset+len(part.encode()))
                    nonblank = value['nonblank']
                    if nonblank:
                        break
                self.assertTrue(nonblank)
                value = driver.call('correct_references',id='a',revision=3,status='active',current=current,
                                    changes=changes,content_nonblank=nonblank)
                self.assertEqual(value['replacement'],dict(current,**changes))
                self.assertEqual((value['id'],value['revision']),('a',3))

        def test_correction_references_cannot_revive_add_fields_or_change_selector_source(self):
            def ref(source, field, text):
                return dict(source=source,field=field,sha256=hashlib.sha256(text.encode()).hexdigest(),bytes=len(text.encode()))
            current = dict(kind='preference',scope='global',scope_key=ref('current','scope_key',''),
                           content=ref('current','content','before'),context=ref('current','context','old'),importance_permille=750,expires_at=0)
            query = dict(schema='axyndra.memory-policy/v1',action='correct_references',snapshot_digest='s',page_id='p',
                         id='a',revision=3,status='active',current=current,changes=dict(context=ref('changes','context','new')),content_nonblank=True)
            with self.peer() as p:
                for bad in [dict(query,status='deleted'),dict(query,content_nonblank=False),dict(query,changes={}),
                            dict(query,changes=dict(source='forged')),
                            dict(query,changes=dict(context=ref('current','context','new')))]:
                    self.assertFalse(p.invoke(bad)['ok'])

        def test_one_record_larger_than_logical_frame_has_exact_late_and_cross_fragment_matches(self):
            original = record_factory(content='x' * 262142 + '文档 NEEDLE' + 'x' * (6 * 1024 * 1024), context='ALPHA')
            with self.peer() as p:
                driver = FragmentDriver(p)
                # The copied old algorithm is exercised directly on the full
                # 8 MiB record by the Cangjie oracle; native also compares a
                # representable record with the same actual matching facts.
                expected = self.value(p, retrieve_factory([record_factory(content='文档 NEEDLE', context='ALPHA')],
                                                          query='needle ALPHA'))['hits'][0]['score']
                self.assertEqual(driver.lexical(original, 'needle ALPHA'), expected)
                self.assertEqual(driver.lexical(original, 'absent'), 0)
                self.assertEqual(len(self.value(p, retrieve_factory([record_factory()]))['hits']), 1)

        def test_long_vector_uses_bounded_native_pages_and_preserves_sequential_sum(self):
            with self.peer() as p:
                driver = FragmentDriver(p)
                dimension, offset, total = 70001, 0, 0
                while offset < dimension:
                    size = min(4096, dimension-offset)
                    # All terms exact integers: large-vector transport witness.
                    value = driver.call('dot_fragment', record_digest='v', index=0, revision=1,
                                        dimension=dimension, offset=offset, query=[1]*size, vector=[2]*size, sum=total)
                    self.assertEqual(value['next_offset'], offset+size)
                    offset, total = value['next_offset'], value['sum']
                self.assertEqual(struct.unpack('>d', bytes.fromhex(total['binary64']))[0], 2*dimension)

        def test_inline_large_pending_whitespace_and_unicode_match_actual_old_normalizer(self):
            with self.peer() as p:
                driver = FragmentDriver(p)
                raw = '\f' * (5*1024*1024) + '雪\r\n  A\tB' + '\f' * (1024*1024)
                self.assertEqual(driver.inline(raw), '雪 A B')
                for text in ['', '  雪\r\n A\tB\f ', 'left'+'\f'*300000+'right']:
                    for bound in [4, 119, 65536]:
                        normalized = driver.inline(text, bound)
                        original = dict(schema='axyndra.memory-policy/v1', action='context', snapshot_digest='oracle',
                                        hits=[dict(record=record_factory(content=text or ' '), score=1000)],
                                        max_bytes=bound, now_millis=NOW)
                        oracle = self.value(p, original)['content']
                        row = dict(id='a', revision=1, kind='preference', scope='workspace', content=normalized, context='')
                        actual = driver.call('context_compose', rows=[row], max_bytes=bound, prefix=None)['content']
                        self.assertEqual(actual, oracle)

        def test_fragment_protocol_rejects_offsets_dimensions_replay_and_oversize(self):
            with self.peer() as p:
                driver = FragmentDriver(p)
                base = dict(schema='axyndra.memory-policy/v1', action='inline_fragment', snapshot_digest='s', page_id='p',
                            record_digest='r', field='content', offset=0, total=1, text='a', max_bytes=10, carry=None)
                completed = self.value(p, base)
                for bad in [dict(base, offset=1), dict(base, carry=completed['carry']),
                            dict(base, text='x'*262145, total=262145), dict(base, max_bytes=65538)]:
                    self.assertFalse(p.invoke(bad)['ok'])
                for size, dimension, offset in [(4097,4097,0),(2,1,0),(0,1,0),(1,1,1)]:
                    bad = dict(schema='axyndra.memory-policy/v1',action='dot_fragment',snapshot_digest='s',page_id='p',
                               record_digest='r',index=0,revision=1,dimension=dimension,offset=offset,
                               query=[1]*size,vector=[1]*size,sum=0)
                    self.assertFalse(p.invoke(bad)['ok'])
    return MemoryFragmentProtocolTests
