# agent-devcontainer

A devcontainer template for running coding agents unattended behind an egress
fence. Copy `.devcontainer/` into a project and own it; the template is never a
runtime dependency.

Everything is in [`.devcontainer/README.md`](.devcontainer/README.md): what the
container provides, what to edit after copying, the `devc` verbs, and how the
fence works.

Taking the template's later changes is optional and a job for a coding agent:
[`.devcontainer/UPGRADING.md`](.devcontainer/UPGRADING.md) is its brief.

This repository's own `.devcontainer/` is the template itself, which is how it
tests itself: the stub suites run on every push, and the image is built and
smoke-checked on amd64 and arm64.
