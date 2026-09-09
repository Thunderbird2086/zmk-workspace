#!/bin/bash
# Build ZMK firmware using the repo's devcontainer-managed Docker environment.
# Usage:
#   ./build-docker.sh -b holyiot_yj17120_usb -d build/mydongle -c non-nemo-zmk-config
#   ./build-docker.sh -b seeeduino_xiao_ble -d build/right -c non-nemo-zmk-config -e zmk-helpers -e zmk-dongle-screen

set -euo pipefail

ROOT="${PWD}"
ZMK_ROOT="${ROOT}/zmk"
WORKSPACE_DIR="/workspaces/zmk"
ZMK_CONFIG_BASE="/workspaces/zmk-config"
ZMK_MODULES_BASE="/workspaces/zmk-modules"

BOARD=""
SHIELD=""
BUILD_DIR_ARG="build"
BUILD_YAML=0
EXTRA_MODULES=""
ZMK_CONFIG_HOST="${ROOT}/zmk-modules"   # config repo should be placed in zmk-modules directory, e.g. zmk-modules/non-nemo-zmk-config
ZMK_MODULES_HOST="${ROOT}/zmk-modules"
ZMK_CONFIG_CONTAINER="${ZMK_CONFIG_BASE}"
CONTAINER_ID=""

cleanup_devcontainer() {
  local container_id="${CONTAINER_ID}"

  if [[ -z "${container_id}" ]]; then
    container_id="$(container_id_for_repo)"
  fi

  if [[ -n "${container_id}" ]]; then
    echo "Stopping dev container '${container_id}'"
    docker stop "${container_id}" >/dev/null 2>&1 || true
    docker rm "${container_id}" >/dev/null 2>&1 || true
  fi
}

trap cleanup_devcontainer EXIT

ensure_named_volume() {
  local volume_name="$1"
  local expected_device="$2"
  local current_device=""

  if docker volume inspect "${volume_name}" >/dev/null 2>&1; then
    current_device="$(docker volume inspect "${volume_name}" --format '{{json .Options}}' 2>/dev/null || echo '{}')"
    if [[ "${current_device}" != *"\"device\":\"${expected_device}\""* ]]; then
      echo "Removing stale Docker volume '${volume_name}' (expected bind to '${expected_device}')"
      docker volume rm "${volume_name}" >/dev/null 2>&1 || true
    fi
  fi

  if ! docker volume inspect "${volume_name}" >/dev/null 2>&1; then
    docker volume create --driver local -o o=bind -o type=none \
      -o device="${expected_device}" "${volume_name}" >/dev/null
  fi
}

ensure_zmk_modules_volume() {
  echo "Ensuring Docker volume 'zmk-modules' is bound to '${ZMK_MODULES_HOST}'"
  ensure_named_volume "zmk-modules" "${ZMK_MODULES_HOST}"
}

ensure_zmk_config_volume() {
  echo "Ensuring Docker volume 'zmk-config' is bound to '${ZMK_CONFIG_HOST}'"
  ensure_named_volume "zmk-config" "${ZMK_CONFIG_HOST}"
}

ensure_devcontainer_cli() {
  if ! command -v devcontainer >/dev/null 2>&1; then
    echo "Error: devcontainer CLI is required. Install it with: npm install -g @devcontainers/cli" >&2
    exit 1
  fi
}

container_id_for_repo() {
  docker ps -aq --filter "label=devcontainer.local_folder=${ZMK_ROOT}" | head -n 1
}

ensure_devcontainer_state() {
  local container_id
  container_id="$(container_id_for_repo)"

  if [[ -n "${container_id}" ]]; then
    local state
    state="$(docker inspect --format '{{.State.Status}}' "${container_id}" 2>/dev/null || echo 'missing')"

    case "${state}" in
      running)
        echo "Dev container is running; restarting it to ensure the correct state."
        docker stop "${container_id}" >/dev/null
        docker rm -f "${container_id}" >/dev/null 2>&1 || true
        ;;
      created|restarting|paused|exited|dead|missing)
        echo "Dev container is in state '${state}'; recreating it."
        docker rm -f "${container_id}" >/dev/null 2>&1 || true
        ;;
      *)
        echo "Dev container is in unexpected state '${state}'; recreating it."
        docker rm -f "${container_id}" >/dev/null 2>&1 || true
        ;;
    esac
  else
    echo "Dev container is not running; starting it."
  fi

  devcontainer up --workspace-folder "${ZMK_ROOT}" >/dev/null
}

yaml_target_name() {
  local board="$1"
  local shield="$2"
  local artifact_name="$3"

  if [[ -n "${artifact_name}" ]]; then
    echo "${artifact_name}"
    return 0
  fi

  local name="${board//\//_}"
  if [[ -n "${shield}" ]]; then
    name="${name}-${shield// /_}"
  fi
  echo "${name}"
}

