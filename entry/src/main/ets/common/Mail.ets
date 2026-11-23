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
import buffer from '@ohos.buffer';
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

class SmtpClient {
  private tls: socket.TLSSocket | null = null;
  private buf: string = '';
  private waiter: ((text: string) => void) | null = null;

  async connect(host: string, port: number): Promise<void> {
    const tls = socket.constructTLSSocketInstance();
    tls.on('message', (info: socket.SocketMessageInfo) => {
      this.buf += buffer.from(info.message).toString('utf8');
      this.flush();
    });
    tls.on('error', () => {
      this.flush();
    });
    await tls.connect({
      address: { address: host, port: port },
      secureOptions: {},
      timeout: 15000,
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
    await this.tls.send(data);
  }

  /** 发一条命令并等响应；返回响应文本 */
  async cmd(line: string): Promise<string> {
    await this.raw(`${line}\r\n`);
    return await this.waitResponse();
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

/** 解 =?UTF-8?B?xxx?= 这种 MIME 编码，失败就原样返回 */
function decodeMime(raw: string): string {
  const m = /=\?UTF-8\?B\?([^?]+)\?=/i.exec(raw);
  if (m === null) {
    return raw.trim();
  }
  try {
    return buffer.from(m[1], 'base64').toString('utf8').trim();
  } catch (e) {
    return raw.trim();
  }
}

export class MailHeader {
  index: number = 0;
  from: string = '';
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
    const tls = socket.constructTLSSocketInstance();
    tls.on('message', (info: socket.SocketMessageInfo) => {
      this.buf += buffer.from(info.message).toString('utf8');
      this.pump();
    });
    await tls.connect({
      address: { address: host, port: port },
      secureOptions: {},
      timeout: 15000,
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
    const pattern = new RegExp(`\\r\\n${this.tag} (OK|NO|BAD)[^\\r\\n]*\\r\\n`);
    const pending = this.waitFor(pattern);
    await this.tls.send(`${this.tag} ${command}\r\n`);
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

/** 读最近 limit 封邮件的信头（发件人 / 主题 / 日期） */
export async function fetchInbox(limit: number): Promise<string> {
  const cfg = await loadMailConfig();
  if (cfg.address.length === 0 || cfg.auth.length === 0 || cfg.imapHost.length === 0) {
    return '还没配置邮箱（我的 → 邮件：地址、授权码、IMAP 服务器）';
  }
  const n = limit < 1 ? 5 : (limit > 30 ? 30 : limit);
  const client = new ImapClient();
  try {
    await client.connect(cfg.imapHost, cfg.imapPort);
    const greet = await client.greeting();
    if (!greet.includes('* OK')) {
      return `连接被拒：${greet.slice(0, 100)}`;
    }
    const login = await client.exec(`LOGIN "${cfg.address}" "${cfg.auth}"`);
    if (!/ a\d+ OK/.test(login) && !login.includes('OK')) {
      return `登录失败：${login.slice(0, 120)}（授权码，不是登录密码）`;
    }
    const select = await client.exec('SELECT "INBOX"');
    const existsMatch = /(\d+) EXISTS/.exec(select);
    const total = existsMatch !== null ? parseInt(existsMatch[1], 10) : 0;
    if (total === 0) {
      client.close();
      return '收件箱是空的';
    }
    const from = Math.max(1, total - n + 1);
    const fetch = await client.exec(
      `FETCH ${from}:${total} (BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])`);
    const headers = parseHeaders(fetch, from);
    client.close();
    if (headers.length === 0) {
      return '读到了响应但没解析出邮件（可能服务器格式不同）';
    }
    const lines: string[] = [];
    for (const h of headers) {
      lines.push(`#${h.index} ${h.date} | ${decodeMime(h.from)} | ${decodeMime(h.subject)}`);
    }
    return lines.join('\n');
  } catch (err) {
    client.close();
    return `收信出错：${err}`;
  }
}

function parseHeaders(raw: string, firstIndex: number): MailHeader[] {
  const out: MailHeader[] = [];
  let index = firstIndex;
  let from = '';
  let subject = '';
  let date = '';
  const lines = raw.split('\r\n');
  for (const line of lines) {
    if (line.startsWith('* ') && line.includes('FETCH')) {
      if (from.length > 0 || subject.length > 0) {
        const h = new MailHeader();
        h.index = index;
        h.from = from;
        h.subject = subject;
        h.date = date;
        out.push(h);
        index += 1;
      }
      from = '';
      subject = '';
      date = '';
      continue;
    }
    if (line.startsWith('From:')) {
      from = line.substring(5).trim();
    } else if (line.startsWith('Subject:')) {
      subject = line.substring(8).trim();
    } else if (line.startsWith('Date:')) {
      date = line.substring(5).trim();
    }
  }
  if (from.length > 0 || subject.length > 0) {
    const h = new MailHeader();
    h.index = index;
    h.from = from;
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
    resp = await client.cmd(payload);
    if (!expectCode(resp, '250')) {
      return `发送失败：${resp.slice(0, 120)}`;
    }
    await client.cmd('QUIT');
    return `已发送给 ${to.trim()}`;
  } catch (err) {
    return `发信出错：${err}`;
  } finally {
    client.close();
  }
}
