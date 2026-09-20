"""Private HTTPS (via Tailscale Serve) companion for the existing VM desktop."""
import asyncio
import hashlib
import hmac
import json
import os
import re
import secrets
import sqlite3
import time
import uuid
from contextlib import closing
from collections import defaultdict, deque
from pathlib import Path
from urllib.parse import urlsplit
from aiohttp import web
from desktop import Desktop, DesktopError, ordered_turns

UUID = re.compile(r'^[a-zA-Z0-9_-]{8,100}$')

class Bridge:
    def __init__(self, codex_home, state_dir, token, origin=None, web_dir=None):
        self.codex_home, self.state_dir, self.token = Path(codex_home), Path(state_dir), token
        self.origin = (origin or os.environ.get('RELAY_ORIGIN', '')).rstrip('/')
        parsed = urlsplit(self.origin)
        if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.path or parsed.query or parsed.fragment:
            raise ValueError('Set RELAY_ORIGIN to the exact HTTPS origin of your private bridge, including its port.')
        self.host_label = os.environ.get('RELAY_HOST_LABEL', 'Codex host')
        self.web_dir = Path(web_dir or os.environ.get('RELAY_WEB_DIR', str(Path(__file__).parent.parent/'Web/dist')))
        self.desktop = Desktop(self.codex_home/'ipc/ipc.sock')
        self.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.journal = sqlite3.connect(self.state_dir/'delivery.sqlite')
        os.chmod(self.state_dir/'delivery.sqlite', 0o600)
        self.journal.execute('CREATE TABLE IF NOT EXISTS delivery (id TEXT PRIMARY KEY, digest TEXT NOT NULL, status TEXT NOT NULL, result TEXT, created REAL NOT NULL)')
        self.journal.execute("UPDATE delivery SET status='uncertain' WHERE status='sending'")
        self.journal.execute('CREATE TABLE IF NOT EXISTS sessions (digest TEXT PRIMARY KEY, expires REAL NOT NULL)')
        self.journal.commit()
        self.write_lock = asyncio.Lock()
        self.rates = defaultdict(deque)

    @web.middleware
    async def secure(self, req, handler):
        try:
            origin = req.headers.get('Origin')
            if origin and origin != self.origin:
                raise web.HTTPForbidden(text='Untrusted origin')
            # Static assets contain no conversation data. APIs never enter the SW cache.
            public = req.path == '/auth/session' or not req.path.startswith(('/v1/', '/auth/'))
            if not public:
                bearer = hmac.compare_digest(req.headers.get('Authorization', '').encode(), ('Bearer '+self.token).encode())
                session = req.cookies.get('__Host-relay', '')
                digest = hashlib.sha256(session.encode()).hexdigest()
                valid = self.journal.execute('SELECT 1 FROM sessions WHERE digest=? AND expires>?', (digest, time.time())).fetchone()
                if not bearer and not valid: raise web.HTTPUnauthorized(text='Pairing credential required')
                # Cookie-authenticated writes and WS handshakes require exact origin.
                if not bearer and (req.method not in ('GET', 'HEAD') or req.headers.get('Upgrade','').lower() == 'websocket') and origin != self.origin:
                    raise web.HTTPForbidden(text='Same-origin request required')
            if req.path.startswith(('/v1/', '/auth/')):
                self.rate_limit(req, 'api', 180)
            response = await handler(req)
        except web.HTTPException as exc:
            response = web.json_response({'error':exc.text or exc.reason}, status=exc.status)
        except (DesktopError, asyncio.TimeoutError) as exc:
            message = str(exc) or 'The desktop did not respond in time.'
            if message == 'no-client-found': message = 'Open this task in Codex on the VM first. No live desktop owner was found.'
            response = web.json_response({'error':message}, status=409)
        except (KeyError, TypeError, ValueError) as exc:
            response = web.json_response({'error':'Invalid request'}, status=400)
        response.headers['Cache-Control'] = 'no-store'
        response.headers['X-Content-Type-Options'] = 'nosniff'
        response.headers['Referrer-Policy'] = 'no-referrer'
        response.headers['Content-Security-Policy'] = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; font-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
        response.headers['Permissions-Policy'] = 'camera=(), microphone=(), geolocation=()'
        return response

    def rate_limit(self, req, scope, limit):
        # Tailscale Serve is the only upstream; keep a conservative shared limit.
        q = self.rates[(req.remote, scope)]; now = time.monotonic()
        while q and q[0] < now-60: q.popleft()
        if len(q) >= limit: raise web.HTTPTooManyRequests(text='Try again in a minute')
        q.append(now)

    async def login(self, req):
        if req.headers.get('Origin') != self.origin: raise web.HTTPForbidden(text='Same-origin sign-in required')
        self.rate_limit(req, 'login', 10)
        value = (await req.json()).get('token', '')
        if not isinstance(value, str) or not hmac.compare_digest(value.encode(), self.token.encode()):
            raise web.HTTPUnauthorized(text='Pairing code not recognized')
        session = secrets.token_urlsafe(48)
        self.journal.execute('DELETE FROM sessions WHERE expires<=?', (time.time(),))
        self.journal.execute('INSERT INTO sessions VALUES (?,?)', (hashlib.sha256(session.encode()).hexdigest(), time.time()+30*86400))
        self.journal.commit()
        response = web.json_response({'connected':True})
        response.set_cookie('__Host-relay', session, max_age=30*86400, secure=True, httponly=True, samesite='Strict', path='/')
        return response

    async def logout(self, req):
        session = req.cookies.get('__Host-relay', '')
        self.journal.execute('DELETE FROM sessions WHERE digest=?', (hashlib.sha256(session.encode()).hexdigest(),)); self.journal.commit()
        response = web.json_response({'connected':False})
        response.del_cookie('__Host-relay', path='/', secure=True, httponly=True, samesite='Strict')
        return response

    async def asset(self, req):
        name = req.match_info.get('path', '') or 'index.html'
        path = (self.web_dir/name).resolve()
        if not path.is_relative_to(self.web_dir.resolve()) or not path.is_file(): raise web.HTTPNotFound()
        return web.FileResponse(path)

    def db(self):
        c = sqlite3.connect(f'file:{self.codex_home}/state_5.sqlite?mode=ro', uri=True)
        c.row_factory = sqlite3.Row
        return c

    def thread_id(self, req):
        tid = req.match_info['tid']
        if not UUID.fullmatch(tid): raise web.HTTPBadRequest()
        with closing(self.db()) as c:
            if not c.execute('SELECT 1 FROM threads WHERE id=? AND archived=0', (tid,)).fetchone():
                raise web.HTTPNotFound()
        return tid

    async def health(self, req):
        return web.json_response(dict(name=self.host_label, bridgeVersion='0.2.0',
            desktopConnected=self.desktop.connected, protocol='desktop-ipc-v11',
            capabilities=['existingTasks','liveUpdates','send','steer','stop','commandApproval','fileApproval','userInput'],
            newTaskSupported=False))

    async def delivery(self, req):
        row = self.journal.execute('SELECT status,result FROM delivery WHERE id=?',(req.match_info['cid'],)).fetchone()
        if not row: return web.json_response({'status':'notRecorded','result':None})
        return web.json_response({'status':row[0],'result':json.loads(row[1]) if row[1] else None})

    async def threads(self, req):
        offset = max(0, int(req.query.get('cursor', 0)))
        limit = min(100, max(1, int(req.query.get('limit', 50))))
        search = req.query.get('search', '')[:300]
        with closing(self.db()) as c:
            rows = c.execute("SELECT id,coalesce(nullif(name,''),title) title,cwd,model_provider,updated_at,is_pinned FROM threads WHERE archived=0 AND source IN ('cli','vscode','appServer') AND (title LIKE ? OR name LIKE ?) ORDER BY is_pinned DESC,updated_at DESC,id DESC LIMIT ? OFFSET ?", ('%'+search+'%', '%'+search+'%',limit+1,offset)).fetchall()
        data = []
        for row in rows[:limit]:
            d = dict(row); state = self.desktop.states.get(d['id'], {})
            d['title'] = state.get('title') or d['title'].split('\n')[0][:160] or 'Untitled task'
            d['status'] = state.get('threadRuntimeStatus', {}).get('type', 'unknown')
            d['isPinned'] = bool(d.pop('is_pinned')); d['provider'] = d.pop('model_provider')
            d['updatedAt'] = d.pop('updated_at'); data.append(d)
        return web.json_response(dict(data=data, nextCursor=str(offset+limit) if len(rows)>limit else None))

    async def conversation(self, req):
        tid = self.thread_id(req)
        return web.json_response(await self.desktop.follow(tid, force=req.query.get('refresh')=='true'))

    async def command(self, req):
        tid = self.thread_id(req)
        body = await req.json()
        op, cid = body.get('operation'), body.get('id')
        if not isinstance(cid,str) or not UUID.fullmatch(cid): raise web.HTTPBadRequest(text='Operation ID required')
        if op not in ['send','stop','approveCommand','approveFile','answer','loadHistory']:
            raise web.HTTPBadRequest(text='Unsupported operation')
        digest = hashlib.sha256(json.dumps([tid,body], sort_keys=True).encode()).hexdigest()
        # Serialize precondition checks + delivery registration. A duplicate ID is
        # never sent again, even across restart or an ambiguous desktop timeout.
        async with self.write_lock:
            row = self.journal.execute('SELECT digest,status,result FROM delivery WHERE id=?',(cid,)).fetchone()
            if row:
                if row[0] != digest: raise web.HTTPConflict(text='Operation ID already used with different content')
                return web.json_response({'status':row[1], 'result':json.loads(row[2]) if row[2] else None})
            await self.desktop.follow(tid)
            state = self.desktop.states[tid]
            turns = ordered_turns(state)
            active = next((t for t in reversed(turns) if t.get('status')=='inProgress'),None)
            if op == 'send':
                prompt = body.get('text','')
                if not isinstance(prompt,str) or not prompt.strip() or len(prompt)>100000:
                    raise web.HTTPBadRequest(text='Enter a prompt under 100,000 characters')
                inputs=[{'type':'text','text':prompt,'text_elements':[]}]
                if active or state.get('threadRuntimeStatus',{}).get('type')=='active':
                    method='thread-follower-steer-turn'
                    params={'input':inputs,'clientUserMessageId':cid,
                        'restoreMessage':{'text':prompt,'cwd':state.get('cwd'),
                            'context':{'workspaceRoots':[state['cwd']] if state.get('cwd') else [],
                                'collaborationMode':state.get('latestCollaborationMode'),
                                'commentAttachments':[]}},'attachments':[]}
                else:
                    method='thread-follower-start-turn'
                    params={'turnStart':{'request':{'threadId':tid,'input':inputs,'clientUserMessageId':cid},
                        'context':{'inheritThreadSettings':True}}}
            elif op == 'stop':
                expected = body.get('expectedTurnId')
                if not active or expected != active.get('turnId'):
                    raise web.HTTPConflict(text='The active turn changed. Refresh before stopping.')
                method='thread-follower-interrupt-turn';params={'mode':'user-stop','expectedTurnId':expected}
            elif op == 'loadHistory':
                method='thread-follower-load-complete-history';params={}
            else:
                request = next((r for r in state.get('requests',[]) if str(r.get('id'))==str(body.get('requestId'))),None)
                if not request: raise web.HTTPConflict(text='This request is no longer pending')
                request_method=request.get('method')
                if op in ['approveCommand','approveFile']:
                    expected_method='item/commandExecution/requestApproval' if op=='approveCommand' else 'item/fileChange/requestApproval'
                    if request_method != expected_method: raise web.HTTPBadRequest(text='Request type mismatch')
                    decision=body.get('decision')
                    if decision not in ('accept','decline','cancel'): raise web.HTTPBadRequest(text='Invalid decision')
                    available=request.get('params',{}).get('availableDecisions')
                    if available and decision not in available: raise web.HTTPBadRequest(text='Decision unavailable')
                    method='thread-follower-command-approval-decision' if op=='approveCommand' else 'thread-follower-file-approval-decision'
                    params={'requestId':request['id'],'decision':decision}
                else:
                    if request_method != 'item/tool/requestUserInput': raise web.HTTPBadRequest(text='Unsupported question type')
                    answers=body.get('answers')
                    if not isinstance(answers,dict): raise web.HTTPBadRequest(text='Answers required')
                    questions=request.get('params',{}).get('questions',[])
                    if set(answers) != {q['id'] for q in questions}: raise web.HTTPBadRequest(text='Answer every question')
                    if not all(isinstance(v,dict) and isinstance(v.get('answers'),list) and len(v['answers'])==1 and isinstance(v['answers'][0],str) and 0<len(v['answers'][0])<10000 for v in answers.values()):
                        raise web.HTTPBadRequest(text='Invalid answer')
                    method='thread-follower-submit-user-input';params={'requestId':request['id'],'response':{'answers':answers}}
            self.journal.execute('INSERT INTO delivery VALUES (?,?,?,?,?)',(cid,digest,'sending',None,time.time()));self.journal.commit()
            try:
                result=await self.desktop.command(tid,method,params);status='accepted'
            except (Exception, asyncio.CancelledError):
                result={'message':'Delivery is uncertain. Check the conversation before sending again.'};status='uncertain'
            self.journal.execute('UPDATE delivery SET status=?,result=? WHERE id=?',(status,json.dumps(result),cid));self.journal.commit()
            return web.json_response({'status':status,'result':result})

    async def stream(self, req):
        tid = self.thread_id(req)
        await self.desktop.follow(tid)
        ws = web.WebSocketResponse(heartbeat=25, max_msg_size=4096)
        await ws.prepare(req)
        changed=asyncio.Event(); changed.set()
        def notify(t):
            if t is None or t==tid: changed.set()
        self.desktop.listeners.add(notify)
        async def publish():
            previous = None
            try:
                while not ws.closed:
                    await changed.wait();changed.clear()
                    await asyncio.sleep(0.15)
                    value=self.desktop.view(tid)
                    if previous is None:
                        await ws.send_json({'type':'conversation','conversation':value})
                    else:
                        old_items={item['id']:item for item in previous['messages']}
                        metadata={k:v for k,v in value.items() if k!='messages'}
                        upserts=[item for item in value['messages'] if old_items.get(item['id'])!=item]
                        await ws.send_json({'type':'conversationPatch','patch':{'metadata':metadata,
                            'upserts':upserts,'order':[item['id'] for item in value['messages']]}})
                    previous=value
            except Exception:
                await ws.close(code=1011,message=b'Conversation stream unavailable; reconnect')
        task=asyncio.create_task(publish())
        try:
            async for message in ws:
                if message.type in (web.WSMsgType.ERROR,web.WSMsgType.CLOSE):break
        finally:
            task.cancel(); self.desktop.listeners.discard(notify)
            await asyncio.gather(task,return_exceptions=True)
        return ws

    async def lifecycle(self, app):
        async def reconnect():
            while True:
                if not self.desktop.connected:
                    try: await self.desktop.connect()
                    except Exception: pass
                await asyncio.sleep(3)
        task=asyncio.create_task(reconnect())
        yield
        task.cancel();await asyncio.gather(task,return_exceptions=True)
        await self.desktop.close();self.journal.close()

    def app(self):
        app=web.Application(middlewares=[self.secure],client_max_size=1024*1024)
        app.add_routes([web.get('/v1/health',self.health),web.get('/v1/threads',self.threads),
            web.get('/v1/delivery/{cid}',self.delivery),
            web.get('/v1/threads/{tid}',self.conversation),web.post('/v1/threads/{tid}/commands',self.command),
            web.get('/v1/threads/{tid}/stream',self.stream),
            web.post('/auth/session',self.login), web.post('/auth/logout',self.logout),
            web.get('/{path:.*}',self.asset)])
        app.cleanup_ctx.append(self.lifecycle)
        return app

if __name__=='__main__':
    state=Path(os.environ.get('RELAY_STATE_DIR',str(Path.home()/'.local/state/relay')))
    token_file=Path(os.environ.get('RELAY_TOKEN_FILE',str(state/'pairing-token')))
    if not token_file.exists(): raise SystemExit('Create a private pairing-token file first. See README.')
    if token_file.stat().st_mode & 0o077: raise SystemExit('Pairing token must have mode 600')
    token=token_file.read_text().strip()
    if len(token)<40: raise SystemExit('Pairing token must contain at least 40 characters')
    app=Bridge(os.environ.get('RELAY_CODEX_HOME',str(Path.home()/'.codex')),state,token).app()
    web.run_app(app,host='127.0.0.1',port=int(os.environ.get('RELAY_PORT','8787')),access_log=None)
