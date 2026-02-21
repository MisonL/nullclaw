//! Agent module — delegates to agent/root.zig.
//!
//! Re-exports all public symbols from the agent submodule.

const agent_root = @import("agent/root.zig");

pub const Agent = agent_root.Agent;
pub const run = agent_root.run;

test {
    _ = agent_root;
}
