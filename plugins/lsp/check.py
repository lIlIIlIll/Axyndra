#!/usr/bin/env python3
"""Actual packaged LSP + real backend pipes; not Product/Store authority proof."""
import argparse,base64,hashlib,json,os,queue,select,subprocess,sys,tempfile,threading,time,unittest
from pathlib import Path
BINARY=None
IDENTITY=('protocol','extension_id','extension_version','generation','id','tool','kind','command_id','thread_id','run_id','epoch','operation_id','call_id')
def encode(value):return json.dumps(value,ensure_ascii=False,separators=(',',':')).encode()
class Peer:
 def __init__(self,timeout=1000,profile=None):
  self.process=None;self.backend=None;self.reader=None
  self.frame_limit=profile["max_frame_bytes"] if profile else 262144
  self.profile=profile;self.current=None
  self.temp=tempfile.TemporaryDirectory(prefix='lsp-package-');self.log=Path(self.temp.name)/'peer.jsonl'
  try:
   self.backend=subprocess.Popen([sys.executable,'-u',str(Path(__file__).parent/'tests/lsp_peer.py'),str(self.log)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
   self.process=subprocess.Popen([str(BINARY)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env={k:v for k,v in os.environ.items() if k not in ('LD_LIBRARY_PATH','CANGJIE_HOME','CANGJIE_STDX_PATH')})
   self.frames=queue.Queue();self.count=0;self.call=0;self.writes=[];self.selected=None;self.proposals=[];self.channel_reads=[];self.poison_channel_read=None
   def pump():
    try:
     for line in self.process.stdout:
      if len(line)>self.frame_limit+1 or not line.endswith(b'\n'):raise AssertionError('unbounded frame')
      self.frames.put(json.loads(line))
    except BaseException as error:self.frames.put(error)
    finally:self.frames.put(EOFError())
   self.reader=threading.Thread(target=pump,daemon=True);self.reader.start()
   hello=dict(type='hello',protocol='axyndra-js-host-v2',extension_id='lsp',extension_version='1.0.0',generation=7,capabilities=['process.channel'])
   if profile:hello['service_protocol_limits']=profile;hello['max_frame_bytes']=self.frame_limit
   self.send(hello)
   ready=self.next();assert ready['type']=='ready' and ready['tools']==[] and ready['services'][0]['name']=='session'
   self.configuration=dict(version=1,root_uri='file:///workspace',language_id='python',initialization_options={},settings={},request_timeout_ms=timeout)
  except BaseException:
   self.close();raise
 def send(self,value):self.process.stdin.write(encode(value)+b'\n');self.process.stdin.flush()
 def next(self,timeout=7):
  value=self.frames.get(timeout=timeout)
  if isinstance(value,BaseException):raise value
  return value
 def frame(self,args,prepare=False,call=None):
  self.count+=1
  if call is None:self.call+=1;call=self.call
  return dict(type='invoke',protocol='axyndra-js-host-v2',extension_id='lsp',extension_version='1.0.0',generation=7,id=f'wire-{self.count}',tool='session',kind='service_prepare' if prepare else 'service',command_id='',thread_id='target',run_id=f'run-{call}',epoch=2,operation_id='' if prepare else f'op-{call}',call_id=f'call-{call}',arguments=args)
 def broker(self,frame):
  service=frame['service'];args=frame['arguments']
  if service=='file.plan.propose':
   assert set(args)=={'proposal'} and set(args['proposal'])=={'schema','operations'}
   assert args['proposal']['schema']=='axyndra.file-change-proposal/v1'
   self.proposals.append(args['proposal'])
   # Protocol-shape fixture only. Product cases prove real immutable artifacts,
   # derived Receipts and the independent approval needed to apply them.
   result=dict(is_error=False,receipt_id='fixture-file-plan-receipt',output=dict(plan_ref='blob:fixture',plan_digest='fixture'))
   self.send(dict({key:frame[key] for key in IDENTITY},type='service_response',request_id=frame['request_id'],ok=True,result=result));return
  if service=='process.channel.startup.write':raw=bytes.fromhex(args['bytes_hex'])
  elif service=='process.channel.write':
   assert args=={'intent_id':'lsp-call'} and self.selected is not None
   raw=bytes.fromhex(self.selected);self.selected=None
  else:raw=None
  if raw is not None:
   self.backend.stdin.write(raw);self.backend.stdin.flush();self.writes.append(raw)
   result={'written_bytes':len(raw)}
   if service=='process.channel.write':result['receipt_id']='protocol-fixture-receipt'
  else:
   encoding=args.get('encoding','hex')
   assert set(args) in ({'stream','max_bytes','wait_ms'},{'stream','max_bytes','wait_ms','encoding'})
   assert encoding in ('hex','base64')
   assert service=='process.channel.read' and args['stream'] in ('stdout','stderr') and 0<args['max_bytes']<=(32768 if encoding=='base64' else 16384) and 0<=args['wait_ms']<=1000
   if args['stream']=='stderr':assert args['wait_ms']==0
   stream=getattr(self.backend,args['stream']);ready=select.select([stream],[],[],args['wait_ms']/1000)[0]
   raw=os.read(stream.fileno(),args['max_bytes']) if ready else b''
   self.channel_reads.append(dict(stream=args['stream'],encoding=encoding,maximum=args['max_bytes'],bytes=len(raw)))
   result=dict(bytes_base64=base64.b64encode(raw).decode('ascii'),eof=bool(ready and not raw)) if encoding=='base64' else dict(bytes_hex=raw.hex(),eof=bool(ready and not raw))
   if self.poison_channel_read is not None and args['stream']=='stdout' and raw:
    result=self.poison_channel_read;self.poison_channel_read=None
  self.send(dict({key:frame[key] for key in IDENTITY},type='service_response',request_id=frame['request_id'],ok=True,result=result))
 def invoke(self,frame,pure=False,cancel_after_write=False):
  self.current=frame;self.send(frame)
  deadline=time.monotonic()+(15 if self.profile else 7)
  while time.monotonic()<deadline:
   value=self.next(max(.001,deadline-time.monotonic()))
   if value['type']=='service_request':
    assert not pure,'pure preparation emitted I/O'
    for key in IDENTITY:assert value[key]==frame[key]
    self.broker(value)
    if cancel_after_write and value['service']=='process.channel.write':
     self.send(dict({key:frame[key] for key in IDENTITY},type='cancel'));cancel_after_write=False
    continue
   assert value['type'] in ('result','cancelled'),value
   for key in IDENTITY:assert value[key]==frame[key]
   return value
  raise AssertionError('invocation missed fixed deadline')
 def start(self):return self.invoke(self.frame(dict(action='start',configuration=self.configuration)))
 def prepare(self,name,input):
  frame=self.frame(dict(action='call',tool=name,input=input),prepare=True)
  value=self.invoke(frame,pure=True);assert value['ok'],value
  return frame,value['result']['intents']
 def execute(self,prepared,intents,input=None,cancel=False):
  args=prepared['arguments'];self.selected=intents[0]['bytes_hex']
  frame=self.frame(dict(action='call',tool=args['tool'],input=args['input'] if input is None else input,host_plan=dict(version='process-channel-intent-v1',binding={},intents=intents)),call=int(prepared['call_id'].split('-')[1]))
  return self.invoke(frame,cancel_after_write=cancel)
 def messages(self):return [json.loads(line) for line in self.log.read_text(encoding='utf-8').splitlines()] if self.log.exists() else []
 def close(self):
  for process in (self.process,self.backend):
   if process is None:continue
   try:process.stdin.close();process.wait(timeout=2)
   except (BrokenPipeError,subprocess.TimeoutExpired):process.kill();process.wait(timeout=2)
   process.stdout.close();process.stderr.close()
  if self.reader is not None:self.reader.join(timeout=1)
  self.temp.cleanup()
def input_value(version=1,text='first 雪'):
 return dict(documents=[dict(uri='file:///workspace/a.py',version=version,text=text)],params=dict(textDocument=dict(uri='file:///workspace/a.py'),position=dict(line=0,character=0)),method='')
class LspPackageTests(unittest.TestCase):
 def setUp(self):
  self.peer=Peer();self.addCleanup(self.peer.close);self.assertTrue(self.peer.start()['ok'])
 def test_actual_initialization_documents_navigation_and_diagnostics(self):
  p=self.peer
  self.assertEqual([m.get('method') for m in p.messages()][:2],['initialize','initialized'])
  initial=len(p.writes);frame,intents=p.prepare('hover',input_value());self.assertEqual(len(p.writes),initial)
  result=p.execute(frame,intents);self.assertTrue(result['ok'])
  self.assertEqual(result['result']['result']['value'],{'contents':'first 雪','version':1})
  self.assertIn('textDocument/publishDiagnostics',[e['method'] for e in result['result']['result']['notifications']['events']])
  frame,intents=p.prepare('hover',input_value(2,'changed'))
  result=p.execute(frame,intents);self.assertEqual(result['result']['result']['value'],{'contents':'changed','version':2})
  self.assertIn('textDocument/didChange',[m.get('method') for m in p.messages()])
 def test_frozen_input_change_and_consumed_identity_cannot_write(self):
  p=self.peer;frame,intents=p.prepare('definition',input_value());count=len(p.writes)
  altered=input_value();altered['documents'][0]['text']='different'
  self.assertFalse(p.execute(frame,intents,altered)['ok']);self.assertEqual(len(p.writes),count)
  self.assertTrue(p.execute(frame,intents)['ok']);count=len(p.writes)
  self.assertFalse(p.execute(frame,intents)['ok']);self.assertEqual(len(p.writes),count)
 def test_rename_proposes_plan_without_workspace_apply(self):
  p=self.peer;input=input_value();input['params']['newName']='renamed'
  frame,intents=p.prepare('rename',input);result=p.execute(frame,intents)
  self.assertTrue(result['ok']);data=result['result']['result'];self.assertFalse(data['workspace_changes_applied'])
  self.assertEqual(data['value']['changes']['file:///workspace/a.py'][0]['newText'],'renamed')
  self.assertEqual(data['application_plan']['plan_ref'],'blob:fixture')
  self.assertEqual(p.proposals,[dict(schema='axyndra.file-change-proposal/v1',operations=[dict(kind='replace',path='a.py',expected_content='first 雪',content='renamedirst 雪')])])
 def test_backend_known_error_is_complete_and_unapproved_reverse_reply_is_unknown(self):
  p=self.peer;input=dict(documents=[],params={},method='fixture/error')
  frame,intents=p.prepare('request',input);result=p.execute(frame,intents)
  self.assertFalse(result['ok']);self.assertEqual(result['result']['status'],'complete')
  input['method']='fixture/askEdit';frame,intents=p.prepare('request',input);result=p.execute(frame,intents)
  self.assertFalse(result['ok']);self.assertEqual(result['result']['status'],'unknown')
  self.assertFalse(any(m.get('id')=='unapproved-server-request' for m in p.messages()))
 def test_actual_cancel_closes_window_and_emits_no_unapproved_cancel_frame(self):
  p=self.peer;frame,intents=p.prepare('request',dict(documents=[],params={},method='fixture/hang'))
  result=p.execute(frame,intents,cancel=True);self.assertEqual(result['type'],'cancelled')
  self.assertFalse(any(m.get('method')=='$/cancelRequest' for m in p.messages()))
 def test_filepath_prepare_requests_read_without_io_then_freezes_same_identity(self):
  p=self.peer;initial=len(p.writes)
  input=input_value();input['documents']=[dict(path='a.py',version=1)]
  first=p.frame(dict(action='call',tool='hover',input=input),prepare=True)
  requested=p.invoke(first,pure=True)
  self.assertTrue(requested['ok']);self.assertEqual(requested['result'],dict(context_read=dict(resources=[dict(source='/workspace/a.py',path='a.py',mode='file')])))
  self.assertEqual(len(p.writes),initial)
  # Data-only protocol fixture; actual canonical fact authority is exercised by
  # PluginContextReadTests through Core, SQLite, approval and verified handles.
  text='read once 雪'
  input['_axyndra_context_read']=dict(schema='axyndra.context-read-input/v1',data=dict(schema='axyndra.context-read-result/v1',resources=[dict(kind='file',source='/workspace/a.py',path='a.py',witness='fixture-only',text=text,sha256=hashlib.sha256(text.encode()).hexdigest())]),facts=[dict(protocol_fixture=True)])
  second=p.frame(dict(action='call',tool='hover',input=input),prepare=True,call=int(first['call_id'].split('-')[1]))
  prepared=p.invoke(second,pure=True);self.assertTrue(prepared['ok']);self.assertEqual(len(p.writes),initial)
  result=p.execute(second,prepared['result']['intents']);self.assertTrue(result['ok'])
  self.assertEqual(result['result']['result']['value']['contents'],text)
  self.assertEqual(len(p.writes),initial+1)
 def test_filepath_escape_and_changed_fact_are_rejected_without_backend_write(self):
  p=self.peer;initial=len(p.writes)
  for path in ('../escape','/absolute','a//b','a/./b','a\\b'):
   input=input_value();input['documents']=[dict(path=path,version=1)]
   self.assertFalse(p.invoke(p.frame(dict(action='call',tool='hover',input=input),prepare=True),pure=True)['ok'])
  input=input_value();input['documents']=[dict(path='a.py',version=1)]
  input['_axyndra_context_read']=dict(schema='axyndra.context-read-input/v1',data=dict(schema='axyndra.context-read-result/v1',resources=[dict(kind='file',source='/foreign/a.py',path='a.py',witness='fixture-only',text='changed',sha256='0'*64)]),facts=[{}])
  self.assertFalse(p.invoke(p.frame(dict(action='call',tool='hover',input=input),prepare=True),pure=True)['ok'])
  self.assertEqual(len(p.writes),initial)
 def test_versioned_rename_uses_frozen_content_and_advertises_text_support(self):
  p=self.peer;init=next(m for m in p.messages() if m.get('method')=='initialize')
  self.assertTrue(init['params']['capabilities']['workspace']['workspaceEdit']['documentChanges'])
  self.assertFalse(init['params']['capabilities']['workspace']['applyEdit'])
  input=input_value(7,'old');input['params'].update(newName='N',fixture_edit_form='versioned')
  frame,intents=p.prepare('rename',input);result=p.execute(frame,intents)
  self.assertTrue(result['ok'],result)
  self.assertEqual(p.proposals,[dict(schema='axyndra.file-change-proposal/v1',operations=[dict(kind='replace',path='a.py',expected_content='old',content='Nld')])])
 def test_multiple_versioned_and_null_version_documents_share_one_plan(self):
  p=self.peer;input=input_value(7,'old')
  input['documents'].append(dict(uri='file:///workspace/b.py',version=3,text='second'))
  input['params'].update(newName='N',fixture_edit_form='multi',fixture_other_uri='file:///workspace/b.py')
  frame,intents=p.prepare('rename',input);result=p.execute(frame,intents)
  self.assertTrue(result['ok'],result)
  self.assertEqual(len(p.proposals),1)
  self.assertEqual(p.proposals[0]['operations'],[dict(kind='replace',path='a.py',expected_content='old',content='Nld'),dict(kind='replace',path='b.py',expected_content='second',content='Necond')])
 def test_stale_version_and_resource_edit_cannot_reach_plan_service(self):
  for form in ('stale','resource'):
   p=Peer()
   try:
    self.assertTrue(p.start()['ok']);input=input_value(7,'old');input['params'].update(newName='N',fixture_edit_form=form)
    frame,intents=p.prepare('rename',input);count=len(p.writes);result=p.execute(frame,intents)
    self.assertFalse(result['ok']);self.assertEqual(result['result']['status'],'unknown')
    self.assertEqual(len(p.writes),count+1);self.assertEqual(p.proposals,[])
    self.assertEqual(sum(m.get('method')=='textDocument/rename' for m in p.messages()),1)
   finally:p.close()
 def test_empty_rename_result_needs_no_plan_and_session_remains_usable(self):
  p=self.peer
  for version,form in enumerate(('null','empty','empty_changes','empty_document_changes','identity'),1):
   input=input_value(version,'old');input['params'].update(newName='N',fixture_edit_form=form)
   frame,intents=p.prepare('rename',input);result=p.execute(frame,intents)
   self.assertTrue(result['ok'],result);self.assertIsNone(result['result']['result']['application_plan']);self.assertEqual(p.proposals,[])
  frame,intents=p.prepare('hover',input_value(6,'still usable'));result=p.execute(frame,intents)
  self.assertEqual(result['result']['result']['value']['contents'],'still usable')
if __name__=='__main__':
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--package',type=Path,required=True);args=parser.parse_args()
 BINARY=args.package.resolve()/'bin/lsp-plugin'
 if not BINARY.is_file():parser.error('actual standalone package required')
 sys.modules['check']=sys.modules[__name__]
 from check_payload import LspPayloadTests
 from check_channel import LspCompactReadTests
 suite=unittest.defaultTestLoader.loadTestsFromTestCase(LspPackageTests)
 suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(LspPayloadTests))
 suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(LspCompactReadTests))
 result=unittest.TextTestRunner(verbosity=2).run(suite)
 if result.testsRun!=19 or result.skipped or not result.wasSuccessful():raise SystemExit(1)
 print('LSP native service packaged contract passed: 19 actual process cases (original16 plus compact3)')
