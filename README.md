# Local Code

Local Code is a private AI agent for Mac, iPad and iPhone. It puts three things in one app: an LLM inference engine for Apple Silicon, a coding harness tuned to each model, and an agent runtime with Python, Node.js, a shell and other familiar tools built in. With these, the agent can work through whole tasks on files you choose, such as analyzing data, charting it, writing documents and slide decks, or building software.

With an on-device quasi-frontier model, such as DeepSeek 4.1 Flash 1017, inference runs on your device and works offline. You can also pick a cloud model from Anthropic, OpenAI, OpenRouter or an OpenAI-compatible server. When you do, your prompts, file contents and tool output go to that provider. Either way, the agent's tools run inside the app's sandbox and can reach only the folders you allow.

Download Local Code from [getlocalcode.app](https://getlocalcode.app).

This repository contains the source code of the app and its command-line tools, along with the libraries and vendored dependencies they are built from.

## An Agent that does Real Work

### Models

Local Code downloads its own quantized checkpoints of each model:

| Model | Quantizations | Input | Download size |
| --- | --- | --- | --- |
| DeepSeek 4.1 Flash 1017 | 2-bit S, 3-bit S | Text and images | TBD |
| DeepSeek 4 Flash 0731 | 2-bit S | Text | TBD |
| Qwen 3.8 27B | 2-bit S, 4-bit S, 8-bit S | Text and images | TBD, TBD, TBD |

The DeepSeek models are mixtures of experts, and they are larger than the memory of most Macs. For example, the DeepSeek 4.1 Flash checkpoint is about 150 GiB. Local Code keeps as many of the most used experts in memory as there is room for, and streams the rest from disk. So these models run on Macs with less memory than the checkpoint, and run faster the more memory there is.

During setup, Local Code suggests a model based on the device's memory:

- under 32 GB: Qwen 3.8 27B (2-bit S)
- 32 GB and up: Qwen 3.8 27B (4-bit S)
- 64 GB and up: DeepSeek 4 Flash 0731
- 96 GB and up: DeepSeek 4.1 Flash 1017

You can switch to any model later.

### Performance on Macs

Speeds are in tokens per second, given as prefill / decode. Each prefill reading is a 4,096-token prompt, and each decode reading is 128 tokens generated after a short prompt.

| Mac | Qwen 3.8 27B (4-bit S) | DeepSeek 4 Flash 0731 | DeepSeek 4.1 Flash 1017 |
| --- | --- | --- | --- |
| TBD, 24 GB | TBD / TBD | TBD / TBD | TBD / TBD |
| TBD, 48 GB | TBD / TBD | TBD / TBD | TBD / TBD |
| TBD, 64 GB | TBD / TBD | TBD / TBD | TBD / TBD |
| TBD, 128 GB | TBD / TBD | TBD / TBD | TBD / TBD |
| TBD, 256 GB | TBD / TBD | TBD / TBD | TBD / TBD |

To measure your own Mac, open Model Speed in the app, or run the same measurements, at context lengths up to the model's limit, with the CLI:

```bash
bazel run -c opt //Apps/LocalCode:LocalCodeCLI -- speedometer \
  --model qwen_3.8_27b_i4x.ckpt --result-json /path/to/speed.json
```

### Benchmarks

| Benchmark | DeepSeek 4.1 Flash 1017 (2-bit S) |
| --- | --- |
| AIME 2026 | TBD |
| MathArena Apex | TBD |
| GPQA Diamond | TBD |

### The In-App Sandbox

Local Code doesn't run the agent's commands as separate programs on your computer. The shell, the language runtimes and the command-line tools are compiled into the app and run in its own process, inside Apple's App Sandbox. On a Mac, the Hardened Runtime also protects the app's code. The agent has no full-disk access, and it can't launch other programs on your computer, so it can't run native programs that aren't built into the app.

Each project is a folder inside a workspace that you choose. The agent starts in the project folder and can read and write anywhere in the workspace, plus the app's temporary folder. Packages and caches that the agent installs for a project stay in that project's folder. Commands that use the network, such as web search, `curl` and `ssh`, connect out when the agent runs them.

The sandbox includes:

- **Shell:** OSH from [Oils](https://oils.pub), with common Unix commands such as `grep`, `sed`, `awk`, `find`, `diff`, `rg`, `jq`, `zip`, `curl`, `git` and `ssh`.
- **Python 3.14:** NumPy, pandas, Matplotlib, Pillow, lxml, openpyxl, python-docx, python-pptx and pypdf, and `pip` for more.
- **Node.js 24:** `npm` and `npx`.
- **Lean 4 and Z3:** to check proofs and solve constraint problems. Lean can also install Mathlib.
- **Documents and media:** LibreOffice, through the `office` command, to convert and render Word, Excel, PowerPoint and PDF files. Also FFmpeg, plus `html2video` and `hyperframes` to make videos from HTML.
- **Web:** web search, and a WebKit browser that the agent can drive to test pages or to use sites that need JavaScript or a sign-in.
- **Images and video:** the Draw Things CLI, to generate images and videos.
- **Personal data:** `calendar` to read and edit events, and `photos` to find, import, edit and organize photos and videos. On a Mac, `notes`, `mail` and `imessage` also read Notes, Mail and Messages, but they can't change or send anything. Each command works only after you grant access.

Built-in skills show the agent how to use these tools for common work:

| Skill | Use |
| --- | --- |
| [`office`](Apps/LocalCode/Resources/Skills/office) | Create, read, edit and check Word, PowerPoint and Excel files and CSV or TSV tables, and export them to PDF or images |
| [`answers-charts`](Apps/LocalCode/Resources/Skills/answers-charts) | Draw data charts with Python and Matplotlib, shown inline in the answer |
| [`hyperframes`](Apps/LocalCode/Resources/Skills/hyperframes) | Make motion graphics and timed HTML compositions, such as animated text, captions and slideshows, and render them to video |
| [`use-draw-things-cli`](Apps/LocalCode/Resources/Skills/use-draw-things-cli) | Generate and edit images, and create videos, with the Draw Things CLI |
| [`use-web-browse-cli`](Apps/LocalCode/Resources/Skills/use-web-browse-cli) | Drive the WebKit browser to test pages, or to use sites that need JavaScript or a sign-in |
| [`deploy-static-site-with-wrangler`](Apps/LocalCode/Resources/Skills/deploy-static-site-with-wrangler) | Publish a folder of static web files to a temporary public URL with Cloudflare Wrangler |
| [`use-mcp-with-mcporter`](Apps/LocalCode/Resources/Skills/use-mcp-with-mcporter) | Connect to Model Context Protocol servers and call their tools through MCPorter |
| [`check_lean-and-lean-tools`](Apps/LocalCode/Resources/Skills/check_lean-and-lean-tools) | Prove non-obvious claims about code, such as ones about recursive functions or data structures, with Lean |
| [`skill-creator`](Apps/LocalCode/Resources/Skills/skill-creator) | Create, import, update and validate skills |
| [`introduce-local-code`](Apps/LocalCode/Resources/Skills/introduce-local-code) | Explain what Local Code is and what the agent can do |

You can add your own skills to a project's `.agents/skills` folder.

## Repository Layout

| Path | Contents |
| --- | --- |
| `Apps/LocalCode` | The app, and `LocalCodeCLI`, which runs the app's agents on macOS ([CLI/README.md](Apps/LocalCode/CLI/README.md)) |
| `Apps/DrawThingsCLI`, `Apps/HTML2VideoCLI`, `Apps/HyperFramesCLI` | Commands that are available in the agent's shell and as standalone macOS executables |
| `Libraries` | Swift libraries for model inference (`SwiftLLM`, `SwiftDiffusion`), the model catalog (`LLMZoo`), the agent's shell (`BashToolContext`), and the rest of the app |
| `Vendors` | Third-party code, plus prebuilt Python, Node.js and LibreOffice frameworks |
| `Scripts`, `Tools` | Setup, formatting, packaging and release scripts |

The neural network runtime, [s4nnc](https://github.com/liuliu/s4nnc), and the other external dependencies are pinned in `WORKSPACE.darwin`.

## Building

Local Code builds on macOS with Xcode and Bazel. The Bazel version is pinned in `.bazelversion`, which [Bazelisk](https://github.com/bazelbuild/bazelisk) reads automatically.

The prebuilt Python, Node.js and LibreOffice frameworks under `Vendors/` are stored with Git LFS. Install Git LFS before you clone, or fetch the files afterward:

```bash
git lfs install
git lfs pull
```

Then set up the checkout once:

```bash
./Scripts/install.sh
```

The script installs the swift-format and buildifier pre-commit hooks, writes a `.bazelrc` that imports `.bazelrc.darwin`, links `WORKSPACE` to `WORKSPACE.darwin`, and installs `coreutils` and `cmake` with Homebrew. If you only need to build, the two Bazel steps are enough:

```bash
ln -s WORKSPACE.darwin WORKSPACE
echo 'try-import %workspace%/.bazelrc.darwin' > .bazelrc
```

Use a link instead of a copy for `WORKSPACE`, so that it stays current when dependency pins in `WORKSPACE.darwin` change.

Machine-specific flags go in `.bazelrc.local`, which `.bazelrc.darwin` imports and Git ignores. Xcode 27 no longer includes `ld-classic`, which FFmpeg and Lean need, so with Xcode 27 point the build at the copy in an Xcode 26 installation:

```
build --action_env="FFMPEG_LD_CLASSIC=/Applications/Xcode 26.6.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/ld-classic"
build --define="LEAN_LD_CLASSIC=/Applications/Xcode 26.6.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/ld-classic"
```

Build the app for iPhone and iPad:

```bash
bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=arm64
```

Add `--config=release` for an optimized build. A device build needs a provisioning profile, and this repository doesn't include one. Put your own development profile at `Apps/LocalCode/ProvisioningFiles/LocalCode_Development.mobileprovision`, and change `bundle_id` in `Apps/LocalCode/BUILD` to that profile's app ID. If your team can't use the Sign in with Apple and associated domains entitlements, also remove them from `Apps/LocalCode/SupportingFiles/LocalCode.entitlements`.

The Mac app is a Mac Catalyst build that needs a patched version of Bazel, which isn't published yet. On a Mac, you can run the same agents with `LocalCodeCLI`, which needs no signing:

```bash
bazel run //Apps/LocalCode:LocalCodeCLI -- models
bazel run //Apps/LocalCode:LocalCodeCLI -- local-agent \
  --model qwen_3.8_27b_i4x.ckpt --project /path/to/project \
  --message 'Review the parser and fix the failing tests.'
```

See [Apps/LocalCode/CLI/README.md](Apps/LocalCode/CLI/README.md) for remote providers, sign-in, saving and resuming runs, and benchmarks.

## Repository Sync

Local Code is developed in the private Draw Things mono-repository. Each commit there that touches a path listed in [SYNCLIST](SYNCLIST) is applied to this repository. Each line of `SYNCLIST` is either a path that has the same name in both repositories, or `private path -> path here` when the names differ. A line that starts with `!` leaves a path out. For example, `!Apps/LocalCode/ProvisioningFiles` keeps the team's provisioning profiles out of this repository.

Files that are not listed in `SYNCLIST`, such as this README, `LICENSE.md`, `Apps/BUILD`, `force_sync.sh` and `.github/`, are maintained in this repository only.

Commits made here can also be applied back to the private repository by [cross-repo-synchronization.yaml](.github/workflows/cross-repo-synchronization.yaml). That direction is turned off for now, so the workflow runs only when it is started by hand.

## License

Local Code is licensed under the GNU General Public License v3.0. See [LICENSE.md](LICENSE.md). Third-party code under `Vendors/` keeps its own license. HyperFrames code in `Apps/HyperFramesCLI` and the built-in `hyperframes` skill is licensed under the Apache License 2.0. See [Apps/HyperFramesCLI/LICENSE.hyperframes](Apps/HyperFramesCLI/LICENSE.hyperframes) and [Apps/LocalCode/Resources/Skills/LICENSE.hyperframes](Apps/LocalCode/Resources/Skills/LICENSE.hyperframes).
