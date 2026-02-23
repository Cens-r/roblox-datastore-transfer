--!strict

-- Zune libraries:
local time = zune.time
local sqlite = zune.sqlite
local process = zune.process

local VALIDATE_DATASTORES: boolean = true
local MAX_PAGE_SIZE: number = 256

local ENVIRONMENT = process.env :: { API_KEY: string?, [string]: string }
assert(ENVIRONMENT.API_KEY, "Missing `API_KEY` variable in environment!")

local UNIVERSE_ID: { FROM: number?, TO: number? } = {}

-- Set constructor helper method:
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
			if not alias[flag] then continue end

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

local function drain<T>(method: (T?) -> T?, key: T?): ()
	repeat
		key = method(key)
	until key == nil
end

local TO_CTX: datastores.Context = {
	api_key = ENVIRONMENT.API_KEY,
	universe_id = UNIVERSE_ID.TO,
}
local FROM_CTX: datastores.Context = {
	api_key = ENVIRONMENT.API_KEY,
	universe_id = UNIVERSE_ID.FROM,
}

drain(function(ds_token: string?)
	local page: { datastores.DataStore }
	page, ds_token = datastores.list(FROM_CTX, { pageToken = ds_token, maxPageSize = MAX_PAGE_SIZE })

	for _, from_datastore in page do
		local identifier = from_datastore.id

		local to_datastore = datastores.get(TO_CTX, identifier, VALIDATE_DATASTORES)
		if not to_datastore then
			print(
				`[SKIPPING]: Couldn't find '{identifier}' DataStore in the Universe ({UNIVERSE_ID.TO}) you're transfering to!`
			)
			continue
		end

		print(`[TRANSFER]: Starting for '{identifier}' DataStore:`)
		drain(function(key_token: string?)
			local keys: { datastores.DataStoreKey }
			keys, key_token = from_datastore:keys({ showDeleted = false, maxPageSize = MAX_PAGE_SIZE })
			if #keys == 0 then return key_token end

			print(`* * * * * | Processing batch of {#keys} keys!`)
			for _, key in keys do
				local value = from_datastore:get(key)
				if value == nil then continue end
				value = datastores.reassign(to_datastore, value) :: datastores.DataStoreValue
				to_datastore:set(value)
			end

			return key_token
		end)
		print("-")
	end
	return ds_token
end)
print("[COMPLETE]: Finished transfering process!")
