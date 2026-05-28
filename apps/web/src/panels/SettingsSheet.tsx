// Appearance settings modal: terminal font size + theme. Both are global,
// persisted in localStorage via the store. Reuses the .mdock-modal* and .seg
// styles. Closes on backdrop click or Escape.

import { useEffect } from "react";
import { useApp } from "../store/store";
import {
  FONT_SIZE_MAX, FONT_SIZE_MIN, THEME_OPTIONS,
} from "../appearance";

export default function SettingsSheet({ onClose }: { onClose: () => void }) {
  const fontSize    = useApp(s => s.fontSize);
  const theme       = useApp(s => s.theme);
  const setFontSize = useApp(s => s.setFontSize);
  const setTheme    = useApp(s => s.setTheme);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <div className="mdock-modal-backdrop" onClick={onClose}>
      <div
        className="mdock-modal settings-sheet"
        onClick={e => e.stopPropagation()}
        role="dialog"
        aria-modal="true"
        aria-label="Settings"
      >
        <h2>Settings</h2>

        <div className="settings-row">
          <span className="settings-label">Terminal font size</span>
          <div className="settings-stepper">
            <button
              onClick={() => setFontSize(fontSize - 1)}
              disabled={fontSize <= FONT_SIZE_MIN}
              aria-label="Decrease font size"
            >−</button>
            <span className="settings-fontsize">{fontSize}px</span>
            <button
              onClick={() => setFontSize(fontSize + 1)}
              disabled={fontSize >= FONT_SIZE_MAX}
              aria-label="Increase font size"
            >+</button>
          </div>
        </div>

        <div className="settings-row">
          <span className="settings-label">Theme</span>
          <div className="seg">
            {THEME_OPTIONS.map(opt => (
              <button
                key={opt.value}
                className={theme === opt.value ? "on" : ""}
                onClick={() => setTheme(opt.value)}
                aria-pressed={theme === opt.value}
              >{opt.label}</button>
            ))}
          </div>
        </div>

        <div className="muted small">
          Applies to all terminals immediately. System follows your browser appearance.
        </div>
      </div>
    </div>
  );
}
