const std = @import("std");
const builtin = @import("builtin");

const dbg = std.debug.print;

pub const GlobError = error{
    ParseError,
    AbsolutePathRequired,
};

const MatchType = enum {
    // We didn't match.
    Mismatch,

    // We didn't fully match the glob, but nothing in our input caused an explicit mismatch.
    PartialMatch,

    // We got a good old match.
    Match,
};

const Glob = struct {
    parts: [][]const u8,
    wants_directory: bool,
    recursive: bool,
    len: usize,
};

const GlobMatches = struct {
    caller_allocator: *std.mem.Allocator,

    arena: std.heap.ArenaAllocator,
    allocator: *std.mem.Allocator,

    glob: Glob,
    buffered_matches: std.ArrayList([]const u8),
    dir_queue: std.ArrayList([]const u8),
    realpath_buf: [std.fs.MAX_PATH_BYTES]u8,
    path_buf: std.ArrayList(u8),

    pub fn init(caller_allocator: *std.mem.Allocator, glob_s: []const u8) !*GlobMatches {
        var self: *GlobMatches = try caller_allocator.create(GlobMatches);
        errdefer caller_allocator.destroy(self);

        self.caller_allocator = caller_allocator;

        self.arena = std.heap.ArenaAllocator.init(caller_allocator);
        self.allocator = &self.arena.allocator;

        self.glob = try parseGlob(self.allocator, glob_s);
        self.buffered_matches = std.ArrayList([]const u8).init(self.allocator);
        self.dir_queue = std.ArrayList([]const u8).init(self.allocator);
        self.realpath_buf = undefined;
        self.path_buf = std.ArrayList(u8).init(self.allocator);

        try self.dir_queue.append(try self.allocator.dupe(u8, extractBasedir(glob_s)));

        return self;
    }

    pub fn deinit(self: *GlobMatches) void {
        self.arena.deinit();
        var caller_allocator = self.caller_allocator;
        caller_allocator.destroy(self);
    }

    pub fn next(self: *GlobMatches) !?[]const u8 {
        while (true) {
            if (self.buffered_matches.items.len > 0) {
                return self.buffered_matches.pop();
            }

            // Out of results and out of places to search.  End of the line.
            if (self.dir_queue.items.len == 0) {
                return null;
            }

            // Work on finding more matches
            var dir = self.dir_queue.pop();

            var match = try matchPath(self.allocator, &self.glob, dir);

            if (match == MatchType.Mismatch) {
                continue;
            }

            if (match == MatchType.Match) {
                try self.buffered_matches.append(try self.allocator.dupe(u8, if (dir.len == 0) std.fs.path.sep_str else dir));

                // If the glob was recursive, there might be matches further down the tree.
                if (!self.glob.recursive) {
                    continue;
                }
            }

            var dir_handle = std.fs.openDirAbsolute(if (dir.len == 0) std.fs.path.sep_str else dir, .{ .iterate = true }) catch |err| {
                std.log.debug("Skipped unreadable directory {s}: {}", .{ dir, err });
                continue;
            };

            defer dir_handle.close();

            var iter = dir_handle.iterate();

            while (try iter.next()) |entry| {
                if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) {
                    continue;
                }

                self.path_buf.clearRetainingCapacity();
                try self.path_buf.appendSlice(dir);
                try self.path_buf.append(std.fs.path.sep);
                try self.path_buf.appendSlice(entry.name);

                var is_directory = false;

                if (std.fs.openFileAbsolute(self.path_buf.items, .{})) |fd| {
                    if (fd.stat()) |stat| {
                        is_directory = (stat.kind == std.fs.Dir.Entry.Kind.Directory);
                        fd.close();

                        if (stat.kind == std.fs.Dir.Entry.Kind.SymLink) {
                            if (std.fs.realpath(self.path_buf.items, &self.realpath_buf)) |realpath| {
                                if (std.fs.openFileAbsolute(realpath, .{})) |link_fd| {
                                    is_directory = (try link_fd.stat()).kind == std.fs.Dir.Entry.Kind.Directory;
                                    link_fd.close();
                                } else |err| {
                                    std.log.debug("Failure opening symlink target: {s} (symlink: {s}): {}", .{ realpath, self.path_buf.items, err });
                                }
                            } else |err| {
                                std.log.debug("Failure calling realpath on: {s}: {}", .{ self.path_buf.items, err });
                            }
                        }
                    } else |err| {
                        std.log.debug("Could not stat path: {s}: {}", .{ self.path_buf.items, err });
                    }
                } else |err| {
                    std.log.debug("Could not open file: {s}: {}", .{ self.path_buf.items, err });
                }

                var entryMatch = try matchPath(self.allocator, &self.glob, self.path_buf.items);

                if (!is_directory and self.glob.wants_directory) {
                    // Glob only matches directories due to its trailing slash
                } else if (is_directory) {
                    try self.dir_queue.append(try self.allocator.dupe(u8, self.path_buf.items));
                } else {
                    if (entryMatch == MatchType.Match) {
                        try self.buffered_matches.append(try self.allocator.dupe(u8, self.path_buf.items));
                    }
                }
            }
        }
    }
};

