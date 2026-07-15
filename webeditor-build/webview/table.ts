// 暗黙テーブル: 画像とテキストが混在する行を、ライブプレビューの非アクティブ時に
// 「画像セル＋テキストセル」の横並びレイアウトで表示する（Cosense 発展仕様）。
//
// 設計の要点:
//   - 列幅は決定的に計算する（ブラウザの自動配分に任せない）:
//       残り幅 R = エディタ幅 − 画像幅合計 − セル間ギャップ
//       公平枠 S = R ÷ テキスト列数
//       自然幅が S 以下の列は自然幅のまま（全列収まれば全体が左寄せ）、
//       超える列だけで残りを均等に分け合う。
//   - 高さは「画面外の隠しコンテナで実際にレンダリングして実測」する。
//     測った同じ値をテーブル（固定高さ）とアクティブ行の min-height の両方へ強制するので、
//     カーソルの出入りでレイアウトが動かない（画像行の高さ安定化と同じ原理）。
//   - セル内はプレーンテキスト＋数式（KaTeX）のみ。文字装飾はしない。
//   - タップはカーソルを行末に置く（リンク付き画像のタップはリンクを開く）。
import { EditorView, WidgetType } from "@codemirror/view";
import { attachImageErrorRetry, editorContentWidth, lineImageSizes, noteNaturalSize } from "./images";
import { INLINE_MATH_RE, renderTeX } from "./math";

const CELL_GAP = 8;        // セル間の横ギャップ(px)
const MIN_TEXT_WIDTH = 60; // これよりテキスト領域が狭くなる行はテーブル化しない

interface ImageCell {
  kind: "image";
  url: string;
  w: number;
  h: number;
  href: string | null;
}
interface TextCell {
  kind: "text";
  content: string;
  width: number;  // 割り当て幅(px)。レイアウト計算後に確定
  height: number;
}
type Cell = ImageCell | TextCell;

export interface TableLayout {
  cells: Cell[];
  rowH: number;   // 行全体の高さ(px)。テーブル固定高さ＝アクティブ時の予約高さ
  key: string;    // ウィジェット同一性判定用
}

const IMG_RE_G = /!\[[^\]]*\]\((https?:\/\/[^)\s]+)\)/g;
const LINKED_IMG_RE_G = /\[(!\[[^\]]*\]\((https?:\/\/[^)\s]+)\))\]\((https?:\/\/[^)\s]+)\)/g;

// ---- 画面外の隠し測定 ----------------------------------------------------

let measureBox: HTMLDivElement | null = null;
let fontSig = "";
const naturalWidthCache = new Map<string, number>();
const heightCache = new Map<string, number>();

function measurer(view: EditorView): HTMLDivElement {
  if (!measureBox) {
    measureBox = document.createElement("div");
    Object.assign(measureBox.style, {
      position: "absolute",
      left: "-99999px",
      top: "0",
      visibility: "hidden",
      pointerEvents: "none",
    } as Partial<CSSStyleDeclaration>);
    document.body.appendChild(measureBox);
  }
  // エディタと同じフォント・行間で測る（違うと高さがズレる）
  const content = getComputedStyle(view.contentDOM);
  const lineEl = view.contentDOM.querySelector(".cm-line");
  const lineHeight = lineEl ? getComputedStyle(lineEl).lineHeight : "1.45";
  const sig = `${content.fontFamily}|${content.fontSize}|${lineHeight}`;
  if (sig !== fontSig) {
    fontSig = sig;
    naturalWidthCache.clear();
    heightCache.clear();
  }
  measureBox.style.fontFamily = content.fontFamily;
  measureBox.style.fontSize = content.fontSize;
  measureBox.style.lineHeight = lineHeight;
  return measureBox;
}

/** 測定キャッシュを消す（Web フォント読み込み完了時など）。 */
export function clearTableMeasureCache() {
  fontSig = "";
  naturalWidthCache.clear();
  heightCache.clear();
}

/** セル内の手動改行「//」（Cosense 風）。URL の "://" は改行として扱わない。 */
const CELL_BREAK_RE = /\s*(?<!:)\/\/\s*/;

/** テキストを「//」で改行しながら el に追加する（数式の外側のみ）。 */
function appendTextWithBreaks(el: HTMLElement, text: string) {
  const parts = text.split(CELL_BREAK_RE);
  parts.forEach((part, i) => {
    if (i > 0) el.appendChild(document.createElement("br"));
    if (part) el.appendChild(document.createTextNode(part));
  });
}

