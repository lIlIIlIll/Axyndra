package agent_tui

import core.*

// Bridges semantic card retirement to the core presenter. The adapter owns
// monotonic batch identity and keeps a batch pending until the terminal draw
// has completed, so retries cannot duplicate scrollback.
class AgentPresentationAdapter {
    private let source: AgentTranscriptSource
    private var nextBatchIdValue: Int64 = 1
    private var pending: ?HistoryBatch = None

    init(source: AgentTranscriptSource) {
        this.source = source
    }

    func prepare(size: Rect): ?HistoryBatch {
        match (pending) {
            case Some(batch) => return Some(batch)
            case None => ()
        }
        let batch = source.prepareHistoryBatch(
            nextBatchIdValue,
            max(1, size.width - 4),
            replay: source.historyReplayRequested()
        )
        match (batch) {
            case Some(value) =>
                pending = Some(value)
                nextBatchIdValue++
                Some(value)
            case None => None
        }
    }

    func renderHistory(batchId: Int64, startRow: Int64, frame: Frame): Unit {
        match (pending) {
            case Some(batch) =>
                if (batch.id == batchId) {
                    renderHistoryBatch(batch, startRow, frame)
                }
            case None => ()
        }
    }

    func acknowledge(id: Int64): Unit {
        match (pending) {
            case Some(batch) =>
                if (batch.id == id) {
                    source.acknowledgeHistory(id)
                    pending = None
                }
            case None => ()
        }
    }

    func hasHistoryFollowUp(): Bool {
        source.hasHistoryAfterCurrentBatch()
    }
    func requestReplay(): Unit {
        pending = None
        source.requestHistoryReplay()
    }

    func generation(): Int64 {
        source.generation()
    }
}
