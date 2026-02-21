--!strict

local net = require("@lune/net")
local serde = require("@lune/serde")
local task = require("@lune/task")

local MAX_RETRY_COUNT: number = 5

local BASE_URL: string = "https://apis.roblox.com/cloud/v2"
local HEADERS = {
	API_KEY = "x-api-key",
	RATE_LIMIT_RESET = "x-ratelimit-reset",
	CONTENT_TYPE = "content-type",
}

export type Context = {
	api_key: string,
	universe_id: number,
}
local function hide_context(ctx: Context): Context
	local metatable = getmetatable(ctx) or {} :: any
	metatable.__tostring = `[ Universe ID = {ctx.universe_id} ]`
	return setmetatable(ctx, metatable)
end

local EXPANSION_TOKEN = "*" :: "*"
local function handle_expansion<T>(generator: (string?) -> string?, token: string?): string?
	if token ~= EXPANSION_TOKEN then
		return generator(token)
	end

	token = nil
	repeat
		token = generator(token)
	until not token
	return nil
end

local function build_query(params: { [string]: unknown }?): string
	if not params then
		return ""
	end
	local queries: { string } = {}
	for key, value in params do
		table.insert(queries, `{key}={value}`)
	end
	return if #queries > 0 then "?" .. table.concat(queries, "&") else ""
end

type RequestMethod = "GET" | "POST" | "PATCH" | "DELETE"
type RequestBody = { type: string, content: string }
type RequestParams = {
	-- Required Parameters:
	api_key: string,
	path: string,

	-- Optional parameters:
	method: RequestMethod?,
	body: RequestBody?,
	query: { [string]: unknown }?,
}

local function request(params: RequestParams): net.FetchResponse
	local body = (params.body or {} :: RequestBody)
	local config: net.FetchParams = {
		method = params.method,
		url = `{BASE_URL}/{params.path}{build_query(params.query)}`,
		headers = {
			[HEADERS.API_KEY] = params.api_key,
			[HEADERS.CONTENT_TYPE] = body.type,
		},
		body = body.content,
	}
	return net.request(config)
end

local request_reset: { [RequestMethod]: number } = {}
local function api_request<T>(params: RequestParams): T
	local method = params.method or "GET" :: RequestMethod
	local response: net.FetchResponse

	-- Handle for rate-limiting and throttling:
	local retry_count = 0
	repeat
		if response then --> Only wait on future loops.
			assert(retry_count <= MAX_RETRY_COUNT, `Request exceded the retry limit: {MAX_RETRY_COUNT}`)
			task.wait(request_reset[method] or (0.5 * 2 ^ retry_count))
		end
		response = request(params)
		retry_count += 1
	until response.statusCode ~= 429

	-- TODO: Use Content-Type header to determine how to decode body.
	local content = serde.decode("json", response.body)
	if not response.ok then
		error(`[{response.statusCode}]: {response.statusMessage}\nPath = {params.path}\nResponse = {response.body}`)
	end

	local header = response.headers
	request_reset[method] = tonumber(header[HEADERS.RATE_LIMIT_RESET]) or request_reset[method]

	return content
end

local DataStore = {}
local METATABLE = { __index = DataStore }

type DataStoreState = "STATE_UNSPECIFIED" | "ACTIVE" | "DELETED"
type DataStoreInfo = {
	id: string,
	path: string,
	state: DataStoreState,
}

export type DataStoreKey = DataStoreInfo
export type DataStoreMetadata = { users: { string }?, attributes: { unknown }? }
export type DataStoreValue = {
	value: unknown,
} & DataStoreMetadata & DataStoreInfo

type _DataStore = { __context: Context } & DataStoreInfo
export type DataStore = setmetatable<_DataStore, typeof(METATABLE)>

local function construct(ctx: Context, info: DataStoreInfo): DataStore
	local datastore = table.clone(info) :: _DataStore
	datastore.__context = hide_context(ctx)
	setmetatable(datastore, METATABLE)
	return table.freeze(datastore :: any)
