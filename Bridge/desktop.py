"""Version-pinned, independently implemented Codex desktop IPC adapter.

This is NOT a public OpenAI API. Refuse unknown protocol versions; never start
another agent against an already-owned conversation. No desktop code is bundled.
"""
import asyncio
import copy
import json
import struct
import uuid
from pathlib import Path

VERSIONS = {
    'initialize': 0, 'thread-owner-discovery': 1,
    'thread-stream-following-changed': 1, 'thread-stream-state-changed': 11,
    'thread-follower-start-turn': 2, 'thread-follower-steer-turn': 1,
    'thread-follower-interrupt-turn': 4, 'thread-follower-load-complete-history': 1,
    'thread-follower-command-approval-decision': 1,
    'thread-follower-file-approval-decision': 1,
    'thread-follower-submit-user-input': 1,
}

class DesktopError(Exception):
    pass

def apply_patches(state, patches):
    """Apply Immer path-array patches to an independent copy, atomically."""
    result = copy.deepcopy(state)
    for patch in patches:
        path, op = patch['path'], patch['op']
        if op not in ('add', 'replace', 'remove') or not isinstance(path, list):
            raise DesktopError('Unsupported desktop patch')
        if not path:
            if op == 'remove': raise DesktopError('Invalid root removal')
            result = copy.deepcopy(patch['value'])
            continue
        obj = result
        for key in path[:-1]: obj = obj[key]
        key = path[-1]
        if op == 'remove':
            if isinstance(obj, list): obj.pop(key)
            else: del obj[key]
        elif isinstance(obj, list) and op == 'add':
            obj.insert(key, copy.deepcopy(patch['value']))
        else: obj[key] = copy.deepcopy(patch['value'])
    return result

def ordered_turns(state):
    history = state.get('turnHistory', {}).get('history')
    if history:
        entities = history.get('entitiesByKey', {})
        seen, turns = set(), []
        for island in history.get('islands', []):
            for entry in island.get('entries', []):
                key = entry.get('value')
                if key in entities and key not in seen:
                    turns.append(entities[key]); seen.add(key)
        return turns
    return state.get('turns', [])

def conversation_view(state, revision, owner_available=True):
    turns = ordered_turns(state)
    messages = []
    for turn in turns:
        for item in turn.get('items', []):
            kind = item.get('type', 'unknown')
            text, title = '', ''
            if kind == 'userMessage':
                text = '\n'.join(x.get('text', '') for x in item.get('content', []) if isinstance(x, dict))
            elif kind == 'agentMessage': text = item.get('text', '')
            elif kind == 'reasoning':
                text = '\n'.join(x if isinstance(x, str) else x.get('text', '') for x in item.get('summary', []))
                title = 'Thinking'
            elif kind == 'commandExecution':
                title = item.get('command', 'Command')
                text = item.get('aggregatedOutput', '')
            elif kind == 'fileChange':
                title = 'File changes'
                text = '\n\n'.join(x.get('path', '')+'\n'+x.get('diff', '') for x in item.get('changes', []))
            elif kind == 'mcpToolCall':
                title = item.get('tool', 'Tool call')
                text = json.dumps(item.get('result') or item.get('error') or item.get('arguments', {}), ensure_ascii=False, indent=2)
            else:
                title = kind
                text = json.dumps(item, ensure_ascii=False, indent=2)
            messages.append(dict(id=str(turn.get('turnId', ''))+':'+str(item.get('id', uuid.uuid4())),
                kind=kind, text=text or '', title=title or '', status=item.get('status') or '', phase=item.get('phase') or ''))
    runtime = state.get('threadRuntimeStatus', {}).get('type', 'unknown')
    active = next((t for t in reversed(turns) if t.get('status') == 'inProgress'), None)
    return dict(id=state['id'], title=state.get('title') or 'Untitled task', cwd=state.get('cwd') or '',
        model=state.get('latestModel') or '', effort=state.get('latestReasoningEffort') or '',
        provider=state.get('modelProvider') or '', status=runtime, revision=revision,
        ownerAvailable=owner_available, activeTurnId=active.get('turnId') if active else None,
        messages=messages, requests=state.get('requests') or [],
        diff=next((t.get('diff') for t in reversed(turns) if t.get('diff')), None),
        permissions=state.get('currentPermissions', {}).get('sandboxPolicy', {}).get('type', 'Host settings'),
        historyComplete=state.get('turnHistory', {}).get('history', {}).get('isComplete',
            state.get('turnsPagination', {}).get('hasLoadedOldest', True)))

