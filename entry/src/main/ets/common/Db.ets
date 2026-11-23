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
      'remind_minutes', 'color', 'done',
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

  static async setDone(id: number, done: boolean): Promise<void> {
    await Db.need().executeSql('UPDATE events SET done = ? WHERE id = ?', [done ? 1 : 0, id]);
  }

  static async deleteEvent(id: number): Promise<void> {
    await Db.need().executeSql('DELETE FROM events WHERE id = ?', [id]);
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
