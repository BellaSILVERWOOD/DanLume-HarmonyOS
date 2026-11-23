/*
 * 本地库：relationalStore 版的 lumina.db（对应 Rust 版 store.rs 里用到的两张表）
 *
 * 约定（与桌面版一致，别改字段名，否则 .dlpk 迁不过来）：
 *   settings(key TEXT PRIMARY KEY, value TEXT)
 *   events(id INTEGER PK AUTOINCREMENT, title, description, date, start_time, end_time,
 *          remind_minutes INTEGER, color TEXT, done INTEGER, group_id INTEGER,
 *          repeat TEXT, repeat_until TEXT, done_dates TEXT, created_at TEXT)
 *
 * 时间是本地时间字符串（YYYY-MM-DD / HH:MM），跟桌面版一样不做时区换算。
 */
import relationalStore from '@ohos.data.relationalStore';
import common from '@ohos.app.ability.common';

const STORE_CONFIG: relationalStore.StoreConfig = {
  name: 'lumina.db',
  securityLevel: relationalStore.SecurityLevel.S1,
};

export interface EventRow {
  id: number;
  title: string;
  description: string;
  date: string;
  start_time: string;
  end_time: string;
  remind_minutes: number;
  color: string;
  done: boolean;
  reminder_id: number;
}

/** 新建日程的入参（ArkTS 不允许把对象字面量直接当类型，必须显式声明） */
export interface NewEventInput {
  title: string;
  date: string;
  start_time?: string;
  end_time?: string;
  description?: string;
  color?: string;
}

const SCHEMA: string[] = [
  `CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL DEFAULT '')`,
  `CREATE TABLE IF NOT EXISTS events (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     title TEXT NOT NULL DEFAULT '',
     description TEXT NOT NULL DEFAULT '',
     date TEXT NOT NULL DEFAULT '',
     start_time TEXT NOT NULL DEFAULT '',
     end_time TEXT NOT NULL DEFAULT '',
     remind_minutes INTEGER NOT NULL DEFAULT 10,
     color TEXT NOT NULL DEFAULT '',
     done INTEGER NOT NULL DEFAULT 0,
     group_id INTEGER,
     repeat TEXT NOT NULL DEFAULT '',
     repeat_until TEXT NOT NULL DEFAULT '',
     done_dates TEXT NOT NULL DEFAULT '',
     created_at TEXT NOT NULL DEFAULT ''
   )`,
  `CREATE INDEX IF NOT EXISTS idx_events_date ON events(date)`,
  `CREATE TABLE IF NOT EXISTS memos (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     body TEXT NOT NULL DEFAULT '',
     created_at TEXT NOT NULL DEFAULT ''
   )`,
  `CREATE TABLE IF NOT EXISTS flashcards (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     question TEXT NOT NULL DEFAULT '',
     answer TEXT NOT NULL DEFAULT '',
     tag TEXT NOT NULL DEFAULT '',
     created_at TEXT NOT NULL DEFAULT ''
   )`,
  `CREATE TABLE IF NOT EXISTS countdowns (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     title TEXT NOT NULL DEFAULT '',
     date TEXT NOT NULL DEFAULT '',
     created_at TEXT NOT NULL DEFAULT ''
   )`,
];

let store: relationalStore.RdbStore | null = null;

export class Db {
  /** 第一次调用时建库建表；之后复用同一个连接 */
  static async init(context: common.UIAbilityContext): Promise<void> {
    if (store !== null) {
      return;
    }
    store = await relationalStore.getRdbStore(context, STORE_CONFIG);
    for (const sql of SCHEMA) {
      await store.executeSql(sql);
    }
    await Db.ensureReminderColumn();
  }

  /** 老库补 `reminder_id` 列（CREATE TABLE IF NOT EXISTS 不会改已存在的表） */
  private static async ensureReminderColumn(): Promise<void> {
    const db = Db.need();
    let has = false;
    const rows = await db.querySql('PRAGMA table_info(events)');
    while (rows.goToNextRow()) {
      const name = rows.getString(rows.getColumnIndex('name'));
      if (name === 'reminder_id') {
        has = true;
      }
    }
    rows.close();
    if (!has) {
      await db.executeSql('ALTER TABLE events ADD COLUMN reminder_id INTEGER NOT NULL DEFAULT 0');
    }
  }

  private static need(): relationalStore.RdbStore {
    if (store === null) {
      throw new Error('数据库还没初始化（先在 EntryAbility.onCreate 里调 Db.init）');
    }
    return store;
  }

  // ---------------------------------------------------------------- 设置
  static async getSetting(key: string, fallback: string = ''): Promise<string> {
    const predicates = new relationalStore.RdbPredicates('settings');
    predicates.equalTo('key', key);
    const rows = await Db.need().query(predicates, ['value']);
    if (rows === null || rows.rowCount <= 0) {
      return fallback;
    }
    rows.goToFirstRow();
    const value = rows.getString(0);
    rows.close();
    return value === null ? fallback : value;
  }

