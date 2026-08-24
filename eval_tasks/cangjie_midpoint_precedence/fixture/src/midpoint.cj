package division_fixture

// BUG: operator precedence makes this left + (right / 2).
public func midpoint(left: Int64, right: Int64): Int64 {
    left + right / 2
}
