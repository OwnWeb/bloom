#!/usr/bin/env python3
"""Bundle bloom-server for a Cloud workspace's machine: the executables, the Swift runtime
libraries they need, Caddy, the bootstrap script and every licence notice, in one archive.

    python3 Tools/package-linux-server.py <bin directory> <output directory> [--version 1.29.0]

Writes bloom-server-linux-x86_64-<version>.tar.gz and a .sha256 beside it, which is what
runbloom.app is told to install and what Tools/bootstrap-machine.sh checks before unpacking.

Built on Ubuntu 24.04, whose glibc is the package's minimum; the machines run Ubuntu 26.04, whose
glibc is newer, and a Swift runtime linked against the older one runs there unchanged. The host's
glibc and loader are never bundled, because mixing a bundled glibc with the host's loader is
unsupported. Ported from #163, which proved the relocation on both releases.
"""

import argparse
import hashlib
import io
import json
import os
import pathlib
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

HOST_LIBRARIES = {
    "libc.so.6", "libm.so.6", "libpthread.so.0", "libdl.so.2", "librt.so.1",
    "libresolv.so.2", "libutil.so.1", "libanl.so.1",
}

# Caddy, pinned by the SHA-512 its own release publishes, so the package carries exactly the
# binary that was reviewed. Update both together, and read Caddy's release notes for anything the
# Caddyfile in Sources/BloomServer/Setup relies on.
CADDY_VERSION = "2.11.4"
CADDY_SHA512 = {
    "x86_64": "8220d1f013b6f27510247b2360c9e0ca9f018feebd82515f07635318b34ff9777ccc8fd0b6e6f2486ce3a33fe389fbb7db12d05baa474f4587509fb4f5ebf1c9",
    "aarch64": "d5a7c423853c24a799765e0e8210d5c7c22a8f56ed37a3cae2fb9f58be138853c02b4efd6b59d576e6d8c7c0d30b9c1592deeaa6a536ff69bcca23b8c1ea709c",
}
CADDY_ARCHITECTURE = {"x86_64": "amd64", "aarch64": "arm64"}

EXECUTABLES = ("bloom-server", "bloom-bridge")


def run(*arguments):
    return subprocess.check_output(arguments, text=True).strip()


def linked_libraries(binary):
    result = {}
    for line in run("ldd", str(binary)).splitlines():
        if "not found" in line:
            raise RuntimeError(f"Unresolved library: {line.strip()}")
        match = re.match(r"\s*(\S+) => (/\S+) \(", line)
        if match and match[1] not in HOST_LIBRARIES:
            result[match[1]] = pathlib.Path(match[2]).resolve()
    if not result:
        raise RuntimeError(f"Expected a dynamically linked Swift executable: {binary}")
    return result


