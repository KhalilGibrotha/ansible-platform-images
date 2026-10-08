# Build the Authoring Images in the Cluster

*Read this when you want an image built where the hub, the mirror, and the
registry are reachable, and no CI runner inside the cluster exists yet. It
assumes a Dev Spaces workspace opened on this repository and the `oc`
token it carries. The pipeline form, where a runner triggers the same
builds, is described in the repository README.*

What you get: the network and enterprise authoring images built by the
cluster from this working tree, tagged by digest in your namespace, which
any workspace in that namespace can pull with no secret, and promoted to a
version by copying a digest. Both stay internal. OpenShift stamps the build
namespace into every image it builds, so even the network image built here
is not the public one; that one comes from CI on a hosted runner.

## What You Need

- A Dev Spaces workspace on this repository. The devfile carries the
  tasks; the scripts run anywhere `oc` is logged in.
- The permissions the check script names. Run it first:

  ```bash
  bash scripts/check-cluster-prereqs.sh
  ```

  Expected: `ok` and `info` lines, no `MISSING`, ending `everything the
  MVP needs is in place`. Each `MISSING` line carries an `ask for:` line,
  and that line is the whole request to make. The items it can name:

  | Item | Who grants it | Why it is needed |
  |---|---|---|
  | `edit` role in your namespace | Usually already yours in a Dev Spaces namespace | `oc apply` (get, create, patch), starting a binary build, following its log, tagging by digest |
  | `system:build-strategy-docker` cluster role | OpenShift platform team | The Docker build strategy is on by default and often removed by hardening; without it a build fails after everything else passed |
  | `builder` service account bound to `system:image-builder` | Created by OpenShift in every namespace; a namespace admin restores the binding | The build pod pushes as this account, not as you |
  | Image registry operator managed | OpenShift platform team | The integrated registry is where the MVP lands images. The check reports it as `info` only: it cannot find the registry before your namespace has an ImageStream |

## Build

Commit first. Everything under `devspaces/` is uploaded, untracked files
included, so the script refuses to build unless git reports nothing there
at all. The tag it writes names a commit, and a tag that names a tree
nobody can check out is the first lie in the chain. A commit is built
once: running the script again on the same commit reports the existing
tag and builds nothing.

```bash
bash scripts/build-in-cluster.sh network
```

The build log streams, then:

```text
built:  ansible-devspaces-network:sha-ab0edbba1f94
base:   ghcr.io/ansible/ansible-devspaces:v26.7.1@sha256:...
digest: sha256:...

  image: image-registry.openshift-image-registry.svc:5000/<ns>/ansible-devspaces-network:sha-ab0edbba1f94@sha256:...
```

The `base:` line is read back from the built image. The script refuses to
tag an image whose base is not the one it asked for.

That last line goes into a content repository's devfile as its `image:`.
Apply it with the editor's **Restart Workspace from Local Devfile**
command; a restart from the dashboard keeps the devfile the workspace was
created with. Then prove the image is the one you built:

```bash
python3 -c "import infoblox_client; print(infoblox_client.__version__)"
```

Expected: the version pinned in `devspaces/requirements/network.txt`.

The enterprise build is the same command with `full`. Until the
organisation's registry mirrors the supported base it builds from the
community base. When it does, set two variables before running it, and
nothing in the repository changes:

- `DEVSPACES_BASE`: the mirrored image, by digest.
- `DEVSPACES_BASE_PULL_SECRET`: a secret in your namespace holding a pull
  credential for that mirror, ideally a robot account. The script sets it
  as the BuildConfig's pull secret. Without it the build pod has only the
  `builder` account's credentials, which reach this cluster's integrated
  registry and nothing else, and the build fails pulling its base.

Build arguments are written onto the BuildConfig, not passed to
`oc start-build`, because a binary build ignores `--build-arg`. Every run
rewrites them, so a base set for one build does not linger into the next.

