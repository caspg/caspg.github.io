#!/bin/bash

# Exit on error
set -e

# Configuration
MAIN_BRANCH="master"  # Changed from "main" to "master"
DEPLOY_BRANCH="gh-pages"
BUILD_DIR="_site"

# Check if we're on master branch
CURRENT_BRANCH=$(git branch --show-current)
if [[ "$CURRENT_BRANCH" != "$MAIN_BRANCH" ]]; then
    echo "❌ Must be on $MAIN_BRANCH branch to deploy. Current branch: $CURRENT_BRANCH"
    exit 1
fi

echo "🚀 Starting deployment process..."

# Ensure working directory is clean
if [[ -n $(git status --porcelain) ]]; then
    echo "❌ Working directory is not clean. Please commit or stash your changes first."
    exit 1
fi

# Build the site
echo "🏗️  Building Jekyll site..."
jekyll build

# Save the built site to a temporary directory
echo "📦 Saving built site..."
TMP_DIR=$(mktemp -d)
cp -R $BUILD_DIR/* $TMP_DIR/

# Switch to gh-pages branch
echo "🔄 Switching to $DEPLOY_BRANCH branch..."
if git show-ref --verify --quiet refs/heads/$DEPLOY_BRANCH; then
    git checkout $DEPLOY_BRANCH
else
    git checkout --orphan $DEPLOY_BRANCH
fi

# Remove existing files
echo "🗑️  Cleaning old files..."
git rm -rf . || true

# Copy the built site from temp directory
echo "📋 Copying new files..."
cp -R $TMP_DIR/* .

# Clean up temp directory
rm -rf $TMP_DIR

# Add all changes to git
echo "📝 Committing changes..."
git add -A
git commit -m "Deploy site built at $(date)" || true

# Push to GitHub
echo "⬆️  Pushing to GitHub..."
git push origin $DEPLOY_BRANCH --force

# Switch back to master branch
echo "↩️  Switching back to $MAIN_BRANCH..."
git checkout $MAIN_BRANCH

echo "✅ Deployment complete!"
