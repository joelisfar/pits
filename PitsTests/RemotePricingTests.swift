import XCTest
@testable import Pits

final class RemotePricingTests: XCTestCase {
    /// LiteLLM's documented JSON shape: per-token costs as numbers, with
    /// `litellm_provider == "anthropic"` for the entries we care about.
    func test_parse_extractsAnthropicClaudeEntries() {
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