end

function DataStore.keys(
	self: DataStore,
	query: {
		pageToken: typeof(EXPANSION_TOKEN) | string?,
		showDeleted: boolean?,
	}?
): ({ DataStoreKey }, string?)
	local internal_query = if query then table.clone(query) else {} :: { [string]: any }

	local out = {}
	local next_token = handle_expansion(function(token)
		internal_query.pageToken = token
		local params: RequestParams = {
			api_key = self.__context.api_key,
			path = `{self.path}/entries`,
			query = internal_query :: any,
		}
		local content = api_request(params) :: {
			dataStoreEntries: { DataStoreKey },
			nextPageToken: string?,
		}
		local entries = content.dataStoreEntries
		if entries then
			table.move(entries, 1, #entries, #out + 1, out)
		end
		return content.nextPageToken
	end, internal_query.pageToken)
	return out, next_token
end

function DataStore.get(self: DataStore, key: DataStoreKey): DataStoreValue
	local params: RequestParams = {
		api_key = self.__context.api_key,
		path = key.path,
	}
	return api_request(params) :: DataStoreValue
end

function DataStore.set(self: DataStore, value: DataStoreValue): ()
	local payload = {
		value = value.value,
		users = if value.users and #value.users > 0 then value.users else nil,
		attributes = if value.attributes and #value.attributes > 0 then value.attributes else nil,
	}
	local params: RequestParams = {
		api_key = self.__context.api_key,
		path = value.path,
		query = { allowMissing = true },
		method = "PATCH",
		body = {
			type = "application/json",
			content = serde.encode("json", payload),
		},
	}
	api_request(params)
end

local function list(
	ctx: Context,
	query: {
		pageToken: typeof(EXPANSION_TOKEN) | string?,
	}?
): ({ [string]: DataStore }, string?)
	local internal_query = if query then table.clone(query) else {} :: { [string]: any }

	local out = {}
	local next_token = handle_expansion(function(token)
		internal_query.pageToken = token
		local params: RequestParams = {
			api_key = ctx.api_key,
			path = `universes/{ctx.universe_id}/data-stores`,
			query = internal_query,
		}
		local content = api_request(params) :: { dataStores: { DataStoreInfo }, nextPageToken: string? }
		for _, info in content.dataStores or {} do
			out[info.id] = construct(ctx, info)
		end
		return content.nextPageToken
	end, internal_query.pageToken)
	return out, next_token
end

local function get(ctx: Context, id: string): DataStore
	return construct(ctx, {
		id = id,
		path = `universes/{ctx.universe_id}/data-stores/{id}`,
		state = "STATE_UNSPECIFIED",
	})
end

local function build_key(datastore: DataStore, id: string, scope: string?): DataStoreKey
	scope = scope or "global"
	return {
		id = `{scope}/{id}`,
		path = `{datastore.path}/scopes/{scope}/entries/{id}`,
		state = "STATE_UNSPECIFIED",
	}
end

local function build_value(key: DataStoreKey, value: unknown, meta: DataStoreMetadata?): DataStoreValue
	local object = {
		id = key.id,
		path = key.path,
		state = key.state,
		value = value,
		users = meta and meta.users,
		attributes = meta and meta.attributes,
	}
	return object
end

local function reassign_ownership(datastore: DataStore, object: DataStoreInfo): DataStoreInfo
	assert(not (object :: DataStore).__context, "Ownership reassginment of a DataStore objects is forbidden!")

	local index = string.find(object.path, "/scopes/") or string.find(object.path, "/entries/")
	assert(index, "Failed to parse path of object during ownership reassignment!")

	local new_object = table.clone(object)
	new_object.path = datastore.path .. string.sub(object.path, index, -1)

	return new_object
end

return {
	list = list,
	get = get,
	key = build_key,
	value = build_value,
	reassign = reassign_ownership,
}
