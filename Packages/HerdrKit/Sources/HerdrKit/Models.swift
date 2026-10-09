// Lenient models of herdr's JSON: only the fields the app uses. Unknown fields are ignored and
// unknown enum values fall back, so a newer herdr does not break decoding.

public struct Snapshot: Decodable, Sendable {
    public let focusedWorkspaceID: String?
    public let workspaces: [Workspace]
    public let tabs: [Tab]
    public let panes: [Pane]
    public let agents: [Agent]
    let layouts: [Layout]
    /// Each tab's split tree by tab id. Filled by `HerdrClient.snapshot()`.
    public internal(set) var trees: [String: SplitNode] = [:]

    enum CodingKeys: String, CodingKey {
        case focusedWorkspaceID = "focused_workspace_id"
        case workspaces, tabs, panes, agents, layouts
    }
}

public struct Workspace: Decodable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let activeTabID: String
    public let agentStatus: AgentStatus

    enum CodingKeys: String, CodingKey {
        case id = "workspace_id", label, activeTabID = "active_tab_id", agentStatus = "agent_status"
    }
}

public struct Tab: Decodable, Sendable, Identifiable {
    public let id: String
    public let workspaceID: String
    public let label: String
    public let agentStatus: AgentStatus

    enum CodingKeys: String, CodingKey {
        case id = "tab_id", workspaceID = "workspace_id", label, agentStatus = "agent_status"
    }
}

public struct Pane: Decodable, Sendable, Identifiable {
    public let id: String
    /// Optional so one odd pane cannot fail the whole snapshot.
    public let terminalID: String?
    public let tabID: String
    public let label: String?

    enum CodingKeys: String, CodingKey {
        case id = "pane_id", terminalID = "terminal_id", tabID = "tab_id", label
    }
}

/// Only the pane: the events stream asks for status changes of agent panes.
public struct Agent: Decodable, Sendable {
    public let paneID: String

    enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
}

public enum AgentStatus: String, Decodable, Sendable {
    case idle, working, blocked, done, unknown

    public init(from decoder: any Decoder) throws {
        self = try Self(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct Session: Decodable, Sendable {
    public let name: String
    public let running: Bool
}

struct Layout: Decodable {
    let tabID: String
    let panes: [Pane]
    let splits: [Split]

    struct Pane: Decodable {
        let pane_id: String // swiftlint:disable:this identifier_name
    }

    struct Split: Decodable {
        let id: String
        let direction: SplitNode.Direction
        let ratio: Double
    }

    enum CodingKeys: String, CodingKey { case tabID = "tab_id", panes, splits }
}
