import { Db, EventRow } from '../common/Db';
import { Api, PaperHit, AiProfile } from '../common/Api';
import { importSystemCalendar, importDlpk, exportDayToSystem } from '../common/Migrate';
import { PHONE_TOOL_NAMES, TOOL_LABELS, toolKey } from '../common/AiTools';
import { sendMail, fetchInbox, fetchInboxList, fetchMailBody, MailHeader } from '../common/Mail';
import { syncEvents } from '../common/Sync';
import { parseMarkdown, MdBlock, MdKind, MdSpan } from '../common/Md';
import common from '@ohos.app.ability.common';
import reminderAgentManager from '@ohos.reminderAgentManager';
import notificationManager from '@ohos.notificationManager';
import { speechRecognizer } from '@kit.CoreSpeechKit';
import { picker, fileIo as fsKit } from '@kit.CoreFileKit';
import abilityAccessCtrl, { Permissions } from '@ohos.abilityAccessCtrl';
import pasteboard from '@ohos.pasteboard';
import { promptAction } from '@kit.ArkUI';

interface ChatLine {
  role: 'user' | 'assistant';
  text: string;
}

/** 今日列表的一项（ArkTS 不允许对象字面量当类型，ForEach 回调也要写类型） */
interface EventItem {
  id: number;
  title: string;
  start: string;
  done: boolean;
  reminderId: number;
}

/** 服务器公告（/api/v1/announcements 的 items 里用到的字段） */
interface NoticeItem {
  id: number;
  title: string;
  body: string;
  created_at: string;
}

/** 日历月视图的一格（day = 0 表示补位空格） */
interface DayCell {
  day: number;
  date: string;
  count: number;
  inMonth: boolean;
  today: boolean;
}

@Entry
@Component
struct Index {
  // 不能叫 tabIndex：和 CustomComponent 内置的 tabIndex 属性方法重名
  @State currentTab: number = 0;
  @State today: string = Db.today();
  @State events: EventItem[] = [];
  // 每个标签页各自的输入内容，别共用一个 draft（会在页面之间串）
  @State todayDraft: string = '';
  @State chatDraft: string = '';
  @State chat: ChatLine[] = [];
  @State asking: boolean = false;
  @State accountName: string = '';
  @State loginUser: string = '';
  @State loginPwd: string = '';
  @State message: string = '';
  // AI 接口（OpenAI 兼容）：可以存多组，聊天页顶部切换
  @State aiProfiles: AiProfile[] = [];
  @State aiActive: string = '';
  @State aiName: string = '';
  @State aiEditIndex: number = -1;
  @State aiToolsOn: boolean = false;
  @State toolOn: boolean[] = [];
  // 邮件
  @State mailAddress: string = '';
  @State mailAuth: string = '';
  @State mailSmtpHost: string = 'smtp.qq.com';
  @State mailSmtpPort: string = '465';
  @State mailImapHost: string = 'imap.qq.com';
  @State mailImapPort: string = '993';
  @State inboxText: string = '';
  @State mailBusy: boolean = false;
  @State mailTo: string = '';
  @State mailSubject: string = '';
  @State mailBody: string = '';
  @State inboxList: MailHeader[] = [];
  @State inboxDetail: string = '';
  @State syncing: boolean = false;
  // 小工具：备忘 / 倒计时 / 闪卡 / 番茄钟
  @State memos: string[] = [];
  @State memoDraft: string = '';
  @State countdowns: string[] = [];
  @State cdTitle: string = '';
  @State cdDate: string = '';
  @State flashTotal: number = 0;
  @State flashQ: string = '';
  @State flashA: string = '';
  @State flashReveal: boolean = false;
  @State pomoLeft: number = 0;
  @State pomoOn: boolean = false;
  pomoTimer: number = -1;
  @State aiBase: string = '';
  @State aiModel: string = '';
  @State aiKey: string = '';
  @State serverUrl: string = '';
  @State notices: NoticeItem[] = [];
  // 行内编辑：editingId 是正在编辑的日程 id（0 = 没有在编辑）
  @State editingId: number = 0;
  @State editingTitle: string = '';
  // 日历页：month = "YYYY-MM"
  @State month: string = '';
  @State monthRows: EventRow[] = [];
  // 日历页：选中的那天 + 那天的事件 + 快速新增 / 编辑状态
  @State selDate: string = '';
  @State dayRows: EventRow[] = [];
  @State calDraft: string = '';
  @State calTime: string = '';
  @State editEventId: number = 0;
  @State editTitle: string = '';
  @State editStart: string = '';
  @State editEnd: string = '';
  @State editDate: string = '';
  @State editDesc: string = '';
  @State editAllDay: boolean = false;
  @State sheetOpen: boolean = false;
  // 文献页（arXiv）
  @State paperQuery: string = '';
  @State papers: PaperHit[] = [];
  @State paperBusy: boolean = false;
  @State listening: boolean = false;
  // 语音识别引擎（第一次用时创建，之后复用）
  asrEngine: speechRecognizer.SpeechRecognitionEngine | null = null;

  aboutToAppear(): void {
    // AI 工具（打开链接 / 读写沙箱文件）要用到应用上下文
    AppStorage.setOrCreate('abilityContext', getContext(this) as common.UIAbilityContext);
    this.reloadToday();
    this.reloadAccount();
    this.reloadAi();
    this.reloadMail();
    this.reloadTools();
    if (this.month.length === 0) {
      this.month = this.today.slice(0, 7);
    }
    if (this.selDate.length === 0) {
      this.selDate = this.today;
    }
    this.reloadMonth();
    this.reloadDay();
  }

  // ------------------------------------------------------------ 数据
  async reloadToday(): Promise<void> {
    const rows = await Db.eventsOn(this.today);
    this.events = rows.map((row): EventItem => {
      const item: EventItem = {
        id: row.id,
        title: row.title,
        start: row.start_time,
        done: row.done,
        reminderId: row.reminder_id,
      };
      return item;
    });
  }

  // ------------------------------------------------------------ 日历
  async reloadMonth(): Promise<void> {
    if (this.month.length === 0) {
      this.month = this.today.slice(0, 7);
    }
    this.monthRows = await Db.eventsInMonth(this.month);
  }

  /** 日历页下半部分：选中那天的日程 */
  async reloadDay(): Promise<void> {
    if (this.selDate.length === 0) {
      this.dayRows = [];
      return;
    }
    this.dayRows = await Db.eventsOn(this.selDate);
  }

  selectDay(date: string): void {
    if (date.length === 0) {
      return;
    }
    this.selDate = date;
    this.editEventId = 0;
    this.reloadDay();
  }

  jumpToday(): void {
    this.today = Db.today();
    this.month = this.today.slice(0, 7);
    this.selDate = this.today;
    this.reloadMonth();
    this.reloadDay();
    this.reloadToday();
  }

  dayLabel(): string {
    if (this.selDate.length === 0) {
      return '';
    }
    const y = parseInt(this.selDate.slice(0, 4), 10);
    const m = parseInt(this.selDate.slice(5, 7), 10);
    const d = parseInt(this.selDate.slice(8, 10), 10);
    const names: string[] = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
    return `${m} 月 ${d} 日 ${names[new Date(y, m - 1, d).getDay()]}`;
  }

  /** 往选中的那天加一条（时间是可选，格式 HH:MM） */
  async addOnSelected(): Promise<void> {
    const title = this.calDraft.trim();
    if (title.length === 0) {
      this.message = '先写要做什么';
      return;
    }
    if (this.selDate.length === 0) {
      this.selDate = this.today;
    }
    await Db.addEvent({
      title: title,
      date: this.selDate,
      start_time: this.calTime.trim(),
      end_time: '',
    });
    this.calDraft = '';
    this.message = `已加到 ${this.selDate}`;
    await this.reloadDay();
    await this.reloadMonth();
    await this.reloadToday();
  }

  pad2(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }

  /** 打开「新建日程」弹出的表单（跟系统日历一样是从底部升起的整页） */
  openNewSheet(): void {
    this.editEventId = 0;
    this.editTitle = '';
    this.editDesc = '';
    this.editDate = this.selDate.length > 0 ? this.selDate : Db.today();
    this.editStart = '09:00';
    this.editEnd = '10:00';
    this.editAllDay = false;
    this.sheetOpen = true;
  }

  openEditSheet(row: EventRow): void {
    this.editEventId = row.id;
    this.editTitle = row.title;
    this.editDesc = row.description;
    this.editDate = row.date;
    this.editStart = row.start_time.length > 0 ? row.start_time : '09:00';
    this.editEnd = row.end_time.length > 0 ? row.end_time : '10:00';
    this.editAllDay = row.start_time.length === 0;
    this.sheetOpen = true;
  }

  cancelEdit(): void {
    this.sheetOpen = false;
    this.editEventId = 0;
  }

  pickEditDate(): void {
    const y = parseInt(this.editDate.slice(0, 4), 10);
    const m = parseInt(this.editDate.slice(5, 7), 10);
    const d = parseInt(this.editDate.slice(8, 10), 10);
    const selected = new Date(isNaN(y) ? 2026 : y, isNaN(m) ? 0 : m - 1, isNaN(d) ? 1 : d);
    DatePickerDialog.show({
      start: new Date(2020, 0, 1),
      end: new Date(2035, 11, 31),
      selected: selected,
      onDateAccept: (value: Date) => {
        this.editDate = `${value.getFullYear()}-${this.pad2(value.getMonth() + 1)}-${this.pad2(value.getDate())}`;
      },
    });
  }

  /** which: 1 = 开始，2 = 结束 */
  pickTime(which: number): void {
    const base = which === 1 ? this.editStart : this.editEnd;
    const hh = parseInt(base.slice(0, 2), 10);
    const mm = parseInt(base.slice(3, 5), 10);
    TimePickerDialog.show({
      selected: new Date(2026, 0, 1, isNaN(hh) ? 9 : hh, isNaN(mm) ? 0 : mm),
      useMilitaryTime: true,
      onAccept: (value: TimePickerResult) => {
        const t = `${this.pad2(value.hour)}:${this.pad2(value.minute)}`;
        if (which === 1) {
          this.editStart = t;
        } else {
          this.editEnd = t;
        }
      },
    });
  }

