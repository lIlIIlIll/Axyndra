#!/usr/bin/python3
"""Actual native fixture requests a forbidden service; no Host authority is simulated."""
import json, sys
IDENTITY=('protocol','extension_id','extension_version','generation','id','tool','kind','command_id','thread_id','run_id','epoch','operation_id','call_id')
def write(frame):
    sys.stdout.write(json.dumps(frame,separators=(',',':'))+'\n');sys.stdout.flush()
def read():
    line=sys.stdin.buffer.readline(262145)
    if not line or len(line)>262144 or not line.endswith(b'\n'):raise EOFError()
    return json.loads(line)
hello=read()
assert hello['type']=='hello' and hello['capabilities']==[]
write(dict(type='ready',protocol=hello['protocol'],extension_id=hello['extension_id'],extension_version=hello['extension_version'],generation=hello['generation'],capabilities=[],tools=[dict(name='probe',description='Actual service rejection probe',execution_profile='data_only',input_schema=dict(type='object',properties={},additionalProperties=False))],hooks=[],commands=[],providers=[]))
while True:
    try:frame=read()
    except EOFError:break
    if frame['type'] in ['shutdown','close','dispose']:
        write(dict(type='disposed',protocol=hello['protocol'],extension_id=hello['extension_id'],extension_version=hello['extension_version'],generation=hello['generation']));break
    if frame['type']!='invoke':
        raise AssertionError('unexpected fixture frame')
    identity={key:frame[key] for key in IDENTITY}
    if frame['kind']=='prepare':
        write(dict(type='result',**identity,ok=True,is_error=False,result=frame['arguments']));continue
    write(dict(type='service_request',**identity,request_id='denied-document-1',service='document.store',arguments=dict(intent_id='denied-document-1')))
    answer=read()
    assert answer['type']=='service_response' and answer['request_id']=='denied-document-1'
    assert answer['ok'] is False
    assert answer['error']['code']=='extension.service_unsupported'
    assert all(answer[key]==frame[key] for key in IDENTITY)
    write(dict(type='result',**identity,ok=False,result=dict(error=answer['error']['code'])))
