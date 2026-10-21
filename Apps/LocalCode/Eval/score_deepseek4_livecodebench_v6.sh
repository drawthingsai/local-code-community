#!/bin/sh
set -eu

usage() {
  echo "Usage: $0 LIVE_CODE_BENCH_ROOT DATASET_JSONL GENERATIONS_JSONL OUTPUT_JSON [NUM_PROCESSES] [TIMEOUT_SECONDS]" >&2
  exit 2
}

[ "$#" -ge 4 ] || usage
[ "$#" -le 6 ] || usage

livecodebench_root=$1
dataset_path=$2
generations_path=$3
output_path=$4
num_processes=${5:-8}
timeout_seconds=${6:-6}

[ -d "$livecodebench_root/lcb_runner" ] || {
  echo "Missing official LiveCodeBench checkout: $livecodebench_root" >&2
  exit 1
}
[ -f "$dataset_path" ] || {
  echo "Missing dataset: $dataset_path" >&2
  exit 1
}
[ -f "$generations_path" ] || {
  echo "Missing generations: $generations_path" >&2
  exit 1
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
livecodebench_root=$(CDPATH= cd -- "$livecodebench_root" && pwd)
dataset_dir=$(CDPATH= cd -- "$(dirname -- "$dataset_path")" && pwd)
dataset_path="$dataset_dir/$(basename -- "$dataset_path")"
generations_dir=$(CDPATH= cd -- "$(dirname -- "$generations_path")" && pwd)
generations_path="$generations_dir/$(basename -- "$generations_path")"
mkdir -p "$(dirname -- "$output_path")"
output_dir=$(CDPATH= cd -- "$(dirname -- "$output_path")" && pwd)
output_path="$output_dir/$(basename -- "$output_path")"

livecodebench_revision=$(git -C "$livecodebench_root" rev-parse HEAD)
expected_livecodebench_revision=28fef95ea8c9f7a547c8329f2cd3d32b92c1fa24
if [ "$livecodebench_revision" != "$expected_livecodebench_revision" ]; then
  echo "LiveCodeBench checkout must be pinned to $expected_livecodebench_revision; found $livecodebench_revision" >&2
  exit 1
fi
revision_prefix=$(printf '%s' "$livecodebench_revision" | cut -c1-12)
image="draw-things-livecodebench-eval:$revision_prefix"

if ! docker image inspect "$image" >/dev/null 2>&1; then
  docker build \
    --file "$script_dir/LiveCodeBenchEval.Dockerfile" \
    --tag "$image" \
    "$livecodebench_root"
fi

score_temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/draw-things-lcb-score.XXXXXX")
cleanup() {
  rm -rf "$score_temp_dir"
}
trap cleanup EXIT INT TERM

docker run --rm \
  --network none \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --pids-limit 512 \
  --memory 16g \
  --shm-size 2g \
  --tmpfs /tmp:rw,nosuid,nodev,size=2g \
  --user "$(id -u):$(id -g)" \
  --env LCB_EVAL_IN_CONTAINER=1 \
  --env "LCB_REVISION=$livecodebench_revision" \
  --volume "$script_dir/score_deepseek4_livecodebench_v6.py:/runner/score.py:ro" \
  --volume "$dataset_path:/input/test6.jsonl:ro" \
  --volume "$generations_path:/input/generations.jsonl:ro" \
  --volume "$score_temp_dir:/output:rw" \
  "$image" \
  --dataset /input/test6.jsonl \
  --generations /input/generations.jsonl \
  --output /output/score.json \
  --num-process-evaluate "$num_processes" \
  --timeout "$timeout_seconds"

cp "$score_temp_dir/score.json" "$output_path"
echo "Wrote $output_path"