resolve_container_build_dir() {
  local requested_dir="$1"

  if [[ "${requested_dir}" == /* ]]; then
    echo "${requested_dir#${ROOT}/}"
    return 0
  fi

  echo "${WORKSPACE_DIR}/${requested_dir}"
}

run_west_init() {
  docker exec -w "${WORKSPACE_DIR}" "${CONTAINER_ID}" bash -lc '
    if [ ! -f .west/config ]; then
      west init -l app/
    fi
    west update > /dev/null 2>&1
  '
}

run_west_build() {
  local board="$1"
  local build_dir="$2"
  local shield="${3:-}"
  local snippet="${4:-}"
  local cmake_args="${5:-}"

  local -a build_cmd=(west build -s app -d "${build_dir}" -b "${board}")

  if [[ -n "${snippet}" ]]; then
    build_cmd+=(-S "${snippet}")
  fi

  build_cmd+=(-- -DZMK_CONFIG="${BUILD_CONFIG}")

  if [[ -n "${shield}" ]]; then
    build_cmd+=(-DSHIELD="${shield}")
  fi

  if [[ -n "${cmake_args}" ]]; then
    local -a extra_cmake_args
    read -r -a extra_cmake_args <<< "${cmake_args}"
    build_cmd+=("${extra_cmake_args[@]}")
  fi

  if [[ -n "${DZMK_EXTRA_MODULES}" ]]; then
    build_cmd+=(-DZMK_EXTRA_MODULES="${DZMK_EXTRA_MODULES}")
  fi

  docker exec -w "${WORKSPACE_DIR}" "${CONTAINER_ID}" bash -lc "$(printf '%q ' "${build_cmd[@]}")"
}

build_yaml_targets() {
  local yaml_path="${ZMK_CONFIG_HOST}/build.yaml"

  if [[ ! -f "${yaml_path}" ]]; then
    echo "Error: build.yaml not found at '${yaml_path}'." >&2
    exit 1
  fi

  local -a targets=()
  local target
  while IFS= read -r -d '' target; do
    targets+=("${target}")
  done < <(python3 - "${yaml_path}" <<'PY'
import sys
import yaml

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as handle:
    data = yaml.safe_load(handle) or {}

entries = data.get('include') if isinstance(data, dict) and 'include' in data else data
if isinstance(entries, dict):
    entries = [entries]
if not isinstance(entries, list):
    raise SystemExit(f"No build targets found in {path}")

for entry in entries:
    if not isinstance(entry, dict):
        continue
    board = entry.get('board')
    if not board:
        continue

    shield = entry.get('shield') or ''
    snippet = entry.get('snippet') or ''
    cmake_args = entry.get('cmake-args') or ''
    artifact_name = entry.get('artifact-name') or ''
    print(f"{board}\034{shield}\034{snippet}\034{cmake_args}\034{artifact_name}\0", end='')
PY
)

  if [[ ${#targets[@]} -eq 0 ]]; then
    echo "Error: no valid build entries found in '${yaml_path}'." >&2
    exit 1
  fi

  local idx=0
  for target in "${targets[@]}"; do
    idx=$((idx + 1))
    IFS=$'\034' read -r board shield snippet cmake_args artifact_name <<< "${target}"

    local target_name
    target_name="$(yaml_target_name "${board}" "${shield}" "${artifact_name}")"

    local target_build_dir="${BUILD_DIR_ARG}"
    if [[ -n "${artifact_name}" ]]; then
      target_build_dir="${target_build_dir}/${artifact_name}"
    else
      target_build_dir="${target_build_dir}/${target_name}"
    fi

    local target_build_dir_container
    target_build_dir_container="$(resolve_container_build_dir "${target_build_dir}")"

    echo "=============================================="
    echo "  YAML Build ${idx}/${#targets[@]}"
    echo "  Board: ${board}"
    echo "  Shield: ${shield:-<none>}"
    echo "  Snippet: ${snippet:-<none>}"
    echo "  CMake args: ${cmake_args:-<none>}"
    echo "  Artifact: ${artifact_name:-${target_name}}"
    echo "  Build dir: ${target_build_dir}"
    echo "=============================================="

    if [[ "${target_build_dir}" != /* ]] && [[ -d "${ZMK_ROOT}/${target_build_dir}" ]]; then
      rm -rf "${ZMK_ROOT}/${target_build_dir}"
    fi

    run_west_build "${board}" "${target_build_dir_container}" "${shield}" "${snippet}" "${cmake_args}"
  done
}

usage() {
  echo "Usage: $0 [-b <board>] [-S <shield>] [-d <build-dir>] [-c <zmk-config-repository>] [-e <extra-module>] [-y]"
  echo "  -S <shield>        Pass -DSHIELD to west build (single or space-separated list)"
  echo "  -y, --build-yaml  Build all entries from the selected zmk-config build.yaml"
  echo "Example: $0 -b holyiot_yj17120 -d build/mydongle -c non-nemo-zmk-config -e zmk-holyiot-board -S yj17120_tester"
  echo "Example: $0 -b seeeduino_xiao_ble -d build/right -c non-nemo-zmk-config -e zmk-helpers -e zmk-dongle-screen"
  echo "Example: $0 -y -d build -c non-nemo-zmk-config"
  exit 1
}

while getopts ":b:S:d:e:c:yh" opt; do
  case "$opt" in
    b)
      BOARD="$OPTARG"
      ;;
    S)
      SHIELD="$OPTARG"
      ;;
    d)
      BUILD_DIR_ARG="$OPTARG"
      ;;
    c)
      ZMK_CONFIG_HOST="${ZMK_CONFIG_HOST}/${OPTARG}"
      # The zmk-config volume is bound directly to the repo root, so
      # /workspaces/zmk-config == the repo root; do NOT double the path.
      ZMK_CONFIG_CONTAINER="${ZMK_CONFIG_BASE}"
      EXTRA_MODULES="${EXTRA_MODULES};${ZMK_MODULES_BASE}/${OPTARG}"
      ;;
    e)
      EXTRA_MODULES="${EXTRA_MODULES};${ZMK_MODULES_BASE}/${OPTARG}"
      ;;
    y)
      BUILD_YAML=1
      ;;
    h)
      usage
      ;;
    :)
      echo "Error: option -$OPTARG requires an argument." >&2
      usage
      ;;
    \?)
      echo "Error: invalid option -$OPTARG" >&2
      usage
      ;;
  esac
done

if [[ -z "${BOARD}" && "${BUILD_YAML}" -ne 1 ]]; then
  echo "Error: board is required unless -y is used." >&2
  usage
fi

if [[ ! -d "${ZMK_ROOT}" ]]; then
  echo "Error: ZMK checkout not found at '${ZMK_ROOT}'." >&2
  exit 1
fi

if [[ ! -d "${ZMK_CONFIG_HOST}" ]]; then
  echo "Error: ZMK config directory not found at '${ZMK_CONFIG_HOST}'." >&2
  exit 1
fi

if [[ ! -d "${ZMK_MODULES_HOST}" ]]; then
  echo "Error: ZMK modules directory not found at '${ZMK_MODULES_HOST}'." >&2
  exit 1
fi

if [[ "${BUILD_DIR_ARG}" == /* ]]; then
  BUILD_DIR_IN_CONTAINER="${BUILD_DIR_ARG#${ROOT}/}"
  BUILD_DIR_IN_CONTAINER="/workspaces/${BUILD_DIR_IN_CONTAINER}"
else
  BUILD_DIR_IN_CONTAINER="${WORKSPACE_DIR}/${BUILD_DIR_ARG}"
fi

if [[ "${BUILD_DIR_ARG}" != /* ]] && [[ -d "${ZMK_ROOT}/${BUILD_DIR_ARG}" ]]; then
  rm -rf "${ZMK_ROOT}/${BUILD_DIR_ARG}"
fi

EXTRA_MODULES="${EXTRA_MODULES#;}"
EXTRA_MODULES="${EXTRA_MODULES%;}"

DZMK_EXTRA_MODULES=""
if [[ -n "${EXTRA_MODULES}" ]]; then
  DZMK_EXTRA_MODULES="${EXTRA_MODULES}"
fi

ensure_devcontainer_cli
ensure_zmk_modules_volume
ensure_zmk_config_volume
ensure_devcontainer_state

CONTAINER_ID="$(container_id_for_repo)"
if [[ -z "${CONTAINER_ID}" ]]; then
  echo "Error: devcontainer did not start a ZMK container for '${ZMK_ROOT}'." >&2
  exit 1
fi

echo "=============================================="
echo "  ZMK Dev Container Build"
echo "  Board: ${BOARD}"
echo "  Build dir: ${BUILD_DIR_ARG}"
echo "  ZMK config: ${ZMK_CONFIG_HOST} -> ${ZMK_CONFIG_CONTAINER}"
echo "  Extra modules: ${DZMK_EXTRA_MODULES}"
echo "=============================================="

BUILD_CONFIG="${ZMK_CONFIG_CONTAINER}/config"

# test
# docker exec -w "${WORKSPACE_DIR}" -it "${CONTAINER_ID}" /bin/bash
# exit 0

run_west_init

if [[ "${BUILD_YAML}" -eq 1 ]]; then
  build_yaml_targets
else
  run_west_build "${BOARD}" "${BUILD_DIR_IN_CONTAINER}" "${SHIELD}" "" ""
fi

echo ""
echo "=============================================="
echo "  Build Complete!"
echo "  Output dir: ${BUILD_DIR_IN_CONTAINER}"
echo "=============================================="
