package logical_json_payload

// Fixed allocation failure category only. This carries neither an AgentError
// nor attempt/observation policy. Caller result objects pass through generic
// borrows unchanged, including errors the caller already owns.
public enum PayloadDataResult<T> {
    Ok(T) | Err(String)
    public func isOk(): Bool { match(this) { case Ok(_) => true; case Err(_) => false } }
    public func isError(): Bool { !isOk() }
    public func value(): ?T { match(this) { case Ok(value) => Some(value); case Err(_) => None<T> } }
    public func error(): ?String { match(this) { case Ok(_) => None<String>; case Err(code) => Some(code) } }
}
