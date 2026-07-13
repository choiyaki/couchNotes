// [[ 入力時にワークスペースの .md 名を候補表示する（couchNotes のサジェストパネル相当）。
import { CompletionContext, CompletionResult, Completion } from "@codemirror/autocomplete";
import { EditorView } from "@codemirror/view";
import { wikiTargetsField } from "./state";

/**
 * 直前テキストが [[query（]] や改行を挟まない）のときだけ発火。
 * couchNotes の wikiLinkQuery と同じく、部分一致（contains）で絞り込む。
 */
export function wikiCompletionSource(context: CompletionContext): CompletionResult | null {
  // [[ の直後からカーソルまで（] を含まない）
  const before = context.matchBefore(/\[\[[^\]\n]*$/);
  if (!before) return null;

  const query = before.text.slice(2); // 先頭 "[[" を除く
  const from = before.from + 2; // 候補を差し込む開始位置（[[ の直後）
  const lower = query.toLowerCase();

  const names = context.state.field(wikiTargetsField);
  const options: Completion[] = names
    .filter((n) => n.toLowerCase().includes(lower))
    .slice(0, 50)
    .map((name) => ({
      label: name,
      type: "text",
      apply: (view: EditorView, _c: Completion, aFrom: number, aTo: number) => {
        // すでにカーソル直後に "]]"（ツールバー挿入由来）があれば取り込み、]]]] を防ぐ
        const hasClose = view.state.sliceDoc(aTo, aTo + 2) === "]]";
        const insert = name + "]]";
        view.dispatch({
          changes: { from: aFrom, to: hasClose ? aTo + 2 : aTo, insert },
          selection: { anchor: aFrom + insert.length },
          userEvent: "input.complete",
        });
      },
    }));

  if (options.length === 0) return null;
  // contains で自前フィルタ済みなので CM 側の再フィルタは無効化
  return { from, options, filter: false };
}
