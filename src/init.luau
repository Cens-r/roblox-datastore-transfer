--!strict
local process = require("@lune/process")
local task = require("@lune/task")

local env = require("@self/utils/env")
assert(env.API_KEY, "Missing `API_KEY` variable in environment!")

local UNIVERSE_ID: { FROM: number?, TO: number? } = {}

local function set<T>(array: { T }): { [T]: true }
	local out = {}
	for _, value in array do
		out[value] = true
	end
	return out
end

local FLAG_ALIASES = { FROM = set({ "-f", "--from" }), TO = set({ "-t", "--to" }) }
do -- Handle universe id arguments:
	local index, args = 1, process.args
	while index <= #args do
		for key, alias in FLAG_ALIASES :: any do
			local flag = args[index]
			if not alias[flag] then
				continue
			end

			index += 1
			(UNIVERSE_ID :: any)[key] = args[index]
			break
		end
		index += 1
	end
end

assert(UNIVERSE_ID.FROM and typeof(UNIVERSE_ID.FROM), "Missing require `--from <UNIVERSE_ID>` arguments!")
assert(UNIVERSE_ID.TO and typeof(UNIVERSE_ID.TO), "Missing require `--to <UNIVERSE_ID>` arguments!")

local datastores = require("@self/datastores")

-- Transfer-from Universe's DataStores:
local from_list = datastores.list({
	api_key = env.API_KEY,
	universe_id = UNIVERSE_ID.FROM,
}, { pageToken = "*" })

-- Transfer-to Universe's DataStores:
local to_list = datastores.list({
	api_key = env.API_KEY,
	universe_id = UNIVERSE_ID.TO,
}, { pageToken = "*" })

for id, from_datastore in from_list do
	local to_datastore = to_list[id]
	if not to_datastore then
		print(`[SKIPPING]: Couldn't find '{id}' DataStore in the Universe ({UNIVERSE_ID.TO}) you're transfering to!`)
		continue
	end

	print(`[TRANSFER]: Starting for '{id}' DataStore:`)
	local keys: { datastores.DataStoreKey }, token: string?
	repeat
		keys, token = from_datastore:keys({ showDeleted = false })
		if #keys == 0 then
			break --> No more keys to process!
		end

		print(`* * * * * | Processing batch of {#keys} keys!`)
		for _, key in keys do
			local value = from_datastore:get(key)
			value = datastores.reassign(to_datastore, value) :: datastores.DataStoreValue
			to_datastore:set(value)
		end
	until not token
	print("-")
end
print("[COMPLETE]: Finished transfering process!")
