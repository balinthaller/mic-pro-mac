#!/usr/bin/python3
"""Read Codex rate limits through installed official app-server; never reads auth files."""
import json, os, selectors, subprocess, time, sys
from pathlib import Path
candidates = [Path('/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex'), Path('/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex')]
cli = next((p for p in candidates if p.is_file() and os.access(p, os.X_OK)), None)
if cli is None:
    print(json.dumps({'ok':False,'error':'official_codex_cli_unavailable'}));sys.exit(1)
proc = None
try:
    proc=subprocess.Popen([str(cli),'-s','read-only','-a','never','app-server'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,bufsize=0)
    def send(value):
        proc.stdin.write((json.dumps(value)+'\n').encode());proc.stdin.flush()
    send({'id':1,'method':'initialize','params':{'clientInfo':{'name':'mic-pro-quota','title':'Mic Pro quota reader','version':'0.6.0'}}})
    selector=selectors.DefaultSelector();selector.register(proc.stdout,selectors.EVENT_READ)
    end=time.monotonic()+15;buffer=b'';completed=False
    while time.monotonic()<end and not completed:
        for key,_ in selector.select(timeout=min(.2,max(0,end-time.monotonic()))):
            chunk=os.read(key.fd,65536)
            if not chunk: raise ValueError('codex_rpc_closed')
            buffer+=chunk
            if len(buffer)>1024*1024:raise ValueError('codex_rpc_overflow')
            while b'\n' in buffer:
                line,buffer=buffer.split(b'\n',1)
                try: reply=json.loads(line)
                except ValueError:continue
                if reply.get('id')==1:
                    if 'error' in reply:raise ValueError('codex_initialize_failed')
                    send({'method':'initialized','params':{}});send({'id':2,'method':'account/rateLimits/read'})
                if reply.get('id')==2:
                    if 'error' in reply:raise ValueError('codex_quota_read_failed')
                    payload=reply.get('result',{})
                    # Whitelist quota data, omitting credentials, account identity, credits and other RPC fields.
                    buckets=payload.get('rateLimitsByLimitId') or payload.get('rate_limits_by_limit_id') or {}
                    primary=buckets.get('codex') or payload.get('rateLimits') or payload.get('rate_limits') or {}
                    windows=[]
                    for name in ('primary','secondary'):
                        w=primary.get(name)
                        if not isinstance(w,dict):continue
                        used=w.get('usedPercent',w.get('used_percent'))
                        minutes=w.get('windowDurationMins',w.get('window_duration_mins'))
                        reset=w.get('resetsAt',w.get('resets_at'))
                        if isinstance(used,(int,float)) and not isinstance(used,bool) and 0<=used<=100 and isinstance(minutes,(int,float)) and minutes>0 and isinstance(reset,(int,float)) and reset>0:
                            windows.append({'used_percent':used,'window_minutes':minutes,'resets_at':reset})
                    if not windows:raise ValueError('codex_quota_windows_unavailable')
                    print(json.dumps({'ok':True,'source':'Codex app-server','read_at':time.time(),'windows':windows}));completed=True
    if not completed:raise ValueError('codex_quota_timeout')
except Exception as error:
    # Do not print backend errors: they can contain account/transport details.
    message=str(error) if isinstance(error,ValueError) else 'codex_reader_unavailable'
    print(json.dumps({'ok':False,'error':message}));sys.exit(1)
finally:
    if proc is not None:
        try:proc.stdin.close()
        except Exception:pass
        try:proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            proc.terminate()
            try:proc.wait(timeout=1)
            except subprocess.TimeoutExpired:proc.kill();proc.wait()
