// couchNotes アプリの WKWebView に埋め込む CodeMirror エディタをビルドする。
// couchnotes-vscode/webview の装飾・コマンドロジックを流用し、VSCode 依存部分だけ
// ネイティブブリッジ（main.ts）に差し替えている。
const esbuild = require("esbuild");
const fs = require("fs");
const path = require("path");

const production = process.argv.includes("--production");
const outDir = path.join(__dirname, "..", "couchNotes", "WebEditor");

/** @type {import('esbuild').BuildOptions} */
const webviewConfig = {
  entryPoints: ["webview/main.ts"],
  bundle: true,
  outfile: path.join(outDir, "webview.js"),
  platform: "browser",
  format: "iife",
  sourcemap: !production,
  minify: production,
  logLevel: "info",
};

async function main() {
  fs.mkdirSync(outDir, { recursive: true });
  await esbuild.build(webviewConfig);
  fs.copyFileSync(path.join(__dirname, "index.html"), path.join(outDir, "index.html"));
  console.log("done ->", outDir);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
