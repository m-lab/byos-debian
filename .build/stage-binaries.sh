#!/bin/bash
#
# stage-binaries.sh stages the component binaries shipped in the mlab-node
# Debian package under ./binaries/:
#   - the M-Lab components are the official release binaries each repository
#     publishes (pure Go, statically linked, amd64);
#   - node_exporter is the official Prometheus release binary;
#   - scamper, the one C tool, is built here from the source tarball
#     traceroute-caller vendors, with flags specific to this package's sandbox.
# Versions and sha256 checksums are pinned in .build/components.env; every
# download is verified against them before it is staged.
#
# Caching: downloads are kept under binaries/.downloads/, named by their
# checksum, so a re-run only fetches what a pin change added. scamper carries
# a recipe-keyed stamp under binaries/.stamps/ and is rebuilt only when its
# tarball, configure flags or the host toolchain change. Delete binaries/ to
# start over.
#
# Local testing: with MLAB_NODE_LOCAL_BINARIES=<dir>, any staged name present
# in <dir> (e.g. <dir>/ndt-server) is staged from there instead of being
# downloaded, without checksum verification. Never set it for a package that
# leaves your machine.
set -euo pipefail
# download() runs in command substitutions; keep -e in effect there too.
shopt -s inherit_errexit

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${REPO_DIR}/binaries"
CACHE_DIR="${OUT_DIR}/.downloads"
STAMP_DIR="${OUT_DIR}/.stamps"

# Salt mixed into the scamper recipe key. Bump it to force a rebuild when the
# build logic changes in a way the key cannot see.
STAMP_SCHEMA=2

# shellcheck source=components.env
source "${SCRIPT_DIR}/components.env"

for tool in curl sha256sum tar gcc make file; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "ERROR: required build tool '${tool}' not found in PATH" >&2
    exit 1
  }
done

WORK_DIR="$(mktemp -d "${REPO_DIR}/.build-work.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

mkdir -p "${OUT_DIR}" "${CACHE_DIR}"

# check_binary PATH: sanity-check the produced ELF. Everything is built
# against glibc or statically by construction; this catches accidental
# linkage against anything that would not resolve on the target (e.g. a
# scamper private .so if --disable-shared regressed) and logs what was staged.
check_binary() {
  local bin="$1" info
  info="$(file -L "${bin}")"
  case "${info}" in
    *"statically linked"* | *"static-pie linked"*) ;;
    *"dynamically linked"*)
      if echo "${info}" | grep -q "ld-musl"; then
        echo "ERROR: ${bin##*/} is musl-linked and would not run on the target." >&2
        exit 1
      fi
      ;;
    *)
      echo "ERROR: ${bin} does not look like an executable: ${info}" >&2
      exit 1
      ;;
  esac
  echo "   ${bin##*/}: ${info#*: }"
}

# download URL SHA256: print the path of URL's content in the download cache,
# fetching it unless a cached copy already matches SHA256.
download() {
  local url="$1" sha="$2"
  local file="${CACHE_DIR}/${sha}"
  if [ -e "${file}" ] && echo "${sha}  ${file}" | sha256sum -c --status; then
    echo "${file}"
    return
  fi
  echo ">> downloading ${url}" >&2
  curl -fsSL --retry 3 -o "${WORK_DIR}/download" "${url}"
  if ! echo "${sha}  ${WORK_DIR}/download" | sha256sum -c --status; then
    echo "ERROR: checksum mismatch for ${url}" >&2
    echo "  expected: ${sha}" >&2
    echo "  got:      $(sha256sum "${WORK_DIR}/download" | awk '{print $1}')" >&2
    exit 1
  fi
  mv "${WORK_DIR}/download" "${file}"
  echo "${file}"
}

# local_override NAME: stage NAME from MLAB_NODE_LOCAL_BINARIES if it is
# there, and report whether it was.
local_override() {
  local name="$1"
  [ -n "${MLAB_NODE_LOCAL_BINARIES:-}" ] || return 1
  [ -e "${MLAB_NODE_LOCAL_BINARIES}/${name}" ] || return 1
  echo "   ${name}: LOCAL OVERRIDE from ${MLAB_NODE_LOCAL_BINARIES}, not verified" >&2
  install -m 0755 "${MLAB_NODE_LOCAL_BINARIES}/${name}" "${OUT_DIR}/${name}"
}

