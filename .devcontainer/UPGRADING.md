# Upgrading

Optional. This `.devcontainer/` is yours, and nothing in it depends on the
template it was copied from. If you never want the template's later changes,
delete this file.

If you do want them, hand the job to a coding agent:

```text
Follow .devcontainer/UPGRADING.md.
```

```text
repository: https://github.com/ViacheslavPashkevich/agent-devcontainer
ref:        unrecorded
```

`ref` is the template tag this copy last took changes from. The agent keeps it
current.

## For the agent

You are bringing the template's later changes into this project's copy. The
copy has local edits, and they win: the goal is this project's container with
the template's improvements, not the template's container.

1. **Fetch.** Clone the repository above to a directory outside the project.
   The target is its newest tag, unless the user named another.
2. **Find the base.** It is `ref` above. If that is unrecorded, it is the tag
   whose `.devcontainer/` differs least from this copy. If the base is the
   target, say so and stop.
3. **Report first.** Read the template's changes to `.devcontainer/` between
   base and target. Before editing anything, tell the user what changed and
   what each change is for. They may take all of it, some of it or none.
4. **Merge.** Apply the changes the user wants as a three-way merge, file by
   file (`git merge-file <copy> <base> <target>` does it without touching the
   project's history). Where a change meets a local edit:
   - Inside a `project section`, and for lines the project added to
     `firewall/allowlist`, the project's content stays.
   - Anywhere else, take the template's change and carry the local edit over
     it if it still makes sense. Ask when it is unclear.
5. **Name what widens the fence.** Any change that lets the container do
   more gets its own line in your report: a domain added to the allowlist, a
   new grant in `etc/sudoers.d/`, a looser rule in `sbin/dev-firewall`, a new
   capability, port or mount in `compose.yaml`.
6. **Record.** Set `ref` above to the target, also when the user skipped some
   changes. What they skipped is now a local difference.
7. **Verify.** Run the unit tests; they need no Docker. `devc rebuild` and the
   smoke checks run on the host, so from inside the container give the user
   the commands instead. See [test/README.md](test/README.md).
8. **Leave it uncommitted.** The user reviews the result as one diff.
