/*
 * 多端同步客户端（鸿蒙）：POST /api/v1/sync
 * 契约见 `_开发文档.md` §13：稳定 uid、UTC ISO 的 updated_at、墓碑 deleted=true、后写胜出。
 * 游标存在 settings 的 `sync_cursor`（服务器回的 server_time）。
 */
import http from '@ohos.net.http';
import { Db } from './Db';
import { Api } from './Api';

export async function syncEvents(): Promise<string> {
  const token = await Api.token();
  if (token.length === 0) {
    return '先登录账号再同步';
  }
  const base = await Api.serverUrl();
  const cursor = await Db.getSetting('sync_cursor', '');
  const items = await Db.syncExport(cursor);
  const body: Record<string, Object> = { 'since': cursor, 'items': items };
  const client = http.createHttp();
  try {
    const res = await client.request(`${base}/api/v1/sync`, {
      method: http.RequestMethod.POST,
      header: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${token}`,
      },
      extraData: JSON.stringify(body),
      connectTimeout: 15000,
      readTimeout: 20000,
    });
    if (res.responseCode !== 200) {
      return `同步失败：HTTP ${res.responseCode}`;
    }
    const data = JSON.parse(`${res.result}`) as Record<string, Object>;
    const serverTime = `${data['server_time'] ?? ''}`;
    const remote = data['items'] as Object[] | undefined;
    let applied = 0;
    if (remote !== undefined) {
      for (const raw of remote) {
        const o = raw as Record<string, Object>;
        if (`${o['kind'] ?? ''}` !== 'event') {
          continue;
        }
        await Db.syncApplyEvent(
          `${o['uid'] ?? ''}`,
          `${o['payload'] ?? '{}'}`,
          `${o['updated_at'] ?? ''}`,
          o['deleted'] === true);
        applied += 1;
      }
    }
    if (serverTime.length > 0) {
      await Db.setSetting('sync_cursor', serverTime);
    }
    return `同步完成：上传 ${items.length} 条，合并 ${applied} 条`;
  } catch (err) {
    return `同步失败：${err}`;
  } finally {
    client.destroy();
  }
}
