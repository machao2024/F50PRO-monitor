import Foundation

/// B28 原厂后台 AUTO_MODES；Only_5G 明确对应 SA。
public enum F50NetworkMode: String, CaseIterable, Identifiable {
    case automatic = "WL_AND_5G"
    case lteOnly = "Only_LTE"
    case sa = "Only_5G"
    case nsa = "LTE_AND_5G"
    case lteAnd3G = "WCDMA_AND_LTE"
    case wcdmaOnly = "Only_WCDMA"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: return "自动 5G"
        case .lteOnly: return "仅 4G"
        case .sa: return "5G SA"
        case .nsa: return "5G NSA"
        case .lteAnd3G: return "4G/3G"
        case .wcdmaOnly: return "仅 3G"
        }
    }
}

public enum F50NetworkModeError: LocalizedError {
    case busy, unavailable, requestFailed, notConfirmed

    public var errorDescription: String? {
        switch self {
        case .busy: return "正在切换网络，请稍候"
        case .unavailable: return "无法读取网络模式，请刷新后重试"
        case .requestFailed: return "切换网络模式失败，请稍后重试"
        case .notConfirmed: return "尚未确认模式已切换，请检查路由器后台"
        }
    }
}
