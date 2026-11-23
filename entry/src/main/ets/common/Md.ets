/**
 * 极简 Markdown 解析（给聊天回答用）
 * 只做「模型真正会写、界面看得见」的那部分：
 *   标题 / 段落 / 无序列表 / 有序列表 / 引用 / 分隔线 / 围栏代码块，
 *   行内 **粗体**、*斜体*、`行内代码`。
 * 表格不特殊处理（按段落显示），链接保留原文，避免在 ArkUI 里做点击态。
 */
export enum MdKind {
  Para = 0,
  Heading = 1,
  Code = 2,
  Bullet = 3,
  Ordered = 4,
  Quote = 5,
  Rule = 6,
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
