package division_fixture

main(): Int64 {
    let cases = [(0, 0, 0), (4, 4, 4), (10, 20, 15), (-8, -2, -5)]
    for ((left, right, expected) in cases) {
        let actual = midpoint(left, right)
        if (actual != expected) {
            eprintln("midpoint(${left}, ${right}): expected ${expected}, got ${actual}")
            return 1
        }
    }
    0
}
