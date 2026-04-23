#!/bin/bash
# Git Worktree Management for Claude Code
# Enables concurrent work on different branches with isolated working directories
#
# Worktrees are created in a sibling directory to the main repo:
#   /path/to/project           <- main repo
#   /path/to/project-feature   <- worktree for feature branch

# Get the main repository root (even if in a worktree)
# Returns: path to main git repository
worktree_get_main_repo() {
    local git_dir=$(git rev-parse --git-dir 2>/dev/null)
    if [[ -z "$git_dir" ]]; then
        echo "Error: Not in a git repository" >&2
        return 1
    fi

    # If we're in a worktree, git-dir points to .git/worktrees/name
    # The main repo is two levels up from there
    if [[ "$git_dir" == *".git/worktrees/"* ]]; then
        # Extract main repo path from worktree git dir
        local main_git="${git_dir%/worktrees/*}"
        dirname "$main_git"
    else
        # We're in the main repo
        git rev-parse --show-toplevel
    fi
}

# Get the worktree root (current working tree, whether main or worktree)
# Returns: path to current worktree root
worktree_get_current() {
    git rev-parse --show-toplevel 2>/dev/null
}

# Generate worktree path from branch name
# Args: $1 = branch name
#       $2 = main repo path (optional, auto-detected)
# Returns: full path for worktree directory
worktree_get_path() {
    local branch="$1"
    local main_repo="${2:-$(worktree_get_main_repo)}"

    if [[ -z "$branch" ]]; then
        echo "Error: Branch name required" >&2
        return 1
    fi

    # Sanitize branch name for filesystem
    # Replace / with - and remove special chars
    local safe_branch=$(echo "$branch" | tr '/' '-' | tr -cd '[:alnum:]-_')

    # Worktree goes in sibling directory
    local repo_name=$(basename "$main_repo")
    local parent_dir=$(dirname "$main_repo")

    echo "${parent_dir}/${repo_name}-${safe_branch}"
}

# Check if a worktree exists for a branch
# Args: $1 = branch name
# Returns: 0 if exists, 1 if not
worktree_exists() {
    local branch="$1"
    local worktree_path=$(worktree_get_path "$branch")

    [[ -d "$worktree_path" ]]
}

# List all worktrees for the current repository
# Args: $1 = format (json, table, paths) - defaults to table
# Returns: worktree information in requested format
worktree_list() {
    local format="${1:-table}"
    local main_repo=$(worktree_get_main_repo)

    if [[ -z "$main_repo" ]]; then
        return 1
    fi

    cd "$main_repo" || return 1

    case "$format" in
        json)
            git worktree list --porcelain | awk '
                BEGIN { print "["; first=1 }
                /^worktree / {
                    if (!first) print ","
                    first=0
                    path=$2
                }
                /^HEAD / { head=$2 }
                /^branch / {
                    branch=$2
                    gsub("refs/heads/", "", branch)
                    printf "  {\"path\": \"%s\", \"branch\": \"%s\", \"head\": \"%s\"}", path, branch, head
                }
                /^detached/ {
                    printf "  {\"path\": \"%s\", \"branch\": \"(detached)\", \"head\": \"%s\"}", path, head
                }
                END { print "\n]" }
            '
            ;;
        paths)
            git worktree list --porcelain | grep '^worktree ' | cut -d' ' -f2
            ;;
        table|*)
            echo "Worktrees for $(basename "$main_repo"):"
            echo ""
            git worktree list
            ;;
    esac
}

# Create a new worktree for a branch
# Args: $1 = branch name
#       $2 = create branch if doesn't exist (true/false, default false)
# Returns: path to created worktree, or error
worktree_create() {
    local branch="$1"
    local create_branch="${2:-false}"

    if [[ -z "$branch" ]]; then
        echo "Error: Branch name required" >&2
        return 1
    fi

    local main_repo=$(worktree_get_main_repo)
    if [[ -z "$main_repo" ]]; then
        return 1
    fi

    local worktree_path=$(worktree_get_path "$branch" "$main_repo")

    # Check if worktree already exists
    if [[ -d "$worktree_path" ]]; then
        echo "$worktree_path"
        return 0
    fi

    cd "$main_repo" || return 1

    # Check if branch exists
    if git show-ref --verify --quiet "refs/heads/$branch"; then
        # Branch exists, create worktree
        git worktree add "$worktree_path" "$branch"
    elif [[ "$create_branch" == "true" ]]; then
        # Create new branch and worktree
        git worktree add -b "$branch" "$worktree_path"
    else
        # Check if it's a remote branch
        if git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
            # Track remote branch
            git worktree add --track -b "$branch" "$worktree_path" "origin/$branch"
        else
            echo "Error: Branch '$branch' does not exist. Use create_branch=true to create it." >&2
            return 1
        fi
    fi

    if [[ $? -eq 0 ]]; then
        echo "$worktree_path"
        return 0
    else
        return 1
    fi
}

