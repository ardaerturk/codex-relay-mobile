import asyncio
import copy
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock
from aiohttp.test_utils import TestClient, TestServer
from desktop import apply_patches, conversation_view, Desktop, DesktopError
from server import Bridge

def state():
    return {'id':'test-thread-123','title':'Synthetic test task','cwd':'/workspace',
        'turnHistory':{'kind':'canonical','history':{'isComplete':True,'entitiesByKey':{
            'turn:first':{'turnId':'first','status':'completed','items':[{'id':'a','type':'agentMessage','text':'First'}]},
            'turn:last':{'turnId':'last','status':'inProgress','items':[{'id':'b','type':'agentMessage','text':'Latest'}]}},
            'islands':[{'entries':[{'key':'turn:first','value':'turn:first'},{'key':'turn:last','value':'turn:last'}]}]}},
        'threadRuntimeStatus':{'type':'active'},'requests':[]}

class ProjectionTests(unittest.TestCase):
    def test_canonical_order_not_dictionary_insertion_order(self):
        s=state();h=s['turnHistory']['history'];h['entitiesByKey']=dict(reversed(list(h['entitiesByKey'].items())))
        v=conversation_view(s,4)
        self.assertEqual([x['text'] for x in v['messages']],['First','Latest'])
        self.assertEqual(v['activeTurnId'],'last')
    def test_patch_batch_atomic_on_invalid_path(self):
        original={'items':['a','b']};old=copy.deepcopy(original)
        with self.assertRaises(KeyError):apply_patches(original,[{'op':'replace','path':['items',0],'value':'x'},{'op':'replace','path':['missing','x'],'value':1}])
        self.assertEqual(original,old)
    def test_patch_insert_remove_and_text(self):
        result=apply_patches({'items':['a','b']},[{'op':'add','path':['items',1],'value':'new'},{'op':'remove','path':['items',0]}])
        self.assertEqual(result,{'items':['new','b']})
    def test_nullable_desktop_output_is_valid_for_native_decoder(self):
        s=state();s['turnHistory']['history']['entitiesByKey']['turn:last']['items']=[{'id':'nulls','type':'commandExecution','aggregatedOutput':None,'command':None,'phase':None,'status':None}]
        item=conversation_view(s,1)['messages'][-1]
        for field in ['text','title','phase','status']:self.assertIsInstance(item[field],str)

class DesktopTests(unittest.IsolatedAsyncioTestCase):
    async def test_revision_gap_disables_writes(self):
        d=Desktop('/unused');d.owners['test-thread-123']='owner';d.states['test-thread-123']=state();d.revisions['test-thread-123']=5
        await d._broadcast({'type':'broadcast','method':'thread-stream-state-changed','version':11,'sourceClientId':'owner','params':{'hostId':'local','conversationId':'test-thread-123','change':{'type':'patches','baseRevision':3,'revision':6,'patches':[]}}})
        self.assertNotIn('test-thread-123',d.owners)
    async def test_other_owner_cannot_overwrite_snapshot(self):
        d=Desktop('/unused');d.owners['test-thread-123']='owner';d.states['test-thread-123']=state();d.revisions['test-thread-123']=5
        await d._broadcast({'type':'broadcast','method':'thread-stream-state-changed','version':11,'sourceClientId':'other','params':{'hostId':'local','conversationId':'test-thread-123','change':{'type':'snapshot','revision':6,'conversationState':{'id':'bad'}}}})
        self.assertEqual(d.states['test-thread-123']['id'],'test-thread-123')

