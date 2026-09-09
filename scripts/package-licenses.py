#!/usr/bin/env python3
import pathlib, shutil, sys
root=pathlib.Path(__file__).resolve().parent.parent
destination=pathlib.Path(sys.argv[1])
destination.mkdir(parents=True,exist_ok=True)
shutil.copy(root/"LICENSE",destination/"App-MIT.txt")
shutil.copy(root/"vendor/copilot-bridge/LICENSE",destination/"CLI-MIT.txt")
shutil.copy(root/"THIRD_PARTY_NOTICES.md",destination/"THIRD_PARTY_NOTICES.md")
for file in (root/"resources/licenses").glob("*"):
    if file.is_file():shutil.copy(file,destination/file.name)
modules=(root/"vendor/copilot-bridge/node_modules").resolve()
for package in modules.iterdir():
    candidates=list(package.iterdir()) if package.name.startswith("@") and package.is_dir() else [package]
    for candidate in candidates:
        if not candidate.is_dir() or candidate.name.startswith("."):continue
        name=str(candidate.relative_to(modules)).replace("/","--")
        for file in candidate.iterdir():
            if file.is_file() and file.name.lower().startswith(("license","licence","copying","notice")):
                target=destination/name
                target.mkdir(exist_ok=True)
                shutil.copy(file,target/file.name)
