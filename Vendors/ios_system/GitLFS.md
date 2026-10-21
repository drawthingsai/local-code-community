# Git LFS in ios_system

`git lfs` and `git-lfs` use an in-process client backed by libgit2, libcurl and
CommonCrypto. The upstream Git LFS executable is not launched as a subprocess.

The native clean/smudge filter is registered whenever the Git frontend starts.
`git add` stores SHA-256 pointers in Git and content in `.git/lfs/objects`.
Clone and checkout hydrate pointers through the LFS Batch API. Before `git push`
publishes refs, the frontend uploads missing LFS objects reachable from the
source refs, including historical objects, and completes any server verification
action. An upload failure prevents the Git push.

```sh
git lfs install
git lfs track '*.bin' '*.safetensors'
git add .gitattributes model.safetensors
git commit -m 'Add model'
git push origin main
```

`install` confirms the built-in integration; no shell hooks or external filter
processes are necessary. `track` writes patterns to the worktree root's
`.gitattributes`, preserves existing entries, and accepts quoted filenames with
spaces. It does not rewrite existing commits.

Supported explicit commands:

- `git lfs fetch [remote]`: download pointers in the current index into the cache.
- `git lfs checkout`: hydrate indexed pointers from verified cached objects.
- `git lfs pull [remote]`: fetch, then hydrate indexed pointers.
- `git lfs push remote [refs...]`: upload objects reachable from the given source
  refs (HEAD by default), without publishing Git refs.
- `git lfs ls-files`: list indexed pointers.
- `git lfs track [patterns...]`, `git lfs install`, `git lfs version`, `git lfs help`.

Explicit checkout/pull only replace an unchanged indexed pointer. They preserve
modified files, missing files and symlinks. Downloads are streamed to temporary
files, checked for SHA-256 and exact byte size, and installed atomically.
`GIT_LFS_SKIP_SMUDGE=1` or `true` leaves pointers during automatic checkout.

HTTP(S) `basic` transfers are supported. Endpoint discovery uses `lfs.url`,
`remote.<name>.lfsurl`, `.lfsconfig`, then the remote URL with `.git/info/lfs`.
Uploads additionally honor `lfs.pushurl` and `remote.<name>.lfspushurl`.
The existing Git frontend's `user.name` / `user.password` credentials are used
only on the configured remote's origin; an exact URL-scoped
`http.<LFS endpoint>.extraheader` can supply a bearer token. Server-supplied
action headers are honored; local credentials are not copied to another origin.

This implements the ordinary track/add/clone/pull/push workflow, not every
upstream Git LFS command or transport. SSH authentication negotiation, custom
transfers, pointer extensions, file locking, migration, pruning, ref-based fetch,
and Git credential-helper subprocesses are unsupported. SSH Git remotes need an
explicit HTTP(S) LFS endpoint. Clean/smudge conversion and HTTP object transfers stream through disk files.

The implementation follows the upstream [pointer specification](https://github.com/git-lfs/git-lfs/blob/main/docs/spec.md)
and [Batch API](https://github.com/git-lfs/git-lfs/blob/main/docs/api/batch.md).

Validation:

```sh
bazel test //Vendors/ios_system:GitLFSTests --test_output=errors
```

The native fixture uses a local HTTP Batch API and the actual libgit2 filter and
upload code. It covers pointer staging, quoted patterns, duplicate content,
upload/verify, historical objects, automatic clone/checkout, skip-smudge, clean
status, explicit download commands, modified-file preservation, corrupted object
rejection, credentials, unsupported pointers, and cancellation. The surrounding
shell and app use the same `git_lfs` library through `cmd_git`.
