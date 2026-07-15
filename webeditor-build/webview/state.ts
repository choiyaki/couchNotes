// wiki リンクの存在判定・サジェストに使う「ワークスペース内ノート名（原文表記）」を保持。
import { StateEffect, StateField } from "@codemirror/state";

export const setWikiTargets = StateEffect.define<string[]>();

export const wikiTargetsField = StateField.define<string[]>({
  create: () => [],
  update(value, tr) {
    for (const e of tr.effects) {
      if (e.is(setWikiTargets)) return e.value;
    }
    return value;
  },
});

// エディタがフォーカスを持っているか（EditorView.focusChangeEffect 経由で更新）。
// フォーカスが無い時（iPhone でキーボードが出ていない時）は「アクティブ行」を作らず、
// 全行をプレビュー表示にする。
export const setEditorFocused = StateEffect.define<boolean>();

export const editorFocusedField = StateField.define<boolean>({
  create: () => false,
  update(value, tr) {
    for (const e of tr.effects) {
      if (e.is(setEditorFocused)) return e.value;
    }
    return value;
  },
});

// ライブプレビュー（記法隠し）のオン/オフ。カーソル行は生表示、他の行は記法を隠す。
export const setLivePreview = StateEffect.define<boolean>();

export const livePreviewField = StateField.define<boolean>({
  create: () => false,
  update(value, tr) {
    for (const e of tr.effects) {
      if (e.is(setLivePreview)) return e.value;
    }
    return value;
  },
});

// どこかのノートの [[...]] に登場するが、まだページが存在しない名前（正規化済み・小文字）。
// サジェスト専用。リンクの存在色分けには使わない（wikiTargetsField と分離）。
export const setMentionedTargets = StateEffect.define<string[]>();

export const mentionedTargetsField = StateField.define<string[]>({
  create: () => [],
  update(value, tr) {
    for (const e of tr.effects) {
      if (e.is(setMentionedTargets)) return e.value;
    }
    return value;
  },
});
