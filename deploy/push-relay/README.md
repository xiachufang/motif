# motif-push-relay Docker image

Author-operated APNs push relay image for Motif. It keeps the APNs `.p8`
signing keys out of `motifd` and the clients, then forwards motifd's encrypted
notification payloads to Apple over HTTP/2.

The image is built and pushed to GHCR by
[`.github/workflows/push-relay-image.yml`](../../.github/workflows/push-relay-image.yml)
on tags, on `main` pushes touching the relay, and on manual dispatch.

## Image

CI publishes the `linux/amd64` image to GHCR:

```sh
ghcr.io/<owner>/motif-push-relay:latest
ghcr.io/<owner>/motif-push-relay:<git-tag>
ghcr.io/<owner>/motif-push-relay:sha-<short-sha>
```

Replace `<owner>` with the GitHub org/user that owns the repository. GHCR
packages default to private; make the package public or `docker login ghcr.io`
on the host before pulling.

## Run

```sh
docker run -d --name motif-push-relay --restart=unless-stopped \
  -p 127.0.0.1:8088:8088 \
  -v /secure/AuthKey_SANDBOXK1.p8:/run/secrets/apns-sandbox.p8:ro \
  -v /secure/AuthKey_PRODKEY22.p8:/run/secrets/apns-production.p8:ro \
  -e APNS_SANDBOX_KEY_PATH=/run/secrets/apns-sandbox.p8 \
  -e APNS_SANDBOX_KEY_ID=SANDBOXK1 \
  -e APNS_PRODUCTION_KEY_PATH=/run/secrets/apns-production.p8 \
  -e APNS_PRODUCTION_KEY_ID=PRODKEY22 \
  -e APNS_TEAM_ID=UWNR93L682 \
  -e APNS_TOPIC=io.allsunday.motif \
  ghcr.io/<owner>/motif-push-relay:latest
```

The container runs as uid `10001`; mounted key files must be readable by that
uid, or you can override Docker's `--user` to match the host owner of the key
files. Keep it on loopback or a trusted segment and front it with a
TLS-terminating reverse proxy:

```sh
motifd --push-relay-url https://relay.example.com/v1/push ...
```

## Health

```sh
curl -fsS http://127.0.0.1:8088/healthz
```

The relay validates both APNs signers at startup, so a healthy response means
the process has already parsed the mounted `.p8` keys and signed provider JWTs.

## Build locally

```sh
docker build -f deploy/push-relay/Dockerfile -t motif-push-relay .
docker run --rm motif-push-relay --help
```
