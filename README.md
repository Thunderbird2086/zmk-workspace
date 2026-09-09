# ZMK Workspace with Helper Script

## Directory Structure

| Path | Description |
| --- | --- |
| `zmk/` | ZMK firmware checkout. Build outputs land in `zmk/build/<build-dir>` |
| `zmk-modules/` | Local ZMK config repositories and extra modules (each subdirectory is a git repo) |
| `zmk-modules/<config>/` | A ZMK config repo (e.g. `non-nemo-zmk-config`) containing `config/`, `build.yaml`, `boards/`, etc. |
| `build-docker.sh` | Helper script that builds firmware inside the ZMK devcontainer (Docker) |

## Prerequisites

- Docker and the [`devcontainer` CLI](https://github.com/devcontainers/cli) (`npm install -g @devcontainers/cli`)
- A ZMK repo placed under `zmk/` as below
  ```bash
  $ git clone git@github.com:zmkfirmware/zmk.git
  ```
- Any ZMK module repos placed under `zmk-modules/` (e.g. `zmk-modules/zmk-helpers`)
- A ZMK config repo placed under `zmk-modules/` (e.g. `zmk-modules/non-nemo-zmk-config`)

The script manages the devcontainer itself (starts it via `devcontainer up`,
wipes/recreates it between runs, and stops/removes it on exit). It also ensures
Docker named volumes `zmk-config` and `zmk-modules` are bind-mounted to the
host directories, so host edits are visible inside the container at
`/workspaces/zmk-config/...` and `/workspaces/zmk-modules/...`.

## Usage

```bash
./build-docker.sh [-b <board>] [-S <shield>] [-d <build-dir>] [-c <zmk-config-repository>] [-e <extra-module>] [-y]
```

| Option | Description |
| --- | --- |
| `-b <board>` | Target Zephyr board (e.g. `holyiot_yj17120_usb`, `seeeduino_xiao_ble`). Required unless `-y` is used |
| `-S <shield>` | ZMK shield(s) to pass as `-DSHIELD`. Space-separated for multiple (e.g. `non_nemo_dongle dongle_screen`) |
| `-d <build-dir>` | Build directory. Relative paths are created under `zmk/build/` (default: `build`) and removed before rebuilding |
| `-c <config>` | Name of a ZMK config repo under `zmk-modules/` (e.g. `non-nemo-zmk-config`) |
| `-e <module>` | Extra ZMK module under `zmk-modules/` to add (e.g. `zmk-helpers`, `zmk-dongle-screen`). Can be repeated |
| `-y` | Build all entries from the selected config's `build.yaml` (matrix builds) |
| `-h` | Show usage |

### Examples

Single board build:

```bash
./build-docker.sh -b holyiot_yj17120_usb -d build/mydongle -c non-nemo-zmk-config

./build-docker.sh -b seeeduino_xiao_ble -d build/right -c non-nemo-zmk-config \
  -e zmk-helpers -e zmk-dongle-screen
```

Build a specific shield on a board (multiple shields may be space-separated
within the single `-S` argument):

```bash
./build-docker.sh -b yj17120//zmk -S non_nemo_dongle \
  -d build/non-nemo-dongle-yj17120 -c non-nemo-zmk-config \
  -e zmk-holyiot-board -e zmk-helpers
```

Build everything defined in the config's `build.yaml` (each target goes to
`zmk/build/<artifact-name>`):

```bash
./build-docker.sh -y -d build -c non-nemo-zmk-config
```

### What the script does

1. Validates that `zmk/`, `zmk-modules/`, and the chosen config repo exist.
2. Removes any stale build directory to force a clean rebuild.
3. Ensures the `zmk-config` / `zmk-modules` Docker named volumes point at the
   host directories, and starts (or recycles) the devcontainer for `zmk/`.
4. Runs `west init -l app/` (if needed) and `west update` inside the container.
5. Runs `west build -s app -d <build-dir> -b <board>` with
   `-DZMK_CONFIG=/workspaces/zmk-config/config` (the `zmk-config` volume is
   bound directly to the selected repo root, so no per-config segment is
   needed) and, when specified, `-DZMK_EXTRA_MODULES`, `-DSHIELD`, and any
   extra CMake args.
6. Stops and removes the devcontainer on exit.

On success the firmware artifacts (`.uf2` / `.bin`) are in
`zmk/build/<build-dir>` under the host filesystem.
