import Foundation

public enum GeometryMsgs {
    /// `geometry_msgs/msg/Vector3`
    public struct Vector3: ROSMessage, Hashable {
        public static let rosType = "geometry_msgs/msg/Vector3"
        public var x: Double, y: Double, z: Double
        public init(x: Double = 0, y: Double = 0, z: Double = 0) {
            self.x = x; self.y = y; self.z = z
        }
    }

    /// `geometry_msgs/msg/Point`
    public struct Point: ROSMessage, Hashable {
        public static let rosType = "geometry_msgs/msg/Point"
        public var x: Double, y: Double, z: Double
        public init(x: Double = 0, y: Double = 0, z: Double = 0) {
            self.x = x; self.y = y; self.z = z
        }
    }

    /// `geometry_msgs/msg/Quaternion` — identity by default, as in ROS.
    public struct Quaternion: ROSMessage, Hashable {
        public static let rosType = "geometry_msgs/msg/Quaternion"
        public var x: Double, y: Double, z: Double, w: Double
        public init(x: Double = 0, y: Double = 0, z: Double = 0, w: Double = 1) {
            self.x = x; self.y = y; self.z = z; self.w = w
        }
    }

    /// `geometry_msgs/msg/Transform`
    public struct Transform: ROSMessage, Hashable {
        public static let rosType = "geometry_msgs/msg/Transform"
        public var translation: Vector3
        public var rotation: Quaternion
        public init(translation: Vector3 = .init(), rotation: Quaternion = .init()) {
            self.translation = translation
            self.rotation = rotation
        }
    }

    /// `geometry_msgs/msg/TransformStamped`
    public struct TransformStamped: ROSMessage, Hashable {
        public static let rosType = "geometry_msgs/msg/TransformStamped"
        public var header: StdMsgs.Header
        public var childFrameId: String
        public var transform: Transform
        public init(header: StdMsgs.Header, childFrameId: String, transform: Transform) {
            self.header = header
            self.childFrameId = childFrameId
            self.transform = transform
        }
    }

    /// `geometry_msgs/msg/Pose`
    public struct Pose: ROSMessage, Hashable {
        public static let rosType = "geometry_msgs/msg/Pose"
        public var position: Point
        public var orientation: Quaternion
        public init(position: Point = .init(), orientation: Quaternion = .init()) {
            self.position = position
            self.orientation = orientation
        }
    }

    /// `geometry_msgs/msg/PoseStamped`
    public struct PoseStamped: ROSMessage, Hashable {
        public static let rosType = "geometry_msgs/msg/PoseStamped"
        public var header: StdMsgs.Header
        public var pose: Pose
        public init(header: StdMsgs.Header, pose: Pose) {
            self.header = header
            self.pose = pose
        }
    }
}
