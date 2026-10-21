---
name: deploy-static-site-with-wrangler
description: Temporarily publish a directory of built static web artifacts to a public internet URL with Cloudflare Wrangler so other people can open and review it. Use when a user asks to share, publish, host, or deploy generated HTML, CSS, JavaScript, or a static output directory such as dist, build, or out for temporary external access, including a preview link for other people.
---

# Temporarily Share Static Web Artifacts

Publish an existing static build directory to a temporary public URL with
Cloudflare Wrangler. Keep the workflow about sharing the artifact; do not
require the user to understand Cloudflare Workers or underlying runtime details.

## Identify the artifact

Inspect the project and find its actual static output directory. Common names
include `dist`, `build`, and `out`, but prefer the directory configured by the
project.

If only source files exist, run the project's existing production build first.
Do not replace its framework, bundler, or build command. Confirm that the
result contains an entry HTML document and the expected JavaScript, CSS, and
other assets.

For a standalone static page with no build step, create a clean artifact
directory and copy only the files the page needs. For example:

```sh
mkdir -p public
cp index.html public/index.html
```

Before publishing, inspect the artifact for files that should not become
public, including environment files, credentials, private keys, source data,
and unintended source maps. Deploy only the build directory, never the whole
project by convenience. In particular, do not use `.` as the artifact
directory: it can upload `node_modules`, assistant metadata, and unrelated
project files.

## Use the validated package set

The deployment workflow is generic. The package selection below is the part
specific to the bundled Node.js runtime:

| Role | Exact package |
| --- | --- |
| Deployment CLI | `wrangler@4.118.0` |
| Wrangler's expected dependency | `esbuild@0.28.1` |
| Runtime-compatible Wasm provider | `esbuild-wasm@0.28.1`, materialized at `node_modules/esbuild` |

Install the pinned CLI and Wasm provider together. The npm alias places the
provider at the `esbuild` path Wrangler already expects:

```sh
npm install --save-dev \
  wrangler@4.118.0 \
  esbuild@npm:esbuild-wasm@0.28.1
```

Do not use `wrangler@latest` or a one-off command such as
`npm exec --yes wrangler@latest`. Those forms can select an unvalidated graph
and install it in npm's managed `_npx` cache instead of the project's
`node_modules`.

Require the exact Wasm provider above. Do not substitute a native esbuild
binary, enable lifecycle scripts to download executable code, or silently use
a different version. Static artifact deployment does not require a local
workerd runtime. If npm cannot resolve this exact graph, report a package-compatibility
error in the current environment instead of changing the web project.

Keep any resulting `package.json` and lockfile changes visible to the user.

## Invoke Wrangler through its JavaScript entrypoint

Run Wrangler's real CLI module directly:

```sh
node node_modules/wrangler/wrangler-dist/cli.js
```

Do not use `npm exec -- wrangler`, `npx wrangler`, or
`./node_modules/.bin/wrangler` in the current environment. Wrangler's bin wrapper respawns
the runtime with Node flags before the JavaScript entry path, which the bundled
Node.js runtime's virtual-node spawn validation rejects.

For static artifacts, always pass `--no-bundle`. Bundling is unnecessary and
starts esbuild's service by spawning `node` by name, which is unsupported in
this runtime. Keep the pinned Wasm provider installed as part of the validated
Wrangler dependency graph, even though `--no-bundle` prevents the deployment
from invoking it.

## Choose the public deployment

Determine these values explicitly:

- The artifact directory.
- A short Cloudflare-compatible deployment name. Prefer a user-supplied name;
  otherwise derive a candidate from project metadata and state it.
- A compatibility date in `YYYY-MM-DD` form. Use the `datetime` tool when the
  current date is appropriate; do not guess it.

This skill uses Wrangler's unauthenticated `--temporary` deployment. Check for
active Cloudflare credentials without printing their values. Wrangler rejects
temporary deployment when credentials are active; do not unset credentials or
log the user out without direction.

## Validate with a dry run

Replace the example values and run the complete deployment command with
`--dry-run` first:

```sh
node node_modules/wrangler/wrangler-dist/cli.js deploy ./dist \
  --name my-static-site \
  --temporary \
  --compatibility-date 2026-08-26 \
  --no-bundle \
  --dry-run
```

A successful dry run reads the artifact files, prepares the upload, reports
upload sizes and bindings, and exits normally because of `--dry-run`. Confirm
that the reported file count matches the intended artifact; an unexpectedly
large count usually means the wrong directory was selected. Resolve artifact
or package errors before publishing. Do not infer that a live upload succeeded
from dependency installation alone.

## Publish temporarily

Running without `--dry-run` creates a public external resource. Proceed when
the user directly asked to share or deploy it. If the user asked only to
prepare, inspect, or test the deployment, stop after the dry run.

Before the first live command, briefly tell the user that the deployment:

- is publicly reachable by anyone with its URL;
- creates or reuses a temporary Cloudflare preview account;
- proceeds through Cloudflare's noninteractive terms flow;
- expires after about 60 minutes unless claimed; and
- returns a bearer-sensitive claim URL.

Remove only `--dry-run` from the validated command:

```sh
node node_modules/wrangler/wrangler-dist/cli.js deploy ./dist \
  --name my-static-site \
  --temporary \
  --compatibility-date 2026-08-26 \
  --no-bundle
```

Treat the claim URL like a credential. Do not commit it, quote it in later
summaries, or copy it into ordinary project logs.

Report the public site URL, the temporary expiration behavior, the artifact
directory deployed, the Wrangler version, and any project files changed by
building or installing dependencies. Claim success only after Wrangler exits
successfully.

## Handle common failures

- If Wrangler rejects `--temporary` because credentials exist, preserve them
  and ask whether the user wants a different deployment mode.
- If a command fails with `ENOTSUP` and says a direct JavaScript entry path
  must be the first argument, it used Wrangler's bin wrapper. Run the real CLI
  module directly as shown above.
- If Wrangler reports `spawn node ENOENT` or that the esbuild service is no
  longer running, verify that the static deployment command includes
  `--no-bundle`.
- If the dry run reads project files or thousands of unexpected files, stop
  and prepare a clean `public`, `dist`, `build`, or `out` directory containing
  only the intended static artifacts.
- If npm or esbuild selects an unsupported native package or version, return to
  the exact package table above; do not patch the installed package.
- If Wrangler reports a missing entry document or asset, correct the build or
  artifact directory and repeat the dry run.
- Do not fall back to `wrangler dev`, Miniflare, or workerd. They solve local
  development rather than temporary internet sharing.

When Wrangler behavior changes, consult Cloudflare's official
[Wrangler command documentation](https://developers.cloudflare.com/workers/wrangler/commands/workers/)
and
[claim-deployment documentation](https://developers.cloudflare.com/workers/platform/claim-deployments/)
before changing the pinned workflow.
