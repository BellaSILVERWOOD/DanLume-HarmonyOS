/*
 * 网络层：账号服务器 + 公告 + AI + 使用上报。
 *
 * 契约照 Rust 版（`account.rs` / `notify.rs` / `usage.rs` / `ai.rs`），别自己发明字段：
 *   POST /api/v1/register            {username,email,password,device_fingerprint,...}
 *   POST /api/v1/login               {username_or_email,password,device_fingerprint,...} -> {token,refresh_token,account,...}
 *   POST /api/v1/refresh             {refresh_token}
 *   GET  /api/v1/me                  Bearer
 *   GET  /api/v1/announcements?since=<id>&limit=200
 *   POST /api/v1/usage               Bearer，{day,used_seconds,requests,device,version}
 *   AI   POST {ai_base_url}/chat/completions   Bearer <ai_api_key>，OpenAI 兼容
 *
 * 说明：鸿蒙这边**没有做流式**，AI 是「整段拿到再渲染」；桌面版是 SSE 流式。
 */
import http from '@ohos.net.http';
import { fileIo as fs } from '@kit.CoreFileKit';
import zlib from '@ohos.zlib';
import deviceInfo from '@ohos.deviceInfo';
import common from '@ohos.app.ability.common';
import { Db, ChatMessageRow, MemoryRow } from './Db';
import { enabledToolSpecs, PHONE_TOOL_NAMES, TOOL_LABELS } from './AiTools';
import { sendMail, fetchInbox } from './Mail';

export interface LoginResult {
  token: string;
  refresh_token: string;
  username: string;
  role: string;
}

/**
 * 一组 AI 接口配置（OpenAI 兼容）。用户可以存多组，聊天页顶部切换。
 * 存在 settings 的 `ai_profiles`（JSON 数组），当前选中的名字存在 `ai_active`。
 */
export class AiProfile {
  name: string = '';
  base: string = '';
  model: string = '';
  key: string = '';

  constructor(name: string, base: string, model: string, key: string) {
    this.name = name;
    this.base = base;
    this.model = model;
    this.key = key;
  }
}

/** 导出给 Index.ets 用；不导出的话 ArkTS 会说找不到 */
export interface ApiProfileBox {
  profiles: AiProfile[];
  active: string;
}

/** 请求体都要显式声明（ArkTS 的 arkts-no-untyped-obj-literals / no-obj-literals-as-types） */
interface LoginPayload {
  username_or_email: string;
  password: string;
  device_fingerprint: string;
  device_name: string;
  platform: string;
}

interface UsagePayload {
  day: string;
  used_seconds: number;
  requests: number;
  device: string;
  username: string;
  version: string;
}

interface ChatMessage {
  role: string;
  content: string;
}

interface ChatPayload {
  model: string;
  messages: ChatMessage[];
  temperature: number;
}

/** 文献检索结果（arXiv Atom 条目） */
export interface PaperHit {
  title: string;
  authors: string;
  year: string;
  url: string;
  summary: string;
}

const DEFAULT_SERVER: string = 'https://43.108.99.38.sslip.io';
const DEFAULT_BASE_URL: string = 'https://api.deepseek.com/v1';
const DEFAULT_MODEL: string = 'deepseek-chat';

/** 人设与桌面版 `prompts.rs` 的 PERSONA 保持一致 */
export const PERSONA: string = '你是梅子，DanLume 里的写作与学习助手。' +
  '回答用简体中文，简洁直接，先给结论再给要点；不确定的地方要说明不确定，不要编造。';

/** 把对话整理成记忆库条目用的一次性提示词（memory_organize_* 工具） */
const MEMORY_PROMPT: string = '把对话整理成可长期记住的要点，输出 JSON 数组，每项 {title, content, folder}，' +
  'title 不超过 20 字且要概括，folder 形如 学业/高数 或 生活/偏好，最多 8 条，不要输出 JSON 以外的东西。';

interface HttpResult {
  code: number;
  body: string;
}

async function request(
  method: http.RequestMethod,
  url: string,
  body: string | null,
  token: string | null,
): Promise<HttpResult> {
  const client = http.createHttp();
  try {
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (token !== null && token.length > 0) {
      headers['Authorization'] = `Bearer ${token}`;
    }
    const response = await client.request(url, {
      method: method,
      header: headers,
      extraData: body === null ? undefined : body,
      connectTimeout: 15000,
      readTimeout: 60000,
    });
    return { code: response.responseCode as number, body: `${response.result}` };
  } finally {
    client.destroy();
  }
}

export class Api {
  static async serverUrl(): Promise<string> {
    const value = await Db.getSetting('server_url', DEFAULT_SERVER);
    return value.length > 0 ? value : DEFAULT_SERVER;
  }

