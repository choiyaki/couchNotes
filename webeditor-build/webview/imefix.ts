// iPad（ハードウェアキーボード）の日本語入力で、確定した文字が次の Enter で消える件の対策。
// iPadOS は変換中の文字を DOM の選択範囲として扱い、CodeMirror はそれを取り込む。
// 確定すると画面の選択はカーソルに戻るのに、CodeMirror は確定した文字を選択したままになり、
// 次の Enter が「選択範囲を改行で置き換える」ため、確定した文字が消えていた（2026-11-09 診断で確認）。
// 確定の直後と Enter の直前に、CodeMirror の選択が「いま確定した文字そのもの」なら、その後ろへ畳む。
import { EditorView } from "@codemirror/view";

export function installImeSelectionFix(view: EditorView) {
  const dom = view.contentDOM;
  // 直前に確定した文字。利用者が自分で選択を動かしたら（打鍵・タップ）、もう見ない
  let committed: string | null = null;

  const collapseIfStale = () => {
    if (!committed || view.composing) return;
    const sel = view.state.selection.main;
    if (sel.empty || view.state.sliceDoc(sel.from, sel.to) !== committed) return;
    view.dispatch({ selection: { anchor: sel.to }, userEvent: "select" });
  };

  dom.addEventListener("compositionstart", () => { committed = null; }, true);
  dom.addEventListener("compositionend", (e) => {
    committed = (e as CompositionEvent).data || null;
    // 確定が本文へ反映された後に見る
    window.setTimeout(collapseIfStale, 0);
  }, true);
  // CodeMirror より先に見るため capture で付ける
  dom.addEventListener("keydown", (e) => {
    if (e.key === "Enter" || e.keyCode === 13) {
      collapseIfStale();
    } else if (!["Shift", "Control", "Alt", "Meta", "CapsLock"].includes(e.key) && e.keyCode !== 229) {
      committed = null;
    }
  }, true);
  dom.addEventListener("mousedown", () => { committed = null; }, true);
  dom.addEventListener("touchstart", () => { committed = null; }, true);
}
