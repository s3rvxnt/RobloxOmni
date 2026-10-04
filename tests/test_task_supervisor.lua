-- scratch/test_task_supervisor.lua
-- Test harness for Omni.TaskSupervisor & Omni.TaskDAG runtime concurrency diagnostics

local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

print("=== [TEST HARNESS]: Starting Omni TaskSupervisor Diagnostics ===")

-- 1. Ensure Omni.TaskSupervisor is initialized
local Supervisor = getgenv().Omni and getgenv().Omni.TaskSupervisor
local DAG = getgenv().Omni and getgenv().Omni.TaskDAG

if not Supervisor or not DAG then
    warn("[TEST HARNESS]: TaskSupervisor not loaded, loading module...")
    local ok, mod = pcall(function()
        if isfile and isfile("autoexec/kernel/TaskSupervisor.lua") then
            return loadstring(readfile("autoexec/kernel/TaskSupervisor.lua"))()
        elseif isfile and isfile("kernel/TaskSupervisor.lua") then
            return loadstring(readfile("kernel/TaskSupervisor.lua"))()
        end
    end)
    Supervisor = getgenv().Omni and getgenv().Omni.TaskSupervisor
    DAG = getgenv().Omni and getgenv().Omni.TaskDAG
end

assert(Supervisor, "Omni.TaskSupervisor must be loaded")
assert(DAG, "Omni.TaskDAG must be loaded")
print("[TEST HARNESS]: Omni.TaskSupervisor & TaskDAG validated.")

-- 2. Variables to hold thread and task references
local rootTaskNode = nil
local workerTaskNode = nil
local pollerTaskNode = nil
local heartbeatConn = nil
local computeIterations = 0
local pollTicks = 0

-- 3. Define the nested task hierarchy
local function supervisoryRoot()
    local myThread = coroutine.running()
    rootTaskNode = Supervisor.getTaskByThread(myThread)

    -- Attach engine frame step connection to supervisory root
    heartbeatConn = RunService.Heartbeat:Connect(function(dt)
        -- Monitoring sibling / engine tick
    end)

    -- Spawn Worker Pipeline (Child 1)
    local function computeWorker()
        local wThread = coroutine.running()
        workerTaskNode = Supervisor.getTaskByThread(wThread)

        -- Spawn Cyclic Polling Loop (Grandchild)
        local function cyclicPoller()
            local pThread = coroutine.running()
            pollerTaskNode = Supervisor.getTaskByThread(pThread)

            while true do
                pollTicks = pollTicks + 1
                Supervisor.recordIntrospection()
                local state = #game:GetChildren()
                task.wait(0.03)
            end
        end

        task.spawn(cyclicPoller)

        -- Perform compute-heavy workload
        while true do
            computeIterations = computeIterations + 1
            local acc = 0
            for i = 1, 10000 do
                acc = acc + math.sin(i) * math.cos(i)
            end
            task.wait(0.04)
        end
    end

    task.spawn(computeWorker)

    -- Keep root alive
    while true do
        task.wait(0.05)
    end
end

-- Launch the supervisory root
local rootThread = task.spawn(supervisoryRoot)

-- Allow tasks to run and accumulate execution slices & categorization metrics
print("[TEST HARNESS]: Allowing hierarchy to execute for 200ms...")
task.wait(0.20)

-- 4. Validate lineage & categorization
assert(rootTaskNode, "rootTaskNode must be registered")
assert(workerTaskNode, "workerTaskNode must be registered")
assert(pollerTaskNode, "pollerTaskNode must be registered")

local rootId = rootTaskNode.id
local workerId = workerTaskNode.id
local pollerId = pollerTaskNode.id

print(string.format("[TEST HARNESS]: Hierarchy spawned successfully:"))
print(string.format("  Root Task:      %s (%s)", rootId, rootTaskNode.name))
print(string.format("  Worker Task:    %s (%s)", workerId, workerTaskNode.name))
print(string.format("  Poller Task:    %s (%s)", pollerId, pollerTaskNode.name))

-- Check Parent-Child DAG relationships
assert(workerTaskNode.parentId == rootId, "Worker parentId must equal rootId")
assert(pollerTaskNode.parentId == workerId, "Poller parentId must equal workerId")
assert(rootTaskNode.children[workerId] ~= nil, "Root children must contain workerId")
assert(workerTaskNode.children[pollerId] ~= nil, "Worker children must contain pollerId")
print("[TEST HARNESS]: Directed Acyclic Graph (DAG) parent-child links verified.")

