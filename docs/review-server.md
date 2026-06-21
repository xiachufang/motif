# App Review 服务器（hardened motifd）

App Store 审核员必须能**实际连上一台 motifd** 跑一下,否则大概率以 "unable to
review" 被拒。为此我们维护一个无 Tailscale、硬化过的 motifd 镜像,部署在一台 VPS 上。
网络监听**自动加密**(自签 TLS,客户端 pin 证书)+ **自动鉴权**(psk 派生 bearer),
审核员扫一个 `motif://pair` 链接即可连上——无需反向代理/隧道,也无需 ATS 明文例外。

相关文件:
- `deploy/review/Dockerfile` — 镜像
- `deploy/review/entrypoint.sh` — 启动时 seed demo workspace、起 motifd(自动 psk + TLS)
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
- **持久数据目录**(bind-mount 到容器的 `$XDG_DATA_HOME`):motifd 把 psk + 自签证书
  存在这里,持久化后配对链接的 pin 跨重启稳定;目录要可被容器 uid 10001 读写
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

持久化要点(满足:容器 auto-restart + psk/证书固定 + 防火墙扛重启):

```sh
cd ~/motif-review

# 1) 持久数据目录(motifd 在此存 psk + 自签证书 → pin 跨重启稳定)。
#    容器以 uid 10001 跑,目录要可写。
mkdir -p data && chmod 777 data
#    可选:固定 psk(否则首启自动生成并存进 data/)
[ -s psk ] || (head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n' > psk)

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

# 4) 容器:auto-restart + 公网 TLS 直连(安全组放行 8099/tcp)
docker run -d --name motifd-review --restart unless-stopped \
  --network motif-review-net -p 0.0.0.0:8099:8099 \
  -e MOTIFD_LISTEN=0.0.0.0:8099 \
  -e MOTIFD_ADVERTISE_HOST=43.173.125.125 \
  -e XDG_DATA_HOME=/data \
  -e MOTIFD_PSK="$(cat psk)" \
  --user 10001:10001 --cap-drop=ALL --security-opt=no-new-privileges --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=32m \
  --tmpfs /home/demo:rw,nosuid,nodev,mode=1777,size=128m \
  --tmpfs /run:rw,noexec,nosuid,nodev,mode=1777,size=4m \
  -v "$HOME/motif-review/data:/data" \
  --pids-limit=256 --memory=512m --memory-swap=512m --cpus=1 \
  ghcr.io/xiachufang/motifd-review:latest
```

> 端口对齐 `8099:8099` + `MOTIFD_LISTEN=0.0.0.0:8099`,这样链接里的端口和外部一致。
> `--restart unless-stopped` 让 Docker 崩溃/开机自动拉起;systemd 只负责开机重下发防火墙规则。

验证(外网):`curl -k https://43.173.125.125:8099/ping` → 200;无 bearer 的
`POST /rpc/session.list` → 401,带正确 bearer → 200。从日志拿配对链接:
`docker logs motifd-review 2>&1 | grep -o 'motif://pair[^ ]*'`。

## 审核端点

把 motifd 打印的**配对链接**写进 App Store Connect 的 review notes(version review
detail);它自带 host/port/psk/pin,审核员在 App 里选 Pair 粘贴即连:

```
motif://pair?v=1&host=43.173.125.125&port=8099&psk=<…>&pk=<…>
```

reviewer 连上后:开终端(服务器上跑真实 shell)、浏览文件树、看 demo 仓库的 git diff。
无需账号,配对链接即唯一凭证(连接全程 TLS 加密 + 证书 pin)。

## run-review.sh 的模式（临时调试用）

- 默认:绑 `127.0.0.1`、`--rm`,退出时 trap 自动拆容器/网络/iptables。motifd 自动生成
  psk + 证书,启动后打印 `motif://pair` 链接(本次有效;持久部署才需固定 psk + 持久 data)。
  **注意**它的 cleanup 会删 `motif-review-net`——持久部署前 `pkill run-review.sh` 要等
  cleanup 跑完再建网络,否则竞态报 "network not found"。
- `--bind 0.0.0.0` `--advertise <公网IP>`:直接公网 TLS 直连(自行放行端口),打印
  `motif://pair` 链接的 review-notes 块。`--tunnel` 已不需要(motifd 自带 TLS)。
