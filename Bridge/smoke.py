"""Read-only private bridge smoke check. Never sends a prompt or approves tools."""
import argparse
import asyncio
import json
from pathlib import Path
import aiohttp

async def run(url, token_file):
    headers={'Authorization':'Bearer '+Path(token_file).read_text().strip()}
    async with aiohttp.ClientSession() as s:
        async with s.get(url+'/v1/health') as r:
            assert r.status == 401
            print('PASS: unauthenticated access rejected')
    async with aiohttp.ClientSession(headers=headers) as s:
        async with s.get(url+'/v1/health',headers={'Origin':'https://example.com'}) as r:
            assert r.status==403
            print('PASS: browser-origin requests rejected')
        async with s.get(url+'/v1/health') as r:
            assert r.status==200
            health=await r.json(); assert health['desktopConnected']
            print('PASS: authenticated host and desktop ready')
        async with s.get(url+'/v1/threads') as r:
            assert r.status==200
            page=await r.json(); assert page['data']
            print('PASS: task history returned',len(page['data']),'tasks; more:',bool(page['nextCursor']))
        for summary in page['data'][:10]:
            tid=summary['id']
            async with s.get(url+'/v1/threads/'+tid) as r:
                if r.status!=200: continue
                conversation=await r.json()
                assert conversation['id']==tid and conversation['ownerAvailable']
                print('PASS: desktop-owned conversation;',len(conversation['messages']),'timeline items')
            async with s.ws_connect(url.replace('https:','wss:')+'/v1/threads/'+tid+'/stream',compress=15) as ws:
                event=await ws.receive_json(timeout=55)
                assert event['type']=='conversation' and event['conversation']['id']==tid
                print('PASS: authenticated WebSocket snapshot; revision',event['conversation']['revision'])
            return
        raise AssertionError('No desktop-owned task found among the first ten tasks')

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('url');p.add_argument('token_file');a=p.parse_args()
    asyncio.run(run(a.url.rstrip('/'),a.token_file))
