motifd: MOTIFD_RPC_LOG=./motif-rpc.log cargo watch -w crates/motif-server -w crates/motif-proto -w crates/motif-tailscale -w crates/motif-net -x "run -q -p motif-server --bin motifd -- --listen 0.0.0.0:7777 --insecure-no-auth --tailscale --push-relay-url http://127.0.0.1:8088/v1/push"
relay: cargo watch -w crates/motif-push-relay -x "run -q -p motif-push-relay -- --apns-key-path apns.p8 --apns-key-id 946S4U9BDG --apns-team-id UWNR93L682 --apns-topic io.allsunday.motif --listen 127.0.0.1:8088"
vite: cd apps/web && pnpm dev --host 0.0.0.0 --port 5173
