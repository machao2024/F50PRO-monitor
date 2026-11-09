import Foundation
import CryptoKit

enum F50ResponseParser {
    static func parseSMSMessages(_ json: [String: Any]) -> [F50SMSMessage]? {
        guard let rows = json["messages"] as? [[String: Any]] else { return nil }

        return rows.compactMap { row in
            let id = stringValue(row["id"])
            guard !id.isEmpty else { return nil }

            let encodedContent = stringValue(row["content"])
            let decodedContent = Data(base64Encoded: encodedContent, options: .ignoreUnknownCharacters)
                .flatMap { String(data: $0, encoding: .utf8) }

            return F50SMSMessage(
                id: id,
                number: stringValue(row["number"]),
                content: decodedContent ?? encodedContent,
                dateText: formatSMSDate(stringValue(row["date"])),
                tag: stringValue(row["tag"])
            )
        }
    }

    private static func stringValue(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        return String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatSMSDate(_ raw: String) -> String {
        let values = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard values.count >= 6 else { return raw }
        return "\(values[0])-\(values[1])-\(values[2]) \(values[3]):\(values[4]):\(values[5])"
    }

    /// 路由器「自动清零」开关被明确关闭（固定流量包场景）：此时清零日不生效，不应显示重置倒计时。
    static func isAutoTrafficClearDisabled(_ dict: [String: Any]) -> Bool {
        guard let raw = dict["flux_auto_clear_flow_data_switch"] else { return false }
        let value = String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "off" || value == "0"
    }

    static func extractFirstValidResetDay(from dict: [String: Any]) -> Int {
        guard !isAutoTrafficClearDisabled(dict) else { return 0 }
        // 同时覆盖 ZTE 路由器路径的 *_day 键与 UFI 路径归一化后的 *_date 键
        let candidateKeys = [
            "traffic_clear_date",
            "flux_clear_date",
            "data_volume_clear_date",
            "monthly_clear_date",
            "clear_date",
            "data_volume_reset_date",
            "billing_date",
            "data_volume_clear_day",
            "monthly_clear_day",
            "clear_day",
            "data_volume_reset_day",
            "billing_day",
            "reset_day",
            "monthly_reset_day",
            "traffic_clear_day"
        ]
        for key in candidateKeys {
            if let val = dict[key] {
                let day = parseResetDayValue(val)
                if day > 0 && day <= 31 {
                    return day
                }
            }
        }
        return 0
    }

    /// 从清零日取值中提取“日”。支持纯数字日（如 "16"）以及完整日期（如
    /// "2026-08-16" / "2026/8/16" / "2026年8月16日"）。
    private static func parseResetDayValue(_ value: Any) -> Int {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return 0 }

            // 若看起来像完整日期，优先按日期解析并取其日分量
            if trimmed.contains("-") || trimmed.contains("/") || trimmed.contains(".") || trimmed.contains("年") {
                let formats = ["yyyy-MM-dd", "yyyy/M/d", "yyyy.M.d", "yyyy年M月d日"]
                for format in formats {
                    let formatter = DateFormatter()
                    formatter.dateFormat = format
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    if let date = formatter.date(from: trimmed) {
                        let day = Calendar.current.component(.day, from: date)
                        if day > 0 && day <= 31 {
                            return day
                        }
                    }
                }
            }
        }
        return parseInt(value)
    }

    static func parseInt(_ value: Any) -> Int {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let val = Int(trimmed) { return val }
            if let firstNumericPart = string.components(separatedBy: CharacterSet.decimalDigits.inverted).first(where: { !$0.isEmpty }),
               let val = Int(firstNumericPart) {
                return val
            }
        }
        return 0
    }

    static func parseDouble(_ value: Any) -> Double {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let string = value as? String {
            // 先剥 "dBm" 再剥 "dB"，避免把 "dBm" 拆成 "m"
            let clean = string.replacingOccurrences(of: "℃", with: "")
                .replacingOccurrences(of: "%", with: "")
                .replacingOccurrences(of: "dBm", with: "")
                .replacingOccurrences(of: "dB", with: "")
                .trimmingCharacters(in: .whitespaces)
            return Double(clean) ?? 0
        }
        return 0
    }

    /// 信号指标取值：从候选键中依次取第一个可解析为“非零数值”的值。
    /// - 大小写不敏感（部分固件返回 Nr_snr / nr_snr、5g_rsrp / 5G_rsrp 等变体）
    /// - 跳过 null / "0" / 无效值：设备在 NSA/4G 等状态下会把不适用的字段置为
    ///   null 或 0，若用 `??` 链会因首键命中无效值而短路，真实值永远读不到。
    static func firstValidSignalValue(in dict: [String: Any], keys: [String]) -> Double? {
        var lowercased: [String: Any] = [:]
        for (key, value) in dict {
            lowercased[key.lowercased()] = value
        }
        for key in keys {
            guard let value = lowercased[key.lowercased()] else { continue }
            let num = parseDouble(value)
            if num != 0 { return num }
        }
        return nil
    }

    static func parseUInt64(_ value: Any) -> UInt64 {
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        // JSON 数值都是 NSNumber，此分支覆盖纯 Swift UInt64 值（如测试/本地构造）
        if let number = value as? UInt64 {
            return number
        }
        if let number = value as? Int {
            return UInt64(max(0, number))
        }
        if let number = value as? Double {
            return number.isFinite && number >= 0 ? UInt64(number) : 0
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
                let hexStr = String(trimmed.dropFirst(2))
                return UInt64(hexStr, radix: 16) ?? 0
            }
            if let uVal = UInt64(trimmed) {
                return uVal
            }
            if let dVal = Double(trimmed), dVal.isFinite && dVal >= 0 {
                return UInt64(dVal)
            }
            let clean = trimmed.trimmingCharacters(in: CharacterSet.decimalDigits.inverted)
            return UInt64(clean) ?? 0
        }
        return 0
    }

    static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 格式化短信时间字符串：yy;MM;dd;HH;mm;ss;+TZ
    static func formatSMSTime(date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yy;MM;dd;HH;mm;ss"
        let base = formatter.string(from: date)
        let tzOffsetSeconds = timeZone.secondsFromGMT(for: date)
        let tzOffsetHours = tzOffsetSeconds / 3600
        let tzSign = tzOffsetHours >= 0 ? "+" : "-"
        return "\(base);\(tzSign)\(abs(tzOffsetHours))"
    }

    /// 解析 ADB shell 输出：thermal_zone 的 "type:temp" 行、/proc/stat 的 cpu 行、/proc/meminfo 的内存行。
    static func parseLinuxShellMetrics(
        _ output: String,
        previousCPU: (total: Double, idle: Double)?
    ) -> (metrics: [String: Any], cpu: (total: Double, idle: Double)?) {
        var dict: [String: Any] = [:]
        var cpuSample: (total: Double, idle: Double)?
        var memKb: [String: Double] = [:]
        var maxSocCpuTemp = 0.0
        var fallbackTemp = 0.0

        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // CPU 占用率：与上一轮采样做差
            if trimmed.hasPrefix("cpu ") {
                let parts = trimmed.split(separator: " ").dropFirst().compactMap { Double($0) }
                guard parts.count >= 4 else { continue }
                let total = parts.reduce(0, +)
                let idle = parts[3] + (parts.count > 4 ? parts[4] : 0)
                if let previousCPU, total > previousCPU.total {
                    let usage = (1.0 - (idle - previousCPU.idle) / (total - previousCPU.total)) * 100.0
                    dict["cpu_utility"] = max(0.0, min(100.0, usage))
                }
                cpuSample = (total, idle)
                continue
            }

            let parts = trimmed.components(separatedBy: ":")
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            // 内存："MemTotal:  123456 kB"
            if ["MemTotal", "MemAvailable", "MemFree", "Buffers", "Cached"].contains(key) {
                memKb[key] = Double(value.replacingOccurrences(of: "kB", with: "").trimmingCharacters(in: .whitespaces))
                continue
            }

            // 温度："soc-thmzone:61190"（毫摄氏度）或 "nr0-thmzone:61"
            guard let rawVal = Double(value), rawVal > 0 else { continue }
            let valC = rawVal > 1000 ? rawVal / 1000.0 : rawVal
            guard valC > 10 && valC < 125 else { continue }
            let type = key.lowercased()
            if ["soc", "cpu", "nr", "tsens", "modem", "chip"].contains(where: type.contains) {
                maxSocCpuTemp = max(maxSocCpuTemp, valC)
            } else if fallbackTemp == 0 {
                fallbackTemp = valC
            }
        }

        if let totalKb = memKb["MemTotal"], totalKb > 0 {
            let availKb = memKb["MemAvailable"]
                ?? (memKb["MemFree"].map { $0 + (memKb["Buffers"] ?? 0) + (memKb["Cached"] ?? 0) } ?? 0)
            if availKb > 0 {
                dict["mem_utility"] = max(0.0, min(100.0, (1.0 - availKb / totalKb) * 100.0))
            }
        }

        let finalTemp = maxSocCpuTemp > 0 ? maxSocCpuTemp : fallbackTemp
        if finalTemp > 0 {
            dict["cpu_temp"] = finalTemp
        }
        return (dict, cpuSample)
    }

    /// 跨日时「当日用量」的基线。路由器无当日计数器，只能用累计值相减；
    /// 若 12 小时内见过累计值（Mac 跨零点睡眠），它比唤醒时的当前值更接近零点真实值。
    static func dailyBaseline(current: UInt64, lastSeen: UInt64, lastSeenAge: TimeInterval) -> UInt64 {
        let isRecent = lastSeenAge >= 0 && lastSeenAge <= 12 * 3600
        return (lastSeen > 0 && lastSeen <= current && isRecent) ? lastSeen : current
    }

    /// 漫游状态原始值：优先 network_simcard_roam（后台首页同款），空则回退 simcard_roam
    static func parseRoamStatus(_ dict: [String: Any]) -> String {
        for key in ["network_simcard_roam", "simcard_roam"] {
            if let value = dict[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return ""
    }

    // 固件 js/util.js 里的 SHA256 输出「大写」十六进制，且内层结果原样（大写）参与外层拼接。
    // 内层若用小写，算出的哈希不同：登录会被判为密码错误并消耗尝试次数，几次后账户被锁定。
    private static func routerSHA256(_ text: String) -> String {
        sha256Hex(text).uppercased()
    }

    /// 登录口令哈希：SHA256(SHA256(密码) + LD)
    static func loginPasswordHash(password: String, ld: String) -> String {
        routerSHA256(routerSHA256(password) + ld)
    }

    /// goform 写操作鉴权参数：SHA256(SHA256(wa_inner_version + cr_version) + RD)
    static func authAD(waInnerVersion: String, crVersion: String, rd: String) -> String {
        routerSHA256(routerSHA256(waInnerVersion + crVersion) + rd)
    }

    /// LOGIN 响应的 result（字符串）："0" / "4" 成功；"1" 失败、"2" 重复登录、"3" 密码错误
    static func isLoginSuccess(_ data: Data) -> Bool {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = dict["result"] else { return false }
        return ["0", "4"].contains(String(describing: result))
    }

    /// 登录失败会消耗路由器的剩余尝试次数（psw_fail_num_str），耗尽后账户锁定 login_lock_time 秒。
    /// 仅在未锁定且剩余次数充裕（≥3）时才允许应用尝试登录，给用户自己在网页端登录留足余量。
    static func isLoginAttemptSafe(_ dict: [String: Any]) -> Bool {
        let remainingText = String(describing: dict["psw_fail_num_str"] ?? "").trimmingCharacters(in: .whitespaces)
        let remaining = remainingText.isEmpty ? 5 : parseInt(remainingText)
        let lockSeconds = parseInt(dict["login_lock_time"] ?? 0)
        return remaining >= 3 && lockSeconds == 0
    }

    /// 移动数据开关请求体（与 ZTE 后台 service.js 的 CONNECT_NETWORK / DISCONNECT_NETWORK 一致）
    static func buildMobileDataRequestBody(enabled: Bool, ad: String) -> String {
        let goformId = enabled ? "CONNECT_NETWORK" : "DISCONNECT_NETWORK"
        return "isTest=false&goformId=\(goformId)&notCallback=true&AD=\(ad)"
    }

    static func parseNetworkMode(_ dict: [String: Any]) -> F50NetworkMode? {
        // network_type 是实际驻网类型，不能用于推断已配置的模式。
        let value = (dict["network_net_select"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? (dict["net_select"] as? String)
        return value.flatMap(F50NetworkMode.init(rawValue:))
    }

    static func buildNetworkModeRequestBody(mode: F50NetworkMode, ad: String) -> String {
        "isTest=false&goformId=SET_BEARER_PREFERENCE&BearerPreference=\(mode.rawValue)&AD=\(ad)"
    }

    static func isGoformSetSuccess(_ data: Data) -> Bool {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = dict["result"] else { return false }
        return String(describing: result).lowercased() == "success"
    }

    /// 构造标准 ZTE / UFI-TOOLS 发送短信请求体 (application/x-www-form-urlencoded)
    static func buildSMSRequestBody(
        number: String,
        content: String,
        ad: String? = nil,
        date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let rawNum = number.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNum = rawNum.filter { $0 != " " && $0 != "-" && $0 != "(" && $0 != ")" }

        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")

        let encodedNumber = cleanNum.addingPercentEncoding(withAllowedCharacters: allowed) ?? cleanNum
        let rawSmsTime = formatSMSTime(date: date, timeZone: timeZone)
        let encodedSmsTime = rawSmsTime.addingPercentEncoding(withAllowedCharacters: allowed) ?? rawSmsTime
        let gsmBody = gsmEncode(content)

        var formParts = [
            "isTest=false",
            "goformId=SEND_SMS",
            "notCallback=true",
            "Number=\(encodedNumber)",
            "sms_time=\(encodedSmsTime)",
            "MessageBody=\(gsmBody)",
            "ID=-1",
            "encode_type=UNICODE"
        ]
        if let ad = ad, !ad.isEmpty {
            formParts.append("AD=\(ad)")
        }
        return formParts.joined(separator: "&")
    }

    /// UFI-TOOLS 短信发送的消息体编码：UTF-16BE 的 hex 字符串
    /// （与 UFI 后台 gsmEncode 一致，非 GSM 7-bit）
    static func gsmEncode(_ text: String) -> String {
        var bytes: [UInt8] = []
        for scalar in text.unicodeScalars {
            let cp = scalar.value
            if cp <= 0xFFFF {
                bytes.append(UInt8((cp >> 8) & 0xFF))
                bytes.append(UInt8(cp & 0xFF))
            } else {
                let high = 0xD800 + ((cp - 0x10000) >> 10)
                let low = 0xDC00 + ((cp - 0x10000) & 0x3FF)
                bytes.append(UInt8((high >> 8) & 0xFF))
                bytes.append(UInt8(high & 0xFF))
                bytes.append(UInt8((low >> 8) & 0xFF))
                bytes.append(UInt8(low & 0xFF))
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// 从 Router 响应解析套餐总量。旧固件用 data_volume_limit_*，
    /// F50 Pro (MU3356) 等新固件只返回 flux_ 前缀键；空串视为缺失。
    static func parseTrafficLimit(from dict: [String: Any]) -> UInt64 {
        for prefix in ["", "flux_"] {
            let limit = parseTrafficLimit(
                size: dict["\(prefix)data_volume_limit_size"],
                unit: dict["\(prefix)data_volume_limit_unit"]
            )
            if limit > 0 { return limit }
        }
        return 0
    }

    static func parseTrafficLimit(size: Any?, unit: Any?) -> UInt64 {
        let sizeStr = String(describing: size ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let unitStr = String(describing: unit ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !sizeStr.isEmpty, sizeStr != "0", sizeStr != "null", sizeStr != "undefined" else { return 0 }

        // 1. Check if size string contains underscore separators e.g. "1536_1", "100_1024" or "500_1"
        let parts = sizeStr.split(separator: "_").compactMap { Double($0) }
        if parts.count >= 2 {
            let value = parts[0]
            guard value > 0 else { return 0 }
            let subMultiplier = parts[1] > 0 ? parts[1] : 1.0
            let bytes = value * subMultiplier * 1024.0 * 1024.0
            if bytes.isFinite && bytes > 0 && bytes <= Double(UInt64.max) {
                return UInt64(bytes)
            }
        }

        // 2. Single numeric size value
        let cleanSize = sizeStr.components(separatedBy: CharacterSet.decimalDigits.union(CharacterSet(charactersIn: ".")).inverted).joined()
        guard let numValue = Double(cleanSize), numValue > 0 else { return 0 }

        let multiplier: Double
        if unitStr == "gb" || unitStr == "1" || unitStr == "g" {
            multiplier = 1024.0 * 1024.0 * 1024.0
        } else if unitStr == "mb" || unitStr == "0" || unitStr == "m" {
            multiplier = 1024.0 * 1024.0
        } else if unitStr == "tb" || unitStr == "2" || unitStr == "t" {
            multiplier = 1024.0 * 1024.0 * 1024.0 * 1024.0
        } else if unitStr == "kb" || unitStr == "k" {
            multiplier = 1024.0
        } else if unitStr == "data" || unitStr == "data_volume" || unitStr == "size" {
            multiplier = numValue < 1000 ? 1024.0 * 1024.0 * 1024.0 : 1024.0 * 1024.0
        } else if numValue > 1_000_000_000 {
            multiplier = 1.0
        } else if numValue > 100_000 {
            multiplier = 1024.0
        } else {
            multiplier = 1024.0 * 1024.0 * 1024.0
        }

        let totalBytes = numValue * multiplier
        if totalBytes.isFinite && totalBytes > 0 && totalBytes <= Double(UInt64.max) {
            return UInt64(totalBytes)
        }
        return 0
    }

    static func parseCurrentBands(from payload: [String: Any], networkType: String) -> String {
        let lteBand = firstBand(
            in: payload,
            keys: ["lte_ca_pcell_band", "wan_active_band", "lte_band"],
            prefix: "B"
        )
        let nrBand = firstBand(
            in: payload,
            // Nr_bands 来自 network_information dump（F50 不返回 nr5g_action_band 等字段）
            keys: ["nr5g_action_band", "nr5g_action_nsa_band", "ZCELLINFO_band", "Z5g_CELLINFO_band", "nr_ca_pcell_band", "Nr_bands"],
            prefix: "n"
        )

        if networkType == "5G NSA" {
            return [lteBand, nrBand].compactMap { $0 }.joined(separator: " + ")
        }
        if networkType.hasPrefix("5G") {
            return nrBand ?? lteBand ?? ""
        }
        return lteBand ?? ""
    }

    private static func firstBand(in payload: [String: Any], keys: [String], prefix: String) -> String? {
        for key in keys {
            guard let value = payload[key] else { continue }
            let raw = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, raw != "0",
                  let range = raw.range(of: #"\d+"#, options: .regularExpression) else { continue }
            return prefix + String(raw[range])
        }
        return nil
    }

}