/** テキストセルの中身（プレーンテキスト＋ $...$ の KaTeX、// で改行）を el に構築する。
    測定とウィジェット描画の両方でこれを使う＝同じ構造なので実測が正確に一致する。 */
function buildCellContent(el: HTMLElement, content: string) {
  let last = 0;
  INLINE_MATH_RE.lastIndex = 0;
  for (let m: RegExpExecArray | null; (m = INLINE_MATH_RE.exec(content)); ) {
    if (m.index > last) appendTextWithBreaks(el, content.slice(last, m.index));
    const span = document.createElement("span");
    span.className = "cm-cn-math-widget";
    renderTeX(m[1], false, span);
    el.appendChild(span);
    last = m.index + m[0].length;
  }
  if (last < content.length) appendTextWithBreaks(el, content.slice(last));
}

/** セル内容の自然幅（折り返しなしの一行幅）。 */
function naturalWidth(view: EditorView, content: string): number {
  const cached = naturalWidthCache.get(content);
  if (cached != null) return cached;
  const box = measurer(view);
  box.style.width = "auto";
  box.style.whiteSpace = "nowrap";
  box.textContent = "";
  buildCellContent(box, content);
  const w = box.scrollWidth;
  naturalWidthCache.set(content, w);
  return w;
}

/** 指定幅で折り返した時のセル内容の高さ。 */
function wrappedHeight(view: EditorView, content: string, width: number): number {
  const key = `${Math.round(width)}|${content}`;
  const cached = heightCache.get(key);
  if (cached != null) return cached;
  const box = measurer(view);
  box.style.width = `${Math.round(width)}px`;
  box.style.whiteSpace = "normal";
  (box.style as any).overflowWrap = "anywhere";
  box.textContent = "";
  buildCellContent(box, content);
  const h = box.offsetHeight;
  heightCache.set(key, h);
  return h;
}

// ---- 行の分析とレイアウト計算 --------------------------------------------

/** 行を画像セグメントとテキストセグメントに分解する。対象外の行は null。 */
function segmentLine(text: string): Array<
  { kind: "image"; start: number; end: number; url: string; href: string | null }
  | { kind: "text"; content: string }
