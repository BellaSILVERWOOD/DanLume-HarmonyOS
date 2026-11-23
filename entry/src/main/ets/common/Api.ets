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
import { Db } from './Db';

export interface LoginResult {
  token: string;
  refresh_token: string;
  username: string;
  role: string;
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

const DEFAULT_SERVER: string = 'https://43.108.99.38.sslip.io';
const DEFAULT_BASE_URL: string = 'https://api.deepseek.com/v1';
const DEFAULT_MODEL: string = 'deepseek-chat';

/** 人设与桌面版 `prompts.rs` 的 PERSONA 保持一致 */
export const PERSONA: string = '你是梅子，DanLume 里的写作与学习助手。' +
  '回答用简体中文，简洁直接，先给结论再给要点；不确定的地方要说明不确定，不要编造。';

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
  static async chat(userText: string, history: string[]): Promise<string> {
    const token = await Db.getSetting('ai_api_key', '');
    if (token.length === 0) {
      throw new Error('还没填 AI Key（我的 → AI 接口）');
    }
    const base = await Db.getSetting('ai_base_url', DEFAULT_BASE_URL);
    const model = await Db.getSetting('ai_model', DEFAULT_MODEL);
    const messages: ChatMessage[] = [{ role: 'system', content: PERSONA }];
    for (const line of history) {
      messages.push({ role: 'user', content: line });
    }
    messages.push({ role: 'user', content: userText });
    const payload: ChatPayload = { model: model, messages: messages, temperature: 0.7 };
    const result = await request(
      http.RequestMethod.POST, `${base}/chat/completions`, JSON.stringify(payload), token);
    if (result.code !== 200) {
      throw new Error(`AI 接口返回 ${result.code}`);
    }
    const data = JSON.parse(result.body) as Record<string, Object>;
    const choices = data['choices'] as Object[] | undefined;
    if (!choices || choices.length === 0) {
      return '（模型没有返回内容）';
    }
    const first = choices[0] as Record<string, Object>;
    const message = first['message'] as Record<string, Object> | undefined;
    return `${message?.['content'] ?? ''}`;
  }
}
