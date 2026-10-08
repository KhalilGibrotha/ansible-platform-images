# Ansible Execution Environments

This repository builds the container images the Ansible platform owns: the
**execution environments** (the runtime images Automation Controller and
`ansible-navigator` execute automation *inside*) and the **Dev Spaces tooling
image** (the authoring image the `ansible-dev-workspace` devfile *consumes*). It
is the "engine" side of the engine/content boundary — content repos (roles,
playbooks) are authored and tested elsewhere and run inside these images.

One thin shared base, purpose-built EEs layered on top, built once and promoted
by digest — plus the authoring image on its own track.

> **Registry namespace is temporary.** These images publish to
> `ghcr.io/khalilgibrotha/*` for now. When the platform is rebuilt internally,
> change `REGISTRY` and `OWNER` in the CI workflow (and the `base_image` /
> `DEVSPACES_BASE` defaults) to the internal registry, and repoint the consuming
> `ansible-dev-workspace` devfile at the published image. The references are
> deliberately in few, obvious places.

## The fleet

| Image | Kind | Purpose | Base | Owner | Key content |
|---|---|---|---|---|---|
| `ee-base` | runtime | Org foundation — OS, ansible-core/runner, CA certs, proxy, universal collections. Rarely changes. | UBI9 (lab) / `ee-minimal-rhel9` (SECU) | Platform | `ansible.posix`, `ansible.utils` |
| `ee-primary` | runtime | General-purpose, most automation | `ee-base` | Platform | `community.general`, `ansible.windows`, `redhat.rhel_system_roles` |
| `ee-vmware` | runtime | vSphere / vCenter virtualization | `ee-base` | Platform | `community.vmware`, `vmware.vmware_rest` + pyVmomi |
| `ee-network` | runtime | Network devices (Cisco, Arista, Juniper, F5) | `ee-base` | Platform *(network team can adopt later)* | `cisco.*`, `arista.eos`, `junipernetworks.junos`, `f5networks.f5_modules` |
| `ansible-devspaces` | authoring | The Dev Spaces workspace image (lint, molecule, navigator) | Red Hat `ansible-devspaces` (community image in the lab) | Platform | ansible-dev-tools + every Python client the collections import (`devspaces/requirements/full.txt`); org CA planned, enterprise-only |
| `ansible-devspaces-network` | authoring | Public variant for network-automation development | Community `ansible-devspaces`, always | Platform | ansible-dev-tools + the network clients (`devspaces/requirements/network.txt`); no org content |

## How the layering works

`ee-primary`, `ee-vmware`, and `ee-network` each set `images.base_image.name` to
`ee-base`. The CI overrides it at build time with the **freshly built base pinned
by digest** (`--build-arg EE_BASE_IMAGE=<digest>`), so:

- A CVE patch or new root CA is applied **once** in `ee-base` and flows into
  every derived EE on the next build.
- The derived EEs are thin deltas — only their own collections and Python libs.
- The cost is coupling: a base change rebuilds and retests all children. That is
  the trade you take for patch-once consistency.

## Building locally

```bash
pip install ansible-builder

# base first
ansible-builder build -f base/execution-environment.yml -c base/context \
  -t ghcr.io/khalilgibrotha/ee-base:dev --verbosity 2

# then a derived EE, pointing at the base you just built
ansible-builder build -f network/execution-environment.yml -c network/context \
  --build-arg EE_BASE_IMAGE=ghcr.io/khalilgibrotha/ee-base:dev \
  -t ghcr.io/khalilgibrotha/ee-network:dev --verbosity 2
```

CI (`.github/workflows/build-ee.yml`) does this in dependency order on every push
and publishes to GHCR by digest.

## Collection sourcing: lab vs SECU

Each EE's `requirements.yml` is the **contract** — *what* collections, not *where*
from. The source is environment configuration, exactly as in `ansible-dev-workspace`:

- **Lab** — `ansible-builder` resolves from public Ansible Galaxy by default. No
  setup.
- **SECU** — the build stages an `ansible.cfg` (internal Automation Hub server +
  a token from a CI secret) into the build context and copies it in via
  `additional_build_steps.prepend_galaxy`, so **certified and validated** builds
  are used. The token is never committed.

> Watch the `ee-network` validated content (`network.*`). Certified vendor
> collections (`cisco.*`, `f5networks.*`) are on both public Galaxy and
> Automation Hub under the same name. Some **validated** content is
> Automation-Hub-only — the same sourcing trap `redhat.openshift` set — so pin
> those only after confirming your Hub has synced them.

## Testing content against an EE

- **Inner loop (Dev Spaces):** point a molecule scenario's `platforms[].image` at
  an EE image so the test pod *is* the EE — same collections and Python as prod.
- **Outer loop (CI):** `ansible-navigator run --ee` (or molecule) against the
  built EE on a runner that allows containers — full parity, the EE's own
  ansible-core executes.
- **Platform:** Automation Controller pulls the same EE digest. Nothing to sync.

## Changing the Ansible version

`ee-base` sets `ansible-core` in `base/execution-environment.yml`
(`dependencies.ansible_core.package_pip`). To test a new version, bump that pin
and rebuild — every derived EE inherits it. To test several versions side by
side, add an `ansible-core` build matrix to the CI and run the same content tests
against each; green across the matrix is the signal to move the platform's EE.

## Using the Red Hat supported base (production)

Swap `base/execution-environment.yml`'s `base_image.name` to the mirrored
supported EE base and set the microdnf package manager path:

```yaml
images:
  base_image:
    name: registry.redhat.io/ansible-automation-platform-25/ee-minimal-rhel9:latest
options:
  package_manager_path: /usr/bin/microdnf
```

This needs a `registry.redhat.io` pull secret / AAP entitlement — mirror it into
the internal registry, same pattern as the Dev Spaces tooling image.

## The Dev Spaces authoring image

`devspaces/Containerfile` builds the tooling images a Dev Spaces devfile
consumes. They are **not** EEs and are not built by `ansible-builder` — they
derive (`FROM`) the Ansible `ansible-devspaces` image and layer the Python
clients that collections import. An org CA is planned for the enterprise build
only and is not in either image yet. They build on their own CI track, in parallel with the EEs, because they have a
different lineage.

Two builds come out of the one file: `ansible-devspaces`, the enterprise image
from the mirrored supported base, kept in the internal registry; and
`ansible-devspaces-network`, a public image from the community base with the
network clients only and no org content. Which clients, why they are in the
image rather than installed in the workspace, and how a devfile pins the
result are in [`devspaces/README.md`](devspaces/README.md).

Where no CI runner inside the cluster exists yet, the same images build in
the cluster from a Dev Spaces workspace on this repository, land in the
namespace's ImageStreams by digest, and promote by digest copy: see
[`openshift/README.md`](openshift/README.md). The pipeline form triggers
those same builds from a runner later. Images built in the cluster stay
internal, the network one included.

CI builds both on every pull request and, on merge, publishes the ones
built from the community base, with the pushed digest in the job summary.
The enterprise base is selected by the `DEVSPACES_ENTERPRISE_BASE`
repository variable and the two `DEVSPACES_BASE_REGISTRY_*` secrets. With
them set, CI still builds the enterprise image but does not push it to
GHCR; without them the lab builds and publishes both from the community
base.

## Splitting an EE out later

Each EE is a self-contained directory. When the network team wants to own its
EE, lift `network/` into its own repo (a `git filter-repo` of one folder),
point its `base_image` at the published `ee-base`, and copy the workflow. The
monorepo is the starting home, not a lock-in.
