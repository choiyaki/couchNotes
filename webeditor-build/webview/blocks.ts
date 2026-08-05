// Markdown の「複数行ブロック」（``` フェンス付きコードブロック / | テーブル）の地図。
//
// なぜ StateField でドキュメント全体を走査するか:
//   decorations.ts の build() は可視範囲しか回さない。フェンスの開閉はそれより前の行に
//   依存するので、ビューポート内だけを見ても「今この行がコードブロックの中か」が判定できない。
//   docChanged のたびに 1 回だけ全行を走査して地図を作り、描画側はそれを引くだけにする。
//
// ここで作るのは「範囲と構造」だけ。列幅・行高のようにビュー（フォント・幅）に依存する値は
// State には持たせず、mdtable.ts が描画時に実測する。
import { StateField, Text } from "@codemirror/state";

export type Align = "left" | "center" | "right" | null;

export interface CodeBlock {
  kind: "code";
  from: number;             // ブロックの先頭行番号（= 開きフェンス行）
  to: number;               // 末尾行番号（閉じフェンスが無ければ最終行）
  closeLine: number | null; // 閉じフェンス行。未閉鎖なら null
  lang: string;             // 情報文字列（```swift の "swift"）
}

export interface TableBlock {
  kind: "table";
  from: number;             // ヘッダ行
  to: number;               // 最終データ行
  sepLine: number;          // 区切り行（= from + 1）
  aligns: Align[];          // 列ごとの寄せ（区切り行の : から）
  cells: string[][];        // from..to の各行のセル。区切り行は空配列
}

export type Block = CodeBlock | TableBlock;

export interface BlockMap {
  blocks: Block[];
  byLine: Map<number, Block>;
}

// 先頭に空白を許した ``` / ~~~ フェンス。capture2=フェンス文字列, capture3=情報文字列
const FENCE_RE = /^[\t ]*(`{3,}|~{3,})(.*)$/;
// テーブル行の候補（先頭が | の行）
const TABLE_ROW_RE = /^[\t ]*\|/;

/** テーブル行をセルに分解する。前後の | は省略可、\| はエスケープされた | として扱う。 */
export function splitRow(text: string): string[] {
  let body = text.trim();
  if (body.startsWith("|")) body = body.slice(1);
  if (body.endsWith("|") && !body.endsWith("\\|")) body = body.slice(0, -1);
  const cells: string[] = [];
  let cur = "";
  for (let i = 0; i < body.length; i++) {
    const ch = body[i];
    if (ch === "\\" && body[i + 1] === "|") {
      cur += "|";
      i++;
      continue;
    }
    if (ch === "|") {
      cells.push(cur.trim());
      cur = "";
      continue;
    }
    cur += ch;
  }
  cells.push(cur.trim());
  return cells;
}

/** 区切り行（|---|:--:|）か。全セルが -/: だけで構成されていること。 */
function isSeparatorRow(cells: string[]): boolean {
  return cells.length > 0 && cells.every((c) => /^:?-+:?$/.test(c));
}

function alignOf(cell: string): Align {
  const l = cell.startsWith(":");
  const r = cell.endsWith(":");
  if (l && r) return "center";
  if (r) return "right";
  if (l) return "left";
  return null;
}

export function parseBlocks(doc: Text): BlockMap {
  const blocks: Block[] = [];
  const byLine = new Map<number, Block>();
  const total = doc.lines;

  const push = (blk: Block) => {
    blocks.push(blk);
    for (let m = blk.from; m <= blk.to; m++) byLine.set(m, blk);
  };

  let n = 1;
  while (n <= total) {
    const text = doc.line(n).text;

    // --- コードフェンス ---
    const fence = FENCE_RE.exec(text);
    if (fence) {
      const marker = fence[1];
      const ch = marker[0];
      const info = fence[2].trim();
      // 情報文字列にフェンス文字が混ざるものは開きフェンスではない
      // （例: `` `x` `` の行や ```` ```a``` ```` のような 1 行完結の書き方）
      if (!info.includes(ch)) {
        let closeLine: number | null = null;
        for (let m = n + 1; m <= total; m++) {
          const f = FENCE_RE.exec(doc.line(m).text);
          if (f && f[1][0] === ch && f[1].length >= marker.length && f[2].trim() === "") {
            closeLine = m;
            break;
          }
        }
        // 未閉鎖のフェンスは CommonMark どおり文書末までをブロックとする。
        // （書きかけが灰色に伸びるのは「閉じ忘れ」のはっきりした手がかりになる）
        const to = closeLine ?? total;
        push({ kind: "code", from: n, to, closeLine, lang: info });
        n = to + 1;
        continue;
      }
    }

    // --- Markdown テーブル（ヘッダ行 + 区切り行が必須）---
    if (TABLE_ROW_RE.test(text) && n + 1 <= total) {
      const sepText = doc.line(n + 1).text;
      if (TABLE_ROW_RE.test(sepText)) {
        const header = splitRow(text);
        const sep = splitRow(sepText);
        if (isSeparatorRow(sep) && sep.length === header.length) {
          let end = n + 1;
          while (end + 1 <= total && TABLE_ROW_RE.test(doc.line(end + 1).text)) end++;
          const cells: string[][] = [];
          for (let m = n; m <= end; m++) {
            cells.push(m === n + 1 ? [] : splitRow(doc.line(m).text));
          }
          push({
            kind: "table",
            from: n,
            to: end,
            sepLine: n + 1,
            aligns: sep.map(alignOf),
            cells,
          });
          n = end + 1;
          continue;
        }
      }
    }

    n++;
  }

  return { blocks, byLine };
}

export const blocksField = StateField.define<BlockMap>({
  create: (state) => parseBlocks(state.doc),
  update(value, tr) {
    return tr.docChanged ? parseBlocks(tr.state.doc) : value;
  },
});
