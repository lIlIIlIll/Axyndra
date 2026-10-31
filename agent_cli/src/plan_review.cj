package agent_cli

import agent_domain.modelPolicySha256Text

// The exact UTF-8 source digest shared by Host and frontend. Display labels
// are not source content; callers must pass the canonical body itself.
public func planReviewHash(value: String): String {
    modelPolicySha256Text(value)
}
