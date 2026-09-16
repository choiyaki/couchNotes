// ```ocr フェンス（画像内テキスト）の折りたたみ表示。
//
// - ライブプレビューでは既定で閉じ、開きフェンス行に ▶ だけを出す。中身と閉じフェンス行は高さ 0 に潰す。
// - ▶ タップで開く（▼）。開閉は表示状態だけで本文には書かない（同期を走らせない）。
//   ノートを開き直すと閉じた状態に戻る。
// - カーソルがブロックに入れば、他のコードブロックと同じく全体が生記法に戻る（decorations.ts）。
// - 複数行を 1 つのウィジェットに置き換える方式は使わない（1 ソース行 = 1 視覚行の原則を守る）。
// - 画像メニュー「文字を取り込む」（imagemenu.ts）の結果もここで画像行の直後へ挿入する。
import { EditorState, StateEffect, StateField } from "@codemirror/state";
import { EditorView, WidgetType } from "@codemirror/view";
import { blocksField, CodeBlock } from "./blocks";

/** 情報文字列の最初の語が ocr か（```ocr gyazo:xxxx のような付加情報も許す） */
export function isOcrLang(lang: string): boolean {
  return lang.split(/\s+/)[0].toLowerCase() === "ocr";
}

const OCR_FENCE_RE = /^[\t ]*(`{3,}|~{3,})[\t ]*ocr(\s|$)/i;

/** 開きフェンス行の先頭位置を指定して開閉を反転する */
export const toggleOcr = StateEffect.define<number>();

/** 開いている ocr ブロック（開きフェンス行の先頭位置）の集合 */
export const ocrOpenField = StateField.define<ReadonlySet<number>>({
  create: () => new Set(),
  update(value, tr) {
    let next = value;
    if (tr.docChanged && value.size > 0) {
      const mapped = new Set<number>();
      for (const pos of value) {
        const p = tr.changes.mapPos(pos, 1);
        // 行頭のまま ocr フェンスとして残っているものだけ保持する
        if (p > tr.state.doc.length) continue;
        const line = tr.state.doc.lineAt(p);
        if (line.from === p && OCR_FENCE_RE.test(line.text)) mapped.add(p);
      }
      next = mapped;
    }
    for (const e of tr.effects) {
      if (!e.is(toggleOcr)) continue;
      const s = new Set(next);
      if (s.has(e.value)) s.delete(e.value);
      else s.add(e.value);
      next = s;
    }
    return next;
  },
});

/** 開きフェンス行に置く ▶ / ▼ */
export class OcrToggleWidget extends WidgetType {
  constructor(readonly open: boolean) {
    super();
  }
  eq(other: OcrToggleWidget) {
    return other.open === this.open;
  }
  ignoreEvent() {
    return true; // タップは下の listener が処理（CM はカーソル配置しない＝キーボードを出さない）
  }
  toDOM(view: EditorView) {
    const s = document.createElement("span");
    s.className = "cm-cn-ocr-toggle";
    s.textContent = this.open ? "▼" : "▶";
    s.addEventListener("mousedown", (e) => {
      e.preventDefault();
      e.stopPropagation();
      const line = view.state.doc.lineAt(Math.min(view.posAtDOM(s), view.state.doc.length));
      view.dispatch({ effects: toggleOcr.of(line.from) });
    });
    return s;
  }
}

/** 行 lineNo（画像行）の直後にある ```ocr ブロック（閉じフェンスあり）。無ければ null */
export function ocrBlockAfter(state: EditorState, lineNo: number): CodeBlock | null {
  if (lineNo >= state.doc.lines) return null;
  const b = state.field(blocksField).byLine.get(lineNo + 1);
  if (b && b.kind === "code" && b.from === lineNo + 1 && b.closeLine !== null && isOcrLang(b.lang)) {
    return b;
  }
  return null;
}

/** 認識結果を、url の画像行（複数あれば hintLine に最も近い行）の直後へ ```ocr として入れる。
    既に ```ocr があれば置き換える。画像が消えていれば何もしない。 */
export function applyOcrResult(view: EditorView, url: string, text: string, hintLine: number) {
  const doc = view.state.doc;
  const needle = `](${url})`;
  let best = -1;
  for (let n = 1; n <= doc.lines; n++) {
    const t = doc.line(n).text;
    if (!t.includes("![") || !t.includes(needle)) continue;
    if (best < 0 || Math.abs(n - hintLine) < Math.abs(best - hintLine)) best = n;
  }
  if (best < 0) return;

  const body = text
    .replace(/\r\n?/g, "\n")
    .split("\n")
    .map((l) => l.replace(/\s+$/, ""))
    .join("\n")
    .trim();
  if (!body) return;
  // 本文にフェンスが含まれても閉じてしまわないよう、それより長いフェンスで囲む
  let run = 0;
  for (const m of body.matchAll(/^[\t ]*(`{3,})/gm)) run = Math.max(run, m[1].length);
  const fence = "`".repeat(Math.max(3, run + 1));
  const block = `${fence}ocr\n${body}\n${fence}`;

  const existing = ocrBlockAfter(view.state, best);
  const change = existing
    ? { from: doc.line(existing.from).from, to: doc.line(existing.closeLine!).to, insert: block }
    : { from: doc.line(best).to, to: doc.line(best).to, insert: "\n" + block };
  view.dispatch({ changes: change, userEvent: "input" });
}
