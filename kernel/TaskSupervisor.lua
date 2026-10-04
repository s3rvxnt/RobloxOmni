--!stage Kernel
--!name TaskSupervisor
--!priority 1050
--[[
    ==============================================================================
    OMNI TASK SUPERVISOR & DIRECTED ACYCLIC GRAPH (DAG) RUNTIME SUBSYSTEM
    ==============================================================================
    A production-grade Luau concurrency diagnostics, task supervision, and lineage
    tracking engine. Transparently instruments asynchronous thread schedulers,
    constructs parent-child execution DAGs, categorizes background workloads,
    and provides structured concurrency lifecycle control (pause, resume, ordered
    topological shutdown).

    Zero external dependencies. Works standalone or integrated with Omni Kernel.

    [ COMPONENT 1: SCHEDULER INSTRUMENTATION LAYER ]
    - Transparently wraps task.spawn, task.defer, task.delay, task.wait, task.cancel,
      coroutine.create, and coroutine.wrap.
    - Preserves function environments, closures, signatures, and call stacks with zero
      proxy wrapper pollution (debug.info evaluates user closures at level 1).
    - Captures caller provenance: parent thread identifier, caller closure source/line
      via debug.info(level, "slna"), and timestamps.
    - Assigns unique, deterministic 64-bit hex handles (e.g., 0x0000000100000001).

    [ COMPONENT 2: DIRECTED ACYCLIC GRAPH (DAG) TASK REGISTRY ]
    - Maintains parent_task_id -> child_task_id relational hierarchy.
    - Weak table referencing (__mode = "k" / "v") to eliminate memory retention.
    - Tracks runtime lifecycle states: running, suspended, normal, dead.
    - Intercepts and binds RBXScriptConnection instances (RunService.Heartbeat,
      Stepped, RenderStepped, Pre/PostSimulation, and custom signals).

    [ COMPONENT 3: WORKLOAD CATEGORIZATION ENGINE ]
    - Automated classification of active tasks:
      1. CyclicPolling: recurring task.wait loops querying state / introspection.
      2. EventSupervisory: frame step listeners monitoring sibling tasks / states.
      3. ComputePipeline: compute-heavy transformation and serialization routines.
      4. OneShot: ephemeral single-execution tasks.
      5. Idle: suspended inactive coroutines.

    [ COMPONENT 4: STRUCTURED CONCURRENCY LIFECYCLE API ]
    - getExecutionTree(rootTaskId?) -> TaskDAGNode
    - pauseTaskSubtree(taskId) / resumeTaskSubtree(taskId)
    - terminateTask(taskId, disconnectSignals)
    - orderedShutdown(targetTaskId) -> topological post-order leaf-to-root termination
    - visualizeTree(rootTaskId?) -> formatted ASCII / Unicode hierarchy tree
    ==============================================================================
]]

local RunService = game:GetService("RunService")

-- Unified Idempotent Reload: Clean up prior instance if loaded
if getgenv()._OmniTaskSupervisorCleanUp and type(getgenv()._OmniTaskSupervisorCleanUp) == "function" then
    pcall(getgenv()._OmniTaskSupervisorCleanUp)
end

-- Native Pointer Cache (never overwritten across reloads)
local origTaskSpawn = getgenv()._OrigTaskSpawn or task.spawn
local origTaskDefer = getgenv()._OrigTaskDefer or task.defer
local origTaskDelay = getgenv()._OrigTaskDelay or task.delay
local origTaskWait = getgenv()._OrigTaskWait or task.wait
local origTaskCancel = getgenv()._OrigTaskCancel or task.cancel
local origCoroutineCreate = getgenv()._OrigCoroutineCreate or coroutine.create
local origCoroutineWrap = getgenv()._OrigCoroutineWrap or coroutine.wrap
local origCoroutineResume = getgenv()._OrigCoroutineResume or coroutine.resume
local origCoroutineYield = getgenv()._OrigCoroutineYield or coroutine.yield
local origCoroutineStatus = getgenv()._OrigCoroutineStatus or coroutine.status
local origCoroutineRunning = getgenv()._OrigCoroutineRunning or coroutine.running