# --- M-Lab components: official release binaries ----------------------------
for entry in "${RELEASE_BINARIES[@]}"; do
  read -r name repo tag binary sha <<<"${entry}"
  if ! local_override "${name}"; then
    src="$(download \
      "https://github.com/${repo}/releases/download/${tag}/${binary}_${tag}_linux_amd64" \
      "${sha}")"
    install -m 0755 "${src}" "${OUT_DIR}/${name}"
  fi
  check_binary "${OUT_DIR}/${name}"
done

# --- node_exporter: official Prometheus release --------------------------------
if ! local_override node-exporter; then
  ne="node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64"
  src="$(download \
    "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${ne}.tar.gz" \
    "${NODE_EXPORTER_SHA256}")"
  tar -xzf "${src}" -C "${WORK_DIR}" "${ne}/node_exporter"
  install -m 0755 "${WORK_DIR}/${ne}/node_exporter" "${OUT_DIR}/node-exporter"
fi
check_binary "${OUT_DIR}/node-exporter"

# --- asnames.ipinfo.csv ----------------------------------------------------------
# The package ships the file and passes its location with -asname.url.
src="$(download "${ASNAMES_URL}" "${ASNAMES_SHA256}")"
install -m 0644 "${src}" "${OUT_DIR}/asnames.ipinfo.csv"
echo "   asnames.ipinfo.csv: $(wc -c <"${OUT_DIR}/asnames.ipinfo.csv" | tr -d ' ') bytes"

# --- scamper: built from source ------------------------------------------------------
# --disable-shared statically links scamper's internal libraries into the
# binary, so the package can ship the single file with no private .so deps.
# --disable-privsep drops scamper's built-in privilege separation (chroot to
# /var/empty + setuid), which by design cannot work inside the
# traceroute-caller unit's systemd sandbox (read-only /var, no CAP_SYS_CHROOT
# or CAP_SETUID, chroot filtered) and is redundant there: the unit itself
# confines scamper, and raw sockets come from the inherited CAP_NET_RAW
# ambient capability.
# OpenSSL is deliberately not linked: configure would silently pick it up if
# the dev headers happen to be installed, which would make the build depend
# on the host. traceroute-caller does not use the TLS probes. There is no
# --without-openssl switch (AX_CHECK_OPENSSL), so point the search at an
# empty directory instead.
SCAMPER_CONFIGURE_FLAGS="--disable-shared --disable-privsep --with-openssl=/nonexistent"
# The recipe key covers everything that determines the output: the tarball,
# the flags, and the native toolchain (whose glibc also sets the package's
# libc6 floor through dh_shlibdeps).
scamper_key="$(printf '%s\n' "schema=${STAMP_SCHEMA}" "tarball=${SCAMPER_SHA256}" \
  "configure=${SCAMPER_CONFIGURE_FLAGS}" "gcc=$(gcc -dumpfullversion)" \
  "libc=$(getconf GNU_LIBC_VERSION)" | sha256sum | awk '{print $1}')"
if local_override scamper; then
  :
elif [ -e "${OUT_DIR}/scamper" ] &&
  [ "$(cat "${STAMP_DIR}/scamper" 2>/dev/null)" = "${scamper_key}" ]; then
  echo "   scamper: cached, skipping build"
else
  rm -f "${STAMP_DIR}/scamper"
  src="$(download "${SCAMPER_URL}" "${SCAMPER_SHA256}")"
  echo ">> building scamper (${SCAMPER_DIST}, vendored in traceroute-caller)"
  scamper_build="${WORK_DIR}/scamper"
  scamper_prefix="${WORK_DIR}/scamper-install"
  mkdir -p "${scamper_build}"
  tar -xzf "${src}" -C "${scamper_build}"
  (
    cd "${scamper_build}/${SCAMPER_DIST}"
    chmod +x ./configure
    # shellcheck disable=SC2086 # deliberate word splitting of the flags
    ./configure --quiet --prefix="${scamper_prefix}" ${SCAMPER_CONFIGURE_FLAGS}
    make --quiet -j"$(nproc)" >/dev/null
    make --quiet install >/dev/null
  )
  install -m 0755 "${scamper_prefix}/bin/scamper" "${OUT_DIR}/scamper"
  mkdir -p "${STAMP_DIR}"
  printf '%s\n' "${scamper_key}" >"${STAMP_DIR}/scamper"
fi
check_binary "${OUT_DIR}/scamper"

echo
echo "Staged in ${OUT_DIR}"
