#!/usr/bin/env python3
import glob
import json
import os
import re
import sys
from pathlib import Path


def eprint(msg: str, code: int = 1) -> None:
    print(f"❌ {msg}", file=sys.stderr)
    sys.exit(code)


files_input = os.environ.get("INPUT_FILES", "").strip()
start_token = os.environ.get("INPUT_START_TOKEN", "#{")
end_token = os.environ.get("INPUT_END_TOKEN", "}")
secrets_json = os.environ.get("INPUT_SECRETS_JSON", "{}").strip()

if not files_input:
    eprint("No files provided. Set inputs.files.")

if not start_token or not end_token:
    eprint("start-token and end-token must be non-empty.")

try:
    secrets = json.loads(secrets_json) if secrets_json else {}
except json.JSONDecodeError as exc:
    eprint(f"Invalid secrets JSON: {exc}", 2)

if not isinstance(secrets, dict):
    eprint("Secrets JSON must be an object.", 2)

patterns: list[str] = []
for line in files_input.splitlines():
    if not line.strip():
        continue
    patterns.extend(line.split())

files: list[Path] = []
for pat in patterns:
    for match in glob.glob(pat, recursive=True):
        path = Path(match)
        if path.is_file():
            files.append(path)

if not files:
    eprint("No files matched inputs.files.")

unique_files: list[Path] = []
seen: set[Path] = set()
for f in files:
    if f not in seen:
        seen.add(f)
        unique_files.append(f)

pattern = re.compile(re.escape(start_token) + r"([A-Za-z0-9_.-]+)" + re.escape(end_token))

replaced_tokens: set[str] = set()
missing_tokens: set[str] = set()

print(f"🔍 Processing {len(unique_files)} file(s)...")

for f in unique_files:
    text = f.read_text(encoding="utf-8")
    tokens_in_file = set(pattern.findall(text))
    if not tokens_in_file:
        continue

    def repl(match: re.Match[str]) -> str:
        key = match.group(1)
        if key in secrets:
            return str(secrets[key])
        return match.group(0)

    for token in tokens_in_file:
        if token in secrets:
            replaced_tokens.add(token)
        else:
            missing_tokens.add(token)

    new_text = pattern.sub(repl, text)
    if new_text != text:
        f.write_text(new_text, encoding="utf-8")

if replaced_tokens:
    print("✅ Replaced tokens:")
    for t in sorted(replaced_tokens):
        print(f"- {t}")
else:
    print("⚠️ No tokens were replaced.")

if missing_tokens:
    print("⚠️ Missing tokens:")
    for t in sorted(missing_tokens):
        print(f"- {t}")
else:
    print("✅ No missing tokens.")
