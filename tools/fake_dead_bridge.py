#!/usr/bin/env python3
"""A websocket server that accepts connections and then plays dead: no pongs, no frames.

Used to test the client's liveness detection locally (a real half-open socket is hard to
reproduce on one machine). Usage: tools/ros.sh jazzy python tools/fake_dead_bridge.py [port]
"""

import sys

from aiohttp import web

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9099


async def handler(request: web.Request) -> web.StreamResponse:
    ws = web.WebSocketResponse(autoping=False)  # do NOT answer pings
    await ws.prepare(request)
    print("client connected; playing dead", flush=True)
    async for msg in ws:  # drain whatever arrives, never reply
        print(f"got {msg.type.name} {str(msg.data)[:80]!r}", flush=True)
    return ws


app = web.Application()
app.add_routes([web.get("/", handler)])
print(f"dead bridge on :{PORT}", flush=True)
web.run_app(app, host="127.0.0.1", port=PORT, print=None)