getgenv()._OrigTaskSpawn = origTaskSpawn
getgenv()._OrigTaskDefer = origTaskDefer
getgenv()._OrigTaskDelay = origTaskDelay
getgenv()._OrigTaskWait = origTaskWait
getgenv()._OrigTaskCancel = origTaskCancel
getgenv()._OrigCoroutineCreate = origCoroutineCreate
getgenv()._OrigCoroutineWrap = origCoroutineWrap
getgenv()._OrigCoroutineResume = origCoroutineResume
getgenv()._OrigCoroutineYield = origCoroutineYield
getgenv()._OrigCoroutineStatus = origCoroutineStatus
getgenv()._OrigCoroutineRunning = origCoroutineRunning

-- 64-bit Deterministic Handle Generator
local sessionHigh = (math.floor(os.time()) % 0x7FFFFFFF)
local taskSequence = 0
local function generateTaskId()
    taskSequence = taskSequence + 1
    return string.format("0x%08X%08X", sessionHigh, taskSequence)
end

-- Task State & Weak Registry Tables
local threadToTask = setmetatable({}, { __mode = "k" }) -- thread -> TaskRecord
local taskToThread = setmetatable({}, { __mode = "v" }) -- taskId -> thread
local tasksById = {}                                   -- taskId -> TaskRecord
local rootTaskIds = {}                                 -- taskId -> true
local connectionToTaskId = setmetatable({}, { __mode = "k" }) -- conn -> taskId
local signalHooksInstalled = false
local origSignalConnects = {}

-- Task Supervisor & Task DAG Table Declarations
local TaskSupervisor = {}
local TaskDAG = {}

-- Helper: Safe caller context extraction without throwing
local function captureCallerContext(stackLevel)
    local ok, source, line, name, arity = pcall(debug.info, stackLevel or 3, "slna")
    if ok and source then
        return source, line or 0, (name and name ~= "") and name or "[anonymous]", arity or 0
    end
    return "[unknown]", 0, "[anonymous]", 0
end

-- Helper: Inspect target function directly
local function inspectFunction(targetFn)
    if type(targetFn) == "function" then
        local ok, source, line, name, arity = pcall(debug.info, targetFn, "slna")
        if ok and source then
            return source, line or 0, (name and name ~= "") and name or "[anonymous]", arity or 0
        end
    end
    return nil, nil, nil, nil
end

-- Registry: Allocate and link a new task node
local function registerTask(thread, targetFn, schedType, parentTaskId, callerLevel)
    local taskId = generateTaskId()
    local fnSource, fnLine, fnName, fnArity = inspectFunction(targetFn)
    local callerSource, callerLine, callerName, callerArity = captureCallerContext(callerLevel or 3)

    local finalName = fnName or callerName or "[anonymous]"
    local finalSource = fnSource or callerSource or "[unknown]"
    local finalLine = fnLine or callerLine or 0
    local finalArity = fnArity or callerArity or 0

    local taskNode = {
        id = taskId,
        parentId = parentTaskId,
        children = {},
        name = finalName,
        source = finalSource,
        line = finalLine,
        arity = finalArity,
        scheduledType = schedType or "spawn",
        createdAt = os.clock(),
        lastResumeTick = os.clock(),
        lastActiveTick = os.clock(),
        tickDelta = 0,
        totalDuration = 0,
        invocations = 0,
        yieldCount = 0,
        introspectionCount = 0,
        connections = {},
        status = "running",
        category = "OneShot",
        isPaused = false,
        isTerminated = false,
        metadata = {},
    }

    tasksById[taskId] = taskNode

    if thread then
        threadToTask[thread] = taskNode
        taskToThread[taskId] = thread
    end

    -- Relational DAG Linking
    if parentTaskId and tasksById[parentTaskId] then
        tasksById[parentTaskId].children[taskId] = taskNode
    else
        rootTaskIds[taskId] = true
    end

    -- Periodic memory pruning
    if taskSequence % 20 == 0 and TaskSupervisor.pruneDeadTasks then
        pcall(TaskSupervisor.pruneDeadTasks, 150)
    end

    return taskNode