  static async setSetting(key: string, value: string): Promise<void> {
    // 桌面版用 ON CONFLICT DO UPDATE；这里用 INSERT OR REPLACE 等价
    await Db.need().executeSql(
      'INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)',
      [key, value],
    );
  }

  // ---------------------------------------------------------------- 日程
  static async eventsOn(date: string): Promise<EventRow[]> {
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('date', date).orderByAsc('start_time');
    const rows = await Db.need().query(predicates, [
      'id', 'title', 'description', 'date', 'start_time', 'end_time',
      'remind_minutes', 'color', 'done', 'reminder_id',
    ]);
    const out: EventRow[] = [];
    while (rows.goToNextRow()) {
      out.push({
        id: rows.getLong(rows.getColumnIndex('id')),
        title: rows.getString(rows.getColumnIndex('title')),
        description: rows.getString(rows.getColumnIndex('description')),
        date: rows.getString(rows.getColumnIndex('date')),
        start_time: rows.getString(rows.getColumnIndex('start_time')),
        end_time: rows.getString(rows.getColumnIndex('end_time')),
        remind_minutes: rows.getLong(rows.getColumnIndex('remind_minutes')),
        color: rows.getString(rows.getColumnIndex('color')),
        done: rows.getLong(rows.getColumnIndex('done')) === 1,
        reminder_id: rows.getLong(rows.getColumnIndex('reminder_id')),
      });
    }
    rows.close();
    return out;
  }

  /** 某个月的全部日程（month = "YYYY-MM"），日历页用 */
  static async eventsInMonth(month: string): Promise<EventRow[]> {
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.like('date', `${month}-%`).orderByAsc('date');
    const rows = await Db.need().query(predicates, [
      'id', 'title', 'description', 'date', 'start_time', 'end_time',
      'remind_minutes', 'color', 'done', 'reminder_id',
    ]);
    const out: EventRow[] = [];
    while (rows.goToNextRow()) {
      out.push({
        id: rows.getLong(rows.getColumnIndex('id')),
        title: rows.getString(rows.getColumnIndex('title')),
        description: rows.getString(rows.getColumnIndex('description')),
        date: rows.getString(rows.getColumnIndex('date')),
        start_time: rows.getString(rows.getColumnIndex('start_time')),
        end_time: rows.getString(rows.getColumnIndex('end_time')),
        remind_minutes: rows.getLong(rows.getColumnIndex('remind_minutes')),
        color: rows.getString(rows.getColumnIndex('color')),
        done: rows.getLong(rows.getColumnIndex('done')) === 1,
        reminder_id: rows.getLong(rows.getColumnIndex('reminder_id')),
      });
    }
    rows.close();
    return out;
  }

  static async addEvent(input: NewEventInput): Promise<number> {
    const bucket: relationalStore.ValuesBucket = {
      title: input.title,
      description: input.description ?? '',
      date: input.date,
      start_time: input.start_time ?? '',
      end_time: input.end_time ?? '',
      remind_minutes: 10,
      color: input.color ?? '',
      done: 0,
      repeat: '',
      repeat_until: '',
      done_dates: '',
      created_at: Db.stamp(),
    };
    return await Db.need().insert('events', bucket);
  }

  /** 导入前查重：同标题 + 同日期 + 同开始时间就当已经有了 */
  static async hasEvent(title: string, date: string, startTime: string): Promise<boolean> {
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('title', title).and().equalTo('date', date).and().equalTo('start_time', startTime);
    const rows = await Db.need().query(predicates, ['id']);
    const has = rows.rowCount > 0;
    rows.close();
    return has;
  }

  /** 带完整字段的插入（导入用，保留提醒分钟 / 颜色 / 完成状态） */
  static async insertEventRow(row: EventRow): Promise<number> {
    const bucket: relationalStore.ValuesBucket = {
      title: row.title,
      description: row.description,
      date: row.date,
      start_time: row.start_time,
      end_time: row.end_time,
      remind_minutes: row.remind_minutes,
      color: row.color,
      done: row.done ? 1 : 0,
      repeat: '',
      repeat_until: '',
      done_dates: '',
      created_at: Db.stamp(),
    };
    return await Db.need().insert('events', bucket);
  }

  /** 按 id 取一条（AI 工具改 / 删前先看看有没有） */
  static async eventById(id: number): Promise<EventRow | null> {
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('id', id);
    const rows = await Db.need().query(predicates, [
      'id', 'title', 'description', 'date', 'start_time', 'end_time',
      'remind_minutes', 'color', 'done', 'reminder_id',
    ]);
    let out: EventRow | null = null;
    if (rows.goToFirstRow()) {
      out = {
        id: rows.getLong(rows.getColumnIndex('id')),
        title: rows.getString(rows.getColumnIndex('title')),
        description: rows.getString(rows.getColumnIndex('description')),
        date: rows.getString(rows.getColumnIndex('date')),
        start_time: rows.getString(rows.getColumnIndex('start_time')),
        end_time: rows.getString(rows.getColumnIndex('end_time')),
        remind_minutes: rows.getLong(rows.getColumnIndex('remind_minutes')),
        color: rows.getString(rows.getColumnIndex('color')),
        done: rows.getLong(rows.getColumnIndex('done')) === 1,
        reminder_id: rows.getLong(rows.getColumnIndex('reminder_id')),
      };
    }
    rows.close();
    return out;
  }

