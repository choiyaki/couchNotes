// フェンス付きコードブロック（``` / ~~~）のライブプレビュー用ウィジェット。
//
// 記法を隠すとき、フェンス行を Decoration.replace で丸ごと消しても .cm-line は残るので、
// そのままだと 1 行ぶんの空白が上下に空いてしまう。
// 代わりに「細い帯」のウィジェットを置き、行側は CSS で行高を 0 に潰す
// （.cm-cn-code-strip-line）。帯の高さがそのまま行の高さになる。
import { WidgetType } from "@codemirror/view";

export class CodeFenceStripWidget extends WidgetType {
  constructor(readonly lang: string, readonly open: boolean) {
    super();
  }
  eq(other: CodeFenceStripWidget) {
    return other.lang === this.lang && other.open === this.open;
  }
  ignoreEvent() {
    return true;
  }
  toDOM() {
    const d = document.createElement("div");
    d.className =
      "cm-cn-code-strip " + (this.open ? "cm-cn-code-strip-open" : "cm-cn-code-strip-close");
    if (this.open && this.lang) {
      const s = document.createElement("span");
      s.className = "cm-cn-code-lang";
      s.textContent = this.lang;
      d.appendChild(s);
    }
    return d;
  }
}