  /** 设备指纹：桌面版是随机串；这里用「设备信息摘要 + 首次生成的随机串」落到设置里 */
  static async fingerprint(): Promise<string> {
    let value = await Db.getSetting('device_fingerprint', '');
    if (value.length === 0) {
      value = `harmony-${Date.now()}-${Math.floor(Math.random() * 100000)}`;
      await Db.setSetting('device_fingerprint', value);
    }
    return value;
  }

  static async token(): Promise<string> {
    return await Db.getSetting('server_token', '');
  }

  static async login(username: string, password: string): Promise<LoginResult> {
    const base = await Api.serverUrl();
    const payload: LoginPayload = {
      username_or_email: username,
      password: password,
      device_fingerprint: await Api.fingerprint(),
      device_name: 'HarmonyOS 手机',
      platform: 'harmony',
    };
    const result = await request(
      http.RequestMethod.POST, `${base}/api/v1/login`, JSON.stringify(payload), null);
    const data = JSON.parse(result.body) as Record<string, Object>;
    if (result.code !== 200) {
      throw new Error(`${data['error'] ?? '登录失败'}（${result.code}）`);
    }
    const account = data['account'] as Record<string, Object> | undefined;
    const login: LoginResult = {
      token: `${data['token'] ?? ''}`,
      refresh_token: `${data['refresh_token'] ?? ''}`,
      username: `${account?.['username'] ?? username}`,
      role: `${account?.['role'] ?? 'user'}`,
    };
    await Db.setSetting('server_token', login.token);
    await Db.setSetting('server_refresh_token', login.refresh_token);
    await Db.setSetting('server_username', login.username);
    await Db.setSetting('server_role', login.role);
    return login;
  }

  static async logout(): Promise<void> {
    await Db.setSetting('server_token', '');
    await Db.setSetting('server_refresh_token', '');
    await Db.setSetting('server_username', '');
  }

  /** 公告：公开接口，不需要令牌 */
  static async announcements(since: number): Promise<Object[]> {
    const base = await Api.serverUrl();
    const result = await request(
      http.RequestMethod.GET, `${base}/api/v1/announcements?since=${since}&limit=200`, null, null);
    if (result.code !== 200) {
      return [];
    }
    const data = JSON.parse(result.body) as Record<string, Object>;
    const items = data['items'];
    return Array.isArray(items) ? items as Object[] : [];
  }

  /** 使用上报（J2-16）：只报时长和请求数，判罚在服务器侧 */
  static async reportUsage(usedSeconds: number, requests: number): Promise<string> {
    const token = await Api.token();
    if (token.length === 0) {
      return 'idle'; // 没登录就不报，跟桌面版一致
    }
    const base = await Api.serverUrl();
    const payload: UsagePayload = {
      day: Db.today(),
      used_seconds: usedSeconds,
      requests: requests,
      device: await Api.fingerprint(),
      username: await Db.getSetting('server_username', ''),
      version: '1.0.0',
    };
    const result = await request(
      http.RequestMethod.POST, `${base}/api/v1/usage`, JSON.stringify(payload), token);
    if (result.code !== 200) {
      return 'error';
    }
    const data = JSON.parse(result.body) as Record<string, Object>;
    return `${data['action'] ?? 'ok'}`;
  }

  // ---------------------------------------------------------------- AI
  /** 读出所有接口配置；没有就往下兼容旧的单条设置（ai_api_key / ai_base_url / ai_model） */
  static async aiProfiles(): Promise<AiProfile[]> {
    const out: AiProfile[] = [];
    const raw = await Db.getSetting('ai_profiles', '');
    if (raw.length > 0) {
      try {
        const arr = JSON.parse(raw) as Object[];
        if (Array.isArray(arr)) {
          for (const item of arr) {
            const o = item as Record<string, Object>;
            out.push(new AiProfile(
              `${o['name'] ?? ''}`,
              `${o['base'] ?? ''}`,
              `${o['model'] ?? ''}`,
              `${o['key'] ?? ''}`));
          }
        }
      } catch (e) {
        // 解析失败就当没有，下面走旧配置
      }
    }
    if (out.length === 0) {
      const key = await Db.getSetting('ai_api_key', '');
      const base = await Db.getSetting('ai_base_url', DEFAULT_BASE_URL);
      const model = await Db.getSetting('ai_model', DEFAULT_MODEL);
      if (key.length > 0) {
        out.push(new AiProfile(model, base, model, key));
      }
    }
    return out;
  }

  static async saveAiProfiles(list: AiProfile[]): Promise<void> {
    const arr: Object[] = [];
    for (const p of list) {
      const o: Record<string, string> = {
        'name': p.name,
        'base': p.base,
        'model': p.model,
        'key': p.key,
      };
      arr.push(o);
    }
    await Db.setSetting('ai_profiles', JSON.stringify(arr));
  }

