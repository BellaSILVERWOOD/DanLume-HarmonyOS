/*
 * 手机端邮件：目前实现 SMTP 发信（465 / 隐式 TLS + AUTH LOGIN）。
 * IMAP 收信下一步再做。
 *
 * 配置存在 settings：
 *   mail_address / mail_auth / mail_smtp_host / mail_smtp_port / mail_imap_host / mail_imap_port
 * 常见值：
 *   QQ 邮箱   smtp.qq.com:465   imap.qq.com:993
 *   163       smtp.163.com:465  imap.163.com:993
 *   复旦      smtp.fudan.edu.cn:465 / imap.fudan.edu.cn:993（以邮件系统说明为准）
 */
import socket from '@ohos.net.socket';
import connection from '@ohos.net.connection';
import buffer from '@ohos.buffer';
import { BusinessError } from '@kit.BasicServicesKit';
import { Db } from './Db';

export class MailConfig {
  address: string = '';
  auth: string = '';
  smtpHost: string = '';
  smtpPort: number = 465;
  imapHost: string = '';
  imapPort: number = 993;

  ok(): boolean {
    return this.address.length > 0 && this.auth.length > 0 && this.smtpHost.length > 0;
  }
}

export async function loadMailConfig(): Promise<MailConfig> {
  const cfg = new MailConfig();
  cfg.address = await Db.getSetting('mail_address', '');
  cfg.auth = await Db.getSetting('mail_auth', '');
  cfg.smtpHost = await Db.getSetting('mail_smtp_host', 'smtp.qq.com');
  const sp = parseInt(await Db.getSetting('mail_smtp_port', '465'), 10);
  cfg.smtpPort = isNaN(sp) ? 465 : sp;
  cfg.imapHost = await Db.getSetting('mail_imap_host', 'imap.qq.com');
  const ip = parseInt(await Db.getSetting('mail_imap_port', '993'), 10);
  cfg.imapPort = isNaN(ip) ? 993 : ip;
  return cfg;
}

/** 把 BusinessError / 普通错误都转成人能看的字符串（ArkTS 里直接拼对象会变成 [object Object]） */
function errText(err: Object): string {
  const o = err as Record<string, Object>;
  const code = o['code'];
  const msg = o['message'];
  const parts: string[] = [];
  if (code !== undefined && `${code}`.length > 0) {
    parts.push(`code=${code}`);
  }
  if (msg !== undefined && `${msg}`.length > 0) {
    parts.push(`${msg}`);
  }
  return parts.length > 0 ? parts.join(' ') : `${err}`;
}

/** TLSSocket.connect 只认 IP，不认域名：先自己解析一次 */
async function resolveHost(host: string): Promise<string> {
  try {
    const list = await connection.getAddressesByName(host);
    if (list.length > 0) {
      console.info(`[mail] ${host} -> ${list[0].address}`);
      return list[0].address;
    }
  } catch (e) {
    console.info(`[mail] dns failed: ${errText(e as Object)}`);
  }
  return host;
}

/** 先用 TCPSocket 连上，再升级成 TLSSocket（官方推荐的升级路径） */
async function upgradeTls(host: string, port: number): Promise<socket.TLSSocket> {
  const tcp = socket.constructTCPSocketInstance();
  await tcp.connect({ address: { address: host, port: port }, timeout: 15000 });
  const tls = socket.constructTLSSocketInstance(tcp);
  return tls;
}

class SmtpClient {
  private tls: socket.TLSSocket | null = null;
  private buf: string = '';
  private waiter: ((text: string) => void) | null = null;
  lastError: string = '';

