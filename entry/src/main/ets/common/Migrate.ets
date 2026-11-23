/*
 * 日程迁移：
 *   1) 从系统日历（CalendarKit）读一段时间的事件，去重后写进本地 lumina.db；
 *   2) 从电脑端导出的 .dlpk（zip 里带 lumina.db）导入，表结构和桌面版一致。
 *
 * 权限：READ_CALENDAR 是 user_grant，第一次调用会弹系统授权框。
 */
import { calendarManager } from '@kit.CalendarKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import zlib from '@ohos.zlib';
import relationalStore from '@ohos.data.relationalStore';
import abilityAccessCtrl, { Permissions } from '@ohos.abilityAccessCtrl';
import common from '@ohos.app.ability.common';
import { Db, EventRow } from './Db';

function pad(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

function dateOf(ms: number): string {
  const d = new Date(ms);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

function timeOf(ms: number): string {
  const d = new Date(ms);
  return `${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/** 读系统日历，导入过去 30 天到未来 180 天的事件 */
export async function importSystemCalendar(context: common.UIAbilityContext): Promise<string> {
  const at = abilityAccessCtrl.createAtManager();
  const wanted: Permissions[] = ['ohos.permission.READ_CALENDAR'];
  const res = await at.requestPermissionsFromUser(context, wanted);
  if (res.authResults.length === 0 || res.authResults[0] !== 0) {
    return '没有日历权限：设置 → 应用和元服务 → DanLume → 权限 → 日历，打开后再试';
  }
  const mgr = calendarManager.getCalendarManager(context);
  const calendars = await mgr.getAllCalendars();
  console.info(`[cal] calendars=${calendars.length}`);
  if (calendars.length === 0) {
    return '系统里还没有任何日历账户';
  }
  const now = Date.now();
  const from = now - 30 * 24 * 3600 * 1000;
  const to = now + 180 * 24 * 3600 * 1000;
  let read = 0;
  let added = 0;
  let failed = 0;
  for (let ci = 0; ci < calendars.length; ci += 1) {
    const cal = calendars[ci];
    let events: calendarManager.Event[] = [];
    try {
      events = await cal.getEvents(calendarManager.EventFilter.filterByTime(from, to));
      console.info(`[cal] calendar#${ci} -> ${events.length} events`);
    } catch (e) {
      failed += 1;
      console.error(`[cal] getEvents failed: ${e}`);
      continue;
    }
    for (const ev of events) {
      const title = `${ev.title ?? ''}`.trim();
      if (title.length === 0) {
        continue;
      }
      read += 1;
      const allDay = ev.isAllDay === true;
      const date = dateOf(ev.startTime);
      const start = allDay ? '' : timeOf(ev.startTime);
      const end = allDay ? '' : timeOf(ev.endTime);
      if (await Db.hasEvent(title, date, start)) {
        continue;
      }
      await Db.addEvent({
        title: title,
        date: date,
        start_time: start,
        end_time: end,
        description: '来自系统日历',
        color: '',
      });
      added += 1;
    }
  }
  console.info(`[cal] read=${read} added=${added} failed=${failed}`);
  if (read === 0) {
    return failed > 0
      ? `读取系统日历失败（${failed} 个日历账户报错），详见 hilog 里 [cal] 开头的日志`
      : '系统日历里没读到日程：确认手机「日历」里确实有事件，并且 DanLume 有日历读取权限';
  }
  return added > 0
    ? `导入 ${added} 条（读了 ${read} 条系统日程，重复的已跳过）`
    : `没有新日程（读了 ${read} 条，都已在 DanLume 里）`;
}

/** 把 DanLume 里某一天的日程写进系统日历（标题重复的跳过） */
export async function exportDayToSystem(context: common.UIAbilityContext, date: string): Promise<string> {
  const at = abilityAccessCtrl.createAtManager();
  const wanted: Permissions[] = ['ohos.permission.WRITE_CALENDAR'];
  const res = await at.requestPermissionsFromUser(context, wanted);
  if (res.authResults.length === 0 || res.authResults[0] !== 0) {
    return '没有日历写入权限：设置 → 应用和元服务 → DanLume → 权限 → 日历，改成允许';
  }
  const rows = await Db.eventsOn(date);
  if (rows.length === 0) {
    return `${date} 没有日程可写`;
  }
  const mgr = calendarManager.getCalendarManager(context);
  const calendars = await mgr.getAllCalendars();
  if (calendars.length === 0) {
    return '系统里还没有任何日历账户';
  }
  const cal = calendars[0];
  // 已经写过的（同一天同标题）跳过，避免重复
  const existing: string[] = [];
  try {
    const dayStart = new Date(`${date}T00:00:00`).getTime();
    const dayEnd = dayStart + 24 * 3600 * 1000;
    const events = await cal.getEvents(calendarManager.EventFilter.filterByTime(dayStart, dayEnd));
    for (const ev of events) {
      existing.push(`${ev.title ?? ''}`);
    }
  } catch (e) {
    // 读不到就当没有
  }
  let added = 0;
  let skipped = 0;
  for (const row of rows) {
    if (existing.includes(row.title)) {
      skipped += 1;
      continue;
    }
    const allDay = row.start_time.length === 0;
    const start = allDay
      ? new Date(`${row.date}T00:00:00`).getTime()
      : new Date(`${row.date}T${row.start_time}:00`).getTime();
    let end = 0;
    if (allDay) {
      end = start + 24 * 3600 * 1000 - 60000;
    } else if (row.end_time.length > 0) {
      end = new Date(`${row.date}T${row.end_time}:00`).getTime();
    } else {
      end = start + 3600 * 1000;
    }
    const event: calendarManager.Event = {
      type: calendarManager.EventType.NORMAL,
      title: row.title,
      startTime: start,
      endTime: end,
      isAllDay: allDay,
      description: row.description,
    };
    try {
      await cal.addEvent(event);
      added += 1;
    } catch (e) {
      console.error(`[cal] addEvent failed: ${e}`);
    }
  }
  return `写入系统日历 ${added} 条（重复跳过 ${skipped} 条）`;
}

