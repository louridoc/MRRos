import Foundation

public enum BuiltinInterfaces {
    /// `builtin_interfaces/msg/Time`
    public struct Time: ROSMessage, Hashable, Comparable {
        public static let rosType = "builtin_interfaces/msg/Time"
        public var sec: Int32
        public var nanosec: UInt32

        public init(sec: Int32 = 0, nanosec: UInt32 = 0) {
            self.sec = sec
            self.nanosec = nanosec
        }

        /// Seconds since the ROS epoch (Unix epoch for wall-clock time).
        public var seconds: Double {
            Double(sec) + Double(nanosec) * 1e-9
        }

        public init(seconds: Double) {
            let whole = seconds.rounded(.down)
            sec = Int32(whole)
            nanosec = UInt32(((seconds - whole) * 1e9).rounded())
        }

        public static func < (lhs: Time, rhs: Time) -> Bool {
            (lhs.sec, lhs.nanosec) < (rhs.sec, rhs.nanosec)
        }
    }

    /// `builtin_interfaces/msg/Duration`
    public struct Duration: ROSMessage, Hashable {
        public static let rosType = "builtin_interfaces/msg/Duration"
        public var sec: Int32
        public var nanosec: UInt32

        public init(sec: Int32 = 0, nanosec: UInt32 = 0) {
            self.sec = sec
            self.nanosec = nanosec
        }

        public var seconds: Double {
            Double(sec) + Double(nanosec) * 1e-9
        }
    }
}

public typealias ROSTime = BuiltinInterfaces.Time
