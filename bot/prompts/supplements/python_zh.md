---
type: supplement
language: zh
extensions: [".py", ".pyw"]
---

## Python 专项审查要点

### 类型安全
- 缺少类型注解导致接口不清晰
- `isinstance` 检查遗漏导致运行时 TypeError
- `Optional` 类型未做 None 检查就直接使用
- Union 类型缺少穷尽匹配

### 常见陷阱
- 可变默认参数：`def func(items=[])` 会在调用间共享状态，应使用 `None` 后初始化
- 延迟绑定闭包：循环中创建 lambda/函数捕获循环变量，实际引用最终值
- `is` vs `==`：非 intern 字符串/非小整数使用 `is` 比较会失败
- 裸 `except:` 或 `except Exception:` 吞掉了 `KeyboardInterrupt` 等信号

### 安全问题
- `eval()`/`exec()` 执行不可信输入 → 代码注入
- `pickle.loads()` 反序列化不可信数据 → 远程代码执行
- `yaml.load()` 未使用 `SafeLoader` → 任意对象实例化
- `subprocess` 使用 `shell=True` 拼接用户输入 → 命令注入
- `os.path.join` 拼接用户输入中的绝对路径 → 路径遍历

### 异步/并发
- `async def` 中调用阻塞 I/O（如 `requests.get`）会阻塞事件循环
- 忘记 `await` 协程导致协程未执行
- 共享可变状态在 asyncio 任务间未加锁
- `asyncio.gather` 中的异常处理：默认一个失败会取消其他任务

### 资源管理
- 文件/网络连接未使用 `with` 语句（上下文管理器）
- `__del__` 中做资源清理不可靠，应使用 `contextlib` 或 `atexit`
- 数据库连接/游标未正确关闭
