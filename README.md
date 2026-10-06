# byos-debian (mlab-node)

Native Debian packaging of the M-Lab BYOS ("Bring Your Own Server") Network
Diagnostic Tool (NDT) measurement stack. Each component runs as a hardened
systemd service, confined with systemd's own sandboxing directives.

## What's in the package

The `mlab-node` package installs and runs the following systemd services:

| Service                          | Unit                                  |
|----------------------------------|---------------------------------------|
| Node registration (Autojoin API) | `mlab-node-register.service`          |
| NDT7 measurement server          | `mlab-node-ndt-server.service`        |
| Heartbeat (Locate API)           | `mlab-node-heartbeat.service`         |
| UUID annotator                   | `mlab-node-uuid-annotator.service`    |
| Jostler (GCS archival)           | `mlab-node-jostler.service`           |
| Traceroute caller (scamper)      | `mlab-node-traceroute-caller.service` |
| Prometheus node exporter         | `mlab-node-node-exporter.service`     |

There are also a few one-shot units for schema generation, the UUID prefix,
BBR, and external-IP metadata. The whole stack is started and stopped as a
unit through `mlab-node.target`; if `register-node` goes down, the entire
stack is brought down with it.

The component binaries are built at package build time from the pinned
upstream sources (see `.build/build-binaries.sh`).

## File layout

The [root](./root) directory mirrors the installed filesystem layout: a
file at `root/foo/bar` is installed as `/foo/bar`.

| Path                               | Contents                                        |
|------------------------------------|-------------------------------------------------|
| `/etc/mlab-node/api-key.env`       | M-Lab API key (`0600 root:root`)                |
| `/etc/mlab-node/locate/verify.pub` | Locate token verification key                   |
| `/etc/mlab-node/node.env`          | node configuration (non-secret), generated from the debconf answers |
| `/run/mlab-node/sockets/`          | tcpinfo / ipservice unix sockets                |
| `/usr/libexec/mlab-node/`          | binaries and scripts                            |
| `/usr/share/mlab-node/html/`       | static content served by ndt-server             |
| `/usr/share/mlab-node/static.env`  | package-owned constants                         |
| `/var/lib/mlab-node/autocert/`     | Let's Encrypt certificate cache                 |
| `/var/lib/mlab-node/node/`         | registration data + service-account credentials |
| `/var/lib/mlab-node/resultsdir/`   | measurement results awaiting upload             |
| `/var/lib/mlab-node/schemas/`      | generated JSON schemas + uuid.prefix            |
| `/usr/share/mlab-node/templates/`  | initial versions of the two `/etc/mlab-node/*.env` files |
| `/etc/apt/apt.conf.d/52mlab-node-unattended-upgrades` | unattended-upgrades settings (if enabled) |

The binaries built by this package are installed under `/usr/libexec/mlab-node`
because the operator does not need to run them directly and the only
(typical) consumer is `systemd`. This usage is consistent with the stated
purpose of `libexec` according to [FHS][fhs]. Debian supports FHS 3.0
and hence `libexec` since version 4.1.5 of the Debian Policy.

[fhs]: https://refspecs.linuxfoundation.org/FHS_3.0/fhs-3.0.html

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
`dpkg-buildpackage`, debhelper 13.14 or newer (older versions ignore
units under `/usr/lib/systemd/system`; on bookworm take it from backports), a
recent Go, `git`, `file`, and a C toolchain
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
pre-filled: with the value already in `/etc/mlab-node/*.env` when there is one,
otherwise, on a fresh install, with a guess derived from the host. Check the
guesses.

