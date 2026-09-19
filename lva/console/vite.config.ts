// Web build of reSpeaker Console for Home Assistant ingress.
//
// Copied into the cloned respeaker-console repo as `ha/` together with tauri.ts,
// which replaces all Tauri APIs, so the upstream sources are used unmodified.

import { readFileSync } from "fs";
import path from "path";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

const root = path.resolve(__dirname, "..");
const pkg = JSON.parse(readFileSync(path.join(root, "package.json"), "utf-8"));

export default defineConfig({
  root,
  // Ingress serves the app under /api/hassio_ingress/<token>/
  base: "./",
  plugins: [
    react(),
    tailwindcss(),
    {
      // Upstream index.html still carries the Tauri template title and favicon
      name: "ha-index",
      transformIndexHtml: (html) =>
        html
          .replace(/<title>.*<\/title>/, "<title>reSpeaker Console</title>")
          .replace(/\s*<link rel="icon"[^>]*>/, ""),
    },
  ],
  define: {
    __CONSOLE_VERSION__: JSON.stringify(pkg.version),
  },
  resolve: {
    alias: [
      { find: /^@tauri-apps\/.*/, replacement: path.join(__dirname, "tauri.ts") },
      { find: "@", replacement: path.join(root, "src") },
    ],
  },
  build: {
    outDir: path.join(root, "dist-ha"),
    emptyOutDir: true,
  },
});
