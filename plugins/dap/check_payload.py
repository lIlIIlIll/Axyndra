"""Native payload44 framing reused against an actual DAP Content-Length peer."""
import hashlib,json,time,unittest
import check
PROFILE=dict(max_frame_bytes=4194304,max_input_bytes=1048576,max_prepare_bytes=2097152,
             max_result_bytes=4128768,max_directory_bytes=2097152,max_tools=8192,call_timeout_ms=120000)
PAYLOAD=dict(version=1,max_message_bytes=16777216,max_input_bytes=4194304,
             max_prepare_bytes=8388608,max_result_bytes=8388608,max_write_bytes=4128768)
def envelope(invocation,kind,**fields):
 return dict({k:invocation[k] for k in check.IDENTITY},type=kind,payload=dict(schema='axyndra.logical-json/v1',
             window=invocation['payload_window'],transfer_sequence=1,**fields))
class PayloadPeer(check.Peer):
 def __init__(self,timeout=10000,profile=None):
  self.logical_results=0
  super().__init__(timeout=timeout,profile=PROFILE if profile is None else profile)
 def frame(self,*args,**kwargs):
  frame=super().frame(*args,**kwargs);frame['payload_window']='payload-'+frame['id'];return frame
 def send(self,frame):
  if frame['type']=='hello':frame=dict(frame,service_payload_limits=PAYLOAD)
  raw=check.encode(frame)
  if frame['type']=='invoke':
   # Always traverse the same logical profile on input, including tiny calls.
   super().send(envelope(frame,'payload_begin',message_type='invoke',bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest()))
   for offset in range(0,len(raw),16384):super().send(envelope(frame,'payload_chunk',offset=offset,bytes_hex=raw[offset:offset+16384].hex()))
   super().send(envelope(frame,'payload_end'))
  else:super().send(frame)
 def next(self,timeout=15):
  deadline=time.monotonic()+timeout;frame=super().next(timeout)
  if frame['type']!='payload_begin':return frame
  self.logical_results+=1;header=frame['payload']
  assert header==dict(schema='axyndra.logical-json/v1',window=self.current['payload_window'],transfer_sequence=1,
                     message_type='result',bytes=header['bytes'],sha256=header['sha256'])
  assert 0<header['bytes']<=PAYLOAD['max_message_bytes']
  for key in check.IDENTITY:assert frame[key]==self.current[key]
  body=bytearray()
  while True:
   part=super().next(max(.001,deadline-time.monotonic()));assert time.monotonic()<deadline
   for key in check.IDENTITY:assert part[key]==frame[key]
   item=part['payload'];assert item['schema']==header['schema'] and item['window']==header['window'] and item['transfer_sequence']==1
   if part['type']=='payload_end':
    assert set(item)=={'schema','window','transfer_sequence'};break
   assert part['type']=='payload_chunk' and set(item)=={'schema','window','transfer_sequence','offset','bytes_hex'}
   assert item['offset']==len(body)
   raw=bytes.fromhex(item['bytes_hex']);assert 0<len(raw)<=16384 and len(body)+len(raw)<=header['bytes'];body.extend(raw)
  assert len(body)==header['bytes'] and hashlib.sha256(body).hexdigest()==header['sha256']
  value=json.loads(body);assert value['type']=='result' and value['payload_window']==header['window']
  for key in check.IDENTITY:assert value[key]==frame[key]
  return value
 def execute(self,prepared,intents,input=None,cancel=False):
  args=prepared['arguments'];self.selected=intents[0]['bytes_hex'];raw=bytes.fromhex(self.selected)
  encoded_hash=hashlib.sha256(self.selected.encode()).hexdigest()
  payload=dict(schema='axyndra.service-payload/v1',artifact_ref='blob:sha256:'+encoded_hash,encoding='hex',
               bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest(),encoded_sha256=encoded_hash)
  frame=self.frame(dict(action='call',tool=args['tool'],input=args['input'] if input is None else input,
                       host_plan=dict(version='process-channel-intent-v2',binding={},intents=[dict(id='dap-call',payload=payload)])),
                   call=int(prepared['call_id'].split('-')[1]))
  return self.invoke(frame,cancel_after_write=cancel)

