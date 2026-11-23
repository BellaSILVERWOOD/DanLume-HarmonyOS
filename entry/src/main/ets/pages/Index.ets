import { Db } from '../common/Db';
import { Api } from '../common/Api';

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
}

@Entry
@Component
struct Index {
  // 不能叫 tabIndex：和 CustomComponent 内置的 tabIndex 属性方法重名
  @State currentTab: number = 0;
  @State today: string = Db.today();
  @State events: EventItem[] = [];
  @State draft: string = '';
  @State chat: ChatLine[] = [];
  @State asking: boolean = false;
  @State accountName: string = '';
  @State message: string = '';

  aboutToAppear(): void {
    this.reloadToday();
    this.reloadAccount();
  }

  // ------------------------------------------------------------ 数据
  async reloadToday(): Promise<void> {
    const rows = await Db.eventsOn(this.today);
    this.events = rows.map((row): EventItem => {
      const item: EventItem = { id: row.id, title: row.title, start: row.start_time, done: row.done };
      return item;
    });
  }

  async reloadAccount(): Promise<void> {
    this.accountName = await Db.getSetting('server_username', '');
  }

  async addQuickEvent(): Promise<void> {
    const title = this.draft.trim();
    if (title.length === 0) {
      this.message = '先写个标题';
      return;
    }
    await Db.addEvent({ title: title, date: this.today });
    this.draft = '';
    this.message = '已加进今天';
    await this.reloadToday();
  }

  async toggleDone(id: number, done: boolean): Promise<void> {
    await Db.setDone(id, !done);
    await this.reloadToday();
  }

  async askMeizi(): Promise<void> {
    const text = this.draft.trim();
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
    this.draft = '';
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
    const user = this.draft.trim();
    if (user.length === 0) {
      this.message = '先在输入框里写用户名';
      return;
    }
    // 骨架版：密码也在同一个输入框里用「用户名,密码」格式输入，正式版要换成两个输入框
    const parts = user.split(',');
    if (parts.length < 2) {
      this.message = '格式：用户名,密码';
      return;
    }
    try {
      const result = await Api.login(parts[0].trim(), parts[1].trim());
      this.accountName = result.username;
      this.message = `已登录 ${result.username}`;
      this.draft = '';
    } catch (err) {
      this.message = `登录失败：${err}`;
    }
  }

  async pullAnnouncements(): Promise<void> {
    const items = await Api.announcements(0);
    this.message = items.length > 0 ? `拉到 ${items.length} 条公告` : '没有新公告';
  }

  // ------------------------------------------------------------ 界面
  @Builder
  todayTab() {
    Column({ space: 12 }) {
      Text(this.today).fontSize(13).fontColor('#8a8f98').width('100%')
      Row({ space: 8 }) {
        TextInput({ text: this.draft, placeholder: '今天要做的事…' })
          .layoutWeight(1)
          .height(40)
          .borderRadius(10)
          .onChange((value: string) => { this.draft = value; })
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
                Text(item.title).fontSize(15).decoration({ type: item.done ? TextDecorationType.LineThrough : TextDecorationType.None })
                if (item.start.length > 0) {
                  Text(item.start).fontSize(12).fontColor('#8a8f98')
                }
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            .padding(12)
            .borderRadius(12)
            .backgroundColor('#ffffff')
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

  @Builder
  chatTab() {
    Column({ space: 10 }) {
      List({ space: 8 }) {
        ForEach(this.chat, (line: ChatLine, index: number) => {
          ListItem() {
            Row() {
              Text(line.text)
                .fontSize(14)
                .padding(10)
                .borderRadius(10)
                .backgroundColor(line.role === 'user' ? '#f6dfe4' : '#ffffff')
                .width('100%')
            }
            .width('100%')
            .justifyContent(line.role === 'user' ? FlexAlign.End : FlexAlign.Start)
          }
        }, (line: ChatLine, index: number) => `${index}`)
      }
      .layoutWeight(1)
      .width('100%')

      Row({ space: 8 }) {
        TextInput({ text: this.draft, placeholder: '跟梅子说点什么…' })
          .layoutWeight(1)
          .height(40)
          .borderRadius(10)
          .onChange((value: string) => { this.draft = value; })
        Button(this.asking ? '…' : '发送')
          .height(40)
          .backgroundColor('#c8546a')
          .enabled(!this.asking)
          .onClick(() => { void this.askMeizi(); })
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
      Text('输入「用户名,密码」后点登录（骨架版省了两个输入框）')
        .fontSize(12)
        .fontColor('#8a8f98')
        .width('100%')
      Row({ space: 8 }) {
        TextInput({ text: this.draft, placeholder: '用户名,密码' })
          .layoutWeight(1)
          .height(40)
          .borderRadius(10)
          .onChange((value: string) => { this.draft = value; })
        Button('登录')
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

      if (this.message.length > 0) {
        Text(this.message).fontSize(12).fontColor('#c8546a').width('100%')
      }
    }
    .padding(16)
    .width('100%')
    .height('100%')
  }

  build() {
    Tabs({ index: this.currentTab }) {
      TabContent() { this.todayTab() }.tabBar('今日')
      TabContent() { this.chatTab() }.tabBar('梅子')
      TabContent() { this.meTab() }.tabBar('我的')
    }
    .onChange((index: number) => { this.currentTab = index; })
    .barPosition(BarPosition.End)
    .width('100%')
    .height('100%')
  }
}
