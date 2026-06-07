// libghostty-vt WebAssembly bridge for the Flutter web terminal.
//
// Loads ghostty-vt.wasm and exposes a small API on window.GhosttyVt. The call
// sequence mirrors the native FFI TerminalState and was verified end-to-end in
// Node (feedBytes -> render grid). The terminal handle and render-state handles
// are opaque pointer-sized values into the wasm linear memory.
(function () {
  const DATA_ROW_ITERATOR = 4;
  const ROW_DATA_CELLS = 3;
  const GLEN = 3;
  const GBUF = 4;
  const BG_COLOR = 5;
  const FG_COLOR = 6;
  const CURSOR_VISIBLE = 11;
  const CURSOR_HAS_VALUE = 14;
  const CURSOR_X = 15;
  const CURSOR_Y = 16;

  let e = null; // wasm exports
  const dv = () => new DataView(e.memory.buffer);
  const u8 = () => new Uint8Array(e.memory.buffer);
  const alloc = (n) =>
    e.ghostty_wasm_alloc_u8_array ? e.ghostty_wasm_alloc_u8_array(n) : e.ghostty_alloc(0, n);
  const rdU32 = (p) => dv().getUint32(p, true);

  // Scratch slots (allocated once after load).
  let rsSlot, iterSlot, cellsSlot, lenSlot, gbuf;

  const api = {
    ready: null,

    // Create a terminal of the given grid size; returns an opaque handle.
    newTerminal(cols, rows) {
      const opts = alloc(8);
      const d = dv();
      d.setUint16(opts, cols, true);
      d.setUint16(opts + 2, rows, true);
      d.setUint32(opts + 4, 10000, true); // max_scrollback
      const slot = alloc(4);
      e.ghostty_terminal_new(0, slot, opts);
      return rdU32(slot);
    },

    resize(term, cols, rows, cw, ch) {
      if (e.ghostty_terminal_resize) e.ghostty_terminal_resize(term, cols, rows, cw, ch);
    },

    // Feed bytes (Uint8Array) from the remote PTY into the engine.
    write(term, bytes) {
      const buf = alloc(bytes.length);
      u8().set(bytes, buf);
      e.ghostty_terminal_vt_write(term, buf, bytes.length);
      if (e.ghostty_wasm_free_u8_array) e.ghostty_wasm_free_u8_array(buf, bytes.length);
    },

    // Extract the visible grid as text (one string per row, joined by \n).
    gridText(term) {
      e.ghostty_render_state_update(rsSlot.rs, term);
      e.ghostty_render_state_get(rsSlot.rs, DATA_ROW_ITERATOR, iterSlot);
      const iter = () => rdU32(iterSlot);
      const cells = () => rdU32(cellsSlot);
      const rows = [];
      let guard = 0;
      while (e.ghostty_render_state_row_iterator_next(iter()) && guard++ < 1000) {
        e.ghostty_render_state_row_get(iter(), ROW_DATA_CELLS, cellsSlot);
        let line = '';
        let cg = 0;
        while (e.ghostty_render_state_row_cells_next(cells()) && cg++ < 2000) {
          e.ghostty_render_state_row_cells_get(cells(), GLEN, lenSlot);
          const glen = rdU32(lenSlot);
          if (glen > 0) {
            e.ghostty_render_state_row_cells_get(cells(), GBUF, gbuf);
            const d = dv();
            for (let i = 0; i < glen; i++) line += String.fromCodePoint(d.getUint32(gbuf + i * 4, true));
          }
        }
        rows.push(line.replace(/\s+$/, ''));
      }
      while (rows.length && rows[rows.length - 1] === '') rows.pop();
      return rows.join('\n');
    },

    // Extract the visible grid WITH per-cell colors, as a JSON string:
    // { rows: [ [ {t, f:[r,g,b], b:[r,g,b]} ... ] ... ] }. Adjacent cells with
    // the same fg/bg are coalesced into one run.
    gridCellsJson(term) {
      this._colorSlot = this._colorSlot || alloc(4);
      const cslot = this._colorSlot;
      e.ghostty_render_state_update(rsSlot.rs, term);
      e.ghostty_render_state_get(rsSlot.rs, DATA_ROW_ITERATOR, iterSlot);
      const iter = () => rdU32(iterSlot);
      const cells = () => rdU32(cellsSlot);
      const readColor = (kind) => {
        e.ghostty_render_state_row_cells_get(cells(), kind, cslot);
        const d = dv();
        return [d.getUint8(cslot), d.getUint8(cslot + 1), d.getUint8(cslot + 2)];
      };
      const rows = [];
      let guard = 0;
      while (e.ghostty_render_state_row_iterator_next(iter()) && guard++ < 1000) {
        e.ghostty_render_state_row_get(iter(), ROW_DATA_CELLS, cellsSlot);
        const runs = [];
        let cur = null;
        let cg = 0;
        while (e.ghostty_render_state_row_cells_next(cells()) && cg++ < 2000) {
          e.ghostty_render_state_row_cells_get(cells(), GLEN, lenSlot);
          const glen = rdU32(lenSlot);
          let ch = ' ';
          if (glen > 0) {
            e.ghostty_render_state_row_cells_get(cells(), GBUF, gbuf);
            const d = dv();
            ch = '';
            for (let i = 0; i < glen; i++) ch += String.fromCodePoint(d.getUint32(gbuf + i * 4, true));
          }
          const f = readColor(FG_COLOR);
          const b = readColor(BG_COLOR);
          if (cur && cur.f[0] === f[0] && cur.f[1] === f[1] && cur.f[2] === f[2] &&
              cur.b[0] === b[0] && cur.b[1] === b[1] && cur.b[2] === b[2]) {
            cur.t += ch;
          } else {
            cur = { t: ch, f, b };
            runs.push(cur);
          }
        }
        rows.push(runs);
      }
      // Cursor position (viewport coords) + visibility.
      const rsGet = (kind, bytes) => {
        e.ghostty_render_state_get(rsSlot.rs, kind, cslot);
        const d = dv();
        return bytes === 1 ? d.getUint8(cslot) : d.getUint16(cslot, true);
      };
      const cursor = {
        vis: rsGet(CURSOR_VISIBLE, 1) !== 0 && rsGet(CURSOR_HAS_VALUE, 1) !== 0,
        x: rsGet(CURSOR_X, 2),
        y: rsGet(CURSOR_Y, 2),
      };
      return JSON.stringify({ rows, cursor });
    },
  };

  // NOTE: WebAssembly.instantiate's first arg must be a BufferSource/Module,
  // not a Promise — so resolve the arrayBuffer first, THEN instantiate.
  api.ready = fetch('ghostty-vt.wasm')
    .then((r) => r.arrayBuffer())
    .then((buf) => WebAssembly.instantiate(buf, { env: { log: () => {} } }))
    .then((res) => {
      e = res.instance.exports;
      // Persistent render-state + iterator/cells handles.
      const rsSlotPtr = alloc(4);
      e.ghostty_render_state_new(0, rsSlotPtr);
      rsSlot = { rs: rdU32(rsSlotPtr) };
      iterSlot = alloc(4);
      e.ghostty_render_state_row_iterator_new(0, iterSlot);
      cellsSlot = alloc(4);
      e.ghostty_render_state_row_cells_new(0, cellsSlot);
      lenSlot = alloc(4);
      gbuf = alloc(64 * 4);
      return true;
    })
    .catch((err) => {
      console.error('GhosttyVt load failed:', err);
      return false;
    });

  window.GhosttyVt = api;
})();
