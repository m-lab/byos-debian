# byos-debian (mlab-node)

Native Debian packaging of the M-Lab BYOS ("Bring Your Own Server") Network
Diagnostic Tool (NDT) measurement stack. Each component runs as a hardened
systemd service, confined with systemd's own sandboxing directives.

## What's in the package

The `mlab-node` package installs and runs the following systemd services:

| Service | Unit |
|---|---|
| Node registration (Autojoin API) | `mlab-node-register.service` |
| NDT7 measurement server | `mlab-node-ndt-server.service` |
| Heartbeat (Locate API) | `mlab-node-heartbeat.service` |
| UUID annotator | `mlab-node-uuid-annotator.service` |
| Jostler (GCS archival) | `mlab-node-jostler.service` |
| Traceroute caller (scamper) | `mlab-node-traceroute-caller.service` |
| Prometheus node exporter | `mlab-node-node-exporter.service` |

There are also a few one-shot units for schema generation, the UUID prefix,
BBR, and external-IP metadata. The whole stack is started and stopped as a
unit through `mlab-node.target`; if `register-node` goes down, the entire
stack is brought down with it.

The component binaries are built at package build time from the pinned
upstream sources (see `.build/build-binaries.sh`).

## File layout

The [root](./root) directory mirrors the installed filesystem layout: a
file at `root/foo/bar` is installed as `/foo/bar`.

The binaries built by this package are installed under `/usr/lib/mlab`
under the assumption that an operator does not need to invoke them
directly, consistently with the [FHS][fhs-usr-lib]'s convention that
`/usr/lib` "may also include internal binaries that are not intended
to be executed directly by users or shell scripts."

[fhs-usr-lib]: https://refspecs.linuxfoundation.org/FHS_3.0/fhs-3.0.html#usrlibLibrariesForProgrammingAndPa

| Path                          | Contents                                                  |
|-------------------------------|-----------------------------------------------------------|
| `/usr/lib/mlab/`              | binaries, scripts, package-owned constants (`static.env`) |
| `/etc/mlab/mlab-node.env`     | configuration (non-secret), generated from the debconf answers |
| `/etc/mlab/api-key.env`       | M-Lab API key (`0600 root:root`), generated likewise      |
| `/etc/mlab/locate/verify.pub` | Locate token verification key                             |
| `/usr/share/mlab/templates/`  | the initial versions of the two `/etc/mlab/*.env` files   |
| `/etc/apt/apt.conf.d/52mlab-node-unattended-upgrades` | unattended-upgrades settings (if enabled) |
| `/var/lib/mlab/node/`         | registration data + service-account credentials           |
| `/var/lib/mlab/schemas/`      | generated JSON schemas + uuid.prefix                      |
| `/var/lib/mlab/resultsdir/`   | measurement results awaiting upload                       |
| `/var/lib/mlab/autocert/`     | Let's Encrypt certificate cache                           |
| `/run/mlab/sockets/`          | tcpinfo / ipservice unix sockets                          |
| `/usr/share/mlab/html/`       | static content served by ndt-server                       |

## Building the package

CI is the canonical way to build the package: every push runs the
[`build-deb` workflow](.github/workflows/build-deb.yml), which builds it for
amd64 and arm64 (natively, on `ubuntu-24.04-arm` runners for the latter) in a
`debian:bookworm` container and uploads the resulting .debs as workflow
artifacts. Building on bookworm sets the package's `libc6` floor to bookworm's
glibc, so the .deb installs on Debian 12 and anything newer. Pushing a `v*`
tag creates a GitHub Release with the .debs attached; production machines
should install from Releases.

Local builds work too and use the same script. You'll need
`dpkg-buildpackage`, debhelper, a recent Go, `git`, `file`, and a C toolchain
(for scamper and the cgo builds), plus network access to clone the pinned
sources and fetch Go modules:

```sh
dpkg-buildpackage -us -uc -b
```

(Add `-d` if Go is installed from upstream tarballs rather than the
`golang-go` package.) A locally built .deb inherits the host's glibc as its
`libc6` dependency floor, so a package built on a newer distro may not
install on bookworm; use the CI artifacts for anything that leaves your
machine.

The build clones each component's repository at its pinned release tag,
builds the binaries with the upstream builds' flags plus `-s -w` stripping,
and stages them under `binaries/`. Each component is cached with a
recipe-keyed stamp under `binaries/.stamps/`, so rebuilds only recompile
components whose version pin or build flags changed; delete `binaries/` to
force a full rebuild.

## Installing and configuring

```sh
sudo apt install ./mlab-node_1.1.0_amd64.deb
```

The installer asks for the node's configuration through debconf (the usual
terminal dialogs) and, once every required setting has a value, starts the
whole stack (it is also enabled to start on boot). Every question is
pre-filled: with the value already in `/etc/mlab/*.env` when there is one,
otherwise, on a fresh install, with a guess derived from the host. Check the
guesses.