> | null {
  // 見出し・リスト・チェックボックス・ブロック数式行は対象外（既存の表示を維持）
  if (/^#{1,5} /.test(text)) return null;
  if (/^[\t ]*[-*+] /.test(text)) return null;
  if (/^\s*\$\$[^$]+\$\$\s*$/.test(text)) return null;

  // リンク付き画像 → 外側全体を画像範囲として扱う
  const linkedByInner = new Map<number, { s: number; e: number; href: string }>();
  LINKED_IMG_RE_G.lastIndex = 0;
  for (let m: RegExpExecArray | null; (m = LINKED_IMG_RE_G.exec(text)); ) {
    linkedByInner.set(m.index + 1, { s: m.index, e: m.index + m[0].length, href: m[3] });
  }

  const images: Array<{ start: number; end: number; url: string; href: string | null }> = [];
  IMG_RE_G.lastIndex = 0;
  for (let m: RegExpExecArray | null; (m = IMG_RE_G.exec(text)); ) {
    const linked = linkedByInner.get(m.index);
    images.push({
      start: linked ? linked.s : m.index,
      end: linked ? linked.e : m.index + m[0].length,
      url: m[1],
      href: linked ? linked.href : null,
    });
  }
  if (images.length === 0) return null;

  const segments: Array<
    { kind: "image"; start: number; end: number; url: string; href: string | null }
    | { kind: "text"; content: string }
  > = [];
  let pos = 0;
  let hasText = false;
  for (const img of images) {
    const before = text.slice(pos, img.start).trim();
    if (before) {
      segments.push({ kind: "text", content: before });
      hasText = true;
    }
    segments.push({ kind: "image", ...img });
    pos = img.end;
  }
  const after = text.slice(pos).trim();
  if (after) {
    segments.push({ kind: "text", content: after });
    hasText = true;
  }
  return hasText ? segments : null; // 画像のみの行は対象外
}

/** 行のテーブルレイアウトを計算する。対象外・幅不足なら null。 */
export function tableForLine(view: EditorView, text: string): TableLayout | null {
  const segments = segmentLine(text);
  if (!segments) return null;

  // 先に幅を実測（自己修復）してから画像サイズを引く（lineImageSizes は更新後の幅を使う）
  const W = editorContentWidth(view);
  const imgSizes = lineImageSizes(text);   // IMG_RE の出現順（segmentLine と同順）

  // セル列を組み立て（画像はサイズ確定、テキストは後で幅決定）
  const cells: Cell[] = [];
  let imgIndex = 0;
  let imgWSum = 0;
  for (const seg of segments) {
    if (seg.kind === "image") {
      const size = imgSizes[imgIndex++];
      if (!size) return null;
      cells.push({ kind: "image", url: size.url, w: size.w, h: size.h, href: seg.href });
      imgWSum += size.w;
    } else {
      cells.push({ kind: "text", content: seg.content, width: 0, height: 0 });
    }
  }
  const textCells = cells.filter((c): c is TextCell => c.kind === "text");
  const R = W - imgWSum - CELL_GAP * (cells.length - 1);
  if (R < MIN_TEXT_WIDTH * textCells.length) return null; // テキストが置けないほど狭い

  // 幅配分: 公平枠 S に収まる列は自然幅、超える列だけで残りを分け合う
  const S = R / textCells.length;
  const naturals = textCells.map((c) => naturalWidth(view, c.content));
  const exceeds = naturals.map((n) => n > S);
  const fitSum = naturals.reduce((a, n, i) => a + (exceeds[i] ? 0 : n), 0);
  const exceedCount = exceeds.filter(Boolean).length;
  const share = exceedCount > 0 ? (R - fitSum) / exceedCount : 0;
  textCells.forEach((c, i) => {
    c.width = exceeds[i] ? share : naturals[i];
    c.height = wrappedHeight(view, c.content, c.width);
  });

  const rowH = Math.ceil(
    Math.max(
      ...cells.map((c) => (c.kind === "image" ? c.h : c.height))
    )
  );

  const key =
    `${text}|${Math.round(W)}|${fontSig}|${rowH}|` +
    cells.map((c) => (c.kind === "image" ? `i${Math.round(c.w)}x${Math.round(c.h)}` : `t${Math.round(c.width)}`)).join(",");

  return { cells, rowH, key };
}

// ---- テーブルウィジェット --------------------------------------------------

declare global {
  interface Window {
    webkit: { messageHandlers: { couchNotes: { postMessage(msg: unknown): void } } };
  }
}

export class TableRowWidget extends WidgetType {
  constructor(readonly layout: TableLayout) {
    super();
  }
  eq(other: TableRowWidget) {
    return other.layout.key === this.layout.key;
  }
  ignoreEvent() {
    return true; // タップは自前で処理（行末へカーソル or リンクを開く）
  }
  toDOM(view: EditorView) {
    const wrap = document.createElement("div");
    wrap.className = "cm-cn-table";
    wrap.style.height = `${this.layout.rowH}px`;

    for (const cell of this.layout.cells) {
      if (cell.kind === "image") {
        const holder = document.createElement("span");
        holder.className = "cm-cn-table-img" + (cell.href ? " cm-cn-linked-img" : "");
        if (cell.href) holder.setAttribute("data-href", cell.href);
        const img = document.createElement("img");
        img.src = cell.url;
        img.style.width = `${Math.round(cell.w)}px`;
        img.style.height = `${Math.round(cell.h)}px`;
        img.addEventListener("load", () => {
          noteNaturalSize(cell.url, img.naturalWidth, img.naturalHeight, view);
        });
        attachImageErrorRetry(img);
        holder.appendChild(img);
        wrap.appendChild(holder);
      } else {
        const div = document.createElement("div");
        div.className = "cm-cn-table-cell-text";
        div.style.width = `${Math.round(cell.width)}px`;
        buildCellContent(div, cell.content);
        wrap.appendChild(div);
      }
    }

    wrap.addEventListener("mousedown", (e) => {
      e.preventDefault();
      // リンク付き画像 → リンクを開く
      const linked = (e.target as HTMLElement | null)?.closest?.(".cm-cn-linked-img");
      if (linked) {
        const href = linked.getAttribute("data-href");
        if (href) {
          window.webkit.messageHandlers.couchNotes.postMessage({ type: "openExternal", url: href });
          return;
        }
      }
      // それ以外 → カーソルを行末へ（行がアクティブ化して生記法になる）
      const pos = Math.min(view.posAtDOM(wrap), view.state.doc.length);
      const line = view.state.doc.lineAt(pos);
      view.dispatch({ selection: { anchor: line.to } });
      view.focus();
    });

    return wrap;
  }
}
