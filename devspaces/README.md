# Dev Spaces Authoring Images

The images an OpenShift Dev Spaces devfile consumes for Ansible work. One
Containerfile builds two of them.

| Image | Base | Installs | Distribution | For |
|---|---|---|---|---|
| `ansible-devspaces` | The supported Red Hat image, mirrored into the organisation's registry (community image in the lab) | `requirements/full.txt` | Private, internal registry | Every authoring workspace in the organisation |
| `ansible-devspaces-network` | The community image on `ghcr.io/ansible`, always | `requirements/network.txt` | Public | Network-automation development, including outside the organisation |

Both are thin layers over an upstream image that already carries
ansible-core, ansible-lint, ansible-navigator, molecule, ansible-builder,
ansible-creator, and the `oc` and `kubectl` command-line tools. The layer adds the Python
client libraries that collections import at module runtime. Nothing else.

An organisation root CA belongs in the enterprise image only, and neither
image carries one yet. The Containerfile builds both images, so the CA
needs a step gated to the enterprise build before it is added; until then
the placeholder in the Containerfile stays commented out.

The public image is the network image CI builds on a hosted runner, only
ever from the community base. The supported image is entitled content, so
an image derived from it stays inside the organisation's registry, and CI
does not push it. Images built inside the cluster stay internal too, even
the network one: OpenShift stamps the build namespace into every image it
builds, and a pip proxy set for the build is recorded in its history.

## Why the Clients Are in the Image

A Dev Spaces workspace is immutable by design: the arbitrary UID it runs as
has no `pip`, so nobody installs anything at runtime and every workspace
started from the same digest behaves the same. That rules out the obvious
fix for a collection whose modules import a client library. In an execution
environment `ansible-builder` installs that library from the collection's
own `requirements.txt`; the authoring image has no builder step, so the same
pins are layered here at build time, into the system interpreter the base
image installed the Ansible tools with.

Every pin in `requirements/` records the collection and version it was
copied from. Choose nothing here; copy from the collection.

## Consuming an Image

In the devfile, pin by tag and digest. The tag is for humans, the digest is
what the cluster resolves:

```yaml
components:
  - name: tooling-container
    container:
      image: <registry>/<namespace>/ansible-devspaces-network:<tag>@sha256:<digest>
```

A private image needs a pull secret in the workspace namespace carrying
two labels, `controller.devfile.io/devworkspace_pullsecret: 'true'` and
`controller.devfile.io/watch-secret: 'true'`, so Dev Spaces attaches it. A
public image needs nothing, and neither does an image in the workspace's
own namespace in the integrated registry.

Apply the devfile change with the editor's **Restart Workspace from Local
Devfile** command. A restart from the dashboard reuses the devfile the
workspace was created with and keeps the old image. Then verify:

```bash
python3 -c "import infoblox_client; print(infoblox_client.__version__)"
```

Expected: the version pinned in `requirements/network.txt`.

## Adding a Client

1. Install the collection at the version the hub serves and read its own
   pin:

   ```bash
   cat collections/ansible_collections/<namespace>/<collection>/requirements.txt
   ```

2. Add the line to the domain file under `requirements/`, with a comment
   naming the collection and version it came from. A new domain gets a new
   file and one `-r` line in `full.txt`.
3. Open a pull request. CI builds both images on every pull request. On a
   push to `main` it publishes the ones the `PUBLISH_IMAGES` repository
   variable names, community-base builds only, with the pushed digests in
   the job summary.

## Building Locally

```bash
# The public network image
podman build -f devspaces/Containerfile --build-arg REQUIREMENTS=network \
  -t ansible-devspaces-network:dev devspaces/

# The enterprise image, from the mirrored supported base
podman build -f devspaces/Containerfile \
  --build-arg DEVSPACES_BASE=<internal-registry>/ansible-automation-platform-27/ansible-devspaces-rhel9:<tag>@sha256:<digest> \
  -t <internal-registry>/ansible-devspaces:<tag> devspaces/
```

Pulling the supported base needs a `registry.redhat.io` login, or a
mirrored copy in the internal registry.

## What the Layer Keeps From the Upstream Image

The upstream image is built to Red Hat's rules for Dev Spaces workspace
images, and the layer does nothing to break them:

- It derives from the supported image rather than rebuilding it, so editor
  injection, the entrypoint, and the tool versions come from upstream.
- It runs as an arbitrary UID in group 0. Build steps run as root and write
  only to system paths that are world-readable; nothing the workspace
  writes at runtime is touched.
- It ends on the unprivileged `USER` the upstream image sets.
- It carries no credentials, tokens, or organisation identifiers. A root
  CA, when an enterprise-only step adds one, goes through
  `update-ca-trust`, not into any tool's configuration.
- It pins its base by digest, and a devfile pins it by digest the same way.