pub fn listFiles(caller_allocator: *std.mem.Allocator, glob_s: []const u8) !*GlobMatches {
    if (glob_s.len > 0 and glob_s[0] != std.fs.path.sep) {
        return GlobError.AbsolutePathRequired;
    }

    return GlobMatches.init(caller_allocator, glob_s);
}

fn extractBasedir(glob_s: []const u8) []const u8 {
    var wildcard_pos = std.mem.indexOf(u8, glob_s, "*") orelse glob_s.len;
    var last_dir_pos = std.mem.lastIndexOf(u8, glob_s[0..wildcard_pos], std.fs.path.sep_str).?;

    return glob_s[0..last_dir_pos];
}

fn parseGlob(allocator: *std.mem.Allocator, glob_s: []const u8) !Glob {
    var glob = std.ArrayList([]const u8).init(allocator);

    if (glob_s.len > 0 and glob_s[0] == '*') {
        // Glob always gets a leading slash
        try glob.append("");
    }

    var recursive = false;

    var it = std.mem.split(glob_s, std.fs.path.sep_str);
    while (it.next()) |s| {
        if (s.len == 0 and glob.items.len > 0 and (glob.items[glob.items.len - 1].len == 0)) {
            // ignore repeated separators
            continue;
        }

        if (std.mem.eql(u8, s, "**")) {
            recursive = true;
        }

        try glob.append(try allocator.dupe(u8, s));
    }

    var wants_directory = false;
    if (glob.items.len > 1 and glob.items[glob.items.len - 1].len == 0) {
        _ = glob.pop();
        wants_directory = true;
    }

    return Glob{ .parts = glob.items, .len = glob.items.len, .wants_directory = wants_directory, .recursive = recursive };
}

fn matchPath(caller_allocator: *std.mem.Allocator, glob: *Glob, path_s: []const u8) !MatchType {
    var arena = std.heap.ArenaAllocator.init(caller_allocator);
    defer arena.deinit();
    var allocator = &arena.allocator;

    var path = try std.ArrayList([]const u8).initCapacity(allocator, 8);
    {
        var it = std.mem.split(path_s, std.fs.path.sep_str);
        while (it.next()) |s| {
            if (s.len == 0 and path.items.len > 0 and (path.items[path.items.len - 1].len == 0)) {
                // ignore repeated separators
                continue;
            }

            try path.append(s);
        }
    }

    // If our path had a trailing slash, ignore it unless it was the root directory.
    if (path.items.len > 1 and path.items[path.items.len - 1].len == 0) {
        _ = path.pop();
    }

    return try matchLoop(allocator, glob, path.items);
}

const MatchPosition = struct {
    glob_idx: usize,
    input_idx: usize,
};

fn pathComponentMatch(allocator: *std.mem.Allocator, glob: []const u8, s: []const u8) !bool {
    if (std.mem.eql(u8, glob, s)) {
        return true;
    }

    var possible_match_starts = std.ArrayList(MatchPosition).init(allocator);

    try possible_match_starts.append(MatchPosition{
        .glob_idx = 0,
        .input_idx = 0,
    });

    while (possible_match_starts.items.len > 0) {
        var possible_match = possible_match_starts.pop();

        if (possible_match.glob_idx == glob.len or possible_match.input_idx == s.len) {
            // We've run out of glob or we've run out of letters.  Either is no match.
            continue;
        }

        if ((possible_match.glob_idx + 1) == glob.len and glob[possible_match.glob_idx] == '*') {
            // Glob ends in '*', which matches all remaining input.  Instant win!
            return true;
        } else if (glob[possible_match.glob_idx] == '*') {
            // Hit a wildcard.  Scan forward to find potential positions of remaining matches
            // and queue them up.
            var next_required_char = glob[possible_match.glob_idx + 1];

            if (next_required_char == '*') {
                return GlobError.ParseError;
            }

            var possible_start_idx = possible_match.input_idx;
            while (possible_start_idx < s.len) {
                if (s[possible_start_idx] == next_required_char) {
                    try possible_match_starts.append(MatchPosition{
                        .glob_idx = possible_match.glob_idx + 1,
                        .input_idx = possible_start_idx,
                    });
                }

                possible_start_idx += 1;
            }
        } else {
            // Non-wildcard
            if (glob[possible_match.glob_idx] != s[possible_match.input_idx]) {
                // Mismatch on literal
                continue;
            }

            if ((possible_match.glob_idx + 1) == glob.len) {
                if ((possible_match.input_idx + 1) == s.len) {
                    // We're out of glob and we're out of input.  That's a win.
                    return true;
                } else {
                    continue;
                }
            } else {
                // Consume one char from our glob; one from our input
                try possible_match_starts.append(MatchPosition{
                    .glob_idx = possible_match.glob_idx + 1,
                    .input_idx = possible_match.input_idx + 1,
                });
            }
        }
    }

    return false;
}

