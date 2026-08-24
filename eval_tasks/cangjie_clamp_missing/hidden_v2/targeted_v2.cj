package clamp_fixture
main(): Int64 {
    let below = clamp(-3, 0, 10)
    let above = clamp(12, 0, 10)
    if (below == 0 && above == 10) { 0 } else { 1 }
}
