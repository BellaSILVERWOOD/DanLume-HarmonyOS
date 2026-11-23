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

/** 对话会话（历史会话列表用） */
export interface ChatSessionRow {
  id: number;
  title: string;
  updated_at: string;
}

/** 一条聊天消息 */
export interface ChatMessageRow {
  role: string;
  text: string;
}

/** 一条记忆（folder 形如 "学业/高数"，空 = 未归档） */
export interface MemoryRow {
  id: number;
  title: string;
  content: string;
  folder: string;
  updated_at: string;
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
     created_at TEXT NOT NULL DEFAULT '',
     reminder_id INTEGER NOT NULL DEFAULT 0,
     uid TEXT NOT NULL DEFAULT '',
     updated_at TEXT NOT NULL DEFAULT '',
     deleted INTEGER NOT NULL DEFAULT 0
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
  `CREATE TABLE IF NOT EXISTS chat_sessions (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     title TEXT NOT NULL DEFAULT '',
     created_at TEXT NOT NULL DEFAULT '',
     updated_at TEXT NOT NULL DEFAULT ''
   )`,
  `CREATE TABLE IF NOT EXISTS chat_messages (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     session_id INTEGER NOT NULL,
     role TEXT NOT NULL DEFAULT '',
     text TEXT NOT NULL DEFAULT '',
     created_at TEXT NOT NULL DEFAULT ''
   )`,
  `CREATE TABLE IF NOT EXISTS memories (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     title TEXT NOT NULL DEFAULT '',
     content TEXT NOT NULL DEFAULT '',
     folder TEXT NOT NULL DEFAULT '',
     created_at TEXT NOT NULL DEFAULT '',
     updated_at TEXT NOT NULL DEFAULT ''
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
    await Db.ensureColumns();
  }

  /** 老库补列：reminder_id / uid / updated_at / deleted，并给老日程补 uid */
  private static async ensureColumns(): Promise<void> {
    const db = Db.need();
    const have: string[] = [];
    const rows = await db.querySql('PRAGMA table_info(events)');
    while (rows.goToNextRow()) {
      have.push(rows.getString(rows.getColumnIndex('name')));
    }
    rows.close();
    const wanted: string[] = ['reminder_id', 'uid', 'updated_at', 'deleted'];
    for (const name of wanted) {
      if (!have.includes(name)) {
        if (name === 'reminder_id') {
          await db.executeSql('ALTER TABLE events ADD COLUMN reminder_id INTEGER NOT NULL DEFAULT 0');
        } else if (name === 'deleted') {
          await db.executeSql('ALTER TABLE events ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0');
        } else {
          await db.executeSql(`ALTER TABLE events ADD COLUMN ${name} TEXT NOT NULL DEFAULT ''`);
        }
      }
    }
    const missing = await db.querySql(`SELECT id FROM events WHERE uid = '' OR uid IS NULL`);
    const ids: number[] = [];
    while (missing.goToNextRow()) {
      ids.push(missing.getLong(0));
    }
    missing.close();
    for (const id of ids) {
      const uid = `e_${id}_${Date.now()}_${Math.floor(Math.random() * 100000)}`;
      await db.executeSql('UPDATE events SET uid = ?, updated_at = ? WHERE id = ?',
        [uid, Db.isoNow(), id]);
    }
  }

  /** UTC ISO（服务器同步用，字典序就是时间序） */
  static isoNow(): string {
    return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
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
    predicates.equalTo('date', date).and().equalTo('deleted', 0).orderByAsc('start_time');
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
    predicates.like('date', `${month}-%`).and().equalTo('deleted', 0).orderByAsc('date');
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
    const uid = `e_${Date.now()}_${Math.floor(Math.random() * 100000)}`;
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
      uid: uid,
      updated_at: Db.isoNow(),
      deleted: 0,
    };
    return await Db.need().insert('events', bucket);
  }

  /** 导入前查重：同标题 + 同日期 + 同开始时间就当已经有了 */
  static async hasEvent(title: string, date: string, startTime: string): Promise<boolean> {
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('title', title).and().equalTo('date', date).and()
      .equalTo('start_time', startTime).and().equalTo('deleted', 0);
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
      uid: `e_${Date.now()}_${Math.floor(Math.random() * 100000)}`,
      updated_at: Db.isoNow(),
      deleted: 0,
    };
    return await Db.need().insert('events', bucket);
  }

  // ---------------------------------------------------------------- 多端同步
  /** 导出本地比 since 新的日程（含墓碑），给 /api/v1/sync 用 */
  static async syncExport(since: string): Promise<Object[]> {
    const out: Object[] = [];
    const rows = await Db.need().querySql(
      'SELECT uid, title, description, date, start_time, end_time, remind_minutes, color, done, updated_at, deleted ' +
      'FROM events WHERE updated_at > ?', [since]);
    while (rows.goToNextRow()) {
      const payload: Record<string, Object> = {
        'title': rows.getString(1),
        'description': rows.getString(2),
        'date': rows.getString(3),
        'start_time': rows.getString(4),
        'end_time': rows.getString(5),
        'remind_minutes': rows.getLong(6),
        'color': rows.getString(7),
        'done': rows.getLong(8) === 1,
      };
      const item: Record<string, Object> = {
        'kind': 'event',
        'uid': rows.getString(0),
        'payload': JSON.stringify(payload),
        'updated_at': rows.getString(9),
        'deleted': rows.getLong(10) === 1,
      };
      out.push(item);
    }
    rows.close();
    return out;
  }

  /** 把服务器上的一条日程合并进来（后写胜出） */
  static async syncApplyEvent(uid: string, payloadJson: string, updatedAt: string,
    deleted: boolean): Promise<void> {
    if (uid.length === 0) {
      return;
    }
    const existing = await Db.need().querySql(
      'SELECT id, updated_at FROM events WHERE uid = ?', [uid]);
    let id = 0;
    let localUpdated = '';
    if (existing.goToFirstRow()) {
      id = existing.getLong(0);
      localUpdated = existing.getString(1);
    }
    existing.close();
    if (id > 0 && localUpdated >= updatedAt) {
      return; // 本地更新，别被旧数据覆盖
    }
    if (deleted) {
      if (id > 0) {
        await Db.need().executeSql('UPDATE events SET deleted = 1, updated_at = ? WHERE id = ?',
          [updatedAt, id]);
      }
      return;
    }
    let payload: Record<string, Object> = {};
    try {
      payload = JSON.parse(payloadJson) as Record<string, Object>;
    } catch (e) {
      return;
    }
    const title = `${payload['title'] ?? ''}`;
    const description = `${payload['description'] ?? ''}`;
    const date = `${payload['date'] ?? ''}`;
    const start = `${payload['start_time'] ?? ''}`;
    const end = `${payload['end_time'] ?? ''}`;
    const remind = parseInt(`${payload['remind_minutes'] ?? '10'}`, 10);
    const color = `${payload['color'] ?? ''}`;
    const done = payload['done'] === true || `${payload['done'] ?? ''}` === 'true';
    if (date.length === 0) {
      return;
    }
    if (id > 0) {
      await Db.need().executeSql(
        'UPDATE events SET title = ?, description = ?, date = ?, start_time = ?, end_time = ?, ' +
        'remind_minutes = ?, color = ?, done = ?, deleted = 0, updated_at = ? WHERE id = ?',
        [title, description, date, start, end, isNaN(remind) ? 10 : remind, color,
          done ? 1 : 0, updatedAt, id]);
    } else {
      const bucket: relationalStore.ValuesBucket = {
        title: title,
        description: description,
        date: date,
        start_time: start,
        end_time: end,
        remind_minutes: isNaN(remind) ? 10 : remind,
        color: color,
        done: done ? 1 : 0,
        repeat: '',
        repeat_until: '',
        done_dates: '',
        created_at: Db.stamp(),
        uid: uid,
        updated_at: updatedAt,
        deleted: 0,
      };
      await Db.need().insert('events', bucket);
    }
  }

  /** 按 id 取一条（AI 工具改 / 删前先看看有没有） */
  static async eventById(id: number): Promise<EventRow | null> {
    const predicates = new relationalStore.RdbPredicates('events');
    predicates.equalTo('id', id).and().equalTo('deleted', 0);
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
      'UPDATE events SET title = ?, date = ?, start_time = ?, end_time = ?, done = ?, description = ?, updated_at = ? WHERE id = ?',
      [title, date, startTime, endTime, done ? 1 : 0, description, Db.isoNow(), id]);
  }

  static async setDone(id: number, done: boolean): Promise<void> {
    await Db.need().executeSql('UPDATE events SET done = ?, updated_at = ? WHERE id = ?',
      [done ? 1 : 0, Db.isoNow(), id]);
  }

  /** 删除用墓碑（deleted=1），同步时另一台设备才知道这条被删了 */
  static async deleteEvent(id: number): Promise<void> {
    await Db.need().executeSql('UPDATE events SET deleted = 1, updated_at = ? WHERE id = ?',
      [Db.isoNow(), id]);
  }

  static async renameEvent(id: number, title: string): Promise<void> {
    await Db.need().executeSql('UPDATE events SET title = ?, updated_at = ? WHERE id = ?',
      [title, Db.isoNow(), id]);
  }

  /** 日历页编辑：标题 + 开始/结束时间（日期与提醒不动） */
  static async updateEvent(id: number, title: string, startTime: string, endTime: string): Promise<void> {
    await Db.need().executeSql(
      'UPDATE events SET title = ?, start_time = ?, end_time = ?, updated_at = ? WHERE id = ?',
      [title, startTime, endTime, Db.isoNow(), id]);
  }

  /** 记下系统提醒 id（0 = 没设提醒） */
  static async setReminderId(id: number, reminderId: number): Promise<void> {
    await Db.need().executeSql('UPDATE events SET reminder_id = ? WHERE id = ?', [reminderId, id]);
  }

  /** 提醒提前多少分钟（0 = 不提醒） */
  static async setRemindMinutes(id: number, minutes: number): Promise<void> {
    await Db.need().executeSql('UPDATE events SET remind_minutes = ?, updated_at = ? WHERE id = ?',
      [minutes, Db.isoNow(), id]);
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

  // ---------------------------------------------------------------- 会话 / 记忆
  static async chatSessionCreate(title: string): Promise<number> {
    const bucket: relationalStore.ValuesBucket = {
      title: title,
      created_at: Db.stamp(),
      updated_at: Db.isoNow(),
    };
    return await Db.need().insert('chat_sessions', bucket);
  }

  static async chatSessionRename(id: number, title: string): Promise<void> {
    await Db.need().executeSql('UPDATE chat_sessions SET title = ?, updated_at = ? WHERE id = ?',
      [title, Db.isoNow(), id]);
  }

  static async chatSessionDelete(id: number): Promise<void> {
    await Db.need().executeSql('DELETE FROM chat_messages WHERE session_id = ?', [id]);
    await Db.need().executeSql('DELETE FROM chat_sessions WHERE id = ?', [id]);
  }

  static async chatSessionList(limit: number): Promise<ChatSessionRow[]> {
    const rows = await Db.need().querySql(
      'SELECT id, title, updated_at FROM chat_sessions ORDER BY updated_at DESC LIMIT ?', [limit]);
    const out: ChatSessionRow[] = [];
    while (rows.goToNextRow()) {
      out.push({
        id: rows.getLong(0),
        title: rows.getString(1),
        updated_at: rows.getString(2),
      });
    }
    rows.close();
    return out;
  }

  static async chatMessageAdd(sessionId: number, role: string, text: string): Promise<void> {
    const bucket: relationalStore.ValuesBucket = {
      session_id: sessionId,
      role: role,
      text: text,
      created_at: Db.stamp(),
    };
    await Db.need().insert('chat_messages', bucket);
    await Db.need().executeSql('UPDATE chat_sessions SET updated_at = ? WHERE id = ?',
      [Db.isoNow(), sessionId]);
  }

  static async chatMessages(sessionId: number): Promise<ChatMessageRow[]> {
    const rows = await Db.need().querySql(
      'SELECT role, text FROM chat_messages WHERE session_id = ? ORDER BY id', [sessionId]);
    const out: ChatMessageRow[] = [];
    while (rows.goToNextRow()) {
      out.push({ role: rows.getString(0), text: rows.getString(1) });
    }
    rows.close();
    return out;
  }

  /** 当天所有会话（整理记忆用） */
  static async chatMessagesSince(isoStamp: string): Promise<ChatMessageRow[]> {
    const rows = await Db.need().querySql(
      'SELECT role, text FROM chat_messages WHERE created_at >= ? ORDER BY id', [isoStamp]);
    const out: ChatMessageRow[] = [];
    while (rows.goToNextRow()) {
      out.push({ role: rows.getString(0), text: rows.getString(1) });
    }
    rows.close();
    return out;
  }

  static async memoryAdd(title: string, content: string, folder: string): Promise<number> {
    const bucket: relationalStore.ValuesBucket = {
      title: title,
      content: content,
      folder: folder,
      created_at: Db.stamp(),
      updated_at: Db.isoNow(),
    };
    return await Db.need().insert('memories', bucket);
  }

  static async memoryUpdate(id: number, title: string, content: string, folder: string): Promise<void> {
    await Db.need().executeSql(
      'UPDATE memories SET title = ?, content = ?, folder = ?, updated_at = ? WHERE id = ?',
      [title, content, folder, Db.isoNow(), id]);
  }

  static async memoryDelete(id: number): Promise<void> {
    await Db.need().executeSql('DELETE FROM memories WHERE id = ?', [id]);
  }

  static async memoryList(): Promise<MemoryRow[]> {
    const rows = await Db.need().querySql(
      'SELECT id, title, content, folder, updated_at FROM memories ORDER BY folder, updated_at DESC');
    const out: MemoryRow[] = [];
    while (rows.goToNextRow()) {
      out.push({
        id: rows.getLong(0),
        title: rows.getString(1),
        content: rows.getString(2),
        folder: rows.getString(3),
        updated_at: rows.getString(4),
      });
    }
    rows.close();
    return out;
  }

  static async memorySearch(query: string, limit: number): Promise<MemoryRow[]> {
    const like = `%${query}%`;
    const rows = await Db.need().querySql(
      'SELECT id, title, content, folder, updated_at FROM memories ' +
      'WHERE title LIKE ? OR content LIKE ? OR folder LIKE ? ORDER BY updated_at DESC LIMIT ?',
      [like, like, like, limit]);
    const out: MemoryRow[] = [];
    while (rows.goToNextRow()) {
      out.push({
        id: rows.getLong(0),
        title: rows.getString(1),
        content: rows.getString(2),
        folder: rows.getString(3),
        updated_at: rows.getString(4),
      });
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