  static async activeProfile(): Promise<AiProfile | null> {
    const list = await Api.aiProfiles();
    if (list.length === 0) {
      return null;
    }
    const name = await Db.getSetting('ai_active', '');
    for (const p of list) {
      if (p.name === name) {
        return p;
      }
    }
    return list[0];
  }

  static async setActiveProfile(name: string): Promise<void> {
    await Db.setSetting('ai_active', name);
    await Db.setSetting('ai_model', name); // 兼容还没升级的旧路径
  }

  static async chat(userText: string, history: string[]): Promise<string> {
    const profile = await Api.activeProfile();
    if (profile === null || profile.key.trim().length === 0) {
      throw new Error('还没配置 AI 接口（我的 → AI 接口）');
    }
    await Db.bumpCounter('usage_ai_calls');
    const base = profile.base.trim().length > 0 ? profile.base.trim() : DEFAULT_BASE_URL;
    const model = profile.model.trim().length > 0 ? profile.model.trim() : DEFAULT_MODEL;
    const messages: Object[] = [];
    messages.push(Api.msg('system', PERSONA));
    for (const line of history) {
      messages.push(Api.msg('user', line));
    }
    messages.push(Api.msg('user', userText));

    // 设置里开了「AI 工具」才会带 tools 过去，否则跟以前一样纯聊天
    const tools = await enabledToolSpecs();
    if (tools.length > 0) {
      messages.push(Api.msg('system',
        '本次会话你可以调用工具直接读写这台手机上的日程和本地设置。涉及日程的请求：先 schedule_list 查清楚现状，需要时再 schedule_add / schedule_update / schedule_delete；改完用一句话说明改了什么。时间一律用 24 小时制 HH:MM，日期用 YYYY-MM-DD。'));
    }
    for (let round = 0; round < 4; round += 1) {
      const body: Record<string, Object> = {
        'model': model,
        'messages': messages,
        'temperature': 0.7,
      };
      if (tools.length > 0) {
        body['tools'] = tools;
        body['tool_choice'] = 'auto';
      }
      const result = await request(
        http.RequestMethod.POST, `${base}/chat/completions`, JSON.stringify(body), profile.key);
      if (result.code !== 200) {
        throw new Error(`${profile.name || model} 返回 ${result.code}`);
      }
      const data = JSON.parse(result.body) as Record<string, Object>;
      const choices = data['choices'] as Object[] | undefined;
      if (!choices || choices.length === 0) {
        return '（模型没有返回内容）';
      }
      const message = (choices[0] as Record<string, Object>)['message'] as Record<string, Object>;
      const content = `${message['content'] ?? ''}`;
      const calls = message['tool_calls'] as Object[] | undefined;
      if (!calls || calls.length === 0) {
        return content;
      }
      // 有工具调用：把模型的这条消息原样塞回去，再逐条执行 + 回填结果
      messages.push(message);
      for (const raw of calls) {
        const call = raw as Record<string, Object>;
        const callId = `${call['id'] ?? ''}`;
        const fn = call['function'] as Record<string, Object>;
        const name = `${fn['name'] ?? ''}`;
        const args = `${fn['arguments'] ?? '{}'}`;
        let out = '';
        try {
          out = await Api.runTool(name, args);
        } catch (e) {
          out = `工具执行失败：${e}`;
        }
        console.info(`[ai] tool ${name}(${args}) -> ${out}`);
        Api.pushToolResult(messages, callId, out);
      }
    }
    return '（工具调用轮次太多，先停下了）';
  }

  private static msg(role: string, content: string): Object {
    const m: Record<string, string> = { 'role': role, 'content': content };
    return m;
  }

  private static pushToolResult(list: Object[], callId: string, content: string): void {
    const m: Record<string, string> = {
      'role': 'tool',
      'tool_call_id': callId,
      'content': content,
    };
    list.push(m);
  }

