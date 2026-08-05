// Markdown テーブル（| a | b |）のライブプレビュー。
//
// 設計の要点（カーソル挙動を壊さないための制約）:
//   - ブロックウィジェット（block: true）は使わない。1 ソース行 = 1 視覚行を保ち、
//     各行を「その行だけの」インライン replace ウィジェットに置き換える。
//     CM から見れば普通の行のままなので、矢印キー・選択・IME の挙動は変わらない。
//   - 「生記法に戻る」判定はブロック単位（decorations.ts 側）。カーソルがテーブル内の
//     どこかにあればテーブル全体が生表示になるので、1 行ずつ崩れて見えることがない。
//   - 列幅は決定的に計算する（table.ts の隠しコンテナで自然幅を実測）。行は折り返さず、
//     幅を超えたら横スクロールする。行ごとに独立したスクローラになるため、同じテーブルの
//     行同士は scrollLeft を同期させる（下の registerRow）。
import { EditorView, WidgetType } from "@codemirror/view";
import { Align, TableBlock } from "./blocks";
import { buildCellContent, cellNaturalWidth, editorLineHeight } from "./table";

const CELL_PAD_H = 10; // セル左右の内側余白(px)。CSS の .cm-cn-mdtable-cell と一致させる
const CELL_PAD_V = 3;  // セル上下の内側余白(px)。同上
const MIN_COL_W = 28;  // 空列でも潰れないようにする最小列幅(px)

export interface MdTableLayout {
  key: string;      // ブロック同一性（スクロール同期・ウィジェット比較用）
  colW: number[];   // 列幅(px)。パディング込み
  totalW: number;   // 全列の合計幅(px)
  viewW: number;    // 行スクローラの幅(px)＝本文が使える幅
  rowH: number;     // 1 行の高さ(px)
  aligns: Align[];
}

/** 本文が使える幅。.cm-content の clientWidth は使わない:
    .cm-content は .cm-scroller の flex アイテム（flex-shrink:0）で中身に合わせて伸びるため、
    横スクロールするテーブルを入れると幅が自分自身の内容で膨らみ、循環参照になる。
    スクローラ（＝ビューポート）の幅から本文パディングを引いて求める。 */
function availableWidth(view: EditorView): number {
  const cs = getComputedStyle(view.contentDOM);
  const pad = (parseFloat(cs.paddingLeft) || 0) + (parseFloat(cs.paddingRight) || 0);
  const w = view.scrollDOM.clientWidth - pad;
  return w > 0 ? Math.floor(w) : 360;
}

export function layoutMdTable(view: EditorView, block: TableBlock): MdTableLayout {
  const nCol = block.aligns.length;
  const colW = new Array<number>(nCol).fill(0);
  for (const row of block.cells) {
    if (row.length === 0) continue; // 区切り行
    for (let i = 0; i < nCol; i++) {
      const w = cellNaturalWidth(view, row[i] ?? "");
      if (w > colW[i]) colW[i] = w;
    }
  }
  for (let i = 0; i < nCol; i++) {
    colW[i] = Math.max(Math.ceil(colW[i]) + CELL_PAD_H * 2, MIN_COL_W);
  }
  const totalW = colW.reduce((a, b) => a + b, 0);
  const viewW = availableWidth(view);
  const rowH = Math.ceil(editorLineHeight(view)) + CELL_PAD_V * 2;
  const key = `mdt:${block.from}:${colW.join(",")}:${block.aligns.join(",")}:${rowH}:${viewW}`;
  return { key, colW, totalW, viewW, rowH, aligns: block.aligns };
}

// ---- 行同士の横スクロール同期 ----------------------------------------------
// 各行は別々の .cm-line の中にあるので 1 つのスクローラにまとめられない。
// 同じテーブル（key）の行を集めておき、どれかが横スクロールしたら他にも同じ
// scrollLeft を書き込む。ウィジェットは再生成されるので、位置は key 単位で保持し、
// 新しく作られた行はそれを復元する。
const scrollPos = new Map<string, number>();
const liveRows = new Map<string, Set<HTMLElement>>();
let syncing = false;

