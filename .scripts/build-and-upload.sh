#!/usr/bin/env bash
#
# Local mirror of .github/workflows/build.yml: builds the openvtc release
# binary and uploads it to Cloudflare R2 under both `latest/` and a
# versioned path (`<crate-version>-<git-short-sha>/`).
#
# Required env vars (export them, or put them in <repo>/.env):
#   R2_ACCESS_KEY_ID
#   R2_SECRET_ACCESS_KEY
#   R2_ACCOUNT_ID
#   R2_BUCKET
#
# Usage:
#   .scripts/build-and-upload.sh            # build + upload
#   .scripts/build-and-upload.sh --build-only
#   .scripts/build-and-upload.sh --dry-run  # build + print aws cmds, don't upload

set -euo pipefail

BUILD_ONLY=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --build-only) BUILD_ONLY=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

for tool in cargo git jq; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
if [[ $BUILD_ONLY -eq 0 ]]; then
  command -v aws >/dev/null || { echo "missing tool: aws (install aws-cli)" >&2; exit 1; }
fi

metadata="$(cargo metadata --no-deps --format-version 1)"
openvtc_version="$(printf '%s' "$metadata" | jq -r '.packages[] | select(.name=="openvtc") | .version')"
if [[ -z "$openvtc_version" || "$openvtc_version" == "null" ]]; then
  echo "Failed to resolve openvtc version" >&2
  exit 1
fi
git_hash="$(git rev-parse --short HEAD)"
version_tag="${openvtc_version}-${git_hash}"

echo "==> building openvtc ${version_tag} (release, --no-default-features)"
cargo build --release -p openvtc --no-default-features

binary="target/release/openvtc"
[[ -f "$binary" ]] || { echo "build succeeded but $binary missing" >&2; exit 1; }

if [[ $BUILD_ONLY -eq 1 ]]; then
  echo "==> --build-only set; skipping upload. binary: $binary"
  exit 0
fi

for var in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ACCOUNT_ID R2_BUCKET; do
  if [[ -z "${!var:-}" ]]; then
    echo "missing env var: $var (set in shell or in <repo>/.env)" >&2
    exit 1
  fi
done

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="us-east-1"
ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

latest_dest="s3://${R2_BUCKET}/openvtc/latest/openvtc"
versioned_dest="s3://${R2_BUCKET}/openvtc/${version_tag}/openvtc"

upload() {
  local dest="$1"
  echo "==> uploading $binary -> $dest"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "    [dry-run] aws s3 cp $binary $dest --endpoint-url $ENDPOINT"
  else
    aws s3 cp "$binary" "$dest" --endpoint-url "$ENDPOINT"
  fi
}

upload "$latest_dest"
upload "$versioned_dest"

echo "==> done."
