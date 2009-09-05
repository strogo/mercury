require 'luarocks.require'
require 'wsapi.request'
require 'wsapi.response'
require 'wsapi.util'
require 'base'

module('mercury', package.seeall)

local route_table = { GET = {}, POST = {}, PUT = {}, DELETE = {} }

local application_methods = {
    get    = function(path, method, options) add_route('GET', path, method) end,
    post   = function(path, method, options) add_route('POST', path, method) end,
    put    = function(path, method, options) add_route('PUT', path, method) end,
    delete = function(path, method, options) add_route('DELETE', path, method) end,
}

function yield_template(engine, ...)
    -- TODO: seriously, using error() here goes beyond being hackish. 
    --       Moving everything to a coroutine-based dispatch to avoid 
    --       using return in the routes could be a viable solution.
    error({ template = engine(unpack(arg)) })
end

local templating_engines = {
    haml = function(...)
        local haml = require 'haml'
        return { render = function() return haml.render(unpack(arg)) end }
    end, 
    cosmo = function(...)
        local cosmo = require 'cosmo'
        return { render = function() return cosmo.fill(unpack(arg)) end }
    end, 
}

local route_methods = {
    pass   = function() error({ pass = true }) end, 
    -- NOTE: we use a table to group template-related methods to prevent name clashes.
    t = {
        haml   = function(template, options, locals)
            yield_template(templating_engines.haml, template, options, locals)
        end, 
        cosmo  = function(template, values)
            yield_template(templating_engines.cosmo, template, values)
        end, 
    },
}

--
-- *** application *** --
--

function application(application, fun)
    if type(application) == 'string' then
        application = { _NAME = application }
    else
        application = application or {}
    end

    for k, v in pairs(application_methods) do
        application[k] = v
    end

    application.run = function(wsapi_env) 
        return run(application, wsapi_env)
    end

    if fun then 
        setfenv(fun, setmetatable({}, {
            __index = function(_, k) return application[k] or _G[k] end
        }))()
    end

    return application
end

function add_route(verb, path, handler, options)
    table.insert(route_table[verb], { 
        pattern = path, 
        handler = handler, 
        options = options, 
    })
end

function compile_url_pattern(pattern)
    local compiled_pattern = { 
        original = pattern,
        params   = { },
    }

    -- TODO: Lua pattern matching is blazing fast compared to regular 
    --       expressions, but at the same time it is tricky when you 
    --       need to mimic some of their behaviors.
    pattern = pattern:gsub("[%(%)%.%%%+%-%%?%[%^%$%*]", function(char)
        if char == '*' then return ':*' else return '%' .. char end
    end)

    pattern = pattern:gsub(':([%w%*]+)(/?)', function(param, slash)
        if param == '*' then
            table.insert(compiled_pattern.params, 'splat')
            return '(.-)' .. slash
        else
            table.insert(compiled_pattern.params, param)
            return '([^/?&#]+)' .. slash
        end

    end)

    if pattern:sub(-1) ~= '/' then pattern = pattern .. '/' end
    compiled_pattern.pattern = '^' .. pattern .. '?$'

    return compiled_pattern
end

function extract_parameters(pattern, matches)
    local params = { }
    for i,k in ipairs(pattern.params) do
        if (k == 'splat') then
            if not params.splat then params.splat = {} end
            table.insert(params.splat, wsapi.util.url_decode(matches[i]))
        else
            params[k] = wsapi.util.url_decode(matches[i])
        end
    end
    return params
end

function url_match(pattern, path)
    local matches = { string.match(path, pattern.pattern) }
    if #matches > 0 then
        return true, extract_parameters(pattern, matches)
    else
        return false, nil
    end
end

function prepare_route(route, request, response, params)
    local route_env = {
        params   = params, 
        request  = request, 
        response = response, 
    }
    for k, v in pairs(route_methods) do route_env[k] = v end
    return setfenv(route.handler, setmetatable(route_env, { __index = _G }))
end

function router(application, state, request, response)
    local verb, path = state.vars.REQUEST_METHOD, state.vars.PATH_INFO

    return coroutine.wrap(function() 
        for _, route in pairs(route_table[verb]) do 
            -- TODO: routes should be compiled upon definition
            local match, params = url_match(compile_url_pattern(route.pattern), path)
            if match then 
                coroutine.yield(prepare_route(route, request, response, params)) 
            end
        end
    end)
end


function initialize(application, wsapi_env)
    -- TODO: taken from Orbit! It will change soon to adapt 
    --       request and response to a more suitable model.
    local web = { 
        status = "200 Ok", 
        headers  = { ["Content-Type"]= "text/html" },
        cookies  = {} 
    }

    web.vars     = wsapi_env
    web.prefix   = application.prefix or wsapi_env.SCRIPT_NAME
    web.suffix   = application.suffix
    web.doc_root = wsapi_env.DOCUMENT_ROOT

    if wsapi_env.APP_PATH == '' then
        web.real_path = application.real_path or '.'
    else
        web.real_path = wsapi_env.APP_PATH
    end

    local wsapi_req = wsapi.request.new(wsapi_env)
    local wsapi_res = wsapi.response.new(web.status, web.headers)

    web.set_cookie = function(_, name, value)
        wsapi_res:set_cookie(name, value)
    end

    web.delete_cookie = function(_, name, path)
        wsapi_res:delete_cookie(name, path)
    end

    web.path_info = wsapi_req.path_info

    if not wsapi_env.PATH_TRANSLATED == '' then
        web.path_translated = wsapi_env.PATH_TRANSLATED 
    else
        web.path_translated = wsapi_env.SCRIPT_FILENAME 
    end

    web.script_name = wsapi_env.SCRIPT_NAME
    web.method      = string.lower(wsapi_req.method)
    web.input       = wsapi_req.params
    web.cookies     = wsapi_req.cookies

    return web, wsapi_req, wsapi_res
end

function run(application, wsapi_env)
    local state, request, response = initialize(application, wsapi_env)
    local current_env = getfenv()

    for route in router(application, state, request, response) do
        setfenv(0, getfenv(route))
        local successful, res = xpcall(route, debug.traceback)
        setfenv(0, current_env)

        if successful then 
            if type(res) == 'function' then
                -- first attempt at streaming responses using coroutines
                return response.status, response.headers, coroutine.wrap(res)
            else
                response:write(res or '')
                return response:finish()
            end
        else
            if res and res.template then
                response:write(res.template.render() or 'template rendered an empty body')
                return response:finish()
            end

            if not res.pass then
                response.status  = 500
                response.headers = { ['Content-type'] = 'text/html' }
                response:write('<pre>' .. res:gsub("\n", "<br/>") .. '</pre>')
                return response:finish()
            end
        end
    end

    local function emit_no_routes_matched()
        coroutine.yield('<html><head><title>ERROR</title></head><body>')
        coroutine.yield('Sorry, no route found to match ' .. request.path_info .. '<br /><br/>')
        if application.debug_mode then
            coroutine.yield('<code><b>REQUEST DATA:</b><br/>' .. tostring(request) .. '<br/><br/>')
            coroutine.yield('<code><b>RESPONSE DATA:</b><br/>' .. tostring(response) .. '<br/><br/>')
        end
        coroutine.yield('</body></html>')
    end

    return 500, { ['Content-type'] = 'text/html' }, coroutine.wrap(emit_no_routes_matched)
end
