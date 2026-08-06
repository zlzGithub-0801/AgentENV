#!/usr/bin/env bash
# Verify native Linux release artifacts inside an Ubuntu 22.04 userspace.
#
# Local artifacts:
#   DIST_DIR=./dist bash scripts/test-release-ubuntu22.sh
#
# Published release assets:
#   RELEASE_TAG=static-linux-probe-123-1 \
#     bash scripts/test-release-ubuntu22.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist_dir="${DIST_DIR:-$repo_root/dist}"
release_tag="${RELEASE_TAG:-}"
repo="zlzGithub-0801/AgentENV"

case "$(uname -m)" in
    x86_64|amd64) arch=x86_64; docker_arch=amd64 ;;
    aarch64|arm64) arch=aarch64; docker_arch=arm64 ;;
    *) echo "error: unsupported host architecture: $(uname -m)" >&2; exit 1 ;;
esac

if [[ -z "$release_tag" ]]; then
    cli="$dist_dir/aenv-linux-$arch"
    server_archive="$dist_dir/aenv-server-linux-$arch.tar.gz"
    [[ -f "$cli" ]] || { echo "error: missing $cli" >&2; exit 1; }
    [[ -f "$server_archive" ]] || { echo "error: missing $server_archive" >&2; exit 1; }
    source_dir="$(realpath "$dist_dir")"
else
    source_dir="$(mktemp -d)"
    trap 'rm -rf "$source_dir"' EXIT
    base_url="https://github.com/$repo/releases/download/$release_tag"
    curl -fL --retry 5 "$base_url/aenv-linux-$arch" \
        -o "$source_dir/aenv-linux-$arch"
    curl -fL --retry 5 "$base_url/aenv-server-linux-$arch.tar.gz" \
        -o "$source_dir/aenv-server-linux-$arch.tar.gz"
fi

docker run --rm \
    --privileged \
    --platform "linux/$docker_arch" \
    -v /dev:/dev \
    -v /lib/modules:/lib/modules:ro \
    -v "$source_dir:/release:ro" \
    -e TEST_ARCH="$arch" \
    ubuntu:22.04 \
    bash -euo pipefail -c '
        apt-get update >/dev/null
        apt-get install -y --no-install-recommends \
            ca-certificates curl e2fsprogs file iproute2 iptables jq kmod \
            sudo umoci zstd >/dev/null

        work=/tmp/aenv-release
        mkdir -p "$work/server"
        cp "/release/aenv-linux-$TEST_ARCH" "$work/aenv"
        tar -xzf "/release/aenv-server-linux-$TEST_ARCH.tar.gz" -C "$work/server"
        chmod +x "$work/aenv" "$work/server/server" \
            "$work/server/ublk/uvm-ublk-daemon"

        for binary in "$work/aenv" "$work/server/server" \
            "$work/server/ublk/uvm-ublk-daemon"; do
            echo "Checking $binary"
            file "$binary"
            output="$(ldd "$binary")"
            printf "%s\n" "$output"
            ! grep -q "not found" <<<"$output"
            ! grep -Eq "lib(ssl|crypto)\\.so" <<<"$output"
            "$binary" --help >/dev/null
        done

        mkdir -p /etc/overlaybd
        cp "$work/server/etc/overlaybd/overlaybd.json" \
            /etc/overlaybd/overlaybd.json
        mkdir -p /run/aenv /root/.config/aenv
        printf "url = \"http://127.0.0.1:18080\"\napi_key = \"\"\n" \
            > /root/.config/aenv/credentials

        export API_ADDR=127.0.0.1:18080
        export AENV_CONFIG_PATH="$work/server/default.toml"
        export AENV_HOME_PATH="$work/server"
        export AENV_RUNTIME_PATH=/run/aenv
        export AENV_VIRTUALIZATION_MODE=kvm
        export AENV_UBLK_DAEMON_BINARY_PATH="$work/server/ublk/uvm-ublk-daemon"

        "$work/server/server" >"$work/server.log" 2>&1 &
        server_pid=$!
        cleanup() {
            kill "$server_pid" >/dev/null 2>&1 || true
            wait "$server_pid" >/dev/null 2>&1 || true
        }
        trap cleanup EXIT

        healthy=0
        for _ in $(seq 1 120); do
            if curl -fsS http://127.0.0.1:18080/health >/dev/null; then
                healthy=1
                break
            fi
            if ! kill -0 "$server_pid" >/dev/null 2>&1; then
                break
            fi
            sleep 1
        done
        if [[ "$healthy" != 1 ]]; then
            echo "error: server did not become healthy" >&2
            cat "$work/server.log" >&2
            exit 1
        fi

        if ! timeout 600 "$work/aenv" pull ubuntu:22.04 \
            --name ubuntu22-compat --timeout 540; then
            echo "error: aenv pull failed" >&2
            cat "$work/server.log" >&2
            exit 1
        fi

        echo "Ubuntu 22.04 aenv pull test passed for $TEST_ARCH."
    '
