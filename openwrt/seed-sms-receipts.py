#!/usr/bin/env python3
"""Migrate already-notified Mac SMS IDs to cloud PDU receipts; never send SMS."""
import hashlib
import json
from pathlib import Path
import sqlite3
import urllib.request
base=Path.home()/'Library/Application Support/YumeSimHub'
config=json.loads((base/'edge.json').read_text())
# Run with Mac stopped: immutable read avoids creating WAL/SHM runtime files.
db=sqlite3.connect((base/'runtime/messages.sqlite').as_uri()+'?mode=ro&immutable=1',uri=True)
receipts=[]
for (identity,) in db.execute("SELECT id FROM messages WHERE direction='inbound'"):
    parts=[row[0] for row in db.execute('SELECT pdu_hash FROM sms_segments WHERE message_id=? ORDER BY pdu_hash',(identity,))]
    if parts:
        receipts.append({'id':identity,'fingerprint':hashlib.sha256('\n'.join(parts).encode()).hexdigest()})
for offset in range(0,len(receipts),100):
    req=urllib.request.Request(config['origin']+'/edge/sms-known',data=json.dumps({'receipts':receipts[offset:offset+100]}).encode(),
        headers={'Authorization':'Bearer '+config['token'],'Content-Type':'application/json','User-Agent':'YumeSIMHub/27.2.0'})
    with urllib.request.urlopen(req,timeout=15) as response:
        if not json.loads(response.read(4096)).get('ok'):raise SystemExit('Receipt migration not acknowledged')
print('Migrated',len(receipts),'historical Mac SMS receipt candidates; cloud retains only known historical event IDs.')
