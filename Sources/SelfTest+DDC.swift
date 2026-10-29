import Cocoa

// 多外接屏 DDC 映射的自检。由负责该功能的人填写；不要在 main.swift 里加这部分断言。
// 只测纯函数 + 只读枚举；不发任何 DDC/I²C 读写，断言不依赖本机是否接了外接屏。
extension SelfTest {
    static func ddcChecks() -> [SelfTestCheck] {
        var out: [SelfTestCheck] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            out.append(SelfTestCheck(name: name, ok: ok, detail: detail))
        }
        typealias B = DisplayBrightness
        typealias ID = B.DisplayIdentity
        typealias Ext = B.ExternalDisplay
        let gsm: UInt32 = 0x1E6D, dell: UInt32 = 0x10AC

        // EDID 字段解析
        check("ddc: PNP vendor GSM", ID.pnpVendor("GSM") == gsm && ID.pnpVendor("del") == dell
              && ID.pnpString(gsm) == "GSM" && ID.pnpVendor("G5M") == nil && ID.pnpVendor("GSMX") == nil)
        let attrs: [String: Any] = ["ProductAttributes": ["ManufacturerID": "GSM", "ProductID": 0x5B09,
                                                          "SerialNumber": 123456, "ProductName": "LG HDR 4K"]]
        check("ddc: identity from DisplayAttributes",
              B.identity(displayAttributes: attrs, edidUUID: nil) == ID(vendor: gsm, model: 0x5B09, serial: 123456))
        check("ddc: identity numeric vendor, no serial",
              B.identity(displayAttributes: ["ProductAttributes": ["ManufacturerID": 4268, "ProductID": 41_234]],
                         edidUUID: nil) == ID(vendor: dell, model: 41_234, serial: 0))
        check("ddc: identity from EDID UUID",
              B.identity(displayAttributes: nil, edidUUID: "10AC12A1-0000-0000-2A1E-0104B53C2278")
                == ID(vendor: dell, model: 0xA112, serial: 0))
        check("ddc: identity unknown", B.identity(displayAttributes: nil, edidUUID: nil) == nil
              && B.identity(displayAttributes: ["Foo": 1], edidUUID: "") == nil)

        // IORegistry 端口名
        check("ddc: port key from names",
              B.portKey(names: ["AppleCLCD2", "dispext0", "arm-io"]) == "ext0"
              && B.portKey(names: ["DCPAVServiceProxy", "dispext1:dcpav-service-epic:0", "AFKDCPEXT1Endpoint5",
                                   "DCPEXT1Endpoint5", "RTBuddy(DCPEXT1)", "iop-dcpext1-nub", "dcpext1"]) == "ext1"
              && B.portKey(names: ["DCPAVServiceProxy", "disp0:dcpav-service-epic:0"]) == "0"
              && B.portKey(names: ["x", "dcp"]) == "0" && B.portKey(names: ["AppleCLCD2", "disp0"]) == "0")
        check("ddc: port key ignores look-alikes",
              B.portKey(names: ["dcp-sac-controller", "dcpext0-expert", "dart-dispext0", "display-crossbar0"]) == nil
              && B.portKey(names: []) == nil)

