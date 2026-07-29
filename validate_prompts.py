#!/usr/bin/env python3
"""CI check: every prompt template declares the variables its name requires."""
import glob, sys
from jinja2 import Environment, meta

REQUIRED_VARS = {
    "system": {"persona"},
    "rag_answer": {"context", "question"},
}

env = Environment()
failed = False

for path in glob.glob("prompts/*.j2"):
    name = path.rsplit("/", 1)[-1].removesuffix(".j2")
    ast = env.parse(open(path).read())
    found = meta.find_undeclared_variables(ast)
    missing = REQUIRED_VARS.get(name, set()) - found
    if missing:
        print(f"[FAIL] {path}: missing template vars {sorted(missing)}")
        failed = True
    else:
        print(f"[OK]   {path}")

sys.exit(1 if failed else 0)
