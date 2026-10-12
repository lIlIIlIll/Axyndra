package agent_product

import agent_host_runtime
import agent_host_runtime.*

import agent_domain.*
import yjson.*
import yjson_support.*

func serviceArtifactAppendText(args: AgentValue): String { agent_host_runtime.hostServiceArtifactAppendText(args) }

func serviceArtifactBase64(value: String): String { agent_host_runtime.hostServiceArtifactBase64(value) }

