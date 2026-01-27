#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixtures_dir="${root_dir}/test/fixtures"
input_dir="${fixtures_dir}/input"
output_dir="${fixtures_dir}/output"

rm -rf "${output_dir}"
mkdir -p "${output_dir}"
cp "${input_dir}"/*.txt "${output_dir}/"

export INPUT_FILES="${output_dir}/*.txt"
export INPUT_START_TOKEN="#{"
export INPUT_END_TOKEN="}"
export INPUT_SECRETS_JSON='{"API_KEY":"abc123","HOST":"example.com","TOKEN_ONE":"one","TOKEN_TWO":"two"}'

output="$(${root_dir}/replace-tokens.py)"

echo "${output}"

if [[ "${output}" != *"✅ Replaced tokens:"* ]]; then
  echo "Expected replaced tokens header" >&2
  exit 1
fi

if [[ "${output}" != *"⚠️ Missing tokens:"* ]]; then
  echo "Expected missing tokens header" >&2
  exit 1
fi

if [[ "${output}" != *"- API_KEY"* ]]; then
  echo "Expected API_KEY to be replaced" >&2
  exit 1
fi

if [[ "${output}" != *"- HOST"* ]]; then
  echo "Expected HOST to be replaced" >&2
  exit 1
fi

if [[ "${output}" != *"- NOT_SET"* ]]; then
  echo "Expected NOT_SET to be missing" >&2
  exit 1
fi

if ! grep -q "API=abc123" "${output_dir}/sample.txt"; then
  echo "Expected API_KEY to be replaced in sample.txt" >&2
  exit 1
fi

if ! grep -q "HOST=example.com" "${output_dir}/sample.txt"; then
  echo "Expected HOST to be replaced in sample.txt" >&2
  exit 1
fi

if ! grep -q "MISSING=\#{NOT_SET\}" "${output_dir}/sample.txt"; then
  echo "Expected NOT_SET to remain unchanged in sample.txt" >&2
  exit 1
fi

if ! grep -q "TOKEN=one" "${output_dir}/second.txt"; then
  echo "Expected TOKEN_ONE to be replaced in second.txt" >&2
  exit 1
fi

if ! grep -q "OTHER=two" "${output_dir}/second.txt"; then
  echo "Expected TOKEN_TWO to be replaced in second.txt" >&2
  exit 1
fi

echo "All tests passed."
