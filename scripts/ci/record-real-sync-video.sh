#!/usr/bin/env bash
set -euo pipefail

BUILD_TAG="${BUILD_TAG:?BUILD_TAG is required}"
DEVICE_FAMILY="${DEVICE_FAMILY:-iphone}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$PWD/artifact}"
SYNC_MARKER="${SYNC_MARKER:-cmux-real-sync-video}"
DEV_STACK_AUTH_TOKEN="${CMUX_MOBILE_DEV_STACK_AUTH_TOKEN:-cmux-dev-mobile-stack-token}"

mkdir -p "$ARTIFACT_DIR"

phase() {
  echo "==> $*"
}

run_with_timeout() {
  local seconds="$1"
  shift
  python3 - "$seconds" "$@" <<'PY'
import subprocess
import sys

timeout = float(sys.argv[1])
cmd = sys.argv[2:]
try:
    raise SystemExit(subprocess.run(cmd, timeout=timeout).returncode)
except subprocess.TimeoutExpired:
    print(f"command timed out after {timeout:g}s: {' '.join(cmd)}", file=sys.stderr)
    raise SystemExit(124)
PY
}

sanitize_tag() {
  local raw="$1"
  local cleaned
  cleaned="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  [[ -n "$cleaned" ]] || cleaned="dev"
  printf '%s' "$cleaned"
}

sanitize_bundle() {
  local raw="$1"
  local cleaned
  cleaned="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\.+//; s/\.+$//; s/\.+/./g')"
  [[ -n "$cleaned" ]] || cleaned="dev"
  printf '%s' "$cleaned"
}

TAG_SLUG="$(sanitize_tag "$BUILD_TAG")"
TAG_BUNDLE="$(sanitize_bundle "$BUILD_TAG")"
MAC_BUNDLE_ID="com.cmuxterm.app.debug.${TAG_BUNDLE}"
IOS_BUNDLE_ID="dev.cmux.ios.${TAG_SLUG}"
SOCKET_PATH="/tmp/cmux-debug-${TAG_SLUG}.sock"
MAC_RAW_VIDEO="$ARTIFACT_DIR/cmux-macos-${BUILD_TAG}.mp4"
IOS_RAW_VIDEO="$ARTIFACT_DIR/cmux-ios-${BUILD_TAG}.mp4"
FINAL_VIDEO="$ARTIFACT_DIR/cmux-real-sync-left-right-${BUILD_TAG}.mp4"
MAC_RECORD_LOG="$ARTIFACT_DIR/macos-record.log"
MAC_FRAME_DIR="$ARTIFACT_DIR/macos-frames"
IOS_RECORD_LOG="$ARTIFACT_DIR/ios-record.log"
METADATA_PATH="$ARTIFACT_DIR/metadata.json"

MAC_RECORDER_PID=""
IOS_RECORDER_PID=""
IOS_APP_LOG_PID=""
MAC_APP_PID=""
SIMULATOR_ID=""
SIMULATOR_CREATED="0"

stop_pid_bounded() {
  local pid="$1"
  local signal="${2:-INT}"
  if [[ -z "$pid" ]] || ! kill -0 "$pid" >/dev/null 2>&1; then
    return 0
  fi
  kill "-$signal" "$pid" >/dev/null 2>&1 || true
  for _ in $(seq 1 25); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      wait "$pid" >/dev/null 2>&1 || true
      return 0
    fi
    sleep 0.2
  done
  kill -KILL "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
}