  async connect(host: string, port: number): Promise<void> {
    console.info(`[smtp] connect ${host}:${port}`);
    let tls: socket.TLSSocket;
    try {
      tls = await upgradeTls(host, port);
      console.info('[smtp] upgraded from TCP');
      // 升级后有些版本还需要再 connect 一次触发握手；失败了就当已经握好
      try {
        await tls.connect({
          address: { address: host, port: port },
          secureOptions: {
            protocols: [socket.Protocol.TLSv12, socket.Protocol.TLSv13],
            useRemoteCipherPrefer: true,
          },
          timeout: 15000,
        });
        console.info('[smtp] handshake connect ok');
      } catch (e3) {
        console.info(`[smtp] post-upgrade connect: ${errText(e3 as Object)}`);
      }
    } catch (e) {
      console.info(`[smtp] upgrade failed: ${errText(e as Object)}, 走直连兜底`);
      tls = socket.constructTLSSocketInstance();
      await resolveHost(host);
      try {
        await tls.bind({ address: '0.0.0.0', port: 0, family: 1 });
      } catch (e2) {
        console.info(`[smtp] bind skipped: ${errText(e2 as Object)}`);
      }
      await tls.connect({
        address: { address: host, port: port },
        secureOptions: {
          protocols: [socket.Protocol.TLSv12, socket.Protocol.TLSv13],
          useRemoteCipherPrefer: true,
        },
        timeout: 15000,
      });
    }
    tls.on('message', (info: socket.SocketMessageInfo) => {
      const size = info.message !== undefined ? info.message.byteLength : -1;
      console.info(`[smtp] recv ${size} bytes`);
      this.buf += buffer.from(info.message).toString('utf8');
      this.flush();
    });
    tls.on('error', (err: BusinessError) => {
      this.lastError = `${err.code}: ${err.message}`;
      console.error(`[smtp] socket error ${this.lastError}`);
      this.flush();
    });
    this.tls = tls;
  }

  /** 收到一段完整响应（最后一行是 "250 " 这种）就交给等待方 */
  private flush(): void {
    if (this.waiter === null) {
      return;
    }
    const lines = this.buf.split('\r\n').filter((s: string) => s.length > 0);
    if (lines.length === 0) {
      return;
    }
    const last = lines[lines.length - 1];
    if (!/^\d{3} /.test(last)) {
      return;
    }
    const text = this.buf;
    this.buf = '';
    const w = this.waiter;
    this.waiter = null;
    w(text);
  }

  waitResponse(): Promise<string> {
    return new Promise<string>((resolve: (text: string) => void) => {
      this.waiter = resolve;
      setTimeout(() => {
        if (this.waiter !== null) {
          const w = this.waiter;
          this.waiter = null;
          w('TIMEOUT');
        }
      }, 20000);
      this.flush();
    });
  }

  async raw(data: string): Promise<void> {
    if (this.tls === null) {
      throw new Error('SMTP 还没连接');
    }
    // 统一按 ArrayBuffer 发：字符串发送在真机上会被截断（DATA 正文尤其明显）
    await this.tls.send(buffer.from(data, 'utf8').buffer);
  }

  /** 发一段原样数据（DATA 正文），不额外补 CRLF；按 ArrayBuffer 发，避免字符串被截 */
  async sendData(data: string): Promise<string> {
    if (this.tls === null) {
      throw new Error('SMTP 还没连接');
    }
    const bytes = buffer.from(data, 'utf8');
    console.info(`[smtp] >> data ${data.length} chars / ${bytes.length} bytes`);
    await this.tls.send(bytes.buffer);
    const resp = await this.waitResponse();
    console.info(`[smtp] << ${resp.replace(/\r\n/g, ' | ').slice(0, 120)}`);
    return resp;
  }

  /** 发一条命令并等响应；返回响应文本 */
  async cmd(line: string): Promise<string> {
    await this.raw(`${line}\r\n`);
    const resp = await this.waitResponse();
    console.info(`[smtp] << ${resp.replace(/\r\n/g, ' | ').slice(0, 120)}`);
    return resp;
  }

  close(): void {
    try {
      this.tls?.close();
    } catch (e) {
      // 忽略
    }
    this.tls = null;
  }
}

function b64(text: string): string {
  return buffer.from(text, 'utf8').toString('base64');
}

