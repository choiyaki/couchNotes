// MarkdownStyler.swift の移植 + ライブプレビュー（記法隠し）。
// CM6 の Decoration で生のテキストをその場装飾する。
// ライブプレビュー時は「カーソル・選択が乗っている行」だけ生の記法を表示し、
// それ以外の行では記法（## / ** / [[ ]] / [](url) / - 等）を隠す（Cosense 風）。
// 記法隠しは Decoration.replace（DOM から取り除く）が基本で、contenteditable=false の
// DOM 島を作らない。唯一の例外はリストの「•」ウィジェット（極小・inline）。
import { Range } from "@codemirror/state";
import {
  Decoration,
  DecorationSet,
  EditorView,
  ViewPlugin,
  ViewUpdate,
  WidgetType,
} from "@codemirror/view";
import { wikiTargetsField, livePreviewField } from "./state";
import { lineImageSizes, InlineImageWidget, imagesChanged, editorContentWidth } from "./images";
import { MathWidget, BLOCK_MATH_RE, INLINE_MATH_RE } from "./math";
import { tableForLine, TableRowWidget } from "./table";
import { toggleCheckboxAt } from "./commands";

const TAB_SIZE = 2;

const WIKI_RE = /\[\[([^\]]+)\]\]/g;
// 画像でない Markdown リンク [text](http...)。先頭の ! を除外。capture1=テキスト, capture2=URL。
const MD_LINK_RE = /(?<!!)\[([^\]]*)\]\((https?:\/\/[^)\s]+)\)/g;
// 画像 Markdown ![alt](http...)。
const IMG_MD_RE = /!\[[^\]]*\]\((https?:\/\/[^)\s]+)\)/g;
// リンク付き画像 [![alt](imgurl)](url)。capture1=画像部, capture2=画像URL, capture3=リンク先URL。
const LINKED_IMG_RE = /\[(!\[[^\]]*\]\((https?:\/\/[^)\s]+)\))\]\((https?:\/\/[^)\s]+)\)/g;
const BARE_URL_RE = /https?:\/\/[^\s)\]]+/g;
const BLOCK_ID_RE = /\^[a-zA-Z0-9_-]+$/;
const BOLD_RE = /\*\*([^*\n]+?)\*\*/g;
const STRIKE_RE = /~~([^~\n]+?)~~/g;
// 斜体: 単独の * ペア（** の一部や 単語*単語 は除外）
const ITALIC_RE = /(?<![*\w])\*([^*\n]+?)\*(?!\*)/g;

const lineDeco = (cls: string) => Decoration.line({ class: cls });
const hangDeco = (padCh: number) =>
  Decoration.line({ attributes: { style: `padding-left:${padCh}ch;text-indent:-${padCh}ch` } });
const mark = (cls: string) => Decoration.mark({ class: cls });
const hidden = Decoration.replace({});

/** リストマーカー「- 」の代わりに表示するビュレット。
    テキストグリフはフォントごとにインク位置が揺れて checkbox と中心が揃わないため、
    checkbox と同一のボックスモデル＋SVG 背景の円で描く（構造的に中心が一致する）。 */
class BulletWidget extends WidgetType {
  toDOM() {
    const s = document.createElement("span");
    s.className = "cm-cn-bullet";
    return s;
  }
  eq() {
    return true;
  }
  ignoreEvent() {
    return true;
  }
}
const bulletReplace = Decoration.replace({ widget: new BulletWidget() });

/** チェックボックス「- [ ] / - [x]」の代わりに表示する ☐/☑（タップでトグル） */
class CheckboxWidget extends WidgetType {
  constructor(readonly checked: boolean) {
    super();
  }
  eq(other: CheckboxWidget) {
    return other.checked === this.checked;
  }
  ignoreEvent() {
    return true; // タップは下の listener が処理（CM はカーソル配置しない）
  }
  toDOM(view: EditorView) {
    const s = document.createElement("span");
    s.className =
      "cm-cn-checkbox " + (this.checked ? "cm-cn-checkbox-done" : "cm-cn-checkbox-open");
    s.addEventListener("mousedown", (e) => {
      e.preventDefault();
      e.stopPropagation();
      const pos = view.posAtDOM(s);
      toggleCheckboxAt(view, pos);
    });
    return s;
  }
}
const checkboxOpenReplace = Decoration.replace({ widget: new CheckboxWidget(false) });
const checkboxDoneReplace = Decoration.replace({ widget: new CheckboxWidget(true) });