| Setting | Asked as | Pre-filled with |
|---|---|---|
| `API_KEY` | API key, echoed as typed | (no guess; cleared from debconf once written) |
| `IATA` | nearest large international airport | (no guess: a nearest-airport lookup proposes airfields; the dialog links a list of international airports) |
| `PROBABILITY` | load-balancer probability | `0.1` |
| `INTERFACE_NAME` | measurement interface | the default route's interface |
| `UPLINK` | uplink speed | the link speed the interface reports (`/sys/class/net/*/speed`), if any |
| `INTERFACE_MAXRATE` | max transmit rate | M-Lab's recommendation for the uplink: 1g → 150000000, 10g → 7000000000, else 75% of the uplink |
| `IPV4` | public IPv4 address | the address outbound traffic comes from (ipinfo.io), else the default route's source address if public |
| `IPV6` | public IPv6 address | likewise, over IPv6; optional |
| `TYPE` | machine type | `virtual`/`physical` per `systemd-detect-virt` |
| (unattended upgrades) | yes/no, default yes | see [Unattended upgrades](#unattended-upgrades) |

Answers are validated (uplink is lowercased for you); an invalid
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
mlab-node mlab-node/api-key string <api key>
mlab-node mlab-node/iata string lhr
mlab-node mlab-node/uplink string 10g
mlab-node mlab-node/type select physical
mlab-node mlab-node/unattended-upgrades boolean true
EOF
sudo env DEBIAN_FRONTEND=noninteractive apt install ./mlab-node_1.1.0_amd64.deb
```

The question names are listed in `debian/mlab-node.templates`. On upgrades
nothing is asked: the existing configuration is kept as is.

There is no organization setting: the organization is a property of the API
key on the Autojoin side, and the node learns it from the hostname it is
registered under (`<machine>.<org>.<project>.measurement-lab.org`).
`mlab-node-register-ready.service` exports it as `ORGANIZATION` in
`/run/mlab-node/metadata/registration.env` for jostler (GCS path) and ndt-server
(metrics label).

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

## APT repositories

CI publishes the package to Artifact Registry APT repositories, one per M-Lab project tier, all named `mlab-node` in `us-central1`: pushes to `main` upload the `~dev` snapshot to `mlab-staging`, a manual `workflow_dispatch` on any branch uploads it to `mlab-sandbox` (the dev channel), and `v*` tags upload the release to `mlab-autojoin` (stable). See the `publish-*` jobs in [`build-deb.yml`](.github/workflows/build-deb.yml) and [`.build/apt-publish.sh`](.build/apt-publish.sh). The repositories are private for now; a client reads them with `apt-transport-artifact-registry` and the repository signing key, which is ASCII-armored despite its URL and so must be saved with a `.asc` extension for `signed-by=` to accept it:

```
curl -fsSL https://us-central1-apt.pkg.dev/doc/repo-signing-key.gpg -o /etc/apt/keyrings/artifact-registry.asc
deb [signed-by=/etc/apt/keyrings/artifact-registry.asc] ar+https://us-central1-apt.pkg.dev/projects/<project> mlab-node main
```

Once the stable repository is made public, the same line without the `ar+` transport prefix works with plain https.

## Test deployment (M-Lab internal)

M-Lab runs this package on an `autonode-deb` VM in `mlab-sandbox` and in `mlab-staging` (us-central1, Terraform-managed in [terraform-support](https://github.com/m-lab/terraform-support), `modules/autojoin`), the deb-package counterpart of the `autonode` Docker Compose test VM. Each VM tracks its own project's `mlab-node` repository: the startup script (`scripts/setup-autonode-deb.sh` in terraform-support) configures the APT source and a systemd timer that runs `apt-get install --only-upgrade mlab-node` every 15 minutes, so on staging every merge to `main` reaches the VM on its own; the package's postinst restarts the stack gracefully on upgrade. The timer only upgrades an installed package, so a VM needs a one-time install and `/etc/mlab-node/*.env` configuration first.

Branches under development deploy through Cloud Build instead: a trigger on `sandbox-*` branches runs [`.build/cloudbuild.yaml`](.build/cloudbuild.yaml), whose first step builds the .deb in a `golang:1-bookworm` container with a `~wip` version stamp (above `~dev` snapshots, so the periodic upgrade does not replace the branch under test; below the release version), and [`.build/deploy.sh`](.build/deploy.sh) then copies it to the VM over IAP, installs it noninteractively (debconf takes its defaults and guesses), writes `/etc/mlab-node/node.env` and `/etc/mlab-node/api-key.env` (overriding `PROJECT`/`LOCATE_URL`/`AUTH_URL` to the project's own Autojoin/Locate), and restarts `mlab-node.target`. The trigger supplies `_API_KEY` and `_PROBABILITY` as substitutions. `-upload-schema` is left at the package default (`false`): schema uploads are manual and intentional.