/** Q 编码：先还原成字节数组再按 UTF-8 解（直接 String.fromCharCode 会变成 Latin-1 乱码） */
function qpDecode(data: string): string {
  const text = data.replace(/_/g, ' ');
  const bytes: number[] = [];
  let i = 0;
  while (i < text.length) {
    const c = text.charAt(i);
    if (c === '=' && i + 2 < text.length) {
      const code = parseInt(text.substring(i + 1, i + 3), 16);
      if (!isNaN(code)) {
        bytes.push(code);
        i += 3;
        continue;
      }
    }
    bytes.push(text.charCodeAt(i));
    i += 1;
  }
  return buffer.from(new Uint8Array(bytes)).toString('utf8');
}

/** 解 =?UTF-8?B?xxx?= / =?utf-8?Q?xxx?= 这种 MIME 编码（可能连续出现多个） */
function decodeMime(raw: string): string {
  const re = /=\?([^?]+)\?([BbQq])\?([^?]*)\?=/g;
  let out = '';
  let last = 0;
  let m = re.exec(raw);
  while (m !== null) {
    out += raw.substring(last, m.index);
    const enc = m[2].toUpperCase();
    const data = m[3];
    try {
      if (enc === 'B') {
        out += buffer.from(data, 'base64').toString('utf8');
      } else {
        out += qpDecode(data);
      }
    } catch (e) {
      out += m[0];
    }
    last = m.index + m[0].length;
    m = re.exec(raw);
  }
  out += raw.substring(last);
  return out.trim();
}

export class MailHeader {
  index: number = 0;
  from: string = '';
  to: string = '';
  subject: string = '';
  date: string = '';
}

class ImapClient {
  private tls: socket.TLSSocket | null = null;
  private buf: string = '';
  private tag: string = '';
  private seq: number = 0;
  private resolveFn: ((text: string) => void) | null = null;
  private pattern: RegExp = /^$/;

  async connect(host: string, port: number): Promise<void> {
    let tls: socket.TLSSocket;
    try {
      tls = await upgradeTls(host, port);
      console.info('[imap] upgraded from TCP');
      try {
        await tls.connect({
          address: { address: host, port: port },
          secureOptions: {
            protocols: [socket.Protocol.TLSv12, socket.Protocol.TLSv13],
            useRemoteCipherPrefer: true,
          },
          timeout: 15000,
        });
        console.info('[imap] handshake connect ok');
      } catch (e3) {
        console.info(`[imap] post-upgrade connect: ${errText(e3 as Object)}`);
      }
    } catch (e) {
      console.info(`[imap] upgrade failed: ${errText(e as Object)}, 走直连兜底`);
      tls = socket.constructTLSSocketInstance();
      await resolveHost(host);
      await tls.bind({ address: '0.0.0.0', port: 0, family: 1 }).catch((e2: Object) => {
        console.info(`[imap] bind skipped: ${errText(e2)}`);
      });
      await tls.connect({
        address: { address: host, port: port },
        secureOptions: {
          protocols: [socket.Protocol.TLSv12, socket.Protocol.TLSv13],
          useRemoteCipherPrefer: true,
        },
        timeout: 15000,
      });
    }
    tls.on('message', (info: socket.SocketMessageInfo) => {
      this.buf += buffer.from(info.message).toString('utf8');
      this.pump();
    });
    this.tls = tls;
  }

  private pump(): void {
    if (this.resolveFn === null) {
      return;
    }
    if (this.pattern.test(this.buf)) {
      const text = this.buf;
      this.buf = '';
      const fn = this.resolveFn;
      this.resolveFn = null;
      fn(text);
    }
  }

  private waitFor(pattern: RegExp): Promise<string> {
    return new Promise<string>((resolve: (text: string) => void) => {
      this.pattern = pattern;
      this.resolveFn = resolve;
      setTimeout(() => {
        if (this.resolveFn !== null) {
          const fn = this.resolveFn;
          this.resolveFn = null;
          fn(this.buf);
        }
      }, 20000);
      this.pump();
    });
  }

  async greeting(): Promise<string> {
    return await this.waitFor(/^\* OK/);
  }