-- Check Workload Categorization
Supervisor.categorizeAllTasks()
assert(rootTaskNode.category == "EventSupervisory", "Root task must be categorized as EventSupervisory, got: " .. tostring(rootTaskNode.category))
assert(workerTaskNode.category == "ComputePipeline", "Worker task must be categorized as ComputePipeline, got: " .. tostring(workerTaskNode.category))
assert(pollerTaskNode.category == "CyclicPolling", "Poller task must be categorized as CyclicPolling, got: " .. tostring(pollerTaskNode.category))
print(string.format("[TEST HARNESS]: Workload Categorization verified: Root=%s, Worker=%s, Poller=%s",
    rootTaskNode.category, workerTaskNode.category, pollerTaskNode.category))

-- 5. Visualize Generated Task Tree
print("\n--- Visualized Task Tree ---")
local treeOutput = Supervisor.visualizeTree(rootId)
print(treeOutput)
print("----------------------------\n")

-- 6. Verify Structured Concurrency Lifecycle API: Pause & Resume
print("[TEST HARNESS]: Testing pauseTaskSubtree...")
local pausedList = Supervisor.pauseTaskSubtree(rootId)
print(string.format("[TEST HARNESS]: Paused %d tasks.", #pausedList))
assert(rootTaskNode.isPaused == true, "Root task should be paused")
assert(workerTaskNode.isPaused == true, "Worker task should be paused")
assert(pollerTaskNode.isPaused == true, "Poller task should be paused")

print("[TEST HARNESS]: Testing resumeTaskSubtree...")
local resumedList = Supervisor.resumeTaskSubtree(rootId)
print(string.format("[TEST HARNESS]: Resumed %d tasks.", #resumedList))
assert(rootTaskNode.isPaused == false, "Root task should be resumed")
assert(workerTaskNode.isPaused == false, "Worker task should be resumed")
assert(pollerTaskNode.isPaused == false, "Poller task should be resumed")

-- 7. Verify Topological Sort (Dependency Order)
local topoOrder = DAG.topologicalSort(rootId)
print(string.format("[TEST HARNESS]: Topological Sort (Leaf -> Root):"))
for idx, tId in ipairs(topoOrder) do
    local n = DAG.getNode(tId)
    print(string.format("  [%d] %s (%s)", idx, tId, n and n.name or "unknown"))
end

-- Assert leaf (poller) comes before parent (worker), and worker comes before root
local pollerIndex = table.find(topoOrder, pollerId)
local workerIndex = table.find(topoOrder, workerId)
local rootIndex = table.find(topoOrder, rootId)

assert(pollerIndex < workerIndex, "Poller must precede Worker in topological sort")
assert(workerIndex < rootIndex, "Worker must precede Root in topological sort")
print("[TEST HARNESS]: Topological leaf-to-root ordering verified.")

-- 8. Perform Ordered Shutdown
print("[TEST HARNESS]: Performing Supervisor.orderedShutdown...")
local shutdownReport = Supervisor.orderedShutdown(rootId)
print(string.format("[TEST HARNESS]: Ordered shutdown terminated %d tasks.", #shutdownReport))
for idx, entry in ipairs(shutdownReport) do
    print(string.format("  Shutdown [%d]: %s (%s, signals disconnected: %d)",
        idx, entry.id, entry.name, entry.signalsDisconnected))
end

-- Validate that all tasks are dead and cancelled
task.wait(0.05)
assert(coroutine.status(rootThread) == "dead", "Root thread must be dead")
assert(rootTaskNode.status == "dead", "Root taskNode status must be dead")
assert(workerTaskNode.status == "dead", "Worker taskNode status must be dead")
assert(pollerTaskNode.status == "dead", "Poller taskNode status must be dead")

if heartbeatConn then
    assert(heartbeatConn.Connected == false, "Heartbeat connection must be disconnected")
    print("[TEST HARNESS]: Attached RBXScriptConnection confirmed disconnected.")
end

-- 9. Full Execution Tree Export Validation
local exportTree = Supervisor.getExecutionTree(rootId, true)
assert(exportTree.id == rootId, "Export tree root id matches")
assert(#exportTree.children == 1, "Export tree root has 1 child")
assert(exportTree.children[1].id == workerId, "Export tree child 1 is worker")
assert(#exportTree.children[1].children == 1, "Export tree worker has 1 child")
assert(exportTree.children[1].children[1].id == pollerId, "Export tree grandchild is poller")
print("[TEST HARNESS]: Structured JSON/Tree Export format validated.")

print("\n=== [TEST HARNESS]: ALL CONCURRENCY DIAGNOSTICS TESTS PASSED 100% ===")

return {
    success = true,
    rootId = rootId,
    workerId = workerId,
    pollerId = pollerId,
    tree = treeOutput,
    shutdownSequence = shutdownReport,
    categories = {
        root = rootTaskNode.category,
        worker = workerTaskNode.category,
        poller = pollerTaskNode.category,
    },
}
