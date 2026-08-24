package division_fixture

func requireMidpoint(left: Int64, right: Int64, expected: Int64): Int64 {
    let actual = midpoint(left, right)
    if (actual != expected) {
        eprintln("midpoint(${left}, ${right}): expected ${expected}, got ${actual}")
        return 1
    }
    0
}

main(): Int64 {
    requireMidpoint(2, 8, 5)
}
