import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import "./styles.css";

function syncViewportHeight() {
  const vv = window.visualViewport;
  if (!vv) return;
  const keyboardOffset = Math.max(0, window.innerHeight - vv.height - vv.offsetTop);
  document.documentElement.style.setProperty("--keyboard-offset", `${keyboardOffset}px`);
  document.documentElement.style.setProperty("--app-height", `${vv.height}px`);
  document.documentElement.style.setProperty("--vv-top", `${vv.offsetTop}px`);
}
window.visualViewport?.addEventListener("resize", syncViewportHeight);
window.visualViewport?.addEventListener("scroll", syncViewportHeight);
syncViewportHeight();

const root = document.getElementById("root");
if (!root) throw new Error("root element missing");
createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>
);
