/**
 * 极简 Markdown 解析（给聊天回答用）
 * 只做「模型真正会写、界面看得见」的那部分：
 *   标题 / 段落 / 无序列表 / 有序列表 / 引用 / 分隔线 / 围栏代码块 / 表格，
 *   行内 **粗体**、*斜体*、`行内代码`。
 * 表格单元格按纯文本处理（不做行内 span），链接保留原文，避免在 ArkUI 里做点击态。
 */
export enum MdKind {
  Para = 0,
  Heading = 1,
  Code = 2,
  Bullet = 3,
  Ordered = 4,
  Quote = 5,
  Rule = 6,
  Table = 7,
}

export class MdSpan {
  text: string = '';
  bold: boolean = false;
  italic: boolean = false;
  code: boolean = false;
}

export class MdBlock {
  kind: MdKind = MdKind.Para;
  /** 标题级别 1-6；有序列表的序号 */
  level: number = 0;
  /** 代码块语言标记 */
  lang: string = '';
  /** 代码块原文 */
  code: string = '';
  /** 列表前缀（• 或 1.） */
  marker: string = '';
  /** 表格：第一行是表头，其余是数据行；单元格为纯文本，列数已按表头补齐 */
  rows: string[][] = [];
  spans: MdSpan[] = [];
}

function makeSpan(text: string, bold: boolean, italic: boolean, code: boolean): MdSpan {
  const s = new MdSpan();
  s.text = text;
  s.bold = bold;
  s.italic = italic;
  s.code = code;
  return s;
}

/** 找配对的分隔符（后面没闭合就返回 -1，按字面显示） */
function findClose(src: string, from: number, token: string): number {
  const idx = src.indexOf(token, from);
  return idx;
}

/** 行内解析：`code` / **bold** / *italic* / _italic_ */
export function inlineSpans(src: string): MdSpan[] {
  const out: MdSpan[] = [];
  let buf = '';
  let i = 0;
  const flush = (): void => {
    if (buf.length > 0) {
      out.push(makeSpan(buf, false, false, false));
      buf = '';
    }
  };
  while (i < src.length) {
    const c = src.charAt(i);
    if (c === '`') {
      const j = findClose(src, i + 1, '`');
      if (j > i + 1) {
        flush();
        out.push(makeSpan(src.substring(i + 1, j), false, false, true));
        i = j + 1;
        continue;
      }
      buf += c;
      i += 1;
      continue;
    }
    if (c === '*' && src.startsWith('**', i)) {
      const j = findClose(src, i + 2, '**');
      if (j > i + 2) {
        flush();
        out.push(makeSpan(src.substring(i + 2, j), true, false, false));
        i = j + 2;
        continue;
      }
      buf += c;
      i += 1;
      continue;
    }
    if (c === '*' || c === '_') {
      const token = c === '*' ? '*' : '_';
      const j = findClose(src, i + 1, token);
      if (j > i + 1) {
        flush();
        out.push(makeSpan(src.substring(i + 1, j), false, true, false));
        i = j + 1;
        continue;
      }
      buf += c;
      i += 1;
      continue;
    }
    buf += c;
    i += 1;
  }
  flush();
  return out;
}

function headingLevel(line: string): number {
  let n = 0;
  while (n < line.length && line.charAt(n) === '#') {
    n += 1;
  }
  if (n === 0 || n > 6) {
    return 0;
  }
  if (n < line.length && line.charAt(n) !== ' ') {
    return 0;
  }
  return n;
}

function isRule(line: string): boolean {
  const t = line.trim();
  if (t.length < 3) {
    return false;
  }
  const head = t.charAt(0);
  if (head !== '-' && head !== '*' && head !== '_') {
    return false;
  }
  for (let i = 0; i < t.length; i += 1) {
    const ch = t.charAt(i);
    if (ch !== head && ch !== ' ') {
      return false;
    }
  }
  return true;
}

/** 有序列表前缀：返回序号，不是则 0 */
function orderedNumber(line: string): number {
  const t = line.trimStart();
  let i = 0;
  while (i < t.length && t.charAt(i) >= '0' && t.charAt(i) <= '9') {
    i += 1;
  }
  if (i === 0 || i > 3) {
    return 0;
  }
  if (i >= t.length) {
    return 0;
  }
  const c = t.charAt(i);
  if (c !== '.' && c !== ')') {
    return 0;
  }
  if (i + 1 < t.length && t.charAt(i + 1) !== ' ') {
    return 0;
  }
  return parseInt(t.substring(0, i), 10);
}

function bulletBody(line: string): string {
  const t = line.trimStart();
  if (t.length < 2) {
    return '';
  }
  const c = t.charAt(0);
  if (c !== '-' && c !== '*' && c !== '+') {
    return '';
  }
  if (t.charAt(1) !== ' ') {
    return '';
  }
  return t.substring(2).trim();
}

/** 按 | 切分表格行：去掉首尾分隔符产生的空项，单元格 trim */
function splitCells(line: string): string[] {
  const parts = line.trim().split('|');
  let start = 0;
  let end = parts.length;
  if (end > start && parts[start].trim().length === 0) {
    start += 1;
  }
  if (end > start && parts[end - 1].trim().length === 0) {
    end -= 1;
  }
  const cells: string[] = [];
  for (let k = start; k < end; k += 1) {
    cells.push(parts[k].trim());
  }
  return cells;
}

