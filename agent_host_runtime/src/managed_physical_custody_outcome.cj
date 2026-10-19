package agent_host_runtime

import agent_domain.*

// Fixed bounded callback cell; the original dynamic grant pays it while the
// actual native stream custody callback runs. No result DOM is stored here.
class HostManagedPhysicalCustodyOutcome {
    var value:?Result<Unit>=None<Result<Unit>>
}
