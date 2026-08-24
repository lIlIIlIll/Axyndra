package grievances_contract

import agent_product.*
import std.fs.*
import tool_runtime.*

main(): Int64 {
    if (!exists(Path("target"))) {
        Directory.create("target", recursive: true)
    }
    let root = Directory.createTemp("target").toString()
    try {
        let product = openProduct(config: ProductConfig(
            settingsRoot: root + "/settings",
            stateRoot: root + "/state",
            workspaceRoot: root + "/workspace",
            fixture: true,
            approvalMode: ApprovalMode.Yolo,
            asyncEnabled: false
        )).value().getOrThrow()
        let session = product.applicationSession()

        let missing = session.listGrievances(
            20,
            ""
        ).value().getOrThrow()
        expect(
            !missing.databaseFound && missing.rows.isEmpty(),
            "missing store is distinguished from an empty store"
        )

        File.writeTo(
            root + "/settings/grievances.json",
            (
                "{\"schema_version\":1,\"grievances\":[" +
                "{\"id\":1,\"model\":\"a\",\"version\":\"1\"," +
                "\"tool\":\"read\",\"report\":\"first\"," +
                "\"pushed\":false}," +
                "{\"id\":2,\"model\":\"b\",\"version\":\"2\"," +
                "\"tool\":\"edit\",\"report\":\"second\"," +
                "\"pushed\":true}," +
                "{\"id\":3,\"model\":\"c\",\"version\":\"3\"," +
                "\"tool\":\"read\",\"report\":\"third\"," +
                "\"pushed\":false}]}"
            ).toArray()
        )
        let recent = session.listGrievances(
            2,
            ""
        ).value().getOrThrow()
        expect(
            recent.databaseFound &&
            recent.rows.size == 2 &&
            recent.rows[0].id == 3 &&
            recent.rows[1].id == 2,
            "lists newest grievances first with a stable limit"
        )
        let filtered = session.listGrievances(
            20,
            "read"
        ).value().getOrThrow()
        expect(
            filtered.rows.size == 2 &&
            filtered.rows[0].report == "third" &&
            filtered.rows[1].report == "first",
            "filters by exact tool name"
        )
        let cleaned = session.cleanGrievances(
            None,
            "read",
            false
        ).value().getOrThrow()
        expect(
            cleaned.databaseFound && cleaned.deleted == 2,
            "cleans every matching tool grievance"
        )
        let retained = session.listGrievances(
            20,
            ""
        ).value().getOrThrow()
        expect(
            retained.rows.size == 1 &&
            retained.rows[0].id == 2 &&
            retained.rows[0].pushed,
            "persists non-matching rows without losing fields"
        )
        expect(
            session.cleanGrievances(
                Some(2),
                "",
                false
            ).value().getOrThrow().deleted == 1 &&
            session.listGrievances(
                20,
                ""
            ).value().getOrThrow().rows.isEmpty(),
            "cleans one grievance by id"
        )

        File.writeTo(
            root + "/settings/grievances.json",
            "{not-json".toArray()
        )
        expect(
            session.listGrievances(20, "").isError(),
            "surfaces corrupt stores instead of replacing them"
        )

        println("grievances contract passed")
        0
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
