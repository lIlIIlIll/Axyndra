#!/usr/bin/python3
import hashlib,json,sys,pathlib
KEYS=('protocol','extension_id','extension_version','generation','id','tool','kind','command_id','thread_id','run_id','epoch','operation_id','call_id')
def emit(x): print(json.dumps(x,ensure_ascii=False,separators=(',',':')),flush=True)
def env(x,kind): return dict({k:x[k] for k in KEYS},type=kind)
def receive():
    first=json.loads(sys.stdin.readline())
    if first['type']!='payload_begin':return first
    h=first['payload'];raw=bytearray()
    while True:
        f=json.loads(sys.stdin.readline());assert all(f[k]==first[k] for k in KEYS)
        q=f['payload'];assert q['window']==h['window'] and q['transfer_sequence']==h['transfer_sequence']
        if f['type']=='payload_end':break
        assert f['type']=='payload_chunk' and q['offset']==len(raw);raw.extend(bytes.fromhex(q['bytes_hex']))
    assert len(raw)==h['bytes'] and hashlib.sha256(raw).hexdigest()==h['sha256']
    return json.loads(raw)
def logical(f,seq,mode=''):
    raw=json.dumps(f,ensure_ascii=False,separators=(',',':')).encode()
    h=dict(schema='axyndra.logical-json/v1',window=f['payload_window'],transfer_sequence=seq)
    if mode=='bad_utf8':raw=raw.replace(b'x',b'\xff',1)
    if mode=='identity':f=dict(f,call_id='other')
    if mode=='window':h['window']='other'
    if mode=='sequence':h['transfer_sequence']+=1
    digest=hashlib.sha256(raw).hexdigest() if mode!='hash' else '0'*64
    emit(dict(env(f,'payload_begin'),payload=dict(h,message_type='service_request',bytes=len(raw),sha256=digest)))
    if mode=='overlap':emit(dict(env(f,'progress'),progress={}));return
    for offset in range(0,len(raw),16384):emit(dict(env(f,'payload_chunk'),payload=dict(h,offset=offset,bytes_hex=raw[offset:offset+16384].hex())))
    if mode=='incomplete':return
    if mode=='bad_eof':raise SystemExit(0)
    emit(dict(env(f,'payload_end'),payload=h))
h=receive();ready=dict(h,type='ready',tools=[dict(name='run',description='',input_schema=dict(type='object'))],commands=[],hooks=[])
emit(ready)
f=receive();window=f.get('payload_window','');mode=f['arguments'].get('mode','mixed')
count=32 if mode=='many' else 2 if mode=='mixed' else 1
for index in range(count):
    request=dict(env(f,'service_request'),request_id='child-'+str(index+1),service='fixture.echo',arguments=dict(text=''),payload_window=window)
    if mode=='mixed' and index==0:
        request.pop('payload_window');emit(request)
    else:
        request['arguments']['text']='x'*(1048576-len(json.dumps(request,separators=(',',':')).encode()))
        assert len(json.dumps(request,separators=(',',':')).encode())==1048576
        logical(request,index+2,mode)
    response=receive()
    if response['type']=='cancel':emit(env(f,'cancelled'));raise SystemExit(0)
    assert response['type']=='service_response' and response['request_id']==request['request_id']
result=dict(env(f,'result'),ok=True,result=dict(calls=count))
if window:result['payload_window']=window
emit(result)
for line in sys.stdin:
    if json.loads(line)['type']=='close':break
