//
//  Models.swift
//  TxinKit
//
//  只覆盖 App 真正要用的字段，多余的靠 extra 兜住，避免接口变更就崩。
//

import Foundation

// MARK: - 通用响应壳

public struct TxinEnvelope<Payload: Decodable>: Decodable {
    public let status: String?
    public let data: Payload?
    public let error: String?
    public let errorCode: Int?
    public let time: String?

    public var ok: Bool { status == "y" }
}

/// 不解包 data 的轻量壳，用于任意接口探路
public struct TxinRawEnvelope: Decodable {
    public let status: String?
    public let error: String?
    public let errorCode: Int?
    public let time: String?
}

// MARK: - 会话

public struct TxinProfile: Codable {
    public var user_id: String?
    public var username: String?
    public var nickname: String?
    public var headico: String?
    public var token: String?
    public var is_vip: String?
    public var channel_code: String?
    public var has_login: String?

    public var isVIP: Bool { is_vip == "y" }
    public var isLoggedIn: Bool { has_login == "y" }
}

// MARK: - 视频

public struct TxinMovieList: Decodable {
    public let data: [TxinCategoryBlock]?
}

public struct TxinCategoryBlock: Decodable {
    public let id: String?
    public let name: String?
    public let intro: String?
    public let items: [TxinMovieBrief]?
}

public struct TxinMovieBrief: Decodable, Identifiable {
    public let id: String
    public let name: String?
    public let img: String?
    public let duration: String?
    public let click: String?
    public let love: String?
    public let favorite: String?
    public let pay_type: String?
    public let money: String?
    public let kouling: String?
    public let category: String?
    public let show_at: String?
    public let tags: [TxinTag]?

    public var isPaid: Bool { (pay_type ?? "").lowercased() == "vip" }
    public var coverURL: URL? { TxinCDN.rewrite(img).flatMap(URL.init(string:)) }

    /// 跨 module 构造需要显式 init（memberwise init 默认是 internal）
    public init(id: String, name: String?, img: String?, duration: String?,
                click: String?, love: String?, favorite: String?,
                pay_type: String?, money: String?, kouling: String?,
                category: String?, show_at: String?, tags: [TxinTag]?) {
        self.id = id
        self.name = name
        self.img = img
        self.duration = duration
        self.click = click
        self.love = love
        self.favorite = favorite
        self.pay_type = pay_type
        self.money = money
        self.kouling = kouling
        self.category = category
        self.show_at = show_at
        self.tags = tags
    }
}

public struct TxinTag: Decodable, Identifiable {
    public let id: String
    public let name: String?
}

public struct TxinMovieDetail: Decodable {
    public let id: String
    public let name: String?
    public let category: TxinTag?
    public let tags: [TxinTag]?
    public let img: String?
    public let click: String?
    public let love: String?
    public let favorite: String?
    public let duration: String?
    public let pay_type: String?
    public let money: String?
    public let layer_type: String?
    public let show_at: String?
    public let description: String?
    public let play_links: [TxinPlayLink]?

    public var isPaid: Bool { (pay_type ?? "").lowercased() == "vip" }
    public var coverURL: URL? { TxinCDN.rewrite(img).flatMap(URL.init(string:)) }
    public var bestLink: TxinPlayLink? { play_links?.first }
}

public struct TxinPlayLink: Decodable {
    public let id: String?
    public let code: String?
    public let name: String?
    public let m3u8_url: String?

    /// 线路标识（同一视频下多条线路的 id 相同，不能直接拿来当 Identifiable 的 id）
    public var ident: String { code ?? name ?? m3u8_url ?? UUID().uuidString }
}

// MARK: - 艺人

public struct TxinArtistHome: Decodable {
    public let top_up: [TxinArtist]?
    public let banner: [TxinBanner]?
}

public struct TxinArtist: Decodable, Identifiable {
    public let id: String
    public let nickname: String?
    public let headico: String?
    public let intro: String?
    public let height: String?
    public let tangxin_fans_count: String?
    public let works_count: String?

    public var avatarURL: URL? { TxinCDN.rewrite(headico).flatMap(URL.init(string:)) }
}

public struct TxinBanner: Decodable, Identifiable {
    public let id: String
    public let name: String?
    public let content: String?
    public let content_h5: String?
    public let link: String?

    public var imageURL: URL? { TxinCDN.rewrite(content).flatMap(URL.init(string:)) }
}

// MARK: - 系统

public struct TxinSystemInfo: Decodable {
    public let header: TxinHeader?
    public let upload_image_url: String?
    public let img_key: String?
    public let websocket_key: String?
    public let domain_statistic: [TxinDomainStat]?
}

public struct TxinHeader: Decodable {
    public let site_title: String?
    public let keywords: String?
    public let description: String?
}

public struct TxinDomainStat: Decodable, Identifiable {
    public let domain: String
    public let tracking_code: String?
    public var id: String { domain }
}

public struct TxinHome: Decodable {
    public let banner: [TxinBanner]?
    public let artist_list: [TxinArtist]?
    public let global_artist_fans: String?
    public let work_play_total: String?
    public let work_total: String?
    public let artist_total: String?
}

// MARK: - 标签检索

public struct TxinTagPage: Decodable {
    public let data: [TxinTagFull]?
    public let total: String?
    public let current_page: String?
    public let last_page: String?
}

public struct TxinTagFull: Decodable, Identifiable {
    public let id: String
    public let name: String?
    public let slug: String?
    public let is_hot: String?
}
