#!/usr/bin/env python3
# ----------------------------------------------------------------------------
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# ----------------------------------------------------------------------------

"""Create an isolated Xcode project that compiles the shared core with the app."""

from __future__ import annotations

import hashlib
import re
import shutil
import sys
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if text.count(old) != 1:
        raise RuntimeError(f"could not uniquely locate {label} in project file")
    return text.replace(old, new, 1)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: prepare_sandbox_xcode_project.py REPO_ROOT OUTPUT_ROOT")
    repo = Path(sys.argv[1]).resolve()
    output = Path(sys.argv[2]).resolve()
    shutil.copytree(repo / "iOS", output / "iOS")
    shutil.copytree(repo / "Sources" / "MorseJoggerCore", output / "Sources" / "MorseJoggerCore")

    # The app target's xcconfig includes the gitignored iOS/Local.xcconfig and
    # fails without it. A clean checkout has none, so give the copy one with no
    # contact; this build only compiles and never makes requests.
    local_config = output / "iOS" / "Local.xcconfig"
    if not local_config.exists():
        local_config.write_text("// Written by prepare_sandbox_xcode_project.py\nSCP_CONTACT =\n")

    project_file = output / "iOS" / "MorseJogger.xcodeproj" / "project.pbxproj"
    project = project_file.read_text()

    project = project.replace(
        "\t\tDBCEFD382D7B0C627A66238A /* MorseJoggerCore in Frameworks */ = "
        "{isa = PBXBuildFile; productRef = ABA857E919B98E9E458DB870 /* MorseJoggerCore */; };\n",
        "",
    )
    project = project.replace(
        "\t\t\t\tDBCEFD382D7B0C627A66238A /* MorseJoggerCore in Frameworks */,\n", ""
    )
    project = project.replace(
        "\t\t\tpackageProductDependencies = (\n"
        "\t\t\t\tABA857E919B98E9E458DB870 /* MorseJoggerCore */,\n"
        "\t\t\t);\n",
        "\t\t\tpackageProductDependencies = (\n\t\t\t);\n",
    )
    project = project.replace(
        "\t\t\tpackageReferences = (\n"
        "\t\t\t\t852BDDF0CC5DBD6E981402E9 /* XCLocalSwiftPackageReference \"..\" */,\n"
        "\t\t\t);\n",
        "\t\t\tpackageReferences = (\n\t\t\t);\n",
    )
    project = re.sub(
        r"/\* Begin XCLocalSwiftPackageReference section \*/.*?"
        r"/\* End XCLocalSwiftPackageReference section \*/\n",
        "",
        project,
        flags=re.S,
    )
    project = re.sub(
        r"/\* Begin XCSwiftPackageProductDependency section \*/.*?"
        r"/\* End XCSwiftPackageProductDependency section \*/\n",
        "",
        project,
        flags=re.S,
    )

    # The icon-composer document triggers CoreSimulator/icon tooling that is
    # unavailable in this sandbox. Keep the regular asset catalog build.
    project = "\n".join(line for line in project.splitlines() if "morse_jogger.icon" not in line) + "\n"

    core_files = sorted((output / "Sources" / "MorseJoggerCore").glob("*.swift"))
    build_entries: list[str] = []
    file_entries: list[str] = []
    source_entries: list[str] = []
    for source in core_files:
        stem = hashlib.sha1(source.name.encode()).hexdigest()[:20].upper()
        build_id = f"E0{stem}01"
        file_id = f"E1{stem}02"
        name = source.name
        build_entries.append(
            f"\t\t{build_id} /* {name} in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = {file_id} /* {name} */; }};"
        )
        file_entries.append(
            f"\t\t{file_id} /* {name} */ = "
            f"{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
            f"path = ../Sources/MorseJoggerCore/{name}; sourceTree = \"<group>\"; }};"
        )
        source_entries.append(f"\t\t\t\t{build_id} /* {name} in Sources */,\n")

    project = replace_once(
        project,
        "/* End PBXBuildFile section */",
        "\n".join(build_entries) + "\n/* End PBXBuildFile section */",
        "PBXBuildFile section",
    )
    project = replace_once(
        project,
        "/* End PBXFileReference section */",
        "\n".join(file_entries) + "\n/* End PBXFileReference section */",
        "PBXFileReference section",
    )
    project = replace_once(
        project,
        "\t\t\t\t3009AC24EA7625B582588567 /* GameView.swift in Sources */,\n",
        "\t\t\t\t3009AC24EA7625B582588567 /* GameView.swift in Sources */,\n"
        + "".join(source_entries),
        "app sources phase",
    )
    project_file.write_text(project)

    # In this disposable project the core is compiled into the app module, so
    # remove its package-module imports from the copied app sources only.
    for source in (output / "iOS" / "MorseJogger").glob("*.swift"):
        source.write_text(source.read_text().replace("import MorseJoggerCore\n", ""))


if __name__ == "__main__":
    main()
