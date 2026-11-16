import Foundation

public enum TF2Msgs {
    /// `tf2_msgs/msg/TFMessage`
    public struct TFMessage: ROSMessage, Hashable {
        public static let rosType = "tf2_msgs/msg/TFMessage"
        public var transforms: [GeometryMsgs.TransformStamped]
        public init(transforms: [GeometryMsgs.TransformStamped] = []) {
            self.transforms = transforms
        }
    }
}
