import UIAbility from '@ohos.app.ability.UIAbility';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';
import { Db } from '../common/Db';
import { Api } from '../common/Api';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 建库建表（relationalStore 要在 UIAbility 的 context 上拿）
    Db.init(this.context).then(() => {
      console.info('[DanLume] 数据库就绪');
    }).catch((err: Error) => {
      console.error(`[DanLume] 建库失败：${err.message}`);
    });
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        console.error(`[DanLume] 加载首页失败：${err.message}`);
        return;
      }
      console.info('[DanLume] 首页已加载');
    });
    // 启动后悄悄拉一次公告（失败就算了，不打扰用户）
    setTimeout(() => {
      Api.announcements(0).catch(() => {
        // 忽略
      });
    }, 3000);
  }

  onDestroy(): void {
    console.info('[DanLume] 退出');
  }
}
