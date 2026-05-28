motifd: MOTIFD_RPC_LOG=./motif-rpc.log cargo watch -w crates/motif-server -w crates/motif-proto -w crates/motif-tailscale -w crates/motif-net -x "run -q -p motif-server --bin motifd -- --listen 0.0.0.0:7777 --insecure-no-auth --tailscale"
vite: cd apps/web && pnpm dev --host 0.0.0.0 --port 5173