/** 表格分隔行：形如 | --- | :--: |，每格只允许 -、:、空格且至少一个 - */
function isTableSeparator(line: string): boolean {
  if (line.indexOf('|') < 0) {
    return false;
  }
  const cells = splitCells(line);
  if (cells.length === 0) {
    return false;
  }
  for (let k = 0; k < cells.length; k += 1) {
    const cell = cells[k];
    if (cell.length === 0) {
      return false;
    }
    let dashes = 0;
    for (let m = 0; m < cell.length; m += 1) {
      const ch = cell.charAt(m);
      if (ch === '-') {
        dashes += 1;
      } else if (ch !== ':' && ch !== ' ') {
        return false;
      }
    }
    if (dashes === 0) {
      return false;
    }
  }
  return true;
}

/** 把一行的单元格对齐到表头列数：缺的补空字符串，多的截掉 */
function fitRow(cells: string[], cols: number): string[] {
  const row: string[] = [];
  for (let k = 0; k < cols; k += 1) {
    row.push(k < cells.length ? cells[k] : '');
  }
  return row;
}

function pushTextBlock(out: MdBlock[], kind: MdKind, text: string): void {
  const b = new MdBlock();
  b.kind = kind;
  b.spans = inlineSpans(text);
  out.push(b);
}

export function parseMarkdown(src: string): MdBlock[] {
  const out: MdBlock[] = [];
  const text = src.replace(/\r/g, '');
  const lines = text.split('\n');
  const para: string[] = [];
  const flushPara = (): void => {
    if (para.length > 0) {
      pushTextBlock(out, MdKind.Para, para.join(' '));
      para.splice(0, para.length);
    }
  };
  let i = 0;
  while (i < lines.length) {
    const raw = lines[i];
    const line = raw.trim();

    // 围栏代码块
    if (line.startsWith('```')) {
      flushPara();
      const lang = line.substring(3).trim();
      const body: string[] = [];
      i += 1;
      while (i < lines.length && lines[i].trim() !== '```') {
        body.push(lines[i]);
        i += 1;
      }
      if (i < lines.length) {
        i += 1;
      }
      const b = new MdBlock();
      b.kind = MdKind.Code;
      b.lang = lang;
      b.code = body.join('\n');
      out.push(b);
      continue;
    }

    if (line.length === 0) {
      flushPara();
      i += 1;
      continue;
    }

    // 表格：当前行含 |，且下一行是 | --- | :--: | 形式的分隔行
    const nextLine = i + 1 < lines.length ? lines[i + 1].trim() : '';
    if (line.indexOf('|') >= 0 && isTableSeparator(nextLine)) {
      const header = splitCells(line);
      if (header.length > 0) {
        flushPara();
        const cols = header.length;
        const b = new MdBlock();
        b.kind = MdKind.Table;
        b.rows.push(fitRow(header, cols));
        // 跳过表头行与分隔行
        i += 2;
        while (i < lines.length) {
          const rowLine = lines[i].trim();
          // 空行或不再含 | 即结束表格，剩下的行交回外层正常解析
          if (rowLine.length === 0 || rowLine.indexOf('|') < 0) {
            break;
          }
          b.rows.push(fitRow(splitCells(rowLine), cols));
          i += 1;
        }
        out.push(b);
        continue;
      }
    }

    if (isRule(line)) {
      flushPara();
      const b = new MdBlock();
      b.kind = MdKind.Rule;
      out.push(b);
      i += 1;
      continue;
    }

    const h = headingLevel(line);
    if (h > 0) {
      flushPara();
      const b = new MdBlock();
      b.kind = MdKind.Heading;
      b.level = h;
      b.spans = inlineSpans(line.substring(h + 1).trim());
      out.push(b);
      i += 1;
      continue;
    }

    if (line.startsWith('>')) {
      flushPara();
      const b = new MdBlock();
      b.kind = MdKind.Quote;
      b.spans = inlineSpans(line.substring(1).trim());
      out.push(b);
      i += 1;
      continue;
    }

    const num = orderedNumber(raw);
    if (num > 0) {
      flushPara();
      const t = raw.trimStart();
      let p = 0;
      while (p < t.length && ((t.charAt(p) >= '0' && t.charAt(p) <= '9') ||
        t.charAt(p) === '.' || t.charAt(p) === ')' || t.charAt(p) === ' ')) {
        p += 1;
      }
      const b = new MdBlock();
      b.kind = MdKind.Ordered;
      b.level = num;
      b.marker = `${num}.`;
      b.spans = inlineSpans(t.substring(p).trim());
      out.push(b);
      i += 1;
      continue;
    }

    const bullet = bulletBody(raw);
    if (bullet.length > 0) {
      flushPara();
      const b = new MdBlock();
      b.kind = MdKind.Bullet;
      b.marker = '•';
      b.spans = inlineSpans(bullet);
      out.push(b);
      i += 1;
      continue;
    }

    para.push(line);
    i += 1;
  }
  flushPara();
  return out;
}
