import Foundation

public enum F50Configuration {
    public static let defaultBaseURL = "http://192.168.0.1"
    public static let defaultCredential = "admin"
    public static let defaultRefreshInterval = 2.0
    public static let trafficRefreshInterval = 30.0

    public static let baseURLDefaultsKey = "F50_BaseURL"
    public static let legacyPasswordDefaultsKey = "F50_Password"
    public static let refreshIntervalDefaultsKey = "F50_RefreshInterval"
    public static let displayModeDefaultsKey = "F50_DisplayMode"
    public static let trafficResetDayDefaultsKey = "F50_TrafficResetDay"
    public static let demoModeDefaultsKey = "F50_DemoMode"
    public static let initialSetupCompletedDefaultsKey = "F50_InitialSetupCompleted"

    // 设备检测到的流量清零日 / 每日流量追踪
    public static let detectedTrafficResetDayDefaultsKey = "F50_DetectedTrafficResetDay"
    /// 旧版本已保存过地址的用户无需再次经过首次设置。
    public static var needsInitialSetup: Bool {
        let defaults = UserDefaults.standard
        let hasSavedPassword = !(KeychainCredentialStore.load(account: "router-password") ?? "").isEmpty
        return !defaults.bool(forKey: initialSetupCompletedDefaultsKey)
            && defaults.object(forKey: baseURLDefaultsKey) == nil
            && !hasSavedPassword
    }

    /// 探测常见 F50 网关地址；仅请求设备公开的只读状态接口，不会发送或修改任何配置。
    public static func discoverDeviceAddress() async -> String? {
        let candidates = [
            "192.168.0.1", "192.168.1.1", "192.168.8.1",
            "192.168.10.1", "192.168.31.1", "192.168.100.1"
        ]

        return await withTaskGroup(of: String?.self, returning: String?.self) { group in
            for host in candidates {
                group.addTask {
                    await probeF50(at: host) ? host : nil
                }
            }

            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    private static func probeF50(at host: String) async -> Bool {
        let paths = [
            "http://\(host)/goform/goform_get_cmd_process?isTest=false&cmd=imei",
            "http://\(host):2333/api/baseDeviceInfo"
        ]

        for path in paths {
            guard let url = URL(string: path) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 1.5

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let body = String(data: data, encoding: .utf8)?.lowercased()
            else { continue }

            if body.contains("imei") || body.contains("imsi") || body.contains("network_type") || body.contains("basedeviceinfo") {
                return true
            }
        }
        return false
    }

    /// 提取用于设置界面显示和保存的主机名，忽略协议与端口。
    public static func displayAddress(from raw: String) -> String {
        let clean = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\n\r"))
        guard !clean.isEmpty else { return "192.168.0.1" }
        let withScheme = clean.contains("://") ? clean : "http://" + clean
        guard let url = URL(string: withScheme), let host = url.host, !host.isEmpty else {
            return clean
        }
        return host
    }

    /// 规范化保存的 baseURLString
    public static func normalizeBaseURL(_ raw: String) -> String {
        let clean = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\n\r"))
        guard !clean.isEmpty else { return defaultBaseURL }
        let withScheme = clean.contains("://") ? clean : "http://" + clean
        guard let url = URL(string: withScheme), let host = url.host, !host.isEmpty else {
            return defaultBaseURL
        }
        let scheme = url.scheme?.lowercased() ?? "http"
        return "\(scheme)://\(host)"
    }

    /// 校验地址（支持 IPv4 地址或合法的域名/主机名；输入的协议和端口会在保存时忽略）
    public static func isValidAddress(_ raw: String) -> Bool {
        let clean = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\n\r"))
        guard !clean.isEmpty else { return false }
        let withScheme = clean.contains("://") ? clean : "http://" + clean
        guard let url = URL(string: withScheme), let host = url.host, !host.isEmpty else {
            return false
        }
        guard !host.contains(" ") && !host.contains("/") else { return false }

        let parts = host.split(separator: ".")
        let allNumeric = !parts.isEmpty && parts.allSatisfy { Int($0) != nil }

        if allNumeric {
            guard parts.count == 4 else { return false }
            return parts.allSatisfy { part in
                if let num = Int(part), (0...255).contains(num) {
                    return true
                }
                return false
            }
        }

        if host.lowercased() == "localhost" {
            return true
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard host.rangeOfCharacter(from: allowed.inverted) == nil else { return false }
        guard host.contains(".") else { return false }
        guard !host.hasPrefix(".") && !host.hasSuffix(".") else { return false }
        guard parts.allSatisfy({ !$0.isEmpty }) else { return false }

        return true
    }
}
