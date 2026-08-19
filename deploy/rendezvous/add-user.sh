#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

auth_config="$script_dir/secrets/relay/auth.json"
private_key="$script_dir/secrets/issuer/jwt-private.pem"
client_to_server=10485760
server_to_client=10485760
burst_bytes=1048576
ttl_days=30
output_file=""
key_id=""
replace=false
subject=""
node_bin="${NODE_BIN:-node}"

usage() {
  cat <<'EOF'
Add an owner to the rendezvous auth config and issue an ES256 JWT.

Usage:
  deploy/rendezvous/add-user.sh SUBJECT [options]

Options:
  --auth-config PATH       Auth config to update
                           (default: deploy/rendezvous/secrets/relay/auth.json)
  --private-key PATH       ES256 private key used to sign the JWT
                           (default: deploy/rendezvous/secrets/issuer/jwt-private.pem)
  --client-to-server N     Client-to-server limit in bytes/sec (default: 10485760)
  --server-to-client N     Server-to-client limit in bytes/sec (default: 10485760)
  --burst-bytes N          Token-bucket burst in bytes (default: 1048576)
  --ttl-days N             JWT lifetime in days (default: 30)
  --kid VALUE              Optional JWT key ID
  --output PATH            Write the JWT to PATH with mode 0600 instead of stdout
  --replace                Replace an existing user's rates and reissue its JWT
  -h, --help               Show this help

The auth config is replaced atomically. Restart the relay after adding or
changing a user so it reloads auth.json. Restart motifd after replacing the JWT
file it uses.
EOF
}

die() {
  printf 'add-user: %s\n' "$*" >&2
  exit 1
}

take_value() {
  local option="$1"
  local remaining="$2"
  ((remaining >= 2)) || die "$option requires a value"
}

while (($# > 0)); do
  case "$1" in
    --auth-config)
      take_value "$1" "$#"
      auth_config="$2"
      shift 2
      ;;
    --private-key)
      take_value "$1" "$#"
      private_key="$2"
      shift 2
      ;;
    --client-to-server)
      take_value "$1" "$#"
      client_to_server="$2"
      shift 2
      ;;
    --server-to-client)
      take_value "$1" "$#"
      server_to_client="$2"
      shift 2
      ;;
    --burst-bytes)
      take_value "$1" "$#"
      burst_bytes="$2"
      shift 2
      ;;
    --ttl-days)
      take_value "$1" "$#"
      ttl_days="$2"
      shift 2
      ;;
    --kid)
      take_value "$1" "$#"
      key_id="$2"
      shift 2
      ;;
    --output)
      take_value "$1" "$#"
      output_file="$2"
      shift 2
      ;;
    --replace)
      replace=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      die "unknown option: $1"
      ;;
    *)
      [[ -z "$subject" ]] || die "unexpected argument: $1"
      subject="$1"
      shift
      ;;
  esac
done

[[ -n "$subject" ]] || {
  usage >&2
  exit 2
}

for value_name in client_to_server server_to_client burst_bytes ttl_days; do
  value="${!value_name}"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$value_name must be a positive integer"
done

command -v -- "$node_bin" >/dev/null 2>&1 || die "Node.js is required (set NODE_BIN to override)"
[[ -f "$auth_config" ]] || die "auth config not found: $auth_config"
[[ -f "$private_key" ]] || die "private key not found: $private_key"

umask 077

"$node_bin" - \
  "$auth_config" \
  "$private_key" \
  "$subject" \
  "$client_to_server" \
  "$server_to_client" \
  "$burst_bytes" \
  "$ttl_days" \
  "$key_id" \
  "$output_file" \
  "$replace" <<'NODE'
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const [
  authPath,
  privateKeyPath,
  subject,
  clientToServerRaw,
  serverToClientRaw,
  burstBytesRaw,
  ttlDaysRaw,
  keyId,
  outputPath,
  replaceRaw,
] = process.argv.slice(2);

const replace = replaceRaw === 'true';

