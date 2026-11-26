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
      description = "Default community health files for every public ismailkattakath repository";
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
      topics = [ ];
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
      description = "Claude Code project: an agentic job search — discover, tailor a JSON Resume under an evidence gate, track — with every fact in Google Drive, never in the repo.";
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
      description = "Claude Code project: Ismail's financial affairs — CRA, lenders, document packages, checklist — read-only on every portal, with a verification gate before anything leaves.";
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
      topics = [ ];
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
      description = "Claude Code project: an agentic travel planner — search, book, pay, cancel, refund, support — with a human gate on every spend.";
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
      topics = [ ];
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
      description = "Profile README";
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
      description = "JSON Resume Connect — a Google Workspace Studio step: sign in with jsonresume.org and render your résumé as a document for Google Docs™, with PDF and DOCX export";
      has_discussions = true;
      has_issues = true;
      has_projects = true;
      has_wiki = false;
      homepage_url = "";
      is_template = false;
      merge_commit_message = "PR_TITLE";
      merge_commit_title = "MERGE_MESSAGE";
      squash_merge_commit_message = "COMMIT_MESSAGES";
      squash_merge_commit_title = "COMMIT_OR_PR_TITLE";
      topics = [ ];
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
      description = "One repository shape for a Nix fleet: shared devShell, formatting and checks, plus generated files that cannot drift.";
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
      topics = [ ];
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
      description = "Userscripts that ship alternative experiences for legacy web applications — redesigns, not tweaks. Published on Greasy Fork.";
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
      topics = [ ];
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
      description = "Personal site (JSON Resume → portfolio, Next.js static export)";
      has_discussions = false;
      has_issues = true;
      has_projects = true;
      has_wiki = true;
      homepage_url = "https://ismail.kattakath.com/";
      is_template = false;
      merge_commit_message = "PR_TITLE";
      merge_commit_title = "MERGE_MESSAGE";
      squash_merge_commit_message = "COMMIT_MESSAGES";
      squash_merge_commit_title = "COMMIT_OR_PR_TITLE";
      topics = [ ];
      visibility = "public";
      web_commit_signoff_required = false;
    };
    workspace-studio = {
      allow_auto_merge = true;
      allow_forking = true;
      allow_merge_commit = true;
      allow_rebase_merge = true;
      allow_squash_merge = true;
      allow_update_branch = false;
      default_branch = "main";
      delete_branch_on_merge = true;
      description = "";
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
      topics = [ ];
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
      description = "Shared CI landing system: one required gate check, the suite run once per PR, merge queue where GitHub offers one";
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
        "ci-cd"
        "github-actions"
        "merge-queue"
        "platform-engineering"
        "reusable-workflows"
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
      description = "WhatsApp bot answering Canadian immigration questions, grounded in official IRCC content via a local pgvector RAG store with CRAG web fallback — LangGraph.js dialogue engine, crash-safe checkpointed conversations, portable Nix flake service.";
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
        "pgvector"
        "rag"
        "whatsapp-bot"
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
      description = "ismail.kattakath.com — static professional landing (GitHub Pages; source in nix-config sites/ismail-landing)";
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
      topics = [ ];
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
      description = "kattakath.com — the Kattakath family landing page (static, single self-contained index.html, deployed by GitHub Pages)";
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
      topics = [ ];
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
      description = "Declarative Nix mono-repo: macOS (nix-darwin), NixOS VM, Raspberry Pi 4, Devcontainers";
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
        "home-manager"
        "infrastructure-as-code"
        "nix"
        "nix-darwin"
        "nix-flake"
        "nixos"
        "raspberry-pi"
        "terranix"
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
      description = "Agent resources by Ismail Kattakath: Claude Code skills and plugins, plus portable data catalogs (MCP server configs) that external harnesses consume.";
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
        "agent-skills"
        "ai-agents"
        "claude-code"
        "claude-code-plugins"
        "llmops"
        "mcp"
      ];
      visibility = "public";
      web_commit_signoff_required = false;
    };
  };
}
