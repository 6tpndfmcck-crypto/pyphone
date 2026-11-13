#!/usr/bin/env python3
"""Cross-compile Pygame for BeeWare CPython 3.15 and PyPhone's SDL2.

Run on macOS after staging Python.xcframework and SDL2.xcframework. No host
Pygame wheel, host Python headers, or implicit desktop library lookup is used.
"""
import argparse
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
VERSION = "2.6.1"
# Pin commits as well as release names so a moved tag cannot change a build.
SOURCES = {
    "pygame": ("pygame/pygame", "b92c0da9d1b5eba6c813138790fc1ab6cea0252c"),
    "image": ("libsdl-org/SDL_image", "c1bf2245b0ba63a25afe2f8574d305feca25af77"),
    "ttf": ("libsdl-org/SDL_ttf", "2a891473eaf05ba1707a4b7913e6c4db7de7458a"),
    "mixer": ("libsdl-org/SDL_mixer", "171eb2d420d5643e4ee11514a06e04a41a463bbd"),
}


def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def framework_slice(path, simulator, archs):
    with (path / "Info.plist").open("rb") as stream:
        libraries = plistlib.load(stream)["AvailableLibraries"]
    for library in libraries:
        if (library["SupportedPlatform"] == "ios"
                and (library.get("SupportedPlatformVariant") == "simulator") == simulator
                and set(archs) <= set(library["SupportedArchitectures"])):
            return path / library["LibraryIdentifier"] / library["LibraryPath"]
    raise RuntimeError(f"No matching iOS slice in {path} for {archs}, simulator={simulator}")


def module_sources(source):
    """Use upstream's source lists; omit desktop-only/optional external APIs."""
    selected = {"font", "imageext", "mixer", "mixer_music", "gfxdraw"}
    setup = (source / "buildconfig/Setup.SDL2.in").read_text()
    required = False
    modules = {}
    for line in setup.splitlines():
        if line.startswith("#these modules are required"):
            required = True
        fields = line.split()
        if not fields or fields[0].startswith("#") or "=" in fields:
            continue
        name = fields[0]
        if required or name in selected:
            files = [part for part in fields[1:] if part.endswith(".c")]
            if "$(GFX)" in fields:
                files.append("src_c/SDL_gfx/SDL_gfxPrimitives.c")
            modules[name] = files
    if not {"base", "surface", "display", "event", "font", "imageext", "mixer"} <= modules.keys():
        raise RuntimeError("Unexpected upstream Pygame Setup format")
    return modules


