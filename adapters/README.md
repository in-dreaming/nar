# Adapters

`src/adapters/spindle/host.zig` owns the production `std.Io.Threaded` and
aggregate Spindle runtime. NAR core borrows its execution services and never
deinitializes them. The same adapter provides `TestHost` for virtual-clock,
caller-driven tests.
