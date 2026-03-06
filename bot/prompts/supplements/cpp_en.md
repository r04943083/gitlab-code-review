---
type: supplement
language: en
extensions: [".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".hxx"]
---

## C/C++ Specific Review Guidelines

### Memory Safety
- RAII violations: raw new/delete not wrapped in RAII classes or smart pointers
- Rule of Three/Five: destructor defined but missing copy constructor/assignment operator (or vice versa)
- Use-after-free: accessing memory after deallocation
- Double-free: freeing the same pointer twice
- Dangling references/pointers: returning references or pointers to local variables

### Modern C++ Practices
- Prefer `std::unique_ptr`/`std::shared_ptr` over raw pointers
- Prefer `std::string` over `char*`
- Use `enum class` instead of plain enum
- Use `constexpr`, `auto`, range-based for where appropriate

### Concurrency Safety
- Data races: shared variable access without synchronization
- Deadlocks: inconsistent lock ordering
- Missing RAII lock management (`std::lock_guard`/`std::unique_lock`)

### C++ Anti-patterns
- `using namespace std` in header files (namespace pollution)
- Missing include guards or `#pragma once`
- C-style casts (use `static_cast`/`dynamic_cast`/`reinterpret_cast`)
- Throwing exceptions in destructors
- Object slicing (passing polymorphic objects by value)
- Missing virtual destructor in base classes

### Unsafe C Legacy Functions (avoid in C++)
- `strcpy`/`strcat` → use `std::string` or `strncpy`
- `sprintf` → use `snprintf` or `std::format`
- `gets` → deprecated, use `std::getline`
- `system()` → avoid command injection, use safe alternatives
- `malloc`/`free` → use `new`/`delete` or smart pointers in C++
