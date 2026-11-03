"""Real packaged compact-read protocol controls; no Product authority claim."""
import unittest
import check
from check_payload import PayloadPeer

class LspCompactReadTests(unittest.TestCase):
 def test_explicit_compact_reads_preserve_real_backend_controls_and_unicode(self):
  peer=PayloadPeer()
  try:
   self.assertTrue(peer.start()['ok'])
   expected=('control \x00 \x01 quote" slash\\ 雪😀\n'*2048)
   before=len(peer.writes);prepared,intents=peer.prepare('hover',check.input_value(1,expected))
   self.assertEqual(len(peer.writes),before)
   result=peer.execute(prepared,intents);self.assertTrue(result['ok'],result)
   self.assertEqual(result['result']['result']['value'],dict(contents=expected,version=1))
   self.assertEqual(len(peer.writes),before+1)
   self.assertTrue(peer.channel_reads)
   self.assertTrue(all(item['encoding']=='base64' and item['maximum']==32768 and item['bytes']<=32768 for item in peer.channel_reads))
   self.assertGreater(sum(item['bytes'] for item in peer.channel_reads),32768)
  finally:peer.close()
 def test_noncanonical_base64_is_rejected_by_the_actual_native_reader(self):
  for encoded in ('AB==','AAF=','AA=A','__8='):
   peer=check.Peer()
   try:
    peer.poison_channel_read=dict(bytes_base64=encoded,eof=False)
    self.assertFalse(peer.start()['ok'])
    self.assertTrue(peer.channel_reads)
    self.assertFalse(any(m.get('method') in ('textDocument/didOpen','textDocument/hover') for m in peer.messages()))
   finally:peer.close()
 def test_wrong_representation_or_oversized_decoded_chunk_cannot_fall_back_or_replay(self):
  for poisoned in (dict(bytes_hex='00',eof=False),dict(bytes_base64='AA==',bytes_hex='00',eof=False),
                   dict(bytes_base64='AA==',eof='false'),dict(bytes_base64='A'*43692,eof=False)):
   peer=check.Peer()
   try:
    self.assertTrue(peer.start()['ok'])
    prepared,intents=peer.prepare('hover',check.input_value());before=len(peer.writes)
    peer.poison_channel_read=poisoned
    result=peer.execute(prepared,intents)
    self.assertFalse(result['ok']);self.assertEqual(result['result']['status'],'unknown')
    self.assertEqual(len(peer.writes),before+1)
    self.assertEqual(sum(m.get('method')=='textDocument/hover' for m in peer.messages()),1)
   finally:peer.close()
