#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

auth_config="$script_dir/secrets/relay/auth.json"
private_key="$script_dir/secrets/issuer/jwt-private.pem"
plan="pro"
ttl_days=30
output_file=""
key_id=""
replace=false
subject=""
node_bin="${NODE_BIN:-node}"

usage() {
  cat <<'EOF'
Issue an ES256 owner JWT for a configured rendezvous plan.

Usage:
  deploy/rendezvous/add-user.sh SUBJECT [options]

Options:
  --auth-config PATH  Auth config used for issuer/audience/plan validation
                      (default: deploy/rendezvous/secrets/relay/auth.json)
  --private-key PATH  ES256 private key used to sign the JWT
                      (default: deploy/rendezvous/secrets/issuer/jwt-private.pem)
  --plan NAME         Plan claim to issue (default: pro)
  --ttl-days N        JWT lifetime in days (default: 30)
  --kid VALUE         Optional JWT key ID
  --output PATH       Write the JWT to PATH with mode 0600 instead of stdout
  --replace           Allow overwriting an existing output file
  -h, --help          Show this help

Rvz has no users table. SUBJECT becomes the JWT sub, while the selected plan
defines per-installation and global bandwidth. The auth config is validated but
is not modified.
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
    --plan)
      take_value "$1" "$#"
      plan="$2"
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
[[ "$ttl_days" =~ ^[1-9][0-9]*$ ]] || die "ttl_days must be a positive integer"
[[ -n "$plan" && "$plan" == "${plan//[[:space:]]/}" ]] || die "plan must be non-empty and contain no whitespace"

command -v -- "$node_bin" >/dev/null 2>&1 || die "Node.js is required (set NODE_BIN to override)"
[[ -f "$auth_config" ]] || die "auth config not found: $auth_config"
[[ -f "$private_key" ]] || die "private key not found: $private_key"

umask 077

"$node_bin" - \
  "$auth_config" \
  "$private_key" \
  "$subject" \
  "$plan" \
  "$ttl_days" \
  "$key_id" \
  "$output_file" \
  "$replace" <<'NODE'
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const [authPath, privateKeyPath, subject, plan, ttlDaysRaw, keyId, outputPath, replaceRaw] =
  process.argv.slice(2);
const replace = replaceRaw === 'true';
const ttlDays = Number(ttlDaysRaw);
if (!Number.isSafeInteger(ttlDays) || ttlDays <= 0) {
  throw new Error('TTL days must be a positive safe integer');
}
const ttlSeconds = ttlDays * 24 * 60 * 60;
if (!Number.isSafeInteger(ttlSeconds)) throw new Error('TTL days is too large');

if (subject.length === 0 || subject.trim() !== subject) {
  throw new Error('subject must be non-empty and have no surrounding whitespace');
}
if (/[\u0000-\u001f\u007f]/u.test(subject)) {
  throw new Error('subject must not contain control characters');
}

const auth = JSON.parse(fs.readFileSync(authPath, 'utf8'));
if (!auth.jwt || auth.jwt.algorithm !== 'ES256') {
  throw new Error('auth config must use jwt.algorithm = ES256');
}
if (typeof auth.jwt.issuer !== 'string' || auth.jwt.issuer.length === 0) {
  throw new Error('auth config has no JWT issuer');
}
if (typeof auth.jwt.audience !== 'string' || auth.jwt.audience.length === 0) {
  throw new Error('auth config has no JWT audience');
}
if (!auth.plans || typeof auth.plans !== 'object' || Array.isArray(auth.plans)) {
  throw new Error('auth config has no plans object');
}
if (!Object.prototype.hasOwnProperty.call(auth.plans, plan)) {
  throw new Error(`plan ${JSON.stringify(plan)} is not configured`);
}

if (outputPath) {
  const parent = path.dirname(outputPath);
  const stat = fs.statSync(parent, {throwIfNoEntry: false});
  if (!stat || !stat.isDirectory()) throw new Error(`output directory does not exist: ${parent}`);
  if (fs.existsSync(outputPath) && !replace) {
    throw new Error(`output already exists: ${outputPath}; pass --replace to overwrite it`);
  }
}

const privateKey = crypto.createPrivateKey(fs.readFileSync(privateKeyPath));
if (privateKey.asymmetricKeyType !== 'ec') throw new Error('private key is not an EC key');
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
  plan,
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

function atomicWrite(targetPath, data) {
  const temporaryPath = path.join(
    path.dirname(targetPath),
    `.${path.basename(targetPath)}.tmp-${process.pid}-${crypto.randomUUID()}`,
  );
  try {
    fs.writeFileSync(temporaryPath, data, {encoding: 'utf8', mode: 0o600, flag: 'wx'});
    fs.renameSync(temporaryPath, targetPath);
  } finally {
    try {
      fs.unlinkSync(temporaryPath);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
}

if (outputPath) {
  atomicWrite(outputPath, `${token}\n`);
  console.error(`JWT written to ${outputPath}`);
} else {
  process.stdout.write(`${token}\n`);
}
console.error(
  `Issued ${JSON.stringify(plan)} JWT for ${JSON.stringify(subject)}; ` +
    `expires ${new Date(claims.exp * 1000).toISOString()}`,
);
NODE