  /** 本地执行模型要调的工具（日程 / 时间 / arXiv / 设置） */
  private static async runTool(name: string, argsJson: string): Promise<string> {
    let args: Record<string, Object> = {};
    try {
      args = JSON.parse(argsJson) as Record<string, Object>;
    } catch (e) {
      args = {};
    }
    const textOf = (key: string): string => `${args[key] ?? ''}`.trim();
    const numOf = (key: string, fallback: number): number => {
      const n = parseInt(`${args[key] ?? ''}`, 10);
      return isNaN(n) ? fallback : n;
    };

    if (name === 'schedule_list') {
      const date = textOf('date').length > 0 ? textOf('date') : Db.today();
      const rows = await Db.eventsOn(date);
      const out: Object[] = [];
      for (const row of rows) {
        const o: Record<string, Object> = {
          'id': row.id,
          'title': row.title,
          'date': row.date,
          'start_time': row.start_time,
          'end_time': row.end_time,
          'done': row.done,
        };
        out.push(o);
      }
      return JSON.stringify(out);
    }
    if (name === 'schedule_add') {
      const title = textOf('title');
      const date = textOf('date');
      if (title.length === 0 || date.length === 0) {
        return '缺 title 或 date';
      }
      const id = await Db.addEvent({
        title: title,
        date: date,
        start_time: textOf('start_time'),
        end_time: textOf('end_time'),
      });
      return `已新建日程，id=${id}`;
    }
    if (name === 'schedule_update') {
      const id = numOf('id', 0);
      const row = await Db.eventById(id);
      if (row === null) {
        return `没有 id=${id} 的日程`;
      }
      const title = textOf('title').length > 0 ? textOf('title') : row.title;
      const date = textOf('date').length > 0 ? textOf('date') : row.date;
      const start = textOf('start_time').length > 0 ? textOf('start_time') : row.start_time;
      const end = textOf('end_time').length > 0 ? textOf('end_time') : row.end_time;
      const doneText = textOf('done');
      const done = doneText.length > 0 ? (doneText === 'true' || doneText === '1') : row.done;
      await Db.updateEventFields(id, title, date, start, end, done, row.description);
      return `已更新 id=${id}`;
    }
    if (name === 'schedule_delete') {
      const id = numOf('id', 0);
      const row = await Db.eventById(id);
      if (row === null) {
        return `没有 id=${id} 的日程`;
      }
      await Db.deleteEvent(id);
      return `已删除 id=${id}`;
    }
    if (name === 'time_now') {
      return Db.stamp();
    }
    if (name === 'arxiv_search') {
      const query = textOf('query');
      if (query.length === 0) {
        return '缺 query';
      }
      const limit = numOf('limit', 5);
      const hits = await Api.arxivSearch(query, limit < 1 ? 1 : (limit > 10 ? 10 : limit));
      const out: Object[] = [];
      for (const hit of hits) {
        const o: Record<string, string> = {
          'title': hit.title,
          'authors': hit.authors,
          'year': hit.year,
          'url': hit.url,
          'summary': hit.summary,
        };
        out.push(o);
      }
      return JSON.stringify(out);
    }
    if (name === 'setting_get') {
      const key = textOf('key');
      if (key.length === 0) {
        return '缺 key';
      }
      const value = await Db.getSetting(key, '');
      return value.length > 0 ? value : '（空）';
    }
    if (name === 'setting_set') {
      const key = textOf('key');
      const value = textOf('value');
      if (!key.startsWith('ai_') && !key.startsWith('server_')) {
        return '只能写 ai_ / server_ 开头的设置项';
      }
      await Db.setSetting(key, value);
      return `已写入 ${key}`;
    }
    if (name === 'countdown_add') {
      const title = textOf('title');
      const date = textOf('date');
      if (title.length === 0 || date.length === 0) {
        return '缺 title 或 date';
      }
      const id = await Db.countdownAdd(title, date);
      return `已加倒计时 id=${id}：${date} ${title}`;
    }
    if (name === 'countdown_list') {
      const items = await Db.countdownList(20);
      return items.length > 0 ? items.join('\n') : '还没有倒计时';
    }
    if (name === 'pomodoro_start') {
      return `收到：${numOf('minutes', 25)} 分钟番茄钟。手机端后台计时还没做，先按这个时长自己开始。`;
    }
    if (name === 'memo_search') {
      const items = await Db.memoSearch(textOf('query'), numOf('limit', 5));
      return items.length > 0 ? items.join('\n---\n') : '没有匹配的备忘';
    }
    if (name === 'memo_append') {
      const text = textOf('text');
      if (text.length === 0) {
        return '缺 text';
      }
      const id = await Db.memoAdd(text);
      return `已记录备忘 id=${id}`;
    }
    if (name === 'memory_add') {
      const title = textOf('title');
      const content = textOf('content');
      if (title.length === 0 || content.length === 0) {
        return '缺 title 或 content';
      }
      const id = await Db.memoryAdd(title, content, textOf('folder'));
      return `已记住 id=${id}：${title}`;
    }
    if (name === 'memory_search') {
      const query = textOf('query');
      const limit = numOf('limit', 5);
      const rows: MemoryRow[] = await Db.memorySearch(
        query, limit < 1 ? 5 : (limit > 20 ? 20 : limit));
      if (rows.length === 0) {
        return '没有匹配的记忆';
      }
      const out: string[] = [];
      for (const row of rows) {
        const text = row.content.length > 80 ? `${row.content.substring(0, 80)}…` : row.content;
        out.push(`${row.id} | ${row.title} | ${row.folder} | ${text}`);
      }
      return out.join('\n');
    }
    if (name === 'memory_delete') {
      const id = numOf('id', 0);
      if (id <= 0) {
        return '缺 id（先用 memory_search 查）';
      }
      await Db.memoryDelete(id);
      return `已删除 id=${id}`;
    }
    if (name === 'memory_organize_session') {
      // 手机端没有「当前会话」的全局变量，取最近更新的那个会话
      const sessions = await Db.chatSessionList(1);
      if (sessions.length === 0) {
        return '没有可整理的对话';
      }
      return await Api.organizeMemories(sessions[0].id);
    }
    if (name === 'memory_organize_today') {
      return await Api.organizeMemories(0);
    }
    if (name === 'flashcards_create') {
      const raw = `${args['cards'] ?? '[]'}`;
      let arr: Object[] = [];
      try {
        arr = JSON.parse(raw) as Object[];
      } catch (e) {
        arr = [];
      }
      if (!Array.isArray(arr) || arr.length === 0) {
        return 'cards 解析失败，要给 [{"question":"…","answer":"…"}]';
      }
      let n = 0;
      for (const item of arr) {
        const o = item as Record<string, Object>;
        const q = `${o['question'] ?? ''}`.trim();
        const a = `${o['answer'] ?? ''}`.trim();
        if (q.length === 0) {
          continue;
        }
        await Db.flashcardAdd(q, a, `${o['tag'] ?? ''}`);
        n += 1;
      }
      return `已生成 ${n} 张闪卡`;
    }
    if (name === 'usage_stats') {
      const events = await Db.countFast('SELECT COUNT(*) FROM events');
      const memos = await Db.countFast('SELECT COUNT(*) FROM memos');
      const cards = await Db.countFast('SELECT COUNT(*) FROM flashcards');
      const chats = await Db.getSetting('usage_ai_calls', '0');
      return `日程 ${events} 条，备忘 ${memos} 条，闪卡 ${cards} 张，AI 调用 ${chats} 次`;
    }
    if (name === 'sys_info') {
      return `型号 ${deviceInfo.productModel}，系统 ${deviceInfo.osFullName}，DanLume 1.0.0`;
    }
    if (name === 'fs_read') {
      const p = Api.resolvePath(textOf('path'));
      const text = fs.readTextSync(p);
      return text.length > 4000 ? `${text.substring(0, 4000)}…（截断）` : text;
    }
    if (name === 'fs_discard') {
      const p = Api.resolvePath(textOf('path'));
      fs.unlinkSync(p);
      return `已删除 ${p}`;
    }
    if (name === 'zip_extract') {
      const src = Api.resolvePath(textOf('src'));
      const dst = Api.resolvePath(textOf('dst'));
      await zlib.decompressFile(src, dst);
      return `已解压到 ${dst}`;
    }
    if (name === 'library_open') {
      const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
      if (ctx === undefined) {
        return '拿不到应用上下文';
      }
      await ctx.startAbility({
        action: 'ohos.want.action.viewData',
        uri: 'https://library.fudan.edu.cn',
      });
      return '已打开图书馆网站';
    }
    if (name === 'web_fetch') {
      const url = textOf('url');
      if (!url.startsWith('http')) {
        return 'url 必须是 http/https';
      }
      const html = await Api.httpText(url);
      const text = Api.stripHtml(html);
      return text.length > 4000 ? `${text.substring(0, 4000)}…（截断）` : text;
    }
    if (name === 'web_search') {
      return await Api.webSearch(textOf('query'), numOf('limit', 5));
    }
    if (name === 'video_search') {
      return await Api.webSearch(`site:bilibili.com ${textOf('query')}`, 5);
    }
    if (name === 'crossref_search') {
      return await Api.crossrefSearch(textOf('query'), numOf('limit', 5));
    }
    if (name === 'semantic_scholar_search') {
      return await Api.s2Search(textOf('query'), numOf('limit', 5));
    }
    if (name === 'doi_lookup') {
      return await Api.doiLookup(textOf('doi'));
    }
    if (name === 'literature_search') {
      const query = textOf('query');
      const limit = numOf('limit', 8);
      const arxiv = await Api.arxivSearch(query, limit);
      const crossref = await Api.crossrefLines(query, limit);
      const out: string[] = [];
      for (const hit of arxiv) {
        out.push(`[arXiv] ${hit.title} | ${hit.authors} | ${hit.year} | ${hit.url}`);
      }
      for (const line of crossref) {
        out.push(`[Crossref] ${line}`);
      }
      return out.slice(0, limit).join('\n');
    }
    if (name === 'citation_format') {
      return Api.citation(textOf('title'), textOf('authors'), textOf('year'),
        textOf('journal'), textOf('doi'), textOf('style'));
    }
    if (name === 'endnote_export') {
      const title = textOf('title');
      const authors = textOf('authors');
      const year = textOf('year');
      const journal = textOf('journal');
      const doi = textOf('doi');
      const lines: string[] = [];
      lines.push('%0 Journal Article');
      for (const a of authors.split(',')) {
        if (a.trim().length > 0) {
          lines.push(`%A ${a.trim()}`);
        }
      }
      lines.push(`%T ${title}`);
      lines.push(`%D ${year}`);
      if (journal.length > 0) {
        lines.push(`%J ${journal}`);
      }
      if (doi.length > 0) {
        lines.push(`%R ${doi}`);
      }
      const name = `ref_${Date.now()}.enw`;
      const path = Api.resolvePath(name);
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
      fs.writeSync(file.fd, lines.join('\n'));
      fs.closeSync(file);
      return `已导出 ${path}`;
    }
    if (name === 'pdf_download') {
      const url = textOf('url');
      if (!url.startsWith('http')) {
        return 'url 必须是 http/https';
      }
      const name = textOf('filename').length > 0
        ? textOf('filename') : `paper_${Date.now()}.pdf`;
      const path = Api.resolvePath(name);
      const ok = await Api.downloadTo(url, path);
      return ok ? `已下载到 ${path}` : '下载失败';
    }
    if (name === 'tool_help') {
      const out: string[] = [];
      for (let i = 0; i < PHONE_TOOL_NAMES.length; i += 1) {
        out.push(`${PHONE_TOOL_NAMES[i]}：${TOOL_LABELS[i]}`);
      }
      return out.join('\n');
    }
    if (name === 'mail_send') {
      return await sendMail(textOf('to'), textOf('subject'), `${args['body'] ?? ''}`);
    }
    if (name === 'mail_inbox') {
      return await fetchInbox(numOf('limit', 5));
    }
    if (name === 'elearning_courses' || name === 'timetable_fetch' ||
      name === 'course_resource_search' || name === 'resource_push') {
      return '手机端还没接 eLearning / 教务登录，先在电脑端用这个功能';
    }
    return `手机端没有工具 ${name}`;
  }

