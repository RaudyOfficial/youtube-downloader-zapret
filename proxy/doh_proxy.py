"""Минимальный локальный HTTP CONNECT proxy, который разрешает имена через DNS-over-HTTPS.

ТСПУ подменяет обычный DNS (UDP 53), поэтому yt-dlp не может разрешить youtube.com.
Этот прокси резолвит через DoH (который проходит через zapret) и пробрасывает TCP/TLS
как есть, поэтому обход остаётся сквозным.
"""
import asyncio
import ipaddress
import json
import socket
import sys
import urllib.parse
import urllib.request

DOH_PROVIDERS = [
    ("https://dns.google/resolve?name={}&type=A", {"Accept": "application/dns-json"}),
    ("https://cloudflare-dns.com/dns-query?name={}&type=A", {"Accept": "application/dns-json"}),
]

_cache = {}


def _doh(host):
    for tmpl, headers in DOH_PROVIDERS:
        try:
            req = urllib.request.Request(tmpl.format(urllib.parse.quote(host)), headers=headers)
            with urllib.request.urlopen(req, timeout=10) as r:
                data = json.load(r)
            ips = [a["data"] for a in data.get("Answer", []) if a.get("type") == 1]
            ips = [ip for ip in ips if _valid_ipv4(ip)]
            if ips:
                return ips
        except Exception as e:
            print(f"[doh] {host} via {tmpl.split('/')[2]} failed: {e}", file=sys.stderr, flush=True)
    raise OSError(f"DoH resolution failed for {host}")


def _valid_ipv4(s):
    try:
        ipaddress.IPv4Address(s)
        return True
    except ValueError:
        return False


def resolve(host):
    try:
        ipaddress.ip_address(host)
        return [host]
    except ValueError:
        pass
    if host in _cache:
        return _cache[host]
    ips = _doh(host)
    # prefer addresses that are directly reachable
    _cache[host] = ips
    print(f"[dns] {host} -> {', '.join(ips)}", file=sys.stderr, flush=True)
    return ips


async def open_to(host, port):
    ips = await asyncio.to_thread(resolve, host)
    last = None
    for ip in ips:
        try:
            return await asyncio.wait_for(asyncio.open_connection(ip, port), timeout=12)
        except Exception as e:
            last = e
    raise OSError(f"connect to {host}:{port} failed: {last}")


async def relay(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def pipe(a_r, a_w, b_r, b_w):
    t1 = asyncio.create_task(relay(a_r, b_w))
    t2 = asyncio.create_task(relay(b_r, a_w))
    done, pending = await asyncio.wait({t1, t2}, return_when=asyncio.FIRST_COMPLETED)
    for t in pending:
        t.cancel()


async def read_head(reader):
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = await reader.read(4096)
        if not chunk:
            break
        head += chunk
    if b"\r\n\r\n" not in head:
        return None, b""
    head, rest = head.split(b"\r\n\r\n", 1)
    return head, rest


async def handle(reader, writer):
    target_writer = None
    try:
        head, rest = await read_head(reader)
        if head is None:
            return
        lines = head.split(b"\r\n")
        method, target, version = lines[0].decode("latin-1").split(" ", 2)

        if method.upper() == "CONNECT":
            host, _, port = target.rpartition(":")
            port = int(port or 443)
            try:
                r, w = await open_to(host, port)
            except Exception as e:
                writer.write(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
                await writer.drain()
                print(f"[err] CONNECT {target}: {e}", file=sys.stderr, flush=True)
                return
            target_writer = w
            writer.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
            await writer.drain()
            if rest:
                w.write(rest)
                await w.drain()
            await pipe(reader, writer, r, w)
        else:
            url = urllib.parse.urlsplit(target)
            host = url.hostname
            port = url.port or 80
            try:
                r, w = await open_to(host, port)
            except Exception as e:
                writer.write(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
                await writer.drain()
                print(f"[err] {method} {target}: {e}", file=sys.stderr, flush=True)
                return
            target_writer = w
            path = urllib.parse.urlunsplit(("", "", url.path or "/", url.query, ""))
            out = [f"{method} {path} {version}".encode("latin-1")] + lines[1:]
            w.write(b"\r\n".join(out) + b"\r\n\r\n" + rest)
            await w.drain()
            await pipe(reader, writer, r, w)
    except Exception as e:
        print(f"[err] {e}", file=sys.stderr, flush=True)
    finally:
        try:
            writer.close()
        except Exception:
            pass
        if target_writer is not None:
            try:
                target_writer.close()
            except Exception:
                pass


async def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18080
    server = await asyncio.start_server(handle, "127.0.0.1", port)
    print(f"[proxy] listening on 127.0.0.1:{port}", file=sys.stderr, flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
