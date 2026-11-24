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

/** 读系统日历，导入过去 30 天到未来 180 天的事件；返回值是给用户看的诊断报告 */
export async function importSystemCalendar(context: common.UIAbilityContext): Promise<string> {
  const report: string[] = [];
  const at = abilityAccessCtrl.createAtManager();
  const wanted: Permissions[] = ['ohos.permission.READ_CALENDAR', 'ohos.permission.WRITE_CALENDAR'];
  let perm = '';
  try {
    const res = await at.requestPermissionsFromUser(context, wanted);
    perm = res.authResults.join(',');
    console.info(`[cal] permission results=${perm}`);
  } catch (e) {
    report.push(`申请日历权限失败：${e}`);
    return report.join('\n');
  }
  if (perm.length === 0 || perm.split(',')[0] !== '0') {
    return `没有日历权限（返回 ${perm || '空'}）：设置 → 应用和元服务 → DanLume → 权限 → 日历，改成允许`;
  }
  const mgr = calendarManager.getCalendarManager(context);
  let calendars: calendarManager.Calendar[] = [];
  try {
    calendars = await mgr.getAllCalendars();
  } catch (e) {
    return `拿不到日历账户列表：${e}`;
  }
  console.info(`[cal] calendars=${calendars.length}`);
  report.push(`日历账户：${calendars.length} 个`);
  if (calendars.length === 0) {
    try {
      const def = await mgr.getCalendar();
      calendars = [def];
      report.push('账户列表为空，改用默认日历（getCalendar）');
    } catch (e) {
      report.push(`默认日历也拿不到：${e}`);
    }
  }
  if (calendars.length === 0) {
    return `${report.join('\n')}\n系统里查不到任何日历账户（可能在「日历」App 里还没同步）`;
  }
  const now = Date.now();
  const from = now - 30 * 24 * 3600 * 1000;
  const to = now + 180 * 24 * 3600 * 1000;
  let read = 0;
  let added = 0;
  const seen: string[] = [];
  for (let ci = 0; ci < calendars.length; ci += 1) {
    const cal = calendars[ci];
    let accountName = '';
    try {
      const acc = cal.getAccount();
      accountName = `${acc.displayName ?? ''} ${acc.name ?? ''}`.trim();
    } catch (e) {
      accountName = `账户#${ci}`;
    }
    let events: calendarManager.Event[] = [];
    let countAll = -1;
    let countKeys = -1;
    try {
      events = await cal.getEvents(calendarManager.EventFilter.filterByTime(from, to));
    } catch (e) {
      report.push(`#${ci} 按时间读失败：${e}`);
    }
    try {
      const keys: (keyof calendarManager.Event)[] = ['title', 'startTime', 'endTime', 'isAllDay'];
      const withKeys = await cal.getEvents(calendarManager.EventFilter.filterByTime(from, to), keys);
      countKeys = withKeys.length;
      if (events.length === 0 && withKeys.length > 0) {
        events = withKeys;
      }
    } catch (e) {
      countKeys = -1;
    }
    try {
      const all = await cal.getEvents();
      countAll = all.length;
      // 时间过滤一条都没读到、但账户里明明有事件：退回全部事件再筛
      if (events.length === 0 && all.length > 0) {
        events = all;
      }
    } catch (e) {
      countAll = -1;
    }
    console.info(`[cal] calendar#${ci} ${accountName} time=${events.length} keys=${countKeys} all=${countAll}`);
    report.push(`#${ci} ${accountName}：按时间 ${events.length} 条 / 带字段 ${countKeys} 条 / 账户全部 ${countAll} 条`);
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
      const key = `${title}|${date}|${start}`;
      if (seen.includes(key)) {
        continue;
      }
      seen.push(key);
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
  console.info(`[cal] read=${read} added=${added}`);
  report.push(`合计读到 ${read} 条，新导入 ${added} 条`);
  // 再试一次「默认日历」：有些机器上 getAllCalendars 返回的账户读不到数据
  if (read === 0) {
    try {
      const def = await mgr.getCalendar();
      const acc = def.getAccount();
      let n = -1;
      try {
        const list = await def.getEvents(calendarManager.EventFilter.filterByTime(from, to));
        n = list.length;
      } catch (e) {
        n = -1;
      }
      let allN = -1;
      try {
        const all = await def.getEvents();
        allN = all.length;
      } catch (e) {
        allN = -1;
      }
      report.push(`默认日历 ${acc.displayName ?? ''}：按时间 ${n} 条 / 全部 ${allN} 条`);
    } catch (e) {
      report.push(`默认日历读取失败：${e}`);
    }
  }
  return report.join('\n');
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
  // 已经写过的（同一天同标题）跳过：所有日历账户都查一遍，标题去空格再比
  const existing: string[] = [];
  const dayStart = new Date(`${date}T00:00:00`).getTime();
  const dayEnd = dayStart + 24 * 3600 * 1000;
  for (const each of calendars) {
    try {
      const events = await each.getEvents(calendarManager.EventFilter.filterByTime(dayStart, dayEnd));
      for (const ev of events) {
        existing.push(`${ev.title ?? ''}`.trim());
      }
    } catch (e) {
      // 读不到就当没有
    }
  }
  let added = 0;
  let skipped = 0;
  for (const row of rows) {
    if (existing.includes(row.title.trim())) {
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
      existing.push(row.title.trim());
      added += 1;
    } catch (e) {
      console.error(`[cal] addEvent failed: ${e}`);
    }
  }
  return `写入系统日历 ${added} 条（重复跳过 ${skipped} 条）`;
}

/** 导入 .ics 日历文件（系统日历账户读不出来时的兜底） */
export async function importIcsFile(context: common.UIAbilityContext): Promise<string> {
  const options = new picker.DocumentSelectOptions();
  options.maxSelectNumber = 1;
  const documentPicker = new picker.DocumentViewPicker(context);
  const uris = await documentPicker.select(options);
  if (uris.length === 0) {
    return '没有选择文件';
  }
  const src = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
  const tmp = `${context.filesDir}/import_ics.ics`;
  fs.copyFileSync(src.fd, tmp);
  fs.closeSync(src);
  const text = fs.readTextSync(tmp).replace(/^﻿/, '');
  if (text.indexOf('BEGIN:VEVENT') < 0) {
    return '这个文件里没有 VEVENT（不是 .ics / .vcs 日历？）';
  }
  // RFC 5545：折行是把续行以空格/制表符开头，先拼回去
  const rawLines = text.split(/\r\n|\r|\n/);
  const lines: string[] = [];
  for (const line of rawLines) {
    if ((line.startsWith(' ') || line.startsWith('\t')) && lines.length > 0) {
      lines[lines.length - 1] += line.substring(1);
    } else {
      lines.push(line);
    }
  }
  let summary = '';
  let dtStart = '';
  let dtEnd = '';
  let description = '';
  let location = '';
  let inEvent = false;
  let added = 0;
  let skipped = 0;
  for (const line of lines) {
    if (line === 'BEGIN:VEVENT') {
      inEvent = true;
      summary = '';
      dtStart = '';
      dtEnd = '';
      description = '';
      location = '';
      continue;
    }
    if (line === 'END:VEVENT') {
      inEvent = false;
      if (summary.trim().length === 0 || dtStart.length === 0) {
        skipped += 1;
        continue;
      }
      const parsed = parseIcsTime(dtStart);
      const parsedEnd = parseIcsTime(dtEnd);
      if (parsed.date.length === 0) {
        skipped += 1;
        continue;
      }
      const title = unescapeIcs(summary.trim());
      if (await Db.hasEvent(title, parsed.date, parsed.time)) {
        skipped += 1;
        continue;
      }
      await Db.addEvent({
        title: title,
        date: parsed.date,
        start_time: parsed.time,
        end_time: parsedEnd.time,
        description: unescapeIcs(description).trim(),
        color: '',
      });
      added += 1;
      continue;
    }
    if (!inEvent) {
      continue;
    }
    if (line.startsWith('SUMMARY')) {
      summary = textValueOf(line);
    } else if (line.startsWith('DTSTART')) {
      dtStart = dateValueOf(line);
    } else if (line.startsWith('DTEND')) {
      dtEnd = dateValueOf(line);
    } else if (line.startsWith('DESCRIPTION')) {
      description = textValueOf(line);
    } else if (line.startsWith('LOCATION')) {
      location = textValueOf(line);
    }
  }
  return `从 .ics 导入 ${added} 条（跳过 ${skipped} 条：无标题 / 重复）`;
}

/** "SUMMARY:周一例会" → "周一例会"（第一个冒号后是内容） */
function textValueOf(line: string): string {
  const idx = line.indexOf(':');
  return idx >= 0 ? line.substring(idx + 1).trim() : '';
}

/** "DTSTART;TZID=(UTC+08:00) 北京:20261124T090000" → 取最后一个冒号后的时间（TZID 里可能带冒号） */
function dateValueOf(line: string): string {
  const idx = line.lastIndexOf(':');
  return idx >= 0 ? line.substring(idx + 1).trim() : '';
}

function unescapeIcs(text: string): string {
  return text.replace(/\\n/gi, '\n').replace(/\\,/g, ',').replace(/\\;/g, ';').replace(/\\\\/g, '\\');
}

class IcsTime {
  date: string = '';
  time: string = '';
}

/** 解析 20261124T090000 / 20261124T090000Z / VALUE=DATE:20261124 */
function parseIcsTime(raw: string): IcsTime {
  const out = new IcsTime();
  const value = raw.trim();
  if (value.length < 8) {
    return out;
  }
  const y = parseInt(value.substring(0, 4), 10);
  const mo = parseInt(value.substring(4, 6), 10);
  const d = parseInt(value.substring(6, 8), 10);
  if (isNaN(y) || isNaN(mo) || isNaN(d)) {
    return out;
  }
  out.date = `${y}-${pad(mo)}-${pad(d)}`;
  if (value.length >= 15 && value.charAt(8) === 'T') {
    let hh = parseInt(value.substring(9, 11), 10);
    let mm = parseInt(value.substring(11, 13), 10);
    const isUtc = value.endsWith('Z');
    if (isUtc) {
      const when = new Date(Date.UTC(y, mo - 1, d, hh, mm, 0));
      out.date = `${when.getFullYear()}-${pad(when.getMonth() + 1)}-${pad(when.getDate())}`;
      hh = when.getHours();
      mm = when.getMinutes();
    }
    out.time = `${pad(hh)}:${pad(mm)}`;
  }
  return out;
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
