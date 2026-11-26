# ---- The fleet repos' settings: every public, non-archived, non-fork repo of both owners -----
#
# ADR-016 § 5. Read into github_repository + github_branch_default by stack.nix. Each value
# was the live one when first imported (2026-11-26, the REST repo object), so the first apply
# is import-only and its re-plan must read "No changes". Change a setting HERE, then plan.
# Private repos never appear (no private name enters this public repo); archived repos and
# forks are out of scope. Removing an entry FORGETS the repo (lifecycle.destroy = false),
# it never deletes it.
# ARCHIVING one: archive it on GitHub, then drop its entry as a `removed` block with
# `lifecycle.destroy = false` (a forget, never a delete). Until then the stack ignores
# `archived` (stack.nix), so a kept entry cannot unarchive it.
{
  ismailkattakath = {
    ".github" = {
      allow_auto_merge = false;
      allow_forking = true;
      allow_merge_commit = true;
      allow_rebase_merge = true;
      allow_squash_merge = true;
      allow_update_branch = false;
      default_branch = "main";
      delete_branch_on_merge = false;
      description = "Default community health files for every public ismailkattakath repository.";
      has_discussions = false;
      has_issues = true;
      has_projects = true;
      has_wiki = false;
      homepage_url = "";
      is_template = false;
      merge_commit_message = "PR_TITLE";
      merge_commit_title = "MERGE_MESSAGE";
      squash_merge_commit_message = "COMMIT_MESSAGES";
      squash_merge_commit_title = "COMMIT_OR_PR_TITLE";
      topics = [
        "community-health-files"
        "code-of-conduct"
        "issue-templates"
        "github-templates"
      ];
      visibility = "public";
      web_commit_signoff_required = false;
    };
    agentic-jobseek = {
      allow_auto_merge = true;
      allow_forking = true;
      allow_merge_commit = true;
      allow_rebase_merge = true;
      allow_squash_merge = true;
      allow_update_branch = false;
      default_branch = "main";
      delete_branch_on_merge = true;
      description = "A Claude Code job search: discover postings, tailor a JSON Resume under an evidence gate, track each application";
      has_discussions = false;
      has_issues = true;
      has_projects = true;
      has_wiki = true;
      homepage_url = "";
      is_template = false;
      merge_commit_message = "PR_TITLE";
      merge_commit_title = "MERGE_MESSAGE";
      squash_merge_commit_message = "COMMIT_MESSAGES";
      squash_merge_commit_title = "COMMIT_OR_PR_TITLE";
      topics = [
        "agentic-ai"
        "claude-code"
        "json-resume"
        "llm"
        "pgvector"
        "python"
        "rag"
        "job-search"
        "resume"
        "typst"
        "google-drive"
      ];
      visibility = "public";
      web_commit_signoff_required = false;
    };
    agentic-ledger = {
      allow_auto_merge = true;
      allow_forking = true;
      allow_merge_commit = true;
      allow_rebase_merge = true;
      allow_squash_merge = true;
      allow_update_branch = false;
      default_branch = "main";
      delete_branch_on_merge = true;
      description = "A Claude Code project for personal financial affairs: tax, lenders, document packages, read-only on every portal";
      has_discussions = false;
      has_issues = true;
      has_projects = true;
      has_wiki = false;
      homepage_url = "";
      is_template = false;
      merge_commit_message = "PR_TITLE";
      merge_commit_title = "MERGE_MESSAGE";
      squash_merge_commit_message = "COMMIT_MESSAGES";
      squash_merge_commit_title = "COMMIT_OR_PR_TITLE";
      topics = [
        "claude-code"
        "agentic-ai"
        "human-in-the-loop"
        "personal-finance"
        "browser-automation"
        "beancount"
        "ofx"
      ];
      visibility = "public";
      web_commit_signoff_required = false;
    };
    agentic-nomad = {
      allow_auto_merge = true;
      allow_forking = true;
      allow_merge_commit = true;
      allow_rebase_merge = true;
      allow_squash_merge = true;
      allow_update_branch = false;
      default_branch = "main";
      delete_branch_on_merge = true;
      description = "A Claude Code travel planner: search, book, pay, change, cancel, refund and support, with a human gate on every spend";
      has_discussions = false;
      has_issues = true;
      has_projects = true;
      has_wiki = false;
      homepage_url = "";
      is_template = false;
      merge_commit_message = "PR_TITLE";
      merge_commit_title = "MERGE_MESSAGE";
      squash_merge_commit_message = "COMMIT_MESSAGES";
      squash_merge_commit_title = "COMMIT_OR_PR_TITLE";
      topics = [
        "claude-code"
        "agentic-ai"
        "travel"
        "mcp"
        "human-in-the-loop"
        "stripe"
        "browser-automation"
        "flights"
        "hotels"
      ];
      visibility = "public";
      web_commit_signoff_required = false;
    };
    ismailkattakath = {
      allow_auto_merge = false;
      allow_forking = true;
      allow_merge_commit = true;
      allow_rebase_merge = true;
      allow_squash_merge = true;
      allow_update_branch = false;
      default_branch = "main";
      delete_branch_on_merge = false;
      description = "Ismail Kattakath's GitHub profile README";
      has_discussions = false;
      has_issues = true;
      has_projects = true;
      has_wiki = true;
      homepage_url = "https://ismail.kattakath.com";
      is_template = false;
      merge_commit_message = "PR_TITLE";
      merge_commit_title = "MERGE_MESSAGE";
      squash_merge_commit_message = "COMMIT_MESSAGES";
      squash_merge_commit_title = "COMMIT_OR_PR_TITLE";
      topics = [ ];
      visibility = "public";
      web_commit_signoff_required = false;
    };
    jsonresume-connect = {
      allow_auto_merge = true;
      allow_forking = true;
      allow_merge_commit = true;
      allow_rebase_merge = true;
      allow_squash_merge = true;
      allow_update_branch = false;
      default_branch = "main";
      delete_branch_on_merge = true;
      description = "A step for Google Workspace Studio™: your JSON Resume rendered as a document for Google Docs™, with PDF and DOCX links.";
      has_discussions = true;
      has_issues = true;
      has_projects = true;
      has_wiki = false;
      homepage_url = "https://jsonresume-connect.kattakath.com/";
      is_template = false;
      merge_commit_message = "PR_TITLE";
      merge_commit_title = "MERGE_MESSAGE";
      squash_merge_commit_message = "COMMIT_MESSAGES";
      squash_merge_commit_title = "COMMIT_OR_PR_TITLE";
      topics = [
        "json-resume"
        "resume"
        "google-workspace"
        "workspace-studio"
        "google-workspace-add-on"
        "apps-script"
        "google-docs"
        "oauth2"
        "pkce"
      ];
      visibility = "public";
      web_commit_signoff_required = false;
    };
    listing-lens = {
      allow_auto_merge = true;
      allow_forking = true;
      allow_merge_commit = true;
      allow_rebase_merge = true;
      allow_squash_merge = true;
      allow_update_branch = false;
      default_branch = "main";
      delete_branch_on_merge = true;
      description = "Offline analysis of classified-listing crawls, built on scrape-harness";
      has_discussions = false;
      has_issues = true;
      has_projects = true;
      has_wiki = true;
      homepage_url = "";
      is_template = false;
      merge_commit_message = "PR_TITLE";
      merge_commit_title = "MERGE_MESSAGE";
      squash_merge_commit_message = "COMMIT_MESSAGES";
      squash_merge_commit_title = "COMMIT_OR_PR_TITLE";
      topics = [
        "data-analysis"
        "geocoding"
        "grafana"
        "nix"
        "nix-flake"
        "python"
        "postgresql"
        "web-scraping"
      ];
      visibility = "public";
      web_commit_signoff_required = false;
    };
    repo-kit = {
      allow_auto_merge = false;
      allow_forking = true;
      allow_merge_commit = true;
      allow_rebase_merge = true;
      allow_squash_merge = true;
      allow_update_branch = false;
      default_branch = "main";
      delete_branch_on_merge = false;
      description = "One repository shape for a Nix fleet: a shared devShell, formatting and checks, plus generated files that cannot drift.";
      has_discussions = false;
      has_issues = true;
      has_projects = true;
      has_wiki = true;
      homepage_url = "";
      is_template = false;
      merge_commit_message = "PR_TITLE";
      merge_commit_title = "MERGE_MESSAGE";
      squash_merge_commit_message = "COMMIT_MESSAGES";
      squash_merge_commit_title = "COMMIT_OR_PR_TITLE";
      topics = [
        "nix"
        "nix-flake"
        "flake-parts"
        "treefmt-nix"
        "devshell"
        "devcontainer"
        "editorconfig"
        "repository-template"
        "developer-tooling"
      ];
      visibility = "public";
      web_commit_signoff_required = false;
    };
    scrape-harness = {
      allow_auto_merge = true;
      allow_forking = true;
      allow_merge_commit = true;
      allow_rebase_merge = true;
      allow_squash_merge = true;
      allow_update_branch = false;
      default_branch = "main";
      delete_branch_on_merge = true;
      description = "A site-agnostic harness for careful, approval-gated scraping pipelines";
      has_discussions = false;
      has_issues = true;
      has_projects = true;
      has_wiki = true;
      homepage_url = "";
      is_template = false;
      merge_commit_message = "PR_TITLE";
      merge_commit_title = "MERGE_MESSAGE";
      squash_merge_commit_message = "COMMIT_MESSAGES";
      squash_merge_commit_title = "COMMIT_OR_PR_TITLE";
      topics = [
        "crawlee"
        "nix"
        "nix-flake"
        "playwright"
        "python"
        "web-scraping"
        "claude-code"
        "human-in-the-loop"
        "robots-txt"
      ];
      visibility = "public";
      web_commit_signoff_required = false;
    };
    userscripts = {
      allow_auto_merge = true;
      allow_forking = true;
      allow_merge_commit = false;
      allow_rebase_merge = true;
      allow_squash_merge = true;
      allow_update_branch = false;
      default_branch = "main";
      delete_branch_on_merge = true;
      description = "Userscripts that ship alternative experiences for legacy web apps: redesigns, not tweaks. Published on Greasy Fork.";
      has_discussions = false;
      has_issues = true;
      has_projects = true;
      has_wiki = true;
      homepage_url = "";
      is_template = false;
      merge_commit_message = "PR_TITLE";
      merge_commit_title = "MERGE_MESSAGE";
      squash_merge_commit_message = "COMMIT_MESSAGES";
      squash_merge_commit_title = "COMMIT_OR_PR_TITLE";
      topics = [
        "userscript"
        "userscripts"
        "greasyfork"
        "violentmonkey"
        "tampermonkey"
        "ui-redesign"
        "javascript"
        "css"
      ];
      visibility = "public";
      web_commit_signoff_required = false;
    };
    website = {
      allow_auto_merge = true;
      allow_forking = true;
      allow_merge_commit = true;
      allow_rebase_merge = true;
      allow_squash_merge = true;
      allow_update_branch = false;
      default_branch = "main";
      delete_branch_on_merge = true;
      description = "A portfolio site built from one JSON Resume: homepage, résumé and cover letter builder, and a /resume.json endpoint.";
      has_discussions = false;
      has_issues = true;
      has_projects = true;
      has_wiki = true;
      homepage_url = "";
      is_template = false;
      merge_commit_message = "PR_TITLE";
      merge_commit_title = "MERGE_MESSAGE";
      squash_merge_commit_message = "COMMIT_MESSAGES";
      squash_merge_commit_title = "COMMIT_OR_PR_TITLE";
      topics = [
        "portfolio"
        "json-resume"
        "resume-builder"
        "cover-letter"
        "nextjs"
        "static-site"
        "github-pages"
        "typescript"
        "tailwindcss"
      ];
      visibility = "public";
      web_commit_signoff_required = false;
    };
    # Public since 2026-11-26 (ADR-016 § 8, after a full-history scan).
    design-system = {
      allow_auto_merge = true;
      allow_forking = true;
      allow_merge_commit = true;
      allow_rebase_merge = true;
      allow_squash_merge = true;
      allow_update_branch = false;
      default_branch = "main";
      delete_branch_on_merge = true;
      description = "Duochrome, a two-value design system: pure black ink on pure white ground, Roboto type, nothing in between.";
      has_discussions = false;
      has_issues = true;
      has_projects = true;
      has_wiki = false;
      homepage_url = "";
      is_template = false;
      merge_commit_message = "PR_TITLE";
      merge_commit_title = "MERGE_MESSAGE";
      squash_merge_commit_message = "COMMIT_MESSAGES";
      squash_merge_commit_title = "COMMIT_OR_PR_TITLE";
      topics = [
        "design-system"
        "css"
        "design-tokens"
        "typography"
        "roboto"
        "monochrome"
        "black-and-white"
      ];
      visibility = "public";
      web_commit_signoff_required = false;
    };
    free-rag = {
      allow_auto_merge = true;
      allow_forking = true;
      allow_merge_commit = true;
      allow_rebase_merge = true;
      allow_squash_merge = true;
      allow_update_branch = false;
      default_branch = "main";
      delete_branch_on_merge = true;
      description = "Ingests web documentation into a private Cloudflare AI Search instance, one item per page, for retrieval from Claude";
      has_discussions = false;
      has_issues = true;
      has_projects = true;
      has_wiki = true;
      homepage_url = "";
      is_template = false;
      merge_commit_message = "PR_TITLE";
      merge_commit_title = "MERGE_MESSAGE";
      squash_merge_commit_message = "COMMIT_MESSAGES";
      squash_merge_commit_title = "COMMIT_OR_PR_TITLE";
      topics = [
        "rag"
        "cloudflare-ai-search"
        "ingestion"
        "context7"
        "nix"
        "trafilatura"
        "documentation"
      ];
      visibility = "public";
      web_commit_signoff_required = false;
    };
  };
  kattakath = {
    ".github" = {
      allow_auto_merge = true;
      allow_forking = true;
      allow_merge_commit = true;
      allow_rebase_merge = true;
      allow_squash_merge = true;
      allow_update_branch = false;
      default_branch = "main";
      delete_branch_on_merge = true;
      description = "The fleet's shared landing system: one required gate check, reusable CI workflows, rulesets and community defaults.";
      has_discussions = false;
      has_issues = true;
      has_projects = false;
      has_wiki = false;
      homepage_url = "";
      is_template = false;
      merge_commit_message = "PR_TITLE";
      merge_commit_title = "MERGE_MESSAGE";
      squash_merge_commit_message = "COMMIT_MESSAGES";
      squash_merge_commit_title = "COMMIT_OR_PR_TITLE";
      topics = [
        "github-actions"
        "reusable-workflows"
        "merge-queue"
        "rulesets"
        "continuous-integration"
        "community-health-files"
        "nix"
        "ci-cd"
        "platform-engineering"
      ];
      visibility = "public";
      web_commit_signoff_required = false;
    };
    ircc-whatsapp-bot = {
      allow_auto_merge = true;
      allow_forking = true;
      allow_merge_commit = true;
      allow_rebase_merge = true;
      allow_squash_merge = true;
      allow_update_branch = false;
      default_branch = "main";
      delete_branch_on_merge = true;
      description = "WhatsApp bot answering Canadian immigration questions from official IRCC pages, retrieved via Cloudflare AI Search";
      has_discussions = false;
      has_issues = true;
      has_projects = true;
      has_wiki = false;
      homepage_url = "";
      is_template = false;
      merge_commit_message = "PR_TITLE";
      merge_commit_title = "MERGE_MESSAGE";
      squash_merge_commit_message = "COMMIT_MESSAGES";
      squash_merge_commit_title = "COMMIT_OR_PR_TITLE";
      topics = [
        "baileys"
        "crag"
        "langchain"
        "langgraph"
        "nix"
        "openai"
        "rag"
        "whatsapp-bot"
        "cloudflare-ai-search"
        "ircc"
        "immigration"
      ];
      visibility = "public";
      web_commit_signoff_required = false;
    };
    ismail-landing = {
      allow_auto_merge = true;
      allow_forking = true;
      allow_merge_commit = true;
      allow_rebase_merge = true;
      allow_squash_merge = true;
      allow_update_branch = false;
      default_branch = "main";
      delete_branch_on_merge = true;
      description = "ismail.kattakath.com: a professional landing page and case studies, plain static HTML served by GitHub Pages";
      has_discussions = false;
      has_issues = true;
      has_projects = true;
      has_wiki = false;
      homepage_url = "https://ismail.kattakath.com";
      is_template = false;
      merge_commit_message = "PR_TITLE";
      merge_commit_title = "MERGE_MESSAGE";
      squash_merge_commit_message = "COMMIT_MESSAGES";
      squash_merge_commit_title = "COMMIT_OR_PR_TITLE";
      topics = [
        "github-pages"
        "static-site"
        "portfolio"
        "html"
        "css"
      ];
      visibility = "public";
      web_commit_signoff_required = false;
    };
    "kattakath.github.io" = {
      allow_auto_merge = true;
      allow_forking = true;
      allow_merge_commit = true;
      allow_rebase_merge = true;
      allow_squash_merge = true;
      allow_update_branch = false;
      default_branch = "main";
      delete_branch_on_merge = true;
      description = "kattakath.com: a family landing page, plain static HTML deployed by GitHub Pages with no build step";
      has_discussions = false;
      has_issues = true;
      has_projects = true;
      has_wiki = true;
      homepage_url = "https://kattakath.com";
      is_template = false;
      merge_commit_message = "PR_TITLE";
      merge_commit_title = "MERGE_MESSAGE";
      squash_merge_commit_message = "COMMIT_MESSAGES";
      squash_merge_commit_title = "COMMIT_OR_PR_TITLE";
      topics = [
        "github-pages"
        "static-site"
        "html"
      ];
      visibility = "public";
      web_commit_signoff_required = false;
    };
    nix-config = {
      allow_auto_merge = true;
      allow_forking = true;
      allow_merge_commit = false;
      allow_rebase_merge = false;
      allow_squash_merge = true;
      allow_update_branch = false;
      default_branch = "main";
      delete_branch_on_merge = true;
      description = "One declarative Nix flake for an aarch64 fleet: a nix-darwin Mac, a Raspberry Pi server, NixOS VMs and a devcontainer.";
      has_discussions = false;
      has_issues = true;
      has_projects = true;
      has_wiki = false;
      homepage_url = "";
      is_template = false;
      merge_commit_message = "PR_TITLE";
      merge_commit_title = "MERGE_MESSAGE";
      squash_merge_commit_message = "COMMIT_MESSAGES";
      squash_merge_commit_title = "COMMIT_OR_PR_TITLE";
      topics = [
        "nix"
        "nix-flake"
        "nix-darwin"
        "nixos"
        "home-manager"
        "raspberry-pi"
        "terranix"
        "agenix"
        "infrastructure-as-code"
        "devcontainer"
        "flake-parts"
        "deploy-rs"
        "cachix"
        "dotfiles"
        "aarch64"
      ];
      visibility = "public";
      web_commit_signoff_required = false;
    };
    skills = {
      allow_auto_merge = true;
      allow_forking = true;
      allow_merge_commit = false;
      allow_rebase_merge = false;
      allow_squash_merge = true;
      allow_update_branch = false;
      default_branch = "main";
      delete_branch_on_merge = true;
      description = "A Claude Code plugin marketplace: Agent Skills, hooks, output styles, MCP and LSP servers, one plugin per folder.";
      has_discussions = false;
      has_issues = true;
      has_projects = true;
      has_wiki = true;
      homepage_url = "";
      is_template = false;
      merge_commit_message = "PR_TITLE";
      merge_commit_title = "MERGE_MESSAGE";
      squash_merge_commit_message = "COMMIT_MESSAGES";
      squash_merge_commit_title = "COMMIT_OR_PR_TITLE";
      topics = [
        "claude-code"
        "claude-code-plugins"
        "plugin-marketplace"
        "agent-skills"
        "claude"
        "mcp"
        "model-context-protocol"
        "lsp"
        "ai-agents"
        "llmops"
      ];
      visibility = "public";
      web_commit_signoff_required = false;
    };
  };
}