end

-- Helper: Check if a subtree has any non-dead tasks
local function isSubtreeAlive(node)
    if not node then return false end
    if node.status ~= "dead" then return true end
    for _, child in pairs(node.children) do
        if isSubtreeAlive(child) then return true end
    end
    return false
end

-- ==============================================================================
-- WORKLOAD CATEGORIZATION ENGINE
-- ==============================================================================

local function categorizeTask(node)
    if not node then return "OneShot" end

    -- Update thread lifecycle status
    local th = taskToThread[node.id]
    local currentStatus = "dead"
    if th then
        local ok, s = pcall(origCoroutineStatus, th)
        if ok then currentStatus = s end
    end
    node.status = currentStatus

    -- Tally and prune dead connections
    local activeSignalCount = 0
    local hasFrameStepSignal = false
    if node.connections then
        for conn, meta in pairs(node.connections) do
            local isAlive = true
            if typeof(conn) == "RBXScriptConnection" then
                if conn.Connected == false then isAlive = false end
            elseif type(conn) == "table" and conn.Connected ~= nil then
                if conn.Connected == false then isAlive = false end
            end

            if isAlive then
                activeSignalCount = activeSignalCount + 1
                local sig = meta.signal or ""
                if sig:find("Heartbeat") or sig:find("Stepped") or sig:find("RenderStepped")
                   or sig:find("PostSimulation") or sig:find("PreSimulation") or sig:find("PreRender") then
                    hasFrameStepSignal = true
                end
            else
                node.connections[conn] = nil
            end
        end
    end

    -- Count child subtasks
    local childCount = 0
    for _, _ in pairs(node.children) do
        childCount = childCount + 1
    end

    -- Compute average execution slice
    local avgSlice = node.totalDuration / math.max(1, node.invocations)

    -- Classification Heuristics
    if hasFrameStepSignal then
        node.category = "EventSupervisory"
    elseif avgSlice > 0.0008 or node.totalDuration > 0.001 then
        node.category = "ComputePipeline"
    elseif node.yieldCount >= 2 or node.introspectionCount >= 3 then
        node.category = "CyclicPolling"
    elseif childCount > 0 then
        node.category = "EventSupervisory"
    elseif currentStatus == "dead" and node.yieldCount == 0 then
        node.category = "OneShot"
    elseif currentStatus == "suspended" and node.yieldCount == 0 and node.invocations == 0 then
        node.category = "Idle"
    else
        node.category = "OneShot"
    end

    return node.category
end

local function categorizeAllTasks()
    for _, node in pairs(tasksById) do
        categorizeTask(node)
    end
end

TaskSupervisor.categorizeTask = categorizeTask
TaskSupervisor.categorizeAllTasks = categorizeAllTasks

-- ==============================================================================
-- DAG QUERYING & TRAVERSAL (Omni.TaskDAG)
-- ==============================================================================

function TaskDAG.getNode(taskId)
    local node = tasksById[taskId]
    if node then categorizeTask(node) end
    return node
end

function TaskDAG.getChildren(taskId)
    local node = tasksById[taskId]
    if not node then return {} end
    local list = {}
    for _, child in pairs(node.children) do
        table.insert(list, child)
    end
    table.sort(list, function(a, b) return a.createdAt < b.createdAt end)
    return list
end

function TaskDAG.getParent(taskId)
    local node = tasksById[taskId]
    if not node or not node.parentId then return nil end
    return tasksById[node.parentId]
end

function TaskDAG.getRoots()
    local list = {}
    for rId, _ in pairs(rootTaskIds) do
        local rNode = tasksById[rId]
        if rNode then
            categorizeTask(rNode)
            table.insert(list, rNode)
        end
    end
    table.sort(list, function(a, b) return a.createdAt < b.createdAt end)
    return list
