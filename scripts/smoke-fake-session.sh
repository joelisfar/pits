#!/usr/bin/env bash
# Writes a fake JSONL entry to ~/.claude/projects/-tmp-pits-smoke/smoke.jsonl
# so we can observe Pits picking it up live. Uses the current timestamp.
set -euo pipefail

DIR="$HOME/.claude/projects/-tmp-pits-smoke"
mkdir -p "$DIR"
FILE="$DIR/smoke.jsonl"
TS="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")"
REQ_ID="req_smoke_$(date +%s%N | md5 | head -c 12)"

cat >> "$FILE" <<JSON
{"type":"user","sessionId":"smoke-sess","timestamp":"$TS","message":{"content":[{"type":"text","text":"hi"}]}}
{"type":"assistant","sessionId":"smoke-sess","requestId":"$REQ_ID","timestamp":"$TS","message":{"model":"claude-opus-4-6","stop_reason":"end_turn","usage":{"input_tokens":10,"cache_creation_input_tokens":5000,"cache_read_input_tokens":20000,"output_tokens":80}}}
JSON

echo "Appended turn $REQ_ID to $FILE"