# Remove a worktree
# Args: $1 = branch name or worktree path
#       $2 = force removal (true/false, default false)
# Returns: 0 on success, 1 on error
worktree_remove() {
    local identifier="$1"
    local force="${2:-false}"

    if [[ -z "$identifier" ]]; then
        echo "Error: Branch name or worktree path required" >&2
        return 1
    fi

    local main_repo=$(worktree_get_main_repo)
    if [[ -z "$main_repo" ]]; then
        return 1
    fi

    # Determine if identifier is a path or branch name
    local worktree_path
    if [[ -d "$identifier" ]]; then
        worktree_path="$identifier"
    else
        worktree_path=$(worktree_get_path "$identifier" "$main_repo")
    fi

    # Don't remove the main worktree
    if [[ "$worktree_path" == "$main_repo" ]]; then
        echo "Error: Cannot remove main repository worktree" >&2
        return 1
    fi

    cd "$main_repo" || return 1

    if [[ "$force" == "true" ]]; then
        git worktree remove --force "$worktree_path" 2>/dev/null
    else
        git worktree remove "$worktree_path" 2>/dev/null
    fi

    local result=$?

    # Also prune any stale worktree entries
    git worktree prune 2>/dev/null

    return $result
}

# Prune stale worktree entries (worktrees that no longer exist on disk)
# Returns: 0 on success
worktree_prune() {
    local main_repo=$(worktree_get_main_repo)
    if [[ -z "$main_repo" ]]; then
        return 1
    fi

    cd "$main_repo" || return 1
    git worktree prune
}

# Get the branch name for a worktree path
# Args: $1 = worktree path (optional, defaults to current directory)
# Returns: branch name or empty if not a worktree
worktree_get_branch() {
    local worktree_path="${1:-$(pwd)}"

    cd "$worktree_path" 2>/dev/null || return 1
    git branch --show-current 2>/dev/null
}

# Check if current directory is the main repo or a worktree
# Returns: "main", "worktree", or "not-git"
worktree_get_type() {
    local git_dir=$(git rev-parse --git-dir 2>/dev/null)

    if [[ -z "$git_dir" ]]; then
        echo "not-git"
    elif [[ "$git_dir" == *".git/worktrees/"* ]]; then
        echo "worktree"
    else
        echo "main"
    fi
}

# Install dependencies in a worktree (node_modules, vendor, etc.)
# For worktrees, copies from main repo when possible (faster than fresh install)
# Args: $1 = worktree path
#       $2 = main repo path (optional, auto-detected)
# Returns: 0 on success
worktree_install_deps() {
    local worktree_path="${1:-$(pwd)}"
    local main_repo="${2:-$(worktree_get_main_repo)}"

    cd "$worktree_path" || return 1

    # Check if we're in a worktree (not the main repo)
    local is_worktree=false
    if [[ "$(worktree_get_type)" == "worktree" ]] || [[ "$worktree_path" != "$main_repo" ]]; then
        is_worktree=true
    fi

    # PHP/Composer projects
    if [[ -f "composer.json" ]]; then
        if [[ "$is_worktree" == "true" && -d "$main_repo/vendor" ]]; then
            echo "Copying vendor/ from main repo..."
            cp -R "$main_repo/vendor" "$worktree_path/"
            echo "Running composer dump-autoload..."
            composer dump-autoload
        else
            echo "Installing composer dependencies..."
            composer install
        fi

        # Copy .env if it exists in main repo but not in worktree
        if [[ "$is_worktree" == "true" && -f "$main_repo/.env" && ! -f "$worktree_path/.env" ]]; then
            echo "Copying .env from main repo..."
            cp "$main_repo/.env" "$worktree_path/.env"
        fi
    fi

    # Node.js projects
    if [[ -f "package.json" ]]; then
        if [[ "$is_worktree" == "true" && -d "$main_repo/node_modules" ]]; then
            echo "Copying node_modules/ from main repo..."
            cp -R "$main_repo/node_modules" "$worktree_path/"
        else
            echo "Installing npm dependencies..."
            npm install
        fi
    fi

    # Python projects
    if [[ -f "requirements.txt" ]]; then
        echo "Installing pip dependencies..."
        pip install -r requirements.txt
    fi

    # Ruby projects
    if [[ -f "Gemfile" ]]; then
        echo "Installing bundle dependencies..."
        bundle install
    fi

    return 0
}

# Quick setup: create worktree, cd to it, install deps
# Args: $1 = branch name
#       $2 = create branch if doesn't exist (true/false)
#       $3 = install dependencies (true/false, default true)
# Returns: 0 on success, prints path
worktree_setup() {
    local branch="$1"
    local create_branch="${2:-false}"
    local install_deps="${3:-true}"

    local worktree_path=$(worktree_create "$branch" "$create_branch")
    if [[ $? -ne 0 || -z "$worktree_path" ]]; then
        return 1
    fi

    echo "Worktree created at: $worktree_path"

    if [[ "$install_deps" == "true" ]]; then
        worktree_install_deps "$worktree_path"
    fi

    echo ""
    echo "To use this worktree:"
    echo "  cd $worktree_path"

    return 0
}

# Export functions
export -f worktree_get_main_repo
export -f worktree_get_current
export -f worktree_get_path
export -f worktree_exists
export -f worktree_list
export -f worktree_create
export -f worktree_remove
export -f worktree_prune
export -f worktree_get_branch
export -f worktree_get_type
export -f worktree_install_deps
export -f worktree_setup
