#!/usr/bin/env python3
"""W4 load: N connections POST a 256 KiB body over HTTP/1.1 and then read the
chunked echo slowly (CHUNK bytes every DELAY s), forcing server-side backpressure."""
import asyncio, sys, time

HOST, PORT = '127.0.0.1', int(sys.argv[1])
CONNS = int(sys.argv[2]); DUR = float(sys.argv[3])
CHUNK = 4096; DELAY = 0.020
BODY = b'c' * 262144
REQ = (b'POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: %d\r\n'
       b'Content-Type: application/octet-stream\r\n\r\n' % len(BODY)) + BODY

stats = {'req': 0, 'bytes': 0, 'err': 0}

async def one(deadline):
    while time.monotonic() < deadline:
        try:
            r, w = await asyncio.open_connection(HOST, PORT)
        except Exception:
            stats['err'] += 1; await asyncio.sleep(0.1); continue
        try:
            while time.monotonic() < deadline:
                w.write(REQ); await w.drain()
                # read the response slowly until the terminating chunk
                buf = b''
                while time.monotonic() < deadline:
                    d = await r.read(CHUNK)
                    if not d: raise ConnectionError('eof')
                    stats['bytes'] += len(d)
                    buf = (buf + d)[-8:]
                    if buf.endswith(b'0\r\n\r\n'): break
                    await asyncio.sleep(DELAY)
                stats['req'] += 1
        except Exception:
            stats['err'] += 1
        finally:
            try: w.close()
            except Exception: pass

async def main():
    deadline = time.monotonic() + DUR
    await asyncio.gather(*[one(deadline) for _ in range(CONNS)])
    print('requests=%d bytes=%d errors=%d' % (stats['req'], stats['bytes'], stats['err']))

asyncio.run(main())