fn matchLoop(allocator: *std.mem.Allocator, glob: *Glob, path: [][]const u8) !MatchType {
    var candidates = std.ArrayList(MatchPosition).init(allocator);

    try candidates.append(MatchPosition{
        .glob_idx = 0,
        .input_idx = 0,
    });

    var candidate_idx: usize = 0;

    var found_partial_match = false;

    while (candidates.items.len > 0) {
        var candidate = candidates.pop();

        var glob_idx = candidate.glob_idx;
        var path_idx = candidate.input_idx;

        while (true) {
            if (glob_idx == glob.len) {
                if (path_idx == path.len) {
                    return MatchType.Match;
                }

                break;
            }

            if (path_idx == path.len) {
                // Ran out of input before we ran out of glob.
                found_partial_match = true;
                break;
            }

            if (std.mem.eql(u8, glob.parts[glob_idx], "*")) {
                glob_idx += 1;
                path_idx += 1;
            } else if (std.mem.eql(u8, glob.parts[glob_idx], "**")) {
                found_partial_match = true;

                if ((glob_idx + 1) == glob.len) {
                    // Trailing glob is an instant win
                    return MatchType.Match;
                }

                {
                    var test_idx = path_idx;
                    while (test_idx < path.len) {
                        try candidates.append(MatchPosition{ .glob_idx = glob_idx + 1, .input_idx = test_idx });
                        test_idx += 1;
                    }
                }

                break;
            } else if (try pathComponentMatch(allocator, glob.parts[glob_idx], path[path_idx])) {
                glob_idx += 1;
                path_idx += 1;
            } else {
                break;
            }
        }
    }

    if (found_partial_match) {
        return MatchType.PartialMatch;
    } else {
        return MatchType.Mismatch;
    }
}

//// Testing
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "pathComponentMatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var allocator = &arena.allocator;

    try expect(try pathComponentMatch(allocator, "test", "test"));
    try expect(try pathComponentMatch(allocator, "*est", "test"));
    try expect(try pathComponentMatch(allocator, "*es*", "test"));
    try expect(try pathComponentMatch(allocator, "h*l*o", "hello"));
    try expect(try pathComponentMatch(allocator, "*", "whatever"));
    try expect(!try pathComponentMatch(allocator, "mismatch", "test"));
    try expect(!try pathComponentMatch(allocator, "", "whatever"));
}

fn testMatchPath(glob_s: []const u8, path_s: []const u8) !MatchType {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var allocator = &arena.allocator;

    if (std.fs.path.sep != '/') {
        var adjusted = try allocator.dupe(path_s);
        std.mem.replace(u8, path_s, "/", path.sep_str, adjusted);
        path_s = adjusted;
    }

    return try matchPath(allocator, &try parseGlob(allocator, glob_s), path_s);
}

