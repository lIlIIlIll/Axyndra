package workflow_plugin

import agent_domain.*
import std.collection.*
import yjson.*
import yjson_support.*

// Native-owned schemas. Not registered until the actual canonical bridge is present.
func workflowProductTaskToolDefinition111(): ModelToolDefinition {
    ModelToolDefinition(
        "task",
        "Spawn typed child agents in durable child sessions. " +
            "Provide one task with optional context and agent (default task), " +
            "or shared context and between one and eight task items.",
        objectValue([
            ValueField("type", textValue("object")),
            ValueField("oneOf", listValue([
                workflowSingleTaskSchema111(),
                workflowObjectSchema111([
                    workflowSchemaProperty111("context", "string"),
                    workflowTaskItemsSchemaProperty111(),
                    workflowSchemaNetworkPolicyProperty111()
                ], ["context", "tasks"])
            ]))
        ])
    )
}

func workflowTaskItemSchemaProperties111(): Array<ValueField> {
    [workflowSchemaProperty111("name", "string"),
        workflowSchemaProperty111("agent", "string"),
        workflowSchemaProperty111("task", "string"),
        workflowSchemaAnyProperty111("outputSchema"),
        workflowSchemaEnumProperty111("schemaMode", ["permissive", "strict"])]
}

func workflowSingleTaskSchema111(): AgentValue {
    let properties = ArrayList<ValueField>()
    for (property in workflowTaskItemSchemaProperties111()) { properties.add(property) }
    properties.add(workflowSchemaProperty111("context", "string"))
    properties.add(workflowSchemaEnumProperty111("effort", ["lo", "med", "hi"]))
    properties.add(workflowSchemaNetworkPolicyProperty111())
    workflowObjectSchema111(properties.toArray(), ["task"])
}

func workflowProductHubToolDefinition111(): ModelToolDefinition {
    ModelToolDefinition(
        "hub",
        "Coordinate peers, manage background jobs, and " + "supervise project processes.",
        workflowObjectSchema111(
            [
                workflowSchemaEnumProperty111(
                    "op",
                    [
                        "send",
                        "wait",
                        "inbox",
                        "list",
                        "jobs",
                        "cancel",
                        "start",
                        "ps",
                        "logs",
                        "stop",
                        "restart",
                        "describe"
                    ]
                ),
                workflowSchemaProperty111("to", "string"),
                workflowSchemaProperty111("message", "string"),
                workflowSchemaProperty111("replyTo", "string"),
                workflowSchemaProperty111("await", "boolean"),
                workflowSchemaProperty111("from", "string"),
                workflowSchemaStringListProperty111("ids"),
                workflowSchemaProperty111("timeoutMs", "number"),
                workflowSchemaProperty111("peek", "boolean"),
                workflowSchemaProperty111("name", "string"),
                workflowSchemaProperty111("application", "string"),
                workflowSchemaStringListProperty111("args"),
                workflowSchemaStringMapProperty111("env"),
                workflowSchemaStringMapProperty111("env_from"),
                workflowSchemaStringMapProperty111("secret_env"),
                workflowSchemaNetworkPolicyProperty111(),
                workflowSchemaProperty111("cwd", "string"),
                workflowSchemaProperty111("pty", "boolean"),
                workflowSchemaHubReadyProperty111(),
                workflowSchemaEnumProperty111(
                    "restart",
                    ["no", "on-failure", "always"]
                ),
                workflowSchemaProperty111("persist", "boolean"),
                workflowSchemaProperty111("detached", "boolean"),
                workflowSchemaProperty111("lines", "number"),
                workflowSchemaProperty111("head", "boolean"),
                workflowSchemaProperty111("grep", "string"),
                workflowSchemaProperty111("follow", "boolean"),
                workflowSchemaProperty111("cursor", "number"),
                workflowSchemaEnumProperty111("for", ["ready", "exit"]),
                workflowSchemaProperty111("pattern", "string"),
                workflowSchemaProperty111("text", "string"),
                workflowSchemaProperty111("enter", "boolean"),
                workflowSchemaStringListProperty111("keys"),
                workflowSchemaEnumProperty111(
                    "signal",
                    [
                        "SIGINT",
                        "SIGTERM",
                        "SIGHUP",
                        "SIGQUIT",
                        "SIGKILL"
                    ]
                ),
                workflowSchemaProperty111("timeout", "number")
            ],
            ["op"]
        )
    )
}

