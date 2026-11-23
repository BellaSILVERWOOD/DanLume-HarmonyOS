/*
 * 手机端 AI 工具（function calling）的规格表。
 * 跟电脑端 `aiTools.ts` 一个思路：总开关 `ai_tools_enabled` + 每个工具 `ai_tool_<name>`。
 *
 * 这批工具是用户逐个确认过要迁的（2026-11-24）：日程、计时、备忘、闪卡、文献、网络检索、
 * 文件（沙箱内）、系统信息、设置。eLearning / 邮件 / 番茄钟后台计时目前只保留入口，
 * 执行时返回「还没接」的说明，等后续实现。
 */
import { Db } from './Db';

export const TOOLS_ENABLED_KEY = 'ai_tools_enabled';

export function toolKey(name: string): string {
  return `ai_tool_${name}`;
}

function spec(name: string, desc: string, params: Object): Object {
  const fn: Record<string, Object> = {
    'name': name,
    'description': desc,
    'parameters': params,
  };
  const out: Record<string, Object> = {
    'type': 'function',
    'function': fn,
  };
  return out;
}

function obj(props: Record<string, Object>, required: string[]): Object {
  const out: Record<string, Object> = {
    'type': 'object',
    'properties': props,
  };
  if (required.length > 0) {
    out['required'] = required;
  }
  return out;
}

function str(desc: string): Object {
  const out: Record<string, string> = { 'type': 'string', 'description': desc };
  return out;
}

function num(desc: string): Object {
  const out: Record<string, string> = { 'type': 'number', 'description': desc };
  return out;
}

