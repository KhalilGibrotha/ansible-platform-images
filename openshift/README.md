# Build the Authoring Images in the Cluster

*Read this when you want an image built where the hub, the mirror, and the
registry are reachable, and no CI runner inside the cluster exists yet. It
assumes a Dev Spaces workspace opened on this repository and the `oc`
token it carries. The pipeline form, where a runner triggers the same
builds, is described in the repository README.*

What you get: the public network authoring image and the enterprise
authoring image built by the cluster from this working tree, tagged by
digest in your namespace, which any workspace in that namespace can pull
with no secret, and promoted to a version by copying a digest.

## What You Need

- A Dev Spaces workspace on this repository. The devfile carries the
  tasks; the scripts run anywhere `oc` is logged in.
- The permissions the check script names. Run it first:

  ```bash
  bash scripts/check-cluster-prereqs.sh
  ```

  Expected: every line `ok`, ending `everything the MVP needs is in place`.
  Each `MISSING` line carries an `ask for:` line, and that line is the
  whole request to make. The items it can name:

  | Item | Who grants it | Why it is needed |
  |---|---|---|
  | `edit` role in your namespace | Usually already yours in a Dev Spaces namespace | BuildConfigs, builds, ImageStreams, tags |
  | `system:image-builder` in your namespace | Namespace admin | Push to the integrated registry; included in `edit` |
  | `system:build-strategy-docker` cluster role | OpenShift platform team | The Docker build strategy is on by default and often removed by hardening; without it a build fails after everything else passed |
  | Image registry operator managed | OpenShift platform team | The integrated registry is where the MVP lands images |

## Build

Commit first. The script refuses an uncommitted `devspaces/` tree because
the tag it writes names a commit, and a tag that names a tree nobody can
check out is the first lie in the chain.

```bash
bash scripts/build-in-cluster.sh network
```

The build log streams, then:

```text
built:  ansible-devspaces-network:sha-ab0edbba1f94
digest: sha256:...

  image: image-registry.openshift-image-registry.svc:5000/<ns>/ansible-devspaces-network:sha-ab0edbba1f94@sha256:...
```

That last line goes into a content repository's devfile as its `image:`.
Restart that workspace, then prove the image is the one you built:

```bash
python3 -c "import infoblox_client; print(infoblox_client.__version__)"
```

Expected: the version pinned in `devspaces/requirements/network.txt`.

The enterprise build is the same command with `full`. Until the
organisation's registry mirrors the supported base it builds from the
community base; when it does, set `DEVSPACES_BASE` to the mirrored image
by digest before running it, and nothing in the repository changes.

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

Each BuildConfig's `output.to` becomes a `DockerImage` at the Quay
repository, with a `pushSecret` naming a robot account's secret. The
`sha-` and version tags become `oc image mirror` or `skopeo copy` by
digest within Quay. The scripts' logic is the same; only the registry
hostname moves, and Clair scanning starts running on every push without
anything here asking for it.

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

**`error: no image` after a successful build.** The ImageStream has no tag
named `build`; the BuildConfig's `output.to` was edited away from it.
`oc get istag` shows what it wrote instead.

**The workspace pulls the old image after the devfile change.** The
DevWorkspace re-reads the devfile only on a restart from the dashboard;
an editor reload keeps the pod.

## Not Verified Here

The manifests and scripts were written against the OpenShift Builds v1
API and validated for syntax, not run against a cluster: the author had
no cluster to run them on. The first run in your namespace is the test.
If a command's output differs from what this guide shows, the guide is
wrong, and the fix belongs here.