  async saveSheet(): Promise<void> {
    const title = this.editTitle.trim();
    if (title.length === 0) {
      this.message = '先写标题';
      return;
    }
    const date = this.editDate.length > 0 ? this.editDate : (this.selDate.length > 0 ? this.selDate : Db.today());
    const start = this.editAllDay ? '' : this.editStart;
    const end = this.editAllDay ? '' : this.editEnd;
    if (this.editEventId > 0) {
      const old = await Db.eventById(this.editEventId);
      const done = old !== null ? old.done : false;
      await Db.updateEventFields(this.editEventId, title, date, start, end, done, this.editDesc.trim());
      this.message = '已保存';
    } else {
      await Db.addEvent({
        title: title,
        date: date,
        start_time: start,
        end_time: end,
        description: this.editDesc.trim(),
      });
      this.message = `已加到 ${date}`;
    }
    this.sheetOpen = false;
    this.editEventId = 0;
    this.selDate = date;
    if (this.month !== date.slice(0, 7)) {
      this.month = date.slice(0, 7);
    }
    await this.reloadMonth();
    await this.reloadDay();
    await this.reloadToday();
  }

  async deleteEditEvent(): Promise<void> {
    if (this.editEventId === 0) {
      return;
    }
    await Db.deleteEvent(this.editEventId);
    this.editEventId = 0;
    this.sheetOpen = false;
    this.message = '已删除';
    await this.reloadDay();
    await this.reloadMonth();
    await this.reloadToday();
  }

  async toggleDayDone(row: EventRow): Promise<void> {
    await Db.setDone(row.id, !row.done);
    await this.reloadDay();
    await this.reloadMonth();
    await this.reloadToday();
  }

