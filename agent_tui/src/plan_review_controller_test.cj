package agent_tui

import core.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class PlanReviewControllerTests {
    @TestCase
    func consumedSignalClosesBeforeExecutionResult(): Unit {
        let controller = PlanReviewController()
        let _ = controller.open("# Goal\n\nExecute the reviewed plan.")
        let contentHash = controller.probeSnapshot().contentHash
        let started = controller.updateKey(KeyEvent(KeyCode.Enter), false)
        @Assert(match (started.effect) {
            case Some(PlanReviewEffect.ReviewPlan(_, TuiPlanReviewDecision.ApproveFresh, _)) => true
            case _ => false
        })

        @Expect(controller.acceptConsumed(contentHash))
        @Expect(!controller.isActive())
        @Expect(!controller.hasPending())
        @Expect(controller.statusText(), "executing approved plan")
    }

    @TestCase
    func staleConsumedSignalCannotCloseANewerReview(): Unit {
        let controller = PlanReviewController()
        let _ = controller.open("# Goal\n\nKeep this newer plan open.")
        let currentHash = controller.probeSnapshot().contentHash
        let _ = controller.updateKey(KeyEvent(KeyCode.Enter), false)

        @Expect(!controller.acceptConsumed("stale-review-hash"))
        @Expect(controller.isActive())
        @Expect(controller.hasPending())
        @Expect(controller.probeSnapshot().contentHash, currentHash)
    }

    @TestCase
    func consumedExecutionFailureClosesTheReviewedPlan(): Unit {
        let controller = PlanReviewController()
        let _ = controller.open("# Goal\n\nExecute the reviewed plan.")
        let started = controller.updateKey(KeyEvent(KeyCode.Enter), false)
        @Assert(match (started.effect) {
            case Some(PlanReviewEffect.ReviewPlan(_, TuiPlanReviewDecision.ApproveFresh, _)) => true
            case _ => false
        })

        let forwarded = controller.acceptTurnResult(
            "error: fixture approved-plan execution failed",
            TuiTurnAction.NoAction,
            disposition: TuiPlanReviewDisposition.Consumed
        )

        @Expect(forwarded.isNone())
        @Expect(!controller.isActive())
        @Expect(!controller.hasPending())
        @Expect(controller.statusText(), "error: fixture approved-plan execution failed")
    }

    @TestCase
    func unconsumedReviewFailureKeepsThePlanRetryable(): Unit {
        let controller = PlanReviewController()
        let _ = controller.open("# Goal\n\nKeep this review available.")
        let contentHash = controller.probeSnapshot().contentHash
        let _ = controller.updateKey(KeyEvent(KeyCode.Enter), false)

        let forwarded = controller.acceptTurnResult(
            "plan changed since review opened",
            TuiTurnAction.NoAction,
            disposition: TuiPlanReviewDisposition.Retain
        )
        let retried = controller.updateKey(KeyEvent(KeyCode.Enter), false)

        @Expect(forwarded.isNone())
        @Expect(controller.isActive())
        @Expect(controller.hasPending())
        @Expect(match (retried.effect) {
            case Some(PlanReviewEffect.ReviewPlan(hash, TuiPlanReviewDecision.ApproveFresh, _)) => hash == contentHash
            case _ => false
        })
    }
}