class Desktop:
    def __init__(self, socket_path):
        self.path = str(socket_path)
        self.client_id = 'initializing-client'
        self.reader = self.writer = self.task = None
        self.pending, self.owners, self.states, self.revisions = {}, {}, {}, {}
        self.events, self.locks = {}, {}
        self.listeners = set()
        self.connected = False
        self.write_lock = asyncio.Lock()

    async def connect(self):
        if self.connected: return
        if self.task and not self.task.done(): self.task.cancel()
        self.reader, self.writer = await asyncio.open_unix_connection(self.path)
        self.task = asyncio.create_task(self._read())
        result = await self.request('initialize', {'clientType': 'relay-mobile'})
        self.client_id = result['result']['clientId']
        self.connected = True

    async def close(self):
        self.connected = False
        if self.writer:
            self.writer.close()
            await self.writer.wait_closed()
        if self.task: self.task.cancel()

    async def send(self, message):
        data = json.dumps(message, ensure_ascii=False).encode()
        if len(data) > 64*1024*1024: raise DesktopError('IPC frame too large')
        async with self.write_lock:
            self.writer.write(struct.pack('<I', len(data)) + data)
            await self.writer.drain()

    async def request(self, method, params, owner=None):
        rid = str(uuid.uuid4())
        future = asyncio.get_running_loop().create_future()
        self.pending[rid] = future
        message = dict(type='request', requestId=rid, sourceClientId=self.client_id,
            version=VERSIONS[method], method=method, params=params, timeoutMs=20000)
        if owner: message['targetClientId'] = owner
        try:
            await self.send(message)
            return await asyncio.wait_for(future, 25)
        finally: self.pending.pop(rid, None)

    async def follow(self, thread_id, force=False):
        async with self.locks.setdefault(thread_id, asyncio.Lock()):
            if not self.connected: raise DesktopError('Codex desktop is disconnected. Reconnect after reopening it on the VM.')
            if thread_id in self.states and thread_id in self.owners and not force:
                return self.view(thread_id)
            result = await self.request('thread-owner-discovery', {'hostId':'local', 'conversationId':thread_id})
            owner = result['handledByClientId']
            self.owners[thread_id] = owner
            event = self.events.setdefault(thread_id, asyncio.Event()); event.clear()
            await self.send(dict(type='broadcast', sourceClientId=self.client_id,
                method='thread-stream-following-changed', version=1, targetClientIds=[owner],
                params={'hostId':'local', 'conversationId':thread_id, 'following':True}))
            await asyncio.wait_for(event.wait(), 20)
            return self.view(thread_id)

    def view(self, thread_id):
        return conversation_view(self.states[thread_id], self.revisions[thread_id], self.connected and thread_id in self.owners)

    async def command(self, thread_id, method, params):
        await self.follow(thread_id)
        return await self.request(method, {'conversationId':thread_id, **params}, self.owners[thread_id])

    async def _read(self):
        try:
            while True:
                size = struct.unpack('<I', await self.reader.readexactly(4))[0]
                if size > 64*1024*1024: raise DesktopError('Desktop frame exceeds limit')
                msg = json.loads(await self.reader.readexactly(size))
                if msg.get('type') == 'response':
                    f = self.pending.get(msg.get('requestId'))
                    if f and not f.done():
                        if msg.get('resultType') == 'success': f.set_result(msg)
                        else: f.set_exception(DesktopError(msg.get('error', 'Desktop request failed')))
                elif msg.get('type') == 'client-discovery-request':
                    await self.send(dict(type='client-discovery-response',requestId=msg['requestId'],
                        sourceClientId=self.client_id,canHandle=False))
                elif msg.get('type') == 'broadcast':
                    await self._broadcast(msg)
        except (asyncio.IncompleteReadError, OSError, ValueError, DesktopError) as exc:
            self.connected = False; self.owners.clear()
            for f in self.pending.values():
                if not f.done(): f.set_exception(DesktopError('Desktop connection closed'))
            for callback in self.listeners: callback(None)

    async def _broadcast(self, msg):
        if msg.get('method') == 'client-status-changed':
            p = msg.get('params', {})
            if p.get('status') == 'disconnected':
                for tid, owner in list(self.owners.items()):
                    if owner == p.get('clientId'):
                        del self.owners[tid]
                        for callback in self.listeners: callback(tid)
            return
        if msg.get('method') != 'thread-stream-state-changed': return
        p = msg['params']; tid = p.get('conversationId')
        if p.get('hostId') != 'local' or tid not in self.owners: return
        if msg.get('sourceClientId') != self.owners[tid]: return
        if msg.get('version') != 11: raise DesktopError('Unsupported Codex desktop protocol version')
        change = p['change']
        try:
            if change['type'] == 'snapshot':
                self.states[tid] = change['conversationState']
            elif change['type'] == 'patches':
                if change['baseRevision'] != self.revisions.get(tid):
                    self.owners.pop(tid, None)
                    for callback in self.listeners: callback(tid)
                    return
                self.states[tid] = apply_patches(self.states[tid], change['patches'])
            else: raise DesktopError('Unknown desktop update')
            self.revisions[tid] = change['revision']
            self.events.setdefault(tid, asyncio.Event()).set()
            for callback in self.listeners: callback(tid)
        except (KeyError, IndexError, TypeError, DesktopError):
            self.owners.pop(tid, None)
            for callback in self.listeners: callback(tid)