def copy_notice(source, destination):
    if not source.is_file() or not source.stat().st_size:
        raise RuntimeError(f"Missing licence notice: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def fetch_caddy(machine, destination, notices):
    """Downloads Caddy's release archive, checks it, and takes the binary and its licence."""
    name = f"caddy_{CADDY_VERSION}_linux_{CADDY_ARCHITECTURE[machine]}.tar.gz"
    url = f"https://github.com/caddyserver/caddy/releases/download/v{CADDY_VERSION}/{name}"
    cached = os.environ.get("BLOOM_CADDY_ARCHIVE")
    data = pathlib.Path(cached).read_bytes() if cached else urllib.request.urlopen(url, timeout=120).read()
    digest = hashlib.sha512(data).hexdigest()
    if digest != CADDY_SHA512[machine]:
        raise RuntimeError(f"{name} has SHA-512 {digest}, not the pinned one")
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        binary = archive.extractfile("caddy")
        licence = archive.extractfile("LICENSE")
        if binary is None or licence is None:
            raise RuntimeError(f"{name} has no caddy binary or LICENSE")
        destination.write_bytes(binary.read())
        destination.chmod(0o755)
        (notices / "Caddy.txt").write_bytes(licence.read())


def package(bin_directory, output_directory, version):
    if sys.platform != "linux":
        raise RuntimeError("Package inside the Ubuntu Swift build environment")
    release = dict(line.split("=", 1) for line in pathlib.Path("/etc/os-release").read_text().splitlines() if "=" in line)
    machine = platform.machine()
    if release.get("ID", "").strip('"') != "ubuntu" or release.get("VERSION_ID", "").strip('"') != "24.04":
        raise RuntimeError("bloom-server must be packaged on Ubuntu 24.04")
    if machine not in CADDY_SHA512:
        raise RuntimeError(f"No pinned Caddy for {machine}")
    swift_version = run("swift", "--version")
    if "Swift version 6.3.3 " not in swift_version:
        raise RuntimeError("Use Swift 6.3.3; update the runtime notices before changing toolchains")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?", version):
        raise RuntimeError("The version must be an exact semantic version, without a leading v")

    root = pathlib.Path(__file__).resolve().parent.parent
    executables = [bin_directory / name for name in EXECUTABLES]
    if not all(path.is_file() for path in executables):
        raise RuntimeError("Build bloom-server and bloom-bridge before packaging")
    libraries = {}
    for executable in executables:
        libraries.update(linked_libraries(executable))
    target = json.loads(run("swift", "-print-target-info"))
    runtime_paths = [pathlib.Path(path).resolve() for path in target["paths"]["runtimeLibraryPaths"]]
    bundle_name = "bloom-server-linux-" + machine
    output_directory.mkdir(parents=True, exist_ok=True)
    archive_path = output_directory / f"{bundle_name}-{version}.tar.gz"

    with tempfile.TemporaryDirectory(prefix="bloom-linux-package-") as directory:
        bundle = pathlib.Path(directory) / bundle_name
        (bundle / "bin").mkdir(parents=True)
        (bundle / "lib").mkdir()
        notices = bundle / "licences"
        notices.mkdir()
        copy_notice(root / "LICENSE.md", notices / "Bloom.txt")
        swift_root = pathlib.Path(shutil.which("swift")).resolve().parent.parent
        copy_notice(swift_root / "share/swift/LICENSE.txt", notices / "Swift.txt")
        copy_notice(root / "Tools/server-licences/ICU.txt", notices / "ICU.txt")
        # Every SwiftPM dependency, whatever it is called: the server links NIO, Hummingbird,
        # AsyncHTTPClient and their own dependencies, and a list kept by hand here would be the
        # first thing to go stale when one of them adds another.
        checkouts = root / ".build/checkouts"
        for checkout in sorted(path for path in checkouts.iterdir() if path.is_dir()):
            found = False
            for notice in checkout.rglob("*"):
                relative = notice.relative_to(checkout)
                if ".build" in relative.parts or "Tests" in relative.parts:
                    continue
                if notice.is_file() and notice.name.upper().startswith(("LICENSE", "NOTICE", "COPYING")):
                    copy_notice(notice, notices / checkout.name / relative)
                    found = True
            if not found:
                raise RuntimeError(f"No licence notice in the {checkout.name} checkout")

        manifest = {
            "protocol": "bloom-workspace", "protocolVersion": 1, "version": version, "architecture": machine,
            "glibc": run("getconf", "GNU_LIBC_VERSION"), "swift": swift_version, "caddy": CADDY_VERSION, "libraries": {},
        }
        for name, source in sorted(libraries.items()):
            destination = bundle / "lib" / name
            shutil.copy2(source, destination)
            # RUNPATH is local to each ELF object, so setting it on the executable alone does not
            # cover Foundation's own dependencies. LD_LIBRARY_PATH is not the answer either: it
            # would change library resolution in every agent process the server launches.
            run("patchelf", "--set-rpath", "$ORIGIN", str(destination))
            manifest["libraries"][name] = hashlib.sha256(destination.read_bytes()).hexdigest()
            if not any(source.is_relative_to(path) for path in runtime_paths):
                owner = run("dpkg-query", "-S", str(source)).splitlines()[0].split(": ", 1)[0].split(":")[0]
                copy_notice(pathlib.Path("/usr/share/doc") / owner / "copyright", notices / (owner + ".txt"))

        for source in executables:
            executable = bundle / "bin" / source.name
            shutil.copy2(source, executable)
            run("patchelf", "--set-rpath", "$ORIGIN/../lib", str(executable))
        fetch_caddy(machine, bundle / "bin" / "caddy", notices)
        shutil.copy2(root / "Tools/bootstrap-machine.sh", bundle / "bin" / "bootstrap-machine.sh")
        (bundle / "bin" / "bootstrap-machine.sh").chmod(0o755)
        (bundle / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        (bundle / "README.txt").write_text(
            "bloom-server\n\n"
            "The server a Bloom Cloud workspace's machine runs. runbloom.app installs it with\n"
            "bin/bootstrap-machine.sh; nothing here is meant to be run by hand.\n"
            "Keep bin/ and lib/ together. No Swift installation is needed.\n"
            "Built on Ubuntu 24.04. Runs on Ubuntu 24.04 and 26.04.\n"
            "See https://github.com/spatie/bloom/blob/main/docs/REMOTE-WORKSPACES.md\n"
        )
        # Fail before producing an archive if relocation left a dependency outside the package.
        for source in executables:
            relocated = linked_libraries(bundle / "bin" / source.name)
            if any(not path.is_relative_to(bundle) for path in relocated.values()):
                raise RuntimeError("A bundled dependency still resolves outside the package")
        if run(str(bundle / "bin/bloom-server"), "version") == "":
            raise RuntimeError("The packaged bloom-server did not say its version")
        with tarfile.open(archive_path, "w:gz") as archive:
            # bin/ at the root of the archive rather than inside a named directory, because
            # runbloom.app's bootstrap unpacks it straight into /opt/bloom/<version>.
            for entry in sorted(bundle.iterdir()):
                archive.add(entry, arcname=entry.name)

    digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
    (output_directory / (archive_path.name + ".sha256")).write_text(f"{digest}  {archive_path.name}\n")
    print(f"Packaged {archive_path} ({archive_path.stat().st_size // 1_048_576} MiB), sha256 {digest}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("bin_directory", type=pathlib.Path)
    parser.add_argument("output_directory", type=pathlib.Path)
    parser.add_argument("--version", default=os.environ.get("BLOOM_SERVER_VERSION", "").removeprefix("v"))
    arguments = parser.parse_args()
    version = arguments.version or "0.0.0-dev." + run("git", "rev-parse", "--short=12", "HEAD")
    package(arguments.bin_directory.resolve(), arguments.output_directory.resolve(), version)
