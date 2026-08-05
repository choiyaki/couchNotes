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
import { livePreviewField, setLivePreview, editorFocusedField, setEditorFocused } from "./state";

// 行全体が $$...$$ のブロック数式
export const BLOCK_MATH_RE = /^\s*\$\$([^$]+?)\$\$\s*$/;
// インライン $...$（$$ の一部・改行を含むものは除外）
export const INLINE_MATH_RE = /(?<!\$)\$(?!\$)([^$\n]+?)\$(?!\$)/g;

// ---- KaTeX へ渡す前の記法補正 ----------------------------------------------
// 手書きのノートに多い「LaTeX としては不正だが意図は明らか」な連立方程式の書き方を
// KaTeX が通せる形に直す。対象は 2 つ:
//
//   1. `\left{` / `\right}`
//      \left の直後は「区切り記号」でなければならず、`{` はグループの開始記号。
//      KaTeX は対応する `}` を探して \right にぶつかり、式全体をエラー（赤い生テキスト）
//      として描いてしまう。`\left{` は正しい TeX として存在しないので、`\left\{` への
//      置換で壊れる式は無い。
//   2. `\left…\right` の中の `\\`
//      環境が無いと `\\` は改行として働かず（KaTeX も "does nothing" と警告する）、
//      連立方程式が 1 行に並んでしまう。中身を array で包んで意図どおり段組みにする。

const LEFT = "\\left";
const RIGHT = "\\right";

/** \left / \right の直後にある区切り記号の文字数。`\{` `\|` は 2、`\lbrace` はコマンド長。 */
function delimLength(tex: string, i: number): number {
  if (tex[i] !== "\\") return 1;
  if (/[a-zA-Z]/.test(tex[i + 1] ?? "")) {
    let j = i + 1;
    while (j < tex.length && /[a-zA-Z]/.test(tex[j])) j++;
    return j - i;
  }
  return 2; // \{ \} \| \.
}

/** i 以降で最初の `\left`（\leftarrow 等の別コマンドは飛ばす）。無ければ -1。 */
function nextCommand(tex: string, from: number, cmd: string): number {
  for (let i = tex.indexOf(cmd, from); i >= 0; i = tex.indexOf(cmd, i + 1)) {
    if (!/[a-zA-Z]/.test(tex[i + cmd.length] ?? "")) return i;
  }
  return -1;
}

/** from 以降で、入れ子を数えながら対応する `\right` の位置を返す。無ければ -1。 */
function matchingRight(tex: string, from: number): number {
  let depth = 0;
  let i = from;
  while (i < tex.length) {
    const l = nextCommand(tex, i, LEFT);
    const r = nextCommand(tex, i, RIGHT);
    if (r < 0) return -1;
    if (l >= 0 && l < r) {
      depth++;
      i = l + LEFT.length;
      continue;
    }
    if (depth === 0) return r;
    depth--;
    i = r + RIGHT.length;
  }
  return -1;
}

/** array で包むべき中身か（改行があるのに環境が無い）。 */
function needsArray(body: string): boolean {
  return /\\\\/.test(body) && !/\\begin\s*\{/.test(body);
}

/** 各行の `&` の数から array の列指定（左寄せ）を作る。 */
function arrayCols(body: string): string {
  const cols = body
    .split(/\\\\/)
    .reduce((max, row) => Math.max(max, (row.match(/(?<!\\)&/g) ?? []).length + 1), 1);
  return "l".repeat(cols);
}

/** `\left…\right` を走査し、改行を含む中身を array で包む（入れ子も処理する）。 */
function wrapLineBreaks(tex: string): string {
  let out = "";
  let i = 0;
  while (i < tex.length) {
    const l = nextCommand(tex, i, LEFT);
    if (l < 0) {
      out += tex.slice(i);
      break;
    }
    const bodyStart = l + LEFT.length + delimLength(tex, l + LEFT.length);
    const close = matchingRight(tex, bodyStart);
    if (close < 0) {
      // 対応する \right が無い（書きかけ等）: 触らずそのまま送る
      out += tex.slice(i, bodyStart);
      i = bodyStart;
      continue;
    }
    // 包むかどうかは「元の中身」で判定する。入れ子を先に処理してしまうと、
    // こちらが入れた \begin{array} を「ユーザーが書いた環境」と誤認してしまう。
    const raw = tex.slice(bodyStart, close);
    const body = wrapLineBreaks(raw);
    const wrapped = needsArray(raw)
      ? `\\begin{array}{${arrayCols(raw)}}${body}\\end{array}`
      : body;
    const afterRight = close + RIGHT.length + delimLength(tex, close + RIGHT.length);
    out += tex.slice(i, bodyStart) + wrapped + tex.slice(close, afterRight);
    i = afterRight;
  }
  return out;
}

/** KaTeX に渡す前の記法補正。上のコメントの 1・2 を順に適用する。 */
export function normalizeTeX(tex: string): string {
  const delims = tex.replace(/\\left\{/g, "\\left\\{").replace(/\\right\}/g, "\\right\\}");
  return wrapLineBreaks(delims);
}

/** KaTeX でレンダリングして el に流し込む。失敗時は生テキストを出す。 */
export function renderTeX(tex: string, block: boolean, el: HTMLElement) {
  const src = normalizeTeX(tex);
  try {
    katex.render(block ? src : `\\displaystyle{${src}}`, el, {
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
  // フォーカスが無い時は行自体がレンダリング表示になるのでプレビューは出さない
  if (!state.field(editorFocusedField)) return null;
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
    if (
      tr.docChanged ||
      tr.selection ||
      tr.effects.some((e) => e.is(setLivePreview) || e.is(setEditorFocused))
    ) {
      return mathAtCursor(tr.state);
    }
    return value;
  },
  provide: (f) => showTooltip.from(f),
});
