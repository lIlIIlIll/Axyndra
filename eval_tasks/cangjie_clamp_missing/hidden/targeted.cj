package clamp_fixture
main(): Int64 {
    if (clamp(-3, 0, 10) != 0) { return 1 }
    if (clamp(12, 0, 10) != 10) { return 1 }
    0
}
