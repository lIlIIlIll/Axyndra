package clamp_fixture
main(): Int64 {
    if (clamp(5, 0, 10) != 5) { return 1 }
    if (clamp(0, 0, 10) != 0) { return 1 }
    if (clamp(10, 0, 10) != 10) { return 1 }
    if (clamp(-5, -10, -1) != -5) { return 1 }
    0
}
