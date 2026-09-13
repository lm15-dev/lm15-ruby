#!/usr/bin/env python3
"""Compare novel requests with Python's public protocol entry point.
No contract case or golden files are read. Python is a development oracle only.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--python-repo', required=True, type=Path)
p.add_argument('--ruby', default='ruby')
a = p.parse_args()
messages = []
providers = [('openai','gpt-4.1'),('openai-chat','gpt-4.1'),('anthropic','claude-sonnet-4-5'),('gemini','gemini-2.5-flash')]
for provider, model in providers:
    for i in range(6):
        req = {'model':model,'system':f'Novel differential instruction {i}: keep café and 東京.',
               'messages':[{'role':'user','parts':[{'type':'text','text':f'Independent sample {i}: 🦀 / \\ ? & < >'}]}],
               'config':{'max_tokens':79+i,'temperature':i/10,'stop':['END-NOVEL']}}
        if i % 2:
            req['tools'] = [{'type':'function','name':'locate_unique','description':'Find a point','parameters':{'type':'object','properties':{'city':{'type':'string'},'count':{'type':'integer'}},'required':['city']}}]
            req['config']['tool_choice'] = {'mode':'required','allowed':['locate_unique'],'parallel':False}
        if i == 2:
            req['config']['response_format'] = {'type':'json_schema','schema':{'type':'object','properties':{'answer':{'type':'string'}}},'name':'novel_schema'}
        if i == 4:
            req['messages'] += [{'role':'assistant','parts':[{'type':'tool_call','id':'unique-call','name':'locate_unique','input':{'city':'Oslo','count':7}}]}, {'role':'tool','parts':[{'type':'tool_result','id':'unique-call','name':'locate_unique','content':[{'type':'text','text':'59.91° N'}]}]}]
        messages.append({'id':f'{provider}-{i}','op':'build_request','provider':provider,'api_key':'differential-placeholder','canonical_request':req,'stream':i == 5})
for provider in ['openai-chat','groq','deepseek','openrouter']:
    messages.append({'id':provider+'-ingest-novel','op':'ingest_openai_chat','provider':provider,'body':{'model':'novel-model','messages':[{'role':'system','content':'A fresh prompt'}, {'role':'user','content':'A new migration sample'}],'temperature':0.375,'seed':8703,'metadata':{'test':'independent'}}})
wire = ''.join(json.dumps(m,ensure_ascii=False)+'\n' for m in messages)
def run(command,cwd,env):
    result = subprocess.run(command,cwd=cwd,env=env,input=wire,text=True,capture_output=True,check=True,timeout=60)
    return [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
env = dict(os.environ)
env['PYTHONPATH'] = str(a.python_repo.resolve())
reference = run(['python','-m','lm15.vet'],a.python_repo.resolve(),env)
ruby = run([a.ruby,str(ROOT/'bin/lm15-vet')],ROOT,dict(os.environ))
assert len(reference) == len(ruby) == len(messages)
def comparable(row):
    if row['ok']: return row['result']
    return {'type':row['error']['type'],'code':row['error'].get('code')}
failures = []
for message, expected, actual in zip(messages,reference,ruby):
    if expected['ok'] != actual['ok'] or comparable(expected) != comparable(actual):
        failures.append({'id':message['id'],'expected':expected,'actual':actual})
report = {'total':len(messages),'passed':len(messages)-len(failures),'failures':failures,'python_revision':subprocess.check_output(['git','rev-parse','HEAD'],cwd=a.python_repo,text=True).strip()}
(ROOT/'tmp').mkdir(exist_ok=True)
(ROOT/'tmp/differential.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(f"Novel differential checks: {report['passed']}/{report['total']} passed")
for fail in failures: print(json.dumps(fail,ensure_ascii=False))
raise SystemExit(bool(failures))
