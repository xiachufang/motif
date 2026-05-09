//! Per-PTY ring buffer of finished blocks. Late-joining clients query it
//! via `pty.list_blocks` / `pty.get_block_output` to backfill block UI
//! without having to replay the raw PTY ring.
//!
//! Eviction is twofold: by entry count (default 1000) and by total
//! output bytes (default 50 MiB). Whichever bound trips first pops the
//! oldest block.

use std::collections::VecDeque;
use std::path::PathBuf;

use motif_proto::common::BlockId;
use motif_proto::pty::BlockSummary;

pub const DEFAULT_CAP_COUNT: usize = 1000;
pub const DEFAULT_CAP_TOTAL_BYTES: u64 = 50 * 1024 * 1024;

#[derive(Debug, Clone)]
pub struct Block {
    pub id:                BlockId,
    pub cwd:               PathBuf,
    pub cmd:               String,
    pub started_at:        u64,
    pub finished_at:       u64,
    pub exit_code:         Option<i32>,

    pub prompt:            Vec<u8>,
    pub prompt_truncated:  bool,
    pub command:           Vec<u8>,
    pub command_truncated: bool,
    pub output:            Vec<u8>,
    pub output_truncated:  bool,
}

impl Block {
    pub fn summary(&self) -> BlockSummary {
        BlockSummary {
            id:                self.id.clone(),
            cwd:               self.cwd.clone(),
            cmd:                self.cmd.clone(),
            started_at:        self.started_at,
            finished_at:       Some(self.finished_at),
            exit_code:         self.exit_code,
            prompt_size:       self.prompt.len()  as u64,
            prompt_truncated:  self.prompt_truncated,
            command_size:      self.command.len() as u64,
            command_truncated: self.command_truncated,
            output_size:       self.output.len()  as u64,
            output_truncated:  self.output_truncated,
        }
    }

    /// Total bytes across all three segments — used for the BlockStore
    /// total-bytes cap.
    pub fn total_bytes(&self) -> u64 {
        (self.prompt.len() + self.command.len() + self.output.len()) as u64
    }
}

#[derive(Debug)]
pub struct BlockStore {
    blocks:          VecDeque<Block>,
    cap_count:       usize,
    cap_total_bytes: u64,
    total_bytes:     u64,
}

impl BlockStore {
    pub fn new(cap_count: usize, cap_total_bytes: u64) -> Self {
        Self {
            blocks: VecDeque::new(),
            cap_count,
            cap_total_bytes,
            total_bytes: 0,
        }
    }

    /// Push a block onto the back, evicting oldest blocks until both
    /// caps are respected.
    pub fn append(&mut self, block: Block) {
        self.total_bytes += block.total_bytes();
        self.blocks.push_back(block);
        while self.blocks.len() > self.cap_count
            || self.total_bytes > self.cap_total_bytes
        {
            let Some(b) = self.blocks.pop_front() else { break };
            self.total_bytes = self.total_bytes.saturating_sub(b.total_bytes());
        }
    }

    /// Most-recent-first listing. `before` is exclusive: only blocks
    /// strictly older (smaller ULID, since ULIDs sort lexicographically
    /// in time order) are returned. `None` returns the most-recent
    /// `limit`.
    pub fn list(&self, before: Option<&BlockId>, limit: usize) -> Vec<BlockSummary> {
        let mut out = Vec::with_capacity(limit.min(self.blocks.len()));
        for b in self.blocks.iter().rev() {
            if let Some(cursor) = before {
                if b.id.as_str() >= cursor.as_str() { continue; }
            }
            out.push(b.summary());
            if out.len() >= limit { break; }
        }
        out
    }

    pub fn get(&self, id: &BlockId) -> Option<&Block> {
        self.blocks.iter().find(|b| &b.id == id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mk(id: &str, output: Vec<u8>) -> Block {
        Block {
            id: id.into(),
            cwd: "/tmp".into(),
            cmd: format!("cmd {id}"),
            started_at: 0,
            finished_at: 0,
            exit_code: Some(0),
            prompt:            Vec::new(),
            prompt_truncated:  false,
            command:           Vec::new(),
            command_truncated: false,
            output,
            output_truncated:  false,
        }
    }

    #[test]
    fn eviction_by_count() {
        let mut s = BlockStore::new(2, u64::MAX);
        s.append(mk("a", vec![]));
        s.append(mk("b", vec![]));
        s.append(mk("c", vec![]));
        // Oldest (a) should have been evicted.
        assert!(s.get(&"a".to_string()).is_none());
        assert!(s.get(&"b".to_string()).is_some());
        assert!(s.get(&"c".to_string()).is_some());
    }

    #[test]
    fn eviction_by_bytes() {
        let mut s = BlockStore::new(usize::MAX, 10);
        s.append(mk("a", vec![0; 6]));
        s.append(mk("b", vec![0; 5]));
        // a + b = 11 > 10, oldest evicts.
        assert!(s.get(&"a".to_string()).is_none());
        assert!(s.get(&"b".to_string()).is_some());
    }

    #[test]
    fn list_is_descending_and_respects_before() {
        let mut s = BlockStore::new(10, u64::MAX);
        // ULIDs sort lex; "01"…"04" are valid prefixes here.
        s.append(mk("01", vec![]));
        s.append(mk("02", vec![]));
        s.append(mk("03", vec![]));
        s.append(mk("04", vec![]));
        let all = s.list(None, 10);
        assert_eq!(all.iter().map(|b| b.id.as_str()).collect::<Vec<_>>(),
                   vec!["04", "03", "02", "01"]);
        let before_03 = s.list(Some(&"03".to_string()), 10);
        assert_eq!(before_03.iter().map(|b| b.id.as_str()).collect::<Vec<_>>(),
                   vec!["02", "01"]);
    }

    #[test]
    fn list_limit_caps_returned_count() {
        let mut s = BlockStore::new(10, u64::MAX);
        for i in 0..5 { s.append(mk(&format!("0{i}"), vec![])); }
        let two = s.list(None, 2);
        assert_eq!(two.len(), 2);
    }
}
