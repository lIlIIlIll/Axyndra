#!/usr/bin/env python3
"""Real Content-Length LSP fixture for the independent artifact contract."""
import json,sys
from pathlib import Path
reader=sys.stdin.buffer;writer=sys.stdout.buffer;documents={}
log=Path(sys.argv[1])
def receive():
 headers={};physical=bytearray()
 while True:
  line=reader.readline()
  if not line:return None
  physical.extend(line)
  if line in (b'\r\n',b'\n'):break
  key,value=line.decode().split(':',1);headers[key.lower()]=value.strip()
 body=reader.read(int(headers['content-length']));physical.extend(body)
 with Path(str(log)+'.frames').open('a',encoding='ascii') as raw:raw.write(physical.hex()+'\n')
 return json.loads(body)
def send(value):
 body=json.dumps(value,ensure_ascii=False,separators=(',',':')).encode()
 writer.write(('Content-Length: %d\r\n\r\n'%len(body)).encode()+body);writer.flush()
while True:
 message=receive()
 if message is None:break
 with log.open('a',encoding='utf-8') as stream:stream.write(json.dumps(message,ensure_ascii=False)+'\n')
 method=message.get('method','');params=message.get('params',{})
 if method=='initialize':
  send(dict(jsonrpc='2.0',id=message['id'],result=dict(capabilities=dict(hoverProvider=True,definitionProvider=True,textDocumentSync=1))))
 elif method=='textDocument/didOpen':
  document=params['textDocument'];documents[document['uri']]=document
  send(dict(jsonrpc='2.0',method='textDocument/publishDiagnostics',params=dict(uri=document['uri'],diagnostics=[])))
 elif method=='textDocument/didChange':
  document=params['textDocument'];documents[document['uri']].update(version=document['version'],text=params['contentChanges'][0]['text'])
 elif method=='textDocument/hover':
  document=documents[params['textDocument']['uri']]
  send(dict(jsonrpc='2.0',id=message['id'],result=dict(contents=document['text'],version=document['version'])))
 elif method=='textDocument/definition':
  send(dict(jsonrpc='2.0',id=message['id'],result=[dict(uri=params['textDocument']['uri'],range=dict(start=dict(line=0,character=0),end=dict(line=0,character=1)))]))
 elif method=='textDocument/rename':
  uri=params['textDocument']['uri'];form=params.get('fixture_edit_form','changes')
  edits=[dict(range=dict(start=dict(line=0,character=0),end=dict(line=0,character=1)),newText=params['newName'])]
  result=dict(changes={uri:edits})
  if form in ('versioned','stale','multi'):
   result=dict(documentChanges=[dict(textDocument=dict(uri=uri,version=documents[uri]['version']-(1 if form=='stale' else 0)),edits=edits)])
   if form=='multi':
    other=params['fixture_other_uri'];result['documentChanges'].append(dict(textDocument=dict(uri=other,version=None),edits=edits))
  elif form=='resource':result=dict(documentChanges=[dict(kind='delete',uri=uri)])
  elif form=='null':result=None
  elif form=='empty':result={}
  elif form=='empty_changes':result=dict(changes={})
  elif form=='empty_document_changes':result=dict(documentChanges=[])
  elif form=='identity':result=dict(changes={uri:[]})
  send(dict(jsonrpc='2.0',id=message['id'],result=result))
 elif method=='fixture/askEdit':
  send(dict(jsonrpc='2.0',id='unapproved-server-request',method='workspace/applyEdit',params=dict(edit=dict(changes={}))))
 elif method=='fixture/error':
  send(dict(jsonrpc='2.0',id=message['id'],error=dict(code=-32602,message='fixture invalid request')))
 elif method=='fixture/hang':pass
 elif 'id' in message and 'method' in message:
  send(dict(jsonrpc='2.0',id=message['id'],result=params))