/** ライブプレビューのリスト行用インデント: タブ・マーカーを隠した分を padding で作る。
    先頭行はグリフ（1.25em 幅）ぶんだけ左に出し、折り返し行は本文位置に揃える。
    単位は em（1 階層 = 1.5em）。ch はプロポーショナル・日本語フォントでタブ幅と
    一致せず、生表示との間で位置がずれるため使わない。 */
const GLYPH_EM = 1.25;           // •/☐ グリフの占有幅
const INDENT_EM_PER_COL = 0.75;  // 1 カラム（タブ=2カラム）あたりの字下げ
const listIndentDeco = (leadCols: number) =>
  Decoration.line({
    attributes: {
      style: `padding-left:${(leadCols * INDENT_EM_PER_COL + GLYPH_EM).toFixed(2)}em;text-indent:-${GLYPH_EM}em`,
    },
  });

interface Ctx {
  wiki: Set<string>;
  activeLines: Set<number>; // カーソル／選択がある行番号
  livePreview: boolean;
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
  const hide = ctx.livePreview && !active; // この行の記法を隠すか

  // --- ブロック数式（行全体が $$...$$）---
  const blockMath = BLOCK_MATH_RE.exec(text);
  if (blockMath) {
    if (hide) {
      out.push(
        Decoration.replace({ widget: new MathWidget(blockMath[1], true) })
          .range(lineFrom, lineFrom + text.length)
      );
    } else {
      out.push(mark("cm-cn-math").range(lineFrom, lineFrom + text.length));
    }
    return;
  }

  // --- 暗黙テーブル（画像＋テキスト混在行、ライブプレビューのみ）---
  // 非アクティブ: 行全体をテーブルウィジェット（固定高さ rowH）に置換。
  // アクティブ: 生記法＋同じ rowH を min-height で予約（高さが一致し、出入りで動かない）。
  if (ctx.livePreview) {
    const table = tableForLine(view, text);
    if (table) {
      if (hide) {
        out.push(
          Decoration.replace({ widget: new TableRowWidget(table) })
            .range(lineFrom, lineFrom + text.length)
        );
      } else {
        styleInline(text, lineFrom, active, hide, out, ctx, true);
        out.push(
          Decoration.line({
            class: "cm-cn-imgline-active",
            attributes: { style: `min-height:${table.rowH + 4}px` },
          }).range(lineFrom)
        );
      }
      return;
    }
  }