  /** 全字段更新（AI 工具用，日期也可改） */
  static async updateEventFields(id: number, title: string, date: string,
    startTime: string, endTime: string, done: boolean, description: string): Promise<void> {
    await Db.need().executeSql(
      'UPDATE events SET title = ?, date = ?, start_time = ?, end_time = ?, done = ?, description = ? WHERE id = ?',
      [title, date, startTime, endTime, done ? 1 : 0, description, id]);
  }

  static async setDone(id: number, done: boolean): Promise<void> {
    await Db.need().executeSql('UPDATE events SET done = ? WHERE id = ?', [done ? 1 : 0, id]);
  }

  static async deleteEvent(id: number): Promise<void> {
    await Db.need().executeSql('DELETE FROM events WHERE id = ?', [id]);
  }

  static async renameEvent(id: number, title: string): Promise<void> {
    await Db.need().executeSql('UPDATE events SET title = ? WHERE id = ?', [title, id]);
  }

  /** 日历页编辑：标题 + 开始/结束时间（日期与提醒不动） */
  static async updateEvent(id: number, title: string, startTime: string, endTime: string): Promise<void> {
    await Db.need().executeSql(
      'UPDATE events SET title = ?, start_time = ?, end_time = ? WHERE id = ?',
      [title, startTime, endTime, id]);
  }

  /** 记下系统提醒 id（0 = 没设提醒） */
  static async setReminderId(id: number, reminderId: number): Promise<void> {
    await Db.need().executeSql('UPDATE events SET reminder_id = ? WHERE id = ?', [reminderId, id]);
  }

  // ---------------------------------------------------------------- 备忘 / 闪卡 / 倒计时
  static async memoAdd(body: string): Promise<number> {
    const bucket: relationalStore.ValuesBucket = { body: body, created_at: Db.stamp() };
    return await Db.need().insert('memos', bucket);
  }

  static async memoSearch(query: string, limit: number): Promise<string[]> {
    const predicates = new relationalStore.RdbPredicates('memos');
    if (query.length > 0) {
      predicates.like('body', `%${query}%`);
    }
    predicates.orderByDesc('id').limitAs(limit);
    const rows = await Db.need().query(predicates, ['body']);
    const out: string[] = [];
    while (rows.goToNextRow()) {
      out.push(rows.getString(rows.getColumnIndex('body')));
    }
    rows.close();
    return out;
  }

  static async flashcardAdd(question: string, answer: string, tag: string): Promise<number> {
    const bucket: relationalStore.ValuesBucket = {
      question: question,
      answer: answer,
      tag: tag,
      created_at: Db.stamp(),
    };
    return await Db.need().insert('flashcards', bucket);
  }

  /** 随机抽一张闪卡，返回 [question, answer]；没有就返回空数组 */
  static async flashcardRandom(): Promise<string[]> {
    const rows = await Db.need().querySql(
      'SELECT question, answer FROM flashcards ORDER BY RANDOM() LIMIT 1');
    const out: string[] = [];
    if (rows.goToFirstRow()) {
      out.push(rows.getString(0));
      out.push(rows.getString(1));
    }
    rows.close();
    return out;
  }

  static async countFast(sql: string): Promise<number> {
    const rows = await Db.need().querySql(sql);
    let n = 0;
    if (rows.goToFirstRow()) {
      n = rows.getLong(0);
    }
    rows.close();
    return n;
  }

  static async countdownAdd(title: string, date: string): Promise<number> {
    const bucket: relationalStore.ValuesBucket = {
      title: title,
      date: date,
      created_at: Db.stamp(),
    };
    return await Db.need().insert('countdowns', bucket);
  }

  static async countdownList(limit: number): Promise<string[]> {
    const predicates = new relationalStore.RdbPredicates('countdowns');
    predicates.orderByAsc('date').limitAs(limit);
    const rows = await Db.need().query(predicates, ['title', 'date']);
    const out: string[] = [];
    while (rows.goToNextRow()) {
      out.push(`${rows.getString(rows.getColumnIndex('date'))} ${rows.getString(rows.getColumnIndex('title'))}`);
    }
    rows.close();
    return out;
  }

  /** 计数类设置（usage_stats 用）：每次 +1 */
  static async bumpCounter(key: string): Promise<number> {
    const raw = await Db.getSetting(key, '0');
    const n = parseInt(raw, 10);
    const next = (isNaN(n) ? 0 : n) + 1;
    await Db.setSetting(key, `${next}`);
    return next;
  }

  /** 本地时间戳，和桌面版 now_str() 一个格式 */
  static stamp(): string {
    const now = new Date();
    const pad = (value: number): string => (value < 10 ? `0${value}` : `${value}`);
    return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())} ` +
      `${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}`;
  }

  static today(): string {
    const now = new Date();
    const pad = (value: number): string => (value < 10 ? `0${value}` : `${value}`);
    return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
  }
}
