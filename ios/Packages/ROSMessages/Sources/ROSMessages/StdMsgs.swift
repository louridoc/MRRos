import Foundation

public enum StdMsgs {
    /// `std_msgs/msg/Header`
    public struct Header: ROSMessage, Hashable {
        public static let rosType = "std_msgs/msg/Header"
        public var stamp: BuiltinInterfaces.Time
        public var frameId: String

        public init(stamp: BuiltinInterfaces.Time = .init(), frameId: String = "") {
            self.stamp = stamp
            self.frameId = frameId
        }
    }

    /// `std_msgs/msg/String`
    public struct StringMessage: ROSMessage, Hashable {
        public static let rosType = "std_msgs/msg/String"
        public var data: String
        public init(data: String) {
            self.data = data
        }
    }

    /// `std_msgs/msg/Bool`
    public struct BoolMessage: ROSMessage, Hashable {
        public static let rosType = "std_msgs/msg/Bool"
        public var data: Bool
        public init(data: Bool) {
            self.data = data
        }
    }

    /// `std_msgs/msg/Int32`
    public struct Int32Message: ROSMessage, Hashable {
        public static let rosType = "std_msgs/msg/Int32"
        public var data: Int32
        public init(data: Int32) {
            self.data = data
        }
    }

    /// `std_msgs/msg/Float64`
    public struct Float64Message: ROSMessage, Hashable {
        public static let rosType = "std_msgs/msg/Float64"
        public var data: Double
        public init(data: Double) {
            self.data = data
        }
    }
}