cleanup() {
  set +e
  stop_pid_bounded "$MAC_RECORDER_PID" INT
  stop_pid_bounded "$IOS_RECORDER_PID" INT
  stop_pid_bounded "$IOS_APP_LOG_PID" TERM
  stop_pid_bounded "$MAC_APP_PID" TERM
  launchctl unsetenv CMUX_FORCE_MOBILE_HOST_LISTENER >/dev/null 2>&1 || true
  if [[ -n "$SIMULATOR_ID" ]]; then
    xcrun simctl terminate "$SIMULATOR_ID" "$IOS_BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
    if [[ "$SIMULATOR_CREATED" == "1" ]]; then
      xcrun simctl delete "$SIMULATOR_ID" >/dev/null 2>&1 || true
    fi
  fi
  osascript -e "tell application id \"$MAC_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  pkill -f "cmux DEV ${TAG_SLUG}.app/Contents/MacOS/cmux DEV" >/dev/null 2>&1 || true
}
trap cleanup EXIT

require_ffmpeg() {
  if ! command -v ffmpeg >/dev/null 2>&1; then
    brew install ffmpeg
  fi
  command -v ffmpeg >/dev/null 2>&1
}

require_pillow() {
  if ! python3 - <<'PY' >/dev/null 2>&1
import PIL
PY
  then
    python3 -m pip install --user pillow
  fi
  python3 - <<'PY' >/dev/null
import PIL
PY
}

select_simulator() {
  python3 - "$DEVICE_FAMILY" <<'PY'
import json
import shlex
import subprocess
import sys

family = sys.argv[1]
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
devices = [
    device
    for runtimes in data.get("devices", {}).values()
    for device in runtimes
    if device.get("isAvailable", True)
]
prefix = "iPad" if family == "ipad" else "iPhone"
preferred = ["iPad Pro 13-inch (M4)", "iPad Air 13-inch (M3)"] if family == "ipad" else ["iPhone 17", "iPhone 16"]
selected = next((d for name in preferred for d in devices if d.get("name") == name), None)
selected = selected or next((d for d in devices if d.get("name", "").startswith(prefix)), None)
created = False
if selected is None:
    runtimes_data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "available", "-j"]))
    runtimes = [
        runtime for runtime in runtimes_data.get("runtimes", [])
        if runtime.get("isAvailable", True)
        and (runtime.get("platform") == "iOS" or runtime.get("identifier", "").startswith("com.apple.CoreSimulator.SimRuntime.iOS"))
    ]
    if not runtimes:
        raise SystemExit(f"No available iOS simulator runtime for {family}")
    runtime = sorted(runtimes, key=lambda r: tuple(int(p) for p in r.get("version", "0").split(".") if p.isdigit()), reverse=True)[0]
    types_data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devicetypes", "-j"]))
    types = [device_type for device_type in types_data.get("devicetypes", []) if device_type.get("name", "").startswith(prefix)]
    device_type = next((d for name in preferred for d in types if d.get("name") == name), None) or next(iter(types), None)
    if device_type is None:
        raise SystemExit(f"No available {prefix} simulator device type")
    udid = subprocess.check_output([
        "xcrun", "simctl", "create", f"cmux Real Video {device_type['name']}",
        device_type["identifier"], runtime["identifier"],
    ], text=True).strip()
    selected = {"udid": udid, "name": f"cmux Real Video {device_type['name']}"}
    created = True
print(f"SIMULATOR_ID={shlex.quote(selected['udid'])}")
print(f"SIMULATOR_NAME={shlex.quote(selected['name'])}")
print(f"SIMULATOR_CREATED={'1' if created else '0'}")
PY
}

wait_for_socket() {
  phase "waiting for tagged socket $SOCKET_PATH"
  for _ in $(seq 1 120); do
    if [[ -S "$SOCKET_PATH" ]]; then
      phase "tagged socket is ready"
      return 0
    fi
    if [[ -n "$MAC_APP_PID" ]] && ! kill -0 "$MAC_APP_PID" >/dev/null 2>&1; then
      echo "Tagged cmux app exited before socket appeared" >&2
      tail -120 "$ARTIFACT_DIR/macos-app-stderr.log" >&2 || true
      return 1
    fi
    sleep 0.5
  done
  echo "Tagged cmux socket did not appear: $SOCKET_PATH" >&2
  tail -120 "$ARTIFACT_DIR/macos-app-stderr.log" >&2 || true
  return 1
}