end

-- Topological Sort: Post-order depth-first traversal (Leaves visited BEFORE parents)
function TaskDAG.topologicalSort(targetTaskId)
    local order = {}
    local visited = {}

    local function visit(id)
        if visited[id] then return end
        visited[id] = true
        local node = tasksById[id]
        if not node then return end

        -- Visit all children first
        for childId, _ in pairs(node.children) do
            visit(childId)
        end

        table.insert(order, id)
    end

    if targetTaskId then
        visit(targetTaskId)
    else
        for rId, _ in pairs(rootTaskIds) do
            visit(rId)
        end
    end

    return order
end

function TaskDAG.traversePreOrder(rootTaskId, visitorFn)
    local visited = {}
    local function walk(id)
        if visited[id] then return end
        visited[id] = true
        local node = tasksById[id]
        if not node then return end
        visitorFn(node)
        for childId, _ in pairs(node.children) do
            walk(childId)
        end
    end
    walk(rootTaskId)
end

function TaskDAG.traversePostOrder(rootTaskId, visitorFn)
    local visited = {}
    local function walk(id)
        if visited[id] then return end
        visited[id] = true
        local node = tasksById[id]
        if not node then return end
        for childId, _ in pairs(node.children) do
            walk(childId)
        end
        visitorFn(node)
    end
    walk(rootTaskId)
end

-- ==============================================================================
-- STRUCTURED CONCURRENCY LIFECYCLE API
-- ==============================================================================

function TaskSupervisor.getTaskByThread(th)
    local target = th or origCoroutineRunning()
    local node = threadToTask[target]
    if node then categorizeTask(node) end
    return node
end

function TaskSupervisor.getExecutionTree(rootTaskId, includeDead)
    categorizeAllTasks()

    local function buildNodeExport(node)
        local sigList = {}
        if node.connections then
            for conn, meta in pairs(node.connections) do
                local isAlive = true
                if typeof(conn) == "RBXScriptConnection" and conn.Connected == false then isAlive = false end
                if type(conn) == "table" and conn.Connected == false then isAlive = false end
                if isAlive then
                    table.insert(sigList, meta.signal or "Signal")
                end
            end
        end

        local childrenExport = {}
        local childList = {}
        for _, cNode in pairs(node.children) do
            table.insert(childList, cNode)
        end
        table.sort(childList, function(a, b) return a.createdAt < b.createdAt end)
        for _, cNode in ipairs(childList) do
            table.insert(childrenExport, buildNodeExport(cNode))
        end

        return {
            id = node.id,
            parentId = node.parentId,
            name = node.name,
            source = node.source,
            line = node.line,
            arity = node.arity,
            scheduledType = node.scheduledType,
            status = node.status,
            category = node.category,
            createdAt = node.createdAt,
            totalDuration = node.totalDuration,
            invocations = node.invocations,
            tickDelta = node.tickDelta,
            isPaused = node.isPaused,
            signals = sigList,
            children = childrenExport,
        }
    end

    if rootTaskId then
        local node = tasksById[rootTaskId]
        if not node then return nil end
        return buildNodeExport(node)
    end

    -- Return complete forest under a virtual root
    local forest = {}
    local roots = TaskDAG.getRoots()
    for _, rNode in ipairs(roots) do
        if includeDead or isSubtreeAlive(rNode) then
            table.insert(forest, buildNodeExport(rNode))
        end
    end
    return {
        id = "root",
        name = "[TaskDAG Root]",
        status = "normal",
        category = "EventSupervisory",
        children = forest,
    }
end

function TaskSupervisor.pauseTaskSubtree(taskId)
    local paused = {}
    TaskDAG.traversePreOrder(taskId, function(node)
        if not node.isPaused then
            node.isPaused = true
            table.insert(paused, node.id)
        end
    end)
    return paused
end