  /** 把对话整理成长期记忆；sessionId <= 0 表示今天所有会话。只发一次不带 tools 的请求，避免递归调工具 */
  /** 每晚 18:00 的自动整理用（Index 的 aboutToAppear 里触发一次） */
  static async organizeToday(): Promise<string> {
    const rows = await Db.chatMessagesSince(`${Db.today()} 00:00:00`);
    if (rows.length === 0) {
      return '今天还没有对话';
    }
    return await Api.organizeMemories(0);
  }

  private static async organizeMemories(sessionId: number): Promise<string> {
    try {
      const profile = await Api.activeProfile();
      if (profile === null || profile.key.trim().length === 0) {
        return '整理失败：还没配置 AI 接口（我的 → AI 接口）';
      }
      let rows: ChatMessageRow[] = [];
      if (sessionId > 0) {
        rows = await Db.chatMessages(sessionId);
      } else {
        rows = await Db.chatMessagesSince(`${Db.today()} 00:00:00`);
      }
      const lines: string[] = [];
      for (const row of rows) {
        const who = row.role === 'user' ? '用户' : '梅子';
        const text = row.text.trim();
        if (text.length > 0) {
          lines.push(`${who}：${text}`);
        }
      }
      if (lines.length === 0) {
        return '没有可整理的对话';
      }
      let transcript = lines.join('\n');
      if (transcript.length > 6000) {
        // 太长就留最近的部分，整段截到 6000 字
        transcript = transcript.substring(transcript.length - 6000);
      }

      const base = profile.base.trim().length > 0 ? profile.base.trim() : DEFAULT_BASE_URL;
      const model = profile.model.trim().length > 0 ? profile.model.trim() : DEFAULT_MODEL;
      const payload: ChatPayload = {
        model: model,
        messages: [
          { role: 'system', content: MEMORY_PROMPT },
          { role: 'user', content: transcript },
        ],
        temperature: 0.2,
      };
      const result = await request(
        http.RequestMethod.POST, `${base}/chat/completions`, JSON.stringify(payload), profile.key);
      if (result.code !== 200) {
        return `整理失败：${profile.name || model} 返回 ${result.code}`;
      }
      const data = JSON.parse(result.body) as Record<string, Object>;
      const choices = data['choices'] as Object[] | undefined;
      if (choices === undefined || choices.length === 0) {
        return '整理失败：模型没有返回内容';
      }
      const message = (choices[0] as Record<string, Object>)['message'] as Record<string, Object>;
      let content = `${message['content'] ?? ''}`.trim();
      // 允许外面包 ```json 代码块，也容忍前后有说明文字
      const fence = /```(?:json)?([\s\S]*?)```/.exec(content);
      if (fence !== null) {
        content = fence[1].trim();
      }
      const start = content.indexOf('[');
      const end = content.lastIndexOf(']');
      if (start >= 0 && end > start) {
        content = content.substring(start, end + 1);
      }
      let arr: Object[] = [];
      try {
        arr = JSON.parse(content) as Object[];
      } catch (e) {
        return '整理失败：模型返回的不是 JSON 数组';
      }
      if (!Array.isArray(arr) || arr.length === 0) {
        return '整理出 0 条记忆';
      }
      let n = 0;
      for (const item of arr) {
        if (n >= 8) {
          break;
        }
        const o = item as Record<string, Object>;
        const title = `${o['title'] ?? ''}`.trim();
        const body = `${o['content'] ?? ''}`.trim();
        const folder = `${o['folder'] ?? ''}`.trim();
        if (title.length === 0 || body.length === 0) {
          continue;
        }
        await Db.memoryAdd(title.length > 20 ? title.substring(0, 20) : title, body, folder);
        n += 1;
      }
      return `整理出 ${n} 条记忆`;
    } catch (e) {
      return `整理失败：${e instanceof Error ? e.message : e}`;
    }
  }

