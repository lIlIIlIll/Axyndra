#!/usr/bin/python3
import hashlib,json,sys,pathlib
KEYS=('protocol','extension_id','extension_version','generation','id','tool','kind','command_id','thread_id','run_id','epoch','operation_id','call_id')
def emit(value): print(json.dumps(value,separators=(',',':')),flush=True)
def env(value,kind): return dict({k:value[k] for k in KEYS},type=kind)
def receive():
    line=sys.stdin.readline()
    if not line: return None
    first=json.loads(line)
    if first['type']!='payload_begin': return first
    header=first['payload'];body=bytearray()
    while True:
        value=json.loads(sys.stdin.readline());assert all(value[k]==first[k] for k in KEYS)
        part=value['payload'];assert part['window']==header['window'] and part['transfer_sequence']==header['transfer_sequence']
        if value['type']=='payload_end': break
        assert part['offset']==len(body);body.extend(bytes.fromhex(part['bytes_hex']))
    assert len(body)==header['bytes'] and hashlib.sha256(body).hexdigest()==header['sha256']
    decoded=json.loads(body);assert all(decoded[k]==first[k] for k in KEYS);return decoded
def logical(frame,window,partial=False):
    body=json.dumps(frame,separators=(',',':')).encode();common=dict(schema='axyndra.logical-json/v1',window=window,transfer_sequence=1)
    emit(dict(env(frame,'payload_begin'),payload=dict(common,message_type='result',bytes=len(body),sha256=hashlib.sha256(body).hexdigest())))
    if partial: return
    for offset in range(0,len(body),16384): emit(dict(env(frame,'payload_chunk'),payload=dict(common,offset=offset,bytes_hex=body[offset:offset+16384].hex())))
    emit(dict(env(frame,'payload_end'),payload=common))
hello=receive();ready=dict(hello,type='ready',tools=[dict(name='run',description='',input_schema=dict(type='object'))],commands=[],hooks=[])
emit(ready)
while True:
    invocation=receive()
    if invocation is None or invocation['type']=='close': break
    assert invocation['type']=='invoke'
    pathlib.Path(__file__+'.invocations').write_text('invoked')
    window=invocation.get('payload_window','')
    if invocation['arguments'].get('mode')=='partial':
        result=dict(env(invocation,'result'),ok=True,result=dict(text='x'*300000),payload_window=window)
        logical(result,window,partial=True);pathlib.Path(__file__+'.partial').write_text('begun')
        cancelled=receive();assert cancelled['type']=='cancel';emit(env(invocation,'cancelled'));break
    question=dict(env(invocation,'service_request'),request_id='child',service='fixture.echo',arguments={});emit(question)
    response=receive();assert response['type']=='service_response' and response['request_id']=='child'
    result=dict(env(invocation,'result'),ok=True,result=response['result'])
    if window:result['payload_window']=window
    if len(json.dumps(result))>262144:logical(result,window)
    else:emit(result)