function TaskSupervisor.resumeTaskSubtree(taskId)
    local resumed = {}
    TaskDAG.traversePreOrder(taskId, function(node)
        if node.isPaused then
            node.isPaused = false
            table.insert(resumed, node.id)
        end
    end)
    return resumed
end

function TaskSupervisor.terminateTask(taskId, disconnectSignals)
    local node = tasksById[taskId]
    if not node then return false end

    node.isTerminated = true
    node.status = "dead"

    -- Disconnect associated signals cleanly
    if disconnectSignals ~= false and node.connections then
        for conn, _ in pairs(node.connections) do
            pcall(function()
                if typeof(conn) == "RBXScriptConnection" then
                    conn:Disconnect()
                elseif type(conn) == "table" and type(conn.Disconnect) == "function" then
                    conn:Disconnect()
                end
            end)
        end
        table.clear(node.connections)
    end

    -- Cancel the thread safely via task.cancel
    local th = taskToThread[taskId]
    if th then
        local ok, s = pcall(origCoroutineStatus, th)
        if ok and s ~= "dead" then
            pcall(origTaskCancel, th)
        end
    end

    return true
end

function TaskSupervisor.orderedShutdown(targetTaskId)
    -- Compute topological sort: post-order ensures child tasks are shut down before parents
    local order = TaskDAG.topologicalSort(targetTaskId)
    local shutdownReport = {}
    for _, id in ipairs(order) do
        local node = tasksById[id]
        local name = node and node.name or "unknown"
        local connCount = 0
        if node and node.connections then
            for _ in pairs(node.connections) do connCount = connCount + 1 end
        end
        local ok = TaskSupervisor.terminateTask(id, true)
        table.insert(shutdownReport, {
            id = id,
            name = name,
            success = ok,
            signalsDisconnected = connCount,
        })
    end
    return shutdownReport
end

