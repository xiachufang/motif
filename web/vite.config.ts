import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// During `pnpm dev` the Vite dev server proxies API/WS routes to motifd.
// Set VITE_MOTIFD if you want a different target.
const MOTIFD = process.env.VITE_MOTIFD ?? "http://127.0.0.1:7777";
const WS_MOTIFD = MOTIFD.replace(/^http/, "ws");

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
        // Keep file names predictable so motifd's rust-embed picks them up
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
      "/rpc":    { target: MOTIFD,    changeOrigin: true },
      "/events": { target: WS_MOTIFD, ws: true,  changeOrigin: true },
      "/pty":    { target: WS_MOTIFD, ws: true,  changeOrigin: true }
    }
  }
});