  /** 把系统日历里的事件导进 DanLume */
  async importCalendar(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      this.message = await importSystemCalendar(context);
    } catch (err) {
      this.message = `导入系统日历失败：${err}`;
    }
    try {
      promptAction.showToast({ message: this.message, duration: 3500 });
    } catch (e) {
      // 忽略
    }
    await this.reloadToday();
    await this.reloadMonth();
  }

  /** 把选中那天的日程写进系统日历 */
  async exportDayCalendar(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const date = this.selDate.length > 0 ? this.selDate : this.today;
      this.message = await exportDayToSystem(context, date);
    } catch (err) {
      this.message = `写入系统日历失败：${err}`;
    }
    try {
      promptAction.showToast({ message: this.message, duration: 3000 });
    } catch (e) {
      // 忽略
    }
    await this.reloadDay();
    await this.reloadMonth();
  }

  /** 从电脑端导出的 .dlpk 数据包导入日程 */
  async importComputer(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      this.message = await importDlpk(context);
    } catch (err) {
      this.message = `导入数据包失败：${err}`;
    }
    try {
      promptAction.showToast({ message: this.message, duration: 3500 });
    } catch (e) {
      // 忽略
    }
    await this.reloadToday();
    await this.reloadMonth();
  }

  shiftMonth(delta: number): void {
    const y = parseInt(this.month.slice(0, 4), 10);
    const m = parseInt(this.month.slice(5, 7), 10) + delta;
    const first = new Date(y, m - 1, 1);
    const yy = first.getFullYear();
    const mm = `${first.getMonth() + 1}`.padStart(2, '0');
    this.month = `${yy}-${mm}`;
    this.reloadMonth();
  }

  monthLabel(): string {
    return `${this.month.slice(0, 4)} 年 ${parseInt(this.month.slice(5, 7), 10)} 月`;
  }

  countOn(date: string): number {
    let count = 0;
    for (const row of this.monthRows) {
      if (row.date === date) {
        count += 1;
      }
    }
    return count;
  }

  /** 同一天里时间重叠 → 卡片右上角标「冲突」 */
  isConflict(row: EventRow): boolean {
    if (row.start_time.length === 0) {
      return false;
    }
    const aEnd = row.end_time.length > 0 ? row.end_time : row.start_time;
    if (aEnd === row.start_time) {
      return false;
    }
    for (const other of this.dayRows) {
      if (other.id === row.id || other.start_time.length === 0) {
        continue;
      }
      const bEnd = other.end_time.length > 0 ? other.end_time : other.start_time;
      if (bEnd === other.start_time) {
        continue;
      }
      if (row.start_time < bEnd && other.start_time < aEnd) {
        return true;
      }
    }
    return false;
  }

  /** 日历格子里最多画 3 个小点表示「这天有几条」 */
  dotsFor(count: number): number[] {
    const dots: number[] = [];
    const n = count > 3 ? 3 : count;
    for (let i = 0; i < n; i += 1) {
      dots.push(i);
    }
    return dots;
  }

  weekCells(): DayCell[] {
    const y = parseInt(this.month.slice(0, 4), 10);
    const m = parseInt(this.month.slice(5, 7), 10);
    const lead = new Date(y, m - 1, 1).getDay();
    const days = new Date(y, m, 0).getDate();
    const cells: DayCell[] = [];
    for (let i = 0; i < lead; i += 1) {
      cells.push({ day: 0, date: '', count: 0, inMonth: false, today: false });
    }
    const now = Db.today();
    for (let d = 1; d <= days; d += 1) {
      const date = `${this.month}-${`${d}`.padStart(2, '0')}`;
      cells.push({
        day: d,
        date: date,
        count: this.countOn(date),
        inMonth: true,
        today: date === now,
      });
    }
    return cells;
  }

  openDay(date: string): void {
    if (date.length === 0) {
      return;
    }
    this.today = date;
    this.currentTab = 0;
    this.reloadToday();
  }

  async reloadAccount(): Promise<void> {
    this.accountName = await Db.getSetting('server_username', '');
  }

  async reloadAi(): Promise<void> {
    this.serverUrl = await Db.getSetting('server_url', 'https://43.108.99.38.sslip.io');
    this.aiProfiles = await Api.aiProfiles();
    const active = await Api.activeProfile();
    this.aiActive = active !== null ? active.name : '';
    if (active !== null) {
      this.aiName = active.name;
      this.aiBase = active.base;
      this.aiModel = active.model;
      this.aiKey = active.key;
    }
    this.aiToolsOn = (await Db.getSetting('ai_tools_enabled', '0')) === '1';
    const flags: boolean[] = [];
    for (const name of PHONE_TOOL_NAMES) {
      flags.push((await Db.getSetting(toolKey(name), '1')) === '1');
    }
    this.toolOn = flags;
  }

  /** AI 工具总开关 */
  async setToolsOn(on: boolean): Promise<void> {
    this.aiToolsOn = on;
    await Db.setSetting('ai_tools_enabled', on ? '1' : '0');
    this.message = on ? 'AI 现在可以调用工具了' : 'AI 只聊天，不碰本地数据';
  }

  /** 单个工具开关 */
  async setToolOn(index: number, on: boolean): Promise<void> {
    const flags: boolean[] = [];
    for (let i = 0; i < this.toolOn.length; i += 1) {
      flags.push(i === index ? on : this.toolOn[i]);
    }
    this.toolOn = flags;
    if (index >= 0 && index < PHONE_TOOL_NAMES.length) {
      await Db.setSetting(toolKey(PHONE_TOOL_NAMES[index]), on ? '1' : '0');
    }
  }

 // ------------------------------------------------------------ 邮件
  async reloadMail(): Promise<void> {
    this.mailAddress = await Db.getSetting('mail_address', '');
    this.mailAuth = await Db.getSetting('mail_auth', '');
    this.mailSmtpHost = await Db.getSetting('mail_smtp_host', 'smtp.qq.com');
    this.mailSmtpPort = await Db.getSetting('mail_smtp_port', '465');
    this.mailImapHost = await Db.getSetting('mail_imap_host', 'imap.qq.com');
    this.mailImapPort = await Db.getSetting('mail_imap_port', '993');
  }

  /** 按邮箱域名填好 SMTP / IMAP 服务器（QQ、163、复旦、Gmail、Outlook） */
  applyMailPreset(): void {
    const addr = this.mailAddress.trim().toLowerCase();
    const at = addr.indexOf('@');
    const domain = at >= 0 ? addr.substring(at + 1) : '';
    if (domain === 'qq.com' || domain === 'foxmail.com') {
      this.mailSmtpHost = 'smtp.qq.com';
      this.mailSmtpPort = '465';
      this.mailImapHost = 'imap.qq.com';
      this.mailImapPort = '993';
      this.message = '已按 QQ 邮箱填好（授权码在 QQ 邮箱设置 → 账户里生成）';
    } else if (domain === '163.com' || domain === '126.com') {
      this.mailSmtpHost = domain === '126.com' ? 'smtp.126.com' : 'smtp.163.com';
      this.mailSmtpPort = '465';
      this.mailImapHost = domain === '126.com' ? 'imap.126.com' : 'imap.163.com';
      this.mailImapPort = '993';
      this.message = '已按网易邮箱填好（授权码在网页版设置里开启）';
    } else if (domain.endsWith('fudan.edu.cn')) {
      this.mailSmtpHost = 'smtp.fudan.edu.cn';
      this.mailSmtpPort = '465';
      this.mailImapHost = 'imap.fudan.edu.cn';
      this.mailImapPort = '993';
      this.message = '已按复旦邮箱填好（如果连不上，问一下信息办端口）';
    } else if (domain === 'gmail.com') {
      this.mailSmtpHost = 'smtp.gmail.com';
      this.mailSmtpPort = '465';
      this.mailImapHost = 'imap.gmail.com';
      this.mailImapPort = '993';
      this.message = '已按 Gmail 填好（需要应用专用密码）';
    } else if (domain === 'outlook.com' || domain === 'hotmail.com' || domain === 'live.com') {
      this.mailSmtpHost = 'smtp.office365.com';
      this.mailSmtpPort = '587';
      this.mailImapHost = 'outlook.office365.com';
      this.mailImapPort = '993';
      this.message = '已按 Outlook 填好；注意 587 是 STARTTLS，目前这版只支持 465 直连 TLS';
    } else if (domain.length > 0) {
      this.message = `不认识 ${domain} 的邮件服务器，请手动填 SMTP / IMAP`;
    } else {
      this.message = '先填完整邮箱地址';
    }
  }

  async saveMail(): Promise<void> {
    if (this.mailSmtpHost.trim().length === 0 || this.mailImapHost.trim().length === 0) {
      this.applyMailPreset();
    }
    await Db.setSetting('mail_address', this.mailAddress.trim());
    await Db.setSetting('mail_auth', this.mailAuth.trim());
    await Db.setSetting('mail_smtp_host', this.mailSmtpHost.trim());
    await Db.setSetting('mail_smtp_port', this.mailSmtpPort.trim());
    await Db.setSetting('mail_imap_host', this.mailImapHost.trim());
    await Db.setSetting('mail_imap_port', this.mailImapPort.trim());
    this.message = '邮箱设置已保存';
  }

  /** 发一封测试邮件到自己 */
  async testMail(): Promise<void> {
    if (this.mailBusy) {
      return;
    }
    this.mailBusy = true;
    this.message = '正在发测试邮件…';
    try {
      this.message = await sendMail(this.mailAddress.trim(), 'DanLume 测试邮件',
        '这是一封来自手机端 DanLume 的测试邮件。');
    } catch (err) {
      this.message = `发送失败：${err}`;
    }
    this.mailBusy = false;
  }

  async previewInbox(): Promise<void> {
    if (this.mailBusy) {
      return;
    }
    this.mailBusy = true;
    this.message = '正在读收件箱…';
    try {
      this.inboxList = await fetchInboxList(6);
      this.inboxDetail = '';
      this.message = this.inboxList.length > 0 ? `收件箱 ${this.inboxList.length} 封` : '收件箱是空的';
    } catch (err) {
      this.message = `读收件箱失败：${err instanceof Error ? err.message : err}`;
    }
    this.mailBusy = false;
  }

  async openMail(seq: number): Promise<void> {
    if (this.mailBusy) {
      return;
    }
    this.mailBusy = true;
    this.message = `正在读第 ${seq} 封…`;
    try {
      this.inboxDetail = await fetchMailBody(seq);
      this.message = '已打开';
    } catch (err) {
      this.message = `读邮件失败：${err instanceof Error ? err.message : err}`;
    }
    this.mailBusy = false;
  }

  async sendCompose(): Promise<void> {
    const to = this.mailTo.trim();
    if (to.length === 0) {
      this.message = '收件人为空';
      return;
    }
    if (this.mailBusy) {
      return;
    }
    this.mailBusy = true;
    this.message = '正在发送…';
    try {
      this.message = await sendMail(to, this.mailSubject.trim(), this.mailBody);
      this.mailBody = '';
    } catch (err) {
      this.message = `发送失败：${err instanceof Error ? err.message : err}`;
    }
    this.mailBusy = false;
  }

  /** 点列表里的一行：把它填进下面的编辑框 */
  pickAiProfile(index: number): void {
    if (index < 0 || index >= this.aiProfiles.length) {
      return;
    }
    const p = this.aiProfiles[index];
    this.aiEditIndex = index;
    this.aiName = p.name;
    this.aiBase = p.base;
    this.aiModel = p.model;
    this.aiKey = p.key;
  }

  /** 新增：清空编辑框，把编辑索引置为「新」 */
  newAiProfile(): void {
    this.aiEditIndex = -2;
    this.aiName = '';
    this.aiBase = 'https://api.deepseek.com/v1';
    this.aiModel = 'deepseek-chat';
    this.aiKey = '';
    this.message = '填好下面的字段后点「保存这组接口」';
  }

  /** 保存当前编辑框：编辑索引 >= 0 覆盖那一组，否则新增 */
  async saveAi(): Promise<void> {
    const server = this.serverUrl.trim().length > 0
      ? this.serverUrl.trim() : 'https://43.108.99.38.sslip.io';
    const base = this.aiBase.trim().length > 0 ? this.aiBase.trim() : 'https://api.deepseek.com/v1';
    const model = this.aiModel.trim().length > 0 ? this.aiModel.trim() : 'deepseek-chat';
    const name = this.aiName.trim().length > 0 ? this.aiName.trim() : model;
    this.serverUrl = server;
    this.aiBase = base;
    this.aiModel = model;
    this.aiName = name;
    await Db.setSetting('server_url', server);

    const list: AiProfile[] = [];
    for (const p of this.aiProfiles) {
      list.push(p);
    }
    const entry = new AiProfile(name, base, model, this.aiKey.trim());
    const isNew = this.aiEditIndex < 0;
    const oldName = (this.aiEditIndex >= 0 && this.aiEditIndex < list.length)
      ? list[this.aiEditIndex].name : '';
    if (this.aiEditIndex >= 0 && this.aiEditIndex < list.length) {
      list[this.aiEditIndex] = entry;
    } else {
      list.push(entry);
    }
    this.aiProfiles = list;
    await Api.saveAiProfiles(list);
    // 新加的一组、或改的正好是当前这组、或本来就没选，就切成它
    if (isNew || this.aiActive.length === 0 || this.aiActive === oldName) {
      await Api.setActiveProfile(name);
      this.aiActive = name;
    }
    this.aiEditIndex = -1;
    this.message = this.aiKey.trim().length > 0
      ? `已保存「${name}」（共 ${this.aiProfiles.length} 组）`
      : `已保存「${name}」，但还没填 API Key`;
  }

  async deleteAiProfile(index: number): Promise<void> {
    if (index < 0 || index >= this.aiProfiles.length) {
      return;
    }
    const gone = this.aiProfiles[index];
    const list: AiProfile[] = [];
    for (let i = 0; i < this.aiProfiles.length; i += 1) {
      if (i !== index) {
        list.push(this.aiProfiles[i]);
      }
    }
    this.aiProfiles = list;
    await Api.saveAiProfiles(list);
    if (this.aiActive === gone.name) {
      const next = list.length > 0 ? list[0].name : '';
      this.aiActive = next;
      await Api.setActiveProfile(next);
    }
    this.aiEditIndex = -1;
    this.message = `已删除「${gone.name}」`;
  }

  async switchAiProfile(name: string): Promise<void> {
    await Api.setActiveProfile(name);
    this.aiActive = name;
    this.message = `已切换到 ${name}`;
  }

  // ------------------------------------------------------------ 小工具
  async reloadTools(): Promise<void> {
    this.memos = await Db.memoSearch('', 8);
    this.countdowns = await Db.countdownList(8);
    this.flashTotal = await Db.countFast('SELECT COUNT(*) FROM flashcards');
  }

  async addMemoQuick(): Promise<void> {
    const text = this.memoDraft.trim();
    if (text.length === 0) {
      this.message = '先写点内容';
      return;
    }
    await Db.memoAdd(text);
    this.memoDraft = '';
    this.message = '备忘已记录';
    await this.reloadTools();
  }

  async addCountdownQuick(): Promise<void> {
    const title = this.cdTitle.trim();
    const date = this.cdDate.trim();
    if (title.length === 0 || date.length === 0) {
      this.message = '倒计时要名字和日期（YYYY-MM-DD）';
      return;
    }
    await Db.countdownAdd(title, date);
    this.cdTitle = '';
    this.cdDate = '';
    this.message = '倒计时已加';
    await this.reloadTools();
  }

  async nextFlashcard(): Promise<void> {
    const card = await Db.flashcardRandom();
    if (card.length === 0) {
      this.message = '还没有闪卡，让梅子生成一些';
      return;
    }
    this.flashQ = card[0];
    this.flashA = card[1];
    this.flashReveal = false;
  }

  startPomodoro(): void {
    if (this.pomoOn) {
      return;
    }
    this.pomoOn = true;
    this.pomoLeft = 25 * 60;
    this.pomoTimer = setInterval(() => {
      if (this.pomoLeft <= 1) {
        this.stopPomodoro();
        this.message = '番茄钟结束，休息一下';
        try {
          promptAction.showToast({ message: '番茄钟结束，休息一下', duration: 3000 });
        } catch (e) {
          // 忽略
        }
        return;
      }
      this.pomoLeft -= 1;
    }, 1000);
  }

  stopPomodoro(): void {
    if (this.pomoTimer >= 0) {
      clearInterval(this.pomoTimer);
      this.pomoTimer = -1;
    }
    this.pomoOn = false;
    this.pomoLeft = 0;
  }

  pomoText(): string {
    return `${this.pad2(Math.floor(this.pomoLeft / 60))}:${this.pad2(this.pomoLeft % 60)}`;
  }

  async removeEvent(id: number): Promise<void> {
    await Db.deleteEvent(id);
    this.message = '已删除';
    await this.reloadToday();
  }

  async saveEdit(id: number): Promise<void> {
    const title = this.editingTitle.trim();
    if (title.length > 0) {
      await Db.renameEvent(id, title);
    }
    this.editingId = 0;
    this.editingTitle = '';
    await this.reloadToday();
  }

  /** 给这一天的日程设/取消系统提醒（reminderAgent，到点弹系统通知） */
  async toggleReminder(item: EventItem): Promise<void> {
    if (item.reminderId > 0) {
      try {
        await reminderAgentManager.cancelReminder(item.reminderId);
      } catch (err) {
        // 提醒可能已经被系统清理；本地标记照样清掉
      }
      await Db.setReminderId(item.id, 0);
      this.message = '已取消提醒';
      await this.reloadToday();
      return;
    }
    const start = item.start.length >= 5 ? item.start : '09:00';
    const y = parseInt(this.today.slice(0, 4), 10);
    const m = parseInt(this.today.slice(5, 7), 10);
    const d = parseInt(this.today.slice(8, 10), 10);
    const hour = parseInt(start.slice(0, 2), 10);
    const minute = parseInt(start.slice(3, 5), 10);
    const context = getContext(this) as common.UIAbilityContext;
    try {
      await notificationManager.requestEnableNotification(context);
    } catch (err) {
      // 用户拒绝通知权限时发布提醒会失败，下面会给出提示
    }
    const request: reminderAgentManager.ReminderRequestCalendar = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
      dateTime: { year: y, month: m, day: d, hour: hour, minute: minute, second: 0 },
      title: '日程提醒',
      content: item.title,
      expiredContent: item.title,
      snoozeTimes: 0,
      ringDuration: 5,
      wantAgent: { pkgName: 'com.danlume.app.harmony', abilityName: 'EntryAbility' },
    };
    try {
      const reminderId = await reminderAgentManager.publishReminder(request);
      await Db.setReminderId(item.id, reminderId);
      this.message = `已设提醒 ${start}`;
    } catch (err) {
      this.message = `设提醒失败：${err}`;
    }
    await this.reloadToday();
  }

  /** 选一个日期看当天日程（不选就一直看今天） */
  pickDate(): void {
    DatePickerDialog.show({
      start: new Date('2020-01-01'),
      end: new Date('2035-12-31'),
      selected: new Date(this.today),
      onDateAccept: (value: Date) => {
        const y = value.getFullYear();
        const m = `${value.getMonth() + 1}`.padStart(2, '0');
        const d = `${value.getDate()}`.padStart(2, '0');
        this.today = `${y}-${m}-${d}`;
        this.reloadToday();
      },
    });
  }

  async addQuickEvent(): Promise<void> {
    const title = this.todayDraft.trim();
    if (title.length === 0) {
      this.message = '先写个标题';
      return;
    }
    await Db.addEvent({ title: title, date: this.today });
    this.todayDraft = '';
    this.message = '已加进今天';
    await this.reloadToday();
  }

  async toggleDone(id: number, done: boolean): Promise<void> {
    await Db.setDone(id, !done);
    await this.reloadToday();
  }

  async askMeizi(): Promise<void> {
    const text = this.chatDraft.trim();
    if (text.length === 0 || this.asking) {
      return;
    }
    this.asking = true;
    this.message = '';
    const history: string[] = [];
    for (const line of this.chat) {
      if (line.role === 'user') {
        history.push(line.text);
      }
    }
    this.chat.push({ role: 'user', text: text });
    this.chatDraft = '';
    try {
      const answer = await Api.chat(text, history);
      this.chat.push({ role: 'assistant', text: answer });
    } catch (err) {
      this.chat.push({ role: 'assistant', text: `出错了：${err}` });
    } finally {
      this.asking = false;
    }
  }

  async doLogin(): Promise<void> {
    const user = this.loginUser.trim();
    const pwd = this.loginPwd;
    if (user.length === 0 || pwd.length === 0) {
      this.message = '用户名和密码都要填';
      return;
    }
    try {
      const result = await Api.login(user, pwd);
      this.accountName = result.username;
      this.message = `已登录 ${result.username}`;
      this.loginPwd = '';
    } catch (err) {
      this.message = `登录失败：${err}`;
    }
  }

  /** 多端同步：把本地改动推上去，同时拉回别的设备的改动 */
  async doSync(): Promise<void> {
    if (this.syncing) {
      return;
    }
    this.syncing = true;
    this.message = '正在同步…';
    try {
      this.message = await syncEvents();
    } catch (err) {
      this.message = `同步失败：${err}`;
    }
    this.syncing = false;
    await this.reloadToday();
    await this.reloadMonth();
    await this.reloadDay();
  }

  async pullAnnouncements(): Promise<void> {
    const items = await Api.announcements(0);
    const rows: NoticeItem[] = [];
    for (const item of items) {
      const obj = item as Record<string, Object>;
      const idText = `${obj['id'] ?? ''}`;
      const id = parseInt(idText, 10);
      rows.push({
        id: isNaN(id) ? 0 : id,
        title: `${obj['title'] ?? ''}`,
        body: `${obj['body'] ?? ''}`,
        created_at: `${obj['created_at'] ?? ''}`,
      });
    }
    this.notices = rows;
    this.message = rows.length > 0 ? `拉到 ${rows.length} 条公告` : '没有新公告';
  }

  async searchPapers(): Promise<void> {
    const query = this.paperQuery.trim();
    if (query.length === 0) {
      this.message = '先输入检索词（英文效果更好）';
      return;
    }
    this.paperBusy = true;
    this.message = '正在检索 arXiv…';
    try {
      this.papers = await Api.arxivSearch(query, 8);
      this.message = this.papers.length > 0
        ? `找到 ${this.papers.length} 篇`
        : '没找到结果（换英文关键词试试）';
    } catch (err) {
      this.message = `检索失败：${err}`;
    } finally {
      this.paperBusy = false;
    }
  }

  /** 用系统浏览器打开 PDF / 原文（不需要额外权限） */
  openLink(url: string): void {
    if (url.length === 0) {
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    context.startAbility({
      action: 'ohos.want.action.viewData',
      uri: url,
    }).catch((err: Error) => {
      this.message = `打不开链接：${err.message}`;
    });
  }

  clearChat(): void {
    this.chat = [];
    this.message = '对话已清空';
  }

  copyText(text: string): void {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      this.message = '已复制';
      try {
        promptAction.showToast({ message: '已复制', duration: 1200 });
      } catch (e) {
        // 弹 toast 失败不影响复制本身
      }
    }).catch((err: Error) => {
      this.message = `复制失败：${err.message}`;
      try {
        promptAction.showToast({ message: `复制失败：${err.message}`, duration: 2000 });
      } catch (e) {
        // 同上
      }
    });
  }

  /** 重新生成上一条回答（保留问题，去掉末尾那条助手回复） */
  async regenerate(): Promise<void> {
    if (this.asking) {
      return;
    }
    let lastUser = '';
    for (let i = this.chat.length - 1; i >= 0; i -= 1) {
      if (this.chat[i].role === 'user') {
        lastUser = this.chat[i].text;
        break;
      }
    }
    if (lastUser.length === 0) {
      return;
    }
    if (this.chat.length > 0 && this.chat[this.chat.length - 1].role === 'assistant') {
      this.chat.pop();
    }
    try {
      promptAction.showToast({ message: '正在重新生成…', duration: 1200 });
    } catch (e) {
      // 忽略
    }
    const history: string[] = [];
    for (const line of this.chat) {
      if (line.role === 'user') {
        history.push(line.text);
      }
    }
    this.asking = true;
    try {
      const answer = await Api.chat(lastUser, history);
      this.chat.push({ role: 'assistant', text: answer });
    } catch (err) {
      this.chat.push({ role: 'assistant', text: `出错了：${err}` });
    } finally {
      this.asking = false;
    }
  }

  /** 附件：选一个本地文本文件，读进输入框（也留一份在应用目录，方便 fs_read） */
  async pickAttachment(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      const documentPicker = new picker.DocumentViewPicker(context);
      const uris = await documentPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      const uri = uris[0];
      const parts = uri.split('/');
      const name = parts.length > 0 ? parts[parts.length - 1] : 'attachment.txt';
      const src = fsKit.openSync(uri, fsKit.OpenMode.READ_ONLY);
      const dest = `${context.filesDir}/${name}`;
      fsKit.copyFileSync(src.fd, dest);
      fsKit.closeSync(src);
      const text = fsKit.readTextSync(dest);
      const clipped = text.length > 8000 ? `${text.substring(0, 8000)}…（已截断）` : text;
      this.chatDraft = `【附件 ${name}】\n${clipped}\n\n`;
      this.message = `已读取附件 ${name}`;
    } catch (err) {
      this.message = `读附件失败：${err}`;
    }
  }

  /** 语音输入：华为 Core Speech Kit（离线中文），结果直接填进输入框 */
  async toggleVoice(): Promise<void> {
    if (this.listening) {
      if (this.asrEngine !== null) {
        this.asrEngine.cancel('danlume-asr');
      }
      this.listening = false;
      this.message = '已停止语音输入';
      return;
    }
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const atManager = abilityAccessCtrl.createAtManager();
      const wanted: Permissions[] = ['ohos.permission.MICROPHONE'];
      const result = await atManager.requestPermissionsFromUser(context, wanted);
      if (result.authResults.length === 0 || result.authResults[0] !== 0) {
        this.message = '没有麦克风权限，没法语音输入';
        return;
      }
      if (this.asrEngine === null) {
        const extra: Record<string, Object> = {
          'locate': 'CN',
          'recognizerMode': 'short',
        };
        const params: speechRecognizer.CreateEngineParams = {
          language: 'zh-CN',
          online: 1,
          extraParams: extra,
        };
        this.asrEngine = await speechRecognizer.createEngine(params);
        this.asrEngine.setListener({
          onStart: (sessionId: string, eventMessage: string) => {
            this.listening = true;
            this.message = '正在听…再点麦克风结束';
          },
          onEvent: (sessionId: string, eventCode: number, eventMessage: string) => {
          },
          onResult: (sessionId: string, recognition: speechRecognizer.SpeechRecognitionResult) => {
            if (recognition.result.trim().length > 0) {
              this.chatDraft = recognition.result;
            }
          },
          onComplete: (sessionId: string, eventMessage: string) => {
            this.listening = false;
          },
          onError: (sessionId: string, errorCode: number, errorMessage: string) => {
            this.listening = false;
            this.message = `语音识别失败（${errorCode}）`;
          },
        });
      }
      const audio: speechRecognizer.AudioInfo = {
        audioType: 'pcm',
        sampleRate: 16000,
        soundChannel: 1,
        sampleBit: 16,
      };
      const startExtra: Record<string, Object> = {
        'recognitionMode': 0,
        'vadBegin': 2000,
        'vadEnd': 3000,
        'maxAudioDuration': 30000,
      };
      const startParams: speechRecognizer.StartParams = {
        sessionId: 'danlume-asr',
        audioInfo: audio,
        extraParams: startExtra,
      };
      this.asrEngine.startListening(startParams);
      this.listening = true;
      this.message = '正在听…再点麦克风结束';
    } catch (err) {
      this.listening = false;
      this.message = `语音输入不可用：${err}`;
    }
  }

  // ------------------------------------------------------------ 界面
  @Builder
  todayTab() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text(this.today).fontSize(13).fontColor('#8a8f98').layoutWeight(1)
        Button('今天')
          .height(28)
          .fontSize(12)
          .backgroundColor('#eeeeee')
          .fontColor('#2b2f36')
          .onClick(() => {
            this.today = Db.today();
            this.reloadToday();
          })
        Button('选日期')
          .height(28)
          .fontSize(12)
          .backgroundColor('#eeeeee')
          .fontColor('#2b2f36')
          .onClick(() => { this.pickDate(); })
      }
      .width('100%')
      Row({ space: 8 }) {
        TextInput({ text: this.todayDraft, placeholder: '今天要做的事…' })
          .layoutWeight(1)
          .height(40)
          .borderRadius(10)
          .onChange((value: string) => { this.todayDraft = value; })
        Button('加进日程')
          .height(40)
          .backgroundColor('#c8546a')
          .onClick(() => { void this.addQuickEvent(); })
      }
      .width('100%')

      Row({ space: 10 }) {
        Text('番茄钟').fontSize(13).fontColor('#5c6270')
        Text(this.pomoOn ? this.pomoText() : '25:00')
          .fontSize(16)
          .fontWeight(600)
          .fontColor(this.pomoOn ? '#c8546a' : '#9a9aa2')
          .layoutWeight(1)
          .textAlign(TextAlign.End)
        Button(this.pomoOn ? '停止' : '开始')
          .height(34)
          .fontSize(12)
          .backgroundColor(this.pomoOn ? '#FBE9EC' : '#eeeeee')
          .fontColor(this.pomoOn ? '#c8546a' : '#2b2f36')
          .onClick(() => {
            if (this.pomoOn) {
              this.stopPomodoro();
            } else {
              this.startPomodoro();
            }
          })
      }
      .width('100%')

      if (this.message.length > 0) {
        Text(this.message).fontSize(12).fontColor('#c8546a').width('100%')
      }

      List({ space: 8 }) {
        ForEach(this.events, (item: EventItem) => {
          ListItem() {
            Row({ space: 10 }) {
              Text(item.done ? '✓' : '○')
                .fontSize(16)
                .fontColor(item.done ? '#3f9e6a' : '#8a8f98')
                .onClick(() => { void this.toggleDone(item.id, item.done); })
              Column({ space: 2 }) {
                if (this.editingId === item.id) {
                  TextInput({ text: this.editingTitle })
                    .height(32)
                    .width('100%')
                    .borderRadius(8)
                    .onChange((value: string) => { this.editingTitle = value; })
                } else {
                  Text(item.title).fontSize(15).decoration({ type: item.done ? TextDecorationType.LineThrough : TextDecorationType.None })
                }
                if (item.start.length > 0) {
                  Text(item.start).fontSize(12).fontColor('#8a8f98')
                }
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              if (this.editingId === item.id) {
                Text('保存')
                  .fontSize(12)
                  .fontColor('#3f9e6a')
                  .padding({ left: 6, right: 2 })
                  .onClick(() => { void this.saveEdit(item.id); })
                Text('取消')
                  .fontSize(12)
                  .fontColor('#8a8f98')
                  .padding({ left: 6, right: 2 })
                  .onClick(() => {
                    this.editingId = 0;
                    this.editingTitle = '';
                  })
              } else {
                Text(item.reminderId > 0 ? '取消提醒' : '提醒')
                  .fontSize(12)
                  .fontColor(item.reminderId > 0 ? '#c8546a' : '#3f9e6a')
                  .padding({ left: 6, right: 2 })
                  .onClick(() => { void this.toggleReminder(item); })
                Text('编辑')
                  .fontSize(12)
                  .fontColor('#8a8f98')
                  .padding({ left: 6, right: 2 })
                  .onClick(() => {
                    this.editingId = item.id;
                    this.editingTitle = item.title;
                  })
                Text('删除')
                  .fontSize(12)
                  .fontColor('#c8546a')
                  .padding({ left: 6, right: 2 })
                  .onClick(() => { void this.removeEvent(item.id); })
              }
            }
            .width('100%')
            .padding(12)
            .borderRadius(12)
            .backgroundColor('#F7F7FA')
          }
        }, (item: EventItem) => `${item.id}`)
      }
      .layoutWeight(1)
      .width('100%')
    }
    .padding(16)
    .width('100%')
    .height('100%')
  }

  /** 行内样式：粗体 / 斜体 / 行内代码（一行文字里的 span 拼起来） */
  @Builder
  richSpans(spans: MdSpan[], size: number, color: string, heading: boolean) {
    Text() {
      ForEach(spans, (s: MdSpan, i: number) => {
        Span(s.text)
          .fontSize(s.code ? size - 1 : size)
          .fontColor(s.code ? '#c8546a' : color)
          .fontWeight(s.bold || heading ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(s.italic ? FontStyle.Italic : FontStyle.Normal)
          .textBackgroundStyle(s.code
            ? { color: '#F2F2F7', radius: 4 } as TextBackgroundStyle
            : { color: Color.Transparent, radius: 0 } as TextBackgroundStyle)
      }, (s: MdSpan, i: number) => `${i}-${s.text.length}`)
    }
    .lineHeight(size * 1.65)
    .width('100%')
  }

  /** Markdown 渲染：标题 / 段落 / 列表 / 引用 / 分隔线 / 代码块 */
  @Builder
  mdView(src: string) {
    Column({ space: 9 }) {
      ForEach(parseMarkdown(src), (b: MdBlock, idx: number) => {
        if (b.kind === MdKind.Code) {
          Column() {
            Row({ space: 8 }) {
              Text(b.lang.length > 0 ? b.lang : '代码')
                .fontSize(11)
                .fontColor('#8a8f98')
                .layoutWeight(1)
              Column() {
                Image($r('app.media.md_copy'))
                  .width(15)
                  .height(15)
                  .fillColor('#8a8f98')
              }
              .width(30)
              .height(24)
              .justifyContent(FlexAlign.Center)
              .onClick(() => { this.copyText(b.code); })
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 6 })

            Scroll() {
              Text(b.code)
                .fontSize(13)
                .lineHeight(19)
                .fontColor('#1f2328')
                .fontFamily('monospace')
                .padding({ left: 12, right: 12, bottom: 12 })
                .textAlign(TextAlign.Start)
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .align(Alignment.TopStart)
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .backgroundColor('#F4F4F7')
          .borderRadius(12)
        } else if (b.kind === MdKind.Rule) {
          Divider().color('#E5E7EB')
        } else if (b.kind === MdKind.Bullet || b.kind === MdKind.Ordered) {
          Row({ space: 8 }) {
            Text(b.marker)
              .fontSize(15)
              .lineHeight(15 * 1.65)
              .fontColor('#2b2f36')
            Column() {
              this.richSpans(b.spans, 15, '#2b2f36', false)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .padding({ left: 2 })
        } else if (b.kind === MdKind.Quote) {
          Column() {
            this.richSpans(b.spans, 14, '#5c6270', false)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 10, top: 2, bottom: 2 })
          .border({ width: { left: 3 }, color: '#E3E4E8' })
        } else if (b.kind === MdKind.Heading) {
          Column() {
            this.richSpans(b.spans, b.level <= 2 ? 19 : 16, '#2b2f36', true)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .margin({ top: idx === 0 ? 0 : 4 })
        } else {
          Column() {
            this.richSpans(b.spans, 15, '#2b2f36', false)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
      }, (b: MdBlock, idx: number) => `${idx}-${b.kind}-${b.code.length}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 顶栏「梅子 ›」点开的下拉：切换用哪组接口 */
  @Builder
  modelMenuBuilder() {
    Column({ space: 2 }) {
      if (this.aiProfiles.length === 0) {
        Row() {
          Text('还没有配置接口').fontSize(13).fontColor('#8a8f98')
        }
        .width(220)
        .padding(12)
      }
      ForEach(this.aiProfiles, (p: AiProfile, i: number) => {
        Row({ space: 8 }) {
          Column({ space: 1 }) {
            Text(p.name)
              .fontSize(14)
              .fontColor(p.name === this.aiActive ? '#c8546a' : '#1f2328')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(p.model.length > 0 ? p.model : '未填模型')
              .fontSize(11)
              .fontColor('#9a9aa2')
              .maxLines(1)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          if (p.name === this.aiActive) {
            Text('✓').fontSize(13).fontColor('#c8546a')
          }
        }
        .width(220)
        .padding({ left: 12, right: 12, top: 9, bottom: 9 })
        .borderRadius(8)
        .onClick(() => { void this.switchAiProfile(p.name); })
      }, (p: AiProfile, i: number) => `${i}-${p.name}`)
      Divider().color('#EEEEF1')
      Row() {
        Text('管理接口…').fontSize(13).fontColor('#5c6270')
      }
      .width(220)
      .padding({ left: 12, right: 12, top: 9, bottom: 9 })
      .borderRadius(8)
      .onClick(() => {
        this.currentTab = 4;
        this.message = '在「我的」里新增 / 修改接口';
      })
    }
    .width(220)
    .padding(6)
    .borderRadius(14)
    .backgroundColor(Color.White)
    .shadow({ radius: 18, color: '#1F2A2A40', offsetY: 6 })
  }

  @Builder
  chatTab() {
    // 列表在底层、输入框浮在上面：文字从半透明输入框底下滚过去，才不会出现「纯色块盖住文字」
    Stack({ alignContent: Alignment.Bottom }) {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text('☰')
            .fontSize(22)
            .fontColor('#1f2328')
            .width(38)
            .height(38)
            .textAlign(TextAlign.Center)
            .onClick(() => { this.message = '历史聊天：下一步接 chat_sessions'; })
          Row({ space: 4 }) {
            Text('梅子').fontSize(16).fontWeight(600).fontColor('#1f2328')
            Text('›').fontSize(18).fontColor('#9a9aa2')
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .bindMenu(this.modelMenuBuilder)
          Text('✎')
            .fontSize(20)
            .fontColor('#1f2328')
            .width(38)
            .height(38)
            .textAlign(TextAlign.Center)
            .onClick(() => { this.clearChat(); })
        }
        .width('100%')

        if (this.chat.length === 0) {
          Column({ space: 8 }) {
            Text('LUME')
              .fontSize(36)
              .fontWeight(700)
              .letterSpacing(6)
              .fontColor('#2b2f36')
            Text('有什么可以帮你？').fontSize(22).fontWeight(600).fontColor('#2b2f36')
            Text('问日程、作业、文献，或直接说「帮我写…」').fontSize(13).fontColor('#8a8f98')
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .width('100%')
        } else {
          List({ space: 12 }) {
            ForEach(this.chat, (line: ChatLine, index: number) => {
              ListItem() {
                Column({ space: 4 }) {
                  Row() {
                    if (line.role === 'user') {
                      Text(line.text)
                        .fontSize(15)
                        .lineHeight(22)
                        .fontColor('#1f2328')
                        .padding(12)
                        .borderRadius(20)
                        .backgroundColor('#F1F1F3')
                        .constraintSize({ maxWidth: '84%' })
                    } else {
                      Column() {
                        this.mdView(line.text)
                      }
                      .width('100%')
                      .alignItems(HorizontalAlign.Start)
                    }
                  }
                  .width('100%')
                  .justifyContent(line.role === 'user' ? FlexAlign.End : FlexAlign.Start)
                  if (line.role === 'assistant') {
                    Row({ space: 6 }) {
                      Column() {
                        Image($r('app.media.md_copy')).width(16).height(16).fillColor('#8a8f98')
                      }
                      .width(32)
                      .height(32)
                      .borderRadius(16)
                      .justifyContent(FlexAlign.Center)
                      .onClick(() => { this.copyText(line.text); })
                      Column() {
                        Image($r('app.media.md_refresh')).width(16).height(16).fillColor('#8a8f98')
                      }
                      .width(32)
                      .height(32)
                      .borderRadius(16)
                      .justifyContent(FlexAlign.Center)
                      .onClick(() => { void this.regenerate(); })
                    }
                    .width('100%')
                    .margin({ top: 2 })
                  }
                }
                .width('100%')
              }
            }, (line: ChatLine, index: number) => `${index}`)
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ bottom: 86 })
        }
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16, top: 12 })
      .alignItems(HorizontalAlign.Start)

      Column() {
        Stack() {
          Row() {}
            .width('100%')
            .height(54)
            .borderRadius(27)
            .backgroundColor('#CCFFFFFF')
            .border({ width: 1, color: '#E9E9EE' })
            .shadow({ radius: 12, color: '#102A2A40', offsetY: 2 })
          Row({ space: 4 }) {
            Text('+')
              .fontSize(24)
              .fontColor('#3a3a40')
              .width(38)
              .height(38)
              .textAlign(TextAlign.Center)
              .onClick(() => { void this.pickAttachment(); })
            TextInput({ text: this.chatDraft, placeholder: 'Ask 梅子…' })
              .layoutWeight(1)
              .height(44)
              .fontSize(15)
              .backgroundColor(Color.Transparent)
              .onChange((value: string) => { this.chatDraft = value; })
            Text(this.listening ? '停' : '语音')
              .fontSize(this.listening ? 14 : 12)
              .fontColor(this.listening ? '#c8546a' : '#3a3a40')
              .width(38)
              .height(38)
              .textAlign(TextAlign.Center)
              .onClick(() => { void this.toggleVoice(); })
            Stack() {
              Row() {}
                .width(34)
                .height(34)
                .borderRadius(17)
                .backgroundColor(this.chatDraft.trim().length > 0 ? '#c8546a' : '#D9D9DE')
              Text(this.asking ? '…' : '↑').fontSize(17).fontColor('#FFFFFF')
            }
            .width(34)
            .height(34)
            .margin({ right: 4 })
            .onClick(() => {
              if (!this.asking) {
                void this.askMeizi();
              }
            })
          }
          .width('100%')
          .padding({ left: 8, right: 8 })
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 12, right: 12, bottom: 8 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  meTab() {
    Column({ space: 12 }) {
      if (this.message.length > 0) {
        Text(this.message).fontSize(12).fontColor('#c8546a').width('100%')
      }
      Text(this.accountName.length > 0 ? `已登录：${this.accountName}` : '还没登录账号')
        .fontSize(14)
        .width('100%')
      Text('用 DanLume 账号登录；忘记密码可用注册邮箱在网页版找回')
        .fontSize(12)
        .fontColor('#8a8f98')
        .width('100%')
      TextInput({ text: this.loginUser, placeholder: '学号 / 用户名' })
        .height(40)
        .width('100%')
        .borderRadius(10)
        .onChange((value: string) => { this.loginUser = value; })
      TextInput({ text: this.loginPwd, placeholder: '密码' })
        .type(InputType.Password)
        .height(40)
        .width('100%')
        .borderRadius(10)
        .onChange((value: string) => { this.loginPwd = value; })
      Row({ space: 8 }) {
        Button('登录')
          .layoutWeight(1)
          .height(40)
          .backgroundColor('#c8546a')
          .onClick(() => { void this.doLogin(); })
      }
      .width('100%')

      Button('拉一次公告')
        .height(40)
        .width('100%')
        .backgroundColor('#eeeeee')
        .fontColor('#2b2f36')
        .onClick(() => { void this.pullAnnouncements(); })

      Button(this.syncing ? '同步中…' : '同步日程到云端')
        .height(40)
        .width('100%')
        .backgroundColor('#eeeeee')
        .fontColor('#2b2f36')
        .onClick(() => { void this.doSync(); })

      Text('服务器地址')
        .fontSize(13)
        .fontWeight(500)
        .width('100%')
      TextInput({ text: this.serverUrl, placeholder: 'https://43.108.99.38.sslip.io' })
        .height(40)
        .width('100%')
        .borderRadius(10)
        .onChange((value: string) => { this.serverUrl = value; })

      Text('AI 接口（OpenAI 兼容，可以存多组，聊天页顶部切换）')
        .fontSize(13)
        .fontWeight(500)
        .width('100%')

      ForEach(this.aiProfiles, (p: AiProfile, i: number) => {
        Row({ space: 8 }) {
          Column({ space: 2 }) {
            Text(p.name).fontSize(14).fontColor('#1f2328').width('100%')
            Text(p.model.length > 0 ? p.model : '未填模型')
              .fontSize(11)
              .fontColor('#9a9aa2')
              .maxLines(1)
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          if (p.name === this.aiActive) {
            Text('当前').fontSize(11).fontColor('#c8546a')
          }
          Text('编辑')
            .fontSize(12)
            .fontColor('#5c6270')
            .padding(4)
            .onClick(() => { this.pickAiProfile(i); })
          Text('删除')
            .fontSize(12)
            .fontColor('#c8546a')
            .padding(4)
            .onClick(() => { void this.deleteAiProfile(i); })
        }
        .width('100%')
        .padding(10)
        .borderRadius(10)
        .backgroundColor('#F7F7FA')
      }, (p: AiProfile, i: number) => `${i}-${p.name}`)

      Button('＋ 新增一组接口')
        .height(36)
        .width('100%')
        .backgroundColor('#F2F2F4')
        .fontColor('#2b2f36')
        .onClick(() => { this.newAiProfile(); })

      Text(this.aiEditIndex !== -1 ? '正在编辑（改完点下面的保存）' : '点上面的「编辑 / 新增」再改字段')
        .fontSize(11)
        .fontColor('#8a8f98')
        .width('100%')
      TextInput({ text: this.aiName, placeholder: '名字，如「DeepSeek」' })
        .height(40)
        .width('100%')
        .borderRadius(10)
        .onChange((value: string) => { this.aiName = value; })
      TextInput({ text: this.aiBase, placeholder: '接口地址，如 https://api.deepseek.com/v1' })
        .height(40)
        .width('100%')
        .borderRadius(10)
        .onChange((value: string) => { this.aiBase = value; })
      TextInput({ text: this.aiModel, placeholder: '模型名，如 deepseek-chat' })
        .height(40)
        .width('100%')
        .borderRadius(10)
        .onChange((value: string) => { this.aiModel = value; })
      TextInput({ text: this.aiKey, placeholder: 'API Key' })
        .type(InputType.Password)
        .height(40)
        .width('100%')
        .borderRadius(10)
        .onChange((value: string) => { this.aiKey = value; })
      Button('保存这组接口')
        .height(40)
        .width('100%')
        .backgroundColor('#eeeeee')
        .fontColor('#2b2f36')
        .onClick(() => { void this.saveAi(); })

      Divider().color('#EFEFF3')

      Row({ space: 10 }) {
        Column({ space: 2 }) {
          Text('允许 AI 调用工具').fontSize(13).fontWeight(500).fontColor('#1f2328')
          Text('关掉就只聊天，不动你的日程和设置').fontSize(11).fontColor('#8a8f98')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.aiToolsOn })
          .selectedColor('#c8546a')
          .onChange((on: boolean) => { void this.setToolsOn(on); })
      }
      .width('100%')

      if (this.aiToolsOn) {
        Column({ space: 4 }) {
          ForEach(PHONE_TOOL_NAMES, (name: string, i: number) => {
            Row({ space: 8 }) {
              Text(TOOL_LABELS[i])
                .fontSize(12)
                .fontColor('#3a3a40')
                .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.toolOn[i] === true })
                .selectedColor('#c8546a')
                .onChange((on: boolean) => { void this.setToolOn(i, on); })
            }
            .width('100%')
            .padding({ top: 2, bottom: 2 })
          }, (name: string) => name)
        }
        .width('100%')
        .padding(10)
        .borderRadius(10)
        .backgroundColor('#F7F7FA')
      }

      Divider().color('#EFEFF3')
      Text('邮件')
        .fontSize(13)
        .fontWeight(500)
        .width('100%')
      TextInput({ text: this.mailAddress, placeholder: '邮箱地址，如 xxx@qq.com' })
        .height(40)
        .width('100%')
        .borderRadius(10)
        .onChange((v: string) => { this.mailAddress = v; })
      TextInput({ text: this.mailAuth, placeholder: '授权码（QQ/163 不是登录密码）' })
        .type(InputType.Password)
        .height(40)
        .width('100%')
        .borderRadius(10)
        .onChange((v: string) => { this.mailAuth = v; })
      Row({ space: 8 }) {
        Text('QQ / 163 / 复旦 / Gmail 可一键填服务器')
          .fontSize(11)
          .fontColor('#8a8f98')
          .layoutWeight(1)
        Button('自动填服务器')
          .height(32)
          .fontSize(12)
          .backgroundColor('#FBE9EC')
          .fontColor('#c8546a')
          .onClick(() => { this.applyMailPreset(); })
      }
      .width('100%')
      Row({ space: 8 }) {
        TextInput({ text: this.mailSmtpHost, placeholder: 'SMTP 服务器' })
          .layoutWeight(1)
          .height(40)
          .borderRadius(10)
          .onChange((v: string) => { this.mailSmtpHost = v; })
        TextInput({ text: this.mailSmtpPort, placeholder: '465' })
          .width(70)
          .height(40)
          .borderRadius(10)
          .onChange((v: string) => { this.mailSmtpPort = v; })
      }
      .width('100%')
      Row({ space: 8 }) {
        TextInput({ text: this.mailImapHost, placeholder: 'IMAP 服务器' })
          .layoutWeight(1)
          .height(40)
          .borderRadius(10)
          .onChange((v: string) => { this.mailImapHost = v; })
        TextInput({ text: this.mailImapPort, placeholder: '993' })
          .width(70)
          .height(40)
          .borderRadius(10)
          .onChange((v: string) => { this.mailImapPort = v; })
      }
      .width('100%')
      Row({ space: 8 }) {
        Button('保存邮箱')
          .layoutWeight(1)
          .height(38)
          .fontSize(12)
          .backgroundColor('#eeeeee')
          .fontColor('#2b2f36')
          .onClick(() => { void this.saveMail(); })
        Button(this.mailBusy ? '处理中…' : '发测试')
          .layoutWeight(1)
          .height(38)
          .fontSize(12)
          .backgroundColor('#eeeeee')
          .fontColor('#2b2f36')
          .onClick(() => { void this.testMail(); })
        Button(this.mailBusy ? '处理中…' : '收件箱')
          .layoutWeight(1)
          .height(38)
          .fontSize(12)
          .backgroundColor('#eeeeee')
          .fontColor('#2b2f36')
          .onClick(() => { void this.previewInbox(); })
      }
      .width('100%')
      if (this.inboxList.length > 0) {
        ForEach(this.inboxList, (h: MailHeader) => {
          Row({ space: 8 }) {
            Column({ space: 2 }) {
              Text(h.subject.length > 0 ? h.subject : '（无主题）')
                .fontSize(12)
                .fontColor('#1f2328')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(h.from)
                .fontSize(11)
                .fontColor('#9a9aa2')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Text(h.date.length > 16 ? h.date.substring(0, 16) : h.date)
              .fontSize(10)
              .fontColor('#b9bcc4')
          }
          .width('100%')
          .padding(8)
          .borderRadius(8)
          .backgroundColor('#F7F7FA')
          .onClick(() => { void this.openMail(h.index); })
        }, (h: MailHeader) => `${h.index}`)
      }
      if (this.inboxDetail.length > 0) {
        Text(this.inboxDetail)
          .fontSize(12)
          .fontColor('#3a3a40')
          .width('100%')
          .padding(10)
          .borderRadius(10)
          .backgroundColor('#F7F7FA')
      }

      Text('写邮件').fontSize(12).fontColor('#5c6270').width('100%')
      TextInput({ text: this.mailTo, placeholder: '收件人' })
        .height(40)
        .width('100%')
        .borderRadius(10)
        .onChange((v: string) => { this.mailTo = v; })
      TextInput({ text: this.mailSubject, placeholder: '主题' })
        .height(40)
        .width('100%')
        .borderRadius(10)
        .onChange((v: string) => { this.mailSubject = v; })
      TextArea({ text: this.mailBody, placeholder: '正文' })
        .height(90)
        .width('100%')
        .borderRadius(10)
        .onChange((v: string) => { this.mailBody = v; })
      Button(this.mailBusy ? '处理中…' : '发送')
        .height(38)
        .width('100%')
        .fontSize(13)
        .backgroundColor('#c8546a')
        .onClick(() => { void this.sendCompose(); })

      Divider().color('#EFEFF3')
      Text('小工具（备忘 / 倒计时 / 闪卡）')
        .fontSize(13)
        .fontWeight(500)
        .width('100%')
      Row({ space: 8 }) {
        TextInput({ text: this.memoDraft, placeholder: '记一条备忘…' })
          .layoutWeight(1)
          .height(40)
          .borderRadius(10)
          .onChange((v: string) => { this.memoDraft = v; })
        Button('记')
          .width(56)
          .height(40)
          .fontSize(13)
          .backgroundColor('#eeeeee')
          .fontColor('#2b2f36')
          .onClick(() => { void this.addMemoQuick(); })
      }
      .width('100%')
      ForEach(this.memos, (m: string, i: number) => {
        Text(m)
          .fontSize(12)
          .fontColor('#3a3a40')
          .width('100%')
          .padding(8)
          .borderRadius(8)
          .backgroundColor('#F7F7FA')
      }, (m: string, i: number) => `${i}-${m.length}`)

      Row({ space: 8 }) {
        TextInput({ text: this.cdTitle, placeholder: '倒计时名称' })
          .layoutWeight(1)
          .height(40)
          .borderRadius(10)
          .onChange((v: string) => { this.cdTitle = v; })
        TextInput({ text: this.cdDate, placeholder: 'YYYY-MM-DD' })
          .width(120)
          .height(40)
          .borderRadius(10)
          .onChange((v: string) => { this.cdDate = v; })
        Button('加')
          .width(48)
          .height(40)
          .fontSize(13)
          .backgroundColor('#eeeeee')
          .fontColor('#2b2f36')
          .onClick(() => { void this.addCountdownQuick(); })
      }
      .width('100%')
      ForEach(this.countdowns, (c: string, i: number) => {
        Text(c)
          .fontSize(12)
          .fontColor('#3a3a40')
          .width('100%')
          .padding(8)
          .borderRadius(8)
          .backgroundColor('#F7F7FA')
      }, (c: string, i: number) => `${i}-${c.length}`)

      Row({ space: 8 }) {
        Text(`共 ${this.flashTotal} 张闪卡`)
          .fontSize(12)
          .fontColor('#5c6270')
          .layoutWeight(1)
        Button('抽一张')
          .height(36)
          .fontSize(12)
          .backgroundColor('#eeeeee')
          .fontColor('#2b2f36')
          .onClick(() => { void this.nextFlashcard(); })
      }
      .width('100%')
      if (this.flashQ.length > 0) {
        Column({ space: 8 }) {
          Text(this.flashQ).fontSize(13).fontColor('#1f2328').width('100%')
          if (this.flashReveal) {
            Text(this.flashA).fontSize(13).fontColor('#5c6270').width('100%')
          } else {
            Button('显示答案')
              .height(34)
              .fontSize(12)
              .backgroundColor('#FBE9EC')
              .fontColor('#c8546a')
              .onClick(() => { this.flashReveal = true; })
          }
        }
        .width('100%')
        .padding(10)
        .borderRadius(10)
        .backgroundColor('#F7F7FA')
        .alignItems(HorizontalAlign.Start)
      }

      if (this.notices.length > 0) {
        Text('公告')
          .fontSize(13)
          .fontWeight(500)
          .width('100%')
        ForEach(this.notices, (notice: NoticeItem) => {
          Column({ space: 2 }) {
            Text(notice.title).fontSize(14).width('100%')
            Text(notice.body)
              .fontSize(12)
              .fontColor('#8a8f98')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(10)
          .borderRadius(10)
          .backgroundColor('#F7F7FA')
        }, (notice: NoticeItem) => `${notice.id}`)
      }

      if (this.message.length > 0) {
        Text(this.message).fontSize(12).fontColor('#c8546a').width('100%')
      }
    }
    .padding(16)
    .width('100%')
    .height('100%')
  }

  @Builder
  literatureTab() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        TextInput({ text: this.paperQuery, placeholder: '搜 arXiv，例如 cross-field MRI' })
          .layoutWeight(1)
          .height(40)
          .borderRadius(10)
          .onChange((value: string) => { this.paperQuery = value; })
        Button(this.paperBusy ? '…' : '检索')
          .height(40)
          .backgroundColor('#c8546a')
          .enabled(!this.paperBusy)
          .onClick(() => { void this.searchPapers(); })
      }
      .width('100%')

      if (this.message.length > 0) {
        Text(this.message).fontSize(12).fontColor('#8a8f98').width('100%')
      }

      List({ space: 8 }) {
        ForEach(this.papers, (paper: PaperHit) => {
          ListItem() {
            Column({ space: 2 }) {
              Text(paper.title).fontSize(14).width('100%')
              Text(`${paper.year} · ${paper.authors}`)
                .fontSize(12)
                .fontColor('#8a8f98')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(paper.summary)
                .fontSize(12)
                .fontColor('#5a5f68')
                .maxLines(3)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(10)
            .borderRadius(10)
            .backgroundColor('#F7F7FA')
            .onClick(() => { this.openLink(paper.url); })
          }
        }, (paper: PaperHit) => paper.url + paper.title)
      }
      .layoutWeight(1)
      .width('100%')
    }
    .padding(16)
    .width('100%')
    .height('100%')
  }

  /** 新建 / 编辑日程的表单（底部升起的整页，照系统日历那个样式） */
  @Builder
  eventSheet() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        Text('✕')
          .fontSize(16)
          .fontColor('#1f2328')
          .width(36)
          .height(36)
          .textAlign(TextAlign.Center)
          .borderRadius(18)
          .backgroundColor('#F1F2F4')
          .onClick(() => { this.cancelEdit(); })
        Text(this.editEventId > 0 ? '编辑日程' : '新建日程')
          .fontSize(17)
          .fontWeight(600)
          .fontColor('#1f2328')
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Text('✓')
          .fontSize(18)
          .fontColor('#ffffff')
          .width(36)
          .height(36)
          .textAlign(TextAlign.Center)
          .borderRadius(18)
          .backgroundColor('#c8546a')
          .onClick(() => { void this.saveSheet(); })
      }
      .width('100%')

      Scroll() {
        Column({ space: 12 }) {
          Column() {
            TextInput({ text: this.editTitle, placeholder: '标题' })
              .height(52)
              .fontSize(15)
              .backgroundColor(Color.Transparent)
              .onChange((v: string) => { this.editTitle = v; })
            Divider().color('#EFEFF3').margin({ left: 12, right: 12 })
            TextInput({ text: this.editDesc, placeholder: '描述 / 地点' })
              .height(52)
              .fontSize(14)
              .backgroundColor(Color.Transparent)
              .onChange((v: string) => { this.editDesc = v; })
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor(Color.White)

          Column() {
            Row({ space: 8 }) {
              Text('全天').fontSize(15).fontColor('#1f2328').layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.editAllDay })
                .selectedColor('#c8546a')
                .onChange((v: boolean) => { this.editAllDay = v; })
            }
            .width('100%')
            .height(52)
            .padding({ left: 12, right: 12 })

            Divider().color('#EFEFF3').margin({ left: 12, right: 12 })
            Row({ space: 8 }) {
              Text('日期').fontSize(15).fontColor('#1f2328').layoutWeight(1)
              Text(this.editDate).fontSize(13).fontColor('#8a8f98')
              Text('›').fontSize(16).fontColor('#C7C9CE')
            }
            .width('100%')
            .height(52)
            .padding({ left: 12, right: 12 })
            .onClick(() => { this.pickEditDate(); })

            if (!this.editAllDay) {
              Divider().color('#EFEFF3').margin({ left: 12, right: 12 })
              Row({ space: 8 }) {
                Text('开始').fontSize(15).fontColor('#1f2328').layoutWeight(1)
                Text(this.editStart).fontSize(13).fontColor('#8a8f98')
                Text('›').fontSize(16).fontColor('#C7C9CE')
              }
              .width('100%')
              .height(52)
              .padding({ left: 12, right: 12 })
              .onClick(() => { this.pickTime(1); })

              Divider().color('#EFEFF3').margin({ left: 12, right: 12 })
              Row({ space: 8 }) {
                Text('结束').fontSize(15).fontColor('#1f2328').layoutWeight(1)
                Text(this.editEnd).fontSize(13).fontColor('#8a8f98')
                Text('›').fontSize(16).fontColor('#C7C9CE')
              }
              .width('100%')
              .height(52)
              .padding({ left: 12, right: 12 })
              .onClick(() => { this.pickTime(2); })
            }
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor(Color.White)

          Column() {
            Row({ space: 8 }) {
              Text('提醒').fontSize(15).fontColor('#1f2328').layoutWeight(1)
              Text('10 分钟前').fontSize(13).fontColor('#8a8f98')
            }
            .width('100%')
            .height(52)
            .padding({ left: 12, right: 12 })
            Divider().color('#EFEFF3').margin({ left: 12, right: 12 })
            Row({ space: 8 }) {
              Text('重复').fontSize(15).fontColor('#1f2328').layoutWeight(1)
              Text('不重复').fontSize(13).fontColor('#8a8f98')
            }
            .width('100%')
            .height(52)
            .padding({ left: 12, right: 12 })
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor(Color.White)

          if (this.editEventId > 0) {
            Button('删除日程')
              .height(46)
              .width('100%')
              .backgroundColor(Color.White)
              .fontColor('#c8546a')
              .fontSize(15)
              .onClick(() => { void this.deleteEditEvent(); })
          }
        }
        .width('100%')
        .padding({ bottom: 20 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
    }
    .padding(16)
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F3F5')
  }

  /** 日历页 ⋯ 菜单 */
  @Builder
  calMenu() {
    Column({ space: 2 }) {
      Row() {
        Text('回到今天').fontSize(13).fontColor('#1f2328')
      }
      .width(180)
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .borderRadius(8)
      .onClick(() => { this.jumpToday(); })
      Row() {
        Text('导入手机日历').fontSize(13).fontColor('#1f2328')
      }
      .width(180)
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .borderRadius(8)
      .onClick(() => { void this.importCalendar(); })
      Row() {
        Text('导入电脑数据包').fontSize(13).fontColor('#1f2328')
      }
      .width(180)
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .borderRadius(8)
      .onClick(() => { void this.importComputer(); })
      Row() {
        Text('导出当天到系统日历').fontSize(13).fontColor('#1f2328')
      }
      .width(180)
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .borderRadius(8)
      .onClick(() => { void this.exportDayCalendar(); })
    }
    .width(180)
    .padding(6)
    .borderRadius(14)
    .backgroundColor(Color.White)
    .shadow({ radius: 18, color: '#1F2A2A40', offsetY: 6 })
  }

  @Builder
  calendarTab() {
    Column({ space: 10 }) {
      // 顶栏：菜单 / 大月份 / 新增 / 更多
      Row({ space: 10 }) {
        Text('☰')
          .fontSize(18)
          .fontColor('#1f2328')
          .width(38)
          .height(38)
          .textAlign(TextAlign.Center)
          .borderRadius(19)
          .backgroundColor(Color.White)
          .onClick(() => { this.jumpToday(); })
        Row({ space: 6 }) {
          Text(`${parseInt(this.month.slice(5, 7), 10)} 月`)
            .fontSize(28)
            .fontWeight(700)
            .fontColor('#1f2328')
          Text(this.month.slice(0, 4))
            .fontSize(12)
            .fontColor('#9a9aa2')
          Text('‹')
            .fontSize(16)
            .fontColor('#8a8f98')
            .padding({ left: 6, right: 2 })
            .onClick(() => { this.shiftMonth(-1); })
          Text('›')
            .fontSize(16)
            .fontColor('#8a8f98')
            .padding({ left: 2, right: 2 })
            .onClick(() => { this.shiftMonth(1); })
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Bottom)
        Text('＋')
          .fontSize(22)
          .fontColor('#1f2328')
          .width(38)
          .height(38)
          .textAlign(TextAlign.Center)
          .borderRadius(19)
          .backgroundColor(Color.White)
          .onClick(() => { this.openNewSheet(); })
        Text('⋯')
          .fontSize(20)
          .fontColor('#1f2328')
          .width(38)
          .height(38)
          .textAlign(TextAlign.Center)
          .borderRadius(19)
          .backgroundColor(Color.White)
          .bindMenu(this.calMenu)
      }
      .width('100%')

      Row() {
        ForEach(['日', '一', '二', '三', '四', '五', '六'], (weekday: string) => {
          Text(weekday)
            .fontSize(11)
            .fontColor('#9a9aa2')
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
        }, (weekday: string) => weekday)
      }
      .width('100%')

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.weekCells(), (cell: DayCell) => {
          Column({ space: 2 }) {
            Text(cell.day > 0 ? `${cell.day}` : '')
              .fontSize(16)
              .fontWeight(cell.today || this.selDate === cell.date ? 600 : 400)
              .fontColor(this.selDate === cell.date && cell.day > 0
                ? '#FFFFFF'
                : (cell.today ? '#c8546a' : (cell.inMonth ? '#1f2328' : '#C7C9CE')))
              .width(34)
              .height(34)
              .textAlign(TextAlign.Center)
              .borderRadius(17)
              .backgroundColor(this.selDate === cell.date && cell.day > 0 ? '#c8546a' : Color.Transparent)
            Circle()
              .width(4)
              .height(4)
              .fill(cell.count > 0 ? '#c8546a' : Color.Transparent)
          }
          .width('14.28%')
          .height(52)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .onClick(() => { this.selectDay(cell.date); })
        }, (cell: DayCell) => `${cell.date}-${cell.day}`)
      }
      .width('100%')

      // 选中这天：大标题 + 日程卡片
      Scroll() {
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            Text(this.selDate === Db.today() ? '今天' : this.dayLabel())
              .fontSize(18)
              .fontWeight(700)
              .fontColor('#1f2328')
            Text(this.dayRows.length > 0 ? `${this.dayRows.length} 条` : '没有日程')
              .fontSize(12)
              .fontColor('#9a9aa2')
          }
          .width('100%')

          if (this.dayRows.length === 0) {
            Column() {
              Text('这天还没有日程').fontSize(13).fontColor('#9a9aa2')
            }
            .width('100%')
            .padding(24)
            .borderRadius(16)
            .backgroundColor(Color.White)
          }
          ForEach(this.dayRows, (row: EventRow) => {
            Row({ space: 10 }) {
              Column({ space: 3 }) {
                Text(row.start_time.length > 0 ? row.start_time : '全天')
                  .fontSize(12)
                  .fontColor(row.done ? '#C3C5CB' : '#5c6270')
                if (row.end_time.length > 0) {
                  Text(row.end_time).fontSize(11).fontColor(row.done ? '#D0D2D7' : '#9a9aa2')
                }
              }
              .width(46)
              .alignItems(HorizontalAlign.Start)

              Column() {
                Circle()
                  .width(9)
                  .height(9)
                  .fill(row.done ? '#C9CBD1' : '#c8546a')
              }
              .width(14)
              .margin({ top: 4 })

              Column({ space: 3 }) {
                Row({ space: 6 }) {
                  Text(row.title)
                    .fontSize(15)
                    .fontWeight(500)
                    .fontColor(row.done ? '#B9BCC4' : '#1f2328')
                    .layoutWeight(1)
                  if (this.isConflict(row)) {
                    Text('冲突')
                      .fontSize(10)
                      .fontColor('#c8546a')
                      .backgroundColor('#FBE9EC')
                      .borderRadius(6)
                      .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                  }
                }
                .width('100%')
                if (row.description.length > 0) {
                  Text(row.description)
                    .fontSize(12)
                    .fontColor(row.done ? '#C9CBD1' : '#9a9aa2')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding(14)
            .borderRadius(16)
            .backgroundColor(Color.White)
            .shadow({ radius: 10, color: '#0D2A2A40', offsetY: 2 })
            .onClick(() => { this.openEditSheet(row); })
          }, (row: EventRow) => `${row.id}`)

          Row({ space: 8 }) {
            Text('＋ 新建日程')
              .fontSize(14)
              .fontColor('#c8546a')
          }
          .width('100%')
          .padding(14)
          .borderRadius(16)
          .backgroundColor(Color.White)
          .onClick(() => { this.openNewSheet(); })

          if (this.message.length > 0) {
            Text(this.message).fontSize(12).fontColor('#c8546a').width('100%')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ bottom: 12 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
    }
    .padding({ left: 16, right: 16, top: 12 })
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F3F5')
  }

  build() {
    Tabs({ index: this.currentTab }) {
      TabContent() { this.todayTab() }.tabBar('今日')
      TabContent() { this.calendarTab() }.tabBar('日历')
      TabContent() { this.literatureTab() }.tabBar('文献')
      TabContent() { this.chatTab() }.tabBar('梅子')
      TabContent() { this.meTab() }.tabBar('我的')
    }
    .onChange((index: number) => {
      this.currentTab = index;
      // 提示是三个标签页共用的：切页时清掉，免得「登录失败」跑到「今日」上
      this.message = '';
      if (index === 1) {
        this.reloadMonth();
        this.reloadDay();
      }
    })
    .barPosition(BarPosition.End)
    .backgroundColor(Color.White)
    .bindSheet($$this.sheetOpen, this.eventSheet, {
      height: SheetSize.LARGE,
      dragBar: true,
    })
    .width('100%')
    .height('100%')
  }
}
