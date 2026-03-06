---
type: supplement
language: zh
extensions: [".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".hxx"]
---

## C/C++ 专项审查要点

### 内存安全
- RAII 违规：手动 new/delete 未封装在 RAII 类或智能指针中
- Rule of Three/Five：定义了析构函数但缺少拷贝构造/赋值运算符（反之亦然）
- Use-after-free：释放后继续使用指针
- Double-free：同一指针多次释放
- 悬空引用/指针：返回局部变量的引用或指针

### 现代 C++ 实践
- 优先使用 `std::unique_ptr`/`std::shared_ptr` 替代 raw pointer
- 优先使用 `std::string` 替代 `char*`
- 使用 `enum class` 替代 plain enum
- 适当使用 `constexpr`、`auto`、range-based for

### 并发安全
- 数据竞争：多线程访问共享变量未加锁
- 死锁：不一致的加锁顺序
- 缺少 `std::lock_guard`/`std::unique_lock` 的 RAII 锁管理

### C++ 反模式
- 头文件中 `using namespace std`（污染全局命名空间）
- 缺少 include guard 或 `#pragma once`
- C-style cast（应使用 `static_cast`/`dynamic_cast`/`reinterpret_cast`）
- 析构函数抛出异常
- 对象切片（通过值传递多态对象）
- 基类缺少虚析构函数

### 不安全 C 遗留函数（在 C++ 中应避免）
- `strcpy`/`strcat` → 使用 `std::string` 或 `strncpy`
- `sprintf` → 使用 `snprintf` 或 `std::format`
- `gets` → 已废弃，使用 `std::getline`
- `system()` → 避免命令注入，使用安全的替代方案
- `malloc`/`free` → 在 C++ 中使用 `new`/`delete` 或智能指针
