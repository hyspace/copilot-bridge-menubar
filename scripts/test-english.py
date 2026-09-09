#!/usr/bin/env python3
"""Prevent Chinese UI/help/documentation from reappearing in the English app.

Protocol fixtures deliberately contain Unicode and are not user-interface text.
Vendored upstream sources and historical logs are not translated.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
paths = list((root / "Sources").rglob("*.swift"))
paths += [p for p in (root / "backend").glob("*.ts") if not p.name.endswith(".test.ts")]
paths += list((root / "resources").glob("*.plist"))
paths += list((root / "docs").rglob("*.md"))
paths += list(root.glob("*.md"))
failures = []
for path in paths:
    for line, text in enumerate(path.read_text().splitlines(), 1):
        if re.search(r"[\u3400-\u9fff]", text):
            failures.append(f"{path.relative_to(root)}:{line}")
if failures:
    raise SystemExit("Unexpected Chinese product text:\n" + "\n".join(failures))
print("PASS: owned app interface, help and documentation are English.")
