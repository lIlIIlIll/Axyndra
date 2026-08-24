package orchestration_contract

import agent_domain.*
import task_runtime.*

main(): Int64 {
    verifyConcurrentMemoryTaskRepository()
    verifySameIdCreateSemantics()
    verifyTerminalTaskGenerationReuse()
    let tasks = TaskService(MemoryTaskRepository())
    let task = tasks.create(TaskId("task-1"), "research").value().getOrThrow()
    expect(isQueued(task.status), "new task is queued")
    let running = tasks.transition(
        task.taskId,
        TaskStatus.Running,
        runId: Some(RunId("child-1"))
    ).value().getOrThrow()
    expect(isRunning(running.status), "task lifecycle is independent")

    println("orchestration contract passed")
    0
}

func verifySameIdCreateSemantics(): Unit {
    let repository = MemoryTaskRepository()
    let tasks = TaskService(repository)
    let id = TaskId("same-id-create")
    let first = spawn { tasks.create(id, "candidate a").isOk() }
    let second = spawn { tasks.create(id, "candidate b").isOk() }
    let third = spawn { tasks.create(id, "candidate c").isOk() }
    let fourth = spawn { tasks.create(id, "candidate d").isOk() }
    let fifth = spawn { tasks.create(id, "candidate e").isOk() }
    let sixth = spawn { tasks.create(id, "candidate f").isOk() }
    let seventh = spawn { tasks.create(id, "candidate g").isOk() }
    let eighth = spawn { tasks.create(id, "candidate h").isOk() }
    var successes: Int64 = 0
    for (created in [
        first.get(),
        second.get(),
        third.get(),
        fourth.get(),
        fifth.get(),
        sixth.get(),
        seventh.get(),
        eighth.get()
    ]) {
        if (created) { successes += 1 }
    }
    let queued = repository.find(id).value().getOrThrow()
    expect(
        successes == 1 && queued.version == 0 && isQueued(queued.status),
        "same-id concurrent create installs exactly one queued generation"
    )
    let running = tasks.transition(id, TaskStatus.Running)
    expect(
        running.isOk() && running.value().getOrThrow().version == 1 &&
            tasks.create(id, "duplicate active generation").isError(),
        "expectedVersion zero still transitions queued work while active duplicate create conflicts"
    )
}

func verifyTerminalTaskGenerationReuse(): Unit {
    let repository = MemoryTaskRepository()
    let tasks = TaskService(repository)
    let id = TaskId("terminal-generation-reuse")
    tasks.create(id, "first generation").value().getOrThrow()
    tasks.transition(id, TaskStatus.Running).value().getOrThrow()
    let completed = tasks.transition(id, TaskStatus.Completed).value().getOrThrow()
    expect(completed.version == 2, "first generation reaches a terminal version")

    let next = tasks.create(id, "second generation").value().getOrThrow()
    expect(
        next.version == completed.version + 1 && next.title == "second generation" && isQueued(next.status),
        "a terminal task id starts a fresh queued generation with a monotonic CAS version"
    )
    expect(
        tasks.create(id, "duplicate second generation").isError(),
        "the recreated queued generation still rejects duplicate create"
    )
    let staleTransition = TaskRecord(
        id,
        "first generation",
        status: TaskStatus.Running,
        version: 1
    )
    expect(
        repository.save(staleTransition, 0).isError() && isQueued(repository.find(id).value().getOrThrow().status),
        "a delayed version-zero transition cannot mutate the replacement generation"
    )
}

func verifyConcurrentMemoryTaskRepository(): Unit {
    let repository = MemoryTaskRepository()
    let first = spawn { exerciseRepository(repository, "a") }
    let second = spawn { exerciseRepository(repository, "b") }
    let third = spawn { exerciseRepository(repository, "c") }
    let fourth = spawn { exerciseRepository(repository, "d") }
    let fifth = spawn { exerciseRepository(repository, "e") }
    let sixth = spawn { exerciseRepository(repository, "f") }
    let seventh = spawn { exerciseRepository(repository, "g") }
    let eighth = spawn { exerciseRepository(repository, "h") }
    expect(
        first.get() && second.get() && third.get() && fourth.get() && fifth.get() && sixth.get() && seventh.get() &&
            eighth.get(),
        "memory task repository serializes concurrent save and find access"
    )
}

func exerciseRepository(repository: MemoryTaskRepository, prefix: String): Bool {
    for (index in 0..200) {
        let id = TaskId(prefix + "-" + index.toString())
        let record = TaskRecord(id, "concurrent " + prefix)
        if (repository.save(record, 0).isError()) { return false }
        let restored = match (repository.find(id)) {
            case Result.Ok(value) => value
            case Result.Err(_) => return false
        }
        if (restored.taskId.value != id.value || restored.version != 0) { return false }
    }
    true
}

func expect(condition: Bool, message: String): Unit {
    if (!condition) {
        throw IllegalStateException("contract failed: ${message}")
    }
}

func isQueued(status: TaskStatus): Bool {
    match (status) {
        case TaskStatus.Queued => true
        case _ => false
    }
}

func isRunning(status: TaskStatus): Bool {
    match (status) {
        case TaskStatus.Running => true
        case _ => false
    }
}
