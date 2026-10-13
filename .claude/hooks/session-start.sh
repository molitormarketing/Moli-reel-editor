#!/bin/bash
# Cloud sessions start from a fresh container: install the reel editor, the HyperFrames
# skills and everything doctor.sh checks for, then pre-download the Whisper model.
# Safe to re-run; each step skips work that's already done. A failed step warns and moves on.
set -euo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

REPO="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
SKILLS="$HOME/.claude/skills"
SKILL="$SKILLS/reel-editor"
ENG="$SKILL/engine"
export NODE_USE_ENV_PROXY=1   # Node's fetch ignores HTTPS_PROXY without this
export PATH="$HOME/.local/bin:$PATH"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

step() { echo "reel-editor setup: $1" >&2; }
warn() { echo "reel-editor setup: WARNING $1" >&2; }

# 1. HyperFrames skills
if [ ! -d "$SKILLS/hyperframes" ]; then
  step "installing HyperFrames skills"
  (cd "$HOME" && npx -y skills add heygen-com/hyperframes -g -a claude-code -s '*' -y --copy >/dev/null 2>&1) \
    || warn "HyperFrames skills failed: npx skills add heygen-com/hyperframes"
fi

# 2. The reel editor skill, from this repo (engine/ downloads are kept between runs)
step "installing reel-editor skill from $REPO"
mkdir -p "$SKILL" && cp -a "$REPO/skills/reel-editor/." "$SKILL/"

# 3. gsap: cdn.jsdelivr.net may be blocked, so take the identical file from npm.
#    setup_engine.sh's pinned checksum is enforced here too.
GSAP_SHA=96c01b81f44a3290e2b4532f55e2c9534b2adc43273a19f3756b2cb41f0fd0b6
if [ ! -s "$ENG/gsap.min.js" ]; then
  step "fetching gsap 3.13.0"
  mkdir -p "$ENG"
  if (cd "$TMP" && npm pack gsap@3.13.0 --silent >/dev/null 2>&1 && tar xzf gsap-3.13.0.tgz) \
     && [ "$(sha256sum "$TMP/package/dist/gsap.min.js" | cut -d' ' -f1)" = "$GSAP_SHA" ]; then
    cp "$TMP/package/dist/gsap.min.js" "$ENG/gsap.min.js"
  else
    warn "gsap download failed or its checksum didn't match"
  fi
fi

# 4. Sound effects and HyperFrames motion templates
step "setting up the template engine"
bash "$SKILL/scripts/setup_engine.sh" >/dev/null || warn "setup_engine.sh failed"

# 5. DeepFilterNet noise removal. Torch 2.1 + Python 3.11 is the combination it runs on;
#    the model comes via git because github.com/raw downloads are blocked.
if ! deepFilter --help >/dev/null 2>&1; then
  step "installing DeepFilterNet (downloads PyTorch, takes a few minutes)"
  uv tool install --python 3.11 deepfilternet --with 'torch==2.1.2' --with 'torchaudio==2.1.2' --with 'numpy<2' >/dev/null 2>&1 \
    || warn "DeepFilterNet failed: noise removal falls back to ffmpeg"
fi
if [ ! -f "$HOME/.cache/DeepFilterNet/DeepFilterNet3/config.ini" ]; then
  step "fetching the DeepFilterNet3 model"
  if git clone -q --depth 1 --filter=blob:none --sparse https://github.com/Rikorose/DeepFilterNet "$TMP/df" \
     && git -C "$TMP/df" sparse-checkout set --no-cone /models/DeepFilterNet3.zip; then
    mkdir -p "$HOME/.cache/DeepFilterNet"
    python3 -c "import zipfile,sys;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
      "$TMP/df/models/DeepFilterNet3.zip" "$HOME/.cache/DeepFilterNet"
  else
    warn "DeepFilterNet model download failed"
  fi
fi

# 6. Whisper: transcribing a second of tone downloads the model (needs huggingface.co
#    and *.hf.co allowed) and builds whisper.cpp, so the first real edit doesn't wait.
if [ ! -s "$HOME/.cache/hyperframes/whisper/models/ggml-small.en.bin" ]; then
  step "pre-downloading the Whisper model and building whisper.cpp"
  ffmpeg -v error -y -f lavfi -i "sine=f=300:d=1" -ar 16000 "$TMP/warm.wav"
  (cd "$HOME" && npx -y hyperframes transcribe "$TMP/warm.wav" -d "$TMP/warm" --json --model small.en >/dev/null 2>&1) \
    || warn "Whisper setup failed: allow huggingface.co and *.hf.co in the environment's network settings"
fi

bash "$SKILL/scripts/doctor.sh" >&2 || true
