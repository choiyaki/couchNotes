// ```ocr フェンス（画像内テキスト）の折りたたみ表示。
//
// - ライブプレビューでは既定で閉じ、開きフェンス行に ▶ だけを出す。中身と閉じフェンス行は高さ 0 に潰す。
// - ▶ タップで開く（▼）。開閉は表示状態だけで本文には書かない（同期を走らせない）。
//   ノートを開き直すと閉じた状態に戻る。
// - カーソルがブロックに入れば、他のコードブロックと同じく全体が生記法に戻る（decorations.ts）。
// - 複数行を 1 つのウィジェットに置き換える方式は使わない（1 ソース行 = 1 視覚行の原則を守る）。
import { StateEffect, StateField } from "@codemirror/state";
import { EditorView, WidgetType } from "@codemirror/view";

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
