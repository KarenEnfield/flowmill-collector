#!/bin/bash

# shellcheck disable=SC1091
[[ ! -e ./debug-info.conf ]] || source ./debug-info.conf

if [[ "${FLOWMILL_DEBUG_MODE}" == true ]]; then
  echo "===================== /etc/os-release ====================="
  [[ ! -e /etc/os-release ]] || cat /etc/os-release
  echo "========================= uname -a ========================"
  uname -a
  echo "======================= environment ======================="
  env | sort
  echo "==========================================================="
fi

# For customers using Segment.IO's Chamber, you should store agent keys in
# a secret in chamber.  We will look up that key under $CHAMBER_SERVICE_NAME
if [[ -n "${CHAMBER_SERVICE_NAME}" ]]; then
  eval "$(/bin/chamber export --format dotenv "${CHAMBER_SERVICE_NAME}")"
fi

if [[ -n "${FLOWMILL_PROXY_HOST}" ]]; then
  export http_proxy="http://${FLOWMILL_PROXY_HOST}:${FLOWMILL_PROXY_PORT:-1080}"
  export HTTP_PROXY="${http_proxy}"
  export https_proxy="${http_proxy}"
  export HTTPS_PROXY="${http_proxy}"
fi

flowmill_install_dir=${FLOWMILL_INSTALL_DIR:-/srv}

flowmill_data_dir="/var/run/flowmill"
flowmill_dump_dir="${flowmill_data_dir}/dump"
mkdir -p "${flowmill_data_dir}" "${flowmill_dump_dir}"

kernel_headers_info_path="${flowmill_data_dir}/kernel_headers.cfg"
kernel_headers_log_path="${flowmill_data_dir}/kernel_headers.log"
echo "resolving kernel headers..."
if "${flowmill_install_dir}/kernel_headers.sh" "${kernel_headers_info_path}" \
  > "${kernel_headers_log_path}" 2>&1
then
  # shellcheck disable=SC1090
  . "${kernel_headers_info_path}"
else
  entrypoint_error="unknown"
fi

# cleanup kprobes previously created by Flowmill agent
if [[ -f /sys/kernel/debug/tracing/kprobe_events ]]; then
  FLOWMILL_TMPFILE="${flowmill_data_dir}/flowmill_kprobes"
  grep flowmill /sys/kernel/debug/tracing/kprobe_events \
    | cut -d: -f2 | sed -e 's/^/-:/' > "$FLOWMILL_TMPFILE"
  cat "$FLOWMILL_TMPFILE" >> /sys/kernel/debug/tracing/kprobe_events
  rm -f "$FLOWMILL_TMPFILE"
fi

cmd_args=( \
  --host-distro "${host_distro:-unknown}"
  --kernel-headers-source "${kernel_headers_source:-unknown}"
)

# Errors that take place before the agent is run will be reported through the
# command line flag `entrypoint_error`.
# Logging and troubleshooting will be handled by the agent itself.
if [[ -n "${entrypoint_error}" ]]; then
  cmd_args+=(--entrypoint-error "${entrypoint_error}")

  if [[ "${entrypoint_error}" != "kernel_headers_fetch_refuse" ]] && [[ -e "${kernel_headers_log_path}" ]]; then
    echo "--- BEGIN log from kernel headers resolution with error '${entrypoint_error}': -------------"
    cat "${kernel_headers_log_path}" || true
    echo "---  END  log from kernel headers resolution with error '${entrypoint_error}': -------------"
  fi
fi

echo "launching kernel collector..."
# on Debug (non-production) images, Flowmill devs can run in local mode by setting
# `FLOWMILL_RUN_LOCAL` to non-empty.
if [[ -n "${FLOWMILL_RUN_LOCAL}" ]]; then
  # shellcheck disable=SC1091
  source /srv/local.sh
  cmd_args+=("${local_cmd_args[@]}")
fi

# to run the collector under gdb, set `FLOWMILL_RUN_UNDER_GDB` to the flavor of gdb
# you want (e.g.: `cgdb` or `gdb`) - this is intended for development purposes
if [[ -n "${FLOWMILL_RUN_UNDER_GDB}" ]]; then
  apt-get update -y
  apt-get install -y --no-install-recommends "${FLOWMILL_RUN_UNDER_GDB}"

  if [[ "${#FLOWMILL_GDB_COMMANDS[@]}" -lt 1 ]]; then
    # default behavior is to run the agent, print a stack trace after it exits
    # and exit gdb without confirmation
    FLOWMILL_GDB_COMMANDS=( \
      'set pagination off'
      'handle SIGPIPE nostop pass'
      'handle SIGUSR1 nostop pass'
      'handle SIGUSR2 nostop pass'
      run
      bt
      'server q'
    )
  fi

  GDB_ARGS=()
  for gdb_cmd in "${FLOWMILL_GDB_COMMANDS[@]}"; do
    GDB_ARGS+=(-ex "${gdb_cmd}")
  done

  (set -x; exec "${FLOWMILL_RUN_UNDER_GDB}" -q "${GDB_ARGS[@]}" \
    --args "${flowmill_install_dir}/kernel-collector" "${cmd_args[@]}" "$@" \
  )
elif [[ -n "${FLOWMILL_RUN_UNDER_VALGRIND}" ]]; then
  # to run the collector under valgrind, set `FLOWMILL_RUN_UNDER_VALGRIND` to the options to pass to valgrind,
  # including at minimum the tool you want, for example:
  # "--tool=memcheck", or
  # "--tool=memcheck --leak-check=full --show-leak-kinds=all --track-origins=yes", or
  # "--tool=massif --stacks=yes"
  # note: to get full symbols from valgrind also build the kernel-collector in debug mode
  apt update -y
  apt install -y valgrind

  # shellcheck disable=SC2086
  (set -x; exec /usr/bin/valgrind ${FLOWMILL_RUN_UNDER_VALGRIND} "${flowmill_install_dir}/kernel-collector" "${cmd_args[@]}" "$@")
else
  (set -x; exec "${flowmill_install_dir}/kernel-collector" "${cmd_args[@]}" "$@")
fi
