// ライブプレビューのインライン画像の長押し（iPhone）／右クリック（Mac）メニュー。
// 「文字を取り込む」でネイティブへ { type: "recognizeImage", url } を送り、
// 返ってきた ocrResult を画像行の直後へ ```ocr として入れる（ocr.ts の applyOcrResult）。
//
// - メニューは HTML で自前描画する（Mac Catalyst ではネイティブのポップオーバーが落ちるため）。
//   CM の DOM の外（document.body）に置くので、エディタの DOM 監視と干渉しない。
// - 取り込み中の表示も CM 管理下の DOM を触らず、<style> の属性セレクタで画像に重ねる。
import { EditorSelection } from "@codemirror/state";
import { isCouchImgUrl, isPublicImage } from "./images";
import { EditorView, ViewPlugin, ViewUpdate } from "@codemirror/view";
import { applyOcrResult, ocrBlockAfter } from "./ocr";

type Post = (msg: unknown) => void;

const LONG_PRESS_MS = 450; // iOS の文字選択（約 500ms）より先に出す
const MOVE_TOLERANCE = 10; // これ以上指が動いたらスクロールとみなして取り消す

/** 取り込み中の画像 url → 長押しした行番号（結果の挿入位置を探す手がかり） */
const pending = new Map<string, number>();
let pendingStyle: HTMLStyleElement | null = null;

function refreshPendingStyle() {
  if (!pendingStyle) {
    pendingStyle = document.createElement("style");
    document.head.appendChild(pendingStyle);
  }
  const selectors = [...pending.keys()].map(
    (u) => `.cm-cn-inline-img[data-url="${u.replace(/["\\]/g, "\\$&")}"]::after`
  );
  pendingStyle.textContent = selectors.length
    ? `${selectors.join(",\n")} { content: "取り込み中…"; }`
    : "";
}

/** 手書きメモ（アップロード済み）をカーソル位置（atEnd なら本文末尾）へ独立した行として挿入する。
    ocrPending なら認識結果が届くまで「取り込み中…」を重ねる。フォーカス（キーボード）は動かさない。 */
export function insertImageAtCursor(view: EditorView, url: string, ocrPending: boolean, atEnd = false) {
  const { state } = view;
  const sel = atEnd ? EditorSelection.cursor(state.doc.length) : state.selection.main;
  const startLine = state.doc.lineAt(sel.from);
  const endLine = state.doc.lineAt(sel.to);
  const before = state.sliceDoc(startLine.from, sel.from).trim() !== "";
  const after = state.sliceDoc(sel.to, endLine.to).trim() !== "";
  const insert = (before ? "\n" : "") + `![](${url})` + (after ? "\n" : "");
  view.dispatch({
    changes: { from: sel.from, to: sel.to, insert },
    selection: { anchor: sel.from + insert.length },
    userEvent: "input.paste",
    // 末尾追記は画面外になりがちなので見える位置までスクロールする
    effects: atEnd ? EditorView.scrollIntoView(sel.from + insert.length, { y: "center" }) : [],
  });
  if (ocrPending) {
    pending.set(url, startLine.number + (before ? 1 : 0));
    refreshPendingStyle();
  }
}

/** ネイティブからの ocrResult（text 無し＝失敗。エラー表示はネイティブ側が行う） */
export function applyOcrMessage(view: EditorView, msg: { url?: string; text?: string }) {
  const url = String(msg.url ?? "");
  const hint = pending.get(url) ?? 1;
  pending.delete(url);
  refreshPendingStyle();
  if (msg.text) applyOcrResult(view, url, msg.text, hint);
}