function positiveSafeInteger(raw, name) {
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${name} must be a positive safe integer`);
  }
  return value;
}

if (subject.length === 0 || subject.trim() !== subject) {
  throw new Error('subject must be non-empty and have no leading or trailing whitespace');
}
if (/[\u0000-\u001f\u007f]/u.test(subject)) {
  throw new Error('subject must not contain control characters');
}

const clientToServer = positiveSafeInteger(clientToServerRaw, 'client-to-server rate');
const serverToClient = positiveSafeInteger(serverToClientRaw, 'server-to-client rate');
const burstBytes = positiveSafeInteger(burstBytesRaw, 'burst bytes');
const ttlDays = positiveSafeInteger(ttlDaysRaw, 'TTL days');
const ttlSeconds = ttlDays * 24 * 60 * 60;
if (!Number.isSafeInteger(ttlSeconds)) {
  throw new Error('TTL days is too large');
}

const authRaw = fs.readFileSync(authPath, 'utf8');
const auth = JSON.parse(authRaw);
if (!auth.jwt || auth.jwt.algorithm !== 'ES256') {
  throw new Error('auth config must use jwt.algorithm = ES256');
}
if (typeof auth.jwt.issuer !== 'string' || auth.jwt.issuer.length === 0) {
  throw new Error('auth config has no JWT issuer');
}
if (typeof auth.jwt.audience !== 'string' || auth.jwt.audience.length === 0) {
  throw new Error('auth config has no JWT audience');
}
if (!auth.users || typeof auth.users !== 'object' || Array.isArray(auth.users)) {
  throw new Error('auth config has no users object');
}

const alreadyExists = Object.prototype.hasOwnProperty.call(auth.users, subject);
if (alreadyExists && !replace) {
  throw new Error(`user ${JSON.stringify(subject)} already exists; pass --replace to update it`);
}

if (outputPath) {
  const outputParent = path.dirname(outputPath);
  const outputParentStat = fs.statSync(outputParent, {throwIfNoEntry: false});
  if (!outputParentStat || !outputParentStat.isDirectory()) {
    throw new Error(`output directory does not exist: ${outputParent}`);
  }
  if (fs.existsSync(outputPath) && !replace) {
    throw new Error(`output already exists: ${outputPath}; pass --replace to overwrite it`);
  }
}

const privateKeyPem = fs.readFileSync(privateKeyPath);
const privateKey = crypto.createPrivateKey(privateKeyPem);
if (privateKey.asymmetricKeyType !== 'ec') {
  throw new Error('private key is not an EC key');
}
const curve = privateKey.asymmetricKeyDetails?.namedCurve;
if (curve && curve !== 'prime256v1' && curve !== 'P-256') {
  throw new Error(`private key must use P-256, got ${curve}`);
}

const now = Math.floor(Date.now() / 1000);
const header = {alg: 'ES256', typ: 'JWT'};
if (keyId) header.kid = keyId;
const claims = {
  iss: auth.jwt.issuer,
  aud: auth.jwt.audience,
  sub: subject,
  iat: now,
  exp: now + ttlSeconds,
  jti: crypto.randomUUID(),
};
const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
const signingInput = `${encode(header)}.${encode(claims)}`;
const signature = crypto.sign('sha256', Buffer.from(signingInput), {
  key: privateKey,
  dsaEncoding: 'ieee-p1363',
});
if (signature.length !== 64) {
  throw new Error(`unexpected ES256 signature length: ${signature.length}`);
}
const token = `${signingInput}.${signature.toString('base64url')}`;

Object.defineProperty(auth.users, subject, {
  value: {
    client_to_server_bytes_per_sec: clientToServer,
    server_to_client_bytes_per_sec: serverToClient,
    burst_bytes: burstBytes,
  },
  enumerable: true,
  configurable: true,
  writable: true,
});

function atomicWrite(targetPath, data, mode) {
  const temporaryPath = path.join(
    path.dirname(targetPath),
    `.${path.basename(targetPath)}.tmp-${process.pid}-${crypto.randomUUID()}`,
  );
  try {
    fs.writeFileSync(temporaryPath, data, {encoding: 'utf8', mode, flag: 'wx'});
    fs.chmodSync(temporaryPath, mode);
    fs.renameSync(temporaryPath, targetPath);
  } finally {
    try {
      fs.unlinkSync(temporaryPath);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
}

const authMode = fs.statSync(authPath).mode & 0o777;
atomicWrite(authPath, `${JSON.stringify(auth, null, 2)}\n`, authMode);

if (outputPath) {
  atomicWrite(outputPath, `${token}\n`, 0o600);
  console.error(`JWT written to ${outputPath}`);
} else {
  process.stdout.write(`${token}\n`);
}

console.error(
  `${alreadyExists ? 'Updated' : 'Added'} rendezvous user ${JSON.stringify(subject)}; ` +
  `JWT expires ${new Date(claims.exp * 1000).toISOString()}`,
);
NODE
