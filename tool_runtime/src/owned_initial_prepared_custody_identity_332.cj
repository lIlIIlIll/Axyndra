package tool_runtime

// Exact original data-custody binding of a Kernel-minted full Prepared debt.
// No Prepared getter, Source, permission, receipt, retirement or refund.
public func ownedKernelPreparedReferenceDebtMatchesCustody332(
    actual:OwnedKernelPreparedReferenceCustody,debt:OwnedKernelPreparedReferenceDebt):Bool{
    debt.matchesCustody(actual)
}
