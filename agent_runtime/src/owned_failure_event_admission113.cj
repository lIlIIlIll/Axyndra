package agent_runtime

// Accepted transfers the exact input publication into a real delivery owner;
// it does not acknowledge output. Failed carries its own same-bank paid full
// error. Held gives no admission, completion or retry credit.
public enum OwnedFailureEventAdmissionOutcome113 {
    Accepted | Failed(OwnedFailureDataConsumer113) | Held
}
public interface OwnedFailureEventAdmission113 {
    func admitOwnedFailure113(value: OwnedFailureRunPublication113): OwnedFailureEventAdmissionOutcome113
}
