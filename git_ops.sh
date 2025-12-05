#!/bin/bash

echo "----------------------------------------"
echo "   Git Push & Pull Automation Script"
echo "----------------------------------------"

# === CONFIGURATION ===
REPO_URL="https://github.com/SK-1702/silicic_tool_chain.git"
BRANCH="main"

echo ""
echo "1) Choose Operation:"
echo "   1 - Push local changes to GitHub"
echo "   2 - Pull latest changes from GitHub"
echo "----------------------------------------"
read -p "Enter choice (1/2): " choice

# -------------------------------------------------------------
#  Push Operation
# -------------------------------------------------------------
if [ "$choice" == "1" ]; then
    echo ""
    echo ">>> Performing GIT PUSH"

    # Initialize repo if not already a repo
    if [ ! -d ".git" ]; then
        echo "Initializing new Git repository..."
        git init
        git remote add origin "$REPO_URL"
    fi

    # Add all files
    git add .

    # Commit with timestamp
    COMMIT_MSG="Auto Commit: $(date)"
    read -p "Enter commit message (press Enter for default): " user_msg
    if [ ! -z "$user_msg" ]; then
        COMMIT_MSG="$user_msg"
    fi

    git commit -m "$COMMIT_MSG"

    # Push to GitHub
    echo "Pushing to GitHub..."
    git branch -M "$BRANCH"
    git push -u origin "$BRANCH"

    echo ""
    echo ">>> PUSH COMPLETE!"

# -------------------------------------------------------------
#  Pull Operation
# -------------------------------------------------------------
elif [ "$choice" == "2" ]; then
    echo ""
    echo ">>> Performing GIT PULL"

    # If folder is empty OR not a git repo → clone
    if [ ! -d ".git" ]; then
        echo "No git repository detected. Cloning fresh repository..."
        git clone "$REPO_URL"
        echo "Cloned into silicic_tool_chain/"
        exit 0
    fi

    echo "Pulling latest changes..."
    git pull origin "$BRANCH"

    echo ""
    echo ">>> PULL COMPLETE!"

else
    echo "Invalid choice. Exiting."
    exit 1
fi

