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
| `ansible-devspaces` | authoring | The Dev Spaces workspace image (lint, molecule, navigator) | Red Hat `ansible-devspaces` | Platform | ansible-dev-tools + org certs/tooling + the Python clients collections import (`devspaces/requirements.txt`) |

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

`devspaces/Containerfile` builds the tooling image the `ansible-dev-workspace`
devfile consumes. It is **not** an EE and is not built by `ansible-builder` — it
derives (`FROM`) Red Hat's supported `ansible-devspaces` image and layers org
concerns (internal CA, extra tooling, pre-installed collections). It builds on
its own CI track, in parallel with the EEs, because it has a different lineage.

```bash
docker build -f devspaces/Containerfile \
  -t ghcr.io/khalilgibrotha/ansible-devspaces:dev devspaces/

# SECU: derive from the mirrored supported image instead of the community one
docker build -f devspaces/Containerfile \
  --build-arg DEVSPACES_BASE=<internal-registry>/ansible-devspaces-rhel9:<tag> \
  -t <internal-registry>/ansible-devspaces:<tag> devspaces/
```

Once published, point the `ansible-dev-workspace` devfile's `image:` at this
build instead of the upstream community image.

## Splitting an EE out later

Each EE is a self-contained directory. When the network team wants to own its
EE, lift `network/` into its own repo (a `git filter-repo` of one folder),
point its `base_image` at the published `ee-base`, and copy the workflow. The
monorepo is the starting home, not a lock-in.