class DapPayloadTests(unittest.TestCase):
 def test_three_mib_arguments_and_real_backend_result_survive_repeated_consumers(self):
  peer=PayloadPeer()
  try:
   self.assertTrue(peer.start()['ok'])
   for version in range(1,4):
    expected=('x' if version%2 else 'y')*3145728
    before=len(peer.writes);prepared,intents=peer.prepare('evaluate',check.input_value(dict(expression=expected)))
    self.assertEqual(len(peer.writes),before)
    result=peer.execute(prepared,intents);self.assertTrue(result['ok'],result.get('error'))
    self.assertEqual(result['result']['result']['responses'][0],dict(result=expected,variablesReference=0))
    self.assertEqual(len(peer.writes),before+1)
   self.assertGreaterEqual(peer.logical_results,3) # prepare intents exceed physical frame
   self.assertEqual(sum(m.get('command')=='evaluate' for m in peer.messages()),3)
  finally:peer.close()
 def test_dense_physical_input_is_bounded_before_parse_and_releases_each_rejected_consumer(self):
  peer=PayloadPeer()
  try:
   for index in range(8):
    frame=peer.frame(dict(action='start',configuration=peer.configuration,unexpected=[0]*50000))
    # Deliberately use a physical frame: accounting cannot depend on chunking.
    peer.current=frame;check.Peer.send(peer,frame)
    result=peer.next();self.assertFalse(result['ok']);self.assertEqual(peer.writes,[])
   self.assertTrue(peer.start()['ok'])
  finally:peer.close()

 def test_actual_hanging_request_is_unknown_without_replay_or_cancel_write(self):
  peer=PayloadPeer(timeout=1000,profile=dict(PROFILE,call_timeout_ms=5000))
  try:
   self.assertTrue(peer.start()['ok'])
   prepared,intents=peer.prepare('custom_request',check.input_value(command='fixture/hang'))
   result=peer.execute(prepared,intents)
   self.assertFalse(result['ok']);self.assertEqual(result['result']['status'],'unknown')
   self.assertFalse(result['result']['retry_safe'])
   count=len(peer.writes)
   self.assertFalse(peer.execute(prepared,intents)['ok'])
   self.assertEqual(len(peer.writes),count)
   self.assertEqual(sum(m.get('command')=='fixture/hang' for m in peer.messages()),1)
   self.assertFalse(any(m.get('command')=='cancel' for m in peer.messages()))
  finally:peer.close()
 def test_incomplete_actual_call_transfer_expires_before_any_backend_write(self):
  peer=PayloadPeer(timeout=1000,profile=dict(PROFILE,call_timeout_ms=2000))
  try:
   self.assertTrue(peer.start()['ok'])
   prepared,intents=peer.prepare('evaluate',check.input_value(dict(expression='unchanged')))
   args=prepared['arguments'];peer.selected=intents[0]['bytes_hex']
   call=peer.frame(dict(action='call',tool=args['tool'],input=args['input'],
     host_plan=dict(version='process-channel-intent-v1',binding={},intents=intents)),
     call=int(prepared['call_id'].split('-')[1]))
   peer.current=call;raw=check.encode(call);count=len(peer.writes)
   check.Peer.send(peer,envelope(call,'payload_begin',message_type='invoke',bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest()))
   check.Peer.send(peer,envelope(call,'payload_chunk',offset=0,bytes_hex=raw.hex()))
   self.assertEqual(peer.process.wait(timeout=5),3)
   with self.assertRaises(EOFError):peer.next(timeout=1)
   self.assertEqual(len(peer.writes),count)
   self.assertFalse(any(m.get('command')=='evaluate' for m in peer.messages()))
  finally:peer.close()