cmux_tagged() {
  CMUX_QUIET=1 CMUX_TAG="$BUILD_TAG" scripts/cmux-debug-cli.sh "$@"
}

json_field() {
  python3 -c '
import json
import sys

key = sys.argv[1]
data = json.load(sys.stdin)
value = data.get(key)
if value is None:
    value = data.get(key.replace("_id", "_ref"))
if value is None:
    raise SystemExit(1)
print(value)
' "$1"
}

mint_attach_url() {
  local workspace_id="$1"
  local terminal_id="$2"
  local payload
  local params
  params="$(python3 - "$workspace_id" "$terminal_id" <<'PY'
import json
import sys
print(json.dumps({
    "ttl_seconds": 900,
    "workspace_id": sys.argv[1],
    "terminal_id": sys.argv[2],
    "route_kind": "debug_loopback",
}, separators=(",", ":")))
PY
)"
  for _ in $(seq 1 40); do
    payload="$(cmux_tagged rpc mobile.attach_ticket.create "$params" 2>/dev/null || true)"
    if [[ -n "$payload" ]]; then
      REPO_ROOT="$PWD" PAYLOAD="$payload" node --input-type=module <<'NODE'
import path from "node:path";
import { pathToFileURL } from "node:url";

const { buildAttachURL } = await import(
  pathToFileURL(path.join(process.env.REPO_ROOT, "scripts", "lib", "attach-url.mjs")).href
);
const { attachURL } = buildAttachURL(JSON.parse(process.env.PAYLOAD), { routeKind: "debug_loopback" });
process.stdout.write(attachURL);
NODE
      return 0
    fi
    sleep 0.5
  done
  return 1
}

