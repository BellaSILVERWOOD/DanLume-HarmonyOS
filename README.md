# DanLume · HarmonyOS（手机端）

从 **`DanLume-v2`（Tauri + Rust）** 拆出来的鸿蒙版：同一个账号服务器、同一套 `lumina.db` 表结构，
只是把渲染层换成 ArkTS/ArkUI、把 Rust 那些网络与 SQLite 调用换成 HarmonyOS 的 `@ohos.net.http` 与 `relationalStore`。

> ## ✅ 状态（2026-11-23）
>
> * 已在 **DevEco Studio 26.0.0**（自带 HarmonyOS 26.0.0 / API 26 SDK）上**首次编译通过**：
>   `hvigorw assembleHap` → **BUILD SUCCESSFUL**，产出未签名 HAP（约 117 KB）。
> * 工程里的 `compatibleSdkVersion` 仍写 `5.0.0(12)`；实测更高版本 SDK 也能编译（会提示建议补 `targetSdkVersion`）。
> * **构建路径必须是纯 ASCII**：hvigor 拒绝含 `‘` / 中文的工程路径（目录联接也会被解析成真实路径而拒绝）。
>   工作区源码可以放在任意位置，构建时复制到 `E:\FIles\Work\danlume-harmony-build` 这类路径。
> * **还没做**：签名（要在 DevEco 里登录华为账号生成 signingConfig）与真机安装（`hdc install`）。
> * 目标设备：`phone` / `tablet`；如果要上鸿蒙 PC，把 `entry/src/main/module.json5` 的 `deviceTypes` 加上 `"2in1"` 并适配宽屏布局。

## 1. 这一版做了什么

| 能力 | 对应 Rust 版 | 状态 |
| --- | --- | --- |
| 本地库 `lumina.db`：`settings` / `events` 两张表（字段与 Python/Rust 版逐字一致） | `store.rs` | 代码已写，**未验证** |
| 账号服务器：注册 / 登录 / 刷新、`/me`、公告拉取 | `account.rs`、`notify.rs` | 代码已写，**未验证**（接口契约照 Rust 版） |
| 今日日程列表 + 新建 / 完成 / 删除 | `store.rs` + `CalendarPage.vue` | 代码已写，**未验证** |
| AI 对话（OpenAI 兼容：DeepSeek），人设「你是梅子」 | `ai.rs` + `prompts.rs` | 代码已写，**未验证** |
| 使用上报 `POST /api/v1/usage`（J2-16） | `usage.rs` | 代码已写，**未验证** |
| 邮件 / 文献 / 公式 / 教务 / eLearning | `mail.rs`、`papers.rs`、`latex_*`、`ehall_*`、`elearn.rs` | **没做**，见第 4 节优先级 |

## 2. 目录

```
DanLume-Harmony/
├── AppScope/app.json5                 应用信息（bundleName / 版本 / 图标）
├── build-profile.json5                根构建配置（API 12，Stage 模型）
├── oh-package.json5                   依赖（无三方依赖，全用系统 @ohos.* 能力）
├── hvigorfile.ts                      构建脚本入口
├── entry/
│   ├── build-profile.json5            entry 模块构建配置
│   ├── oh-package.json5               模块依赖
│   ├── hvigorfile.ts
│   └── src/main/
│       ├── module.json5               模块清单（权限：网络 / 通知）
│       ├── resources/base/element/string.json
│       └── ets/
│           ├── entryability/EntryAbility.ets   启动入口、窗口与权限
│           ├── common/Db.ets                   relationalStore + 设置读写
│           ├── common/Api.ets                  账号服务器 / 公告 / AI / 使用上报
│           ├── common/Theme.ets                颜色与字号（对齐 Rust 版浅色主题）
│           └── pages/Index.ets                 三个标签页：今日 / 梅子 / 我的
```

## 3. 怎么跑起来

1. 装 **DevEco Studio**（本机实测 26.0.0，自带 HarmonyOS SDK）；
2. **先把工程复制到纯 ASCII 路径**（例如 `E:\FIles\Work\danlume-harmony-build`）——hvigor 拒绝含 `‘`/中文的工程路径；
3. Open 那个 ASCII 目录 → 等 Sync；
4. `File → Project Structure → Signing Configs` 勾选自动签名（需要登录华为开发者账号）；
5. 选模拟器或真机 → Run。

命令行构建（不经过 IDE 也可以，Windows）：

```powershell
$env:NODE_HOME="D:\Programs\DevEco Studio\tools\node"
$env:DEVECO_SDK_HOME="D:\Programs\DevEco Studio\sdk"
$env:JAVA_HOME="D:\Programs\DevEco Studio\jbr"
$env:Path="$env:NODE_HOME;D:\Programs\DevEco Studio\jbr\bin;$env:Path"
cd E:\FIles\Work\danlume-harmony-build
& "D:\Programs\DevEco Studio\tools\hvigor\bin\hvigorw.bat" assembleHap --mode module -p product=default -p module=entry@default --no-daemon
# 产物：entry\build\default\outputs\default\entry-default-unsigned.hap
```

装到手机（要先在 DevEco 里签好名，或自己配 `signingConfigs`）：

```powershell
& "D:\Programs\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" list targets
& "D:\Programs\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" install <签名后的.hap>
& "D:\Programs\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" shell aa start -a EntryAbility -b com.danlume.app.harmony
```

数据库落在应用沙箱 `context.databaseDir` 下，和桌面版**不是同一个文件**，目前靠 `.dlpk` 之类的方式迁移还没做。

## 4. 下一步（按价值排）

1. **接通知 / 提醒**：`@ohos.reminderAgentManager` 把「日程提醒」做成系统提醒（对应 Rust 版 `reminders.rs`）；
2. **邮件**：HarmonyOS 没有现成 IMAP 客户端，要么走自家服务器转发，要么手写 IMAP over TLS（大工程）；
3. **教务 / eLearning**：ArkWeb 组件内嵌 `ehall.fudan.edu.cn` / `elearning.fudan.edu.cn`，复用 Rust 版那套「登录窗口注入脚本抓 print-data」的思路；
4. **文献 / 公式**：检索走 arXiv/Crossref（纯 HTTP，容易）；LaTeX 编译得放到服务器；
5. **离线队列**：现在写入是「本地直接写」，断网时账号相关的调用会失败但没有重试队列。

## 5. 与桌面版的数据对齐

* 表结构只建了**用到的两张**（`settings`、`events`）。要完整迁移，得把 `store.rs` 的 `SCHEMA` 里剩下的表
  照抄成 `relationalStore.executeSql`（字段名/默认值别改，否则 `.dlpk` 导不过来）；
* 设置键名沿用桌面版：`server_url` / `server_username` / `ai_api_key` / `ai_base_url` / `ai_model` / `focus_minutes`；
* 账号服务器接口与 Rust 版完全一致（见 `common/Api.ets` 顶部注释）。

## 6. 已知限制

* 没有做 TLS 证书固定、没有做 DPAPI 那种密钥保护：令牌只存在应用沙箱的 `settings` 表里（鸿蒙沙箱本身隔离，但没有再加一层加密）；
* AI 走的是**非流式** `chat/completions`（先拿到整段再一次性渲染），桌面版是流式；
* 没有单元测试；ArkTS 目前没有像 `cargo test` 那样的本地测试习惯，验证主要靠 DevEco 里跑。
