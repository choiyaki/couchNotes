// MarkdownTextView.Coordinator の編集支援を CM6 コマンドへ移植。
import { EditorState, Line } from "@codemirror/state";
import { EditorView } from "@codemirror/view";

/** 選択範囲に重なる行（複数可） */
function selectedLines(state: EditorState): Line[] {
  const { from, to } = state.selection.main;
  const lines: Line[] = [];
  let line = state.doc.lineAt(from);
  const last = state.doc.lineAt(to);
  while (true) {
    lines.push(line);
    if (line.to >= last.to) break;
    line = state.doc.lineAt(line.to + 1);
  }
  return lines;
}

/** リスト → チェックボックス → 完了 → リスト の 3 状態サイクル */
function nextListMarker(stripped: string): { marker: string; oldLen: number } {
  if (/^[-*] \[ \]/.test(stripped)) return { marker: stripped[0] + " [x] ", oldLen: 6 };
  if (/^[-*] \[x\]/i.test(stripped)) return { marker: stripped[0] + " ", oldLen: 6 };
  if (/^[-*] /.test(stripped)) return { marker: stripped[0] + " [ ] ", oldLen: 2 };
  if (/^\+ /.test(stripped)) return { marker: "- [ ] ", oldLen: 2 };
  return { marker: "- ", oldLen: 0 };
}

/** Enter: リストマーカーを次行へ引き継ぐ。空項目ならマーカーを消してリスト終了。 */
export function listContinuation(view: EditorView): boolean {
  const { state } = view;
  const sel = state.selection.main;
  if (!sel.empty) return false;

  const line = state.doc.lineAt(sel.head);
  const text = line.text;
  const tabs = /^\t*/.exec(text)?.[0] ?? "";
  const stripped = text.slice(tabs.length);

  let nextMarker: string;
  let afterMarker: string;
  if (/^[-*] \[[ xX]\]/.test(stripped)) {
    nextMarker = stripped[0] + " [ ] ";
    afterMarker = stripped.slice(5).replace(/^ +/, "");
  } else if (/^[-*+] /.test(stripped)) {
    nextMarker = stripped.slice(0, 2);
    afterMarker = stripped.slice(2);
  } else {
    return false;
  }

  if (afterMarker.trim() === "") {
    // 空のリスト項目 → 行を空にしてリスト終了
    view.dispatch({
      changes: { from: line.from, to: line.to, insert: "" },
      selection: { anchor: line.from },
      userEvent: "input",
    });
  } else {
    const insert = "\n" + tabs + nextMarker;
    view.dispatch({
      changes: { from: sel.head, to: sel.head, insert },
      selection: { anchor: sel.head + insert.length },
      userEvent: "input",
    });
  }
  return true;
}

/** Tab: 選択行の行頭にタブを追加 */
export function indentLines(view: EditorView): boolean {
  const lines = selectedLines(view.state);
  view.dispatch({
    changes: lines.map((l) => ({ from: l.from, insert: "\t" })),
    userEvent: "input.indent",
  });
  return true;
}

/** Shift-Tab: 選択行の行頭からタブを 1 つ削除 */
export function outdentLines(view: EditorView): boolean {
  const lines = selectedLines(view.state);
  const changes = lines
    .filter((l) => l.text.startsWith("\t"))
    .map((l) => ({ from: l.from, to: l.from + 1 }));
  if (changes.length === 0) return false;
  view.dispatch({ changes, userEvent: "delete.dedent" });
  return true;
}

/** リストマーカーの 3 状態トグル（カーソル行、または選択行を先頭行基準で統一） */
export function toggleListMarker(view: EditorView): boolean {
  const { state } = view;
  const lines = selectedLines(state);

  if (lines.length === 1) {
    const line = lines[0];
    const tabs = /^\t*/.exec(line.text)?.[0] ?? "";
    const stripped = line.text.slice(tabs.length);
    const { marker, oldLen } = nextListMarker(stripped);
    const body = stripped.slice(oldLen);
    const newLine = tabs + marker + body;
    view.dispatch({
      changes: { from: line.from, to: line.to, insert: newLine },
      selection: { anchor: line.from + (tabs + marker).length },
      userEvent: "input",
    });
    return true;
  }

  // 複数行: 先頭の非空行から決めた marker に統一
  const firstContent = lines.find((l) => l.text.slice(/^\t*/.exec(l.text)![0].length).trim() !== "");
  if (!firstContent) return false;
  const fStripped = firstContent.text.slice(/^\t*/.exec(firstContent.text)![0].length);
  const target = nextListMarker(fStripped).marker;

  const changes = lines.map((l) => {
    const tabs = /^\t*/.exec(l.text)![0];
    const stripped = l.text.slice(tabs.length);
    if (stripped.trim() === "") return { from: l.from, to: l.to, insert: l.text };
    const oldLen = nextListMarker(stripped).oldLen;
    // 既存マーカー長を実測（trim で空でない行のみ）
    const cur = curMarkerLen(stripped);
    return { from: l.from, to: l.to, insert: tabs + target + stripped.slice(cur) };
  });
  view.dispatch({ changes, userEvent: "input" });
  return true;
}

function curMarkerLen(stripped: string): number {
  if (/^[-*] \[[ xX]\]/.test(stripped)) return 6;
  if (/^[-*+] /.test(stripped)) return 2;
  return 0;
}

/** [[ ]] を挿入（選択があれば囲む） */
export function insertWikiLink(view: EditorView): boolean {
  const sel = view.state.selection.main;
  const selected = view.state.sliceDoc(sel.from, sel.to);
  const inserted = `[[${selected}]]`;
  const anchor = sel.empty ? sel.from + 2 : sel.from + inserted.length;
  view.dispatch({
    changes: { from: sel.from, to: sel.to, insert: inserted },
    selection: { anchor },
    userEvent: "input",
  });
  return true;
}

/** クリック位置のチェックボックスをトグル */
export function toggleCheckboxAt(view: EditorView, pos: number): boolean {
  const line = view.state.doc.lineAt(pos);
  const m = /^([\t ]*)[-*] \[([ xX])\]/.exec(line.text);
  if (!m) return false;
  const boxCharPos = line.from + m[1].length + 3; // "[ " の次（チェック文字）
  const next = m[2] === " " ? "x" : " ";
  view.dispatch({
    changes: { from: boxCharPos, to: boxCharPos + 1, insert: next },
    userEvent: "input",
  });
  return true;
}