test "matchPath full matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var allocator = &arena.allocator;

    try expectEqual(MatchType.Match, try testMatchPath("*/**/pants", "/home/mst/foo/pants"));
    try expectEqual(MatchType.Match, try testMatchPath("*/*/foo/*", "/home/mst/foo/pants"));
    try expectEqual(MatchType.Match, try testMatchPath("/", "/"));
    try expectEqual(MatchType.Match, try testMatchPath("/**/**/*/hello/*", "/home/mst/foo/pants/some/thing/else/foopants/mst/and/more/hello/there"));
    try expectEqual(MatchType.Match, try testMatchPath("/**/pants", "/home/mst/foo/pants"));
    try expectEqual(MatchType.Match, try testMatchPath("/home", "/home"));
    try expectEqual(MatchType.Match, try testMatchPath("/home/*", "/home/mst"));
    try expectEqual(MatchType.Match, try testMatchPath("/home/**/pants", "/home/mst/foo/pants"));
    try expectEqual(MatchType.Match, try testMatchPath("/home/**/pants/**/mst", "/home/mst/foo/pants/some/thing/else/mst"));
    try expectEqual(MatchType.Match, try testMatchPath("/home/**/pants/**/mst/**/*/more/hello", "/home/mst/foo/pants/some/thing/else/foopants/mst/and/more/hello"));
    try expectEqual(MatchType.Match, try testMatchPath("/home/**/pants/**/mst/**/hello", "/home/mst/foo/pants/some/thing/else/foopants/mst/and/more/hello"));
    try expectEqual(MatchType.Match, try testMatchPath("/home/mst/*/*", "/home/mst/foo/pants"));
    try expectEqual(MatchType.Match, try testMatchPath("/home/mst/*/*ant*", "/home/mst/foo/pants"));
    try expectEqual(MatchType.Match, try testMatchPath("/home/mst/foo/pants", "/home/mst/foo/pants"));
    try expectEqual(MatchType.Match, try testMatchPath("/home/mst/*/*s", "/home/mst/foo/pants"));
    try expectEqual(MatchType.Match, try testMatchPath("/home/mst/*/p*", "/home/mst/foo/pants"));
    try expectEqual(MatchType.Match, try testMatchPath("/home/mst/*/*.js", "/home/mst/foo/foo.js"));
    try expectEqual(MatchType.Match, try testMatchPath("/home/mst/*/*.git", "/home/mst/foo/hello.git"));
    try expectEqual(MatchType.Match, try testMatchPath("/home/mst/p*nts", "/home/mst/pointpants"));
    try expectEqual(MatchType.Match, try testMatchPath("/home/mst/**", "/home/mst/pretty/much/anything"));
    try expectEqual(MatchType.Match, try testMatchPath("/home/foo/*/qux", "/home/foo/bar/qux"));
    try expectEqual(MatchType.Match, try testMatchPath("**/pants", "/any/thing/foo/pants"));
    try expectEqual(MatchType.Match, try testMatchPath("/**/pants", "/any/thing/foo/pants"));
    try expectEqual(MatchType.Match, try testMatchPath("/home/mst/**", "/home/mst/subdir"));
    try expectEqual(MatchType.Match, try testMatchPath("/home/mst/projects/foo/bar/*/*.md", "/home/mst/projects/foo/bar/something/somefile.md"));
}

test "matchPath mismatches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var allocator = &arena.allocator;

    try expectEqual(MatchType.Mismatch, try testMatchPath("/home/mst/**/pants", "/wrong/start/foo/pants"));
    try expectEqual(MatchType.Mismatch, try testMatchPath("/home/mst/foo/pants", "/home/mst/foo/wrong"));
    try expectEqual(MatchType.Mismatch, try testMatchPath("/home/mst/foo/pants", "/home/mst/foo/pants2"));
}

test "matchPath partial matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var allocator = &arena.allocator;

    try expectEqual(MatchType.PartialMatch, try testMatchPath("/home/foo/bar/qux", "/home/foo"));
    try expectEqual(MatchType.PartialMatch, try testMatchPath("/home/*", "/home"));
    try expectEqual(MatchType.PartialMatch, try testMatchPath("/home/**/pants", "/home/mst/foo/wrong"));
    try expectEqual(MatchType.PartialMatch, try testMatchPath("/home/**/pants/**/mst", "/home/mst/foo/pants/some/thing/else/foopants/wrong"));
    try expectEqual(MatchType.PartialMatch, try testMatchPath("/home/mst/**", "/home/mst"));
    try expectEqual(MatchType.PartialMatch, try testMatchPath("/home/foo/*/qux", "/home/foo/bar"));
    try expectEqual(MatchType.PartialMatch, try testMatchPath("/*", "/"));
}

fn countMatches(glob_parts: [][]const u8) !usize {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var allocator = &arena.allocator;

    var list = try listFiles(std.testing.allocator, try std.fs.path.join(allocator, glob_parts));
    defer list.deinit();

    var count: usize = 0;
    while (try list.next()) |entry| {
        count += 1;
    }

    return count;
}

test "iterator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var allocator = &arena.allocator;

    var test_dir_path: []const u8 = try std.fs.path.join(allocator, &[_][]const u8{ std.fs.path.dirname(@src().file).?, "..", "test_files" });

    var testdir = try std.fs.openDirAbsolute(test_dir_path, .{});
    defer testdir.close();

    test_dir_path = try testdir.realpathAlloc(allocator, ".");

    try expectEqual(@intCast(usize, 4), try countMatches(&[_][]const u8{ test_dir_path, "**", "*.txt" }));
    try expectEqual(@intCast(usize, 10), try countMatches(&[_][]const u8{ test_dir_path, "**", "*" }));
    try expectEqual(@intCast(usize, 1), try countMatches(&[_][]const u8{ test_dir_path, "**", "*hidde*" }));
    try expectEqual(@intCast(usize, 4), try countMatches(&[_][]const u8{ test_dir_path, "**", "*", "" }));
    try expectEqual(@intCast(usize, 0), try countMatches(&[_][]const u8{ test_dir_path, "*", "willnevermatch", "**" }));
}