Where the cluster has no route to `pypi.org`, set `PIP_INDEX_URL` to the
organisation's PyPI proxy for either build. If that proxy presents a
certificate from an internal CA, the build cannot trust it yet: neither
image carries the CA. That is the case for the enterprise-only CA step the
Containerfile describes.

The community base comes from `ghcr.io`. A cluster that reaches registries
only through mirrors needs `ghcr.io/ansible` mirrored, or a
`DEVSPACES_BASE` pointing at a copy in a registry it can reach.

## Promote

A build that has been pulled, used, and found good gets a version. Nothing
is rebuilt; the version tag points at the digest the `sha-` tag does:

```bash
bash scripts/promote-image.sh ansible-devspaces-network sha-ab0edbba1f94 v0.1.0
```

Expected: `promoted: ... -> ansible-devspaces-network:v0.1.0` and the same
digest as the build printed. Run it again with the same version and it
refuses, which is the point: a version is written once, and the next
change is the next version. Consumers pin `vX.Y.Z@sha256:...`; the `build`
tag that moves is never pinned by anyone.

## What Changes When Quay Arrives

The rules stay the same, but the scripts change, because today they talk
to ImageStreams:

- Each BuildConfig's `output.to` becomes a `DockerImage` at the Quay
  repository, with a `pushSecret` naming a robot account's secret.
- The scripts read digests with `oc get istag` and write tags with
  `oc tag`, and both work only on ImageStreams. Against Quay, the digest
  comes from `skopeo inspect` (or `oc image info`) and tags are written by
  `skopeo copy` by digest within the repository.
- The printed pin line names the integrated registry's address; it names
  the Quay repository instead.

What carries over unchanged is the discipline: a commit is built once, a
tag is written from a digest, a version never moves, and only a clean
`sha-` tag can be promoted. The stub tests pin that behaviour, so the
rewrite has a test suite waiting for it. Clair starts scanning every push
without anything here asking for it.

## Troubleshooting

**`build strategy Docker is not allowed`, after the check script passed
everything else.** The cluster-level grant is missing; it is the last
line of the check script's permissions section and the one request to
make.

**The build pod is pending and never starts.** A ResourceQuota or
LimitRange in the namespace will not admit a 1Gi request or 4Gi limit.
`oc describe build <name>-<n>` names which. Lower the values in the
BuildConfig to what the namespace allows, or ask for the quota to be
raised for the build.

**`the build reported success but ... has no image` after a successful
build.** The ImageStream has no tag named `build`; the BuildConfig's
`output.to` was edited away from it. `oc get istag` shows what it wrote
instead.

**The enterprise build fails pulling its base with an authorization
error.** The build pod has no credential for the mirror.
`DEVSPACES_BASE_PULL_SECRET` was unset, or names a secret without access
to that repository.

**The workspace pulls the old image after the devfile change.** A restart
from the dashboard reuses the devfile the workspace was created with, and
an editor reload keeps the pod. Use the editor's **Restart Workspace from
Local Devfile** command.

**`the image was built from ... not ...` after a build.** The base label in
the built image does not match the base the script asked for, so the
image got no `sha-` tag. Check the BuildConfig's build arguments with
`oc get bc/<name> -o yaml`.

## Not Verified Here

The manifests and scripts were written against the OpenShift Builds v1
API and validated for syntax, not run against a cluster: the author had
no cluster to run them on. The first run in your namespace is the test.
If a command's output differs from what this guide shows, the guide is
wrong, and the fix belongs here.

Open questions the first run answers:

- Whether the cluster's builder accepts the base as `name:tag@sha256:...`,
  the form the Containerfile uses.
- Whether the build pod reaches `ghcr.io` directly or through a configured
  mirror.
- Whether `jsonpath` can read the image's labels at
  `.image.dockerImageMetadata.Config.Labels`. If it cannot, the script
  says the base was not verified rather than failing.
- Whether the interactive Promote task in the devfile gets a terminal it
  can prompt in. The script itself takes arguments and needs none.