function findDbFile(dir: string): string {
  const names = fs.listFileSync(dir);
  for (const name of names) {
    if (name === 'lumina.db') {
      return `${dir}/${name}`;
    }
  }
  for (const name of names) {
    const full = `${dir}/${name}`;
    try {
      if (fs.statSync(full).isDirectory()) {
        const inner = findDbFile(full);
        if (inner.length > 0) {
          return inner;
        }
      }
    } catch (e) {
      // 跳过读不了的文件
    }
  }
  return '';
}

/** 从电脑端的 .dlpk 数据包导入（zip 里有 lumina.db） */
export async function importDlpk(context: common.UIAbilityContext): Promise<string> {
  const options = new picker.DocumentSelectOptions();
  options.maxSelectNumber = 1;
  const documentPicker = new picker.DocumentViewPicker(context);
  const uris = await documentPicker.select(options);
  if (uris.length === 0) {
    return '没有选择文件';
  }
  const workDir = `${context.filesDir}/dlpk_import`;
  const zipPath = `${context.filesDir}/import.dlpk`;
  try {
    fs.rmdirSync(workDir);
  } catch (e) {
    // 不存在就算了
  }
  fs.mkdirSync(workDir);

  const src = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
  fs.copyFileSync(src.fd, zipPath);
  fs.closeSync(src);

  await zlib.decompressFile(zipPath, workDir);

  const dbPath = findDbFile(workDir);
  if (dbPath.length === 0) {
    throw new Error('包里没找到 lumina.db（是不是选错文件了？）');
  }

  // 导入库放到 rdb 目录下再打开，主库不动
  const rdbDir = `${context.databaseDir}/rdb`;
  try {
    fs.mkdirSync(rdbDir);
  } catch (e) {
    // 已经有了
  }
  const tmpName = 'import_tmp.db';
  const tmpPath = `${rdbDir}/${tmpName}`;
  const copyFrom = fs.openSync(dbPath, fs.OpenMode.READ_ONLY);
  fs.copyFileSync(copyFrom.fd, tmpPath);
  fs.closeSync(copyFrom);

  const config: relationalStore.StoreConfig = {
    name: tmpName,
    securityLevel: relationalStore.SecurityLevel.S1,
  };
  let imported = 0;
  let skipped = 0;
  const store = await relationalStore.getRdbStore(context, config);
  try {
    const rows = await store.querySql(
      'SELECT title, description, date, start_time, end_time, remind_minutes, color, done FROM events');
    while (rows.goToNextRow()) {
      const title = `${rows.getString(rows.getColumnIndex('title')) ?? ''}`.trim();
      const date = `${rows.getString(rows.getColumnIndex('date')) ?? ''}`;
      const start = `${rows.getString(rows.getColumnIndex('start_time')) ?? ''}`;
      if (title.length === 0 || date.length === 0) {
        continue;
      }
      if (await Db.hasEvent(title, date, start)) {
        skipped += 1;
        continue;
      }
      const row: EventRow = {
        id: 0,
        title: title,
        description: `${rows.getString(rows.getColumnIndex('description')) ?? ''}`,
        date: date,
        start_time: start,
        end_time: `${rows.getString(rows.getColumnIndex('end_time')) ?? ''}`,
        remind_minutes: rows.getLong(rows.getColumnIndex('remind_minutes')),
        color: `${rows.getString(rows.getColumnIndex('color')) ?? ''}`,
        done: rows.getLong(rows.getColumnIndex('done')) === 1,
        reminder_id: 0,
      };
      await Db.insertEventRow(row);
      imported += 1;
    }
    rows.close();
  } finally {
    await relationalStore.deleteRdbStore(context, tmpName);
    try {
      fs.unlinkSync(tmpPath);
      fs.unlinkSync(zipPath);
      fs.rmdirSync(workDir);
    } catch (e) {
      // 清理失败不影响结果
    }
  }
  return `从电脑数据包导入 ${imported} 条（重复跳过 ${skipped} 条）`;
}
