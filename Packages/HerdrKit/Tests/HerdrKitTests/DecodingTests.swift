import Foundation
@testable import HerdrKit
import Testing

/// A recorded reply's `result`, from `Fixtures/` (see `record.sh` for the layout).
func fixture<T: Decodable>(_ name: String, _: T.Type) throws -> T {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try #require(JSONDecoder().decode(Reply<T>.self, from: Data(contentsOf: url)).result)
}

private func snapshot() throws -> Snapshot {
    try fixture("snapshot", SnapshotResult.self).snapshot
}

private func leaf(_ id: String) -> SplitNode {
    .leaf(paneID: id)
}

@Test func `snapshot decodes workspaces, tabs, panes and agents`() throws {
    let snapshot = try snapshot()
    #expect(snapshot.focusedWorkspaceID == "w1")
    #expect(snapshot.workspaces.map(\.id) == ["w1", "w2"])
    #expect(snapshot.workspaces[0].label == "one")
    #expect(snapshot.workspaces[0].activeTabID == "w1:t1")
    #expect(snapshot.tabs.map(\.id) == ["w1:t1", "w1:t2", "w2:t1", "w2:t2", "w2:t3"])
    #expect(snapshot.tabs[1].label == "second")
    #expect(snapshot.panes.count == 10)
    #expect(snapshot.panes[0].terminalID?.hasPrefix("term_") == true)
    #expect(snapshot.panes[0].tabID == "w1:t1")
    #expect(snapshot.workspaces[1].agentStatus == .working)
    #expect(snapshot.agents.map(\.paneID) == ["w1:p1", "w2:p2"])
}

@Test func `unknown fields and values do not fail decoding`() throws {
    let json = #"""
    {"workspaces":[{"workspace_id":"w1","number":1,"label":"x","active_tab_id":"w1:t1",
      "agent_status":"sleeping","new_field":{"a":[1]}}],
     "tabs":[],"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"}],"agents":[],"something_new":true,
     "layouts":[{"tab_id":"w1:t1","panes":[{"pane_id":"w1:p1"},{"pane_id":"w1:p2"}],
       "splits":[{"id":"split_0_root","direction":"diagonal","ratio":0.5}]}]}
    """#
    let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
    #expect(snapshot.workspaces[0].agentStatus == .unknown)
    #expect(snapshot.focusedWorkspaceID == nil)
    #expect(snapshot.panes[0].terminalID == nil)
    #expect(SplitNode(snapshot.layouts[0]) == .split(.right, ratio: 0.5, first: leaf("w1:p1"), second: leaf("w1:p2")))
}

@Test func `split tree rebuilds nested splits`() throws {
    let layouts = try Dictionary(uniqueKeysWithValues: snapshot().layouts.map { ($0.tabID, $0) })
    let w1t1 = try SplitNode(#require(layouts["w1:t1"]))
    #expect(w1t1 == .split(
        .right,
        ratio: 0.6,
        first: leaf("w1:p1"),
        second: .split(
            .down,
            ratio: 0.5,
            first: leaf("w1:p2"),
            second: .split(.right, ratio: 0.3, first: leaf("w1:p3"), second: leaf("w1:p4")),
        ),
    ))
    // A split under the root's first child.
    #expect(try SplitNode(#require(layouts["w2:t1"])) == .split(
        .down,
        ratio: 0.5,
        first: .split(.right, ratio: 0.5, first: leaf("w2:p1"), second: leaf("w2:p3")),
        second: leaf("w2:p2"),
    ))
    #expect(try SplitNode(#require(layouts["w1:t2"])) == leaf("w1:p5"))
    // layout.export gives the same tree, nested.
    #expect(try fixture("layout-export", ExportResult.self).layout.root == w1t1)
}

@Test func `split tree is nil when leaves and panes differ`() throws {
    let json = #"""
    [{"tab_id":"t","panes":[{"pane_id":"p1"},{"pane_id":"p2"}],
      "splits":[{"id":"split_0_root","direction":"right","ratio":0.5},
                {"id":"split_1_1","direction":"down","ratio":0.5}]},
     {"tab_id":"t","panes":[{"pane_id":"p1"},{"pane_id":"p2"}],"splits":[]}]
    """#
    let layouts = try JSONDecoder().decode([Layout].self, from: Data(json.utf8))
    #expect(SplitNode(layouts[0]) == nil) // too few panes
    #expect(SplitNode(layouts[1]) == nil) // too many panes
}
