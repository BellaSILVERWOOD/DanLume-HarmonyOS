import { Db, EventRow } from '../common/Db';
import { Api, PaperHit } from '../common/Api';
import { parseMarkdown, MdBlock, MdKind, MdSpan } from '../common/Md';
import common from '@ohos.app.ability.common';
import reminderAgentManager from '@ohos.reminderAgentManager';
import notificationManager from '@ohos.notificationManager';
import { speechRecognizer } from '@kit.CoreSpeechKit';
import abilityAccessCtrl, { Permissions } from '@ohos.abilityAccessCtrl';
import pasteboard from '@ohos.pasteboard';

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
  // AI 接口（OpenAI 兼容）：和桌面版一样存在本地设置里
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
  // 文献页（arXiv）
  @State paperQuery: string = '';
  @State papers: PaperHit[] = [];
  @State paperBusy: boolean = false;
  @State listening: boolean = false;
  // 语音识别引擎（第一次用时创建，之后复用）
  asrEngine: speechRecognizer.SpeechRecognitionEngine | null = null;

  aboutToAppear(): void {
    this.reloadToday();
    this.reloadAccount();
    this.reloadAi();
    if (this.month.length === 0) {
      this.month = this.today.slice(0, 7);
    }
    this.reloadMonth();
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
    this.aiBase = await Db.getSetting('ai_base_url', 'https://api.deepseek.com/v1');
    this.aiModel = await Db.getSetting('ai_model', 'deepseek-chat');
    this.aiKey = await Db.getSetting('ai_api_key', '');
  }

  async saveAi(): Promise<void> {
    const server = this.serverUrl.trim().length > 0
      ? this.serverUrl.trim() : 'https://43.108.99.38.sslip.io';
    const base = this.aiBase.trim().length > 0 ? this.aiBase.trim() : 'https://api.deepseek.com/v1';
    const model = this.aiModel.trim().length > 0 ? this.aiModel.trim() : 'deepseek-chat';
    this.serverUrl = server;
    this.aiBase = base;
    this.aiModel = model;
    await Db.setSetting('server_url', server);
    await Db.setSetting('ai_base_url', base);
    await Db.setSetting('ai_model', model);
    await Db.setSetting('ai_api_key', this.aiKey.trim());
    this.message = this.aiKey.trim().length > 0 ? '设置已保存' : '设置已保存（还没填 API Key）';
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
    }).catch((err: Error) => {
      this.message = `复制失败：${err.message}`;
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
              Image($r('app.media.md_copy'))
                .width(15)
                .height(15)
                .fillColor('#8a8f98')
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

  @Builder
  chatTab() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Stack() {
          Row() {}
            .width(40)
            .height(40)
            .borderRadius(20)
            .backgroundColor('#CCE9E9EF')
            .backgroundBlurStyle(BlurStyle.Thick)
            .border({ width: 1, color: '#F2FFFFFF' })
            .shadow({ radius: 10, color: '#0F2A2A40', offsetY: 3 })
          Text('☰').fontSize(18).fontColor('#2b2f36')
        }
        .width(40)
        .height(40)
        .onClick(() => { this.message = '历史聊天：下一步接 chat_sessions'; })
        Text('梅子').fontSize(16).fontWeight(600).layoutWeight(1).textAlign(TextAlign.Center)
        Stack() {
          Row() {}
            .width(40)
            .height(40)
            .borderRadius(20)
            .backgroundColor('#CCE9E9EF')
            .backgroundBlurStyle(BlurStyle.Thick)
            .border({ width: 1, color: '#F2FFFFFF' })
            .shadow({ radius: 10, color: '#0F2A2A40', offsetY: 3 })
          Text('✎').fontSize(18).fontColor('#2b2f36')
        }
        .width(40)
        .height(40)
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
                      .padding(12)
                      .borderRadius(20)
                      .backgroundColor('#E7E1FB')
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
                    .width(30)
                    .height(30)
                    .borderRadius(15)
                    .backgroundColor('#F2F2F7')
                    .justifyContent(FlexAlign.Center)
                    .onClick(() => { this.copyText(line.text); })
                    Column() {
                      Image($r('app.media.md_refresh')).width(16).height(16).fillColor('#8a8f98')
                    }
                    .width(30)
                    .height(30)
                    .borderRadius(15)
                    .backgroundColor('#F2F2F7')
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
      }

      // 发送框：底层磨砂负责模糊，上层只放文字/输入（避免文字被画进模糊层）
      Stack() {
        Row() {}
          .width('100%')
          .height(56)
          .borderRadius(28)
          .backgroundColor('#40FFFFFF')
          .backgroundBlurStyle(BlurStyle.Thick)
          .border({ width: 1, color: '#80FFFFFF' })
          .shadow({ radius: 18, color: '#1A2A2A40', offsetY: 6 })
        Row({ space: 6 }) {
          Stack() {
            Row() {}
              .width(36)
              .height(36)
              .borderRadius(18)
              .backgroundColor('#40FFFFFF')
              .backgroundBlurStyle(BlurStyle.Thick)
            Text('+').fontSize(22).fontColor('#3a3a40')
          }
          .width(36)
          .height(36)
          .onClick(() => { this.message = '附件功能待接入'; })
          TextInput({ text: this.chatDraft, placeholder: 'Ask 梅子…' })
            .layoutWeight(1)
            .height(44)
            .fontSize(15)
            .backgroundColor(Color.Transparent)
            .onChange((value: string) => { this.chatDraft = value; })
          Stack() {
            Row() {}
              .width(36)
              .height(36)
              .borderRadius(18)
              .backgroundColor(this.listening ? '#59FFD9D9' : '#40FFFFFF')
              .backgroundBlurStyle(BlurStyle.Thick)
            Text(this.listening ? '停' : '语音')
              .fontSize(this.listening ? 14 : 11)
              .fontColor('#3a3a40')
          }
          .width(36)
          .height(36)
          .onClick(() => { void this.toggleVoice(); })
          Stack() {
            Row() {}
              .width(36)
              .height(36)
              .borderRadius(18)
              .backgroundColor(this.chatDraft.trim().length > 0 ? '#c8546a' : '#C7C7CC')
            Text(this.asking ? '…' : '↑').fontSize(18).fontColor(Color.White)
          }
          .width(36)
          .height(36)
          .onClick(() => {
            if (!this.asking) {
              void this.askMeizi();
            }
          })
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 6, bottom: 6 })
      }
      .width('100%')
    }
    .padding(16)
    .width('100%')
    .height('100%')
  }

  @Builder
  meTab() {
    Column({ space: 12 }) {
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

      Text('服务器地址')
        .fontSize(13)
        .fontWeight(500)
        .width('100%')
      TextInput({ text: this.serverUrl, placeholder: 'https://43.108.99.38.sslip.io' })
        .height(40)
        .width('100%')
        .borderRadius(10)
        .onChange((value: string) => { this.serverUrl = value; })

      Text('AI 接口（OpenAI 兼容，DeepSeek 等）')
        .fontSize(13)
        .fontWeight(500)
        .width('100%')
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
      Button('保存服务器与 AI 设置')
        .height(40)
        .width('100%')
        .backgroundColor('#eeeeee')
        .fontColor('#2b2f36')
        .onClick(() => { void this.saveAi(); })

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

  @Builder
  calendarTab() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Button('‹')
          .height(30)
          .fontSize(14)
          .backgroundColor('#eeeeee')
          .fontColor('#2b2f36')
          .onClick(() => { this.shiftMonth(-1); })
        Text(this.monthLabel())
          .fontSize(15)
          .fontWeight(600)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
        Button('›')
          .height(30)
          .fontSize(14)
          .backgroundColor('#eeeeee')
          .fontColor('#2b2f36')
          .onClick(() => { this.shiftMonth(1); })
      }
      .width('100%')

      Row() {
        ForEach(['日', '一', '二', '三', '四', '五', '六'], (weekday: string) => {
          Text(weekday)
            .fontSize(11)
            .fontColor('#8a8f98')
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
        }, (weekday: string) => weekday)
      }
      .width('100%')

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.weekCells(), (cell: DayCell) => {
          Column({ space: 2 }) {
            Text(cell.day > 0 ? `${cell.day}` : '')
              .fontSize(13)
              .fontColor(cell.today ? '#c8546a' : (cell.inMonth ? '#2b2f36' : '#8a8f98'))
            if (cell.count > 0) {
              Text(`${cell.count}`)
                .fontSize(10)
                .fontColor('#ffffff')
                .backgroundColor('#c8546a')
                .borderRadius(6)
                .padding({ left: 4, right: 4 })
            }
          }
          .width('14.28%')
          .height(48)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .onClick(() => { this.openDay(cell.date); })
        }, (cell: DayCell) => `${cell.date}-${cell.day}`)
      }
      .width('100%')
      .layoutWeight(1)

      Text(this.monthRows.length > 0 ? `本月 ${this.monthRows.length} 条日程` : '本月还没有日程')
        .fontSize(12)
        .fontColor('#8a8f98')
        .width('100%')
    }
    .padding(16)
    .width('100%')
    .height('100%')
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
      }
    })
    .barPosition(BarPosition.End)
    .backgroundColor(Color.White)
    .width('100%')
    .height('100%')
  }
}