/** 全部工具（是否启用由调用方按设置过滤） */
export function toolSpecs(): Object[] {
  const list: Object[] = [];

  // 日程
  list.push(spec('schedule_list', '列出某一天的日程。date 省略就是今天，格式 YYYY-MM-DD。',
    obj({ 'date': str('YYYY-MM-DD，省略为今天') }, [])));
  list.push(spec('schedule_add', '新建一条日程。date 格式 YYYY-MM-DD，时间是 HH:MM（可省略）。',
    obj({
      'title': str('日程标题'),
      'date': str('YYYY-MM-DD'),
      'start_time': str('开始时间 HH:MM，可省略'),
      'end_time': str('结束时间 HH:MM，可省略'),
      'description': str('备注 / 地点，可省略'),
    }, ['title', 'date'])));
  list.push(spec('schedule_update', '修改一条日程，只传要改的字段；id 来自 schedule_list。',
    obj({
      'id': num('日程 id'),
      'title': str('新标题'),
      'date': str('新日期 YYYY-MM-DD'),
      'start_time': str('新开始时间 HH:MM'),
      'end_time': str('新结束时间 HH:MM'),
      'done': str('是否完成：true / false'),
    }, ['id'])));
  list.push(spec('schedule_delete', '删除一条日程。',
    obj({ 'id': num('日程 id') }, ['id'])));

  // 计时 / 时间
  list.push(spec('time_now', '返回手机当前的本地日期和时间。', obj({}, [])));
  list.push(spec('countdown_add', '新建一个倒计时（重要日期），比如考试、截止日。',
    obj({ 'title': str('名称'), 'date': str('YYYY-MM-DD') }, ['title', 'date'])));
  list.push(spec('countdown_list', '列出已有的倒计时。', obj({}, [])));
  list.push(spec('pomodoro_start', '开始番茄钟（当前版本只记录请求，后台计时还没做）。',
    obj({ 'minutes': num('分钟数，默认 25') }, [])));

  // 备忘 / 闪卡 / 统计
  list.push(spec('memo_search', '在本地备忘里按关键词检索。',
    obj({ 'query': str('关键词，空则列最近几条'), 'limit': num('条数，默认 5') }, [])));
  list.push(spec('memo_append', '往本地备忘里追加一条。',
    obj({ 'text': str('备忘内容') }, ['text'])));
  list.push(spec('flashcards_create', '把学习材料做成问答闪卡（存本地）。cards 是 [{question, answer, tag}]。',
    obj({ 'cards': str('JSON 数组：[{\"question\":\"…\",\"answer\":\"…\",\"tag\":\"…\"}]') }, ['cards'])));
  list.push(spec('usage_stats', '本地使用统计：日程数、备忘数、闪卡数、AI 调用次数。', obj({}, [])));

  // 文献
  list.push(spec('arxiv_search', '在 arXiv 上检索论文。',
    obj({ 'query': str('检索词，英文更好'), 'limit': num('1-10，默认 5') }, ['query'])));
  list.push(spec('crossref_search', '在 Crossref 上检索论文元数据。',
    obj({ 'query': str('检索词'), 'limit': num('1-10，默认 5') }, ['query'])));
  list.push(spec('semantic_scholar_search', '在 Semantic Scholar 上检索论文。',
    obj({ 'query': str('检索词'), 'limit': num('1-10，默认 5') }, ['query'])));
  list.push(spec('doi_lookup', '按 DOI 查询论文元数据。',
    obj({ 'doi': str('DOI，如 10.1145/xxxx') }, ['doi'])));
  list.push(spec('literature_search', '综合检索：arXiv + Crossref 合并去重。',
    obj({ 'query': str('检索词'), 'limit': num('总数上限，默认 8') }, ['query'])));
  list.push(spec('pdf_download', '下载 PDF 到手机应用目录，返回本地路径。',
    obj({ 'url': str('PDF 链接'), 'filename': str('保存的文件名，可省略') }, ['url'])));
  list.push(spec('citation_format', '把一篇文献格式化成引用文本（GB/T 7714 或 APA）。',
    obj({
      'title': str('标题'), 'authors': str('作者，逗号分隔'), 'year': str('年份'),
      'journal': str('期刊/会议，可省略'), 'doi': str('DOI，可省略'),
      'style': str('gbt 或 apa，默认 gbt'),
    }, ['title', 'authors', 'year'])));
  list.push(spec('endnote_export', '把一篇文献导出成 EndNote（.enw）文件，返回路径。',
    obj({
      'title': str('标题'), 'authors': str('作者，逗号分隔'), 'year': str('年份'),
      'journal': str('期刊，可省略'), 'doi': str('DOI，可省略'),
    }, ['title', 'authors', 'year'])));

  // 网络
  list.push(spec('web_search', '网页搜索（用 DuckDuckGo），返回标题 + 链接 + 摘要。',
    obj({ 'query': str('搜索词'), 'limit': num('条数，默认 5') }, ['query'])));
  list.push(spec('web_fetch', '抓一个网页并转成纯文本（截断到 4000 字）。',
    obj({ 'url': str('http/https 链接') }, ['url'])));
  list.push(spec('video_search', '搜索视频（B站等），返回标题和链接。',
    obj({ 'query': str('搜索词') }, ['query'])));

  // 系统 / 文件（沙箱内）
  list.push(spec('sys_info', '手机型号、系统版本、应用版本。', obj({}, [])));
  list.push(spec('fs_read', '读应用沙箱里的文本文件。',
    obj({ 'path': str('绝对路径或相对应用目录的文件名') }, ['path'])));
  list.push(spec('fs_discard', '删掉应用沙箱里的临时文件。',
    obj({ 'path': str('文件路径') }, ['path'])));
  list.push(spec('zip_extract', '把沙箱里的 zip 解压到指定目录。',
    obj({ 'src': str('zip 路径'), 'dst': str('目标目录') }, ['src', 'dst'])));
  list.push(spec('library_open', '打开学校图书馆网站（不需要参数）。', obj({}, [])));

  // 设置 / 帮助
  list.push(spec('setting_get', '读取本地设置项的值。',
    obj({ 'key': str('设置键名') }, ['key'])));
  list.push(spec('setting_set', '写入本地设置项（只允许 ai_ / server_ / mail_ 前缀）。',
    obj({ 'key': str('设置键名'), 'value': str('值') }, ['key', 'value'])));
  list.push(spec('tool_help', '列出手机端现在有哪些工具、各自是干什么的。', obj({}, [])));

  // 邮件 / eLearning：先留入口
  list.push(spec('mail_send', '发一封邮件（需要在设置里填好 SMTP）。',
    obj({
      'to': str('收件人邮箱'), 'subject': str('主题'), 'body': str('正文'),
    }, ['to', 'subject', 'body'])));
  list.push(spec('mail_inbox', '读最近几封邮件的发件人 / 主题 / 日期（IMAP）。',
    obj({ 'limit': num('条数，默认 5') }, [])));
  list.push(spec('elearning_courses', '列出 eLearning 课程（手机端尚未接登录）。', obj({}, [])));
  list.push(spec('timetable_fetch', '获取课表（手机端尚未接教务）。', obj({}, [])));
  list.push(spec('course_resource_search', '搜索课程资源（手机端尚未接 eHall）。',
    obj({ 'query': str('关键词') }, ['query'])));
  list.push(spec('resource_push', '推送资源到 eHall（手机端尚未接）。',
    obj({ 'url': str('资源链接') }, ['url'])));

  return list;
}

