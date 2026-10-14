# lua_overload_interface

在 Lua 里方便地引入函数重载 (function overloading)。

参考云风大佬的做法: [Lua 函数重载](https://blog.codingnow.com/cloud/LuaFunctionOverload)。

## 文件说明

| 文件 | 说明 |
|------|------|
| `Overload.lua` | 原版: 云风 trie 方案 + `a.overload.foo{...}` 注册语法糖 |
| `OverloadV2.lua` | 改进版: 平铺签名表 + 单态内联缓存, 修复原版的若干崩溃点 |
| `examples_v2.lua` | V2 自校验示例 (12 项, 全部 assert 通过打印 `ALL PASS`) |

## 原版用法

```lua
local Overload = require "Overload"

local a = {}
Overload(a)                 -- 装配 a.overload 注册表

a.overload.somefunc{
    "number",
    function(n) ... end
}
a.overload.somefunc{
    "string",
    function(s) ... end
}

a.somefunc(1)               -- -> number 版本
a.somefunc("x")             -- -> string 版本
```

## V2 用法

注册语法与原版完全一致, `Overload(a)` 改为 `Overload.mount(a)`:

```lua
local Overload = require "OverloadV2"

local a = {}
Overload.mount(a)

a.overload.greet{
    "string",
    function(s) return "hello " .. s end
}
a.overload.greet{
    "number",
    function(n) return "num " .. n end
}

a.greet("world")            -- hello world
a.greet(42)                 -- num 42
```

### 槽位形式 (V2)

| 槽位 | 语义 |
|------|------|
| `"number"` 等 | 按 `type()` 名匹配 (8 种内建类型, 拼写错误注册时报错) |
| `function(x) -> bool` | 谓词槽: 按值条件分派 (如区分 XLua 下同为 userdata 的不同 C# 类型) |
| `{"number","string"}` | union 槽: 任一类型名命中即可 |
| `"..."` (仅尾槽) | 通配: 匹配零或多个额外参数 |
| 无槽 + 函数 | 0 参重载 |

### V2 相比原版

- **无匹配/短参不再崩** `attempt to call a nil value`, 而是 `error` 带函数名与实际参数类型串:
  `Overload 'greet': no matching overload for (boolean)`
- **desc 表不被修改**: 原版注册时弹出末尾函数 (`desc[#desc] = nil`), desc 复用即崩; V2 只读
- **热重载安全**: 同签名重注册 = 覆盖, 重复挂载幂等 (原版 `all` 记账 + assert 在热重载场景崩)
- **谓词槽 / union 槽**: 原版 trie 只认 type 名; union 在原版里是静默死键
- **单态内联缓存**: 同形状重复调用免注册表遍历, 适合 UI 刷新等热路径
- **纯标准 Lua 5.1+**, 无全局注入, 标准 `return` 模块

## 示例与测试

```bash
lua examples_v2.lua          # 或任意 Lua 5.1+ 运行时 (xlua/luajit/fengari 均可)
# 12 项示例全部 assert 通过后打印 ALL PASS
```

`examples_v2.lua` 覆盖: 基础重载 / 多参 / union / 谓词 / 通配 / 0 参 / fallback 语义 /
明确报错 / 同签名覆盖 / desc 复用 / 独立 dispatcher (`Overload.new` + `Overload.def`) / 内联缓存。

## API 一览 (V2)

```lua
Overload.mount(env)          -- 装配 env.overload 注册表 (幂等)
env.overload.foo{ slots..., fn }  -- 注册签名 (与原版语法一致)
Overload.new(name)           -- 创建独立 dispatcher 函数
Overload.def(disp, desc)     -- 给独立 dispatcher 注册签名
```

## License

MIT, 见 [LICENSE](LICENSE)。方案参考云风
[Lua 函数重载](https://blog.codingnow.com/cloud/LuaFunctionOverload), 致谢。