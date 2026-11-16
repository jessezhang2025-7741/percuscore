/// Transient reader state. Never persists performance mode across app launches.
public struct PerformanceSession: Equatable {
    public private(set) var isActive = false
    public private(set) var exitVisible = false
    public init() {}
    public mutating func enter() { isActive = true; exitVisible = false }
    public mutating func exit() { isActive = false; exitVisible = false }
    public mutating func tapCenter() { if isActive { exitVisible.toggle() } }
    public mutating func pageTurned() { exitVisible = false }
    public func keepAwake(preference: Bool, appActive: Bool) -> Bool {
        appActive && (isActive || preference)
    }
}
