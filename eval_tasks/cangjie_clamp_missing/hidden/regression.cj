package clamp_fixture
main(): Int64 {
    let cases = [(5, 0, 10, 5), (0, 0, 10, 0), (10, 0, 10, 10), (-5, -10, -1, -5)]
    for ((value, low, high, expected) in cases) {
        if (clamp(value, low, high) != expected) { return 1 }
    }
    0
}
