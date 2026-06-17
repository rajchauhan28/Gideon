# Fresh GitHub Repository Start Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a brand new GitHub repository for Gideon with a fresh history to remove all traces of Claude AI contributions.

**Architecture:** Use `git` and `gh` CLI to wipe history and push to a new remote.

**Tech Stack:** Git, GitHub CLI (gh)

---

### Task 1: Wipe Local History and Initialize

**Files:**
- Modify: `.git/` (Delete and Recreate)

- [ ] **Step 1: Delete existing .git directory**

Run: `rm -rf .git`
Expected: `.git` folder is removed.

- [ ] **Step 2: Initialize new git repository**

Run: `git init -b main`
Expected: `Initialized empty Git repository in /home/reign/ddrive/GenAI/Gideon/.git/`

- [ ] **Step 3: Stage all files**

Run: `git add .`
Expected: All files tracked in `.gitignore` are staged.

- [ ] **Step 4: Create initial commit**

Run: `git commit -m "Initial commit: Gideon — local tool-calling assistant for Arch/Hyprland"`
Expected: Clean commit with no "Claude" co-author.

- [ ] **Step 5: Verify commit log**

Run: `git log`
Expected: Exactly one commit by `Raj singh chauhan`.

---

### Task 2: Create GitHub Repository and Push

**Files:**
- Modify: `.git/config` (Add remote)

- [ ] **Step 1: Create GitHub repository**

Run: `gh repo create Gideon --public --source=. --remote=origin`
Expected: Repository created on GitHub and remote `origin` added.

- [ ] **Step 2: Push to GitHub**

Run: `git push -u origin main`
Expected: `main` branch pushed to GitHub.

- [ ] **Step 3: Verify GitHub status**

Run: `gh repo view --web` (or check via CLI `gh repo view`)
Expected: Repository `rajchauhan28/Gideon` exists and is public.
