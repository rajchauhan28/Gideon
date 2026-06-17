# Design Spec: Fresh GitHub Repository Start

## Goal
Remove all traces of previous "Claude AI" contributions by creating a brand new GitHub repository with a clean history.

## Strategy
1.  **Local Cleanup**: Delete the existing `.git` directory to wipe all historical metadata (including co-author tags).
2.  **Initialize Fresh**: Initialize a new git repository locally.
3.  **Prepare Initial Commit**: Stage all files (respecting `.gitignore`) and create a fresh "Initial commit".
4.  **GitHub Integration**: Use `gh repo create` to create a new public repository named `Gideon` on GitHub.
5.  **Deployment**: Push the local `main` branch to the new GitHub remote.

## Components
- **Git**: Local version control.
- **GitHub CLI (gh)**: Repository creation and remote management.

## Success Criteria
- A new GitHub repository `rajchauhan28/Gideon` exists.
- The repository has exactly one commit ("Initial commit").
- No "Co-Authored-By" or "Claude" mentions exist in the git log.
- All core files (backend, frontend, configs) are present.

## Risks
- **Data Loss**: Deleting `.git` is irreversible. (Mitigation: Files themselves are preserved; we are only losing history which is the intent).
- **Naming Conflict**: If `Gideon` already exists on GitHub, creation might fail. (Mitigation: Check first or use a unique name).
