import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// During `pnpm dev` the Vite dev server proxies /ws and /blob to a locally
// running motif-web bridge. Set VITE_BRIDGE if you want a different target.
const BRIDGE = process.env.VITE_BRIDGE ?? "http://127.0.0.1:8080";
const WS_BRIDGE = BRIDGE.replace(/^http/, "ws");

export default defineConfig({
  plugins: [react()],
  build: {
    outDir:      "dist",
    emptyOutDir: true,
    sourcemap:   false,
    target:      "es2022",
    rolldownOptions: {
      output: {
        codeSplitting: true,
        // Heavy deps are only needed deep inside Workspace; splitting them out
        // means the browser parses far less JS during login/sessions, and each
        // chunk caches independently across rebuilds of the rest.
        manualChunks: (id: string): string | undefined => {
          if (!id.includes("node_modules")) return;
          if (id.includes("@xterm/"))                          return "xterm";
          if (id.includes("/diff2html/"))                      return "diff";
          if (id.includes("/highlight.js/"))                   return "hljs";
          if (/\/(react|react-dom|scheduler)\//.test(id))      return "react";
          return;
        },
        // Keep file names predictable so motif-web's rust-embed picks them up
        // by extension (we don't depend on hashed names — the embedded server
        // sets Cache-Control: no-store).
        entryFileNames: "assets/[name].js",
        chunkFileNames: "assets/[name].js",
        assetFileNames: "assets/[name][extname]"
      }
    }
  },
  server: {
    port: 5173,
    proxy: {
      "/ws":   { target: WS_BRIDGE, ws: true,  changeOrigin: true },
      "/blob": { target: BRIDGE,    changeOrigin: true }
    }
  }
});