simulator_host_ip() {
  local interface ip
  interface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
  if [[ -n "$interface" ]]; then
    ip="$(ipconfig getifaddr "$interface" 2>/dev/null || true)"
    if [[ -n "$ip" ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
  fi
  for interface in en0 en1; do
    ip="$(ipconfig getifaddr "$interface" 2>/dev/null || true)"
    if [[ -n "$ip" ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  python3 - <<'PY'
import socket
print(socket.gethostbyname(socket.gethostname()))
PY
}

rewrite_attach_url_loopback_host() {
  local attach_url="$1"
  local host="$2"
  python3 - "$attach_url" "$host" <<'PY'
import base64
import json
import sys
from urllib.parse import parse_qs, urlencode, urlparse, urlunparse

attach_url, host = sys.argv[1:3]
parts = urlparse(attach_url)
query = parse_qs(parts.query)
encoded = (query.get("payload") or [""])[0]
if not encoded:
    raise SystemExit("attach URL has no payload")
encoded += "=" * (-len(encoded) % 4)
ticket = json.loads(base64.urlsafe_b64decode(encoded.encode("utf-8")))
routes = ticket.get("routes") or ticket.get("r") or []
if not routes:
    raise SystemExit("attach ticket has no routes")

route = dict(routes[0])
endpoint = dict(route.get("endpoint") or route.get("e") or {})
port = endpoint.get("port") or endpoint.get("p")
if port is None:
    raise SystemExit("attach ticket first route has no port")

route["id"] = "debug_loopback"
route["kind"] = "debug_loopback"
route["endpoint"] = {
    "type": "host_port",
    "host": host,
    "port": int(port),
}
for key in ("i", "k", "e"):
    route.pop(key, None)
ticket["routes"] = [route]
ticket.pop("r", None)

rewritten_payload = base64.urlsafe_b64encode(
    json.dumps(ticket, separators=(",", ":")).encode("utf-8")
).decode("utf-8").rstrip("=")
flat_query = []
for key, values in query.items():
    if key == "payload":
        flat_query.append((key, rewritten_payload))
    else:
        for value in values:
            flat_query.append((key, value))
print(urlunparse(parts._replace(query=urlencode(flat_query))))
PY
}

write_attach_route_preflight() {
  local attach_url="$1"
  local route_json="$ARTIFACT_DIR/attach-route.json"
  local route_env="$ARTIFACT_DIR/attach-route.env"
  local preflight_log="$ARTIFACT_DIR/mobile-listener-preflight.txt"

  python3 - "$attach_url" "$route_json" >"$route_env" <<'PY'
import base64
import json
import shlex
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlparse

attach_url, route_json = sys.argv[1:3]
query = parse_qs(urlparse(attach_url).query)
encoded = (query.get("payload") or [""])[0]
if not encoded:
    raise SystemExit("attach URL has no payload")
encoded += "=" * (-len(encoded) % 4)
ticket = json.loads(base64.urlsafe_b64decode(encoded.encode("utf-8")))
routes = ticket.get("routes") or ticket.get("r") or []
if not routes:
    raise SystemExit("attach ticket has no routes")

def normalize(route):
    endpoint = route.get("endpoint") or route.get("e") or {}
    endpoint_type = endpoint.get("type") or endpoint.get("t")
    if endpoint_type != "host_port":
        return None
    host = endpoint.get("host") or endpoint.get("h")
    port = endpoint.get("port") or endpoint.get("p")
    if not host or port is None:
        return None
    return {
        "id": route.get("id") or route.get("i"),
        "kind": route.get("kind") or route.get("k"),
        "host": str(host),
        "port": int(port),
    }

route = next((candidate for candidate in (normalize(item) for item in routes) if candidate), None)
if route is None:
    raise SystemExit("attach ticket has no host_port route")

Path(route_json).write_text(json.dumps(route, indent=2) + "\n")
print(f"ATTACH_HOST={shlex.quote(route['host'])}")
print(f"ATTACH_PORT={route['port']}")
PY
  # shellcheck disable=SC1090
  source "$route_env"
  : "${ATTACH_HOST:?}"
  : "${ATTACH_PORT:?}"

  {
    echo "route: ${ATTACH_HOST}:${ATTACH_PORT}"
    echo
    echo "lsof:"
    lsof -nP -iTCP:"$ATTACH_PORT" -sTCP:LISTEN || true
    echo
    echo "socket connect:"
    python3 - "$ATTACH_HOST" "$ATTACH_PORT" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
with socket.create_connection((host, port), timeout=5):
    print(f"connected {host}:{port}")
PY
  } >"$preflight_log" 2>&1
  cat "$preflight_log"
}

start_macos_recording() {
  rm -rf "$MAC_FRAME_DIR"
  mkdir -p "$MAC_FRAME_DIR"
  : > "$MAC_RECORD_LOG"
  (
    set +e
    i=0
    failures=0
    while true; do
      frame="$(printf "%s/frame-%05d.png" "$MAC_FRAME_DIR" "$i")"
      text_file="$(printf "%s/frame-%05d.txt" "$MAC_FRAME_DIR" "$i")"
      {
        printf 'macOS cmux terminal\n'
        printf 'workspace: %s\n' "${WORKSPACE_ID:-unknown}"
        printf 'surface: %s\n\n' "${SURFACE_ID:-unknown}"
        cmux_tagged read-screen --workspace "$WORKSPACE_ID" --surface "$SURFACE_ID" --lines 28
      } >"$text_file" 2>>"$MAC_RECORD_LOG"
      if python3 - "$text_file" "$frame" <<'PY' >>"$MAC_RECORD_LOG" 2>&1
from pathlib import Path
import sys
from PIL import Image, ImageDraw, ImageFont

text_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
text = text_path.read_text(errors="replace")
image = Image.new("RGB", (1000, 700), "#050607")
draw = ImageDraw.Draw(image)
font = None
for candidate in (
    "/System/Library/Fonts/Menlo.ttc",
    "/System/Library/Fonts/SFNSMono.ttf",
    "/System/Library/Fonts/Courier.ttc",
    "/Library/Fonts/Courier New.ttf",
):
    try:
        font = ImageFont.truetype(candidate, 18)
        break
    except Exception:
        pass
if font is None:
    font = ImageFont.load_default()

x, y = 24, 24
line_height = 22
max_chars = 88
for raw_line in text.splitlines()[:29]:
    line = raw_line.expandtabs(4)
    while len(line) > max_chars:
        draw.text((x, y), line[:max_chars], fill="#d8dee9", font=font)
        y += line_height
        line = line[max_chars:]
        if y > 670:
            break
    if y > 670:
        break
    draw.text((x, y), line, fill="#d8dee9", font=font)
    y += line_height
    if y > 670:
        break
image.save(out_path)
PY
      then
        failures=0
      else
        failures=$((failures + 1))
        echo "macOS read-screen frame render failed: $text_file" >&2
        if [[ "$failures" -ge 10 ]]; then
          exit 1
        fi
      fi
      i=$((i + 1))
      sleep 0.25
    done
  ) >"$MAC_RECORD_LOG" 2>&1 &
  MAC_RECORDER_PID="$!"
  for _ in $(seq 1 40); do
    if [[ "$(find "$MAC_FRAME_DIR" -name 'frame-*.png' -type f | wc -l | tr -d ' ')" -ge 2 ]]; then
      return 0
    fi
    if ! kill -0 "$MAC_RECORDER_PID" >/dev/null 2>&1; then
      tail -80 "$MAC_RECORD_LOG" >&2 || true
      return 1
    fi
    sleep 0.25
  done
  stop_pid_bounded "$MAC_RECORDER_PID" TERM
  MAC_RECORDER_PID=""
  tail -80 "$MAC_RECORD_LOG" >&2 || true
  return 1
}

start_ios_recording() {
  xcrun simctl io "$SIMULATOR_ID" recordVideo --codec=h264 --force "$IOS_RAW_VIDEO" 2>"$IOS_RECORD_LOG" &
  IOS_RECORDER_PID="$!"
  for _ in $(seq 1 80); do
    grep -q "Recording started" "$IOS_RECORD_LOG" 2>/dev/null && return 0
    sleep 0.25
  done
  stop_pid_bounded "$IOS_RECORDER_PID" TERM
  IOS_RECORDER_PID=""
  tail -80 "$IOS_RECORD_LOG" >&2 || true
  return 1
}

start_ios_app_log() {
  xcrun simctl spawn "$SIMULATOR_ID" log stream \
    --style compact \
    --level info \
    --predicate 'process == "cmux" || process == "cmux-Runner"' \
    >"$ARTIFACT_DIR/ios-app.log" 2>&1 &
  IOS_APP_LOG_PID="$!"
}

stop_recorders() {
  stop_pid_bounded "$IOS_RECORDER_PID" INT
  IOS_RECORDER_PID=""
  stop_pid_bounded "$IOS_APP_LOG_PID" TERM
  IOS_APP_LOG_PID=""
  stop_pid_bounded "$MAC_RECORDER_PID" INT
  MAC_RECORDER_PID=""
  local frame_count
  frame_count="$(find "$MAC_FRAME_DIR" -name 'frame-*.png' -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$frame_count" -ge 2 && ! -s "$MAC_RAW_VIDEO" ]]; then
    ffmpeg -hide_banner -y -framerate 4 -pattern_type glob -i "$MAC_FRAME_DIR/frame-*.png" \
      -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
      -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$MAC_RAW_VIDEO" >>"$MAC_RECORD_LOG" 2>&1
  fi
}

stitch_videos() {
  ffmpeg -hide_banner -y \
    -i "$MAC_RAW_VIDEO" \
    -i "$IOS_RAW_VIDEO" \
    -filter_complex "\
[0:v]trim=duration=45,setpts=PTS-STARTPTS,scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:color=0x101418,fps=30[mac];\
[1:v]trim=duration=45,setpts=PTS-STARTPTS,scale=540:960:force_original_aspect_ratio=decrease,pad=540:960:(ow-iw)/2:(oh-ih)/2:color=0x101418,fps=30[ios];\
color=c=0x0b0f14:s=1920x1080:r=30:d=45[bg];\
[bg][mac]overlay=x=40:y=(H-h)/2[tmp];\
[tmp][ios]overlay=x=W-w-40:y=(H-h)/2[out]" \
    -map "[out]" -an -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$FINAL_VIDEO"
  [[ -s "$FINAL_VIDEO" ]]
}

phase "checking ffmpeg"
require_ffmpeg
phase "checking pillow"
require_pillow

ios_ready() { xcrun simctl runtime list 2>/dev/null | grep -qiE "iOS [0-9].*\(Ready\)"; }
if ! ios_ready; then
  phase "installing iOS simulator platform"
  xcodebuild -downloadPlatform iOS 2>&1 | tr '\r' '\n' | grep -ivE 'Preparing to download|registering download' | tail -8 || true
  ios_ready || { echo "iOS platform is not registered" >&2; exit 1; }
fi

phase "selecting simulator"
eval "$(select_simulator)"
export SIMULATOR_ID SIMULATOR_NAME SIMULATOR_CREATED
phase "booting simulator $SIMULATOR_NAME ($SIMULATOR_ID)"
xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
xcrun simctl erase "$SIMULATOR_ID"
xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
run_with_timeout 120 xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcrun simctl ui "$SIMULATOR_ID" appearance dark || true

phase "enabling macOS mobile pairing host"
defaults write "$MAC_BUNDLE_ID" mobile.iOSPairingHost.enabled -bool true
./scripts/download-prebuilt-ghosttykit.sh || ./scripts/ensure-ghosttykit.sh

MAC_RELOAD_LOG="$ARTIFACT_DIR/reload-macos.log"
phase "building tagged macOS cmux"
run_with_timeout 600 bash -c './scripts/reload.sh --tag "$1" --swift-frontend-workaround 2>&1 | tee "$2"' bash "$BUILD_TAG" "$MAC_RELOAD_LOG"
MAC_APP_PATH="$(awk '/^App path:/{getline; sub(/^  /,""); print; exit}' "$MAC_RELOAD_LOG")"
[[ -n "$MAC_APP_PATH" && -d "$MAC_APP_PATH" ]] || { echo "could not locate built macOS app from $MAC_RELOAD_LOG" >&2; exit 1; }

phase "launching tagged macOS cmux"
run_with_timeout 10 launchctl setenv CMUX_FORCE_MOBILE_HOST_LISTENER 1
run_with_timeout 30 open "$MAC_APP_PATH"
wait_for_socket

phase "configuring tagged macOS dev Stack auth token"
DEV_STACK_AUTH_PARAMS="$(python3 - "$DEV_STACK_AUTH_TOKEN" <<'PY'
import json
import sys

print(json.dumps({"enabled": True, "token": sys.argv[1]}, separators=(",", ":")))
PY
)"
cmux_tagged rpc mobile.dev_stack_auth.configure "$DEV_STACK_AUTH_PARAMS" >/dev/null

phase "activating tagged macOS cmux"
run_with_timeout 15 osascript -e "tell application id \"$MAC_BUNDLE_ID\" to activate" >/dev/null 2>&1 || true

phase "creating real cmux terminal workspace"
WORKSPACE_OUTPUT="$ARTIFACT_DIR/workspace-create-output.txt"
cmux_tagged --id-format uuids workspace create --name "iOS sync demo" --cwd "$PWD" --focus true --json > "$WORKSPACE_OUTPUT"
WORKSPACE_JSON="$(cat "$WORKSPACE_OUTPUT")"
WORKSPACE_ID="$(printf '%s\n' "$WORKSPACE_JSON" | json_field workspace_id)"
SURFACE_ID="$(printf '%s\n' "$WORKSPACE_JSON" | json_field surface_id)"

for _ in $(seq 1 40); do
  if cmux_tagged read-screen --workspace "$WORKSPACE_ID" --surface "$SURFACE_ID" --lines 5 >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

phase "minting terminal-scoped attach URL"
ATTACH_URL="$(mint_attach_url "$WORKSPACE_ID" "$SURFACE_ID")"
[[ -n "$ATTACH_URL" ]] || { echo "Failed to mint attach URL" >&2; exit 1; }
ATTACH_URL="$(rewrite_attach_url_loopback_host "$ATTACH_URL" "localhost")"
write_attach_route_preflight "$ATTACH_URL"

IOS_TEST_DERIVED_DATA="$ARTIFACT_DIR/ios-ui-test-derived-data"
IOS_TEST_LOG="$ARTIFACT_DIR/ios-sync-xctest.log"
IOS_RESULT_BUNDLE="$ARTIFACT_DIR/ios-sync-xctest.xcresult"
IOS_XCTESTRUN_ARTIFACT="$ARTIFACT_DIR/ios-sync-video.xctestrun"
phase "building iOS app and simulator typing UI test"
rm -rf "$IOS_TEST_DERIVED_DATA" "$IOS_RESULT_BUNDLE" "$IOS_XCTESTRUN_ARTIFACT"
run_with_timeout 900 xcodebuild \
  -workspace ios/cmux.xcworkspace \
  -scheme cmux-ios \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath "$IOS_TEST_DERIVED_DATA" \
  build-for-testing
IOS_XCTESTRUN="$(find "$IOS_TEST_DERIVED_DATA/Build/Products" -name '*.xctestrun' -type f | sort | head -1)"
[[ -s "$IOS_XCTESTRUN" ]] || { echo "could not locate generated xctestrun in $IOS_TEST_DERIVED_DATA" >&2; exit 1; }
phase "injecting simulator attach environment into xctestrun"
python3 - "$IOS_XCTESTRUN" "$ATTACH_URL" "$SYNC_MARKER" "$WORKSPACE_ID" \
  "${CMUX_UITEST_STACK_EMAIL:-${CMUX_DOGFOOD_STACK_EMAIL:-}}" \
  "${CMUX_UITEST_STACK_PASSWORD:-${CMUX_DOGFOOD_STACK_PASSWORD:-}}" \
  "$DEV_STACK_AUTH_TOKEN" <<'PY'
import plistlib
import sys

path, attach_url, marker, workspace_id, email, password, dev_stack_token = sys.argv[1:8]
with open(path, "rb") as handle:
    data = plistlib.load(handle)

def merge_env(config, key):
    env = dict(config.get(key) or {})
    env["CMUX_DOGFOOD_ATTACH_URL"] = attach_url
    env["SYNC_MARKER"] = marker
    env["CMUX_SYNC_WORKSPACE_ID"] = workspace_id
    env["CMUX_MOBILE_DEV_STACK_AUTH_TOKEN"] = dev_stack_token
    env["CMUX_UITEST_MOCK_DATA"] = "0"
    env["CMUX_SYNC_VIDEO_FORCE_AUTH"] = "1"
    env["CMUX_UITEST_AUTH_FIXTURE"] = "1"
    env["CMUX_UITEST_AUTH_USER_ID"] = "cloud-sync-video"
    env["CMUX_UITEST_AUTH_EMAIL"] = "cloud-sync-video@cmux.local"
    env["CMUX_UITEST_AUTH_NAME"] = "Cloud Sync Video"
    if email:
        env["CMUX_UITEST_STACK_EMAIL"] = email
    if password:
        env["CMUX_UITEST_STACK_PASSWORD"] = password
    config[key] = env

def merge_args(config, key):
    args = list(config.get(key) or [])
    additions = [
        "CMUX_SYNC_VIDEO_FORCE_AUTH=1",
        f"CMUX_DOGFOOD_ATTACH_URL={attach_url}",
        f"CMUX_SYNC_WORKSPACE_ID={workspace_id}",
    ]
    if email:
        additions.append(f"CMUX_UITEST_STACK_EMAIL={email}")
    for addition in additions:
        if addition not in args:
            args.append(addition)
    config[key] = args

def visit(value):
    if isinstance(value, dict):
        patch_current = any(
            key in value
            for key in (
                "EnvironmentVariables",
                "UITargetAppEnvironmentVariables",
                "TestHostBundleIdentifier",
                "TestHostPath",
                "TestBundlePath",
                "BlueprintName",
            )
        )
        if patch_current:
            merge_env(value, "EnvironmentVariables")
            merge_env(value, "UITargetAppEnvironmentVariables")
            merge_args(value, "CommandLineArguments")
            merge_args(value, "UITargetAppCommandLineArguments")
        for child in value.values():
            visit(child)
    elif isinstance(value, list):
        for child in value:
            visit(child)

visit(data)

with open(path, "wb") as handle:
    plistlib.dump(data, handle)
PY
cp "$IOS_XCTESTRUN" "$IOS_XCTESTRUN_ARTIFACT"

phase "starting macOS and iOS recordings"
start_macos_recording
start_ios_recording
start_ios_app_log

phase "typing synced terminal input from the iOS simulator"
run_with_timeout 240 xcodebuild \
  -xctestrun "$IOS_XCTESTRUN" \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -resultBundlePath "$IOS_RESULT_BUNDLE" \
  -only-testing:cmuxUITests/cmuxUITests/testCloudSyncVideoTypesIntoRealMacTerminal \
  test-without-building 2>&1 | tee "$IOS_TEST_LOG"
sleep 5

cmux_tagged read-screen --workspace "$WORKSPACE_ID" --surface "$SURFACE_ID" --lines 20 > "$ARTIFACT_DIR/macos-read-screen.txt" || true
xcrun simctl io "$SIMULATOR_ID" screenshot --type=png "$ARTIFACT_DIR/ios-final.png" || true
find "$MAC_FRAME_DIR" -name 'frame-*.png' -type f | sort | tail -1 | while read -r frame; do
  cp "$frame" "$ARTIFACT_DIR/macos-final.png"
done

phase "stopping recorders"
stop_recorders

[[ -s "$MAC_RAW_VIDEO" ]] || { echo "macOS recording missing: $MAC_RAW_VIDEO" >&2; exit 1; }
[[ -s "$IOS_RAW_VIDEO" ]] || { echo "iOS recording missing: $IOS_RAW_VIDEO" >&2; exit 1; }
phase "stitching left-right video"
stitch_videos

phase "writing metadata"
python3 - "$METADATA_PATH" <<PY
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text(json.dumps({
    "tag": "$BUILD_TAG",
    "platform": "sync-video",
    "mode": "real-cmux-desktop-ios",
    "deviceFamily": "$DEVICE_FAMILY",
    "simulatorId": "$SIMULATOR_ID",
    "simulatorName": "$SIMULATOR_NAME",
    "workspaceId": "$WORKSPACE_ID",
    "surfaceId": "$SURFACE_ID",
    "syncMarker": "$SYNC_MARKER",
    "video": "$(basename "$FINAL_VIDEO")",
    "macVideo": "$(basename "$MAC_RAW_VIDEO")",
    "iosVideo": "$(basename "$IOS_RAW_VIDEO")",
}, indent=2) + "\n")
PY

echo "Real cmux desktop+iOS video: $FINAL_VIDEO"
