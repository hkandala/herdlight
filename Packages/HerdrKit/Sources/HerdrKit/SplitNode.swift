/// One tab's split tree, as herdr stores it.
public indirect enum SplitNode: Equatable, Sendable {
    case leaf(paneID: String)
    case split(Direction, ratio: Double, first: SplitNode, second: SplitNode)

    public enum Direction: String, Decodable, Sendable {
        case right, down

        /// herdr has only these two; anything else draws side by side rather than failing the snapshot.
        public init(from decoder: any Decoder) throws {
            self = try Self(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .right
        }
    }

    /// Rebuilds the tree from `snapshot.layouts[]`: a split's id is `split_<n>_<path>` with one digit
    /// per step from the root (`0` first, `1` second), and `panes[]` is depth-first. Nil when the
    /// leaves do not match the panes; then ask herdr with `layout.export`.
    init?(_ layout: Layout) {
        let splits = Dictionary(layout.splits.map { split in
            let path = split.id.split(separator: "_").last.map(String.init) ?? ""
            return (path == "root" ? "" : path, split)
        }, uniquingKeysWith: { first, _ in first })
        var panes = layout.panes.map(\.pane_id)[...]
        func build(_ path: String) -> SplitNode? {
            guard let split = splits[path] else { return panes.popFirst().map { .leaf(paneID: $0) } }
            guard let first = build(path + "0"), let second = build(path + "1") else { return nil }
            return .split(split.direction, ratio: split.ratio, first: first, second: second)
        }
        guard let root = build(""), panes.isEmpty else { return nil }
        self = root
    }
}

/// The nested form `layout.export` returns.
extension SplitNode: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, paneID = "pane_id", direction, ratio, first, second
    }

    public init(from decoder: any Decoder) throws {
        let node = try decoder.container(keyedBy: CodingKeys.self)
        if try node.decode(String.self, forKey: .type) == "split" {
            self = try .split(
                node.decode(Direction.self, forKey: .direction),
                ratio: node.decode(Double.self, forKey: .ratio),
                first: node.decode(SplitNode.self, forKey: .first),
                second: node.decode(SplitNode.self, forKey: .second),
            )
        } else {
            self = try .leaf(paneID: node.decode(String.self, forKey: .paneID))
        }
    }
}
