// 数式（KaTeX）。保存記法は Markdown 互換の $...$（インライン）/ $$...$$（ブロック・1行）。
//
// Cosense と同じ挙動:
//   - 非アクティブ行: 数式記法をレンダリング結果（ウィジェット）に置換。
//     インラインでも \displaystyle を当て、行の高さは数式に合わせて伸びる。
//     幅を超える数式はウィジェット内で横スクロール。
//   - カーソル行: 生の TeX 記法を表示し、行の下にレンダリング結果を
//     フローティング（CM ツールチップ）で表示する。
import katex from "katex";
import "katex/dist/katex.min.css";
import { EditorState, StateField } from "@codemirror/state";
import { EditorView, showTooltip, Tooltip, WidgetType } from "@codemirror/view";
import { livePreviewField, setLivePreview } from "./state";

// 行全体が $$...$$ のブロック数式
export const BLOCK_MATH_RE = /^\s*\$\$([^$]+?)\$\$\s*$/;
// インライン $...$（$$ の一部・改行を含むものは除外）
export const INLINE_MATH_RE = /(?<!\$)\$(?!\$)([^$\n]+?)\$(?!\$)/g;

/** KaTeX でレンダリングして el に流し込む。失敗時は生テキストを出す。 */
function renderTeX(tex: string, block: boolean, el: HTMLElement) {
  try {
    katex.render(block ? tex : `\\displaystyle{${tex}}`, el, {
      displayMode: block,
      throwOnError: false,
    });
  } catch {
    el.textContent = tex;
  }
}

/** 非アクティブ行の数式を描くウィジェット。 */
export class MathWidget extends WidgetType {
  constructor(readonly tex: string, readonly block: boolean) {
    super();
  }
  eq(other: MathWidget) {
    return other.tex === this.tex && other.block === this.block;
  }
  ignoreEvent() {
    return true;
  }
  toDOM() {
    const wrap = document.createElement(this.block ? "div" : "span");
    wrap.className = "cm-cn-math-widget" + (this.block ? " cm-cn-math-block" : "");
    renderTeX(this.tex, this.block, wrap);
    return wrap;
  }
}

/** カーソル行の全数式を集めて、行下のプレビューを作る（Cosense と同じ挙動）。 */
function mathAtCursor(state: EditorState): Tooltip | null {
  if (!state.field(livePreviewField)) return null;
  const head = state.selection.main.head;
  const line = state.doc.lineAt(head);
  const text = line.text;

  const items: Array<{ tex: string; block: boolean }> = [];
  const bm = BLOCK_MATH_RE.exec(text);
  if (bm) {
    items.push({ tex: bm[1], block: true });
  } else {
    INLINE_MATH_RE.lastIndex = 0;
    for (let m: RegExpExecArray | null; (m = INLINE_MATH_RE.exec(text)); ) {
      items.push({ tex: m[1], block: false });
    }
  }
  if (items.length === 0) return null;

  return {
    // 行末をアンカーにする: 行頭だと折り返し行（見た目上の複数行）の
    // 1 行目直下に出てしまい、2 行目以降のテキストに被る。
    // 行末なら折り返しを含めた行全体の下に表示される（Cosense と同じ見え方）。
    pos: line.to,
    above: false,
    strictSide: false,
    arrow: false,
    create: (view: EditorView) => {
      const dom = document.createElement("div");
      dom.className = "cm-cn-math-tooltip";
      for (const item of items) {
        const seg = document.createElement(item.block ? "div" : "span");
        seg.className = "cm-cn-math-tooltip-item";
        renderTeX(item.tex, item.block, seg);
        dom.appendChild(seg);
      }
      return {
        dom,
        // CM の水平位置（アンカー基準）を上書きして、エディタ幅の中央に寄せる
        positioned: () => {
          const rect = view.scrollDOM.getBoundingClientRect();
          const left = rect.left + (rect.width - dom.offsetWidth) / 2;
          dom.style.left = `${Math.max(rect.left + 8, left)}px`;
        },
      };
    },
  };
}

/** カーソル行に数式があれば、行の下にプレビューを出す。 */
export const mathPreview = StateField.define<Tooltip | null>({
  create: mathAtCursor,
  update(value, tr) {
    if (tr.docChanged || tr.selection || tr.effects.some((e) => e.is(setLivePreview))) {
      return mathAtCursor(tr.state);
    }
    return value;
  },
  provide: (f) => showTooltip.from(f),
});