func workflowSchemaProperty111(name: String, kind: String): ValueField {
    ValueField(name, objectValue([ValueField("type", textValue(kind))]))
}

func workflowSchemaStringMapProperty111(name: String): ValueField {
    ValueField(
        name,
        objectValue(
            [
                ValueField("type", textValue("object")),
                ValueField(
                    "additionalProperties",
                    objectValue([ValueField("type", textValue("string"))])
                )
            ]
        )
    )
}

func workflowSchemaStringListProperty111(name: String): ValueField {
    ValueField(name, objectValue([ValueField("type", textValue("array")),
        ValueField("items", objectValue([ValueField("type", textValue("string"))]))]))
}

func workflowSchemaHubReadyProperty111(): ValueField {
    ValueField(
        "ready",
        objectValue(
            [
                ValueField("type", textValue("object")),
                ValueField(
                    "properties",
                    objectValue(
                        [
                            workflowSchemaProperty111("log", "string"),
                            workflowSchemaProperty111("port", "number"),
                            workflowSchemaProperty111("host", "string"),
                            workflowSchemaProperty111("timeout", "number")
                        ]
                    )
                ),
                ValueField("additionalProperties", boolValue(false))
            ]
        )
    )
}

func workflowSchemaEnumProperty111(
    name: String,
    values: Array<String>
): ValueField {
    let encoded = ArrayList<AgentValue>()
    for (value in values) {
        encoded.add(textValue(value))
    }
    ValueField(
        name,
        objectValue(
            [
                ValueField("type", textValue("string")),
                ValueField("enum", listValue(encoded.toArray()))
            ]
        )
    )
}

func workflowSchemaAnyProperty111(name: String): ValueField {
    ValueField(
        name,
        objectValue(
            [
                ValueField(
                    "type",
                    listValue(
                        [
                            textValue("object"),
                            textValue("boolean"),
                            textValue("string"),
                            textValue("null")
                        ]
                    )
                )
            ]
        )
    )
}

func workflowSchemaYieldTypeProperty111(): ValueField {
    ValueField(
        "type",
        objectValue(
            [
                ValueField(
                    "anyOf",
                    listValue(
                        [
                            objectValue([ValueField("type", textValue("string"))]),
                            objectValue(
                                [
                                    ValueField("type", textValue("array")),
                                    ValueField("minItems", integerValue(1)),
                                    ValueField("items", objectValue([ValueField("type", textValue("string"))]))
                                ]
                            )
                        ]
                    )
                )
            ]
        )
    )
}

func workflowSchemaYieldResultProperty111(): ValueField {
    ValueField(
        "result",
        objectValue(
            [
                ValueField(
                    "anyOf",
                    listValue(
                        [
                            objectValue(
                                [
                                    ValueField("type", textValue("object")),
                                    ValueField("properties", objectValue([workflowSchemaProperty111("data", "object")])),
                                    ValueField("required", listValue([textValue("data")])),
                                    ValueField(
                                        "additionalProperties",
                                        boolValue(false)
                                    )
                                ]
                            ),
                            objectValue(
                                [
                                    ValueField("type", textValue("object")),
                                    ValueField("properties", objectValue([workflowSchemaProperty111("error", "string")])),
                                    ValueField("required", listValue([textValue("error")])),
                                    ValueField(
                                        "additionalProperties",
                                        boolValue(false)
                                    )
                                ]
                            ),
                            objectValue(
                                [
                                    ValueField("type", textValue("object")),
                                    ValueField("properties", objectValue([])),
                                    ValueField("required", listValue([])),
                                    ValueField(
                                        "additionalProperties",
                                        boolValue(false)
                                    )
                                ]
                            )
                        ]
                    )
                )
            ]
        )
    )
}