export function imageMenu(post: Post) {
  return ViewPlugin.fromClass(
    class {
      menu: HTMLDivElement | null = null;
      timer: ReturnType<typeof setTimeout> | null = null;
      startX = 0;
      startY = 0;
      swallowTouchEnd = false;
      pressing = false; // メニューを出した長押しの指がまだ離れていない

      constructor(readonly view: EditorView) {
        const c = view.contentDOM;
        c.addEventListener("touchstart", this.onTouchStart, { passive: true });
        c.addEventListener("touchmove", this.onTouchMove, { passive: true });
        c.addEventListener("touchend", this.onTouchEnd, { passive: false });
        c.addEventListener("touchcancel", this.onTouchCancel, { passive: true });
        c.addEventListener("contextmenu", this.onContextMenu);
        document.addEventListener("mousedown", this.onOutside, true);
        document.addEventListener("touchstart", this.onOutside, true);
        // scroll では閉じない: 長押しを続けると iOS がカーソルを画像の行へ動かし、追従スクロールで
        // 出したばかりのメニューが消えてしまう。指でのスクロールは touchstart（onOutside）で閉じるので、
        // ここで拾うのは Mac のホイール・トラックパッドだけでよい。
        view.scrollDOM.addEventListener("wheel", this.close, { passive: true });
      }

      update(u: ViewUpdate) {
        if (u.docChanged) this.close();
      }

      destroy() {
        const c = this.view.contentDOM;
        c.removeEventListener("touchstart", this.onTouchStart);
        c.removeEventListener("touchmove", this.onTouchMove);
        c.removeEventListener("touchend", this.onTouchEnd);
        c.removeEventListener("touchcancel", this.onTouchCancel);
        c.removeEventListener("contextmenu", this.onContextMenu);
        document.removeEventListener("mousedown", this.onOutside, true);
        document.removeEventListener("touchstart", this.onOutside, true);
        this.view.scrollDOM.removeEventListener("wheel", this.close);
        this.cancelTimer();
        this.close();
      }

      imageAt(target: EventTarget | null): HTMLElement | null {
        return (target as Element | null)?.closest?.<HTMLElement>(".cm-cn-inline-img[data-url]") ?? null;
      }

      onTouchStart = (e: TouchEvent) => {
        this.cancelTimer();
        if (e.touches.length !== 1) return;
        const wrap = this.imageAt(e.target);
        if (!wrap) return;
        this.startX = e.touches[0].clientX;
        this.startY = e.touches[0].clientY;
        this.timer = setTimeout(() => {
          this.timer = null;
          this.swallowTouchEnd = true; // 指を離した時にカーソル配置・タップ処理を起こさせない
          this.pressing = true;
          this.open(wrap, this.startX, this.startY);
        }, LONG_PRESS_MS);
      };

      onTouchMove = (e: TouchEvent) => {
        if (!this.timer) return;
        const t = e.touches[0];
        if (Math.hypot(t.clientX - this.startX, t.clientY - this.startY) > MOVE_TOLERANCE) {
          this.cancelTimer();
        }
      };

      onTouchEnd = (e: TouchEvent) => {
        this.cancelTimer();
        this.pressing = false;
        if (this.swallowTouchEnd) {
          this.swallowTouchEnd = false;
          e.preventDefault();
        }
      };

      // 長押しを続けて iOS に操作を引き取られると touchend は来ない。印を残すと次のタップが効かなくなる
      onTouchCancel = () => {
        this.cancelTimer();
        this.pressing = false;
        this.swallowTouchEnd = false;
      };

      onContextMenu = (e: MouseEvent) => {
        const wrap = this.imageAt(e.target);
        if (!wrap) return;
        e.preventDefault();
        this.open(wrap, e.clientX, e.clientY);
      };

      onOutside = (e: Event) => {
        // メニューを出した長押しの最中に来る mousedown では閉じない（同じ指の操作なので）
        if (this.pressing && e.type === "mousedown") return;
        if (this.menu && !this.menu.contains(e.target as Node)) this.close();
      };

      cancelTimer = () => {
        if (this.timer) clearTimeout(this.timer);
        this.timer = null;
      };

      close = () => {
        this.menu?.remove();
        this.menu = null;
      };

      open(wrap: HTMLElement, x: number, y: number) {
        this.close();
        const url = wrap.getAttribute("data-url");
        if (!url) return;
        const state = this.view.state;
        const pos = Math.min(this.view.posAtDOM(wrap), state.doc.length);
        const lineNo = state.doc.lineAt(pos).number;

        const menu = document.createElement("div");
        menu.className = "cn-image-menu";
        const item = document.createElement("button");
        item.type = "button";
        if (pending.has(url)) {
          item.textContent = "取り込み中…";
          item.disabled = true;
        } else {
          item.textContent = ocrBlockAfter(state, lineNo) ? "文字を取り込み直す" : "文字を取り込む";
          item.addEventListener("click", () => {
            this.close();
            pending.set(url, lineNo);
            refreshPendingStyle();
            post({ type: "recognizeImage", url });
          });
        }
        menu.appendChild(item);
        // couchimg（自分のサーバー）の画像だけ: 公開・削除。確認はネイティブ側で出す
        if (isCouchImgUrl(url)) {
          for (const [label, type] of [["公開する…", "couchimgPublish"], ["サーバーから削除…", "couchimgDelete"]]) {
            const b = document.createElement("button");
            b.type = "button";
            if (type === "couchimgPublish" && isPublicImage(url)) {
              // 公開は一方通行なので、公開済みなら状態を見せるだけ
              b.textContent = "公開中";
              b.disabled = true;
            } else {
              b.textContent = label;
              b.addEventListener("click", () => {
                this.close();
                post({ type, url });
              });
            }
            menu.appendChild(b);
          }
        }
        // メニュー操作でエディタのフォーカス（キーボード）を動かさない
        menu.addEventListener("mousedown", (e) => e.preventDefault());
        document.body.appendChild(menu);

        // 指・ポインタの少し下に出し、画面内に収める
        const margin = 8;
        const w = menu.offsetWidth;
        const h = menu.offsetHeight;
        let left = Math.min(Math.max(x - w / 2, margin), window.innerWidth - w - margin);
        let top = y + 16;
        if (top + h > window.innerHeight - margin) top = Math.max(y - h - 16, margin);
        menu.style.left = `${left}px`;
        menu.style.top = `${top}px`;
        this.menu = menu;
      }
    }
  );
}