  /** 相对路径落到应用 filesDir 下 */
  private static resolvePath(p: string): string {
    if (p.startsWith('/')) {
      return p;
    }
    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    const base = ctx !== undefined ? ctx.filesDir : '';
    return `${base}/${p}`;
  }

  private static stripHtml(html: string): string {
    let t = html.replace(/<script[\s\S]*?<\/script>/gi, ' ');
    t = t.replace(/<style[\s\S]*?<\/style>/gi, ' ');
    t = t.replace(/<[^>]+>/g, ' ');
    t = t.replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'");
    return t.replace(/\s+/g, ' ').trim();
  }

  private static async httpText(url: string): Promise<string> {
    const client = http.createHttp();
    try {
      const res = await client.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        header: { 'User-Agent': 'DanLume/1.0 (HarmonyOS)' },
        connectTimeout: 15000,
        readTimeout: 20000,
      });
      return `${res.result ?? ''}`;
    } finally {
      client.destroy();
    }
  }

  /** DuckDuckGo 的 html 版；抓不到就返回提示 */
  private static async webSearch(query: string, limit: number): Promise<string> {
    if (query.trim().length === 0) {
      return '缺 query';
    }
    try {
      const html = await Api.httpText(`https://html.duckduckgo.com/html/?q=${encodeURIComponent(query)}`);
      const out: string[] = [];
      const re = /result__a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/g;
      let m = re.exec(html);
      while (m !== null && out.length < limit) {
        const url = m[1];
        const title = Api.stripHtml(m[2]);
        if (title.length > 0) {
          out.push(`${title} | ${url}`);
        }
        m = re.exec(html);
      }
      return out.length > 0 ? out.join('\n') : '没搜到结果（搜索源可能被网络挡住）';
    } catch (e) {
      return `搜索失败：${e}`;
    }
  }

  private static async crossrefLines(query: string, limit: number): Promise<string[]> {
    try {
      const url = `https://api.crossref.org/works?query=${encodeURIComponent(query)}&rows=${limit}`;
      const body = await Api.httpText(url);
      const data = JSON.parse(body) as Record<string, Object>;
      const message = data['message'] as Record<string, Object>;
      const items = message['items'] as Object[];
      const out: string[] = [];
      for (const item of items) {
        out.push(Api.crossrefLine(item as Record<string, Object>));
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  private static crossrefLine(o: Record<string, Object>): string {
    const titles = o['title'] as string[] | undefined;
    const title = titles !== undefined && titles.length > 0 ? titles[0] : '';
    const names: string[] = [];
    const authors = o['author'] as Object[] | undefined;
    if (authors !== undefined) {
      for (const a of authors) {
        const ao = a as Record<string, Object>;
        const name = `${ao['family'] ?? ''} ${ao['given'] ?? ''}`.trim();
        if (name.length > 0) {
          names.push(name);
        }
      }
    }
    const issued = JSON.stringify(o['issued'] ?? '');
    const y = /\d{4}/.exec(issued);
    const year = y !== null ? y[0] : '';
    return `${title} | ${names.join(', ')} | ${year} | DOI:${o['DOI'] ?? ''} | ${o['URL'] ?? ''}`;
  }

  private static async crossrefSearch(query: string, limit: number): Promise<string> {
    if (query.trim().length === 0) {
      return '缺 query';
    }
    const lines = await Api.crossrefLines(query, limit);
    return lines.length > 0 ? lines.join('\n') : '没搜到结果';
  }

  private static async s2Search(query: string, limit: number): Promise<string> {
    if (query.trim().length === 0) {
      return '缺 query';
    }
    try {
      const url = `https://api.semanticscholar.org/graph/v1/paper/search?query=${encodeURIComponent(query)}` +
        `&limit=${limit}&fields=title,authors,year,externalIds,url`;
      const body = await Api.httpText(url);
      const data = JSON.parse(body) as Record<string, Object>;
      const arr = data['data'] as Object[] | undefined;
      if (arr === undefined || arr.length === 0) {
        return '没搜到结果';
      }
      const out: string[] = [];
      for (const item of arr) {
        const o = item as Record<string, Object>;
        const names: string[] = [];
        const authors = o['authors'] as Object[] | undefined;
        if (authors !== undefined) {
          for (const a of authors) {
            names.push(`${(a as Record<string, Object>)['name'] ?? ''}`);
          }
        }
        out.push(`${o['title'] ?? ''} | ${names.join(', ')} | ${o['year'] ?? ''} | ${o['url'] ?? ''}`);
      }
      return out.join('\n');
    } catch (e) {
      return `S2 检索失败：${e}`;
    }
  }

  private static async doiLookup(doi: string): Promise<string> {
    if (doi.trim().length === 0) {
      return '缺 doi';
    }
    try {
      const body = await Api.httpText(`https://api.crossref.org/works/${encodeURIComponent(doi)}`);
      const data = JSON.parse(body) as Record<string, Object>;
      const message = data['message'] as Record<string, Object>;
      return Api.crossrefLine(message);
    } catch (e) {
      return `DOI 查询失败：${e}`;
    }
  }

  /** GB/T 7714 或 APA */
  private static citation(title: string, authors: string, year: string,
    journal: string, doi: string, style: string): string {
    const names = authors.split(',').map((s: string) => s.trim()).filter((s: string) => s.length > 0);
    const apaNames = names.join(', ');
    const gbtNames = names.join(', ');
    if (style === 'apa') {
      const tail = journal.length > 0 ? ` ${journal}.` : '';
      const doiPart = doi.length > 0 ? ` https://doi.org/${doi}` : '';
      return `${apaNames} (${year}). ${title}.${tail}${doiPart}`;
    }
    const j = journal.length > 0 ? `[J]. ${journal}, ${year}.` : `[J]. ${year}.`;
    const doiPart = doi.length > 0 ? ` DOI:${doi}.` : '';
    return `${gbtNames}. ${title}${j}${doiPart}`;
  }

  private static async downloadTo(url: string, path: string): Promise<boolean> {
    const client = http.createHttp();
    try {
      const res = await client.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 20000,
        readTimeout: 60000,
      });
      if (res.responseCode !== 200) {
        return false;
      }
      const buf = res.result as ArrayBuffer;
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, buf);
      fs.closeSync(file);
      return true;
    } catch (e) {
      return false;
    } finally {
      client.destroy();
    }
  }

  // ---------------------------------------------------------------- 文献（arXiv）
  static async arxivSearch(query: string, limit: number = 8): Promise<PaperHit[]> {
    const text = encodeURIComponent(query.trim());
    const url = `https://export.arxiv.org/api/query?search_query=all:${text}&start=0&max_results=${limit}`;
    const result = await request(http.RequestMethod.GET, url, null, null);
    if (result.code !== 200) {
      return [];
    }
    const hits: PaperHit[] = [];
    const chunks = result.body.split('<entry>');
    for (let i = 1; i < chunks.length; i += 1) {
      const chunk = chunks[i];
      const title = Api.tagText(chunk, 'title');
      if (title.length === 0) {
        continue;
      }
      const link = Api.firstHref(chunk);
      hits.push({
        title: title,
        authors: Api.tagTexts(chunk, 'name').join(', '),
        year: Api.tagText(chunk, 'published').slice(0, 4),
        url: link.replace('/abs/', '/pdf/'),
        summary: Api.tagText(chunk, 'summary'),
      });
    }
    return hits;
  }

  private static tagText(chunk: string, tag: string): string {
    const start = chunk.indexOf(`<${tag}`);
    if (start < 0) {
      return '';
    }
    const headEnd = chunk.indexOf('>', start);
    if (headEnd < 0) {
      return '';
    }
    const close = chunk.indexOf(`</${tag}>`, headEnd);
    if (close < 0) {
      return '';
    }
    return chunk.slice(headEnd + 1, close).replace(/\s+/g, ' ').trim();
  }

  private static tagTexts(chunk: string, tag: string): string[] {
    const out: string[] = [];
    let from = 0;
    while (out.length < 20) {
      const start = chunk.indexOf(`<${tag}`, from);
      if (start < 0) {
        break;
      }
      const headEnd = chunk.indexOf('>', start);
      if (headEnd < 0) {
        break;
      }
      const close = chunk.indexOf(`</${tag}>`, headEnd);
      if (close < 0) {
        break;
      }
      out.push(chunk.slice(headEnd + 1, close).replace(/\s+/g, ' ').trim());
      from = close + tag.length + 3;
    }
    return out;
  }

  private static firstHref(chunk: string): string {
    const at = chunk.indexOf('href="');
    if (at < 0) {
      return '';
    }
    const rest = chunk.slice(at + 6);
    const end = rest.indexOf('"');
    return end < 0 ? '' : rest.slice(0, end);
  }
}
