package agent_testkit

import std.collection.*

// One repeatable benchmark observation. None means the harness could not
// measure that boundary; callers must not silently turn unavailable data into
// zero latency or zero memory.
public class AgentBenchmarkSample {
    public let ttftMillis: ?Int64
    public let generationMillis: ?Int64
    public let outputTokens: ?Int64
    public let contextBuildMillis: ?Int64
    public let toolMillis: ?Int64
    public let renderMillis: ?Int64
    public let resumeMillis: ?Int64
    public let rssBytes: ?Int64

    public init(
        ttftMillis!: ?Int64 = None,
        generationMillis!: ?Int64 = None,
        outputTokens!: ?Int64 = None,
        contextBuildMillis!: ?Int64 = None,
        toolMillis!: ?Int64 = None,
        renderMillis!: ?Int64 = None,
        resumeMillis!: ?Int64 = None,
        rssBytes!: ?Int64 = None
    ) {
        for (value in [
            ttftMillis, generationMillis, outputTokens, contextBuildMillis,
            toolMillis, renderMillis, resumeMillis, rssBytes
        ]) {
            match (value) {
                case Some(number) => if (number < 0) {
                    throw IllegalArgumentException("benchmark metrics must not be negative")
                }
                case None => ()
            }
        }
        this.ttftMillis = ttftMillis
        this.generationMillis = generationMillis
        this.outputTokens = outputTokens
        this.contextBuildMillis = contextBuildMillis
        this.toolMillis = toolMillis
        this.renderMillis = renderMillis
        this.resumeMillis = resumeMillis
        this.rssBytes = rssBytes
    }

    // Tokens per second in milli-token/s fixed point. A zero-duration or
    // unavailable generation never fabricates throughput.
    public func tokensPerSecondMilli(): ?Int64 {
        match ((outputTokens, generationMillis)) {
            case (Some(tokens), Some(millis)) =>
                if (millis > 0) { Some(tokens * 1000000 / millis) } else { None }
            case _ => None
        }
    }
}

public class MetricDistribution {
    public let count: Int64
    public let minimum: ?Int64
    public let p50: ?Int64
    public let p95: ?Int64
    public let p99: ?Int64
    public let maximum: ?Int64
    public let mean: ?Int64

    init(values: Array<Int64>) {
        count = values.size
        if (values.isEmpty()) {
            minimum = None
            p50 = None
            p95 = None
            p99 = None
            maximum = None
            mean = None
            return
        }
        let ordered = sortedMetricValues(values)
        minimum = Some(ordered[0])
        p50 = Some(nearestRank(ordered, 50))
        p95 = Some(nearestRank(ordered, 95))
        p99 = Some(nearestRank(ordered, 99))
        maximum = Some(ordered[ordered.size - 1])
        var total: Int64 = 0
        for (value in ordered) { total += value }
        mean = Some(total / ordered.size)
    }
}

public class AgentBenchmarkSummary {
    public let totalSamples: Int64
    public let warmups: Int64
    public let samples: Int64
    public let ttftMillis: MetricDistribution
    public let generationMillis: MetricDistribution
    public let tokensPerSecondMilli: MetricDistribution
    public let contextBuildMillis: MetricDistribution
    public let toolMillis: MetricDistribution
    public let renderMillis: MetricDistribution
    public let resumeMillis: MetricDistribution
    public let rssBytes: MetricDistribution

    init(
        values: Array<AgentBenchmarkSample>,
        totalSamples!: Int64 = 0,
        warmups!: Int64 = 0
    ) {
        this.totalSamples = totalSamples
        this.warmups = warmups
        samples = values.size
        ttftMillis = MetricDistribution(collect(values, { value => value.ttftMillis }))
        generationMillis = MetricDistribution(collect(values, { value => value.generationMillis }))
        tokensPerSecondMilli = MetricDistribution(collect(values, { value => value.tokensPerSecondMilli() }))
        contextBuildMillis = MetricDistribution(collect(values, { value => value.contextBuildMillis }))
        toolMillis = MetricDistribution(collect(values, { value => value.toolMillis }))
        renderMillis = MetricDistribution(collect(values, { value => value.renderMillis }))
        resumeMillis = MetricDistribution(collect(values, { value => value.resumeMillis }))
        rssBytes = MetricDistribution(collect(values, { value => value.rssBytes }))
    }
}

public class AgentBenchmarkSeries {
    public let scenario: String
    public let warmupRuns: Int64
    private let values = ArrayList<AgentBenchmarkSample>()

    public init(scenario: String, warmupRuns!: Int64 = 1) {
        if (scenario.trimAscii() == "" || warmupRuns < 0) {
            throw IllegalArgumentException("benchmark scenario and warmup count are invalid")
        }
        this.scenario = scenario.trimAscii()
        this.warmupRuns = warmupRuns
    }

    public func add(sample: AgentBenchmarkSample): Unit { values.add(sample) }

    public func summary(): AgentBenchmarkSummary {
        let measured = ArrayList<AgentBenchmarkSample>()
        let discarded = min(warmupRuns, values.size)
        var index = discarded
        while (index < values.size) {
            measured.add(values[index])
            index += 1
        }
        AgentBenchmarkSummary(
            measured.toArray(),
            totalSamples: values.size,
            warmups: discarded
        )
    }
}

func collect(
    values: Array<AgentBenchmarkSample>,
    select: (AgentBenchmarkSample) -> ?Int64
): Array<Int64> {
    let result = ArrayList<Int64>()
    for (value in values) {
        match (select(value)) {
            case Some(number) => result.add(number)
            case None => ()
        }
    }
    result.toArray()
}

func sortedMetricValues(values: Array<Int64>): Array<Int64> {
    let result = values.clone()
    for (index in 1..result.size) {
        let current = result[index]
        var target = index
        while (target > 0 && result[target - 1] > current) {
            result[target] = result[target - 1]
            target -= 1
        }
        result[target] = current
    }
    result
}

func nearestRank(values: Array<Int64>, percentile: Int64): Int64 {
    let rank = max(1, (percentile * values.size + 99) / 100)
    values[min(values.size - 1, rank - 1)]
}
