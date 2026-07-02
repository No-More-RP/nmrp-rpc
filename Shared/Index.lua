---@class RegisteredRPCEvent
---@field invokingPackage string Not implemented yet
---@field callback fun(...: any)
---@field isRemote boolean
---@field name string

---@class PendingRPCEventRequest
---@field invokingPackage string Not implemented yet
---@field promise Promise
---@field name string

---@class RPCEvents
RPCEvents = {};

local currentRequestId = 0;
local pendingRequests <const> = {}; ---@type table<number, PendingRPCEventRequest>
local registeredEvents <const> = {}; ---@type table<string, RegisteredRPCEvent>

local table_unpack <const> = table.unpack;
local table_remove <const> = table.remove;

local subscribe <const> = Events.Subscribe;
local subscribe_remote <const> = Events.SubscribeRemote;
local call <const> = Events.Call;
local call_remote <const> = Events.CallRemote;

---@see https://feedback.nanos-world.com/ideas/p/cross-package-api-call-identification
---@return string
local function get_package_name()
    -- local name <const> = Package.GetName();
    -- return name:match("([^/\\]+)$") or name;
    return nil;
end

---@return number
local function get_next_request_id()
    currentRequestId = currentRequestId + 1;
    if (currentRequestId > 65535) then
        currentRequestId = 1;
    end
    return currentRequestId;
end

--- Emit a server->client RPC call. The first vararg is the target Player, the
--- rest are the event arguments. The pending request must already be registered
--- (see register_pending_request) — this only fires the wire call.
---@param eventName string
---@param requestId number
---@vararg any
local function emit_remote_from_server(eventName, requestId, ...)
    local args <const> = { ... };
    local player <const> = args[1]; ---@type Player

    table_remove(args, 1);

    call_remote("RPCEvents.Call", player, Reliability.Reliable, eventName, requestId, table_unpack(args));
end