  async exec(command: string): Promise<string> {
    if (this.tls === null) {
      throw new Error('IMAP 还没连接');
    }
    this.seq += 1;
    this.tag = `a${this.seq}`;
    const pattern = new RegExp(`(?:^|\\r\\n)${this.tag} (OK|NO|BAD)[^\\r\\n]*\\r\\n`);
    const pending = this.waitFor(pattern);
    console.info(`[imap] >> ${this.tag} ${command.slice(0, 40)}`);
    await this.tls.send(buffer.from(`${this.tag} ${command}\r\n`, 'utf8').buffer);
    return await pending;
  }

  close(): void {
    try {
      this.tls?.close();
    } catch (e) {
      // 忽略
    }
    this.tls = null;
  }
}

/** 读最近 limit 封邮件的信头；出错抛异常（UI 直接显示 e.message） */
/** 找「已发送」文件夹（各家叫法不同，先看 LIST 里的 \Sent 标记） */
async function resolveFolder(client: ImapClient, kind: string): Promise<string> {
  if (kind !== 'SENT') {
    return 'INBOX';
  }
  try {
    const raw = await client.exec('LIST "" "*"');
    for (const line of raw.split('\r\n')) {
      if (line.startsWith('* LIST') && line.indexOf('\\Sent') >= 0) {
        const m = /"([^"]+)"\s*$/.exec(line);
        if (m !== null) {
          return m[1];
        }
      }
    }
    for (const name of ['Sent Messages', 'Sent', 'Sent Items']) {
      if (raw.indexOf(name) >= 0) {
        return name;
      }
    }
  } catch (e) {
    console.info(`[imap] LIST failed: ${errText(e as Object)}`);
  }
  return 'Sent';
}

/** 读某个文件夹最近 limit 封的信头；kind = 'INBOX' | 'SENT' */
export async function fetchMailList(kind: string, limit: number): Promise<MailHeader[]> {
  const cfg = await loadMailConfig();
  if (cfg.address.length === 0 || cfg.auth.length === 0 || cfg.imapHost.length === 0) {
    throw new Error('还没配置邮箱（我的 → 邮件：地址、授权码、IMAP 服务器）');
  }
  const n = limit < 1 ? 5 : (limit > 30 ? 30 : limit);
  const client = new ImapClient();
  try {
    await client.connect(cfg.imapHost, cfg.imapPort);
    const greet = await client.greeting();
    if (!greet.includes('* OK')) {
      throw new Error(`连接被拒：${greet.slice(0, 100)}`);
    }
    const login = await client.exec(`LOGIN "${cfg.address}" "${cfg.auth}"`);
    if (!login.includes(' OK')) {
      throw new Error(`登录失败：${login.slice(0, 120)}（QQ/163 用授权码，不是登录密码）`);
    }
    const folder = await resolveFolder(client, kind);
    const select = await client.exec(`SELECT "${folder}"`);
    if (!select.includes(' OK')) {
      throw new Error(`打不开文件夹 ${folder}`);
    }
    const existsMatch = /(\d+) EXISTS/.exec(select);
    const total = existsMatch !== null ? parseInt(existsMatch[1], 10) : 0;
    if (total === 0) {
      return [];
    }
    const from = Math.max(1, total - n + 1);
    const fetch = await client.exec(
      `FETCH ${from}:${total} (BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE)])`);
    return parseHeaders(fetch, from);
  } finally {
    client.close();
  }
}

export async function fetchInboxList(limit: number): Promise<MailHeader[]> {
  return await fetchMailList('INBOX', limit);
}

/** 读最近 limit 封邮件的信头，拼成给人看的字符串（AI 工具用） */
export async function fetchInbox(limit: number): Promise<string> {
  try {
    const headers = await fetchInboxList(limit);
    if (headers.length === 0) {
      return '收件箱是空的（或还没收到邮件）';
    }
    const lines: string[] = [];
    for (const h of headers) {
      lines.push(`#${h.index} ${h.date} | ${decodeMime(h.from)} | ${decodeMime(h.subject)}`);
    }
    return lines.join('\n');
  } catch (err) {
    return `收信出错：${err instanceof Error ? err.message : err}`;
  }
}

