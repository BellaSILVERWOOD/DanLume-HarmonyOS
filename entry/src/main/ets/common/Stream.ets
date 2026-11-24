/*
 * 自己实现的 HTTPS 流式 POST（只够用来读 SSE）。
 *
 * 为什么不用 @ohos.net.http：真机上它的 on('dataReceive') 一次都不触发（chunks=0），
 * 拿不到增量。这里走已经验证可用的 TLSSocket 路径：
 *   TCPSocket.connect → constructTLSSocketInstance(tcp) → 再 connect 一次触发握手 →
 *   手写 HTTP/1.1 请求 → 读 chunked 响应 → 逐段回调 SSE 事件。
 */
import socket from '@ohos.net.socket';
import buffer from '@ohos.buffer';

class UrlParts {
  host: string = '';
  path: string = '/';
  port: number = 443;
}

function parseUrl(url: string): UrlParts {
  const parts = new UrlParts();
  let rest = url;
  if (rest.startsWith('https://')) {
    rest = rest.substring(8);
  } else if (rest.startsWith('http://')) {
    rest = rest.substring(7);
    parts.port = 80;
  }
  const slash = rest.indexOf('/');
  if (slash >= 0) {
    parts.host = rest.substring(0, slash);
    parts.path = rest.substring(slash);
  } else {
    parts.host = rest;
    parts.path = '/';
  }
  const colon = parts.host.indexOf(':');
  if (colon >= 0) {
    const portText = parts.host.substring(colon + 1);
    const port = parseInt(portText, 10);
    if (!isNaN(port)) {
      parts.port = port;
    }
    parts.host = parts.host.substring(0, colon);
  }
  return parts;
}

/** HTTP/1.1 的 chunked 解码（保留跨包状态） */
class ChunkDecoder {
  private pending: string = '';
  private remaining: number = -1;
  private done: boolean = false;

  feed(text: string, onData: (data: string) => void): void {
    this.pending += text;
    while (!this.done) {
      if (this.remaining < 0) {
        const idx = this.pending.indexOf('\r\n');
        if (idx < 0) {
          return;
        }
        const line = this.pending.substring(0, idx).split(';')[0].trim();
        this.pending = this.pending.substring(idx + 2);
        const size = parseInt(line, 16);
        if (isNaN(size) || size === 0) {
          this.done = true;
          return;
        }
        this.remaining = size;
      }
      if (this.pending.length < this.remaining + 2) {
        return;
      }
      onData(this.pending.substring(0, this.remaining));
      this.pending = this.pending.substring(this.remaining + 2);
      this.remaining = -1;
    }
  }
}

/** SSE：按空行切事件 */
class SseDecoder {
  private buf: string = '';
  private emit: (event: string) => void;

  constructor(emit: (event: string) => void) {
    this.emit = emit;
  }

  feed(text: string): void {
    this.buf += text;
    let idx = this.buf.indexOf('\n\n');
    while (idx >= 0) {
      this.emit(this.buf.substring(0, idx));
      this.buf = this.buf.substring(idx + 2);
      idx = this.buf.indexOf('\n\n');
    }
  }
}

/** 发一个 HTTPS POST，按 SSE 事件回调；返回 HTTP 状态码 */
export async function streamPost(url: string, headers: Record<string, string>, body: string,
  onEvent: (event: string) => void): Promise<number> {
  const parts = parseUrl(url);
  const tcp = socket.constructTCPSocketInstance();
  await tcp.connect({ address: { address: parts.host, port: parts.port }, timeout: 15000 });
  const tls = socket.constructTLSSocketInstance(tcp);
  await tls.connect({
    address: { address: parts.host, port: parts.port },
    secureOptions: {
      protocols: [socket.Protocol.TLSv12, socket.Protocol.TLSv13],
      useRemoteCipherPrefer: true,
    },
    timeout: 15000,
  });

  let raw = '';
  let headersDone = false;
  let chunked = false;
  let status = 0;
  let finished = false;
  const chunkDecoder = new ChunkDecoder();
  const sse = new SseDecoder(onEvent);

  return await new Promise<number>((resolve: (code: number) => void) => {
    const finish = (): void => {
      if (finished) {
        return;
      }
      finished = true;
      try {
        tls.close();
      } catch (e) {
        // 忽略
      }
      resolve(status);
    };
    tls.on('message', (info: socket.SocketMessageInfo) => {
      raw += buffer.from(info.message).toString('utf8');
      if (!headersDone) {
        const idx = raw.indexOf('\r\n\r\n');
        if (idx < 0) {
          return;
        }
        const head = raw.substring(0, idx);
        const m = /^HTTP\/1\.[01] (\d{3})/.exec(head);
        status = m !== null ? parseInt(m[1], 10) : 0;
        chunked = /transfer-encoding:\s*chunked/i.test(head);
        raw = raw.substring(idx + 4);
        headersDone = true;
      }
      const ready = raw;
      raw = '';
      if (chunked) {
        chunkDecoder.feed(ready, (data: string) => { sse.feed(data); });
      } else {
        sse.feed(ready);
      }
    });
    tls.on('close', () => { finish(); });
    tls.on('error', () => { finish(); });
    setTimeout(finish, 180000);

    const headLines: string[] = [
      `POST ${parts.path} HTTP/1.1`,
      `Host: ${parts.host}`,
      'Connection: close',
      'Accept: text/event-stream',
    ];
    const keys = Object.keys(headers);
    for (const key of keys) {
      headLines.push(`${key}: ${headers[key]}`);
    }
    headLines.push(`Content-Length: ${buffer.byteLength(body)}`);
    const payload = `${headLines.join('\r\n')}\r\n\r\n${body}`;
    tls.send(buffer.from(payload, 'utf8').buffer).catch(() => { finish(); });
  });
}
