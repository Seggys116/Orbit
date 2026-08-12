import Foundation

// MARK: - One pull request

// Purely in-memory: never persisted, so a stale folder can never look live and wrong on relaunch.
nonisolated public struct GitHubPullRequest: Identifiable, Hashable, Sendable {

    public var id: String
    public var number: Int
    public var title: String
    public var ownerLogin: String
    public var repositoryName: String
    public var authorLogin: String
    public var isDraft: Bool
    public var isMerged: Bool
    public var state: String
    public var createdAt: Date?
    public var url: URL

    public init(
        id: String,
        number: Int,
        title: String,
        ownerLogin: String,
        repositoryName: String,
        authorLogin: String,
        isDraft: Bool,
        isMerged: Bool,
        state: String,
        createdAt: Date?,
        url: URL
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.ownerLogin = ownerLogin
        self.repositoryName = repositoryName
        self.authorLogin = authorLogin
        self.isDraft = isDraft
        self.isMerged = isMerged
        self.state = state
        self.createdAt = createdAt
        self.url = url
    }

    public var repositorySlug: String { "\(ownerLogin)/\(repositoryName)" }
}

// MARK: - Failure

nonisolated public enum GitHubLiveFolderError: Error, Equatable, Sendable {
    case signedOut
    case rateLimited
    case network(String)
    case badResponse(Int)
    case malformed(String)
}

// MARK: - Status

nonisolated public enum GitHubLiveFolderStatus: Equatable, Sendable {
    case idle
    case loading
    case loaded(Date)
    case failed(GitHubLiveFolderError, lastSuccess: Date?)
}

// MARK: - The persisted part

// Only this config reaches state.json; contents/timestamps are deliberately never persisted.
nonisolated public struct GitHubLiveFolderConfig: Codable, Hashable, Sendable {

    public var enabled: Bool?
    public var name: String?
    public var icon: String?
    public var iconIsEmoji: Bool?
    public var isExpanded: Bool?
    public var showsCreatedByMe: Bool?
    public var showsReviewRequests: Bool?

    public init(
        enabled: Bool? = nil,
        name: String? = nil,
        icon: String? = nil,
        iconIsEmoji: Bool? = nil,
        isExpanded: Bool? = nil,
        showsCreatedByMe: Bool? = nil,
        showsReviewRequests: Bool? = nil
    ) {
        self.enabled = enabled
        self.name = name
        self.icon = icon
        self.iconIsEmoji = iconIsEmoji
        self.isExpanded = isExpanded
        self.showsCreatedByMe = showsCreatedByMe
        self.showsReviewRequests = showsReviewRequests
    }

    public static let defaultName = "Pull Requests"

    // MARK: Non-optional accessors

    public var isEnabled: Bool {
        get { enabled ?? false }
        set { enabled = newValue }
    }

    public var displayName: String {
        get { name ?? Self.defaultName }
        set { name = newValue }
    }

    public var isExpandedOrDefault: Bool {
        get { isExpanded ?? true }
        set { isExpanded = newValue }
    }

    public var includesCreatedByMe: Bool {
        get { showsCreatedByMe ?? true }
        set { showsCreatedByMe = newValue }
    }

    public var includesReviewRequests: Bool {
        get { showsReviewRequests ?? true }
        set { showsReviewRequests = newValue }
    }

    public var isIconEmoji: Bool {
        get { iconIsEmoji ?? false }
        set { iconIsEmoji = newValue }
    }

    // MARK: Decoding

    // Every field decoded with try?, so an unreadable key costs that field, not the whole state.json.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil
        self.name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? nil
        self.icon = (try? container.decodeIfPresent(String.self, forKey: .icon)) ?? nil
        self.iconIsEmoji = (try? container.decodeIfPresent(Bool.self, forKey: .iconIsEmoji)) ?? nil
        self.isExpanded = (try? container.decodeIfPresent(Bool.self, forKey: .isExpanded)) ?? nil
        self.showsCreatedByMe = (try? container.decodeIfPresent(Bool.self, forKey: .showsCreatedByMe)) ?? nil
        self.showsReviewRequests = (try? container.decodeIfPresent(Bool.self, forKey: .showsReviewRequests)) ?? nil
    }
}