def prepare_source(source):
    # Use SDL_image's PNG writer (ImageIO on iOS), removing the old copied
    # libpng writer. Keep the altered source in the build directory for review.
    path = source / "src_c/imageext.c"
    text = path.read_text()
    if "PyPhone: use SDL_image" not in text:
        text = text.replace("#include <png.h>", "/* PyPhone: use SDL_image's native PNG writer. */\n#define PNG_H")
        text, count = re.subn(
            r"#ifdef PNG_H\n.*?#endif /\* end if PNG_H \*/",
            "#define pg_SavePNG_RW IMG_SavePNG_RW\n#define pg_SavePNG IMG_SavePNG", text, count=1, flags=re.S)
        if count != 1:
            raise RuntimeError("Upstream PNG writer changed")
        path.write_text(text)
    # Python 3.15 removed the borrowed-reference PyWeakref_GetObject API.
    # Hold each referent alive until its last use, including unlock callbacks.
    replacements = {
        "surface.c": [
            ("tmp = PyWeakref_GetObject(PyList_GetItem(surf->locklist, i));\n        Py_INCREF(tmp);",
             "int alive = PyWeakref_GetRef(PyList_GetItem(surf->locklist, i), &tmp);\n"
             "        if (alive < 0) { Py_DECREF(tuple); return NULL; }\n"
             "        if (!alive) tmp = Py_NewRef(Py_None);"),
            ("consumer = PyWeakref_GetObject(consumer_ref);",
             "int alive = PyWeakref_GetRef(consumer_ref, &consumer);\n"
             "    if (alive < 0) PyErr_Clear();"),
            ("    Py_DECREF(consumer_ref);\n    PyMem_Free(internal);",
             "    Py_XDECREF(consumer);\n    Py_DECREF(consumer_ref);\n    PyMem_Free(internal);"),
        ],
        "surflock.c": [
            ("ref = PyWeakref_GetObject(item);\n            if (ref == lockobj)",
             "int alive = PyWeakref_GetRef(item, &ref);\n"
             "            if (alive < 0) return 0;\n"
             "            int matches = (ref == lockobj);\n"
             "            Py_XDECREF(ref);\n            if (matches)"),
            ("ref = PyWeakref_GetObject(item);\n            if (ref == Py_None)",
             "int alive = PyWeakref_GetRef(item, &ref);\n"
             "            if (alive < 0) return 0;\n"
             "            Py_XDECREF(ref);\n            if (!alive)"),
        ],
    }
    for filename, changes in replacements.items():
        path = source / "src_c" / filename
        text = path.read_text()
        if "/* PyPhone: Python 3.15 weakrefs */" in text:
            continue
        for old, new in changes:
            if text.count(old) != 1:
                raise RuntimeError(f"Upstream weakref code changed in {filename}")
            text = text.replace(old, new)
        path.write_text("/* PyPhone: Python 3.15 weakrefs */\n" + text)
    version = (source / "buildconfig/version.py.in").read_text()
    (source / "src_py/version.py").write_text(version + (
        f'\nver = "{VERSION}"\nvernum = PygameVersion(2, 6, 1)\nrev = "pyphone-ios"\n'
        '__all__ = ["SDL", "ver", "vernum", "rev"]\n'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", choices=("iphoneos", "iphonesimulator"), default="iphoneos")
    parser.add_argument("--archs", default="arm64", help="Comma-separated architectures for this SDK")
    parser.add_argument("--target", type=Path, default=ROOT / "app_packages")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("native iOS builds require macOS with Xcode and CMake")
    archs = args.archs.split(",")
    if any(arch not in {"arm64", "x86_64"} for arch in archs) or (args.sdk == "iphoneos" and archs != ["arm64"]):
        parser.error("device requires arm64; simulator supports arm64 and/or x86_64")
    target = args.target.resolve()
    simulator = args.sdk == "iphonesimulator"
    build = ROOT / ".build/pygame"
    checkout = build / "source"
    for name, (repo, commit) in SOURCES.items():
        dest = checkout / name
        if not (dest / ".git").exists():
            run("git", "init", dest)
            run("git", "-C", dest, "remote", "add", "origin", f"https://github.com/{repo}.git")
            run("git", "-C", dest, "fetch", "--depth", "1", "origin", commit)
            run("git", "-C", dest, "checkout", "--detach", "FETCH_HEAD")
        actual = subprocess.check_output(["git", "-C", str(dest), "rev-parse", "HEAD"], text=True).strip()
        if actual != commit:
            raise RuntimeError(f"Unexpected checkout at {dest}: {actual}")
    run("git", "-C", checkout / "ttf", "submodule", "update", "--init", "--depth", "1", "external/freetype")
    python = framework_slice(ROOT / "Python.xcframework", simulator, archs)
    sdl = framework_slice(ROOT / "SDL2.xcframework", simulator, archs)
    sdk = subprocess.check_output(["xcrun", "--sdk", args.sdk, "--show-sdk-path"], text=True).strip()
    native = build / args.sdk
    run("cmake", "-S", ROOT / "scripts/pygame", "-B", native,
        "-DCMAKE_SYSTEM_NAME=iOS", f"-DCMAKE_OSX_SYSROOT={sdk}",
        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
        "-DCMAKE_OSX_DEPLOYMENT_TARGET=16.0", f"-DCMAKE_OSX_ARCHITECTURES={';'.join(archs)}",
        "-DCMAKE_BUILD_TYPE=Release", f"-DSDL_FRAMEWORK={sdl}", f"-DADDON_SOURCE={checkout}")
    run("cmake", "--build", native, "--config", "Release", "--parallel", str(os.cpu_count() or 2))
    dependency = next(native.rglob("PygameDependencies.framework"))
    destination = ROOT / "PygameDependencies.xcframework"
    if destination.exists():
        shutil.rmtree(destination)
    run("xcodebuild", "-create-xcframework", "-framework", dependency, "-output", destination)
    source = checkout / "pygame"
    prepare_source(source)
    package = target / "pygame"
    if package.exists():
        shutil.rmtree(package)
    shutil.copytree(source / "src_py", package, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    for name, files in module_sources(source).items():
        binaries = []
        for arch in archs:
            output = native / f"{name}-{arch}.so"
            triple = f"{arch}-apple-ios16.0" + ("-simulator" if simulator else "")
            run("xcrun", "--sdk", args.sdk, "clang", "-target", triple, "-isysroot", sdk,
                "-dynamiclib", "-O2", "-fPIC", "-DSDL_MAIN_HANDLED=1", "-DSDL2=1",
                "-I", python / "Headers", "-I", sdl / "Headers", "-I", source / "src_c",
                "-I", checkout / "image/include", "-I", checkout / "ttf", "-I", checkout / "mixer/include",
                "-F", python.parent, "-framework", "Python", "-F", sdl.parent, "-framework", "SDL2",
                "-F", dependency.parent, "-framework", "PygameDependencies",
                "-Wl,-rpath,@executable_path/Frameworks",
                "-Wl,-install_name,@rpath/pygame." + name + ".framework/pygame." + name,
                *[source / file for file in files], "-o", output)
            binaries.append(output)
        run("xcrun", "lipo", "-create", *binaries, "-output", package / f"{name}.so")
    metadata = target / f"pygame-{VERSION}.dist-info"
    metadata.mkdir(parents=True, exist_ok=True)
    (metadata / "METADATA").write_text(f"Metadata-Version: 2.1\nName: pygame\nVersion: {VERSION}\n")
    # Keep upstream license notices and source provenance with the distribution.
    shutil.copy2(source / "docs/LGPL.txt", metadata / "LICENSE")
    shutil.copytree(source / "docs/licenses", metadata / "licenses", dirs_exist_ok=True)
    for addon in ("image", "ttf", "mixer"):
        shutil.copy2(checkout / addon / "LICENSE.txt", metadata / "licenses" / f"SDL_{addon}.txt")
    (metadata / "pyphone-sources.txt").write_text(
        "\n".join(f"https://github.com/{repo}/tree/{commit}" for repo, commit in SOURCES.values()) + "\n")
    print(f"Built native Pygame {VERSION} for {args.sdk} ({', '.join(archs)}) into {target}")


if __name__ == "__main__":
    main()
