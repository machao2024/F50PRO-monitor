import Foundation
import Combine
import os

final class F50NetworkDelegate: NSObject, URLSessionDelegate {
    static let shared = F50NetworkDelegate()

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

public enum F50MobileDataError: LocalizedError {
    case missingPassword
    case loginFailed
    case requestFailed

    public var errorDescription: String? {
        switch self {
        case .missingPassword: return "请在设置中填写路由器管理密码"
        case .loginFailed: return "登录路由器失败，请检查管理密码（为避免锁定账户，修改密码前不会自动重试）"
        case .requestFailed: return "切换移动数据失败，请稍后重试"
        }
    }
}

@MainActor
public class F50Fetcher: ObservableObject {
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 4.0
        config.timeoutIntervalForResource = 8.0
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config, delegate: F50NetworkDelegate.shared, delegateQueue: nil)
    }
    private let session: URLSession
    private let savePassword: (String) -> Void

    @Published public var status: F50Status = F50Status()
    @Published public private(set) var networkMode: F50NetworkMode?
    @Published public private(set) var isSwitchingNetworkMode = false
    @Published public var baseURLString: String {
        didSet {
            if baseURLString != oldValue {
                UserDefaults.standard.set(baseURLString, forKey: F50Configuration.baseURLDefaultsKey)
                if !isApplyingConfiguration { configurationDidChange() }
            }
        }
    }

    /// 路由器后台地址（例如 http://192.168.0.1 或 http://f50.example.com）
    public var routerURLString: String {
        F50Configuration.normalizeBaseURL(baseURLString)
    }

    @Published public var password: String {
        didSet {
            if password != oldValue {
                savePassword(password)
                if !isApplyingConfiguration { configurationDidChange() }
            }
        }
    }
    @Published public var refreshInterval: Double {
        didSet {
            if refreshInterval != oldValue {
                UserDefaults.standard.set(refreshInterval, forKey: F50Configuration.refreshIntervalDefaultsKey)
                restartTimer()
            }
        }
    }
    @Published public var displayMode: MenuBarDisplayMode {
        didSet {
            if displayMode != oldValue {
                if let data = try? JSONEncoder().encode(displayMode) {
                    UserDefaults.standard.set(data, forKey: F50Configuration.displayModeDefaultsKey)
                }
            }
        }
    }
    @Published public private(set) var smsMessages: [F50SMSMessage] = []
    @Published public private(set) var isFetchingSMS = false
    @Published public private(set) var smsErrorMessage: String?
    public private(set) var locallyReadSMSIds: Set<String> = []
    private var smsAutoRefreshTimer: Timer?

    @Published public var isDemoMode: Bool {
        didSet {
            if isDemoMode != oldValue {
                UserDefaults.standard.set(isDemoMode, forKey: F50Configuration.demoModeDefaultsKey)
                configurationDidChange()
                if isDemoMode {
                    applyDemoData()
                } else {
                    demoTick = 0
                    // 退出演示模式后先清空模拟状态，避免真实设备连接失败时残留演示指标
                    status = F50Status()
                    updateEffectiveTrafficResetDay()
                    fetchData()
                    fetchSMSMessages()
                }
            }
        }
    }
    private var demoTick: Int = 0

    private var timer: Timer?
     public private(set) var isFetching = false
    private var sessionCookie: String? = nil
    private var requestGeneration: UInt = 0
    private var isFetchingExtensions = false
    private var isApplyingConfiguration = false
    private var lastTrafficRefreshDate = Date.distantPast
    private var lastADBHardwareRefreshDate = Date.distantPast
    private let adbHardwareRefreshInterval: TimeInterval = 10

    // /proc/stat 上一轮采样，用于做差计算 CPU 占用率
    private var previousCPUSample: (total: Double, idle: Double)?
    private var routerDetectedTrafficResetDay: Int = 0

    private let logger = Logger(subsystem: "com.f50.monitor", category: "fetcher")

    public func appendLog(_ category: String, _ message: String) {
        logger.info("[\(category, privacy: .public)] \(message, privacy: .public)")
    }

    @Published public var trafficResetDay: Int {
        didSet {
            if trafficResetDay != oldValue {
                UserDefaults.standard.set(trafficResetDay, forKey: F50Configuration.trafficResetDayDefaultsKey)
                updateEffectiveTrafficResetDay()
            }
        }
    }

    private func applyDetectedTrafficResetDay(from dict: [String: Any]) {
        let key = F50Configuration.detectedTrafficResetDayDefaultsKey
        if F50ResponseParser.isAutoTrafficClearDisabled(dict) {
            // 路由器不会自动清零：丢弃之前探测到的清零日，避免误显示「N 天后重置」
            routerDetectedTrafficResetDay = 0
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        let detectedDay = F50ResponseParser.extractFirstValidResetDay(from: dict)
        if detectedDay > 0 {
            routerDetectedTrafficResetDay = detectedDay
            UserDefaults.standard.set(detectedDay, forKey: key)
        }
    }

    private func updateEffectiveTrafficResetDay() {
        let effectiveDay: Int
        if (1...31).contains(routerDetectedTrafficResetDay) {
            effectiveDay = routerDetectedTrafficResetDay
        } else if (1...31).contains(trafficResetDay) {
            effectiveDay = trafficResetDay
        } else {
            let savedDetected = UserDefaults.standard.integer(forKey: "F50_DetectedTrafficResetDay")
            effectiveDay = (1...31).contains(savedDetected) ? savedDetected : 0
        }
        self.status.trafficResetDay = effectiveDay
    }

    public convenience init() {
        self.init(session: Self.makeSession(), automaticallyRefresh: true, loadPassword: {
            KeychainCredentialStore.loadMigratingLegacyValue(
                account: "router-password",
                legacyDefaultsKey: F50Configuration.legacyPasswordDefaultsKey,
                fallback: ""
            )
        }, savePassword: { value in
            KeychainCredentialStore.save(value, account: "router-password")
        })
    }

    /// 内部依赖注入用于隔离网络和钥匙串的回归测试。
    init(session: URLSession, automaticallyRefresh: Bool,
         loadPassword: @escaping () -> String, savePassword: @escaping (String) -> Void) {
        self.session = session
        self.savePassword = savePassword
        self.baseURLString = UserDefaults.standard.string(forKey: F50Configuration.baseURLDefaultsKey)
            ?? F50Configuration.defaultBaseURL
        self.password = loadPassword()

        let savedInterval = UserDefaults.standard.double(forKey: F50Configuration.refreshIntervalDefaultsKey)
        self.refreshInterval = savedInterval > 0 ? savedInterval : F50Configuration.defaultRefreshInterval

        // 保留用户手动设置（若有），否则置为 0（未知），等待设备上报或使用默认值
        let savedManualDay = UserDefaults.standard.integer(forKey: F50Configuration.trafficResetDayDefaultsKey)
        self.trafficResetDay = (1...31).contains(savedManualDay) ? savedManualDay : 0

        let savedDetectedDay = UserDefaults.standard.integer(forKey: "F50_DetectedTrafficResetDay")
        if savedDetectedDay > 0 && savedDetectedDay <= 31 {
            self.routerDetectedTrafficResetDay = savedDetectedDay
        }

        if let modeData = UserDefaults.standard.data(forKey: F50Configuration.displayModeDefaultsKey),
           let mode = try? JSONDecoder().decode(MenuBarDisplayMode.self, from: modeData) {
            self.displayMode = mode
        } else {
            self.displayMode = .dailyUsage
        }

        self.locallyReadSMSIds = Set(UserDefaults.standard.stringArray(forKey: "F50_LocallyReadSMSIds") ?? [])
        self.isDemoMode = UserDefaults.standard.bool(forKey: F50Configuration.demoModeDefaultsKey)

        if !self.locallyReadSMSIds.isEmpty {
            self.status.smsUnreadCount = 0
        }

        if self.isDemoMode {
            self.networkMode = .automatic
            self.status = F50Status.mockStatus(tick: 0)
            self.smsMessages = F50SMSMessage.mockMessages
            self.status.smsUnreadCount = self.smsMessages.filter { $0.isUnread }.count
        }

        updateEffectiveTrafficResetDay()
        if automaticallyRefresh {
            startTimer()
            fetchData()
            fetchSMSMessages()
        }
    }

    public func applyDemoData() {
        networkMode = .automatic
        self.status = F50Status.mockStatus(tick: demoTick)
        if !demoMobileDataOn { self.status.rawPppStatus = "ppp_disconnected" }
        self.smsMessages = F50SMSMessage.mockMessages
        self.status.smsUnreadCount = self.smsMessages.filter { $0.isUnread }.count
        self.smsErrorMessage = nil
        self.isFetchingSMS = false
    }

    public func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.fetchData()
            }
        }
    }

    public func restartTimer() {
        startTimer()
    }

    public func applyConfiguration(
        baseURL: String,
        password: String,
        refreshInterval: Double,
        displayMode: MenuBarDisplayMode,
        trafficResetDay: Int? = nil
    ) {
        let cleanBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let connectionChanged = cleanBaseURL != baseURLString
            || password != self.password

        isApplyingConfiguration = true
        baseURLString = cleanBaseURL
        self.password = password
        self.refreshInterval = refreshInterval
        self.displayMode = displayMode
        if let resetDay = trafficResetDay, (0...31).contains(resetDay) {
            self.trafficResetDay = resetDay
        }
        updateEffectiveTrafficResetDay()
        isApplyingConfiguration = false

        if connectionChanged {
            configurationDidChange()
        }
        fetchData()
    }

    public func fetchData() {
        if isDemoMode {
            demoTick += 1
            self.status = F50Status.mockStatus(tick: demoTick)
            if !demoMobileDataOn { self.status.rawPppStatus = "ppp_disconnected" }
            return
        }

        guard !isFetching else { return }
        isFetching = true
        let generation = requestGeneration
        let refreshTraffic = Date().timeIntervalSince(lastTrafficRefreshDate)
            >= F50Configuration.trafficRefreshInterval
        Task { await refresh(generation: generation, refreshTraffic: refreshTraffic) }
    }

    public func fetchDataAsync() async {
        fetchData()
        guard !isDemoMode else { return }
        guard isFetching else { return }
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !isFetching { break }
        }
    }

    public func fetchSMSMessages() {
        if isDemoMode {
            if self.smsMessages.isEmpty {
                self.smsMessages = F50SMSMessage.mockMessages
            }
            self.smsErrorMessage = nil
            self.isFetchingSMS = false
            return
        }

        guard !isFetchingSMS else { return }
        isFetchingSMS = true
        smsErrorMessage = nil
        let generation = requestGeneration
        Task { await loadSMSMessages(generation: generation) }
    }

    private var smsMessagesPath: String {
        "/goform/goform_get_cmd_process?multi_data=1&isTest=false&cmd=sms_data_total&page=0&data_per_page=100&mem_store=1&tags=100&order_by=order%20by%20id%20desc"
    }

    /// 短信读取优先级：80 Router → 5555 ADB（在设备本机回环访问同一接口）。
    private func loadSMSMessages(generation: UInt) async {
        let routerBaseURL = routerURLString
        var json = try? await routerJSON(routerBaseURL: routerBaseURL, path: smsMessagesPath)
        if json.flatMap(F50ResponseParser.parseSMSMessages) == nil {
            let url = "http://127.0.0.1\(smsMessagesPath)"
            let command = "if command -v curl >/dev/null 2>&1; then curl -sS -H 'Referer: http://127.0.0.1/index.html' '\(url)'; elif command -v wget >/dev/null 2>&1; then wget -qO- --header='Referer: http://127.0.0.1/index.html' '\(url)'; fi"
            if let output = await ADBHardwareFetcher.executeShell(host: routerHost, port: 5555, command: command, timeoutSec: 2.0) {
                json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
            }
        }
        guard generation == requestGeneration else { return }
        isFetchingSMS = false
        guard let json, let messages = F50ResponseParser.parseSMSMessages(json) else {
            smsErrorMessage = "无法读取短信，请检查设备连接与管理密码"
            return
        }
        let readIds = locallyReadSMSIds
        smsMessages = messages.map { message in
            var updated = message
            if readIds.contains(message.id) { updated.isLocallyRead = true }
            return updated
        }
        status.smsUnreadCount = smsMessages.filter { $0.isUnread }.count
    }

    // MARK: - 短信自动刷新与标记已读

    public func startSMSAutoRefresh(interval: TimeInterval = 4.0) {
        stopSMSAutoRefresh()
        fetchSMSMessages()
        smsAutoRefreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fetchSMSMessages()
            }
        }
    }

    public func stopSMSAutoRefresh() {
        smsAutoRefreshTimer?.invalidate()
        smsAutoRefreshTimer = nil
    }

    public func markSMSAsRead(ids: [String]) {
        guard !ids.isEmpty else { return }
        for id in ids {
            locallyReadSMSIds.insert(id)
        }
        UserDefaults.standard.set(Array(locallyReadSMSIds), forKey: "F50_LocallyReadSMSIds")

        let readIds = locallyReadSMSIds
        smsMessages = smsMessages.map { msg in
            var m = msg
            if readIds.contains(msg.id) {
                m.isLocallyRead = true
            }
            return m
        }
        status.smsUnreadCount = smsMessages.filter { $0.isUnread }.count
        if isDemoMode { return }

        // 同步设备端标记已读
        let idsJoined = ids.joined(separator: ";") + ";"
        let generation = requestGeneration
        Task {
            _ = await postGoform(generation: generation) { ad in
                "isTest=false&goformId=SET_MSG_READ&msg_id=\(idsJoined)&tag=0&AD=\(ad)"
            }
        }
    }

    public func markAllSMSAsRead() {
        let unreadIds = smsMessages.filter { $0.isUnread }.map { $0.id }
        markSMSAsRead(ids: unreadIds)
        status.smsUnreadCount = 0
    }

    // MARK: - 移动数据开关

    @Published public private(set) var isSwitchingMobileData = false
    private var demoMobileDataOn = true

    /// 开关蜂窝数据（CONNECT_NETWORK / DISCONNECT_NETWORK）。UI 以轮询到的 ppp_status 为准，不做本地乐观更新。
    public func setMobileData(enabled: Bool) async throws {
        guard !isSwitchingMobileData, !isSwitchingNetworkMode else {
            throw F50NetworkModeError.busy
        }

        if isDemoMode {
            demoMobileDataOn = enabled
            status.rawPppStatus = enabled ? "ipv4_ipv6_connected" : "ppp_disconnected"
            return
        }

        guard !password.isEmpty else { throw F50MobileDataError.missingPassword }

        isSwitchingMobileData = true
        defer { isSwitchingMobileData = false }

        switch await postGoform(generation: requestGeneration, body: {
            F50ResponseParser.buildMobileDataRequestBody(enabled: enabled, ad: $0)
        }) {
        case .success: break
        case .loginFailed: throw F50MobileDataError.loginFailed
        case .failed: throw F50MobileDataError.requestFailed
        }
        appendLog("连接", "已请求\(enabled ? "开启" : "关闭")移动数据")

        // ppp_status 有数秒过渡（ppp_connecting / ppp_disconnecting），短轮询到稳定状态
        await fetchDataAsync()
        for _ in 0..<5 where status.isMobileDataTransitioning {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await fetchDataAsync()
        }
    }

    /// 通过原厂后台切换模式；回读配置确认，不把实际驻网类型当作配置。
    public func setNetworkMode(_ mode: F50NetworkMode) async throws {
        guard !isSwitchingNetworkMode, !isSwitchingMobileData,
              !status.isMobileDataTransitioning else { throw F50NetworkModeError.busy }
        if isDemoMode {
            networkMode = mode
            return
        }
        guard status.isOnline, networkMode != nil else { throw F50NetworkModeError.unavailable }
        guard mode != networkMode else { return }
        guard !password.isEmpty else { throw F50MobileDataError.missingPassword }

        let generation = requestGeneration
        let routerBaseURL = routerURLString
        isSwitchingNetworkMode = true
        defer { isSwitchingNetworkMode = false }
        let result = await postGoform(generation: generation, body: {
            F50ResponseParser.buildNetworkModeRequestBody(mode: mode, ad: $0)
        })
        guard generation == requestGeneration else { throw CancellationError() }
        switch result {
        case .success: break
        case .loginFailed: throw F50MobileDataError.loginFailed
        case .failed: throw F50NetworkModeError.requestFailed
        }
        appendLog("网络", "已请求切换为\(mode.title)")
        for attempt in 0..<15 {
            if attempt > 0 { try await Task.sleep(nanoseconds: 1_000_000_000) }
            guard generation == requestGeneration else { throw CancellationError() }
            if let payload = try? await routerCommands("network_net_select", routerBaseURL: routerBaseURL),
               generation == requestGeneration {
                networkMode = F50ResponseParser.parseNetworkMode(payload)
                if networkMode == mode {
                    await fetchDataAsync()
                    return
                }
            }
        }
        throw F50NetworkModeError.notConfirmed
    }

    // MARK: - 发送短信

    @Published public private(set) var isSendingSMS = false
    @Published public private(set) var smsSendErrorMessage: String?
    @Published public private(set) var smsSendSuccess = false

    public func sendSMSMessage(to number: String, content: String) {
        guard !isSendingSMS else { return }
        let cleanNumber = number.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanNumber.isEmpty, !cleanContent.isEmpty else {
            smsSendErrorMessage = "请填写手机号和短信内容"
            return
        }

        if isDemoMode {
            isSendingSMS = true
            smsSendErrorMessage = nil
            smsSendSuccess = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                let newMsg = F50SMSMessage(
                    id: "demo-out-\(UUID().uuidString.prefix(6))",
                    number: cleanNumber,
                    content: cleanContent,
                    dateText: formatter.string(from: Date()),
                    tag: "2",
                    isLocallyRead: true
                )
                self.smsMessages.insert(newMsg, at: 0)
                self.finishSMSSent()
            }
            return
        }

        isSendingSMS = true
        smsSendErrorMessage = nil
        smsSendSuccess = false
        let generation = requestGeneration
        Task { await sendSMS(number: cleanNumber, content: cleanContent, generation: generation) }
    }

    /// 短信发送优先级：80 Router → 5555 ADB。
    private func sendSMS(number: String, content: String, generation: UInt) async {
        var sent = await postGoform(generation: generation, isSuccess: isSMSSendSuccess) { ad in
            F50ResponseParser.buildSMSRequestBody(number: number, content: content, ad: ad)
        } == .success
        if !sent {
            sent = await sendSMSViaADB(host: routerHost, number: number, content: content, generation: generation)
        }
        guard generation == requestGeneration else { return }
        if sent {
            finishSMSSent()
        } else {
            finishSMSFailed("短信发送失败，请检查管理密码与设备连接")
        }
    }

    private func finishSMSSent() {
        smsSendSuccess = true
        smsSendErrorMessage = nil
        isSendingSMS = false
        fetchSMSMessages()
    }

    private func sendSMSViaADB(
        host: String,
        number: String,
        content: String,
        generation: UInt
    ) async -> Bool {
        guard generation == requestGeneration,
              let output = await ADBHardwareFetcher.executeShell(
                host: host,
                port: 5555,
                command: smsShellCommand(number: number, content: content),
                timeoutSec: 8.0
              ) else {
            return false
        }
        return output.contains("Result: Parcel") && !output.contains("Exception")
    }

    private func smsShellCommand(number: String, content: String) -> String {
        let cleanNum = number.components(
            separatedBy: CharacterSet(charactersIn: "0123456789+").inverted
        ).joined()
        let b64Body = Data(content.utf8).base64EncodedString()
        return """
        sub_id=$(content query --uri content://telephony/siminfo --projection _id --where "sim_id>=0" 2>/dev/null | grep -o "_id=[0-9]*" | head -n 1 | cut -d= -f2)
        if [ -z "$sub_id" ]; then sub_id=3; fi
        BODY=$(echo "\(b64Body)" | base64 -d)
        service call isms 6 i32 $sub_id s16 "com.android.phone" s16 "null" s16 "\(cleanNum)" s16 "null" s16 "$BODY" s16 "null" s16 "null" i32 1 || \
        service call isms 7 i32 $sub_id s16 "com.android.phone" s16 "null" s16 "\(cleanNum)" s16 "null" s16 "$BODY" s16 "null" s16 "null" i32 1 || \
        service call isms 5 i32 $sub_id s16 "com.android.phone" s16 "null" s16 "\(cleanNum)" s16 "null" s16 "$BODY" s16 "null" s16 "null" i32 1
        """
    }

    private func isSMSSendSuccess(_ data: Data) -> Bool {
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let resultInt = dict["result"] as? Int
            let resultStr = (dict["result"] as? String)?.lowercased()
            return resultInt == 0 || resultInt == 3
                || resultStr == "0" || resultStr == "3" || resultStr == "success"
        }
        guard let raw = String(data: data, encoding: .utf8) else { return false }
        return raw.contains("\"result\":0")
            || raw.contains("\"result\":\"0\"")
            || raw.lowercased().contains("success")
    }

    private func finishSMSFailed(_ message: String) {
        guard !smsSendSuccess else { return }
        smsSendErrorMessage = message
        isSendingSMS = false
    }

    // MARK: - Router (80 端口) 请求

    private enum RouterError: LocalizedError {
        case invalidURL
        case badResponse
        case http(Int)
        case unauthorized(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "无效的 URL"
            case .badResponse: return "网络响应错误"
            case .http(let code): return "HTTP 错误: \(code)"
            case .unauthorized(let message): return message
            }
        }
    }

    private enum GoformWriteResult {
        case success, loginFailed, failed
    }

    private var routerHost: String {
        URL(string: routerURLString)?.host ?? "192.168.0.1"
    }

    private func routerRequest(routerBaseURL: String, path: String, timeout: TimeInterval) throws -> URLRequest {
        guard let url = URL(string: routerBaseURL + path) else { throw RouterError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("\(routerBaseURL)/index.html", forHTTPHeaderField: "Referer")
        if let sessionCookie, !sessionCookie.isEmpty {
            request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        }
        return request
    }

    /// GET 并解析 JSON。设备未认证时可能返回 401，也可能返回 200 + {"Error":"none secure connection"}。
    private func routerJSON(routerBaseURL: String, path: String, timeout: TimeInterval = 4.0) async throws -> [String: Any] {
        let request = try routerRequest(routerBaseURL: routerBaseURL, path: path, timeout: timeout)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RouterError.badResponse }
        if http.statusCode == 401 { throw RouterError.unauthorized("口令/密码错误(401)") }
        guard http.statusCode == 200 else { throw RouterError.http(http.statusCode) }
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RouterError.badResponse
        }
        if let errorText = dict["Error"] as? String, !errorText.isEmpty {
            throw RouterError.unauthorized("设备返回错误: \(errorText)")
        }
        return dict
    }

    private func routerCommands(_ cmdList: String, routerBaseURL: String, timeout: TimeInterval = 4.0) async throws -> [String: Any] {
        try await routerJSON(
            routerBaseURL: routerBaseURL,
            path: "/goform/goform_get_cmd_process?multi_data=1&isTest=false&cmd=\(cmdList)",
            timeout: timeout
        )
    }

    /// 当前口令已被路由器拒绝：在口令 / 地址变更前不再尝试登录，避免把账户刷到锁定。
    private var isLoginRejected = false

    /// 登录：LD 挑战值 + 口令哈希。失败的登录会消耗路由器的尝试次数，所以这里宁可不登也不盲目重试。
    private func login(routerBaseURL: String, generation: UInt) async -> Bool {
        guard generation == requestGeneration else { return false }
        sessionCookie = nil
        guard !password.isEmpty, !isLoginRejected else { return false }
        let loginPassword = password

        guard let lockState = try? await routerCommands("psw_fail_num_str,login_lock_time", routerBaseURL: routerBaseURL),
              generation == requestGeneration,
              F50ResponseParser.isLoginAttemptSafe(lockState) else {
            appendLog("错误", "路由器登录已锁定或剩余尝试次数不足，跳过登录")
            return false
        }

        guard let ld = (try? await routerJSON(
                routerBaseURL: routerBaseURL,
                path: "/goform/goform_get_cmd_process?isTest=false&cmd=LD"
              ))?["LD"] as? String, !ld.isEmpty,
              generation == requestGeneration,
              var request = try? routerRequest(
                routerBaseURL: routerBaseURL,
                path: "/goform/goform_set_cmd_process",
                timeout: 4.0
              ) else { return false }

        let passwordHash = F50ResponseParser.loginPasswordHash(password: loginPassword, ld: ld)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("isTest=false&goformId=LOGIN&password=\(passwordHash)".utf8)

        guard let (data, response) = try? await session.data(for: request),
              generation == requestGeneration else { return false }
        guard F50ResponseParser.isLoginSuccess(data) else {
            isLoginRejected = true
            appendLog("错误", "路由器拒绝了登录口令；修改口令前不再重试")
            return false
        }
        if let setCookie = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Set-Cookie") {
            sessionCookie = setCookie.components(separatedBy: ";").first ?? setCookie
        }
        return true
    }

    /// 写操作鉴权参数 AD：SHA256(SHA256(wa_inner_version + cr_version) + RD)
    private func fetchAuthAD(routerBaseURL: String) async -> String? {
        guard let versions = try? await routerCommands("Language,cr_version,wa_inner_version", routerBaseURL: routerBaseURL),
              let rd = (try? await routerJSON(
                routerBaseURL: routerBaseURL,
                path: "/goform/goform_get_cmd_process?cmd=RD&isTest=false"
              ))?["RD"] as? String else { return nil }
        let wa = (versions["wa_inner_version"] as? String) ?? (versions["wa_version"] as? String) ?? ""
        let cr = (versions["cr_version"] as? String) ?? ""
        return F50ResponseParser.authAD(waInnerVersion: wa, crVersion: cr, rd: rd)
    }

    /// goform 写操作：取 AD → POST。先复用现有会话；未登录或会话过期时登录后重试一次。
    private func postGoform(
        generation: UInt,
        isSuccess: @escaping (Data) -> Bool = F50ResponseParser.isGoformSetSuccess,
        body: @escaping (_ ad: String) -> String
    ) async -> GoformWriteResult {
        let routerBaseURL = routerURLString
        func attempt() async -> Bool {
            guard generation == requestGeneration,
                  let ad = await fetchAuthAD(routerBaseURL: routerBaseURL),
                  generation == requestGeneration,
                  var request = try? routerRequest(
                    routerBaseURL: routerBaseURL,
                    path: "/goform/goform_set_cmd_process",
                    timeout: 5.0
                  ) else { return false }
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body(ad).utf8)
            guard let (data, response) = try? await session.data(for: request),
                  generation == requestGeneration,
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            return isSuccess(data)
        }

        if sessionCookie != nil, await attempt() { return .success }
        guard generation == requestGeneration,
              await login(routerBaseURL: routerBaseURL, generation: generation) else { return .loginFailed }
        return await attempt() ? .success : .failed
    }

    // MARK: - 状态刷新（80 Router 为主，5555 ADB 补充硬件指标）

    private func refresh(generation: UInt, refreshTraffic: Bool) async {
        let routerBaseURL = routerURLString
        // 信号指标（nr_rsrp/nr_rsrq/Nr_snr）由 network_information 的 dump 提供：
        // F50 固件若在列表中显式请求这四个命令，会把 dump 对应字段清零（返回空串），
        // 所以这里不显式请求它们，只保留独立数据源 Z5g_rsrp 与其它兑底字段。
        // V50 (MU3351) 会通过 temperature / cpu_temp 返回硬件指标；保留 ic_temp
        // 以兼容 F50 等旧固件。
        let statusCommands = "usb_port_switch,battery_charging,sms_received_flag,sms_unread_num,sms_sim_unread_num,sim_msisdn,battery_value,battery_vol_percent,network_signalbar,network_rssi,cr_version,iccid,imei,imsi,ipv6_wan_ipaddr,lan_ipaddr,mac_address,msisdn,network_information,Lte_ca_status,rssi,Z5g_rsrp,Z5g_snr,lte_rsrp,wifi_access_sta_num,loginfo,realtime_rx_thrpt,realtime_tx_thrpt,network_type,network_net_select,network_provider,ppp_status,temperature,cpu_temp,internal_temperature,ic_temp,cpu_temperature,cpu_utility,mem_utility,5g_rsrp,5g_rsrq,5g_snr,lte_rsrq,lte_snr,signalbar,qci,ambr,dl_ambr,ul_ambr,network_simcard_roam,simcard_roam,roam_setting_option"
        let trafficCommands = "realtime_rx_bytes,realtime_tx_bytes,realtime_time,monthly_tx_bytes,monthly_rx_bytes,monthly_time,day_rx_bytes,day_tx_bytes,total_rx_bytes,total_tx_bytes,data_volume_limit_size,data_volume_limit_unit,data_volume_limit_switch,flux_data_volume_limit_size,flux_data_volume_limit_unit,flux_clear_date,flux_auto_clear_flow_data_switch,data_volume_clear_date,monthly_clear_date,clear_date,data_volume_clear_day,monthly_clear_day,clear_day,data_volume_reset_day,billing_day,traffic_clear_date"
        let cmdList = refreshTraffic ? "\(statusCommands),\(trafficCommands)" : statusCommands

        let dict: [String: Any]
        do {
            do {
                dict = try await routerCommands(cmdList, routerBaseURL: routerBaseURL)
            } catch RouterError.unauthorized(let message) {
                guard await login(routerBaseURL: routerBaseURL, generation: generation) else {
                    throw RouterError.unauthorized(message)
                }
                dict = try await routerCommands(cmdList, routerBaseURL: routerBaseURL)
            }
        } catch {
            updateStatusFailed(error.localizedDescription, generation: generation)
            return
        }

        guard generation == requestGeneration else { return }
        networkMode = F50ResponseParser.parseNetworkMode(dict)
        parseStatusDict(dict, refreshTraffic: refreshTraffic)
        if refreshTraffic {
            lastTrafficRefreshDate = Date()
        }
        isFetching = false

        // 补充数据不阻塞下一轮主刷新；上一轮尚未结束时跳过
        guard !isFetchingExtensions else { return }
        isFetchingExtensions = true
        defer { isFetchingExtensions = false }
        async let bands: Void = refreshBands(routerBaseURL: routerBaseURL, generation: generation)
        await applyADBMetrics(host: routerHost, primaryPayload: dict, generation: generation)
        await bands
    }

    /// 频段需单独请求：与主状态列表合并请求会让部分固件把 dump 字段清零
    private func refreshBands(routerBaseURL: String, generation: UInt) async {
        let cmdList = "network_type,wan_active_band,lte_band,lte_ca_pcell_band,nr5g_action_band,nr5g_action_nsa_band,ZCELLINFO_band,Z5g_CELLINFO_band,nr_ca_pcell_band"
        guard let payload = try? await routerCommands(cmdList, routerBaseURL: routerBaseURL, timeout: 3.0),
              generation == requestGeneration else { return }
        let bands = F50ResponseParser.parseCurrentBands(from: payload, networkType: status.networkType)
        if !bands.isEmpty {
            status.currentBands = bands
        }
    }

    private func configurationDidChange() {
        requestGeneration &+= 1
        networkMode = isDemoMode ? .automatic : nil
        isFetching = false
        isFetchingExtensions = false
        isFetchingSMS = false
        smsMessages = []
        smsErrorMessage = nil
        sessionCookie = nil
        isLoginRejected = false
        status.clearHardwareMetrics()
        // 避免新配置下短暂显示旧设备的流量
        status.monthlyRx = 0
        status.monthlyTx = 0
        status.trafficLimit = 0
        previousCPUSample = nil
        lastTrafficRefreshDate = .distantPast
        lastADBHardwareRefreshDate = .distantPast
    }

    /// 5555 ADB 只补 80 端口本轮未提供的硬件指标（CPU / 内存 / 温度），保证来源优先级不反转。
    private func applyADBMetrics(host: String, primaryPayload: [String: Any], generation: UInt) async {
        var primaryStatus = F50Status()
        primaryStatus.mergeHardwareMetrics(from: primaryPayload)

        let now = Date()
        guard primaryStatus.cpuUsage <= 0 || primaryStatus.memUsage <= 0 || primaryStatus.temperature <= 0,
              now.timeIntervalSince(lastADBHardwareRefreshDate) >= adbHardwareRefreshInterval else { return }
        lastADBHardwareRefreshDate = now

        // 全部使用 shell 内建读取，避免每个温度节点各启动两个 cat 进程。
        let hardwareCommand = "for f in /sys/class/thermal/thermal_zone*; do [ -d \"$f\" ] || continue; type=; temp=; read -r type < \"$f/type\"; read -r temp < \"$f/temp\"; printf '%s:%s\\n' \"$type\" \"$temp\"; done; read -r cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat; printf 'cpu %s %s %s %s %s %s %s %s %s %s\\n' \"$user\" \"$nice\" \"$system\" \"$idle\" \"$iowait\" \"$irq\" \"$softirq\" \"$steal\" \"$guest\" \"$guest_nice\"; while IFS= read -r line; do case \"$line\" in MemTotal:*|MemAvailable:*|MemFree:*|Buffers:*|Cached:*) printf '%s\\n' \"$line\";; esac; done < /proc/meminfo"
        guard let rawHardware = await ADBHardwareFetcher.executeShell(
            host: host,
            port: 5555,
            command: hardwareCommand,
            timeoutSec: 3.0
        ), !rawHardware.isEmpty, generation == requestGeneration else { return }

        let (metrics, cpuSample) = F50ResponseParser.parseLinuxShellMetrics(rawHardware, previousCPU: previousCPUSample)
        previousCPUSample = cpuSample ?? previousCPUSample
        var adbStatus = F50Status()
        adbStatus.mergeHardwareMetrics(from: metrics)
        if primaryStatus.cpuUsage <= 0, adbStatus.cpuUsage > 0 { status.cpuUsage = adbStatus.cpuUsage }
        if primaryStatus.memUsage <= 0, adbStatus.memUsage > 0 { status.memUsage = adbStatus.memUsage }
        if primaryStatus.temperature <= 0, adbStatus.temperature > 0 { status.temperature = adbStatus.temperature }
    }

    private func updateStatusFailed(_ msg: String, generation: UInt) {
        guard generation == requestGeneration else { return }
        status.isOnline = false
        status.errorMessage = msg
        appendLog("错误", msg)
        isFetching = false
    }

    private func parseStatusDict(_ dict: [String: Any], refreshTraffic: Bool) {
        var newStatus = F50Status()
        newStatus.isOnline = true
        newStatus.errorMessage = nil
        newStatus.lastUpdated = Date()

        // 硬件指标可能来自 ADB 补充，主刷新时先沿用上一轮的值
        newStatus.cpuUsage = status.cpuUsage
        newStatus.memUsage = status.memUsage
        newStatus.temperature = status.temperature
        newStatus.smsUnreadCount = status.smsUnreadCount
        newStatus.mergeHardwareMetrics(from: dict)

        // Signal bar (signalbar, rssi, network_signalbar)
        if let val = dict["signalbar"] ?? dict["rssi"] ?? dict["network_signalbar"] {
            let bar = parseInt(val)
            newStatus.signalBar = min(5, max(0, bar))
        }

        newStatus.dlHistory = status.dlHistory
        newStatus.ulHistory = status.ulHistory

        // Speeds
        if let val = dict["realtime_rx_thrpt"] {
            newStatus.dlSpeed = parseDouble(val)
        }
        if let val = dict["realtime_tx_thrpt"] {
            newStatus.ulSpeed = parseDouble(val)
        }
        newStatus.recordSpeed(dl: newStatus.dlSpeed, ul: newStatus.ulSpeed)

        // Connected devices
        if let val = dict["wifi_access_sta_num"] ?? dict["station_num"] {
            newStatus.connectedDevices = parseInt(val)
        }
        if let val = dict["sms_unread_num"] ?? dict["sms_sim_unread_num"] {
            let rawCount = parseInt(val)
            if !self.smsMessages.isEmpty {
                newStatus.smsUnreadCount = self.smsMessages.filter { $0.isUnread }.count
            } else if !self.locallyReadSMSIds.isEmpty {
                newStatus.smsUnreadCount = max(0, rawCount - self.locallyReadSMSIds.count)
            } else {
                newStatus.smsUnreadCount = rawCount
            }
        } else if !self.smsMessages.isEmpty {
            newStatus.smsUnreadCount = self.smsMessages.filter { $0.isUnread }.count
        }

        // Network type parsing (20 -> 5G SA, 19 -> 5G NSA, 10/11 -> 4G LTE)
        var parsedType = ""
        if let rawType = dict["network_type"] {
            let typeStr = String(describing: rawType).trimmingCharacters(in: .whitespaces)
            if typeStr == "20" || typeStr.contains("5G SA") || typeStr.contains("5G_SA") {
                parsedType = "5G SA"
            } else if typeStr == "19" || typeStr.contains("5G NSA") || typeStr.contains("5G_NSA") {
                parsedType = "5G NSA"
            } else if typeStr == "10" || typeStr == "11" || typeStr.lowercased().contains("4g") || typeStr.lowercased().contains("lte") {
                parsedType = "4G LTE"
            } else if typeStr == "5G" || typeStr == "5g" {
                parsedType = "5G"
            } else if !typeStr.isEmpty && typeStr != "0" {
                parsedType = typeStr
            }
        }

        // Fallback / refinement for network type
        // F50 的显式 network_type 只返回泛化的 "5G"（不区分 SA/NSA），
        // 用信号指标进一步区分：仅 NR 有值=SA，NR+LTE 都有=NSA
        if parsedType.isEmpty || parsedType == "0" || parsedType == "5G" {
            let hasNR = F50ResponseParser.firstValidSignalValue(in: dict, keys: ["nr_rsrp", "Z5g_rsrp", "5g_rsrp"]) != nil
            let hasLTE = F50ResponseParser.firstValidSignalValue(in: dict, keys: ["lte_rsrp"]) != nil
            if hasNR && !hasLTE {
                parsedType = "5G SA"
            } else if hasNR && hasLTE {
                parsedType = "5G NSA"
            } else if hasLTE {
                parsedType = "4G LTE"
            } else if parsedType.isEmpty || parsedType == "0" {
                parsedType = "5G"
            }
        }
        newStatus.networkType = parsedType
        let currentBands = F50ResponseParser.parseCurrentBands(from: dict, networkType: parsedType)
        newStatus.currentBands = currentBands.isEmpty ? status.currentBands : currentBands

        // 3 Signal Metrics: RSRP, RSRQ, SINR/SNR
        // firstValidSignalValue 会跳过 null/"0"/无效值继续尝试下一个候选键，
        // 避免设备把不适用的字段置 null 时真实值被短路掉（表现为三项全部 N/A）
        let rsrpKeys = ["nr_rsrp", "Z5g_rsrp", "5g_rsrp", "lte_rsrp", "Nr_signal_strength"]
        let rsrqKeys = ["nr_rsrq", "Z5g_rsrq", "5g_rsrq", "lte_rsrq"]
        let snrKeys = ["Nr_snr", "nr_snr", "Z5g_snr", "5g_snr", "lte_snr", "sinr", "nr_sinr", "5g_sinr", "lte_sinr"]

        if let num = F50ResponseParser.firstValidSignalValue(in: dict, keys: rsrpKeys) {
            newStatus.rsrp = "\(Int(num)) dBm"
        }
        if let num = F50ResponseParser.firstValidSignalValue(in: dict, keys: rsrqKeys) {
            newStatus.rsrq = "\(Int(num)) dB"
        }
        if let num = F50ResponseParser.firstValidSignalValue(in: dict, keys: snrKeys) {
            newStatus.snr = "\(Int(num)) dB"
        }

        // Carrier / Provider
        if let val = dict["network_provider"] as? String, !val.isEmpty {
            newStatus.carrier = val
        }

        // PPP Status
        if let val = dict["ppp_status"] as? String, !val.isEmpty {
            newStatus.rawPppStatus = val
        }

        // Roaming
        newStatus.rawRoamStatus = F50ResponseParser.parseRoamStatus(dict)
        if let val = dict["roam_setting_option"] as? String, !val.isEmpty {
            newStatus.isDataRoamingEnabled = val.lowercased() == "on"
        }

        // Battery
        if let val = dict["battery_value"] ?? dict["battery_vol_percent"] {
            newStatus.batteryValue = parseInt(val)
        }
        if let val = dict["battery_charging"] {
            let str = String(describing: val).lowercased()
            newStatus.isCharging = str == "1" || str == "true" || str == "charging"
        }

        if refreshTraffic {
            if let val = dict["monthly_rx_bytes"] {
                newStatus.monthlyRx = parseUInt64(val)
            }
            if let val = dict["monthly_tx_bytes"] {
                newStatus.monthlyTx = parseUInt64(val)
            }
            if let val = dict["realtime_rx_bytes"] {
                newStatus.realtimeRx = parseUInt64(val)
            }
            if let val = dict["realtime_tx_bytes"] {
                newStatus.realtimeTx = parseUInt64(val)
            }
            if let val = dict["day_rx_bytes"] ?? dict["today_rx_bytes"] {
                newStatus.dailyRx = parseUInt64(val)
            }
            if let val = dict["day_tx_bytes"] ?? dict["today_tx_bytes"] {
                newStatus.dailyTx = parseUInt64(val)
            }

            newStatus.trackedDaily = updateDailyTrafficTracking(
                currentMonthlyTotal: newStatus.monthlyTotal,
                currentSessionTotal: newStatus.sessionTotal
            )
            newStatus.trafficLimit = F50ResponseParser.parseTrafficLimit(from: dict)
            applyDetectedTrafficResetDay(from: dict)
            updateEffectiveTrafficResetDay()
            newStatus.trafficResetDay = self.status.trafficResetDay
        } else {
            newStatus.monthlyRx = status.monthlyRx
            newStatus.monthlyTx = status.monthlyTx
            newStatus.realtimeRx = status.realtimeRx
            newStatus.realtimeTx = status.realtimeTx
            newStatus.dailyRx = status.dailyRx
            newStatus.dailyTx = status.dailyTx
            newStatus.trackedDaily = status.trackedDaily
            newStatus.trafficLimit = status.trafficLimit
            updateEffectiveTrafficResetDay()
            newStatus.trafficResetDay = self.status.trafficResetDay
        }

        self.status = newStatus
    }

    private func updateDailyTrafficTracking(currentMonthlyTotal: UInt64, currentSessionTotal: UInt64) -> UInt64 {
        let defaults = UserDefaults.standard
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let todayStr = formatter.string(from: Date())

        let lastDate = defaults.string(forKey: "F50_DailyTrafficDate") ?? ""
        var startOfDayMonthlyBytes = UInt64(defaults.string(forKey: "F50_DailyTrafficStartBytes") ?? "") ?? 0

        let now = Date().timeIntervalSince1970
        let lastSeenBytes = UInt64(defaults.string(forKey: "F50_DailyTrafficLastSeenBytes") ?? "") ?? 0
        let lastSeenAt = defaults.double(forKey: "F50_DailyTrafficLastSeenAt")
        if currentMonthlyTotal > 0 {
            defaults.set(String(currentMonthlyTotal), forKey: "F50_DailyTrafficLastSeenBytes")
            defaults.set(now, forKey: "F50_DailyTrafficLastSeenAt")
        }

        if lastDate != todayStr {
            let baseline = F50ResponseParser.dailyBaseline(
                current: currentMonthlyTotal,
                lastSeen: lastSeenBytes,
                lastSeenAge: now - lastSeenAt
            )
            defaults.set(todayStr, forKey: "F50_DailyTrafficDate")
            defaults.set(String(baseline), forKey: "F50_DailyTrafficStartBytes")
            startOfDayMonthlyBytes = baseline
        } else if startOfDayMonthlyBytes == 0 && currentMonthlyTotal > 0 {
            defaults.set(String(currentMonthlyTotal), forKey: "F50_DailyTrafficStartBytes")
            startOfDayMonthlyBytes = currentMonthlyTotal
        }

        var calculatedDaily: UInt64 = 0
        if currentMonthlyTotal >= startOfDayMonthlyBytes {
            calculatedDaily = currentMonthlyTotal - startOfDayMonthlyBytes
        } else {
            defaults.set(String(currentMonthlyTotal), forKey: "F50_DailyTrafficStartBytes")
            calculatedDaily = 0
        }

        return max(calculatedDaily, currentSessionTotal)
    }

    private func parseInt(_ val: Any) -> Int {
        F50ResponseParser.parseInt(val)
    }

    private func parseDouble(_ val: Any) -> Double {
        F50ResponseParser.parseDouble(val)
    }

    private func parseUInt64(_ val: Any) -> UInt64 {
        F50ResponseParser.parseUInt64(val)
    }

}
