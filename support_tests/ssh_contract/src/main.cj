package ssh_contract

import agent_domain.*
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

        let empty = session.listSshHosts().value().getOrThrow()
        expect(
            empty.project.isEmpty() && empty.user.isEmpty(),
            "missing config files produce empty scopes"
        )
        expect(session.addSshHost(
            "user",
            ProductSshHost(
                "alpha",
                "example.com",
                username: "elliot",
                port: Some(2222),
                keyPath: "/tmp/key",
                description: "demo",
                compat: true
            )
        ).isOk(), "adds a complete user host")
        expect(session.addSshHost(
            "project",
            ProductSshHost("beta", "10.0.0.2")
        ).isOk(), "adds a project host")

        let listed = session.listSshHosts().value().getOrThrow()
        expect(
            listed.project.size == 1 &&
            listed.project[0].name == "beta" &&
            listed.user.size == 1 &&
            listed.user[0].name == "alpha" &&
            listed.user[0].username == "elliot" &&
            listed.user[0].port == Some(2222) &&
            listed.user[0].compat,
            "round-trips every public host field"
        )
        expect(
            exists(Path(root + "/settings/ssh.json")) &&
            exists(Path(root + "/workspace/.axyndra/ssh.json")),
            "stores user and project scopes independently"
        )
        expect(session.addSshHost(
            "user",
            ProductSshHost("alpha", "duplicate.example")
        ).isError(), "rejects duplicate names")
        expect(session.addSshHost(
            "user",
            ProductSshHost("bad/name", "example.com")
        ).isError(), "rejects unsafe names")
        expect(
            session.removeSshHost("user", "missing").isError(),
            "rejects removal of a missing host"
        )
        expect(
            session.removeSshHost("user", "alpha").isOk() &&
            session.listSshHosts().value().getOrThrow()
                .user.isEmpty(),
            "removes the requested host durably"
        )

        File.writeTo(
            root + "/settings/ssh.json",
            "{not-json".toArray()
        )
        expect(
            session.listSshHosts().isError(),
            "surfaces corrupt config instead of replacing it"
        )

        println("ssh contract passed")
        0
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalStateException(message) }
}
