---
type: supplement
language: en
extensions: [".py", ".pyw"]
---

## Python Specific Review Guidelines

### Type Safety
- Missing type annotations making interfaces unclear
- Missing `isinstance` checks causing runtime TypeError
- Using `Optional` types without None checks
- Union types lacking exhaustive matching

### Common Pitfalls
- Mutable default arguments: `def func(items=[])` shares state across calls; use `None` and initialize inside
- Late-binding closures: lambdas/functions created in loops capture the loop variable by reference, getting the final value
- `is` vs `==`: using `is` for non-interned strings or large integers will fail
- Bare `except:` or `except Exception:` swallows `KeyboardInterrupt` and other signals

### Security Issues
- `eval()`/`exec()` on untrusted input → code injection
- `pickle.loads()` on untrusted data → remote code execution
- `yaml.load()` without `SafeLoader` → arbitrary object instantiation
- `subprocess` with `shell=True` and user input → command injection
- `os.path.join` with user-supplied absolute paths → path traversal

### Async/Concurrency
- Calling blocking I/O (e.g., `requests.get`) inside `async def` blocks the event loop
- Forgetting to `await` a coroutine, leaving it unexecuted
- Shared mutable state across asyncio tasks without locks
- Exception handling in `asyncio.gather`: by default one failure cancels others

### Resource Management
- Files/network connections not using `with` statements (context managers)
- Relying on `__del__` for cleanup is unreliable; use `contextlib` or `atexit`
- Database connections/cursors not properly closed