class ConfigurationTests(unittest.TestCase):
    def test_private_https_origin_is_required(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            for origin in ('http://host', 'https://user:pass@host', 'https://host/path', 'https://host/?token=x'):
                with self.assertRaises(ValueError): Bridge(root,root/'relay','t'*64,origin=origin)

class APITests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp=tempfile.TemporaryDirectory();root=Path(self.temp.name)
        c=sqlite3.connect(root/'state_5.sqlite')
        c.execute('CREATE TABLE threads (id TEXT, name TEXT, title TEXT, cwd TEXT, model_provider TEXT, updated_at INTEGER,is_pinned INTEGER,archived INTEGER,source TEXT,has_user_event INTEGER)')
        c.execute("INSERT INTO threads VALUES ('test-thread-123','Synthetic test','Prompt','/work','azure',1,0,0,'vscode',0)");c.commit();c.close()
        self.bridge=Bridge(root,root/'relay','t'*64,origin='https://relay.example.test',web_dir=root/'web')
        self.bridge.desktop.connected=True
        self.bridge.desktop.states['test-thread-123']=state()
        self.bridge.desktop.follow=AsyncMock(return_value={})
        self.bridge.desktop.command=AsyncMock(return_value={'result':{}})
        app=self.bridge.app();app.cleanup_ctx.clear()
        self.client=TestClient(TestServer(app));await self.client.start_server()
        self.headers={'Authorization':'Bearer '+'t'*64}
    async def asyncTearDown(self):
        await self.client.close();self.bridge.journal.close();self.temp.cleanup()
    async def post(self,body):
        return await self.client.post('/v1/threads/test-thread-123/commands',headers=self.headers,json=body)
    async def test_auth_and_origin(self):
        self.assertEqual((await self.client.get('/v1/health')).status,401)
        self.assertEqual((await self.client.get('/v1/health',headers={**self.headers,'Origin':'https://evil.example'})).status,403)
    async def browser_session(self):
        response=await self.client.post('/auth/session',headers={'Origin':self.bridge.origin},json={'token':'t'*64})
        self.assertEqual(response.status,200)
        cookie=response.cookies['__Host-relay']
        self.assertTrue(cookie['secure']);self.assertTrue(cookie['httponly']);self.assertEqual(cookie['samesite'],'Strict')
        return {'Cookie':'__Host-relay='+cookie.value}
    async def test_cookie_auth_csrf_and_logout(self):
        headers=await self.browser_session()
        self.assertEqual((await self.client.get('/v1/health',headers=headers)).status,200)
        self.assertEqual((await self.client.post('/auth/logout',headers=headers,json={})).status,403)
        self.assertEqual((await self.client.get('/v1/health',headers={**headers,'Origin':'https://evil.example'})).status,403)
        self.assertEqual((await self.client.get('/v1/threads/test-thread-123/stream',headers={**headers,'Upgrade':'websocket','Origin':'https://evil.example'})).status,403)
        self.assertEqual((await self.client.post('/auth/logout',headers={**headers,'Origin':self.bridge.origin},json={})).status,200)
        self.assertEqual((await self.client.get('/v1/health',headers=headers)).status,401)
    async def test_session_expiry(self):
        headers=await self.browser_session()
        self.bridge.journal.execute('UPDATE sessions SET expires=0');self.bridge.journal.commit()
        self.assertEqual((await self.client.get('/v1/health',headers=headers)).status,401)
    async def test_pairing_requires_origin_and_valid_token(self):
        self.assertEqual((await self.client.post('/auth/session',json={'token':'t'*64})).status,403)
        self.assertEqual((await self.client.post('/auth/session',headers={'Origin':self.bridge.origin},json={'token':'wrong'})).status,401)
        self.assertEqual((await self.client.post('/auth/session',headers={'Origin':'https://evil.example'},json={'token':'t'*64})).status,403)
    async def test_static_shell_public_but_api_private(self):
        self.bridge.web_dir.mkdir()
        (self.bridge.web_dir/'index.html').write_text('<!doctype html><title>Relay</title>')
        response=await self.client.get('/')
        self.assertEqual(response.status,200)
        self.assertIn("frame-ancestors 'none'",response.headers['Content-Security-Policy'])
        self.assertEqual((await self.client.get('/v1/threads')).status,401)
        (self.bridge.web_dir/'index.html').unlink();self.bridge.web_dir.rmdir()
    async def test_legacy_desktop_tasks_without_has_user_event_are_listed(self):
        r=await self.client.get('/v1/threads',headers=self.headers)
        self.assertEqual(len((await r.json())['data']),1)
    async def test_identical_request_is_forwarded_only_once(self):
        body={'id':'request-12345','operation':'send','text':'Synthetic test'}
        for _ in range(2): self.assertEqual((await (await self.post(body)).json())['status'],'accepted')
        self.assertEqual(self.bridge.desktop.command.await_count,1)
    async def test_active_prompt_is_steered(self):
        await self.post({'id':'request-12345','operation':'send','text':'Synthetic test'})
        self.assertEqual(self.bridge.desktop.command.call_args.args[1],'thread-follower-steer-turn')
    async def test_idle_prompt_inherits_desktop_settings(self):
        s=self.bridge.desktop.states['test-thread-123']
        s['turnHistory']['history']['entitiesByKey']['turn:last']['status']='completed'
        s['threadRuntimeStatus']={'type':'idle'}
        await self.post({'id':'request-12345','operation':'send','text':'Synthetic test'})
        args=self.bridge.desktop.command.call_args.args
        self.assertEqual(args[1],'thread-follower-start-turn')
        self.assertTrue(args[2]['turnStart']['context']['inheritThreadSettings'])
    async def test_approval_requires_matching_pending_request(self):
        self.bridge.desktop.states['test-thread-123']['requests']=[{'id':123,'method':'item/commandExecution/requestApproval','params':{'availableDecisions':['accept','decline']}}]
        response=await self.post({'id':'request-12345','operation':'approveCommand','requestId':123,'decision':'accept'})
        self.assertEqual(response.status,200)
        self.assertEqual(self.bridge.desktop.command.call_args.args[1],'thread-follower-command-approval-decision')
    async def test_user_input_requires_all_question_ids(self):
        self.bridge.desktop.states['test-thread-123']['requests']=[{'id':123,'method':'item/tool/requestUserInput','params':{'questions':[{'id':'q1'}]}}]
        response=await self.post({'id':'request-12345','operation':'answer','requestId':123,'answers':{}})
        self.assertEqual(response.status,400);self.bridge.desktop.command.assert_not_awaited()
    async def test_conflicting_duplicate_rejected(self):
        await self.post({'id':'request-12345','operation':'send','text':'First'})
        self.assertEqual((await self.post({'id':'request-12345','operation':'send','text':'Second'})).status,409)
    async def test_timeout_is_uncertain_and_never_replayed(self):
        self.bridge.desktop.command.side_effect=asyncio.TimeoutError()
        body={'id':'request-12345','operation':'send','text':'Synthetic'}
        for _ in range(2):self.assertEqual((await (await self.post(body)).json())['status'],'uncertain')
        self.assertEqual(self.bridge.desktop.command.await_count,1)
    async def test_stale_stop_does_not_interrupt_new_turn(self):
        r=await self.post({'id':'request-12345','operation':'stop','expectedTurnId':'first'})
        self.assertEqual(r.status,409);self.bridge.desktop.command.assert_not_awaited()
    async def test_arbitrary_rpc_and_unknown_approval_rejected(self):
        self.assertEqual((await self.post({'id':'request-12345','operation':'shellExec'})).status,400)
        self.assertEqual((await self.post({'id':'request-12346','operation':'approveCommand','requestId':'missing','decision':'accept'})).status,409)
        self.bridge.desktop.command.assert_not_awaited()

if __name__=='__main__':unittest.main()