| Setting | Asked as | Pre-filled with |
|---|---|---|
| `ORGANIZATION` | organization name | (no guess) |
| `API_KEY` | API key | (no guess; never stored in debconf) |
| `IATA` | nearest large international airport | (no guess: a nearest-airport lookup proposes airfields; the dialog links a list of international airports) |
| `PROBABILITY` | load-balancer probability | `0.1` |
| `INTERFACE_NAME` | measurement interface | the default route's interface |
| `UPLINK` | uplink speed | the link speed the interface reports (`/sys/class/net/*/speed`), if any |
| `INTERFACE_MAXRATE` | max transmit rate | M-Lab's recommendation for the uplink: 1g → 150000000, 10g → 7000000000, else 75% of the uplink |
| `IPV4` | public IPv4 address | the address outbound traffic comes from (ipinfo.io), else the default route's source address if public |
| `IPV6` | public IPv6 address | likewise, over IPv6; optional |
| `TYPE` | machine type | `virtual`/`physical` per `systemd-detect-virt` |
| (unattended upgrades) | yes/no, default yes | see [Unattended upgrades](#unattended-upgrades) |

Answers are validated (IATA and uplink are lowercased for you); an invalid
one is explained and asked again. To go through the questions again, with
the current values pre-filled:

```sh
sudo dpkg-reconfigure mlab-node
```

The files can also be edited by hand, followed by `sudo systemctl restart
mlab-node.target`. The package only ever replaces the `KEY=value` lines it
asks about, so comments, hand edits and extra settings (such as a `PROJECT`
override) survive upgrades and reconfigurations. If a required setting is
still empty after installation, the stack is not started and the postinst
says so.

### Unattended installation

Preseed the answers and install noninteractively; questions without a
preseeded answer take the default or the guess:

```sh
sudo debconf-set-selections <<EOF
mlab-node mlab-node/organization string myorg
mlab-node mlab-node/api-key password <api key>
mlab-node mlab-node/iata string lhr
mlab-node mlab-node/uplink string 10g
mlab-node mlab-node/type select physical
mlab-node mlab-node/unattended-upgrades boolean true
EOF
sudo env DEBIAN_FRONTEND=noninteractive apt install ./mlab-node_1.1.0_amd64.deb
```

The question names are listed in `debian/mlab-node.templates`. On upgrades
nothing is asked: the existing configuration is kept as is.

## Unattended upgrades

The installer asks (default: yes) whether the machine should install the
distribution's security updates and new versions of `mlab-node` on its own.
Accepting writes `/etc/apt/apt.conf.d/52mlab-node-unattended-upgrades`,
which turns on the daily `unattended-upgrade` run (`APT::Periodic::*`) and
allows upgrades from the Debian and Ubuntu security archives and from the
M-Lab APT repository (origin and label `mlab-node`), on top of whatever
`/etc/apt/apt.conf.d/50unattended-upgrades` already allows. Declining (or
answering no to `dpkg-reconfigure mlab-node`) removes that snippet and leaves
the rest of the apt configuration alone.

The `mlab-node` package itself is only upgraded automatically once the M-Lab
APT repository is in the machine's APT sources. On an upgrade the postinst
restarts `mlab-node.target` gracefully (ndt-server drains running tests
first). Kernel security updates still need a reboot; unattended-upgrades can
do that too (`Unattended-Upgrade::Automatic-Reboot`), but this package does
not turn it on.

## Operating

```sh
systemctl status mlab-node.target
systemctl list-dependencies mlab-node.target
journalctl -u mlab-node-ndt-server -f

# Stop / restart the entire stack.
sudo systemctl stop mlab-node.target
sudo systemctl restart mlab-node.target
```

## Prometheus metrics

All metrics are exposed directly on the host: 9990 ndt-server, 9991 jostler,
9992 uuid-annotator, 9993 heartbeat,
9994 traceroute-caller, 9995 node-exporter. ndt-server serves measurements on
80 (cleartext) and 443 (TLS).

## Test deployment (M-Lab internal)

M-Lab runs this package on the `autonode-deb` VM (us-central1, Terraform-managed in [terraform-support](https://github.com/m-lab/terraform-support), `modules/autojoin`), the deb-package counterpart of the `autonode` Docker Compose test VM. A Cloud Build trigger runs [`.build/cloudbuild.yaml`](.build/cloudbuild.yaml): the first step builds the .deb in a `golang:1-bookworm` container with a unique version stamp, and [`.build/deploy.sh`](.build/deploy.sh) then copies it to the VM over IAP, installs it noninteractively (debconf takes its defaults and guesses), writes `/etc/mlab/mlab-node.env` and `/etc/mlab/api-key.env` (overriding `PROJECT`/`LOCATE_URL`/`AUTH_URL` to the project's own Autojoin/Locate), and restarts `mlab-node.target`. The trigger supplies `_API_KEY` and `_PROBABILITY` as substitutions. `-upload-schema` is left at the package default (`false`): schema uploads are manual and intentional.