/** 取第 seq 封的正文（best effort：解 base64 / quoted-printable，HTML 去标签） */
export async function fetchMailBody(seq: number, kind: string = 'INBOX'): Promise<string> {
  const cfg = await loadMailConfig();
  if (cfg.address.length === 0 || cfg.auth.length === 0) {
    throw new Error('还没配置邮箱');
  }
  const client = new ImapClient();
  try {
    await client.connect(cfg.imapHost, cfg.imapPort);
    await client.greeting();
    const login = await client.exec(`LOGIN "${cfg.address}" "${cfg.auth}"`);
    if (!login.includes(' OK')) {
      throw new Error('IMAP 登录失败（授权码）');
    }
    const folder = await resolveFolder(client, kind);
    await client.exec(`SELECT "${folder}"`);
    const raw = await client.exec(`FETCH ${seq} BODY.PEEK[]`);
    const message = extractLiteral(raw);
    return decodeMessage(message);
  } finally {
    client.close();
  }
}

/** IMAP 的 {123}\r\n<123 字节> 字面量 */
function extractLiteral(raw: string): string {
  const m = /\{(\d+)\}\r\n/.exec(raw);
  if (m === null) {
    return '';
  }
  const start = m.index + m[0].length;
  const size = parseInt(m[1], 10);
  return raw.substr(start, size);
}

function decodeQuotedPrintable(text: string): string {
  const joined = text.replace(/=\r\n/g, '');
  let out = '';
  let i = 0;
  while (i < joined.length) {
    const c = joined.charAt(i);
    if (c === '=' && i + 2 < joined.length) {
      const hex = joined.substring(i + 1, i + 3);
      const code = parseInt(hex, 16);
      if (!isNaN(code)) {
        out += String.fromCharCode(code);
        i += 3;
        continue;
      }
    }
    out += c;
    i += 1;
  }
  return out;
}

function decodeMessage(message: string): string {
  if (message.length === 0) {
    return '（这封邮件读不出正文）';
  }
  const split = message.indexOf('\r\n\r\n');
  const head = split >= 0 ? message.substring(0, split) : message;
  let body = split >= 0 ? message.substring(split + 4) : '';
  const isBase64 = /Content-Transfer-Encoding:\s*base64/i.test(head);
  const isQp = /Content-Transfer-Encoding:\s*quoted-printable/i.test(head);
  const isHtml = /Content-Type:\s*text\/html/i.test(head);
  try {
    if (isBase64) {
      body = buffer.from(body.replace(/\s+/g, ''), 'base64').toString('utf8');
    } else if (isQp) {
      body = decodeQuotedPrintable(body);
    }
  } catch (e) {
    // 解码失败就按原文显示
  }
  if (isHtml) {
    body = body.replace(/<style[\s\S]*?<\/style>/gi, ' ');
    body = body.replace(/<script[\s\S]*?<\/script>/gi, ' ');
    body = body.replace(/<br\s*\/?>/gi, '\n');
    body = body.replace(/<[^>]+>/g, ' ');
    body = body.replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>').replace(/&quot;/g, '"');
    body = body.replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n');
  }
  return body.trim().slice(0, 6000);
}

function parseHeaders(raw: string, firstIndex: number): MailHeader[] {
  const out: MailHeader[] = [];
  // 先把折行（以空格/制表符开头的续行）拼回去，否则长主题只拿到前一段 encoded-word
  const folded: string[] = [];
  for (const line of raw.split('\r\n')) {
    if ((line.startsWith(' ') || line.startsWith('\t')) && folded.length > 0) {
      folded[folded.length - 1] += line.trim();
    } else {
      folded.push(line);
    }
  }
  let index = firstIndex;
  let from = '';
  let to = '';
  let subject = '';
  let date = '';
  for (const line of folded) {
    if (line.startsWith('* ') && line.includes('FETCH')) {
      if (from.length > 0 || subject.length > 0) {
        const h = new MailHeader();
        h.index = index;
        h.from = from;
        h.to = to;
        h.subject = subject;
        h.date = date;
        out.push(h);
        index += 1;
      }
      from = '';
      to = '';
      subject = '';
      date = '';
      continue;
    }
    if (line.startsWith('From:')) {
      from = decodeMime(line.substring(5).trim());
    } else if (line.startsWith('To:')) {
      to = decodeMime(line.substring(3).trim());
    } else if (line.startsWith('Subject:')) {
      subject = decodeMime(line.substring(8).trim());
    } else if (line.startsWith('Date:')) {
      date = line.substring(5).trim();
    }
  }
  if (from.length > 0 || subject.length > 0) {
    const h = new MailHeader();
    h.index = index;
    h.from = from;
    h.to = to;
    h.subject = subject;
    h.date = date;
    out.push(h);
  }
  return out;
}

