#!/usr/bin/env python3
"""Reject YAML that GitHub rejects but PyYAML happily accepts.

``yaml.safe_load`` keeps the last of a set of duplicate mapping keys and reports
success. GitHub's workflow parser fails the run at parse time instead, before
any job is created, so "it parses locally" proves nothing about whether GitHub
will accept the file unless the loader rejects duplicates too.

Usage: yamlcheck.py <file> [<file> ...]
"""

import sys

import yaml


class StrictLoader(yaml.SafeLoader):
    """SafeLoader that treats a repeated mapping key as an error."""


def _reject_duplicate_keys(loader, node, deep=False):
    mapping = {}

    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)

        if key in mapping:
            raise yaml.constructor.ConstructorError(
                None,
                None,
                f"duplicate key {key!r}",
                key_node.start_mark,
            )

        mapping[key] = loader.construct_object(value_node, deep=deep)

    return mapping


StrictLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    _reject_duplicate_keys,
)


def main(paths):
    if not paths:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2

    failed = False

    for path in paths:
        try:
            with open(path, encoding="utf-8") as handle:
                yaml.load(handle, Loader=StrictLoader)
        except (OSError, yaml.YAMLError) as exc:
            print(f"FAIL {path}: {exc}", file=sys.stderr)
            failed = True
        else:
            print(f"ok   {path}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
