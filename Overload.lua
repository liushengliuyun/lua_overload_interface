local function create()
    local arg_table = {}
    local function dispatcher (...)
        local tbl = arg_table
        local argLength = select("#", ...)
        local last_match
        for i = 1, argLength do
            local t = type(select(i, ...))
            local next = tbl[t]
            last_match = tbl["__end"] or tbl["..."] or last_match
            if not next then
                --如果最后一个参数不匹配, 则返回最后一个匹配
                return last_match(...)
            end
            tbl = next
        end
        return (tbl["__end"] or tbl["..."])(...)
    end
    local function register(desc, func)
        local tbl = arg_table
        for _, v in ipairs(desc) do
            if v == "..." then
                assert(not tbl["..."])
                tbl["..."] = func
                return
            end

            local next = tbl[v]
            if not next then
                next = {}
                tbl[v] = next
            end
            tbl = next
        end
        tbl["__end"] = func
    end
    return dispatcher, register
end

local all = {}
local function register(env, desc, name)
    --判断最后传入的是否是function
    local func = desc[#desc]
    assert(type(func) == "function")
    desc[#desc] = nil

    local func_table
    if all[env] then
        func_table = all[env]
    else
        func_table = {}
        all[env] = func_table
    end

    if env[name] then
        assert(func_table[name])
    else
        env[name], func_table[name] = create()
    end

    func_table[name](desc, func)
end

local overload
overload = setmetatable({}, {
    __index = function(t, k)
        local function reg (env, desc)
            register(env, desc, k)
            overload[k] = nil
        end
        t[k] = reg
        return reg
    end
})

--测试代码
--[[local a = {}
overload.test(a,
        { "number",
          function(n)
              print("number", n)
          end }
)

overload.test(a,
        {"string",
         --"number",
         function(s,n)
             print("string number",s,n)
         end}
)

a.test("hello",2)]]

local function include_overload(client)
    client.overload = setmetatable({}, {
        __index = function(t, k)
            --为了接受函数参数
            local function receiver(desc)
                overload[k](client, desc)
                t[k] = nil
            end
            t[k] = receiver
            return receiver
        end
    })
end

--need require
--[[


local function DefineGlobal(globalName, var, hotreload)
    if hotreload then
        if type(rawget(_G, globalName)) == type(var) then
            return rawget(_G, globalName)
        end
    end

    rawset(_G, globalName, var)

    return var
end

DefineGlobal("DefineGlobal", DefineGlobal)


local function Strict()
    setmetatable(_G, {
        __newindex = function(_, k, v)
            _G.CS.Carbon.Util.CarbonLogger.LogError("不能直接定义全局变量! -> " .. k)

            rawset(_G, k, v)
        end,
    })
end

Strict()

]]

_G.DefineGlobal("Overload", include_overload)
