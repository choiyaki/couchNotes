// 画像 ![](http...) のインライン表示。
// ネイティブ版（UITextView）と同じ「画像行の下に padding で余白を予約し、
// そこへ絶対配置の <img> を重ねる」オーバーレイ方式。
//
// 以前のブロックウィジェット方式（contenteditable=false の DOM 島を行間に挿入）は、
// iOS のスペース長押しカーソル移動・選択ハンドル操作が島を跨ぐ時に
// ネイティブ選択が乱れる（勝手に選択化・範囲が飛ぶ）ため廃止した。
// 本文の DOM は純粋なテキスト行のままなので、ネイティブ選択は画像の存在を感知しない。
//
// 拡張仕様（従来どおり）:
//   - ![|30](url) のように alt に |数値 を書くと、エディタ幅のその % を「幅」に指定。
//   - 同一行に複数の画像 URL を書くと横並び表示。幅指定の無い画像は残り幅を均等割り。
import { EditorState, Range, StateEffect, StateField } from "@codemirror/state";
import { Decoration, DecorationSet, EditorView, ViewPlugin, ViewUpdate } from "@codemirror/view";

const PLACEHOLDER_HEIGHT = 200; // 実寸が分かるまでの予約高さ（native placeholderHeight と同値）
const GAP = 6;                  // 行と画像・画像同士の間隔

interface ImgSpec {
  url: string;
  widthPct: number | null;
}

// ![alt](url) / ![|30](url) / ![alt|30](url)
const IMG_RE = /!\[([^\]]*)\]\((https?:\/\/[^)\s]+)\)/g;

function parseLine(text: string): ImgSpec[] {
  const specs: ImgSpec[] = [];
  IMG_RE.lastIndex = 0;
  for (let m: RegExpExecArray | null; (m = IMG_RE.exec(text)); ) {
    const w = /\|\s*(\d+)/.exec(m[1]);
    specs.push({ url: m[2], widthPct: w ? Number(w[1]) : null });
  }
  return specs;
}

// 読み込み済み画像の実寸キャッシュとエディタ幅（モジュール共有）
const naturalSizes = new Map<string, { w: number; h: number }>();
let editorWidth = 0;
let viewRef: EditorView | null = null;

/** 画像レイアウトの再計算が必要になった（実寸判明・エディタ幅変化） */
const imagesChanged = StateEffect.define<void>();

/** .cm-content の左右 padding（テキストの実開始位置）。config の横インセットもここに乗る。 */
function contentPadding(view: EditorView): { left: number; right: number } {
  const cs = getComputedStyle(view.contentDOM);
  return {
    left: parseFloat(cs.paddingLeft) || 0,
    right: parseFloat(cs.paddingRight) || 0,
  };
}

/** テキストが実際に使える幅（padding を除いた内側）。 */
function availableWidth(view: EditorView): number {
  const pad = contentPadding(view);
  return view.contentDOM.clientWidth - pad.left - pad.right;
}

/** 設定変更（横インセット等）で padding が変わった時に、画像レイアウトを作り直す。 */
export function refreshImageLayout() {
  if (!viewRef) return;
  const w = availableWidth(viewRef);
  if (w > 0) editorWidth = w;
  viewRef.dispatch({ effects: imagesChanged.of() });
}

/** グループ内の各画像の表示サイズ（native displaySize 相当） */
function groupSizes(specs: ImgSpec[], width: number): { w: number; h: number }[] {
  const sumSpecified = specs.reduce((a, s) => a + (s.widthPct ?? 0), 0);
  const unspecCount = specs.filter((s) => s.widthPct == null).length;
  const evenPct = unspecCount > 0 ? Math.max(0, 100 - sumSpecified) / unspecCount : 0;

  return specs.map((s) => {
    const nat = naturalSizes.get(s.url);
    if (s.widthPct != null || specs.length > 1) {
      const w = ((width - GAP * (specs.length - 1)) * (s.widthPct ?? evenPct)) / 100;
      return { w, h: nat ? (w * nat.h) / nat.w : PLACEHOLDER_HEIGHT };
    }
    // 単一・指定なし: 横長は幅を、縦長は高さをエディタ幅の 50% に
    if (!nat) return { w: width * 0.5, h: PLACEHOLDER_HEIGHT };
    const half = width * 0.5;
    return nat.w >= nat.h
      ? { w: half, h: (half * nat.h) / nat.w }
      : { w: (half * nat.w) / nat.h, h: half };
  });
}

/** 画像行に padding-bottom で余白を予約する行デコレーション */
function buildPaddings(state: EditorState): DecorationSet {
  const width = editorWidth || 360;
  const out: Range<Decoration>[] = [];
  for (let i = 1; i <= state.doc.lines; i++) {
    const line = state.doc.line(i);
    const specs = parseLine(line.text);
    if (specs.length === 0) continue;
    const rowH = Math.max(...groupSizes(specs, width).map((s) => s.h));
    const pad = Math.round(rowH) + GAP * 2;
    out.push(
      Decoration.line({ attributes: { style: `padding-bottom:${pad}px` } }).range(line.from)
    );
  }
  return Decoration.set(out, true);
}

