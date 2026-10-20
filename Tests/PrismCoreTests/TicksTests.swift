import Foundation
import Testing
@testable import PrismCore

@Suite("Ticks 时间换算与格式化")
struct TicksTests {
    @Test("tick 常数：1 秒 = 10,000,000 ticks")
    func constants() {
        #expect(Ticks.ticksPerSecond == 10_000_000)
        #expect(Ticks(seconds: 1).rawValue == 10_000_000)
        #expect(Ticks(seconds: 0.001).rawValue == 10_000)
        #expect(Ticks(10_000_000).seconds == 1.0)
        #expect(Ticks(10_000_000).timeInterval == 1.0)
    }

    @Test(
        "formatted 覆盖 0 / 59s / 1h / 跨小时边界 / 负数",
        arguments: [
            (Int64(0), "0:00"),
            (10_000_000, "0:01"),
            (590_000_000, "0:59"),
            (600_000_000, "1:00"),
            (3_599_000_000, "5:59"),
            (3_600_000_000, "6:00"),
            (50_250_000_000, "1:23:45"),
            (36_000_000_000, "1:00:00"),
            (360_000_000_000, "10:00:00"),
            (-5_000_000_000, "0:00"),
            (-1, "0:00")
        ]
    )
    func formatted(rawValue: Int64, expected: String) {
        #expect(Ticks(rawValue).formatted == expected)
    }

    @Test("remainingFormatted 负值带减号，正值不带")
    func remainingFormatted() {
        #expect(Ticks(seconds: -5_025).remainingFormatted == "-1:23:45")
        #expect(Ticks(seconds: -5_025).formatted == "0:00")
        #expect(Ticks(seconds: -45).remainingFormatted == "-0:45")
        #expect(Ticks(seconds: 45).remainingFormatted == "0:45")
        #expect(Ticks(0).remainingFormatted == "0:00")
    }

    @Test("秒 / tick 互转与加减比较")
    func arithmetic() {
        let a = Ticks(seconds: 90)
        let b = Ticks(seconds: 30)
        #expect((a + b).seconds == 120)
        #expect((a - b).seconds == 60)
        #expect(b < a)
        #expect(a > b)
        #expect(Ticks(seconds: 90) == a)
        #expect(Int64(10_000_000).ticks == Ticks(seconds: 1))
        #expect(Double(90).secondsToTicks == Ticks(seconds: 90))
    }

    @Test("非有限秒数退化为 0，不崩溃")
    func nonFinite() {
        #expect(Ticks(seconds: .nan).rawValue == 0)
        #expect(Ticks(seconds: .infinity).rawValue == 0)
    }

    @Test("Codable 往返：编解码为 Int64 裸值")
    func codableRoundTrip() throws {
        let original = Ticks(seconds: 5_025)
        let data = try JSONEncoder().encode(original)
        #expect(String(decoding: data, as: UTF8.self) == "50250000000")

        let decoded = try JSONDecoder().decode(Ticks.self, from: data)
        #expect(decoded == original)

        // 兼容浮点写法
        let doublePayload = Data("12345.0".utf8)
        #expect(try JSONDecoder().decode(Ticks.self, from: doublePayload).rawValue == 12345)

        // 非法内容抛错而不是崩溃
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Ticks.self, from: Data("\"nope\"".utf8))
        }
    }

    @Test("作为模型字段时的裸值解码")
    func decodesInsideModel() throws {
        struct Holder: Decodable { let RunTimeTicks: Ticks? }
        let json = Data(#"{"RunTimeTicks": 8_100_000_000}"#.replacingOccurrences(of: "_", with: "").utf8)
        let holder = try JSONDecoder().decode(Holder.self, from: json)
        #expect(holder.RunTimeTicks?.formatted == "13:30")
    }
}