        // 匹配
        let lgA = ID(vendor: gsm, model: 0x5B09, serial: 111)
        let lgB = ID(vendor: gsm, model: 0x5B09, serial: 222)
        let dellU = ID(vendor: dell, model: 0xA112, serial: 0)
        let lgNoSerial = ID(vendor: gsm, model: 0x5B09, serial: 0)
        do {
            let m = B.matchServices([nil], [Ext(id: 7, identity: dellU)])
            check("ddc map: single external direct", m == [B.ServiceMatch(service: 0, display: 7, basis: .single)]
                  && !m[0].inferred, "\(m)")
        }
        do {
            // 注册表顺序与 CG 顺序相反，靠序列号对上
            let m = B.matchServices([lgB, lgA], [Ext(id: 10, identity: lgA), Ext(id: 11, identity: lgB)])
            check("ddc map: serial exact", m == [B.ServiceMatch(service: 0, display: 11, basis: .serial),
                                                 B.ServiceMatch(service: 1, display: 10, basis: .serial)], "\(m)")
        }
        do {
            let m = B.matchServices([dellU, lgNoSerial], [Ext(id: 20, identity: lgNoSerial), Ext(id: 21, identity: dellU)])
            check("ddc map: vendor+model without serial",
                  m == [B.ServiceMatch(service: 0, display: 21, basis: .vendorModel),
                        B.ServiceMatch(service: 1, display: 20, basis: .vendorModel)] && m.allSatisfy { !$0.inferred }, "\(m)")
        }
        do {
            let m = B.matchServices([lgNoSerial, lgNoSerial, dellU],
                                    [Ext(id: 30, identity: dellU), Ext(id: 31, identity: lgNoSerial),
                                     Ext(id: 32, identity: lgNoSerial)])
            check("ddc map: identical twins inferred by order",
                  m == [B.ServiceMatch(service: 0, display: 31, basis: .order),
                        B.ServiceMatch(service: 1, display: 32, basis: .order),
                        B.ServiceMatch(service: 2, display: 30, basis: .vendorModel)]
                  && m[0].inferred && !m[2].inferred, "\(m)")
        }
        do {
            // 已知身份但对不上任何显示器、另一服务身份未知且数量不等：不硬配
            let other = ID(vendor: dell, model: 1, serial: 5)
            let m = B.matchServices([other, nil], [Ext(id: 40, identity: lgA), Ext(id: 41, identity: lgB)])
            check("ddc map: no match → empty", m.isEmpty, "\(m)")
            let p = B.DDC.plan(targets: [40], matches: m, serviceCount: 2)
            check("ddc map: unmatched target falls back to all", p.services == [0, 1] && p.fallback)
            check("ddc map: no services, no displays", B.matchServices([], []).isEmpty
                  && B.DDC.plan(targets: [1], matches: [], serviceCount: 0).services.isEmpty)
        }
        do {
            let m = B.matchServices([nil, nil], [Ext(id: 50, identity: lgA), Ext(id: 51, identity: dellU)])
            check("ddc map: unknown attributes inferred by order",
                  m.map(\.display) == [50, 51] && m.allSatisfy(\.inferred), "\(m)")
        }

        // 计划：光标所在屏只调一块；external 调全部已映射的
        do {
            let m = B.matchServices([lgA, dellU, lgB],
                                    [Ext(id: 60, identity: lgB), Ext(id: 61, identity: lgA), Ext(id: 62, identity: dellU)])
            let cursor = B.DDC.plan(targets: [62], matches: m, serviceCount: 3)
            check("ddc plan: cursor display only", cursor.services == [1] && !cursor.fallback, "\(cursor)")
            let all = B.DDC.plan(targets: [60, 61, 62], matches: m, serviceCount: 3)
            check("ddc plan: external = every mapped service", all.services == [0, 1, 2] && !all.fallback, "\(all)")
            let partial = B.DDC.plan(targets: [61, 99], matches: m, serviceCount: 3)
            check("ddc plan: one unmapped target → fallback all", partial.services == [0, 1, 2] && partial.fallback)
        }

        // 缓存键按显示器身份
        check("ddc cache: keyed by identity",
              B.cacheKey(lgA, display: 60, service: 0) == B.cacheKey(lgA, display: 61, service: 2)
              && B.cacheKey(lgNoSerial, display: 31, service: 0) != B.cacheKey(lgNoSerial, display: 32, service: 1)
              && B.cacheKey(nil, display: 31, service: 0) != B.cacheKey(nil, display: nil, service: 0))

        // 只读枚举：不依赖本机有没有外接屏，只要求不崩、报告结构完整、两次结果一致
        let report = B.DDC.probeReport()
        check("ddc probe: read-only report", report.contains { $0.hasPrefix("external DDC services:") }
              && report.contains("mapping:") && B.DDC.externalServices().count == B.DDC.externalServices().count,
              report.joined(separator: " | "))
        // 真机回包（小米 27A1 / 优派 VX2478）：单发请求得到空消息，双发得到正常回包
        let null: [UInt8] = [0x6E, 0x80, 0xBE, 0x6E, 0xA3, 0x4E, 0x58, 0xEF, 0xD2, 0x78, 0x6D, 0x3B]
        let mi: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x38, 0xF8, 0x3B]
        let vsc: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x64, 0xA4, 0x90]
        check("ddc: null-message reply is not a reading", B.DDC.parseReply(null, vcp: 0x10) == nil)
        check("ddc: real replies parse (Mi 56/100, ViewSonic 100/100)",
              B.DDC.parseReply(mi, vcp: 0x10).map { [$0.current, $0.max] } == [56, 100]
              && B.DDC.parseReply(vsc, vcp: 0x10).map { [$0.current, $0.max] } == [100, 100])
        return out
    }
}
