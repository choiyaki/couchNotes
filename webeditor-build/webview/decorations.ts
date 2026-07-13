// MarkdownStyler.swift の移植。CM6 の Decoration で生のテキストをその場装飾する。
import { Range } from "@codemirror/state";
import {
  Decoration,
  DecorationSet,
  EditorView,
  ViewPlugin,
  ViewUpdate,
} from "@codemirror/view";
import { wikiTargetsField } from "./state";

const TAB_SIZE = 2;

const WIKI_RE = /\[\[([^\]]+)\]\]/g;
// 画像でない Markdown リンク [text](http...)。先頭の ! を除外。
const MD_LINK_RE = /(?<!!)\[[^\]]*\]\((https?:\/\/[^)\s]+)\)/g;
// 画像 Markdown ![alt](http...)。
const IMG_MD_RE = /!\[[^\]]*\]\((https?:\/\/[^)\s]+)\)/g;
const BARE_URL_RE = /https?:\/\/[^\s)\]]+/g;
const BLOCK_ID_RE = /\^[a-zA-Z0-9_-]+$/;

const lineDeco = (cls: string) => Decoration.line({ class: cls });
const hangDeco = (padCh: number) =>
  Decoration.line({ attributes: { style: `padding-left:${padCh}ch;text-indent:-${padCh}ch` } });
const mark = (cls: string) => Decoration.mark({ class: cls });

interface Ctx {
  wiki: Set<string>;
  activeLines: Set<number>; // カーソル／選択がある行番号
}

function styleLine(
  view: EditorView,
  lineFrom: number,
  lineNumber: number,
  text: string,
  out: Range<Decoration>[],
  ctx: Ctx
) {
  const active = ctx.activeLines.has(lineNumber);
  // --- 見出し ---
  const head = /^(#{1,3}) /.exec(text);
  if (head) {
    const level = head[1].length;
    const cls = level === 1 ? "cm-cn-h1" : level === 2 ? "cm-cn-h2" : "cm-cn-h3";
    out.push(lineDeco(cls).range(lineFrom));
    const markerLen = level + 1; // "# " = 2, "## " = 3, "### " = 4
    out.push(mark("cm-cn-marker").range(lineFrom, lineFrom + markerLen));
    styleInline(text, lineFrom, active, out, ctx);
    return;
  }

  // --- リスト / チェックボックス ---
  const lead = /^[\t ]*/.exec(text)?.[0] ?? "";
  const tabs = (lead.match(/\t/g) ?? []).length;
  const spaces = lead.length - tabs;
  const stripped = text.slice(lead.length);
  const markerLoc = lineFrom + lead.length;
  const leadCols = tabs * TAB_SIZE + spaces;

  let markerLen = 0;

  if (/^[-*] \[ \]/.test(stripped)) {
    out.push(mark("cm-cn-task-open").range(markerLoc, markerLoc + 5));
    markerLen = 6;
  } else if (/^[-*] \[x\]/i.test(stripped)) {
    out.push(mark("cm-cn-task-done-marker").range(markerLoc, markerLoc + 5));
    if (stripped.length > 6) {
      out.push(mark("cm-cn-task-done-body").range(markerLoc + 6, lineFrom + text.length));
    }
    markerLen = 6;
  } else if (/^[-*+] /.test(stripped)) {
    out.push(mark("cm-cn-marker").range(markerLoc, markerLoc + 2));
    markerLen = 2;
  }

  if (markerLen > 0) {
    // ぶら下げインデント（折り返し行を本文位置に揃える）
    out.push(hangDeco(leadCols + markerLen).range(lineFrom));
  }

  styleInline(text, lineFrom, active, out, ctx);

  // --- ブロック ID ^abc（行末） ---
  const bid = BLOCK_ID_RE.exec(text);
  if (bid) {
    const s = lineFrom + bid.index;
    out.push(mark("cm-cn-blockid").range(s, s + bid[0].length));
  }
}

function styleInline(
  text: string,
  lineFrom: number,
  active: boolean,
  out: Range<Decoration>[],
  ctx: Ctx
) {
  // covered: 後続の裸 URL 判定でスキップする範囲（Markdown リンク・画像）
  const covered: Array<[number, number]> = [];

  // 画像 Markdown ![](url): 常に少し小さく、非アクティブ行ならグレーで目立たなく。
  // ここで covered に入れることで、内側 URL が外部リンク装飾（青下線）を拾わないようにする。
  IMG_MD_RE.lastIndex = 0;
  for (let m: RegExpExecArray | null; (m = IMG_MD_RE.exec(text)); ) {
    const s = lineFrom + m.index;
    const e = s + m[0].length;
    out.push(mark(active ? "cm-cn-imgmd" : "cm-cn-imgmd cm-cn-imgmd-dim").range(s, e));
    covered.push([m.index, m.index + m[0].length]);
  }

  // Wiki リンク [[...]]
  WIKI_RE.lastIndex = 0;
  for (let m: RegExpExecArray | null; (m = WIKI_RE.exec(text)); ) {
    const inner = m[1].toLowerCase();
    const cls = ctx.wiki.has(inner) ? "cm-cn-wiki" : "cm-cn-wiki-missing";
    out.push(mark(cls).range(lineFrom + m.index, lineFrom + m.index + m[0].length));
  }

  // Markdown リンク（画像 ![]() は除外）
  MD_LINK_RE.lastIndex = 0;
  for (let m: RegExpExecArray | null; (m = MD_LINK_RE.exec(text)); ) {
    const s = lineFrom + m.index;
    const e = s + m[0].length;
    out.push(mark("cm-cn-link").range(s, e));
    covered.push([m.index, m.index + m[0].length]);
  }

  // 裸 URL（Markdown リンク・画像内は除外）
  BARE_URL_RE.lastIndex = 0;
  for (let m: RegExpExecArray | null; (m = BARE_URL_RE.exec(text)); ) {
    const inCovered = covered.some(([a, b]) => m!.index >= a && m!.index < b);
    if (inCovered) continue;
    out.push(mark("cm-cn-link").range(lineFrom + m.index, lineFrom + m.index + m[0].length));
  }
}

function build(view: EditorView): DecorationSet {
  const names = view.state.field(wikiTargetsField);
  // カーソル／選択が掛かっている行番号を集める（画像 Markdown のアクティブ判定用）
  const activeLines = new Set<number>();
  for (const r of view.state.selection.ranges) {
    const a = view.state.doc.lineAt(r.from).number;
    const b = view.state.doc.lineAt(r.to).number;
    for (let n = a; n <= b; n++) activeLines.add(n);
  }
  const ctx: Ctx = { wiki: new Set(names.map((n) => n.toLowerCase())), activeLines };
  const out: Range<Decoration>[] = [];
  for (const { from, to } of view.visibleRanges) {
    let pos = from;
    while (pos <= to) {
      const line = view.state.doc.lineAt(pos);
      if (line.length > 0) styleLine(view, line.from, line.number, line.text, out, ctx);
      pos = line.to + 1;
    }
  }
  return Decoration.set(out, true);
}

export const liveStyling = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    constructor(view: EditorView) {
      this.decorations = build(view);
    }
    update(u: ViewUpdate) {
      if (
        u.docChanged ||
        u.viewportChanged ||
        u.selectionSet || // カーソル移動で画像 Markdown の淡色 ON/OFF を切り替える
        u.startState.field(wikiTargetsField) !== u.state.field(wikiTargetsField)
      ) {
        this.decorations = build(u.view);
      }
    }
  },
  { decorations: (v) => v.decorations }
);
