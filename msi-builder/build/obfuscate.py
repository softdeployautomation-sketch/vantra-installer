#!/usr/bin/env python3
"""
Vantra MSI value obfuscation.

Randomizes PowerShell variable names and splits string/integer credential
values into chunks so that no two MSIs are internally identical and values
cannot be extracted from the baked-in orchestrator by simple string search.

Obfuscate a generated orchestrator script:
    python3 obfuscate.py \
        --input /path/to/orchestrator.ps1 \
        --output /path/to/orchestrator-obf.ps1 \
        --auth-token <value> \
        --api-url <value> \
        --client-id <value> \
        --site-id <value> \
        --manufacturer <value>

Emit an obfuscated VBScript URL concatenation expression (stdout only):
    python3 obfuscate.py --vbs-url <https://...>

Python 3 standard library only — no external dependencies.
"""

import argparse
import random
import sys

HEX_CHARS = "0123456789abcdef"
HEX_LETTERS = "abcdef"
VAR_NAME_LENGTH = 6


def random_var_name(used, forbidden_chars):
    """Return a unique PowerShell variable name: '$' + 6 lowercase hex chars.

    The name always begins with a hex LETTER (a-f) because PowerShell does not
    reliably accept variable names that start with a digit when used bare.
    Characters that appear in any raw credential value are excluded from the
    name pools whenever possible, so a later str.replace() pass (e.g. replacing
    a one-digit client-id) cannot corrupt a variable name already embedded in
    an earlier expression. Falls back to the full alphabet if every char is
    forbidden.
    """
    letter_pool = [c for c in HEX_LETTERS if c not in forbidden_chars] or list(
        HEX_LETTERS
    )
    char_pool = [c for c in HEX_CHARS if c not in forbidden_chars] or list(HEX_CHARS)
    while True:
        candidate = (
            "$"
            + random.choice(letter_pool)
            + "".join(random.choice(char_pool) for _ in range(VAR_NAME_LENGTH - 1))
        )
        if candidate not in used:
            used.add(candidate)
            return candidate


def split_into_chunks(value, min_parts, max_parts):
    """Split a string into a random number of non-empty chunks."""
    length = len(value)
    if length <= 1:
        return [value]
    max_parts = min(max_parts, length)
    min_parts = min(min_parts, max_parts)
    num_parts = random.randint(min_parts, max_parts)
    cuts = sorted(random.sample(range(1, length), num_parts - 1))
    parts = []
    prev = 0
    for cut in cuts:
        parts.append(value[prev:cut])
        prev = cut
    parts.append(value[prev:])
    return parts


def obfuscate_string(value, used, forbidden_chars):
    """Split a string value across 3-5 random variable chunks (2-4 split points)."""
    parts = split_into_chunks(value, 3, 5)
    declarations = []
    names = []
    for part in parts:
        name = random_var_name(used, forbidden_chars)
        declarations.append('{0} = "{1}"'.format(name, part))
        names.append(name)
    expression = "(" + " + ".join(names) + ")"
    return declarations, expression


def obfuscate_integer(value, used, forbidden_chars):
    """Split an integer into two random addends stored in random variables.

    Returns ([], "[string](0)") for the value 0.
    """
    try:
        n = int(value)
    except ValueError:
        raise ValueError("expected an integer for obfuscation, got {0!r}".format(value))
    if n == 0:
        return [], "[string](0)"
    a = random.randint(0, n)
    b = n - a
    name_a = random_var_name(used, forbidden_chars)
    name_b = random_var_name(used, forbidden_chars)
    declarations = [
        "{0} = {1}".format(name_a, a),
        "{0} = {1}".format(name_b, b),
    ]
    expression = "[string]({0} + {1})".format(name_a, name_b)
    return declarations, expression


def obfuscate_vbs_url(url):
    """Split a URL into 3-5 VBScript string literals joined with ' & '."""
    parts = split_into_chunks(url, 3, 5)
    return " & ".join('"{0}"'.format(part) for part in parts)


def process_input_file(input_path, output_path, values):
    """Replace raw credential values with obfuscated expressions.

    `values` is an iterable of (raw_value, obfuscator_callable). Each raw value
    is located in the file text with str.replace() and swapped for its
    expression; the collected declaration lines are inserted at the very start
    of the `try {` block.
    """
    try:
        with open(input_path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        print("Error: cannot read {0}: {1}".format(input_path, exc), file=sys.stderr)
        return 1

    used = set()
    forbidden_chars = set()
    for raw, _ in values:
        if raw:
            forbidden_chars.update(raw)

    planned = []
    try:
        for raw, obfuscator in values:
            if not raw:
                continue
            declarations, expression = obfuscator(raw, used, forbidden_chars)
            planned.append((raw, declarations, expression))
    except ValueError as exc:
        print("Error: {0}".format(exc), file=sys.stderr)
        return 1

    preamble_lines = []
    # Process the longest values first so a short value (e.g. a one-digit
    # site-id) cannot be substituted inside a longer value's raw form or an
    # already-inserted expression.
    planned.sort(key=lambda item: len(item[0]), reverse=True)
    for raw, declarations, expression in planned:
        if raw not in text:
            print(
                "Warning: value {0!r} not found in input; skipping".format(raw),
                file=sys.stderr,
            )
            continue
        text = text.replace(raw, expression)
        preamble_lines.extend(declarations)

    if preamble_lines:
        preamble = "\n".join(preamble_lines)
        marker = "try {"
        if marker in text:
            text = text.replace(marker, marker + "\n" + preamble, 1)
        else:
            print(
                "Warning: 'try {' block not found; prepending declarations to file",
                file=sys.stderr,
            )
            text = preamble + "\n" + text

    try:
        with open(output_path, "w", encoding="utf-8") as fh:
            fh.write(text)
    except OSError as exc:
        print("Error: cannot write {0}: {1}".format(output_path, exc), file=sys.stderr)
        return 1
    return 0


def main(argv):
    parser = argparse.ArgumentParser(
        description="Obfuscate credential values embedded in the Vantra installer."
    )
    parser.add_argument("--input", help="generated orchestrator.ps1 to obfuscate")
    parser.add_argument("--output", help="path for the obfuscated orchestrator.ps1")
    parser.add_argument("--auth-token", help="agent auth token value")
    parser.add_argument("--api-url", help="TacticalRMM API URL value")
    parser.add_argument("--client-id", help="client ID integer")
    parser.add_argument("--site-id", help="site ID integer")
    parser.add_argument("--manufacturer", help="manufacturer name")
    parser.add_argument(
        "--vbs-url", help="emit an obfuscated VBScript URL expression and exit"
    )
    args = parser.parse_args(argv)

    if args.vbs_url is not None:
        print(obfuscate_vbs_url(args.vbs_url))
        return 0

    if not args.input or not args.output:
        print(
            "Error: --input and --output are required (or use --vbs-url)",
            file=sys.stderr,
        )
        return 1

    if not any(
        [args.auth_token, args.api_url, args.client_id, args.site_id, args.manufacturer]
    ):
        print(
            "Error: at least one value to obfuscate is required "
            "(--auth-token, --api-url, --client-id, --site-id, or --manufacturer)",
            file=sys.stderr,
        )
        return 1

    values = [
        (args.auth_token, obfuscate_string),
        (args.api_url, obfuscate_string),
        (args.manufacturer, obfuscate_string),
        (args.client_id, obfuscate_integer),
        (args.site_id, obfuscate_integer),
    ]
    return process_input_file(args.input, args.output, values)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))