function TaskSupervisor.visualizeTree(rootTaskId, includeDead)
    categorizeAllTasks()
    local lines = {}

    local function formatNodeLine(node, prefix, isLast)
        local branch = isLast and "└── " or "├── "
        local activeConns = 0
        if node.connections then
            for conn, _ in pairs(node.connections) do
                local isAlive = true
                if typeof(conn) == "RBXScriptConnection" and conn.Connected == false then isAlive = false end
                if type(conn) == "table" and conn.Connected == false then isAlive = false end
                if isAlive then activeConns = activeConns + 1 end
            end
        end

        local sigStr = activeConns > 0 and string.format(", %d signals", activeConns) or ""
        local pauseStr = node.isPaused and " [PAUSED]" or ""
        local durationMs = (node.totalDuration or 0) * 1000
        local lineStr = string.format("%s%s[%s] \"%s\" (%s, %s%s, %.2fms)%s",
            prefix, branch, node.id, node.name or "[anonymous]", node.status or "unknown",
            node.category or "OneShot", sigStr, durationMs, pauseStr)
        table.insert(lines, lineStr)

        local nextPrefix = prefix .. (isLast and "    " or "│   ")
        local childList = {}
        for _, cNode in pairs(node.children) do
            table.insert(childList, cNode)
        end
        table.sort(childList, function(a, b) return a.createdAt < b.createdAt end)
        for i, cNode in ipairs(childList) do
            formatNodeLine(cNode, nextPrefix, i == #childList)
        end
    end

    if rootTaskId then
        local root = tasksById[rootTaskId]
        if not root then return "[TaskSupervisor]: Root task " .. tostring(rootTaskId) .. " not found." end
        formatNodeLine(root, "", true)
    else
        local roots = TaskDAG.getRoots()
        local filtered = {}
        for _, rNode in ipairs(roots) do
            if includeDead or isSubtreeAlive(rNode) then
                table.insert(filtered, rNode)
            end
        end
        if #filtered == 0 then return "[TaskSupervisor]: No active tracked tasks." end
        for i, rNode in ipairs(filtered) do
            formatNodeLine(rNode, "", i == #filtered)
        end
    end

    return table.concat(lines, "\n")
end

-- Diagnostic Introspection Logger
function TaskSupervisor.recordIntrospection()
    local curThread = origCoroutineRunning()
    local node = curThread and threadToTask[curThread]
    if node then
        node.introspectionCount = node.introspectionCount + 1
    end
end

-- Explicit Signal Binder
function TaskSupervisor.trackConnection(conn, signalName, ownerThread)
    local targetThread = ownerThread or origCoroutineRunning()
    local node = targetThread and threadToTask[targetThread]
    if node and conn then
        node.connections[conn] = {
            signal = signalName or "CustomSignal",
            connectedAt = os.clock(),
        }
        connectionToTaskId[conn] = node.id
    end
    return conn
end

-- Memory Maintenance: Evict expired dead tasks
function TaskSupervisor.pruneDeadTasks(maxDeadCount)
    local deadKeys = {}
    for id, node in pairs(tasksById) do
        if node.status == "dead" and next(node.children) == nil then
            table.insert(deadKeys, id)
        end
    end

    local threshold = maxDeadCount or 200
    if #deadKeys > threshold then
        table.sort(deadKeys, function(a, b)
            local na = tasksById[a]
            local nb = tasksById[b]
            return (na and na.createdAt or 0) < (nb and nb.createdAt or 0)
        end)
        local toRemove = #deadKeys - threshold
        for i = 1, toRemove do
            local deadId = deadKeys[i]
            tasksById[deadId] = nil
            rootTaskIds[deadId] = nil
        end
    end
end

-- ==============================================================================
-- SCHEDULER & THREAD INSTRUMENTATION LAYER
-- ==============================================================================

local function instrumentSchedulers()
    -- 1. task.spawn
    local customTaskSpawn = function(fnOrThread, ...)
        local callerThread = origCoroutineRunning()
        local parentTaskId = (callerThread and threadToTask[callerThread] and threadToTask[callerThread].id) or nil

        if type(fnOrThread) == "function" then
            local th = origCoroutineCreate(fnOrThread)
            registerTask(th, fnOrThread, "spawn", parentTaskId, 3)
            return origTaskSpawn(th, ...)
        elseif type(fnOrThread) == "thread" then
            local node = threadToTask[fnOrThread]
            if not node then
                registerTask(fnOrThread, nil, "spawn", parentTaskId, 3)
            else
                node.scheduledType = "spawn"
                if not node.parentId and parentTaskId and parentTaskId ~= node.id then
                    node.parentId = parentTaskId
                    if tasksById[parentTaskId] then
                        tasksById[parentTaskId].children[node.id] = node
                    end
                end
            end
            return origTaskSpawn(fnOrThread, ...)
        else
            return origTaskSpawn(fnOrThread, ...)
        end
    end

    -- 2. task.defer
    local customTaskDefer = function(fnOrThread, ...)
        local callerThread = origCoroutineRunning()
        local parentTaskId = (callerThread and threadToTask[callerThread] and threadToTask[callerThread].id) or nil

        if type(fnOrThread) == "function" then
            local th = origCoroutineCreate(fnOrThread)
            registerTask(th, fnOrThread, "defer", parentTaskId, 3)
            return origTaskDefer(th, ...)
        elseif type(fnOrThread) == "thread" then
            local node = threadToTask[fnOrThread]
            if not node then
                registerTask(fnOrThread, nil, "defer", parentTaskId, 3)
            else
                node.scheduledType = "defer"
                if not node.parentId and parentTaskId and parentTaskId ~= node.id then
                    node.parentId = parentTaskId
                    if tasksById[parentTaskId] then
                        tasksById[parentTaskId].children[node.id] = node
                    end
                end
            end
            return origTaskDefer(fnOrThread, ...)
        else
            return origTaskDefer(fnOrThread, ...)
        end
    end

    -- 3. task.delay
    local customTaskDelay = function(duration, fnOrThread, ...)
        local callerThread = origCoroutineRunning()
        local parentTaskId = (callerThread and threadToTask[callerThread] and threadToTask[callerThread].id) or nil

        if type(fnOrThread) == "function" then
            local th = origCoroutineCreate(fnOrThread)
            registerTask(th, fnOrThread, "delay", parentTaskId, 3)
            return origTaskDelay(duration, th, ...)
        elseif type(fnOrThread) == "thread" then
            local node = threadToTask[fnOrThread]
            if not node then
                registerTask(fnOrThread, nil, "delay", parentTaskId, 3)
            else
                node.scheduledType = "delay"
                if not node.parentId and parentTaskId and parentTaskId ~= node.id then
                    node.parentId = parentTaskId
                    if tasksById[parentTaskId] then
                        tasksById[parentTaskId].children[node.id] = node
                    end
                end
            end
            return origTaskDelay(duration, fnOrThread, ...)
        else
            return origTaskDelay(duration, fnOrThread, ...)
        end
    end

    -- 4. task.wait (incorporates structured pausing & delta tracking)
    local customTaskWait = function(dt)
        local curThread = origCoroutineRunning()
        local node = curThread and threadToTask[curThread]
        if node then
            local now = os.clock()
            local runSlice = now - (node.lastResumeTick or now)
            node.totalDuration = node.totalDuration + runSlice
            node.yieldCount = node.yieldCount + 1
            node.lastActiveTick = now

            -- Cooperative Pause: Hold execution while subtree is paused
            if node.isPaused then
                repeat
                    origTaskWait(0.05)
                until not node.isPaused or node.isTerminated
            end
        end

        local t0 = os.clock()
        local actualDt = origTaskWait(dt)
        local postWait = os.clock()

        if node then
            node.tickDelta = postWait - t0
            node.invocations = node.invocations + 1
            node.lastResumeTick = postWait
            node.lastActiveTick = postWait
        end

        return actualDt
    end

    -- 5. task.cancel
    local customTaskCancel = function(th)
        if type(th) == "thread" then
            local node = threadToTask[th]
            if node then
                node.status = "dead"
                node.isTerminated = true
            end
        end
        return origTaskCancel(th)
    end

    -- 6. coroutine.create
    local customCoroutineCreate = function(fn)
        local callerThread = origCoroutineRunning()
        local parentTaskId = (callerThread and threadToTask[callerThread] and threadToTask[callerThread].id) or nil
        local th = origCoroutineCreate(fn)
        registerTask(th, fn, "create", parentTaskId, 3)
        return th
    end

    -- 7. coroutine.wrap
    local customCoroutineWrap = function(fn)
        local callerThread = origCoroutineRunning()
        local parentTaskId = (callerThread and threadToTask[callerThread] and threadToTask[callerThread].id) or nil
        local th = origCoroutineCreate(fn)
        registerTask(th, fn, "wrap", parentTaskId, 3)
        return function(...)
            local status = origCoroutineStatus(th)
            if status == "dead" then
                error("cannot resume dead coroutine", 2)
            end
            local results = table.pack(origCoroutineResume(th, ...))
            if not results[1] then
                error(results[2], 2)
            end
            return table.unpack(results, 2, results.n)
        end
    end

    -- Apply replacements to global task table
    local setTableWritable = function(t)
        if setreadonly then pcall(setreadonly, t, false)
        elseif make_writeable then pcall(make_writeable, t) end
    end
    local setTableReadonly = function(t)
        if setreadonly then pcall(setreadonly, t, true)
        elseif make_readonly then pcall(make_readonly, t) end
    end

    setTableWritable(task)
    task.spawn = customTaskSpawn
    task.defer = customTaskDefer
    task.delay = customTaskDelay
    task.wait = customTaskWait
    task.cancel = customTaskCancel
    setTableReadonly(task)

    -- Apply replacements to coroutine table
    setTableWritable(coroutine)
    coroutine.create = customCoroutineCreate
    coroutine.wrap = customCoroutineWrap
    setTableReadonly(coroutine)
end

-- ==============================================================================
-- ENGINE SIGNAL INTERCEPTION LAYER
-- ==============================================================================

local function hookSignal(signal, signalName)
    if not signal or type(signal.Connect) ~= "function" then return end
    if origSignalConnects[signal] then return end

    if type(signal) == "table" then
        local origConnect = signal.Connect
        origSignalConnects[signal] = { kind = "table", orig = origConnect }
        signal.Connect = function(sig, callback)
            local callerThread = origCoroutineRunning()
            local curTask = callerThread and threadToTask[callerThread]
            local conn = origConnect(sig, callback)
            if curTask and conn then
                curTask.connections[conn] = {
                    signal = signalName or tostring(sig),
                    connectedAt = os.clock(),
                }
                connectionToTaskId[conn] = curTask.id
            end
            return conn
        end
    elseif typeof(signal) == "RBXScriptSignal" and hookfunction then
        local origConnect
        origConnect = hookfunction(signal.Connect, function(sig, callback)
            local callerThread = origCoroutineRunning()
            local curTask = callerThread and threadToTask[callerThread]
            local conn = origConnect(sig, callback)
            if curTask and conn then
                curTask.connections[conn] = {
                    signal = signalName or tostring(sig),
                    connectedAt = os.clock(),
                }
                connectionToTaskId[conn] = curTask.id
            end
            return conn
        end)
        origSignalConnects[signal] = { kind = "hook", orig = origConnect }
    end
end

local function instrumentEngineSignals()
    if signalHooksInstalled then return end
    signalHooksInstalled = true

    -- Hook proxied signals from KernelTaskManager if active, else raw RunService signals
    local proxiedSignals = getgenv()._VirtualSchedulerProxiedSignals
    if proxiedSignals and type(proxiedSignals) == "table" then
        for sigName, sigObj in pairs(proxiedSignals) do
            if sigObj and type(sigObj.Connect) == "function" then
                hookSignal(sigObj, "RunService." .. tostring(sigName))
            end
        end
    else
        pcall(function()
            hookSignal(RunService.Heartbeat, "RunService.Heartbeat")
            hookSignal(RunService.Stepped, "RunService.Stepped")
            hookSignal(RunService.RenderStepped, "RunService.RenderStepped")
        end)
    end
end

-- ==============================================================================
-- CLEANUP & UNINSTALLATION
-- ==============================================================================

local function uninstrumentAll()
    local setTableWritable = function(t)
        if setreadonly then pcall(setreadonly, t, false)
        elseif make_writeable then pcall(make_writeable, t) end
    end
    local setTableReadonly = function(t)
        if setreadonly then pcall(setreadonly, t, true)
        elseif make_readonly then pcall(make_readonly, t) end
    end

    setTableWritable(task)
    task.spawn = origTaskSpawn
    task.defer = origTaskDefer
    task.delay = origTaskDelay
    task.wait = origTaskWait
    task.cancel = origTaskCancel
    setTableReadonly(task)

    setTableWritable(coroutine)
    coroutine.create = origCoroutineCreate
    coroutine.wrap = origCoroutineWrap
    setTableReadonly(coroutine)

    -- Restore signal connects
    for sig, meta in pairs(origSignalConnects) do
        pcall(function()
            if meta.kind == "table" then
                sig.Connect = meta.orig
            elseif meta.kind == "hook" and hookfunction then
                hookfunction(sig.Connect, meta.orig)
            end
        end)
    end
    table.clear(origSignalConnects)
    signalHooksInstalled = false
end

getgenv()._OmniTaskSupervisorCleanUp = function()
    uninstrumentAll()
    getgenv()._OmniTaskSupervisorLoaded = false
end

-- Install Instrumentation
instrumentSchedulers()
instrumentEngineSignals()
getgenv()._OmniTaskSupervisorLoaded = true

-- Export to Omni namespace
getgenv().Omni = getgenv().Omni or {}
getgenv().Omni.TaskSupervisor = TaskSupervisor
getgenv().Omni.TaskDAG = TaskDAG

return TaskSupervisor
