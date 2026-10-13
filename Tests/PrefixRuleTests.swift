import XCTest
@testable import Shared

/// 号段规则与采样生成器测试。
///
/// 覆盖 PrefixRule 验证、号码范围计算、预算分配、采样生成、合并去重等核心逻辑。
/// 这些测试在 Mac 上跑，不需要模拟器或签名。
final class PrefixRuleTests: XCTestCase {

    // MARK: - PrefixRule 验证

    func testValidateRejectsEmptyPrefix() {
        let (normalized, error) = PrefixRule.validate("")
        XCTAssertNil(normalized)
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("空"))
    }

    func testValidateRejectsNonDigits() {
        let (normalized, error) = PrefixRule.validate("40a")
        XCTAssertNil(normalized)
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("数字"))
    }

    func testValidateRejectsTooShort() {
        let (normalized, error) = PrefixRule.validate("4")
        XCTAssertNil(normalized)
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("至少"))
    }

    func testValidateRejectsTooLong() {
        let (normalized, error) = PrefixRule.validate("123456")
        XCTAssertNil(normalized)
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("最多"))
    }

    func testValidateRejectsLeadingZero() {
        let (normalized, error) = PrefixRule.validate("010")
        XCTAssertNil(normalized)
        XCTAssertNotNil(error)
        XCTAssertTrue(error!.contains("0"))
    }

    func testValidateAcceptsValidPrefixes() {
        let (normalized1, error1) = PrefixRule.validate("400")
        XCTAssertNil(error1)
        XCTAssertEqual(normalized1, "400")

        let (normalized2, error2) = PrefixRule.validate("170")
        XCTAssertNil(error2)
        XCTAssertEqual(normalized2, "170")

        let (normalized3, error3) = PrefixRule.validate("95")
        XCTAssertNil(error3)
        XCTAssertEqual(normalized3, "95")
    }

    func testValidateTrimsWhitespace() {
        let (normalized, error) = PrefixRule.validate("  400  ")
        XCTAssertNil(error)
        XCTAssertEqual(normalized, "400")
    }

    // MARK: - 号码范围计算

    func testNumberRangeFor400() {
        let rule = PrefixRule(prefix: "400")
        let (start, count) = rule.numberRange()

        // 400 号段：国内部分 10 位（400 + 7 位），共 10^7 = 1000 万
        XCTAssertEqual(start, 864000000000)
        XCTAssertEqual(count, 10_000_000)
    }

    func testNumberRangeFor170() {
        let rule = PrefixRule(prefix: "170")
        let (start, count) = rule.numberRange()

        // 170 号段：国内部分 11 位（手机号），共 10^8 = 1 亿
        XCTAssertEqual(start, 8617000000000)
        XCTAssertEqual(count, 100_000_000)
    }

    func testNumberRangeFor95() {
        let rule = PrefixRule(prefix: "95")
        let (start, count) = rule.numberRange()

        // 95 号段：国内部分 10 位（非 1 开头），共 10^8 = 1 亿
        XCTAssertEqual(start, 869500000000)
        XCTAssertEqual(count, 100_000_000)
    }

    func testEstimatedTotalDescription() {
        XCTAssertEqual(PrefixRule(prefix: "400").estimatedTotalDescription, "1000万")
        XCTAssertEqual(PrefixRule(prefix: "170").estimatedTotalDescription, "1亿")
        XCTAssertEqual(PrefixRule(prefix: "4001").estimatedTotalDescription, "100万")
    }

    // MARK: - 预算分配

    func testAllocateBudgetDistributesProportionally() {
        let rules = [
            PrefixRule(prefix: "400", level: .block),
            PrefixRule(prefix: "170", level: .block),
        ]
        let allocations = PrefixNumberGenerator.allocateBudget(rules: rules, availableBudget: 50_000)

        // 400 号段 1000 万，170 号段 1 亿，比例 1:10
        // 400 应得约 50000 * 10M / 110M ≈ 4545
        // 170 应得约 50000 * 100M / 110M ≈ 45454
        let alloc400 = allocations.first { $0.prefix == "400" }?.allocation ?? 0
        let alloc170 = allocations.first { $0.prefix == "170" }?.allocation ?? 0

        XCTAssertEqual(alloc400, 4545, accuracy: 100)
        XCTAssertEqual(alloc170, 45454, accuracy: 100)
        XCTAssertEqual(alloc400 + alloc170, 50_000, accuracy: 200)
    }

    func testAllocateBudgetSkipsDisabledRules() {
        let rules = [
            PrefixRule(prefix: "400", level: .block, isEnabled: false),
            PrefixRule(prefix: "170", level: .block),
        ]
        let allocations = PrefixNumberGenerator.allocateBudget(rules: rules, availableBudget: 50_000)

        XCTAssertEqual(allocations.count, 1)
        XCTAssertEqual(allocations.first?.prefix, "170")
    }

    func testAllocateBudgetHandlesOverlappingPrefixes() {
        // "9" 和 "95" 重叠，长前缀 "95" 应当优先
        let rules = [
            PrefixRule(prefix: "9"),
            PrefixRule(prefix: "95"),
        ]
        let allocations = PrefixNumberGenerator.allocateBudget(rules: rules, availableBudget: 50_000)

        // "95" 取代 "9"，只保留 "95"
        XCTAssertEqual(allocations.count, 1)
        XCTAssertEqual(allocations.first?.prefix, "95")
    }

    func testAllocateBudgetReturnsEmptyForZeroBudget() {
        let rules = [PrefixRule(prefix: "400")]
        let allocations = PrefixNumberGenerator.allocateBudget(rules: rules, availableBudget: 0)
        XCTAssertTrue(allocations.isEmpty)
    }

    func testAllocateBudgetReturnsEmptyForNoEnabledRules() {
        let rules = [PrefixRule(prefix: "400", isEnabled: false)]
        let allocations = PrefixNumberGenerator.allocateBudget(rules: rules, availableBudget: 50_000)
        XCTAssertTrue(allocations.isEmpty)
    }

    // MARK: - 采样生成

    func testGenerateSamplesProducesCorrectCount() {
        let rules = [PrefixRule(prefix: "400", level: .block)]
        let allocations: [(String, Int)] = [("400", 1000)]
        let samples = PrefixNumberGenerator.generateSamples(rules: rules, allocations: allocations)

        XCTAssertEqual(samples.count, 1000)
    }

    func testGenerateSamplesAreStrictlyAscending() {
        let rules = [PrefixRule(prefix: "400", level: .block)]
        let allocations: [(String, Int)] = [("400", 1000)]
        let samples = PrefixNumberGenerator.generateSamples(rules: rules, allocations: allocations)

        var previous: Int64 = -1
        for number in samples {
            XCTAssertGreaterThan(number, previous)
            previous = number
        }
    }

    func testGenerateSamplesAreWithinRange() {
        let rules = [PrefixRule(prefix: "400", level: .block)]
        let allocations: [(String, Int)] = [("400", 1000)]
        let samples = PrefixNumberGenerator.generateSamples(rules: rules, allocations: allocations)

        let (start, count) = rules[0].numberRange()
        let end = start + count

        for number in samples {
            XCTAssertGreaterThanOrEqual(number, start)
            XCTAssertLessThan(number, end)
        }
    }

    func testGenerateIdentificationSamplesIncludesLabels() {
        let rules = [PrefixRule(prefix: "400", level: .label, label: "推销")]
        let allocations: [(String, Int)] = [("400", 100)]
        let samples = PrefixNumberGenerator.generateIdentificationSamples(rules: rules, allocations: allocations)

        XCTAssertEqual(samples.count, 100)
        XCTAssertTrue(samples.allSatisfy { $0.label == "推销" })
    }

    func testGenerateIdentificationSamplesUsesDefaultLabel() {
        let rules = [PrefixRule(prefix: "400", level: .label, label: "")]
        let allocations: [(String, Int)] = [("400", 100)]
        let samples = PrefixNumberGenerator.generateIdentificationSamples(rules: rules, allocations: allocations)

        XCTAssertTrue(samples.allSatisfy { $0.label == ListTextParser.defaultLabel })
    }

    // MARK: - 合并去重

    func testMergeBlockingNumbersSortsAndDeduplicates() {
        let manual: [Int64] = [864008208820, 8613800138000]
        let generated: [Int64] = [864000000000, 864008208820, 8613900139000]
        let merged = PrefixNumberGenerator.mergeBlockingNumbers(manual: manual, generated: generated)

        XCTAssertEqual(merged, [864000000000, 864008208820, 8613800138000, 8613900139000])
        XCTAssertEqual(merged, merged.sorted())
        XCTAssertEqual(Set(merged).count, merged.count)
    }

    func testMergeBlockingNumbersHandlesEmptyInputs() {
        let merged1 = PrefixNumberGenerator.mergeBlockingNumbers(manual: [], generated: [1, 2, 3])
        XCTAssertEqual(merged1, [1, 2, 3])

        let merged2 = PrefixNumberGenerator.mergeBlockingNumbers(manual: [1, 2, 3], generated: [])
        XCTAssertEqual(merged2, [1, 2, 3])

        let merged3 = PrefixNumberGenerator.mergeBlockingNumbers(manual: [], generated: [])
        XCTAssertTrue(merged3.isEmpty)
    }

    func testMergeIdentificationEntriesFiltersBlockingNumbers() {
        let manual: [(Int64, String)] = [(8613800138000, "推销"), (8613900139000, "诈骗")]
        let generated: [(Int64, String)] = [(8613700137000, "骚扰")]
        let blocking: [Int64] = [8613800138000, 864000000000]

        let merged = PrefixNumberGenerator.mergeIdentificationEntries(
            manual: manual,
            generated: generated,
            blockingNumbers: blocking
        )

        // 8613800138000 在拦截列表中，应当被排除
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.contains { $0.number == 8613700137000 })
        XCTAssertTrue(merged.contains { $0.number == 8613900139000 })
        XCTAssertFalse(merged.contains { $0.number == 8613800138000 })
    }

    // MARK: - 集成场景

    func testEndToEndPrefixGeneration() {
        // 模拟真实场景：400 号段拦截，预算 45000
        let rules = [PrefixRule(prefix: "400", level: .block)]
        let budget = 45_000

        let allocations = PrefixNumberGenerator.allocateBudget(rules: rules, availableBudget: budget)
        XCTAssertEqual(allocations.count, 1)
        XCTAssertEqual(allocations.first?.prefix, "400")

        let samples = PrefixNumberGenerator.generateSamples(rules: rules, allocations: allocations)
        XCTAssertEqual(samples.count, allocations.first?.allocation ?? 0)

        // 采样号码应当在 400 号段范围内
        let (start, count) = rules[0].numberRange()
        let end = start + count
        XCTAssertTrue(samples.allSatisfy { $0 >= start && $0 < end })

        // 采样号码应当严格升序
        XCTAssertEqual(samples, samples.sorted())
        XCTAssertEqual(Set(samples).count, samples.count)
    }
}