  // --- 見出し（# 〜 #####）---
  const head = /^(#{1,5}) /.exec(text);
  if (head) {
    const level = head[1].length;
    const cls = ["cm-cn-h1", "cm-cn-h2", "cm-cn-h3", "cm-cn-h4", "cm-cn-h5"][level - 1];
    out.push(lineDeco(cls).range(lineFrom));
    const markerLen = level + 1; // "# " = 2, "## " = 3, "### " = 4
    if (hide) {
      out.push(hidden.range(lineFrom, lineFrom + markerLen));
    } else {
      out.push(mark("cm-cn-marker").range(lineFrom, lineFrom + markerLen));
    }
    styleInline(text, lineFrom, active, hide, out, ctx);
    return;
  }

  // --- 引用（> ...）---
  const quote = /^>[ \t]?/.exec(text);
  if (quote) {
    out.push(lineDeco("cm-cn-quote").range(lineFrom));
    const markerLen = quote[0].length;
    if (hide) {
      out.push(hidden.range(lineFrom, lineFrom + markerLen));
    } else {
      out.push(mark("cm-cn-marker").range(lineFrom, lineFrom + markerLen));
    }
    styleInline(text, lineFrom, active, hide, out, ctx);
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
  // ライブプレビューではタブ＋マーカーをまとめてグリフに置換し、階層インデントは
  // padding で作る（タブを残すと text-indent とタブ幅計算が干渉して全階層が左端に寄る）。
  let hideLead = false;

  if (/^[-*] \[ \]/.test(stripped)) {
    if (hide) {
      const end = markerLoc + (/^[-*] \[ \] /.test(stripped) ? 6 : 5);
      out.push(checkboxOpenReplace.range(lineFrom, end));
      hideLead = true;
    } else {
      out.push(mark("cm-cn-task-open").range(markerLoc, markerLoc + 5));
    }
    markerLen = 6;
  } else if (/^[-*] \[x\]/i.test(stripped)) {
    if (hide) {
      const end = markerLoc + (/^[-*] \[x\] /i.test(stripped) ? 6 : 5);
      out.push(checkboxDoneReplace.range(lineFrom, end));
      hideLead = true;
    } else {
      out.push(mark("cm-cn-task-done-marker").range(markerLoc, markerLoc + 5));
    }
    if (stripped.length > 6) {
      out.push(mark("cm-cn-task-done-body").range(markerLoc + 6, lineFrom + text.length));
    }
    markerLen = 6;
  } else if (/^[-*+] /.test(stripped)) {
    if (hide) {
      out.push(bulletReplace.range(lineFrom, markerLoc + 2));   // タブごと置換
      hideLead = true;
    } else {
      out.push(mark("cm-cn-marker").range(markerLoc, markerLoc + 2));
    }
    markerLen = 2;
  }

  // リスト項目の中身が引用（"- > ..." 等）: リストのインデント・マーカーはそのまま、
  // 引用の縦線を「マーカー（•/☐）と本文の間」に描く。border-left は行の左端（ドットより
  // 左）に出てしまうため使わず、背景グラデーションで任意の x 位置に縦線を置く
  // （レイアウトを乱さず、折り返し行も含めた行全体の高さに伸びる）。
  if (markerLen > 0) {
    const rest = stripped.slice(markerLen);
    const nestedQuote = /^>[ \t]?/.exec(rest);
    if (nestedQuote) {
      // 本文の開始位置（listIndentDeco の padding-left と同じ）から少し左に線を置く。
      const pad = leadCols * INDENT_EM_PER_COL + GLYPH_EM;
      const barX = (pad - 0.45).toFixed(2);
      out.push(
        Decoration.line({
          attributes: {
            class: "cm-cn-quote-fg",
            style:
              `background:linear-gradient(var(--cn-quote-bar),var(--cn-quote-bar)) no-repeat;` +
              `background-size:2px 100%;background-position:${barX}em 0`,
          },
        }).range(lineFrom)
      );
      const qs = markerLoc + markerLen;
      const qLen = nestedQuote[0].length;
      if (hide) {
        out.push(hidden.range(qs, qs + qLen));
      } else {
        out.push(mark("cm-cn-marker").range(qs, qs + qLen));
      }
    }
  }

  if (markerLen > 0) {
    if (hideLead) {
      out.push(listIndentDeco(leadCols).range(lineFrom));
    } else {
      // ぶら下げインデント（折り返し行を本文位置に揃える）
      out.push(hangDeco(leadCols + markerLen).range(lineFrom));
    }
  }

  styleInline(text, lineFrom, active, hide, out, ctx);

  // --- ブロック ID ^abc（行末） ---
  const bid = BLOCK_ID_RE.exec(text);
  if (bid) {
    const s = lineFrom + bid.index;
    if (hide) {
      out.push(hidden.range(s, s + bid[0].length));
    } else {
      out.push(mark("cm-cn-blockid").range(s, s + bid[0].length));
    }
  }
}

function styleInline(
  text: string,
  lineFrom: number,
  active: boolean,
  hide: boolean,
  out: Range<Decoration>[],
  ctx: Ctx,
  skipImageReserve = false   // テーブル行は予約高さを styleLine 側（テーブル高さ）で入れる
) {
  // covered: 後続の裸 URL・強調判定でスキップする範囲（Markdown リンク・画像）
  const covered: Array<[number, number]> = [];

  // リンク付き画像 [![](img)](url): 内側の画像とセットで扱う。
  const linkedByInner = new Map<number, { s: number; e: number; href: string }>();
  LINKED_IMG_RE.lastIndex = 0;
  for (let m: RegExpExecArray | null; (m = LINKED_IMG_RE.exec(text)); ) {
    linkedByInner.set(m.index + 1, { s: m.index, e: m.index + m[0].length, href: m[3] });
  }

  // 画像 Markdown ![](url):
  //   ライブプレビュー・非アクティブ行: 記法位置に画像そのものをインライン表示。
  //   ライブプレビュー・アクティブ行: 画像は出さず、行に画像ぶんの高さを min-height で予約して
  //     生の記法を表示する。非アクティブ時と行の高さが一致するので、カーソルの出入りで
  //     レイアウトが動かない（仕様1: 高さ安定化）。
  //   ライブプレビュー無効時: 従来どおり記法を小さく表示し、画像はオーバーレイが行下に描く。
  const imgSizes = ctx.livePreview ? lineImageSizes(text) : null;
  let imgIndex = 0;
  IMG_MD_RE.lastIndex = 0;
  for (let m: RegExpExecArray | null; (m = IMG_MD_RE.exec(text)); ) {
    const linked = linkedByInner.get(m.index);
    const rs = linked ? linked.s : m.index;               // 置換・装飾の範囲（リンク付きは外側全体）
    const re = linked ? linked.e : m.index + m[0].length;
    const s = lineFrom + rs;
    const e = lineFrom + re;
    const size = imgSizes?.[imgIndex];
    if (hide) {
      if (size) {
        out.push(
          Decoration.replace({
            widget: new InlineImageWidget(size.url, size.w, size.h, linked?.href ?? null),
          }).range(s, e)
        );
      } else {
        out.push(hidden.range(s, e));
      }
    } else {
      out.push(mark(active ? "cm-cn-imgmd" : "cm-cn-imgmd cm-cn-imgmd-dim").range(s, e));
    }
    covered.push([rs, re]);
    imgIndex++;
  }

  // ライブプレビューのアクティブ行: 画像ぶんの高さを予約（+4 はインライン画像の上下 margin 2px×2）。
  // 予約領域は薄い灰色にして「この縦幅が画像」だと分かるようにする。
  if (ctx.livePreview && !hide && !skipImageReserve && imgSizes && imgSizes.length > 0) {
    const rowH = Math.max(...imgSizes.map((sz) => sz.h));
    out.push(
      Decoration.line({
        class: "cm-cn-imgline-active",
        attributes: { style: `min-height:${Math.round(rowH) + 4}px` },
      }).range(lineFrom)
    );
  }

  // Wiki リンク [[...]]（ライブプレビューでは括弧を隠して名前だけ）。
  // Obsidian 形式の [[ページ#^ブロックID|エイリアス]] に対応:
  //   - 存在判定はページ名部分（# と | より前）で行う
  //   - エイリアスがあれば、非アクティブ行では [[ページ#^ID| までを隠してエイリアスだけ表示
  WIKI_RE.lastIndex = 0;
  for (let m: RegExpExecArray | null; (m = WIKI_RE.exec(text)); ) {
    const inner = m[1];
    const bar = inner.indexOf("|");
    const alias = bar >= 0 ? inner.slice(bar + 1) : "";
    const targetFull = bar >= 0 ? inner.slice(0, bar) : inner; // ページ名#フラグメント
    const hash = targetFull.indexOf("#");
    // NFC 正規化: Obsidian インポート由来のノート名は NFD（macOS ファイル名）のことがあり、
    // 手入力のリンク（NFC）とコードポイントが一致しない。見た目が同じなら一致させる。
    const page = (hash >= 0 ? targetFull.slice(0, hash) : targetFull)
      .trim().toLowerCase().normalize("NFC");
    const cls = ctx.wiki.has(page) ? "cm-cn-wiki" : "cm-cn-wiki-missing";
    const s = lineFrom + m.index;
    const e = s + m[0].length;
    if (hide) {
      if (alias.length > 0) {
        // "[[ページ#^ID|" を隠し、エイリアスだけリンク表示
        const aliasStart = s + 2 + targetFull.length + 1;
        out.push(hidden.range(s, aliasStart));
        out.push(mark(cls).range(aliasStart, e - 2));
        out.push(hidden.range(e - 2, e));
      } else {
        out.push(hidden.range(s, s + 2));
        out.push(mark(cls).range(s + 2, e - 2));
        out.push(hidden.range(e - 2, e));
      }
    } else {
      out.push(mark(cls).range(s, e));
    }
    covered.push([m.index, m.index + m[0].length]);
  }

  // Markdown リンク [text](url)（ライブプレビューではテキストだけ）
  MD_LINK_RE.lastIndex = 0;
  for (let m: RegExpExecArray | null; (m = MD_LINK_RE.exec(text)); ) {
    const s = lineFrom + m.index;
    const e = s + m[0].length;
    const textLen = m[1].length;
    if (hide) {
      out.push(hidden.range(s, s + 1)); // "["
      out.push(mark("cm-cn-link").range(s + 1, s + 1 + textLen));
      out.push(hidden.range(s + 1 + textLen, e)); // "](url)"
    } else {
      out.push(mark("cm-cn-link").range(s, e));
    }
    covered.push([m.index, m.index + m[0].length]);
  }

  const inCovered = (idx: number) => covered.some(([a, b]) => idx >= a && idx < b);

  // インライン数式 $...$（非アクティブ行は \displaystyle でレンダリング）
  INLINE_MATH_RE.lastIndex = 0;
  for (let m: RegExpExecArray | null; (m = INLINE_MATH_RE.exec(text)); ) {
    if (inCovered(m.index)) continue;
    const s = lineFrom + m.index;
    const e = s + m[0].length;
    if (hide) {
      out.push(
        Decoration.replace({ widget: new MathWidget(m[1], false) }).range(s, e)
      );
    } else {
      out.push(mark("cm-cn-marker").range(s, s + 1));
      out.push(mark("cm-cn-math").range(s + 1, e - 1));
      out.push(mark("cm-cn-marker").range(e - 1, e));
    }
    covered.push([m.index, m.index + m[0].length]);
  }

  // 太字 **text**
  BOLD_RE.lastIndex = 0;
  for (let m: RegExpExecArray | null; (m = BOLD_RE.exec(text)); ) {
    if (inCovered(m.index)) continue;
    const s = lineFrom + m.index;
    const e = s + m[0].length;
    if (hide) {
      out.push(hidden.range(s, s + 2));
      out.push(mark("cm-cn-bold").range(s + 2, e - 2));
      out.push(hidden.range(e - 2, e));
    } else {
      out.push(mark("cm-cn-marker").range(s, s + 2));
      out.push(mark("cm-cn-bold").range(s + 2, e - 2));
      out.push(mark("cm-cn-marker").range(e - 2, e));
    }
    covered.push([m.index, m.index + m[0].length]);
  }

  // 取り消し線 ~~text~~
  STRIKE_RE.lastIndex = 0;
  for (let m: RegExpExecArray | null; (m = STRIKE_RE.exec(text)); ) {
    if (inCovered(m.index)) continue;
    const s = lineFrom + m.index;
    const e = s + m[0].length;
    if (hide) {
      out.push(hidden.range(s, s + 2));
      out.push(mark("cm-cn-strike").range(s + 2, e - 2));
      out.push(hidden.range(e - 2, e));
    } else {
      out.push(mark("cm-cn-marker").range(s, s + 2));
      out.push(mark("cm-cn-strike").range(s + 2, e - 2));
      out.push(mark("cm-cn-marker").range(e - 2, e));
    }
    covered.push([m.index, m.index + m[0].length]);
  }

  // 斜体 *text*（** の一部は除外済み）
  ITALIC_RE.lastIndex = 0;
  for (let m: RegExpExecArray | null; (m = ITALIC_RE.exec(text)); ) {
    if (inCovered(m.index)) continue;
    const s = lineFrom + m.index;
    const e = s + m[0].length;
    if (hide) {
      out.push(hidden.range(s, s + 1));
      out.push(mark("cm-cn-italic").range(s + 1, e - 1));
      out.push(hidden.range(e - 1, e));
    } else {
      out.push(mark("cm-cn-marker").range(s, s + 1));
      out.push(mark("cm-cn-italic").range(s + 1, e - 1));
      out.push(mark("cm-cn-marker").range(e - 1, e));
    }
  }

  // 裸 URL（Markdown リンク・画像内は除外）
  BARE_URL_RE.lastIndex = 0;
  for (let m: RegExpExecArray | null; (m = BARE_URL_RE.exec(text)); ) {
    if (inCovered(m.index)) continue;
    out.push(mark("cm-cn-link").range(lineFrom + m.index, lineFrom + m.index + m[0].length));
  }
}

function build(view: EditorView): DecorationSet {
  // エディタ幅をその場で実測して自己修復（古い幅のままだと画像・テーブルが横パディングを無視する）
  editorContentWidth(view);
  const names = view.state.field(wikiTargetsField);
  // カーソル／選択が掛かっている行番号を集める（記法の生表示・画像 Markdown のアクティブ判定用）。
  // フォーカスが無い時（キーボード非表示・ページ開いた直後）はアクティブ行を作らず全行プレビュー。
  const activeLines = new Set<number>();
  if (view.hasFocus) {
    for (const r of view.state.selection.ranges) {
      const a = view.state.doc.lineAt(r.from).number;
      const b = view.state.doc.lineAt(r.to).number;
      for (let n = a; n <= b; n++) activeLines.add(n);
    }
  }
  const ctx: Ctx = {
    // NFC 正規化してから照合（NFD なノート名と手入力リンクの見かけ上の一致を拾う）
    wiki: new Set(names.map((n) => n.toLowerCase().normalize("NFC"))),
    activeLines,
    livePreview: view.state.field(livePreviewField),
  };
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
        u.selectionSet || // カーソル移動で記法の生表示/プレビューを切り替える
        u.focusChanged || // フォーカス喪失で全行プレビュー／取得でカーソル行を生表示に
        u.startState.field(wikiTargetsField) !== u.state.field(wikiTargetsField) ||
        u.startState.field(livePreviewField) !== u.state.field(livePreviewField) ||
        // 画像の実寸判明・エディタ幅変化でインライン画像のサイズを作り直す
        u.transactions.some((t) => t.effects.some((e) => e.is(imagesChanged)))
      ) {
        this.decorations = build(u.view);
      }
    }
  },
  { decorations: (v) => v.decorations }
);