---@param eventName string
---@return number requestId, Promise promise
local function register_pending_request(eventName)
    assert(type(eventName) == "string", "eventName must be a string");
    assert(#eventName > 0, "eventName must not be empty");

    local requestId <const> = get_next_request_id();
    local promise <const> = Promise();

    pendingRequests[requestId] = {
        invokingPackage = get_package_name(),
        promise = promise,
        name = eventName
    };
    return requestId, promise;
end

---@param eventName string
---@param callback fun(...: any)
---@param isRemote boolean
local function rpc_subscribe(eventName, callback, isRemote)
    assert(type(eventName) == "string", "eventName must be a string");
    assert(#eventName > 0, "eventName must not be empty");
    assert(type(callback) == "function", "callback must be a function");

    --- We can't clean up the events, so we are allowing re-registering the same event.
    --- @see https://feedback.nanos-world.com/ideas/p/cross-package-api-call-identification
    --- @see https://feedback.nanos-world.com/ideas/p/server-packages-events
    -- assert(not RPCEvents.Has(eventName), ("RPC event already exists: '%s'"):format(eventName));

    if (RPCEvents.Has(eventName)) then
        print(("RPC event '%s' is already registered, overwriting it.."):format(eventName));
    end

    local packageName <const> = get_package_name();

    registeredEvents[eventName] = {
        invokingPackage = packageName,
        callback = callback,
        isRemote = isRemote,
        name = eventName
    };
end

---@param callback fun(player: Player, ...: any) | fun(...: any)
---@param player Player | nil
---@param arg1 any | nil
---@vararg any
---@return boolean success, any result
local function sided_remote_pcall(callback, player, arg1, ...)
    if (Server) then
        return pcall(callback, player, ...);
    end
    return pcall(callback, arg1, ...);
end

---@param eventType 'RPCEVents.Reply' | 'RPCEvents.OnError'
---@param eventName string
---@param requestId number
---@param result any
---@param player Player | nil
local function side_remote_rpc_reply(eventType, eventName, requestId, result, player)
    if (Server) then
        call_remote(eventType, player, Reliability.Reliable, eventName, requestId, result);
        return;
    end
    call_remote(eventType, Reliability.Reliable, eventName, requestId, result);
end

---@see https://feedback.nanos-world.com/ideas/p/server-packages-events
-- subscribe('RPCEvents.OnPackageStop', function(package_name)
--     for requestId, data in pairs(pendingRequests) do
--         if (type(data) ~= 'table' or data.invokingPackage ~= package_name) then
--             goto continue;
--         end
--         if (data.promise and data.promise._state == 'pending') then
--             promise:Reject(("Package '%s' stopped"):format(package_name));
--         end
--         ::continue::
--     end
--     for eventName, eventData in pairs(registeredEvents) do
--         if (type(eventData) ~= 'table' or eventData.invokingPackage ~= package_name) then
--             goto continue;
--         end
--         registeredEvents[eventName] = nil;
--         ::continue::
--     end
-- end);

subscribe('RPCEvents.OnError', function(eventName, requestId, errorMessage)
    assert(type(eventName) == "string", "eventName must be a string");
    assert(#eventName > 0, "eventName must not be empty");

    local pendingRequest <const> = pendingRequests[requestId];

    if (pendingRequest and pendingRequest.promise) then
        pendingRequest.promise:Reject(errorMessage);
        pendingRequests[requestId] = nil;
    end

    Console.Error(("RPC event '%s' encountered an error: %s"):format(eventName, errorMessage));
end);

subscribe_remote('RPCEvents.OnError', function(playerOrEventName, eventNameOrRequestId, requestIdOrErrorMessage, errMessage)
    local player <const> = playerOrEventName; ---@type Player
    local eventName <const> = Server and eventNameOrRequestId or playerOrEventName; ---@type string
    local requestId <const> = Server and requestIdOrErrorMessage or eventNameOrRequestId; ---@type number
    local errorMessage <const> = Server and errMessage or requestIdOrErrorMessage; ---@type string

    assert(type(eventName) == "string", "eventName must be a string");
    assert(#eventName > 0, "eventName must not be empty");
    assert(type(requestId) == "number", "requestId must be a number");
    assert(type(errorMessage) == "string", "errorMessage must be a string");

    local pendingRequest <const> = pendingRequests[requestId];

    if (pendingRequest and pendingRequest.promise) then
        pendingRequest.promise:Reject(errorMessage);
        pendingRequests[requestId] = nil;
    end

    if (Client) then
        Console.Error(("RPC event '%s' encountered an error: %s"):format(eventName, errorMessage));
        return;
    end
    Console.Error(("Remote RPC event '%s' from '%s' encountered an error: %s"):format(eventName, player:GetAccountID(), errorMessage));
end);

subscribe('RPCEvents.Call', function(eventName, requestId, ...)
    assert(type(eventName) == "string", "eventName must be a string");
    assert(#eventName > 0, "eventName must not be empty");

    local eventData <const> = registeredEvents[eventName];

    if (not eventData) then
        print(("RPC event '%s' is not registered."):format(eventName));
        return;
    end

    local success <const>, result <const> = pcall(eventData.callback, ...);

    if (not success) then
        Console.Error(("Error while invoking RPC event '%s': %s"):format(eventName, result));
        call("RPCEvents.OnError", eventName, requestId, result);
        return;
    end

    local pendingRequest <const> = pendingRequests[requestId];

    if (pendingRequest and pendingRequest.promise) then
        pendingRequest.promise:Resolve(result);
        pendingRequests[requestId] = nil;
    end
end);

subscribe_remote('RPCEvents.Call', function(playerOrEventName, eventNameOrRequestId, requestIdOrArg1, ...)
    local player <const> = playerOrEventName; ---@type Player
    local eventName <const> = Server and eventNameOrRequestId or playerOrEventName; ---@type string
    local requestId <const> = Server and requestIdOrArg1 or eventNameOrRequestId; ---@type number
    local arg1 <const> = Server and eventNameOrRequestId or requestIdOrArg1; ---@type any

    assert(type(eventName) == "string", "eventName must be a string");
    assert(#eventName > 0, "eventName must not be empty");
    assert(type(requestId) == "number", "requestId must be a number");

    local eventData <const> = registeredEvents[eventName];

    if (not eventData) then
        print(("RPC event '%s' is not registered."):format(eventName));
        side_remote_rpc_reply('RPCEvents.OnError', eventName, requestId, "Event not registered", player);
        return;
    end

    local success <const>, result <const> = sided_remote_pcall(eventData.callback, player, arg1, ...);

    if (not success) then
        Console.Error(("Error while invoking remote RPC event '%s': %s"):format(eventName, result));
        side_remote_rpc_reply('RPCEvents.OnError', eventName, requestId, result, player);
        return;
    end

    side_remote_rpc_reply('RPCEvents.Reply', eventName, requestId, result, player);
end);

subscribe_remote('RPCEvents.Reply', function(playerOrEventName, eventNameOrRequestId, requestIdOrResult, resultOrNothing)
    local player <const> = playerOrEventName; ---@type Player
    local eventName <const> = Server and eventNameOrRequestId or playerOrEventName; ---@type string
    local requestId <const> = Server and requestIdOrResult or eventNameOrRequestId; ---@type number
    local result <const> = Server and resultOrNothing or requestIdOrResult; ---@type any

    assert(type(eventName) == "string", "eventName must be a string");
    assert(#eventName > 0, "eventName must not be empty");
    assert(type(requestId) == "number", "requestId must be a number");

    local pendingRequest <const> = pendingRequests[requestId];

    if (not pendingRequest) then
        Console.Error(("No pending request found for RPC event '%s' with request ID %d."):format(eventName, requestId));
        return;
    end

    if (pendingRequest.promise) then
        pendingRequest.promise:Resolve(result);
        pendingRequests[requestId] = nil;
    end
end);

--- Check if an rpc event is registered.
---@param eventName string
---@return boolean
function RPCEvents.Has(eventName)
    assert(type(eventName) == "string", "eventName must be a string");
    return registeredEvents[eventName] ~= nil;
end

--- Subscribe to an RPC event.
---@param eventName string
---@param callback fun(...: any)
function RPCEvents.Subscribe(eventName, callback)
    rpc_subscribe(eventName, callback, false);
end

--- Subscribe to a remote RPC event.
---@param eventName string
---@param callback fun(...: any) | fun(player: Player, ...: any)
function RPCEvents.SubscribeRemote(eventName, callback)
    rpc_subscribe(eventName, callback, true);
end

--- Call an RPC event and return the pending Promise WITHOUT awaiting it, so the
--- caller can chain `:Then` / `:Catch` without being inside a coroutine.
---
--- ```lua
--- RPCEvents.CallAsync("getTime"):Then(function(time) print(time); end);
--- ```
---@param eventName string
---@vararg any
---@return Promise
function RPCEvents.CallAsync(eventName, ...)
    local requestId <const>, promise <const> = register_pending_request(eventName);

    call("RPCEvents.Call", eventName, requestId, ...);

    return promise;
end

--- Call an RPC event and await the result. Must run inside a coroutine — except
--- on the local side, where the reply is synchronous so it also works on the main
--- thread.
---
--- ```lua
--- async(function() local time <const> = RPCEvents.Call("getTime"); end);
--- ```
---@async
---@param eventName string
---@vararg any
---@return any
function RPCEvents.Call(eventName, ...)
    return RPCEvents.CallAsync(eventName, ...):Await();
end

--- Call an RPC event remotely and return the pending Promise WITHOUT awaiting it.
--- On the server, the first vararg is the target Player.
---
--- ```lua
--- RPCEvents.CallRemoteAsync("ping", player):Then(function(r) print(r); end);
--- ```
---@param eventName string
---@vararg any
---@return Promise
---@overload fun(eventName: string, player: Player, ...: any): Promise
function RPCEvents.CallRemoteAsync(eventName, ...)
    local requestId <const>, promise <const> = register_pending_request(eventName);

    if (Server) then
        emit_remote_from_server(eventName, requestId, ...);
    else
        call_remote("RPCEvents.Call", Reliability.Reliable, eventName, requestId, ...);
    end

    return promise;
end

--- Call an RPC event remotely and await the result. Must run inside a coroutine.
--- On the server, the first vararg is the target Player.
---
--- ```lua
--- async(function() local r <const> = RPCEvents.CallRemote("ping", player); end);
--- ```
---@async
---@param eventName string
---@vararg any
---@return any
---@overload fun(eventName: string, player: Player, ...: any): any
function RPCEvents.CallRemote(eventName, ...)
    return RPCEvents.CallRemoteAsync(eventName, ...):Await();
end

Package.Export("RPCEvents", RPCEvents);
