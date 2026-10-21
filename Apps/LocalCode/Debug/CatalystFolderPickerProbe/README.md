# Catalyst folder picker probe

A standalone, sandboxed UIKit app that compares `UIDocumentPickerViewController`
with the shared `Components.UnifiedDocumentPickerController`, compiled from the production source.
Both receive the same `directoryURL`. The shared picker prefers an `NSOpenPanel`
obtained through `NSClassFromString` on Catalyst, with a UIKit fallback if native
presentation fails. The SDK marks `NSOpenPanel` unavailable to Mac Catalyst, even
though the class exists at runtime.

`UnifiedDocumentPickerController` mirrors UIKit's opening/exporting initializers,
`title`, `directoryURL`, `allowsMultipleSelection`, and delegate callbacks. Its
delegate is a plain Swift protocol. An overload preserves
`viewController.present(picker, animated: true)` and retains the unified controller
through selection or cancellation. File import/export uses UIKit.

Build with the active Xcode toolchain:

```sh
python3 Apps/LocalCode/Debug/CatalystFolderPickerProbe/build.py
open /tmp/CatalystFolderPickerProbe.app
```

The build uses the host architecture, ad hoc signing, App Sandbox, user-selected
read/write access, and app-scoped bookmarks. It has its own bundle identifier and
preferences. It does not change Local Code or Draw Things settings.

The initial path is the current user's
`Library/Containers/com.liuliu.draw-things/Data/Documents/Models`. Edit the field in
the app, or pass `--directory /absolute/path` when building. A previously entered
path takes precedence over the build's default. `--output` changes the app location.
Pass `--dismiss-after 3` to dismiss the shared picker programmatically after three
seconds and check its cancellation callback, as used when stopping `permit`.

## Verification

1. Click **Check path access** before opening a picker. An external directory
   should be inaccessible unless the process already has access.
2. Click **Open shared picker** and check the starting folder. **Open**
   selects the current folder; **Cancel** preserves any existing bookmark.
3. The log reports the selected URL, security-scope result, directory entry count,
   and bookmark creation. It does not read or modify files inside the folder.
4. Quit the app completely and reopen it. Click **Check path access**, then
   **Verify saved bookmark**. The latter resolves the bookmark, activates its
   security scope, lists the directory, and releases that scope.
5. Use **Open UIKit picker** to compare its initial location. Try a different
   requested path, since the native dialog may remember its previous location.

**Forget bookmark** removes the saved bookmark. Restart before testing access
again: a picker grant can remain effective for the lifetime of the process.

## Observed on the development Mac

- The executable is built for `MACCATALYST` and launches with App Sandbox enabled.
- `NSClassFromString("NSOpenPanel")` resolves successfully.
- Direct access to Draw Things' Models directory is denied before selection.
- The dynamic AppKit panel opens directly in that Models directory with the
  **Open** button enabled.
- Native cancellation reaches the plain Swift delegate without opening a fallback.
- Programmatic dismissal closes both the native panel and the UIKit fallback,
  reporting cancellation through the unified delegate.
- Temporary test builds with a missing AppKit class or a deliberately throwing
  AppKit setter both present UIKit's picker. UIKit cancellation also reaches the
  unified delegate.

- In an isolated probe using `/private/tmp/UnifiedDocumentPickerFixture`, direct
  access is denied before selection. Selecting the folder returns a URL for which
  `startAccessingSecurityScopedResource()` succeeds, and the bookmark is saved.
- After quitting and relaunching into a new process, direct access is denied
  again. Resolving the saved bookmark reports `stale: false`; activating its
  security scope succeeds and the directory's single test entry is accessible.
