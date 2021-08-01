A work-in-progress implementation of filesystem globs in Zig.
Untested in production and probably never will be!

Supports globs like:

```
# Text files under a directory
/path/to/somewhere/*.txt

# Sub-directories under a directory
/path/to/somewhere/*/

# All text files found recursively
/path/to/somewhere/**/*.txt

# All sub-directories found recursively
/path/to/somewhere/**/*/
```

The `listFiles` function returns an iterator of match strings, so you
can do something like this:

```zig
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = &arena.allocator;

    var list = try globby.listFiles(allocator, std.mem.span("/my/path/*.txt"));

    const stdout = std.io.getStdOut().writer();
    while (try list.next()) |entry| {
        try stdout.print("{s}\n", .{entry});
    }

    list.deinit();
```
