#!/usr/bin/env python3
"""Actual packaged DAP + real backend pipes; not Product/Store authority proof."""
import argparse,hashlib,json,os,queue,select,subprocess,sys,tempfile,threading,time,unittest
from pathlib import Path
BINARY=None
IDENTITY=('protocol','extension_id','extension_version','generation','id','tool','kind','command_id','thread_id','run_id','epoch','operation_id','call_id')
def encode(value):return json.dumps(value,ensure_ascii=False,separators=(',',':')).encode()
class Peer:
 def __init__(self,timeout=1000,profile=None):
  self.process=None;self.backend=None;self.reader=None
  self.frame_limit=profile["max_frame_bytes"] if profile else 262144
  self.profile=profile;self.current=None
  self.temp=tempfile.TemporaryDirectory(prefix='dap-package-');self.log=Path(self.temp.name)/'peer.jsonl'
  try:
   self.backend=subprocess.Popen([sys.executable,'-u',str(Path(__file__).parent/'tests/dap_peer.py'),str(self.log)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
   self.process=subprocess.Popen([str(BINARY)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env={k:v for k,v in os.environ.items() if k not in ('LD_LIBRARY_PATH','CANGJIE_HOME','CANGJIE_STDX_PATH')})
   self.frames=queue.Queue();self.count=0;self.call=0;self.writes=[];self.selected=None;self.proposals=[]
   def pump():
    try:
     for line in self.process.stdout:
      if len(line)>self.frame_limit+1 or not line.endswith(b'\n'):raise AssertionError('unbounded frame')
      self.frames.put(json.loads(line))
    except BaseException as error:self.frames.put(error)
    finally:self.frames.put(EOFError())
   self.reader=threading.Thread(target=pump,daemon=True);self.reader.start()
   hello=dict(type='hello',protocol='axyndra-js-host-v2',extension_id='dap',extension_version='1.0.0',generation=7,capabilities=['process.channel'])
   if profile:hello['service_protocol_limits']=profile;hello['max_frame_bytes']=self.frame_limit
   self.send(hello)
   ready=self.next();assert ready['type']=='ready' and [tool['name'] for tool in ready['tools']]==['debug'] and [service['name'] for service in ready['services']]==['session']
   assert ready['commands']==[] and ready['hooks']==[] and ready['capabilities']==hello['capabilities']
   schema=ready['tools'][0]['input_schema']
   assert set(schema)=={'type','properties','required','additionalProperties'}
   assert schema['type']=='object' and schema['required']==['action'] and schema['additionalProperties'] is False
   actions=['launch','attach','set_breakpoint','remove_breakpoint','set_instruction_breakpoint','remove_instruction_breakpoint','data_breakpoint_info','set_data_breakpoint','remove_data_breakpoint','continue','step_over','step_in','step_out','pause','evaluate','stack_trace','threads','scopes','variables','disassemble','read_memory','write_memory','modules','loaded_sources','custom_request','output','terminate','sessions']
   assert schema['properties']['action']=={'type':'string','enum':actions}
   self.configuration=dict(version=1,adapter_id='fixture',initialization={},request_timeout_ms=timeout)
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
  return dict(type='invoke',protocol='axyndra-js-host-v2',extension_id='dap',extension_version='1.0.0',generation=7,id=f'wire-{self.count}',tool='session',kind='service_prepare' if prepare else 'service',command_id='',thread_id='target',run_id=f'run-{call}',epoch=2,operation_id='' if prepare else f'op-{call}',call_id=f'call-{call}',arguments=args)
 def broker(self,frame):
  service=frame['service'];args=frame['arguments']
  if service=='process.channel.startup.write':raw=bytes.fromhex(args['bytes_hex'])
  elif service=='process.channel.write':
   assert args=={'intent_id':'dap-call'} and self.selected is not None
   raw=bytes.fromhex(self.selected);self.selected=None
  else:raw=None
  if raw is not None:
   self.backend.stdin.write(raw);self.backend.stdin.flush();self.writes.append(raw)
   result={'written_bytes':len(raw)}
   if service=='process.channel.write':result['receipt_id']='protocol-fixture-receipt'
  else:
   assert service=='process.channel.read' and args['stream'] in ('stdout','stderr') and 0<args['max_bytes']<=16384 and 0<=args['wait_ms']<=1000
   if args['stream']=='stderr':assert args['wait_ms']==0
   stream=getattr(self.backend,args['stream']);ready=select.select([stream],[],[],args['wait_ms']/1000)[0]
   raw=os.read(stream.fileno(),args['max_bytes']) if ready else b''
   result=dict(bytes_hex=raw.hex(),eof=bool(ready and not raw))
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
def input_value(arguments=None,command='',following=None):
 return dict(arguments=arguments or {},command=command,following_requests=following or [])
class DapPackageTests(unittest.TestCase):
 def setUp(self):
  self.peer=Peer();self.addCleanup(self.peer.close);self.assertTrue(self.peer.start()['ok'])
 def run_action(self,action,arguments=None,command='',following=None):
  prepared,intents=self.peer.prepare(action,input_value(arguments,command,following))
  return self.peer.execute(prepared,intents)
 def test_launch_waiting_for_configuration_completes_one_exact_batch(self):
  p=self.peer;before=len(p.writes)
  result=self.run_action('launch',dict(program='/fixture/program'),following=[dict(command='setBreakpoints',arguments=dict(source=dict(path='/fixture/main.py'),breakpoints=[dict(line=1)])),dict(command='configurationDone',arguments={})])
  self.assertTrue(result['ok'],result)
  self.assertEqual(len(p.writes),before+1)
  self.assertEqual(result['result']['result']['responses'][0],dict(started=True))
  self.assertEqual([m['command'] for m in p.messages()],['initialize','launch','setBreakpoints','configurationDone'])
 def test_actual_debug_actions_and_events(self):
  for action,arguments in [('set_breakpoint',dict(source=dict(path='/fixture/main.py'),breakpoints=[dict(line=2)])),('threads',{}),('stack_trace',dict(threadId=1)),('scopes',dict(frameId=2)),('variables',dict(variablesReference=3)),('continue',dict(threadId=1)),('step_over',dict(threadId=1)),('evaluate',dict(expression='42'))]:
   result=self.run_action(action,arguments);self.assertTrue(result['ok'],(action,result))
  self.assertEqual(result['result']['result']['responses'][0]['result'],'42')
  self.assertTrue(any(m['command']=='next' for m in self.peer.messages()))
 def test_pure_preparation_changed_input_and_consumed_identity_never_write(self):
  p=self.peer;initial=len(p.writes);value=input_value(dict(expression='unchanged'))
  prepared,intents=p.prepare('evaluate',value);self.assertEqual(len(p.writes),initial)
  changed=input_value(dict(expression='changed'));self.assertFalse(p.execute(prepared,intents,input=changed)['ok']);self.assertEqual(len(p.writes),initial)
  self.assertTrue(p.execute(prepared,intents)['ok']);self.assertEqual(len(p.writes),initial+1)
  self.assertFalse(p.execute(prepared,intents)['ok']);self.assertEqual(len(p.writes),initial+1)
 def test_known_adapter_failure_has_complete_terminal(self):
  result=self.run_action('custom_request',command='fixture/error')
  self.assertFalse(result['ok']);self.assertEqual(result['result']['status'],'complete')
 def test_reverse_run_in_terminal_has_no_unapproved_reply_or_process(self):
  result=self.run_action('custom_request',command='fixture/runInTerminal')
  self.assertFalse(result['ok']);self.assertEqual(result['result']['status'],'unknown')
  self.assertTrue(all(m['type']=='request' for m in self.peer.messages()))
 def test_cancel_after_real_write_has_no_hidden_cancel_request(self):
  p=self.peer;prepared,intents=p.prepare('custom_request',input_value(command='fixture/hang'))
  result=p.execute(prepared,intents,cancel=True);self.assertEqual(result['type'],'cancelled')
  self.assertFalse(any(m['command']=='cancel' for m in p.messages()))
if __name__=='__main__':
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--package',type=Path,required=True);args=parser.parse_args()
 BINARY=args.package.resolve()/'bin/dap-plugin'
 if not BINARY.is_file():parser.error('actual standalone package required')
 sys.modules['check']=sys.modules[__name__]
 from check_payload import DapPayloadTests
 from check_policy import DapSessionPolicyPackageTests
 suite=unittest.defaultTestLoader.loadTestsFromTestCase(DapPackageTests)
 suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(DapPayloadTests))
 suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(DapSessionPolicyPackageTests))
 result=unittest.TextTestRunner(verbosity=2).run(suite)
 if result.testsRun!=18 or result.skipped or not result.wasSuccessful():raise SystemExit(1)
 print('DAP native service packaged contract passed: 18 actual process cases')
