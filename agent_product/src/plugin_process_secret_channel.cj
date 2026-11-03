package agent_product

import agent_host_runtime
import agent_domain.*

// Filtering wraps the same existing raw channel; it owns no native process.
type ProductProcessSecretChannel = agent_host_runtime.HostProcessSecretChannel

func processEnvironmentChannelError<T>(code: String): Result<T> {
    agent_host_runtime.hostProcessEnvironmentChannelError<T>(code)
}
