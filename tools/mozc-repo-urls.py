"""What Bazel repositories download, for tools/mozc-downloads.sh (#335): one "URL repos SHA256" line per file,
or "? NAME" for a repository whose files it can't tell.

    python3 -I mozc-repo-urls.py REGISTRY NAME...   # a module's repository (NAME: "rules_cc+" or "platforms"), from REGISTRY,
                                                    # the registry's copy: its source.json and MODULE.bazel
    ... | python3 -I mozc-repo-urls.py OUTPUT_BASE  # other repositories, from their rules' attributes in
                                                    # `bazel mod show_repo --output=streamed_jsonproto`, or for
                                                    # protobuf's prebuilt protoc from protobuf's own list
"""

import ast
import base64
import glob
import hashlib
import json
import os
import sys

BCR = "https://bcr.bazel.build/"


def sha(integrity):  # "sha256-<base64>" or hex
    if integrity.startswith("sha256-"):
        return base64.b64decode(integrity[7:]).hex()
    return integrity


def module(registry, name):
    sources = glob.glob(
        os.path.join(registry, "modules", name.rstrip("+"), "*", "source.json")
    )
    if len(sources) != 1:
        return []
    d = os.path.dirname(sources[0])
    rel = os.path.relpath(d, registry)
    source = json.load(open(sources[0]))
    files = [(source["url"], sha(source["integrity"]))]
    for patch, integrity in source.get("patches", {}).items():
        files.append((f"{BCR}{rel}/patches/{patch}", sha(integrity)))
    for overlay, integrity in source.get("overlay", {}).items():
        files.append((f"{BCR}{rel}/overlay/{overlay}", sha(integrity)))
    with open(os.path.join(d, "MODULE.bazel"), "rb") as f:
        files.append((f"{BCR}{rel}/MODULE.bazel", hashlib.sha256(f.read()).hexdigest()))
    return files


def rule(repo, output_base):
    if (
        repo["repoRuleName"] == "prebuilt_protoc_repo"
    ):  # its rule names the file in code, not in attributes
        return protoc(repo, output_base)
    a = {}
    for x in repo.get("attribute", []):
        v = (
            x.get("stringValue")
            or x.get("stringListValue")
            or x.get("stringDictValue")
            or x.get("stringListDictValue")
        )
        if v:
            a[x["name"]] = v
    files = []
    urls = a.get("urls") or ([a["url"]] if "url" in a else [])
    if urls and (a.get("integrity") or a.get("sha256")):
        files.append((urls[0], sha(a.get("integrity") or a["sha256"])))
    if a.get("remote_module_file_urls"):
        files.append(
            (a["remote_module_file_urls"][0], sha(a["remote_module_file_integrity"]))
        )
    for d in a.get("remote_patches", []):
        files.append((d["key"], sha(d["value"])))
    integrity = {d["key"]: d["value"] for d in a.get("remote_file_integrity", [])}
    for d in a.get("remote_file_urls", []):
        files.append(
            (
                d["value"][0] if isinstance(d["value"], list) else d["value"],
                sha(integrity[d["key"]]),
            )
        )
    return files


def protoc(
    repo, output_base
):  # as protobuf's bazel/private/oss/toolchains/prebuilt/protoc_toolchain.bzl
    platform = next(
        x["stringValue"] for x in repo["attribute"] if x["name"] == "platform"
    )
    rel = repo["repoRuleBzlLabel"].split("//")[1].split(":")[0]
    path = os.path.join(
        output_base, "external", repo["repoRuleBzlLabel"][2:].split("//")[0], rel
    )
    tree = ast.parse(open(os.path.join(path, "tool_integrity.bzl")).read())
    known = {
        n.targets[0].id: ast.literal_eval(n.value)
        for n in tree.body
        if isinstance(n, ast.Assign)
    }
    version = known["RELEASE_VERSION"]
    name = f"protoc-{version[1:].replace('rc', 'rc-')}-{platform}.zip"
    url = f"https://github.com/protocolbuffers/protobuf/releases/download/{version}/{name}"
    return [(url, known["RELEASED_BINARY_INTEGRITY"][name])]


if os.path.isdir(os.path.join(sys.argv[1], "modules")):
    named = [(n, module(sys.argv[1], n)) for n in sys.argv[2:]]
else:
    named = [
        (r["canonicalName"], rule(r, sys.argv[1])) for r in map(json.loads, sys.stdin)
    ]
for name, files in named:
    for url, digest in files:
        print(url, "repos", digest)
    if not files:
        print("?", name)
