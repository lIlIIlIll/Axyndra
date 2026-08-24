package division_fixture

func checkCase(left: Int64, right: Int64, expected: Int64): Bool {
    let actual = midpoint(left, right)
    if (actual != expected) {
        eprintln("midpoint(${left}, ${right}): expected ${expected}, got ${actual}")
        return false
    }
    true
}

main(): Int64 {
    let cases = [(0, 0, 0), (4, 4, 4), (10, 20, 15), (-8, -2, -5)]
    for ((left, right, expected) in cases) {
        if (!checkCase(left, right, expected)) { return 1 }
    }
    0
}