const imagePaddingField = StateField.define<DecorationSet>({
  create: buildPaddings,
  update(deco, tr) {
    if (tr.docChanged || tr.effects.some((e) => e.is(imagesChanged))) {
      return buildPaddings(tr.state);
    }
    return deco;
  },
  provide: (f) => EditorView.decorations.from(f),
});

interface Placed {
  url: string;
  x: number;
  y: number;
  w: number;
  h: number;
}

/** 予約した余白へ <img> を絶対配置するオーバーレイ */
const imageOverlay = ViewPlugin.fromClass(
  class {
    container: HTMLDivElement;
    ro: ResizeObserver;

    constructor(readonly view: EditorView) {
      viewRef = view;
      // オーバーレイをコンテンツと一緒にスクロールさせるため、スクローラを基準にする
      view.scrollDOM.style.position = "relative";
      this.container = document.createElement("div");
      this.container.className = "cm-cn-image-overlay";
      Object.assign(this.container.style, {
        position: "absolute",
        top: "0",
        left: "0",
        width: "0",
        height: "0",
        pointerEvents: "none", // タッチ・選択操作は本文へ素通しする
      } as Partial<CSSStyleDeclaration>);
      view.scrollDOM.appendChild(this.container);
      this.ro = new ResizeObserver(() => this.syncWidth());
      this.ro.observe(view.scrollDOM);
      this.schedule();
    }

    syncWidth() {
      const w = availableWidth(this.view);
      if (w > 0 && Math.abs(w - editorWidth) > 1) {
        editorWidth = w;
        requestAnimationFrame(() => viewRef?.dispatch({ effects: imagesChanged.of() }));
      }
      this.schedule();
    }

    update(u: ViewUpdate) {
      if (
        u.docChanged ||
        u.viewportChanged ||
        u.geometryChanged ||
        u.transactions.some((t) => t.effects.some((e) => e.is(imagesChanged)))
      ) {
        this.schedule();
      }
    }

    schedule() {
      this.view.requestMeasure({
        read: () => this.read(),
        write: (placed: Placed[]) => this.write(placed),
      });
    }

    read(): Placed[] {
      const view = this.view;
      const width = editorWidth || availableWidth(view) || 360;
      const scrollerRect = view.scrollDOM.getBoundingClientRect();
      const contentRect = view.contentDOM.getBoundingClientRect();
      const scrollTop = view.scrollDOM.scrollTop;
      // 画像の X 起点はテキストの実開始位置（content の左端 + padding-left）
      const originX = contentRect.left - scrollerRect.left + contentPadding(view).left;
      const docTop = view.documentTop; // クライアント座標での文書先頭 Y

      const placed: Placed[] = [];
      const doc = view.state.doc;
      for (let i = 1; i <= doc.lines; i++) {
        const line = doc.line(i);
        const specs = parseLine(line.text);
        if (specs.length === 0) continue;
        const block = view.lineBlockAt(line.from);
        const sizes = groupSizes(specs, width);
        const rowH = Math.max(...sizes.map((s) => s.h));
        // 行ブロックの底（予約 padding を含む）から画像高さぶん上が画像の Y
        const y = docTop + block.bottom - rowH - GAP - scrollerRect.top + scrollTop;
        let x = originX;
        for (let k = 0; k < specs.length; k++) {
          placed.push({ url: specs[k].url, x, y, w: sizes[k].w, h: sizes[k].h });
          x += sizes[k].w + GAP;
        }
      }
      return placed;
    }

    write(placed: Placed[]) {
      const kids = this.container.children;
      while (kids.length > placed.length) kids[kids.length - 1].remove();
      while (kids.length < placed.length) {
        const img = document.createElement("img");
        img.addEventListener("load", () => {
          const key = img.getAttribute("src") ?? "";
          if (!key || naturalSizes.has(key)) return;
          naturalSizes.set(key, { w: img.naturalWidth, h: img.naturalHeight });
          viewRef?.dispatch({ effects: imagesChanged.of() }); // 実寸で余白を作り直す
        });
        this.container.appendChild(img);
      }
      for (let i = 0; i < placed.length; i++) {
        const img = kids[i] as HTMLImageElement;
        const p = placed[i];
        if (img.getAttribute("src") !== p.url) img.setAttribute("src", p.url);
        Object.assign(img.style, {
          position: "absolute",
          left: `${Math.round(p.x)}px`,
          top: `${Math.round(p.y)}px`,
          width: `${Math.round(p.w)}px`,
          height: `${Math.round(p.h)}px`,
          objectFit: "cover",
          borderRadius: "6px",
        } as Partial<CSSStyleDeclaration>);
      }
    }

    destroy() {
      this.ro.disconnect();
      this.container.remove();
      if (viewRef === this.view) viewRef = null;
    }
  }
);

export const imageField = [imagePaddingField, imageOverlay];
