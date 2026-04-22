# LiteLLM pricing fetch — Implementation Plan (Pits + gh-claude-costs)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop hardcoding model rates. Both apps fetch the rate table from [LiteLLM's `model_prices_and_context_window.json`](https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json), so adding a new Claude model never requires a code change. The local 5m/1h cache-write split logic stays in each app (LiteLLM only models a single cache_creation rate).

**Architecture:** LiteLLM JSON is the source of truth for `base`, `output`, and `cache_read` rates per model. Each app overlays fetched values onto a small bundled fallback table (so a fetch failure or a rate that's missing upstream silently falls back to a sane default). The 1-hour cache rate is always derived locally as `2 × base_input_rate`; the 5-minute cache rate is the LiteLLM-supplied `cache_creation_input_token_cost` (which is `1.25 × base`).

**Tech Stack:**
- gh-claude-costs (Python 3.9+): adds `urllib.request` fetch (stdlib, no new deps)
- Pits (Swift, macOS 14+): adds `URLSession` fetch + on-disk JSON cache file

**LiteLLM URL:** `https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json`

**LiteLLM filter:** keep entries where `litellm_provider == "anthropic"` and the key matches `^claude-(opus|sonnet|haiku)-…$` (skip date-suffixed duplicates and Bedrock variants — they're synonyms; `normalize_model` already strips date suffixes on our side).

**Conversion:** LiteLLM stores per-token costs (e.g., `1e-06` = `$1/M`). Multiply by `1_000_000` to get our `$/M` format.

**Rate derivation:**
- `base` ← `input_cost_per_token × 1_000_000`
- `output` ← `output_cost_per_token × 1_000_000`
- `cache_read` ← `cache_read_input_token_cost × 1_000_000`
- `cache_write_5m` ← `cache_creation_input_token_cost × 1_000_000` (= `base × 1.25`)
- `cache_write_1h` ← `base × 2.0` (derived; not in LiteLLM)

**Per-request 1h-vs-5m attribution:** Already handled in Pits (v0.0.6 PR #9 reads `usage.cache_creation.ephemeral_5m_input_tokens` and `ephemeral_1h_input_tokens`). New in gh-claude-costs (Plan A).

---

## Plan A: gh-claude-costs

Repo: `/Users/jifarris/Projects/gh-claude-costs/`. Single file: `extract.py`. No test framework currently — we'll add a tiny `test_extract.py` driven by the Python `unittest` stdlib so this PR doesn't introduce a new dependency.

### Task A1: Bundled fallback table (extract current PRICING into a constant we can overlay)

**Files:**
- Modify: `extract.py:21-30` — rename `PRICING` to `FALLBACK_PRICING`, add a runtime `pricing` dict that is initially `dict(FALLBACK_PRICING)`.

- [ ] **A1.1: Edit `extract.py`** — replace the existing `PRICING = { ... }` block with:

```python
# Fallback pricing — used when LiteLLM fetch fails or a model isn't listed
# upstream. These are the canonical Anthropic API prices in $/Mtok. They're
# the v0.0.6 corrections (Opus 4.7 added, Haiku 4.5 corrected to $1/$5).
FALLBACK_PRICING = {
    "claude-opus-4-7":   {"base": 5.00, "cache_write": 6.25, "cache_read": 0.50, "output": 25.00},
    "claude-opus-4-6":   {"base": 5.00, "cache_write": 6.25, "cache_read": 0.50, "output": 25.00},
    "claude-opus-4-5":   {"base": 5.00, "cache_write": 6.25, "cache_read": 0.50, "output": 25.00},
    "claude-opus-4":     {"base": 15.00, "cache_write": 18.75, "cache_read": 1.50, "output": 75.00},
    "claude-sonnet-4-6": {"base": 3.00, "cache_write": 3.75, "cache_read": 0.30, "output": 15.00},
    "claude-sonnet-4-5": {"base": 3.00, "cache_write": 3.75, "cache_read": 0.30, "output": 15.00},
    "claude-sonnet-4":   {"base": 3.00, "cache_write": 3.75, "cache_read": 0.30, "output": 15.00},
    "claude-haiku-4-5":  {"base": 1.00, "cache_write": 1.25, "cache_read": 0.10, "output": 5.00},
    "claude-haiku-3-5":  {"base": 0.80, "cache_write": 1.00, "cache_read": 0.08, "output": 4.00},
}
```

- [ ] **A1.2: Replace every `PRICING[…]` lookup with the runtime variable.** There's exactly one usage site near the bottom (`pricing = {m: PRICING[m] for m in seen_models if m in PRICING}`). Update it (we'll point it at the runtime dict in Task A2).

- [ ] **A1.3: Commit**

```bash
cd /Users/jifarris/Projects/gh-claude-costs
git add extract.py
git commit -m "refactor: rename PRICING -> FALLBACK_PRICING for forthcoming overlay"
```

### Task A2: LiteLLM fetcher

**Files:**
- Modify: `extract.py` — add `fetch_litellm_pricing()` and the merge logic.

- [ ] **A2.1: Add the fetcher (place above `extract()`)**

```python
import urllib.request
import urllib.error
import re as _re_mod

LITELLM_URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
LITELLM_TIMEOUT_SEC = 5

def fetch_litellm_pricing(timeout=LITELLM_TIMEOUT_SEC):
    """Fetch model rates from LiteLLM and return a {normalized_model_name: rates}
    dict in our $/Mtok shape. On any failure, return an empty dict — caller
    overlays fetched onto FALLBACK_PRICING, so empty means 'use fallback'.

    LiteLLM stores per-token costs (1e-6 = $1/M); we convert to $/M.
    Filters to anthropic-direct entries; drops date-suffixed duplicates."""
    try:
        with urllib.request.urlopen(LITELLM_URL, timeout=timeout) as resp:
            data = json.load(resp)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
        return {}

    result = {}
    for raw_name, entry in data.items():
        if entry.get("litellm_provider") != "anthropic":
            continue
        # normalize_model strips trailing -YYYYMMDD; that gives us canonical names
        normalized = normalize_model(raw_name)
        if normalized is None:
            continue
        # Only Anthropic Claude models we care about
        if not _re_mod.match(r"^claude-(opus|sonnet|haiku)-\d", normalized):
            continue
        try:
            base = entry["input_cost_per_token"] * 1_000_000
            output = entry["output_cost_per_token"] * 1_000_000
            cache_read = entry["cache_read_input_token_cost"] * 1_000_000
            cache_write = entry["cache_creation_input_token_cost"] * 1_000_000
        except (KeyError, TypeError):
            continue
        # Last write wins for duplicate normalized names (e.g. claude-opus-4-7
        # and claude-opus-4-7-20260416 both normalize to claude-opus-4-7);
        # prices are identical for the duplicates so it doesn't matter.
        result[normalized] = {
            "base": base,
            "cache_write": cache_write,
            "cache_read": cache_read,
            "output": output,
        }
    return result
```

- [ ] **A2.2: Build the runtime `pricing` table by overlaying fetched onto fallback**

In `extract()` (top of the function, after the `files = find_jsonl_files()` line) add:

```python
    fetched = fetch_litellm_pricing()
    pricing = dict(FALLBACK_PRICING)
    pricing.update(fetched)  # fetched values win where present
    if fetched:
        print(f"Loaded pricing for {len(fetched)} models from LiteLLM", file=sys.stderr)
    else:
        print("LiteLLM fetch failed; using bundled fallback pricing", file=sys.stderr)
```

Then replace the existing `pricing = {m: PRICING[m] for m in seen_models if m in PRICING}` line near the bottom with:

```python
    pricing = {m: pricing[m] for m in seen_models if m in pricing}
```

- [ ] **A2.3: Manual smoke test**

```bash
cd /Users/jifarris/Projects/gh-claude-costs
python3 extract.py --since 2026-04-01 2>&1 | head -3
# Expect first stderr line: "Loaded pricing for N models from LiteLLM" with N >= 9
```

- [ ] **A2.4: Commit**

```bash
git add extract.py
git commit -m "feat: fetch model pricing from LiteLLM (fallback to bundled table)"
```

### Task A3: Per-request 5m/1h cache-write split

**Files:** `extract.py` only.

- [ ] **A3.1: Read the nested `cache_creation` object in the assistant-entry parse.**

Find the block that builds the assistant tuple (`elif entry_type == "assistant":` around line 122). Replace the tuple-construction with a version that splits cache_creation:

```python
elif entry_type == "assistant":
    rid = obj.get("requestId", "")
    include = (rid and seen_requests.get(rid) == id(obj)) or not rid
    if include:
        usage = obj.get("message", {}).get("usage", {})
        raw_model = obj.get("message", {}).get("model", "")
        model = normalize_model(raw_model) if raw_model else None
        if usage and model:
            # Anthropic recently added a 1h cache tier billed at 2x base.
            # The JSONL exposes the split via usage.cache_creation; older
            # entries only have the flat field, which we treat as 5m.
            cc = usage.get("cache_creation") or {}
            if cc:
                cc_5m = cc.get("ephemeral_5m_input_tokens", 0)
                cc_1h = cc.get("ephemeral_1h_input_tokens", 0)
            else:
                cc_5m = usage.get("cache_creation_input_tokens", 0)
                cc_1h = 0
            sessions[sid].append((
                "assistant", ts, model,
                cc_5m, cc_1h,
                usage.get("cache_read_input_tokens", 0),
                usage.get("output_tokens", 0),
                usage.get("input_tokens", 0),
                is_subagent, agent_id,
            ))
```

The tuple grew from 9 fields to 10. Update both look-ahead and accumulation indices.

- [ ] **A3.2: Update tuple indices**

The look-ahead loop (`for j in range(i + 1, len(msgs))`) reads `msgs[j][3]` (cache_creation) and `msgs[j][4]` (cache_read). After the split, `cache_creation` is `msgs[j][3] + msgs[j][4]`, and `cache_read` is `msgs[j][5]`. Update:

```python
        if msgs[j][0] == "assistant" and msgs[j][2]:
            creation = (msgs[j][3] or 0) + (msgs[j][4] or 0)  # 5m + 1h
            read = msgs[j][5] or 0
            total_cache = creation + read
```

The accumulation loop (`elif m[0] == "assistant" and bucket and m[2]`) currently does:

```python
stats[key][bucket]["input"] += m[6] or 0
stats[key][bucket]["cache_write"] += m[3] or 0
stats[key][bucket]["cache_read"] += m[4] or 0
stats[key][bucket]["output"] += m[5] or 0
```

Replace with:

```python
stats[key][bucket]["input"] += m[7] or 0
stats[key][bucket]["cache_write_5m"] += m[3] or 0
stats[key][bucket]["cache_write_1h"] += m[4] or 0
stats[key][bucket]["cache_read"] += m[5] or 0
stats[key][bucket]["output"] += m[6] or 0
stats[key][bucket]["messages"] += 1
```

The `is_sub = m[7]` and `agent_id = m[8]` lines (in the human branch) shift to `m[8]` and `m[9]`:

```python
is_sub = m[8]
agent_id = m[9]
```

And `source = "subagent" if m[7] else "main"` in the assistant branch becomes `source = "subagent" if m[8] else "main"`.

- [ ] **A3.3: Update the default stats dict shape**

Change the `defaultdict` factories (two places, around line 142 and 215):

```python
stats = defaultdict(
    lambda: defaultdict(
        lambda: {"input": 0, "cache_write_5m": 0, "cache_write_1h": 0, "cache_read": 0,
                 "output": 0, "human_turns": 0, "messages": 0}
    )
)
```

And in the section-builder (around line 213):

```python
section[b] = dict(d) if d else {
    "input": 0, "cache_write_5m": 0, "cache_write_1h": 0, "cache_read": 0,
    "output": 0, "human_turns": 0, "messages": 0,
}
```

- [ ] **A3.4: Update each model's pricing dict to include cache_write_1h**

In Task A1's `FALLBACK_PRICING`, replace `"cache_write": X` with `"cache_write_5m": X, "cache_write_1h": Y` where `Y = base × 2.0`. Concretely:

```python
FALLBACK_PRICING = {
    "claude-opus-4-7":   {"base": 5.00, "cache_write_5m": 6.25, "cache_write_1h": 10.00, "cache_read": 0.50, "output": 25.00},
    "claude-opus-4-6":   {"base": 5.00, "cache_write_5m": 6.25, "cache_write_1h": 10.00, "cache_read": 0.50, "output": 25.00},
    "claude-opus-4-5":   {"base": 5.00, "cache_write_5m": 6.25, "cache_write_1h": 10.00, "cache_read": 0.50, "output": 25.00},
    "claude-opus-4":     {"base": 15.00, "cache_write_5m": 18.75, "cache_write_1h": 30.00, "cache_read": 1.50, "output": 75.00},
    "claude-sonnet-4-6": {"base": 3.00, "cache_write_5m": 3.75, "cache_write_1h": 6.00, "cache_read": 0.30, "output": 15.00},
    "claude-sonnet-4-5": {"base": 3.00, "cache_write_5m": 3.75, "cache_write_1h": 6.00, "cache_read": 0.30, "output": 15.00},
    "claude-sonnet-4":   {"base": 3.00, "cache_write_5m": 3.75, "cache_write_1h": 6.00, "cache_read": 0.30, "output": 15.00},
    "claude-haiku-4-5":  {"base": 1.00, "cache_write_5m": 1.25, "cache_write_1h": 2.00, "cache_read": 0.10, "output": 5.00},
    "claude-haiku-3-5":  {"base": 0.80, "cache_write_5m": 1.00, "cache_write_1h": 1.60, "cache_read": 0.08, "output": 4.00},
}
```

And in the `fetch_litellm_pricing()` return, add `"cache_write_5m": cache_write` and `"cache_write_1h": base * 2.0` (renaming the existing `cache_write` key):

```python
result[normalized] = {
    "base": base,
    "cache_write_5m": cache_write,
    "cache_write_1h": base * 2.0,  # not in LiteLLM; derived per Anthropic docs
    "cache_read": cache_read,
    "output": output,
}
```

- [ ] **A3.5: Update template.html to read the new fields**

The template currently consumes `cache_write` from `pricing` and `stats`. Search for those references:

```bash
cd /Users/jifarris/Projects/gh-claude-costs
grep -n "cache_write" template.html
```

Update each reference to use `cache_write_5m` and `cache_write_1h`. The dashboard's "LLM INPUT/OUTPUT" table likely sums them into a single "cache write" column for display — combine them in the template's compute step:

```javascript
const cacheWriteCost = (totals.cache_write_5m * pricing.cache_write_5m
                      + totals.cache_write_1h * pricing.cache_write_1h) / 1_000_000;
```

Read the actual template structure before editing — the exact JavaScript shape may differ. The principle: anywhere the old code multiplied a single `cache_write` token total by a single `cache_write` rate, replace with the sum of the two tier-specific products.

- [ ] **A3.6: Smoke test against Pits' total**

```bash
cd /Users/jifarris/Projects/gh-claude-costs
python3 extract.py --since 2026-04-01 > /tmp/check.json
python3 -c "
import json
d = json.load(open('/tmp/check.json'))
total = 0
for key, sec in d['sections'].items():
    model = key.split('|')[0]
    r = d['pricing'].get(model)
    if not r: continue
    for b in ('warm','cold_start','cold_expired'):
        s = sec[b]
        total += (s['input']*r['base'] + s['cache_write_5m']*r['cache_write_5m']
                  + s['cache_write_1h']*r['cache_write_1h']
                  + s['cache_read']*r['cache_read'] + s['output']*r['output']) / 1_000_000
print(f'gh-claude-costs total: \${total:.2f}')
print(f'(Should match Pits ~\$737)')
"
```

Expected output: a number within a few dollars of what Pits shows for April.

- [ ] **A3.7: Commit**

```bash
git add extract.py template.html
git commit -m "feat: split cache_creation into 5m/1h tiers (1h billed at 2x base)"
```

### Task A4: Tests

**Files:**
- Create: `test_extract.py`

- [ ] **A4.1: Write the test file**

```python
"""Standalone tests for extract.py — uses unittest from stdlib only.

Run with: python3 test_extract.py
"""
import json
import unittest
from unittest.mock import patch
from io import BytesIO

import extract


class TestNormalizeModel(unittest.TestCase):
    def test_strips_date_suffix(self):
        self.assertEqual(extract.normalize_model("claude-haiku-4-5-20251001"), "claude-haiku-4-5")

    def test_no_suffix_unchanged(self):
        self.assertEqual(extract.normalize_model("claude-opus-4-7"), "claude-opus-4-7")

    def test_synthetic_returns_none(self):
        self.assertIsNone(extract.normalize_model("<synthetic>"))


class TestFetchLitellmPricing(unittest.TestCase):
    def test_returns_empty_on_network_error(self):
        with patch("urllib.request.urlopen", side_effect=OSError("offline")):
            self.assertEqual(extract.fetch_litellm_pricing(), {})

    def test_returns_empty_on_malformed_json(self):
        bad_response = BytesIO(b"not json")
        with patch("urllib.request.urlopen", return_value=bad_response):
            self.assertEqual(extract.fetch_litellm_pricing(), {})

    def test_parses_anthropic_entries_and_skips_others(self):
        sample = {
            "claude-opus-4-7": {
                "litellm_provider": "anthropic",
                "input_cost_per_token": 5e-6,
                "output_cost_per_token": 25e-6,
                "cache_read_input_token_cost": 5e-7,
                "cache_creation_input_token_cost": 6.25e-6,
            },
            "anthropic.claude-opus-4-7": {
                "litellm_provider": "bedrock_converse",
                "input_cost_per_token": 5e-6,
                "output_cost_per_token": 25e-6,
                "cache_read_input_token_cost": 5e-7,
                "cache_creation_input_token_cost": 6.25e-6,
            },
            "gpt-5": {
                "litellm_provider": "openai",
                "input_cost_per_token": 1e-6,
            },
        }
        body = BytesIO(json.dumps(sample).encode("utf-8"))
        with patch("urllib.request.urlopen", return_value=body):
            result = extract.fetch_litellm_pricing()
        self.assertIn("claude-opus-4-7", result)
        self.assertNotIn("anthropic.claude-opus-4-7", result)
        self.assertNotIn("gpt-5", result)
        rates = result["claude-opus-4-7"]
        self.assertEqual(rates["base"], 5.0)
        self.assertEqual(rates["output"], 25.0)
        self.assertEqual(rates["cache_read"], 0.5)
        self.assertEqual(rates["cache_write_5m"], 6.25)
        self.assertEqual(rates["cache_write_1h"], 10.0)  # derived = base*2

    def test_skips_entry_missing_required_field(self):
        sample = {
            "claude-opus-4-7": {
                "litellm_provider": "anthropic",
                "input_cost_per_token": 5e-6,
                # missing output_cost_per_token
            },
        }
        body = BytesIO(json.dumps(sample).encode("utf-8"))
        with patch("urllib.request.urlopen", return_value=body):
            result = extract.fetch_litellm_pricing()
        self.assertEqual(result, {})


if __name__ == "__main__":
    unittest.main()
```

- [ ] **A4.2: Run tests**

```bash
cd /Users/jifarris/Projects/gh-claude-costs
python3 test_extract.py -v
```

Expected: `OK` with 7 tests passed.

- [ ] **A4.3: Commit**

```bash
git add test_extract.py
git commit -m "test: cover normalize_model and LiteLLM fetcher (stdlib unittest)"
```

### Task A5: Branch + PR

- [ ] **A5.1: Push and open the PR**

```bash
cd /Users/jifarris/Projects/gh-claude-costs
git checkout -b litellm-pricing
git push -u origin litellm-pricing
gh pr create --title "Fetch model pricing from LiteLLM; bill 1h cache writes correctly" \
  --body "Two related changes:

1. **LiteLLM pricing fetch.** \`extract.py\` now fetches \`model_prices_and_context_window.json\` from LiteLLM at runtime, overlays it on a small bundled fallback table, and exits cleanly on offline / malformed-response. New Claude models stop silently zeroing out — they're priced as soon as LiteLLM lists them.

2. **5m vs 1h cache-write split.** Anthropic added a 1-hour cache tier billed at 2× input. The JSONL exposes the split via \`usage.cache_creation.{ephemeral_5m,ephemeral_1h}_input_tokens\`; we now read both and bill them at separate rates (1.25× and 2× base, respectively). LiteLLM only models the 5m rate; the 1h rate is derived locally as \`base × 2\`.

Combined effect on a representative April dataset: total goes from \$482 (silent under-bill) to ~\$737 (matches Anthropic console). Bundled fallback table keeps the offline path working with the same corrected numbers.

## Test plan

- [x] \`python3 test_extract.py\` passes (7 stdlib unittest tests)
- [x] Manual: total for known month matches Pits within rounding
- [x] Manual: kill network, re-run, confirm bundled fallback message + non-zero total"
```

---

## Plan B: Pits

Repo: `/Users/jifarris/Projects/pits/`. v0.0.6 already added the 5m/1h split logic — this plan only adds the LiteLLM fetcher. New files keep the change small.

### Task B1: `RemotePricing` service

**Files:**
- Create: `Pits/Services/RemotePricing.swift`
- Create: `PitsTests/RemotePricingTests.swift`

- [ ] **B1.1: Write the failing test**

Create `/Users/jifarris/Projects/pits/PitsTests/RemotePricingTests.swift`:

```swift
import XCTest
@testable import Pits

final class RemotePricingTests: XCTestCase {
    /// LiteLLM's documented JSON shape: per-token costs as numbers, with
    /// `litellm_provider == "anthropic"` for the entries we care about.
    func test_parse_extractsAnthropicClaudeEntries() throws {
        let json = """
        {
          "claude-opus-4-7": {
            "litellm_provider": "anthropic",
            "input_cost_per_token": 5e-6,
            "output_cost_per_token": 25e-6,
            "cache_read_input_token_cost": 5e-7,
            "cache_creation_input_token_cost": 6.25e-6
          },
          "anthropic.claude-opus-4-7": {
            "litellm_provider": "bedrock_converse",
            "input_cost_per_token": 5e-6,
            "output_cost_per_token": 25e-6,
            "cache_read_input_token_cost": 5e-7,
            "cache_creation_input_token_cost": 6.25e-6
          },
          "gpt-5": {
            "litellm_provider": "openai",
            "input_cost_per_token": 1e-6
          }
        }
        """.data(using: .utf8)!
        let parsed = RemotePricing.parse(jsonData: json)
        XCTAssertEqual(parsed.count, 1)
        guard let r = parsed["claude-opus-4-7"] else { return XCTFail("missing opus-4-7") }
        XCTAssertEqual(r.base, 5.0, accuracy: 0.0001)
        XCTAssertEqual(r.output, 25.0, accuracy: 0.0001)
        XCTAssertEqual(r.cacheRead, 0.5, accuracy: 0.0001)
        XCTAssertEqual(r.cacheWrite5m, 6.25, accuracy: 0.0001)
        XCTAssertEqual(r.cacheWrite1h, 10.0, accuracy: 0.0001)  // derived = base*2
    }

    /// Entries missing any required cost field are silently skipped — we'd
    /// rather use the bundled fallback than guess.
    func test_parse_skipsEntriesMissingRequiredField() {
        let json = """
        {
          "claude-opus-4-7": {
            "litellm_provider": "anthropic",
            "input_cost_per_token": 5e-6
          }
        }
        """.data(using: .utf8)!
        XCTAssertTrue(RemotePricing.parse(jsonData: json).isEmpty)
    }

    /// Date-suffixed names normalize to the canonical name, matching what
    /// Pricing.normalizeModel does on the JSONL side.
    func test_parse_normalizesDateSuffixedKeys() {
        let json = """
        {
          "claude-haiku-4-5-20251001": {
            "litellm_provider": "anthropic",
            "input_cost_per_token": 1e-6,
            "output_cost_per_token": 5e-6,
            "cache_read_input_token_cost": 1e-7,
            "cache_creation_input_token_cost": 1.25e-6
          }
        }
        """.data(using: .utf8)!
        let parsed = RemotePricing.parse(jsonData: json)
        XCTAssertNotNil(parsed["claude-haiku-4-5"])
        XCTAssertNil(parsed["claude-haiku-4-5-20251001"])
    }

    /// Malformed JSON returns empty — caller falls back to the bundled table.
    func test_parse_returnsEmptyForMalformedJSON() {
        XCTAssertTrue(RemotePricing.parse(jsonData: "not json".data(using: .utf8)!).isEmpty)
    }
}
```

- [ ] **B1.2: Verify the test fails**

```bash
cd /Users/jifarris/Projects/pits
xcodegen generate
xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" -only-testing:PitsTests/RemotePricingTests test 2>&1 | tail -8
```

Expected: build error — `Cannot find 'RemotePricing' in scope`.

- [ ] **B1.3: Implement `RemotePricing`**

Create `/Users/jifarris/Projects/pits/Pits/Services/RemotePricing.swift`:

```swift
import Foundation
import os.log

/// Fetches model rates from LiteLLM's public pricing JSON and parses the
/// Anthropic-direct entries into `Pricing.Rates`. The 1h cache rate is not
/// in LiteLLM — derived locally as `base * 2.0` per Anthropic's docs.
enum RemotePricing {
    static let url = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    static let timeoutSeconds: TimeInterval = 5

    private static let log = OSLog(subsystem: "net.farriswheel.Pits", category: "RemotePricing")

    /// Fetch + parse. Returns empty on any failure (network, HTTP error,
    /// malformed JSON). Caller is expected to overlay the result onto a
    /// bundled fallback table.
    static func fetch(session: URLSession = .shared) async -> [String: Pricing.Rates] {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeoutSeconds
        do {
            let (data, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                os_log("LiteLLM HTTP %d", log: log, type: .info, http.statusCode)
                return [:]
            }
            return parse(jsonData: data)
        } catch {
            os_log("LiteLLM fetch failed: %{public}@", log: log, type: .info, String(describing: error))
            return [:]
        }
    }

    /// Pure parser — split out so tests don't need to hit the network.
    static func parse(jsonData: Data) -> [String: Pricing.Rates] {
        guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return [:]
        }
        var result: [String: Pricing.Rates] = [:]
        for (rawName, value) in obj {
            guard let entry = value as? [String: Any] else { continue }
            guard (entry["litellm_provider"] as? String) == "anthropic" else { continue }
            guard let normalized = Pricing.normalizeModel(rawName) else { continue }
            // Restrict to Claude families we care about.
            guard normalized.range(of: #"^claude-(opus|sonnet|haiku)-\d"#,
                                   options: .regularExpression) != nil else { continue }
            guard let inputPer = entry["input_cost_per_token"] as? Double,
                  let outputPer = entry["output_cost_per_token"] as? Double,
                  let cacheReadPer = entry["cache_read_input_token_cost"] as? Double,
                  let cacheCreationPer = entry["cache_creation_input_token_cost"] as? Double
            else { continue }
            let base = inputPer * 1_000_000
            // Last-write-wins for duplicate normalized names — prices are
            // identical across the duplicates so this is safe.
            result[normalized] = Pricing.Rates(
                base: base,
                cacheWrite5m: cacheCreationPer * 1_000_000,
                cacheWrite1h: base * 2.0,  // not in LiteLLM; derived per Anthropic docs
                cacheRead: cacheReadPer * 1_000_000,
                output: outputPer * 1_000_000
            )
        }
        return result
    }
}
```

- [ ] **B1.4: Run tests**

```bash
xcodegen generate
xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" -only-testing:PitsTests/RemotePricingTests test 2>&1 | tail -5
```

Expected: TEST SUCCEEDED, 4 tests pass.

- [ ] **B1.5: Commit**

```bash
git add Pits/Services/RemotePricing.swift PitsTests/RemotePricingTests.swift
git commit -m "feat(pricing): RemotePricing fetches Anthropic rates from LiteLLM JSON"
```

### Task B2: Make `Pricing.table` mutable + overlay-able

**Files:**
- Modify: `Pits/Models/Pricing.swift`
- Modify: `PitsTests/PricingTests.swift`

- [ ] **B2.1: Add a failing overlay test**

Append to `PitsTests/PricingTests.swift` (inside the existing class):

```swift
func test_overlay_updatesExistingRates() {
    // Save then restore so other tests don't see the mutation.
    let snapshot = Pricing.table
    defer { Pricing.replaceTable(with: snapshot) }

    let updated = Pricing.Rates(base: 99.0, cacheWrite5m: 99.0, cacheWrite1h: 99.0,
                                 cacheRead: 99.0, output: 99.0)
    Pricing.overlay(["claude-opus-4-7": updated])
    XCTAssertEqual(Pricing.rates(for: "claude-opus-4-7")?.base, 99.0)
}

func test_overlay_addsBrandNewModels() {
    let snapshot = Pricing.table
    defer { Pricing.replaceTable(with: snapshot) }

    let novel = Pricing.Rates(base: 7.0, cacheWrite5m: 8.75, cacheWrite1h: 14.0,
                               cacheRead: 0.7, output: 35.0)
    Pricing.overlay(["claude-opus-5": novel])
    XCTAssertEqual(Pricing.rates(for: "claude-opus-5")?.base, 7.0)
}
```

- [ ] **B2.2: Run, verify failure**

Expected: `Pricing.overlay` and `Pricing.replaceTable` don't exist.

- [ ] **B2.3: Make the table mutable + add overlay/replace helpers**

In `Pits/Models/Pricing.swift`, change `static let table: [String: Rates] = [...]` to:

```swift
    /// Mutable so `RemotePricing` can overlay fetched rates at app start.
    /// The bundled values stay as a fallback for models LiteLLM hasn't
    /// listed yet (or when the fetch fails entirely).
    private(set) static var table: [String: Rates] = bundledTable

    private static let bundledTable: [String: Rates] = [
        "claude-opus-4-7":   rates(input: 5.00,  output: 25.00),
        // ... (rest of the existing entries unchanged)
    ]

    /// Overlay fetched rates onto the current table — fetched values win,
    /// existing entries we don't have a fetched rate for are preserved.
    static func overlay(_ fetched: [String: Rates]) {
        for (model, rate) in fetched {
            table[model] = rate
        }
    }

    /// Replace the entire table. Used by tests to restore state.
    static func replaceTable(with newTable: [String: Rates]) {
        table = newTable
    }
```

- [ ] **B2.4: Run tests**

```bash
xcodebuild ... -only-testing:PitsTests/PricingTests test
```

Expected: all PricingTests pass (including the two new ones).

- [ ] **B2.5: Commit**

```bash
git add Pits/Models/Pricing.swift PitsTests/PricingTests.swift
git commit -m "feat(pricing): make table overlay-able for runtime rate updates"
```

### Task B3: Wire `RemotePricing` into app startup with daily caching

**Files:**
- Modify: `Pits/PitsApp.swift`
- Create: `Pits/Services/PricingCache.swift`
- Create: `PitsTests/PricingCacheTests.swift`

- [ ] **B3.1: Add a failing test for the cache file format**

Create `/Users/jifarris/Projects/pits/PitsTests/PricingCacheTests.swift`:

```swift
import XCTest
@testable import Pits

final class PricingCacheTests: XCTestCase {
    private var tmpURL: URL!

    override func setUpWithError() throws {
        tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pits-pricing-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpURL)
    }

    func test_saveThenLoad_roundtrips() throws {
        let rates = ["claude-opus-4-7": Pricing.Rates(
            base: 5.0, cacheWrite5m: 6.25, cacheWrite1h: 10.0,
            cacheRead: 0.5, output: 25.0
        )]
        try PricingCache.save(rates: rates, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
                              to: tmpURL)
        let loaded = PricingCache.load(from: tmpURL)
        XCTAssertEqual(loaded?.rates["claude-opus-4-7"]?.base, 5.0)
        XCTAssertEqual(loaded?.fetchedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func test_load_returnsNilForMissingFile() {
        XCTAssertNil(PricingCache.load(from: tmpURL))
    }

    func test_load_returnsNilForCorruptFile() throws {
        try "not json".write(to: tmpURL, atomically: true, encoding: .utf8)
        XCTAssertNil(PricingCache.load(from: tmpURL))
    }
}
```

- [ ] **B3.2: Verify failure**

Expected: `Cannot find 'PricingCache' in scope`.

- [ ] **B3.3: Implement `PricingCache`**

Make `Pricing.Rates` `Codable` first — in `Pits/Models/Pricing.swift`, change:

```swift
struct Rates: Equatable {
```

to:

```swift
struct Rates: Equatable, Codable {
```

Then create `/Users/jifarris/Projects/pits/Pits/Services/PricingCache.swift`:

```swift
import Foundation

/// On-disk cache of the LiteLLM-derived rates so we don't refetch on every
/// launch. One file at `~/Library/Caches/pricing.json`. TTL is enforced by
/// the caller, not the cache itself — `load()` always returns the file and
/// the caller decides whether `fetchedAt` is stale.
enum PricingCache {
    struct Snapshot: Codable, Equatable {
        let rates: [String: Pricing.Rates]
        let fetchedAt: Date
    }

    /// Default file location. Sandboxed apps land at the same spot inside
    /// the container — `urls(for:.cachesDirectory, in:.userDomainMask)`
    /// returns the right path either way.
    static var defaultURL: URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("pricing.json")
    }

    static func save(rates: [String: Pricing.Rates], fetchedAt: Date, to url: URL) throws {
        let snap = Snapshot(rates: rates, fetchedAt: fetchedAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snap)
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func load(from url: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }
}
```

- [ ] **B3.4: Wire up app startup — load cached rates synchronously, then refetch in background if stale**

In `Pits/PitsApp.swift`, inside `init()` (after the existing observer setup, before the `_store = StateObject(...)` assignment if possible — but `_store` needs the rates loaded first), add:

```swift
        // Hydrate Pricing.table from the on-disk cache before the store
        // builds its first snapshot, so totals render with fetched rates
        // on warm launches.
        if let snap = PricingCache.load(from: PricingCache.defaultURL) {
            Pricing.overlay(snap.rates)
        }
```

Place that line above `let s = ConversationStore(...)`.

Then add a background refresh task at the end of `init()`:

```swift
        // Refresh from LiteLLM in the background. If the on-disk snapshot
        // is younger than 24h we still re-overlay (cheap, no UI blip);
        // if older we refetch and persist.
        Task.detached(priority: .background) { [weak s] in
            let cacheURL = PricingCache.defaultURL
            let cached = PricingCache.load(from: cacheURL)
            let isStale = cached.map { Date().timeIntervalSince($0.fetchedAt) > 86_400 } ?? true
            if isStale {
                let fetched = await RemotePricing.fetch()
                guard !fetched.isEmpty else { return }
                try? PricingCache.save(rates: fetched, fetchedAt: Date(), to: cacheURL)
                await MainActor.run {
                    Pricing.overlay(fetched)
                    s?.rebuildSnapshot()
                }
            }
        }
```

- [ ] **B3.5: Run all tests**

```bash
xcodebuild ... test 2>&1 | grep -E "Executed [0-9]+ tests, with [0-9]+ failures" | tail -1
```

Expected: 0 failures.

- [ ] **B3.6: Manual smoke test**

```bash
bash scripts/run.sh
# Wait ~10 seconds for the fetch to complete.
ls -la ~/Library/Caches/pricing.json
# Should exist, contain Anthropic models with sensible rates.
python3 -c "
import json
d = json.load(open('/Users/jifarris/Library/Caches/pricing.json'))
print('Models:', sorted(d['rates'].keys()))
print('Opus 4.7:', d['rates'].get('claude-opus-4-7'))
"
```

Expected: file exists, contains opus-4-7 with `base=5.0`, `cacheWrite1h=10.0`.

- [ ] **B3.7: Commit**

```bash
git add Pits/Services/PricingCache.swift Pits/PitsApp.swift Pits/Models/Pricing.swift PitsTests/PricingCacheTests.swift
git commit -m "feat(pricing): hydrate Pricing.table from LiteLLM at launch (24h cache)"
```

### Task B4: Branch + PR

- [ ] **B4.1: Push and open the PR**

```bash
git checkout -b v0.1.0-litellm-pricing
git push -u origin v0.1.0-litellm-pricing
gh pr create --title "v0.1.0: fetch model pricing from LiteLLM (24h cache)" \
  --body "Stops requiring a code change every time a new Claude model launches. \`Pricing.table\` becomes overlay-able; on launch we synchronously hydrate from \`~/Library/Caches/pricing.json\`, then refetch from LiteLLM in the background if the snapshot is older than 24h. Fetched rates are merged onto the bundled fallback table — bundled stays as the safety net for offline launches and for models LiteLLM hasn't listed yet.

The 1h cache write rate (2× base) is derived locally; LiteLLM only models a single \`cache_creation_input_token_cost\` (= 1.25× base, the 5m rate). Per-request 5m/1h attribution is unchanged from PR #9.

## Test plan

- [x] All unit tests pass (incl. new \`RemotePricingTests\`, \`PricingCacheTests\`, overlay tests)
- [x] Debug build succeeds
- [x] Manual: launch, wait ~10s, confirm \`~/Library/Caches/pricing.json\` is written with opus-4-7 priced and 1h rates derived
- [ ] Manual: kill network, delete cache, launch, confirm app still renders with bundled fallback table"
```

---

## Self-review

- **Spec coverage:**
  - LiteLLM fetch in both apps → A2 + B1/B3 ✓
  - 5m/1h cache split in gh-claude-costs → A3 ✓ (Pits already has it from v0.0.6)
  - Bundled fallback in both → A1 + B2 ✓
  - Daily caching in Pits, runtime fetch in gh-claude-costs (per user spec) → B3 + A2 ✓
  - Tests for both → A4 + B1/B2/B3 ✓
- **Placeholder scan:** No "TBD"/"add error handling"/"similar to" — all code is concrete. Template.html edit in A3.5 has a "read the actual structure first" note because we genuinely need to see the live JS — that's a directive to the implementer, not a placeholder. ✓
- **Type consistency:** `cache_write_5m` / `cache_write_1h` keys used everywhere (gh-claude-costs Python). `cacheWrite5m` / `cacheWrite1h` (Swift Pits, matching v0.0.6 PR #9). `Pricing.Rates` field set unchanged from PR #9. `RemotePricing.fetch` async, `parse(jsonData:)` sync — both used consistently. `PricingCache.Snapshot { rates, fetchedAt }` defined in B3.3, used in B3.4. ✓
