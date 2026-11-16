import Foundation

public enum SensorMsgs {
    /// `sensor_msgs/msg/JointState`. Arrays may be empty or shorter than `name` (ROS allows it).
    public struct JointState: ROSMessage, Hashable {
        public static let rosType = "sensor_msgs/msg/JointState"
        public var header: StdMsgs.Header
        public var name: [String]
        public var position: [Double]
        public var velocity: [Double]
        public var effort: [Double]

        public init(
            header: StdMsgs.Header = .init(),
            name: [String] = [],
            position: [Double] = [],
            velocity: [Double] = [],
            effort: [Double] = []
        ) {
            self.header = header
            self.name = name
            self.position = position
            self.velocity = velocity
            self.effort = effort
        }

        /// Joint name → position, for the joints that have a position entry.
        public var positionsByName: [String: Double] {
            var out: [String: Double] = [:]
            for (i, n) in name.enumerated() where i < position.count {
                out[n] = position[i]
            }
            return out
        }
    }
}