/** 手机端列在设置里的工具（名字 + 中文说明） */
export const PHONE_TOOL_NAMES: string[] = [
  'schedule_list', 'schedule_add', 'schedule_update', 'schedule_delete',
  'time_now', 'countdown_add', 'countdown_list', 'pomodoro_start',
  'memo_search', 'memo_append', 'flashcards_create', 'usage_stats',
  'arxiv_search', 'crossref_search', 'semantic_scholar_search', 'doi_lookup',
  'literature_search', 'pdf_download', 'citation_format', 'endnote_export',
  'web_search', 'web_fetch', 'video_search',
  'sys_info', 'fs_read', 'fs_discard', 'zip_extract', 'library_open',
  'setting_get', 'setting_set', 'tool_help',
  'mail_send', 'mail_inbox', 'elearning_courses', 'timetable_fetch', 'course_resource_search', 'resource_push',
];

export const TOOL_LABELS: string[] = [
  '查看日程', '新建日程', '修改日程', '删除日程',
  '当前时间', '加倒计时', '列倒计时', '番茄钟（仅记录）',
  '备忘检索', '追加备忘', '生成闪卡', '使用统计',
  'arXiv 检索', 'Crossref 检索', 'S2 检索', 'DOI 查询',
  '综合文献检索', '下载 PDF', '引用格式', '导出 EndNote',
  '网页搜索', '抓取网页', '视频搜索',
  '设备信息', '读文件', '删临时文件', '解压', '打开图书馆',
  '读设置', '写设置', '工具帮助',
  '发邮件', '收件箱', 'eLearning 课程', '课表', '课程资源', '资源推送',
];

/** 总开关 */
export async function toolsGloballyOn(): Promise<boolean> {
  return (await Db.getSetting(TOOLS_ENABLED_KEY, '0')) === '1';
}

/** 单个工具开关（总开关关着就一律 false） */
export async function toolEnabled(name: string): Promise<boolean> {
  if (!(await toolsGloballyOn())) {
    return false;
  }
  return (await Db.getSetting(toolKey(name), '1')) === '1';
}

/** 按设置过滤出要发给模型的工具列表 */
export async function enabledToolSpecs(): Promise<Object[]> {
  const all = toolSpecs();
  const out: Object[] = [];
  for (const item of all) {
    const fn = (item as Record<string, Object>)['function'] as Record<string, Object>;
    const name = `${fn['name'] ?? ''}`;
    if (await toolEnabled(name)) {
      out.push(item);
    }
  }
  return out;
}
