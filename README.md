# lua_overload_interface
Function overloading is implemented
/n
功能: 在Lua很方便的引入了函数重载的功能
参考的云风大佬的做法 https://blog.codingnow.com/cloud/LuaFunctionOverload?spm=a2c6h.12873639.0.0.50a47282yJzCoB

使用方法 假设定义了全局方法Overload , 这里使用的是DefineGlobal

```
local a = {}
Overload(a)

a.overload.somefunc{
  "number",
  function(n)
      --do something 
  end
}

a.overload.somefunc{
  "string",
  function(s)
      --do something 
  end
}
```