func workflowTaskItemsSchemaProperty111(): ValueField {
    ValueField(
        "tasks",
        objectValue(
            [
                ValueField("type", textValue("array")),
                ValueField("minItems", integerValue(1)),
                ValueField("maxItems", integerValue(8)),
                ValueField(
                    "items",
                    objectValue(
                        [
                            ValueField("type", textValue("object")),
                            ValueField(
                                "properties",
                                objectValue(workflowTaskItemSchemaProperties111())
                            ),
                            ValueField("required", listValue([textValue("task")])),
                            ValueField("additionalProperties", boolValue(false))
                        ]
                    )
                )
            ]
        )
    )
}

func workflowSchemaNetworkPolicyProperty111(): ValueField {
    let egressItem = objectValue([
        ValueField("type", textValue("object")),
        ValueField(
            "properties",
            objectValue([
                workflowSchemaProperty111("host", "string"),
                workflowSchemaProperty111("port", "number"),
                ValueField(
                    "private_addresses",
                    objectValue([
                        ValueField("type", textValue("array")),
                        ValueField(
                            "items",
                            objectValue([ValueField("type", textValue("string"))])
                        )
                    ])
                )
            ])
        ),
        ValueField("required", listValue([textValue("host"), textValue("port")])),
        ValueField("additionalProperties", boolValue(false))
    ])
    let publishItem = objectValue([
        ValueField("type", textValue("object")),
        ValueField(
            "properties",
            objectValue([
                workflowSchemaProperty111("host_port", "number"),
                workflowSchemaProperty111("target_port", "number")
            ])
        ),
        ValueField(
            "required",
            listValue([textValue("host_port"), textValue("target_port")])
        ),
        ValueField("additionalProperties", boolValue(false))
    ])
    ValueField(
        "network",
        objectValue([
            ValueField("type", textValue("object")),
            ValueField(
                "properties",
                objectValue([
                    workflowSchemaEnumProperty111("mode", ["denied", "proxy", "host"]),
                    ValueField(
                        "egress",
                        objectValue([
                            ValueField("type", textValue("array")),
                            ValueField("items", egressItem)
                        ])
                    ),
                    ValueField(
                        "publish",
                        objectValue([
                            ValueField("type", textValue("array")),
                            ValueField("items", publishItem)
                        ])
                    )
                ])
            ),
            ValueField("required", listValue([textValue("mode")])),
            ValueField("additionalProperties", boolValue(false))
        ])
    )
}

func workflowObjectSchema111(
    properties: Array<ValueField>,
    required: Array<String>
): AgentValue {
    let requiredValues = ArrayList<AgentValue>()
    for (name in required) { requiredValues.add(textValue(name)) }
    objectValue([ValueField("type", textValue("object")),
        ValueField("properties", objectValue(properties)),
        ValueField("required", listValue(requiredValues.toArray())),
        ValueField("additionalProperties", boolValue(false))])
}











func workflowYieldToolDefinition111(): ModelToolDefinition {
    ModelToolDefinition("yield", "Submit structured output from a delegated child agent.",
        workflowObjectSchema111([workflowSchemaYieldTypeProperty111(),workflowSchemaYieldResultProperty111()],["result"]))
}
func workflowDelegationTools111(): AgentValue {
    let definitions=[workflowProductTaskToolDefinition111(),workflowProductHubToolDefinition111(),workflowYieldToolDefinition111()]
    listValue(definitions.map{value=>objectValue([ValueField("name",textValue(value.name)),
        ValueField("description",textValue(value.description)),ValueField("input_schema",value.inputSchema)])})
}
