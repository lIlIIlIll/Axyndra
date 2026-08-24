package division_fixture

main(): Int64 {
    let actual = midpoint(2, 8)
    if (actual != 5) {
        eprintln("expected midpoint(2, 8) == 5, got ${actual}")
        return 1
    }
    0
}