function registerRow(key: string, el: HTMLElement) {
  let set = liveRows.get(key);
  if (!set) {
    set = new Set();
    liveRows.set(key, set);
  }
  set.add(el);
  const group = set;
  el.addEventListener(
    "scroll",
    () => {
      if (syncing) return;
      const x = el.scrollLeft;
      scrollPos.set(key, x);
      syncing = true;
      for (const other of group) if (other !== el) other.scrollLeft = x;
      syncing = false;
    },
    { passive: true }
  );
  const x = scrollPos.get(key);
  // scrollLeft はレイアウト確定後でないと効かない（内側幅がまだ 0）
  if (x) requestAnimationFrame(() => { el.scrollLeft = x; });
}

function unregisterRow(key: string, el: HTMLElement) {
  const set = liveRows.get(key);
  if (!set) return;
  set.delete(el);
  if (set.size === 0) liveRows.delete(key);
  // scrollPos は残す: 再描画で一旦全行が消えてもスクロール位置を失わないため
}

// ---- ウィジェット ----------------------------------------------------------

export class MdTableRowWidget extends WidgetType {
  constructor(
    readonly layout: MdTableLayout,
    readonly cells: string[],
    readonly isHeader: boolean,
    readonly isLast: boolean
  ) {
    super();
  }
  eq(other: MdTableRowWidget) {
    return (
      other.layout.key === this.layout.key &&
      other.isHeader === this.isHeader &&
      other.isLast === this.isLast &&
      other.cells.length === this.cells.length &&
      other.cells.every((c, i) => c === this.cells[i])
    );
  }
  ignoreEvent() {
    return true; // タップは下の listener が処理（CM にカーソル配置させない）
  }
  toDOM(view: EditorView) {
    const wrap = document.createElement("div");
    wrap.className =
      "cm-cn-mdtable-row" +
      (this.isHeader ? " cm-cn-mdtable-head" : "") +
      (this.isLast ? " cm-cn-mdtable-last" : "");
    // 幅を px で固定する: 幅が auto（＝内容依存）だと .cm-content が中身の幅まで
    // 伸びてしまい、エディタ全体が横スクロールしてしまう。
    wrap.style.width = `${this.layout.viewW}px`;
    wrap.style.height = `${this.layout.rowH}px`;

    const inner = document.createElement("div");
    inner.className = "cm-cn-mdtable-inner";
    inner.style.width = `${this.layout.totalW}px`;
    for (let i = 0; i < this.layout.colW.length; i++) {
      const cell = document.createElement("div");
      cell.className = "cm-cn-mdtable-cell";
      cell.style.width = `${this.layout.colW[i]}px`;
      const a = this.layout.aligns[i];
      if (a) cell.style.textAlign = a;
      buildCellContent(cell, this.cells[i] ?? "", false);
      inner.appendChild(cell);
    }
    wrap.appendChild(inner);
    registerRow(this.layout.key, wrap);

    wrap.addEventListener("mousedown", (e) => {
      e.preventDefault();
      // カーソルを対応するソース行の行末へ（ブロック全体が生記法に戻る）
      const pos = Math.min(view.posAtDOM(wrap), view.state.doc.length);
      const line = view.state.doc.lineAt(pos);
      view.dispatch({ selection: { anchor: line.to } });
      view.focus();
    });

    return wrap;
  }
  destroy(dom: HTMLElement) {
    unregisterRow(this.layout.key, dom);
  }
}

/** 区切り行（|---|---|）の代わりに引くヘッダ下の罫線。
    行そのものは残す（カーソルは行けるし、ブロックが生表示になれば元の文字が出る）。 */
export class MdTableRuleWidget extends WidgetType {
  constructor(readonly key: string, readonly width: number) {
    super();
  }
  eq(other: MdTableRuleWidget) {
    return other.key === this.key && other.width === this.width;
  }
  ignoreEvent() {
    return true;
  }
  toDOM() {
    const d = document.createElement("div");
    d.className = "cm-cn-mdtable-rule";
    d.style.width = `${this.width}px`;
    return d;
  }
}
