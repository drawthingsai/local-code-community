#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 OUTPUT_JSONL" >&2
  exit 2
fi

output_path=$1
dataset_revision=0fe84c3912ea0c4d4a78037083943e8f0c4dd505
expected_sha256=bb4c364f71921c4495a6ad15abe1a927350b720009f4933e2e71f8af0f6fd1f5
dataset_url="https://huggingface.co/datasets/livecodebench/code_generation_lite/resolve/$dataset_revision/test6.jsonl"

if [ -e "$output_path" ]; then
  echo "Refusing to overwrite existing path: $output_path" >&2
  exit 1
fi

mkdir -p "$(dirname -- "$output_path")"
output_dir=$(CDPATH= cd -- "$(dirname -- "$output_path")" && pwd)
partial_path=$(mktemp "$output_dir/.livecodebench-v6.XXXXXX")
cleanup() {
  rm -f "$partial_path"
}
trap cleanup EXIT INT TERM

curl -L --fail --retry 3 --output "$partial_path" "$dataset_url"
actual_sha256=$(shasum -a 256 "$partial_path" | awk '{print $1}')
if [ "$actual_sha256" != "$expected_sha256" ]; then
  echo "Dataset checksum mismatch: expected $expected_sha256, got $actual_sha256" >&2
  exit 1
fi
jq -s -e '
  length == 175 and
  all(.[];
    (.question_id | type == "string") and
    (.question_title | type == "string") and
    (.question_content | type == "string") and
    (.starter_code | type == "string") and
    (.difficulty | type == "string") and
    (.public_test_cases | type == "string") and
    (.private_test_cases | type == "string") and
    (.metadata | type == "string"))
' "$partial_path" >/dev/null

mv "$partial_path" "$output_path"
trap - EXIT INT TERM
echo "Wrote verified LiveCodeBench v6 dataset to $output_path"
