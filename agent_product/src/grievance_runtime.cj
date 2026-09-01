package agent_product

import yjson_support.*

import yjson.*

import agent_domain.*
import model_adapters.*
import std.collection.*
import std.convert.*
import std.fs.*

public class ProductGrievance {
    public let id: Int64
    public let model: String
    public let version: String
    public let tool: String
    public let report: String
    public let pushed: Bool

    public init(
        id: Int64,
        model: String,
        version: String,
        tool: String,
        report: String,
        pushed!: Bool = false
    ) {
        this.id = id
        this.model = model
        this.version = version
        this.tool = tool
        this.report = report
        this.pushed = pushed
    }
}

public class ProductGrievanceList {
    public let databaseFound: Bool
    public let rows: Array<ProductGrievance>

    public init(
        databaseFound: Bool,
        rows: Array<ProductGrievance>
    ) {
        this.databaseFound = databaseFound
        this.rows = rows
    }
}

public class ProductGrievanceClean {
    public let databaseFound: Bool
    public let deleted: Int64

    public init(databaseFound: Bool, deleted: Int64) {
        this.databaseFound = databaseFound
        this.deleted = deleted
    }
}

class ProductGrievanceRuntime {
    private let path: String

    init(settingsRoot: String) {
        path = settingsRoot + "/grievances.json"
    }

    func list(
        limit: Int64,
        tool: String
    ): Result<ProductGrievanceList> {
        let loaded = match (read()) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                return Result<ProductGrievanceList>.Err(error)
        }
        let rows = ArrayList<ProductGrievance>()
        var index = loaded.rows.size - 1
        while (index >= 0 && rows.size < limit) {
            let row = loaded.rows[index]
            if (tool == "" || row.tool == tool) { rows.add(row) }
            index -= 1
        }
        Result.Ok(ProductGrievanceList(
            loaded.databaseFound,
            rows.toArray()
        ))
    }

    func clean(
        id: ?Int64,
        tool: String,
        all: Bool
    ): Result<ProductGrievanceClean> {
        let loaded = match (read()) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                return Result<ProductGrievanceClean>.Err(error)
        }
        if (!loaded.databaseFound) {
            return Result.Ok(ProductGrievanceClean(false, 0))
        }
        let retained = ArrayList<ProductGrievance>()
        var deleted: Int64 = 0
        for (row in loaded.rows) {
            let remove = if (all) {
                true
            } else {
                match (id) {
                    case Some(value) => row.id == value
                    case None => tool != "" && row.tool == tool
                }
            }
            if (remove) {
                deleted += 1
            } else {
                retained.add(row)
            }
        }
        if (deleted > 0) {
            match (write(retained.toArray())) {
                case Result.Ok(_) => ()
                case Result.Err(error) =>
                    return Result<ProductGrievanceClean>.Err(error)
            }
        }
        Result.Ok(ProductGrievanceClean(true, deleted))
    }

    private func read(): Result<ProductGrievanceList> {
        if (!exists(Path(path))) {
            return Result.Ok(ProductGrievanceList(false, []))
        }
        let root = match (decodeAgentValue(
            try {
                String.fromUtf8(File.readFrom(path))
            } catch (error: Exception) {
                return grievanceError<ProductGrievanceList>(
                    "grievances.read_failed",
                    error.message,
                    path
                )
            },
            maxBytes: 4194304
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                return grievanceError<ProductGrievanceList>(
                    "grievances.parse_failed",
                    error.message,
                    path
                )
        }
        let values: Array<AgentValue> =
            match (root.field("grievances")) {
            case Some(value) =>
                if (value.unifiedKind != ValueKind.List) {
                    return grievanceError<ProductGrievanceList>(
                        "grievances.invalid_store",
                        "grievances must be a list",
                        path
                    )
                }
                value.items.toArray()
            case None => []
        }
        let rows = ArrayList<ProductGrievance>()
        for (value in values) {
            let id = grievanceInteger(value, "id")
            let tool = grievanceText(value, "tool")
            if (id < 1 || tool == "") {
                return grievanceError<ProductGrievanceList>(
                    "grievances.invalid_store",
                    "grievance entries require a positive id and tool",
                    path
                )
            }
            rows.add(ProductGrievance(
                id,
                grievanceText(value, "model"),
                grievanceText(value, "version"),
                tool,
                grievanceText(value, "report"),
                pushed: grievanceBoolean(value, "pushed")
            ))
        }
        Result.Ok(ProductGrievanceList(true, rows.toArray()))
    }

    private func write(rows: Array<ProductGrievance>): Result<Unit> {
        try {
            let parent = Path(path).parent
            if (!exists(parent)) {
                Directory.create(parent, recursive: true)
            }
            let values = ArrayList<AgentValue>()
            for (row in rows) {
                values.add(objectValue([
                    ValueField("id", integerValue(row.id)),
                    ValueField("model", textValue(row.model)),
                    ValueField("version", textValue(row.version)),
                    ValueField("tool", textValue(row.tool)),
                    ValueField("report", textValue(row.report)),
                    ValueField("pushed", boolValue(row.pushed))
                ]))
            }
            let source = encodeAgentValue(objectValue([
                ValueField("schema_version", integerValue(1)),
                ValueField("grievances", listValue(values.toArray()))
            ]))
            let temporary = path + ".tmp"
            try {
                File.writeTo(temporary, source.toArray())
                rename(temporary, to: path, overwrite: true)
            } catch (error: Exception) {
                try {
                    let _ = removeIfExists(temporary)
                } catch (_: Exception) {}
                throw error
            }
            Result.Ok(())
        } catch (error: Exception) {
            grievanceError<Unit>(
                "grievances.write_failed",
                error.message,
                path
            )
        }
    }
}

func grievanceText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(field) =>
            match (field.unifiedKind) {
                case ValueKind.Text => field.text
                case _ => ""
            }
        case None => ""
    }
}

func grievanceInteger(value: AgentValue, name: String): Int64 {
    match (value.field(name)) {
        case Some(field) =>
            match (field.unifiedKind) {
                case ValueKind.Number =>
                    try { Int64.parse(field.number) }
                    catch (_: Exception) { 0 }
                case _ => 0
            }
        case None => 0
    }
}

func grievanceBoolean(value: AgentValue, name: String): Bool {
    match (value.field(name)) {
        case Some(field) =>
            match (field.unifiedKind) {
                case ValueKind.Boolean => field.boolean
                case _ => false
            }
        case None => false
    }
}

func grievanceError<T>(
    code: String,
    message: String,
    path: String
): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.InvalidInput,
        code,
        message,
        fields: [ErrorField("path", path)]
    ))
}
