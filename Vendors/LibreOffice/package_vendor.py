#!/usr/bin/env python3
"""Publish completed private Office archives as a static XCFramework and resources."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def remove(root, paths):
    for name in paths:
        path = root / name
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink(missing_ok=True)


def main():
    vendor = Path(__file__).resolve().parent
    (vendor / ".build").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="vendor-package-", dir=vendor / ".build") as temporary:
        stage = Path(temporary)
        command = ["xcodebuild", "-create-xcframework"]
        for platform, resources in (("ios-arm64", "Resources"), ("macos-arm64", "ResourcesMacOS")):
            source = vendor / "Artifacts" / platform
            receipt = json.loads((source / "receipt.json").read_text())
            library = source / "libOffice.a"
            with library.open("rb") as stream:
                assert hashlib.file_digest(stream, "sha256").hexdigest() == receipt["archiveSHA256"]
            assert receipt["backend"] == "svp" and receipt["exports"] == ["_OfficeCommandRun"]
            # Packaging-only changes must not disguise a stale compiled wrapper.
            for name in ("OfficeCommand.cpp", "OfficeCommand.h", "document-operations.hpp", "document-validation.hpp", "font-metadata.hpp", "font-operations.hpp", "render-operations.hpp"):
                assert hashlib.sha256((vendor / name).read_bytes()).hexdigest() == receipt["sourceSHA256"][name], name
            for patch in (vendor / "Patches").glob("*.patch"):
                assert hashlib.sha256(patch.read_bytes()).hexdigest() == receipt["patchSHA256"][patch.name], patch
            command += ["-library", str(library), "-headers", str(source / "include")]
            runtime = stage / resources / "office"
            if platform == "ios-arm64":
                shutil.copytree(source / "program/office", runtime)
                data = runtime / "share"
                remove(runtime, ("CREDITS.fodt", "LICENSE", "LICENSE.html", "NOTICE", "readmes",
                                 "program/intro.png", "program/intro-highres.png", "program/scriptforge.pyi",
                                 "program/shell", "program/wizards", "presets/database", "presets/gallery", "presets/basic", "presets/autotext"))
            else:
                # Keep the relative resource layout used by the macOS engine,
                # but no nested app identity or executable bundle structure.
                contents = source / "program/LibreOfficeDev.app/Contents"
                for directory in ("Frameworks", "Resources"):
                    shutil.copytree(contents / directory, runtime / directory)
                data = runtime / "Resources"
                remove(data, ("LICENSE", "NOTICE", "MainMenu.nib", "MenuTranslations.plist",
                              "senddoc", "unoinfo", "readmes", "skia", "presets/database", "presets/gallery", "presets/basic", "presets/autotext"))
            # These are interactive application assets, not conversion data.
            # Keep registry, filters, fonts, language tables and Calc data.
            remove(data, ("config/wizard", "gallery", "basic", "Scripts", "tipoftheday", "glade",
                          "toolbarmode", "wizards", "xdg", "autocorr", "autotext", "template", "wordbook"))
            # Pinned dsh engine/ui-resource-policy.mjs: SVP still creates a few
            # document-view controls. Removing their layouts breaks loading.
            required_ui = {
                "modules/scalc/ui/inputbar.ui", "modules/scalc/ui/posbox.ui",
                "modules/simpress/ui/tabviewbar.ui", "modules/swriter/ui/annotation.ui",
                "svt/ui/scrollbars.ui", "svt/ui/tabbuttons.ui", "svt/ui/tabbuttonsmirrored.ui",
            }
            configuration = data / "config/soffice.cfg"
            for path in configuration.rglob("*.ui"):
                if path.relative_to(configuration).as_posix() not in required_ui:
                    path.unlink()
            assert {p.relative_to(configuration).as_posix() for p in configuration.rglob("*.ui")} == required_ui
            receipt["packagedResourceBytes"] = sum(p.stat().st_size for p in runtime.rglob("*") if p.is_file())
            (stage / "Receipts").mkdir(exist_ok=True)
            (stage / "Receipts" / (platform + ".json")).write_text(json.dumps(receipt, indent=2) + "\n")
            notices = stage / "Notices/LibreOffice"
            notices.mkdir(parents=True, exist_ok=True)
            for path in sorted((source / "licenses").iterdir()):
                if path.is_file():
                    shutil.copy2(path, notices / (platform + "-" + path.name))
        shutil.copy2(vendor / "LICENSE.dsh", notices / "dsh-libreoffice-kit-MPL-2.0.txt")
        (notices / "SourceNotice.txt").write_text(
            "Office uses LibreOffice 26.8.0.3 and dsh-libreoffice-kit.\n"
            "LibreOffice source: https://github.com/LibreOffice/core/tree/bce0998afefdbc355585ca324285661a2170ba77\n"
            "dsh source: https://github.com/deepseek-ai/dsh-libreoffice-kit/tree/b19bb73c74ed893b8a5d1716d32df32a113ed31b\n"
            "Modified sources, patches and build instructions: Vendors/LibreOffice in\n"
            "https://github.com/drawthingsai/draw-things (the source revision of this app).\n"
            "LibreOffice and the adapted worker are covered by MPL-2.0; bundled\n"
            "dependencies retain the accompanying third-party notices.\n")
        framework = stage / "Office.xcframework"
        subprocess.run(command + ["-output", str(framework)], check=True)
        destinations = [(framework, vendor / "Frameworks/Office.xcframework")]
        destinations += [(stage / name, vendor / name) for name in ("Resources", "ResourcesMacOS", "Receipts", "Notices")]
        for source, destination in destinations:
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.exists():
                shutil.rmtree(destination)
            shutil.move(source, destination)
    # Diagnostics exercise exactly the runtime files published for the app.
    diagnostic = vendor / "Artifacts/macos-arm64/office"
    if diagnostic.exists():
        shutil.rmtree(diagnostic)
    shutil.copytree(vendor / "ResourcesMacOS/office", diagnostic)
    metadata = {
        "LIBREOFFICE_VERSION": "26.8.0.3",
        "LIBREOFFICE_SOURCE_REPO": "https://github.com/LibreOffice/core.git",
        "LIBREOFFICE_SOURCE_COMMIT": "bce0998afefdbc355585ca324285661a2170ba77",
        "DSH_KIT_SOURCE_REPO": "https://github.com/deepseek-ai/dsh-libreoffice-kit.git",
        "DSH_KIT_SOURCE_COMMIT": "b19bb73c74ed893b8a5d1716d32df32a113ed31b",
        "LIBREOFFICE_LINKAGE": "static",
        "LIBREOFFICE_BACKEND": "svp",
        "LIBREOFFICE_SLICES": "ios-arm64 macos-arm64",
        "LIBREOFFICE_NATIVE_DEPENDENCY_VISIBILITY": "private-relocatable-object",
        "LIBREOFFICE_EXPORTED_C_API": "OfficeCommandRun",
        "LIBREOFFICE_COMPACT_UNWIND": "preserved",
        "IOS_MINIMUM_OS_VERSION": "15.4",
        "MACOS_MINIMUM_OS_VERSION": "13.5",
        "PACKAGING_XCODE_VERSION": subprocess.check_output(["xcodebuild", "-version"], text=True).strip().replace("\n", " "),
    }
    (vendor / "LIBREOFFICE_BUILD_INFO").write_text("".join(f"{key}={value}\n" for key, value in metadata.items()))
    subprocess.run(["python3", str(vendor / "verify_libreoffice.py"), "--record-checksums"], check=True)


if __name__ == "__main__":
    main()