function expectCode(resp: string, code: string): boolean {
  return resp.startsWith(code);
}

/** 发一封纯文本邮件；返回给人看的结果说明 */
export async function sendMail(to: string, subject: string, body: string): Promise<string> {
  const cfg = await loadMailConfig();
  if (!cfg.ok()) {
    return '还没配置邮箱：我的 → 邮件里填地址、授权码、SMTP 服务器';
  }
  if (to.trim().length === 0) {
    return '收件人为空';
  }
  const client = new SmtpClient();
  try {
    await client.connect(cfg.smtpHost, cfg.smtpPort);
    let resp = await client.waitResponse();
    if (!expectCode(resp, '220')) {
      return `连接被拒：${resp.slice(0, 120)}`;
    }
    resp = await client.cmd('EHLO danlume');
    if (!expectCode(resp, '250')) {
      return `EHLO 失败：${resp.slice(0, 120)}`;
    }
    resp = await client.cmd('AUTH LOGIN');
    if (!expectCode(resp, '334')) {
      return `服务器不支持 AUTH LOGIN：${resp.slice(0, 120)}`;
    }
    await client.cmd(b64(cfg.address));
    resp = await client.cmd(b64(cfg.auth));
    if (!expectCode(resp, '235')) {
      return `登录失败：${resp.slice(0, 120)}（QQ/163 要用「授权码」不是登录密码）`;
    }
    resp = await client.cmd(`MAIL FROM:<${cfg.address}>`);
    if (!expectCode(resp, '250')) {
      return `MAIL FROM 被拒：${resp.slice(0, 120)}`;
    }
    resp = await client.cmd(`RCPT TO:<${to.trim()}>`);
    if (!expectCode(resp, '250') && !expectCode(resp, '251')) {
      return `收件人被拒：${resp.slice(0, 120)}`;
    }
    resp = await client.cmd('DATA');
    if (!expectCode(resp, '354')) {
      return `DATA 被拒：${resp.slice(0, 120)}`;
    }
    const date = new Date().toUTCString();
    const safeBody = body.replace(/\r?\n/g, '\r\n');
    const stuffed = safeBody.split('\r\n').map((line: string) => line.startsWith('.') ? `.${line}` : line).join('\r\n');
    const headers: string[] = [
      `From: <${cfg.address}>`,
      `To: <${to.trim()}>`,
      `Subject: =?UTF-8?B?${b64(subject)}?=`,
      `Date: ${date}`,
      'MIME-Version: 1.0',
      'Content-Type: text/plain; charset=UTF-8',
      'Content-Transfer-Encoding: base64',
      '',
      '',
    ];
    const payload = `${headers.join('\r\n')}${b64(stuffed)}\r\n.\r\n`;
    resp = await client.sendData(payload);
    if (!expectCode(resp, '250')) {
      return `发送失败：${resp.slice(0, 120)}`;
    }
    await client.cmd('QUIT');
    return `已发送给 ${to.trim()}`;
  } catch (err) {
    const extra = client.lastError.length > 0 ? ` / socket ${client.lastError}` : '';
    const text = err instanceof Error ? err.message : errText(err as Object);
    return `发信出错：${text}（${cfg.smtpHost}:${cfg.smtpPort}）${extra}`;
  } finally {
    client.close();
  }
}
