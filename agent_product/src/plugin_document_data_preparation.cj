package agent_product

import agent_host_runtime

import agent_host_runtime.*

import agent_domain.*
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.time.*
import yjson.*
import yjson_support.*

let PRODUCT_DOCUMENT_DATA_SCHEMA = agent_host_runtime.HOST_DOCUMENT_DATA_SCHEMA

type ProductDocumentDataPreparation = agent_host_runtime.HostDocumentDataPreparation

func productDocumentDataNibble(value:Byte):Int64 {
    agent_host_runtime.hostDocumentDataNibble(value)
}

func productDocumentDataReference(writer:ProductServiceArtifactWriter):AgentValue {
    agent_host_runtime.hostDocumentDataReference(writer)
}
