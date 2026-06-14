# App Review 服务器（hardened motifd）

App Store 审核员必须能**实际连上一台 motifd** 跑一下,否则大概率以 "unable to
review" 被拒。为此我们维护一个无 Tailscale、硬化过的 motifd 镜像,部署在一台 VPS 上,
明文 `ws://` 直连(客户端侧配了对应的 ATS 例外)。

相关文件:
- `deploy/review/Dockerfile` — 镜像
- `deploy/review/entrypoint.sh` — 启动时 seed demo workspace、读 token、起 motifd
- `deploy/review/run-review.sh` — 启动器(临时模式 / `--bind` 公网模式)
- `.github/workflows/review-image.yml` — CI 构建 + 推 GHCR

## 镜像

`ghcr.io/xiachufang/motifd-review:latest`。CI 用 `cargo build --no-default-features`
构建,**完全不链接 motif-tailscale / 不需要 Go**(tailscale 现在是可选 feature,见
[`tailscale.md`](./tailscale.md))。镜像里只有 Rust + Zig 构建链,运行时是 debian-slim +
非 root + 预置 demo git 仓库。

硬化点(`run-review.sh` 与持久部署都套用):
- 非 root(uid 10001)、`--cap-drop=ALL`、`--security-opt=no-new-privileges`、`--read-only`
- 可写处是 tmpfs,且 **`mode=1777`**——docker tmpfs 挂载点 root 所有且不接受 uid/gid,
  不给粘滞可写位的话非 root 进程建不了 HOME/workspace,容器秒退
- token 文件 **必须 `chmod 0644`**——Linux bind mount 保留宿主权限,`mktemp` 的 0600
  文件容器(uid 10001)读不到 → `failed to read --token-file: Permission denied`。
  (macOS Docker Desktop 会重映射权限掩盖此坑,只在 Linux / CI 暴露)
- 独立 docker 网络 + DOCKER-USER 出站防火墙:封 `169.254.169.254`(云元数据)+ RFC1918,
  放行公网

## 从 GHCR 拉取（私有包）

包是**私有**的,VPS 拉取前要登录,且 token 需带 `read:packages`(默认 `gh auth token` 只有
`repo/workflow`,拉不动):

```sh
echo "$GHCR_PAT" | docker login ghcr.io -u <user> --password-stdin
docker pull ghcr.io/xiachufang/motifd-review:latest
```

## VPS 持久部署

当前部署在 `ubuntu@us.hq.allsunday.io`(对外公网 IP `43.173.125.125`)。两类坑先记:
- ubuntu 默认**不在 docker 组**(`docker --version` 不碰 daemon 所以不报错,实际操作
  permission denied)→ `sudo usermod -aG docker ubuntu`,**新登录会话**才生效。
- 8080 被别的容器占了 → 用 **8099**。

持久化要点(满足:容器 auto-restart + token 固定 + 防火墙扛重启):

```sh
cd ~/motif-review

# 1) 固定 token(只生成一次,世界可读供容器 uid 读)
[ -s token ] || openssl rand -hex 32 > token; chmod 644 token

# 2) 隔离网络(固定子网,匹配防火墙规则)
docker network create --subnet 172.31.244.0/24 motif-review-net   # 已存在则跳过

# 3) 出站防火墙脚本(幂等),systemd 开机重应用
cat > fw.sh <<'SH'
#!/bin/bash
SUBNET=172.31.244.0/24
for d in 169.254.0.0/16 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10; do
  sudo iptables -C DOCKER-USER -s $SUBNET -d $d -j DROP 2>/dev/null \
    || sudo iptables -I DOCKER-USER -s $SUBNET -d $d -j DROP
done
SH
chmod +x fw.sh && ./fw.sh
# /etc/systemd/system/motifd-review-fw.service: Type=oneshot, After=docker.service,
# ExecStart=/home/ubuntu/motif-review/fw.sh, enable 之 → 开机重新下发 DOCKER-USER 规则

# 4) 容器:auto-restart + 公网明文 ws://(安全组放行 8099/tcp)
docker run -d --name motifd-review --restart unless-stopped \
  --network motif-review-net -p 0.0.0.0:8099:8080 \
  --user 10001:10001 --cap-drop=ALL --security-opt=no-new-privileges --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=32m \
  --tmpfs /home/demo:rw,nosuid,nodev,mode=1777,size=128m \
  --tmpfs /run:rw,noexec,nosuid,nodev,mode=1777,size=4m \
  --pids-limit=256 --memory=512m --memory-swap=512m --cpus=1 \
  --mount type=bind,source=$HOME/motif-review/token,target=/run/secrets/motifd_token,readonly \
  ghcr.io/xiachufang/motifd-review:latest
```

> `--restart unless-stopped` 让 Docker 在崩溃和**开机**时自动拉起容器,无需 systemd 管容器;
> systemd 只负责开机重新下发出站防火墙规则(iptables 运行态不跨重启)。

验证(外网):`curl http://43.173.125.125:8099/ping` → 200;无 token 的
`POST /rpc/session.list` → 401,带 token → 200。

## 审核端点

写在 App Store Connect 的 review notes 里(version review detail):

```
Server URL:  ws://43.173.125.125:8099
Token:       <~/motif-review/token 的内容>
```

reviewer 加这个 server、连上后:开终端(服务器上跑真实 shell)、浏览文件树、看 demo
仓库的 git diff。无需账号,bearer token 即唯一凭证。

## run-review.sh 的两种模式（临时调试用）

- 默认:随机 token、绑 `127.0.0.1`、`--rm`,退出时 trap 自动拆容器/网络/iptables/token。
  **注意**它的 cleanup 会删 `motif-review-net`——持久部署前 `pkill run-review.sh` 要等
  cleanup 跑完再建网络,否则竞态报 "network not found"。
- `--tunnel`:起 cloudflared quick tunnel(临时 `wss://*.trycloudflare.com`,适合本地演示,
  **不适合多天审核**——会回收)。
- `--bind 0.0.0.0`:直接公网明文 `ws://`(自行放行端口),打印 `ws://<公网IP>:<port>` +
  token 的 review-notes 块。
